// lcd_renderer.sv
//
// Turns LCD scan pixels (320x240) into RGB565.  The board is the single source
// of truth and always holds the *settled* (post-commit) state; the animation
// overlays are drawn by offsetting blocks/columns away from their settled
// position, so the board read stays a simple cell lookup.
//
//   anim_mode 0 (STATIC) : settled board
//   anim_mode 1 (BLINK)  : erase effect; cells in `blink_mask` are blanked
//                          while `blink_on` is low
//   anim_mode 2 (FALL)   : each target cell (cx,t) is drawn shifted UP by its
//                          remaining fall distance:
//                            top = t*20 - min(fall_px, fall_dist[cx,t]*20)
//   anim_mode 3 (SHIFT)  : each column (tc) is drawn shifted RIGHT by its
//                          remaining slide distance (it slides right->left):
//                            left = (tc + shift_dist[tc])*20
//                                   - min(shift_px, shift_dist[tc]*20)
//
// `fall_dist` / `shift_dist` are indexed by the *target* (settled) cell /
// column and are produced by the gravity / column-shift engines.
//
// ---------------------------------------------------------------------------
// WHY THIS IS A REQUEST/DONE FSM - do not "simplify" it back
// ---------------------------------------------------------------------------
// Resolving a pixel COMBINATIONALLY does not close timing at 50 MHz: the
// unrolled 12/16-way search, the reciprocal-multiply /20, the board read and
// the EMPTY compare all land in one 20 ns cycle.  Measured worst setup slack
// was -17.992 ns, critical path
//     u_lcd|pix_x -> Mult0 -> fall_dist mux -> Add52..Add55 -> LessThan ->
//     board_rd_addr -> u_board 192:1 read mux -> Equal0 -> id0     (41 ns).
// It only ever *looked* cheap because the divide was buggy: in
//     cx = (({3'd0, pix_x} * 13'd410) >> 13);
// the 130790 product is truncated to 13 bits, so cx was ALWAYS 0 and Quartus
// folded the whole cell search away.
//
// So the search is SEQUENTIAL: while anim_mode is FALL or SHIFT the FSM walks
// one candidate row/column per clock.  A pixel takes 4 clocks (STATIC/BLINK)
// or M+4 clocks (FALL/SHIFT, M = ROWS or COLS), and a new request is only
// accepted once the pixel has been emitted.
//
// The LCD controller pulses `pix_req` and waits in S_SCAN_WAIT until
// `pix_valid`, so it tolerates any latency.  A frame grows from 76,800 * 70 clk
// (~108 ms) to about 76,800 * 80 clk (~123 ms); fine for a puzzle game.
//
// pix_valid is asserted for EVERY request, including pixels no block covers
// (they return BG_COLOR); otherwise the LCD controller would stall mid-frame.
//
// States:
//   R_IDLE : wait for pix_req, latch the /20 decomposition
//   R_CELL : present the pixel's own cell (STATIC/BLINK), board read in flight
//   R_SCAN : one candidate per clock (FALL/SHIFT)
//   R_WAIT : board read for the winning cell in flight
//   R_LOGO : present rom_addr (registered), the logo read starts on the next
//            edge because rom_addr itself is a register
//   R_LW   : logo read in flight
//   R_EMIT : emit pix_color / pix_valid, then back to R_IDLE
//
// A pixel therefore takes 5 clocks with STATIC/BLINK and M+5 with FALL/SHIFT
// (M = ROWS or COLS).
//
// ---------------------------------------------------------------------------
// ARITHMETIC NOTES - real bugs lived here, do not "simplify" them back
// ---------------------------------------------------------------------------
// 1. The /20 reciprocal multiply must be evaluated in a variable wide enough
//    for the product (319*410 = 130790 needs 17 bits).  In a 13-bit context it
//    truncates and cx becomes 0 for every pix_x >= 20.
//
// 2.      rom_addr = (id0 * 9'd400) + (ly0 * 5'd20) + lx0;   // WRONG
//    evaluates id*400 in a 9-bit context, so Logo3 got 1200 & 0x1FF = 176 and
//    Logo4 got 1600 & 0x1FF = 64 - two logos fetched the wrong image.
//    12 bits are used below; the sum (<= 1999) is narrowed only at the end.
//
// 3. The logo store has a REGISTERED read, so `rom_data` is valid only in the
//    cycle AFTER the address is presented.  R_LOGO presents the address and
//    R_EMIT consumes rom_data; the empty flag travels with it.
//
// `x/20` is (x * 410) >> 13, exact for x in 0..319.
// `x%20` is x - (x/20)*20, exact because (x/20)*20 <= 300.

module lcd_renderer #(
    parameter int COLS = 16,
    parameter int ROWS = 12,
    parameter int CELLS = COLS * ROWS,      // 192
    parameter int AW    = 8,                // cell address width
    parameter int RA_W  = 11,               // logo ROM address width (0..1999)
    parameter logic [15:0] BG_COLOR = 16'h0000
)(
    input  logic        clk,
    input  logic        rst,

    // pixel request from the LCD controller
    input  logic        pix_req,
    input  logic [8:0]  pix_x,             // 0..319
    input  logic [7:0]  pix_y,             // 0..239

    output logic [15:0] pix_color,
    output logic        pix_valid,

    // board single-cell read A (combinational)
    output logic [AW-1:0] board_rd_addr,
    input  logic [2:0]    board_rd_data,

    // logo ROM (registered read)
    output logic [RA_W-1:0] rom_addr,
    input  logic [15:0]    rom_data,

    // animation state (from game_fsm)
    input  logic [1:0]   anim_mode,        // 0 static, 1 blink, 2 fall, 3 shift
    input  logic [CELLS-1:0] blink_mask,
    input  logic            blink_on,
    input  logic [8:0]   fall_px,          // global fall progress (pixels)
    input  logic [CELLS*4-1:0] fall_dist,  // per target cell, in cells (0..11)
    input  logic [8:0]   shift_px,         // global shift progress (pixels)
    input  logic [COLS*4-1:0] shift_dist,  // per target column, in cells

    // cursor overlay (from game_fsm).  cur_on = 1 draws it.
    input  logic         cur_on,
    input  logic [3:0]   cur_x,
    input  logic [3:0]   cur_y,

    // ------------------------------------------------------------------
    // GAME-OVER BANNER
    //
    // The game is over when no group of two or more same-coloured cells is
    // left, which game_fsm determines by flood-filling every cell.  Until now
    // `game_over` was computed and then went nowhere visible, so the player had
    // no way to tell "no moves left" from "the buttons stopped working".
    //
    // This draws a red band with a white outline across the top of the panel.
    // It is deliberately NOT a text bitmap: the logo ROM is full (2000 words =
    // 2 M9K blocks) and there is no font in the design, so a solid banner is the
    // only way to signal it without adding memory.  ○ restarts.
    //
    // Drawn LAST, so it covers the board and the cursor rather than the other
    // way round - during game over those are not interactive anyway.
    // ------------------------------------------------------------------
    input  logic         game_over
);
    localparam logic [2:0] EMPTY = 3'b111;

    // ------------------------------------------------------------------
    // game-over banner geometry
    //
    // Full width, rows 90..149 (60 px tall, centred on the 240-row panel).  A
    // 2 px white outline around the red fill keeps the band obvious even if the
    // panel's colours are slightly off.
    //
    // THESE MUST BE DECLARED ABOVE THE always_ff THAT USES THEM.  Putting them at
    // the end of the file looked fine to Quartus but Questa's vlog rejected all
    // four uses with (vlog-2730) "Undefined variable", which failed the renderer
    // suite and the integration suite outright.  Module-scope `logic`/`wire` may
    // be used before their declaration, a `localparam` may NOT.
    // ------------------------------------------------------------------
    localparam logic [15:0] GO_FILL   = 16'hF800;   // red
    localparam logic [15:0] GO_BORDER = 16'hFFFF;   // white
    localparam int GO_Y0 = 90;
    localparam int GO_Y1 = 150;     // exclusive

    // sized copy of the geometry parameter used for the FALL scan base.  The
    // parameter is a plain `int` (32-bit, SIGNED), so using it directly in a
    // narrow expression makes Quartus warn "truncated value with size 32 to
    // match size of target" and can turn a comparison into a signed/unsigned
    // one.
    localparam logic [7:0] ROWS_W = 8'(ROWS);

    typedef enum logic [2:0] {
        R_IDLE, R_CELL, R_SCAN, R_WAIT, R_LOGO, R_LW, R_EMIT
    } rstate_t;
    rstate_t st;

    // ------------------------------------------------------------------
    // /20 decomposition (combinational).  It feeds the R_IDLE registers, so the
    // multiplier never shares a cycle with the search.  See note 1.
    // ------------------------------------------------------------------
    logic [17:0] mx, my;
    logic [3:0]  cx, cy;
    logic [4:0]  lx, ly;
    always_comb begin
        mx = pix_x * 9'd410;
        my = {1'b0, pix_y} * 9'd410;
        cx = mx[16:13];
        cy = my[16:13];
        lx = pix_x - (cx * 5'd20);
        ly = pix_y - (cy * 5'd20);
    end

    // per-request registers
    logic [3:0]  cx0, cy0;         // pixel's cell (column, row)
    logic [4:0]  lx0, ly0;         // pixel offset inside that cell
    logic [1:0]  mode0;            // anim_mode latched with the request
    logic [3:0]  idx0;             // search index: target row / target column
    logic        foundv;           // a usable match was found
    logic [AW-1:0] faddr;          // matched cell address
    logic [4:0]  flx, fly;         // logo x / y inside the matched cell

    // ------------------------------------------------------------------
    // Search-candidate registers.  `scan_addr` is the WORD index into
    // fall_dist / shift_dist and `span_r` is idx0*20.  Both are advanced by
    // the R_SCAN state instead of being recomputed combinationally from
    // cx0 / idx0.
    //
    // NOTE the two arrays are indexed DIFFERENTLY and scan_addr has to match:
    //   fall_dist  is per CELL   -> word index = cx0*ROWS + idx0
    //   shift_dist is per COLUMN -> word index =           idx0
    // (Using the cell base for shift_dist reads past the end of the array and
    // silently returns 0 for every shifted column - the renderer TB caught
    // exactly that when this was first written.)
    //
    // WHY the registers (measured, do not "simplify" back): with
    //     d = fall_dist[4*(cx0*ROWS + idx0) +: 4]
    // the two small adders (cx0*ROWS) sat in the same cycle as the 192:1
    // read mux, so the mux SELECT arrived ~5.7 ns late and the mux was
    // decomposed into 6 cascaded LUT levels.  The resulting path
    //     cx0 -> Add4 -> Add5 -> Mux2 x6 -> Add6 -> LessThan0 -> rem9 ->
    //     Add8 -> Add9 -> flx -> board_rd_addr -> faddr
    // needed 20.600 ns of a 20 ns period (slack -0.733 ns).  Registering
    // the index moves cx0*ROWS into R_IDLE and idx0*20 into an increment,
    // so the mux select is ready at the clock edge.
    // ------------------------------------------------------------------
    logic [7:0]  scan_addr;        // fall_dist / shift_dist word index
    logic [8:0]  span_r;           // idx0 * 20, accumulated in R_SCAN

    // pixel position on the display, in pixels (0..319 / 0..239).  Registered in
    // R_IDLE so that cx0*20 leaves the search cycle: with it in the path the
    // step needed 19.65 ns of a 20 ns period.  The position never changes while
    // a pixel is being resolved.
    logic [8:0] pxa, pya;

    // last search index for the active mode
    wire [3:0] last_idx = (mode0 == 2'd2) ? 4'(ROWS-1) : 4'(COLS-1);

    // logo address accumulator (12 bits - see note 2)
    logic [11:0] rom_acc;

    // ------------------------------------------------------------------
    // cursor overlay
    //
    // The cursor cell is drawn INVERTED (RGB565 inverted is just `~color`), so
    // no second logo image and no extra memory is needed - which matters on a
    // MAX 10 10M08 where the logo ROM has no spare room.
    //
    // `faddr` already holds the cell being emitted in EVERY mode:
    //   STATIC / BLINK : the pixel's own cell (set in R_IDLE)
    //   FALL / SHIFT   : the cell the search matched
    // so a single comparison covers all four animations, and during FALL/SHIFT
    // the cursor correctly rides along with the moving block.
    //
    // The address is REGISTERED rather than recomputed in R_EMIT: cur_y*COLS is
    // a shift (COLS == 16) but the module's timing discipline is to keep every
    // arithmetic term out of the emit cycle, and this costs one 8-bit compare.
    //
    // NOTE the cursor is inverted even where the cell is EMPTY (base colour =
    // BG_COLOR): inverting black gives white, which is exactly what makes the
    // cursor VISIBLE on an empty panel.  Without that the player could not see
    // the cursor at all once it moved onto a cleared cell.
    // ------------------------------------------------------------------
    logic [AW-1:0] cur_addr;      // cursor cell address, registered
    logic          cur_vis;       // 1 = the cursor should be drawn

    always_ff @(posedge clk) begin
        if (rst) begin
            cur_addr <= '0;
            cur_vis  <= 1'b0;
        end else begin
            cur_addr <= AW'(cur_y) * COLS + AW'(cur_x);
            cur_vis  <= cur_on;
        end
    end

    // ------------------------------------------------------------------
    // one search step : exactly ONE candidate cell per clock
    // (FALL = one target row, SHIFT = one target column)
    // ------------------------------------------------------------------
    logic        hit;
    logic [AW-1:0] hit_addr;
    logic [4:0]  hit_lx, hit_ly;

    always_comb begin
        logic [3:0] d;
        logic [8:0] dpx, rem9, off;

        hit      = 1'b0;
        hit_addr = faddr;
        hit_lx   = flx;
        hit_ly   = fly;

        if (mode0 == 2'd2) begin
            // FALL: the block whose TARGET row is idx0, in this column.
            // scan_addr == cx0*ROWS + idx0 and span_r == idx0*20, both
            // registered / incremented in the FSM (see the note above).
            d    = fall_dist[4*scan_addr +: 4];
            dpx  = {5'd0, d} * 9'd20;
            // A block whose remaining travel exceeds its own target row is
            // still entirely above the screen, so reject it.  This keeps the
            // displayed top within 0..220 and makes the range test exact.
            rem9 = (fall_px < dpx) ? (dpx - fall_px) : 9'd0;
            if (rem9 <= span_r) begin
                // off = py_abs - top.  It wraps to >= 512-220 = 292 when
                // py_abs < top, which is also > 20, so `off < 20` means exactly
                // "py_abs is inside [top, top+20)".
                off = pya - (span_r - rem9);
                if (off < 9'd20) begin
                    hit      = 1'b1;
                    hit_addr = AW'(idx0) * COLS + AW'(cx0);
                    hit_lx   = lx0;              // logo column is unchanged
                    hit_ly   = off[4:0];         // logo row = py_abs - top
                end
            end
        end else begin
            // SHIFT: the block whose TARGET column is idx0, in this row.
            d    = shift_dist[4*scan_addr +: 4];
            dpx  = {5'd0, d} * 9'd20;
            // (idx0 + d) is the SOURCE column, i.e. where this column came
            // from; it is always <= COLS-1 so the product is <= 300.
            // NOTE the asymmetry with FALL: here the distance TRAVELLED is
            // subtracted from (idx0+d)*20, while FALL subtracts the distance
            // STILL TO GO from idx0*20.  Using the FALL form here would stop
            // every moved column one cell short of its target.
            // span_r + dpx == (idx0 + d)*20, built by an increment plus a
            // small constant multiply instead of a wide multiply.
            off = pxa - ((span_r + dpx) - ((shift_px < dpx) ? shift_px : dpx));
            if (off < 9'd20) begin
                hit      = 1'b1;
                hit_addr = AW'(cy0) * COLS + AW'(idx0);
                hit_lx   = off[4:0];             // logo column = px_abs - left
                hit_ly   = ly0;                  // logo row is unchanged
            end
        end
    end

    // ==================================================================
    // FSM
    // ==================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            st            <= R_IDLE;
            cx0 <= 4'd0;  cy0 <= 4'd0;
            lx0 <= 5'd0;  ly0 <= 5'd0;
            pxa <= 9'd0;  pya <= 9'd0;
            mode0 <= 2'd0;
            idx0  <= 4'd0;
            foundv <= 1'b0;
            faddr  <= '0;
            flx    <= 5'd0;
            fly    <= 5'd0;
            scan_addr <= 8'd0;
            span_r    <= 9'd0;
            board_rd_addr <= '0;
            rom_addr      <= '0;
            pix_color     <= BG_COLOR;
            pix_valid     <= 1'b0;
        end else begin
            pix_valid <= 1'b0;
            rom_addr  <= '0;

            case (st)
            // ---------------------------------------------- accept request
            R_IDLE: begin
                if (pix_req) begin
                    cx0   <= cx;
                    cy0   <= cy;
                    lx0   <= lx;
                    ly0   <= ly;
                    pxa   <= {1'b0, lx} + (cx * 9'd20);
                    pya   <= {1'b0, ly} + (cy * 9'd20);
                    mode0 <= anim_mode;
                    idx0  <= 4'd0;
                    if (anim_mode == 2'd0 || anim_mode == 2'd1) begin
                        // STATIC / BLINK have no search: the shown cell is this
                        // pixel's own cell.  Present it now.
                        board_rd_addr <= AW'(cy) * COLS + AW'(cx);
                        faddr         <= AW'(cy) * COLS + AW'(cx);
                        flx           <= lx;
                        fly           <= ly;
                        st            <= R_CELL;
                    end else begin
                        foundv <= 1'b0;
                        // First candidate.  FALL walks the rows of column cx
                        // (a per-CELL array, so the base is cx*ROWS); SHIFT
                        // walks the columns and shift_dist is per COLUMN, so
                        // its word index simply starts at 0.
                        scan_addr <= (anim_mode == 2'd2) ? {4'd0, cx} * ROWS_W
                                                         : 8'd0;
                        span_r    <= 9'd0;
                        st     <= R_SCAN;
                    end
                end
            end

            // -------------------------- STATIC / BLINK: board read in flight
            R_CELL: begin
                logic shown;
                shown = (board_rd_data != EMPTY);
                // blink blanks the cells of blink_mask while blink_on is low
                if (mode0 == 2'd1 && blink_mask[faddr] && !blink_on)
                    shown = 1'b0;
                foundv <= shown;
                st     <= R_LOGO;
            end

            // ------------------------------- FALL / SHIFT: one candidate/clock
            R_SCAN: begin
                if (hit) begin
                    foundv <= 1'b1;
                    faddr  <= hit_addr;
                    flx    <= hit_lx;
                    fly    <= hit_ly;
                end
                if (idx0 == last_idx) begin
                    // the last candidate was folded in above, except that the
                    // winner's address still has to be presented for the board
                    // read.  `hit` now refers to the last candidate.
                    board_rd_addr <= hit ? hit_addr : faddr;
                    st            <= R_WAIT;
                end else begin
                    idx0      <= idx0 + 4'd1;
                    scan_addr <= scan_addr + 8'd1;
                    span_r    <= span_r + 9'd20;
                end
            end

            // --------------------------------- board read of the winning cell
            R_WAIT: begin
                foundv <= foundv && (board_rd_data != EMPTY);
                st     <= R_LOGO;
            end

            // --------------------------------- logo address, read in flight
            R_LOGO: begin
                // 12-bit intermediates, see note 2.  id*400 <= 1600 and
                // ly*20 <= 380, sum <= 1999, so narrowing to 11 bits is exact.
                // The id is forced to 0 when nothing is shown so the address
                // always stays inside logo_ram (3'd7 would give 7*400 = 2800,
                // past the 2048-word memory).
                rom_acc = {9'd0, foundv ? board_rd_data : 3'd0} * 12'd400
                        + {7'd0, fly} * 12'd20
                        + {7'd0, flx};
                rom_addr <= rom_acc[RA_W-1:0];
                st       <= R_LW;
            end

            // --------------------------------- logo read in flight
            // rom_addr is REGISTERED, so logo_ram only captures it on the next
            // edge; its own registered read then needs one more edge before
            // rom_data describes this pixel.  Hence the extra wait state.
            R_LW: begin
                st <= R_EMIT;
            end

            // --------------------------------- emit and free the FSM
            R_EMIT: begin
                // rom_data belongs to the address presented in R_LOGO.
                // The cursor cell is inverted (see the note above `cur_addr`).
                //
                // GAME-OVER BANNER is applied LAST, as an override, so the board
                // and the cursor cannot punch through it.  `pya` is the display
                // row of THIS pixel (registered in R_IDLE and unchanged since), so
                // the band lines up exactly with the pixel being emitted.
                //
                // Why a solid band and not text: the logo ROM is full (2000 words
                // = 2 M9K blocks) and there is no font in the design, so text would
                // mean another memory.  Red fill with a white outline is
                // unmistakable and costs two comparators.  ○ restarts.
                if (game_over && (pya >= 8'(GO_Y0)) && (pya < 8'(GO_Y1))) begin
                    pix_color <= ((pya < 8'(GO_Y0 + 2)) || (pya >= 8'(GO_Y1 - 2)))
                                 ? GO_BORDER
                                 : GO_FILL;
                end else begin
                    pix_color <= (cur_vis && faddr == cur_addr)
                                 ? ~(foundv ? rom_data : BG_COLOR)
                                 :  (foundv ? rom_data : BG_COLOR);
                end
                pix_valid <= 1'b1;
                st        <= R_IDLE;
            end

            default: st <= R_IDLE;
            endcase
        end
    end
endmodule
