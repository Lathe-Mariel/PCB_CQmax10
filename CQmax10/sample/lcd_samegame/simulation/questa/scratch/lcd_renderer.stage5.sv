// lcd_renderer.sv
//
// Turns LCD scan pixels (320x240) into RGB565.  The board is the single source
// of truth and always holds the *settled* (post-commit) state; the three
// animation overlays are drawn by offsetting blocks/columns away from their
// settled position, so the board read stays a simple cell lookup.
//
//   anim_mode 0 (STATIC) : settled board
//   anim_mode 1 (BLINK)  : erase effect; the cells in `blink_mask` are blanked
//                          while `blink_on` is low (6-frame blink)
//   anim_mode 2 (FALL)   : a block whose target row is t is drawn shifted UP
//                          by the distance still to go:
//                            top = t*20 - (d*20 - min(fall_px, d*20))
//   anim_mode 3 (SHIFT)  : a column whose target is tc is drawn shifted RIGHT
//                          by the distance still to go (it slides right->left):
//                            left = (tc + d)*20 - min(shift_px, d*20)
//
// `fall_dist` / `shift_dist` are indexed by the *target* (settled) cell /
// column and are produced by the gravity / column-shift engines.
//
// ---------------------------------------------------------------------------
// PIPELINE - each stage is REGISTERED on BOTH sides on purpose
// ---------------------------------------------------------------------------
// The pixel source is polled one pixel per clock, so the renderer has no spare
// cycles - but it does have *latency*, which the LCD controller simply waits
// out.  Everything is spread over five short stages:
//
//   cycle 0 : the LCD controller asserts pix_req with pix_x / pix_y
//   edge 1  : S0 register the pixel coords and their /20 decomposition
//   edge 2  : S1 register the animation result (source cell + logo coords)
//   edge 3  : S2 register the logo index, the empty flag AND the logo coords
//   cycle 3 : rom_addr is presented; logo_ram latches it
//   cycle 4 : logo_ram's registered read has produced rom_data for THIS pixel
//   edge 5  : S4 register pix_color / pix_valid        -> pixel in cycle 5
//
// The logo coords MUST be delayed into the same stage as the logo index.
// They cannot stay in S1 while the index advances to S2: rom_addr would then
// be built from id(N-1) and rly(N)/rlx(N) at once - one pixel of lag on the
// logo id, which looks like every image shifted one pixel to the left (and
// costs one wrong pixel per pixel for the whole frame).
//
// Because rom_addr is presented one cycle later than the stage-2 registers,
// the 16-bit rom_d register is not needed at all: rom_data is already the
// registered output of logo_ram and lands exactly where pix_color is formed.
//
// Splitting the stages is NOT cosmetic: with the /20 multiply, the animation
// loop, the cell lookup and the logo address all in one cycle the design missed
// setup by -22.3 ns at 50 MHz.  With the registers in place the worst path is
// only the animation loop itself.
//
// pix_valid is asserted for EVERY request, including out-of-field pixels
// (which return BG_COLOR); otherwise the LCD controller would wait forever for
// a pixel mid-frame.
//
// ---------------------------------------------------------------------------
// ARITHMETIC NOTES - three real bugs lived here, do not "simplify" them back
// ---------------------------------------------------------------------------
// 1. In Verilog/SystemVerilog the *assignment* context fixes the width of a
//    whole expression, not the widest operand, so
//        cx = (({3'd0, pix_x} * 13'd410) >> 13);        // WRONG
//    truncated the 130790 product to 13 bits and returned cx = 0 for every
//    pix_x >= 20: 75 983 of 76 801 pixels came from column 0 / row 0.
//    The product must live in a variable wide enough for it (17 bits here).
//
// 2.      rom_addr = (id0 * 9'd400) + (ly0 * 5'd20) + lx0;   // WRONG
//    evaluated id*400 in a 9-bit context, so Logo3 got 1200 & 0x1FF = 176 and
//    Logo4 got 1600 & 0x1FF = 64 - two logos fetched the wrong image.
//    12 bits are used below and the sum (<= 1999) is narrowed only at the end.
//
// 3. The logo store has a REGISTERED read, so the data for the address
//    presented in cycle t appears in cycle t+1.  A three-stage pipeline paired
//    the CURRENT empty flag with the PREVIOUS pixel's logo data, which made
//    every cell one logo too late (62 700 wrong pixels once bug 1 was fixed).
//    Each stage below carries the request flag, the empty flag and the data by
//    the same amount.
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
    input  logic [COLS*4-1:0] shift_dist   // per target column, in cells
);
    localparam logic [2:0] EMPTY = 3'b111;

    // ==================================================================
    // S0 : pixel coordinates -> cell index + logo coordinates
    // ==================================================================
    logic [3:0] cx, cy;
    logic [4:0] lx, ly;

    // The product needs 17 bits (319*410 = 130790) - see note 1 above.
    //
    // The subtractions are NOT cast to 5 bits on purpose.  In
    //     lx = pix_x - (cx * 5'd20);
    // the 9-bit pix_x sets the context of the whole expression, so the
    // multiply is evaluated at 9 bits and cannot lose bits (cx*20 <= 300).
    // Writing `5'(pix_x - (cx * 5'd20))` forces a 5-BIT context and then
    // cx=2 already gives 40 & 31 = 8 - a silent, cell-sized error.
    logic [17:0] mul_x, mul_y;
    always_comb begin
        mul_x = pix_x * 9'd410;
        mul_y = {1'b0, pix_y} * 9'd410;
        cx    = mul_x[16:13];              // pix_x / 20   (0..15)
        cy    = mul_y[16:13];              // pix_y / 20   (0..11)
        lx    = pix_x - (cx * 5'd20);      // cx*20 <= 300
        ly    = pix_y - (cy * 5'd20);      // cy*20 <= 220
    end

    logic        req0;
    logic [3:0]  cx0, cy0;
    logic [4:0]  lx0, ly0;
    logic [8:0]  px0;              // pixel coords, delayed with cx0/cy0
    logic [7:0]  py0;

    always_ff @(posedge clk) begin
        if (rst) begin
            req0 <= 1'b0;
            cx0  <= 4'd0;
            cy0  <= 4'd0;
            lx0  <= 5'd0;
            ly0  <= 5'd0;
            px0  <= 9'd0;
            py0  <= 8'd0;
        end else begin
            req0 <= pix_req;
            cx0  <= cx;
            cy0  <= cy;
            lx0  <= lx;
            ly0  <= ly;
            px0  <= pix_x;
            py0  <= pix_y;
        end
    end

    // ==================================================================
    // S1 : animation overlay -> which cell and which logo coords are shown
    // ==================================================================
    logic [AW-1:0] matched_addr;
    logic [4:0]    rlx, rly;
    logic          matched;        // 1 = a block covers this pixel

    always_comb begin
        matched_addr = AW'(cy0)*COLS + AW'(cx0);
        rlx     = lx0;
        rly     = ly0;
        matched = 1'b1;

        case (anim_mode)
        2'd0: begin
            // static: the settled board
        end

        2'd1: begin
            // blink: the cells being erased are blanked while blink_on is low
            if (blink_mask[matched_addr] && !blink_on) matched = 1'b0;
        end

        2'd2: begin
            // FALL.  For each target row t in this column the displayed top is
            //     top = t*20 - (d*20 - min(fall_px, d*20))
            // and the block covers [top, top+20); the logo row is pix_y - top.
            //
            // All the arithmetic fits in 9 bits: t*20 <= 220, d <= ROWS-1 so
            // d*20 <= 220, top <= 220 and top + 20 <= 240.  When
            // rem > t*20 the subtraction wraps to a value >= 256, which is
            // above 239, so the range test rejects it and the wrap is harmless
            // by construction.  fall_dist is clamped to ROWS-1 so a corrupted
            // map cannot push d*20 out of range.
            logic found;
            found   = 1'b0;
            matched = 1'b0;
            for (int t = 0; t < ROWS; t++) begin
                logic [3:0] d;
                logic [8:0] dpx, rem9, top, v;
                d   = fall_dist[4*(cx0*ROWS + t) +: 4];
                if (d > 4'(ROWS-1)) d = 4'd0;
                dpx  = {5'd0, d} * 9'd20;
                rem9 = (fall_px < dpx) ? (dpx - fall_px) : 9'd0;

                // A block whose remaining travel exceeds its own target row is
                // still entirely above the screen, so reject it.  Handling
                // that first keeps `top` in 0..220 and the offset test below
                // exact: without the guard `top` could wrap to >= 292 and
                // py0 - top would alias back into 0..19.
                if (rem9 <= 9'(t * 20)) begin
                    logic [8:0] off;
                    top = 9'(t * 20) - rem9;

                    // ONE comparison instead of `py0 >= top && py0 < top+20`:
                    // py0 - top wraps to >= (512 - 220) = 292 when py0 < top,
                    // which is also > 20, so `off < 20` means exactly
                    // "py0 is inside [top, top+20)".  `off` is the logo row,
                    // so the separate subtraction disappears too.
                    off = {1'b0, py0} - top;
                    if (off < 9'd20) begin
                        matched_addr = AW'(t)*COLS + AW'(cx0);
                        rly   = off[4:0];
                        found = 1'b1;
                    end
                end
            end
            matched = found;
        end

        2'd3: begin
            // SHIFT.  For each target column tc the displayed left is
            //     left = (tc + d)*20 - min(shift_px, d*20)
            // and the column covers [left, left+20); the logo column is
            // pix_x - left.
            //
            // NOTE the asymmetry with FALL: there the distance STILL TO GO is
            // subtracted from t*20, here the distance TRAVELLED is subtracted
            // from (tc+d)*20.  Using the FALL form here stops every moved
            // column one cell short of its target.
            //
            // 9 bits again: tc+d is the SOURCE column, always <= COLS-1, so
            // (tc+d)*20 <= 300.
            logic found;
            found   = 1'b0;
            matched = 1'b0;
            for (int tc = 0; tc < COLS; tc++) begin
                logic [3:0] d;
                logic [8:0] dpx, src, left, off;
                d   = shift_dist[4*tc +: 4];
                if (d > 4'(COLS-1)) d = 4'd0;
                dpx = {5'd0, d} * 9'd20;
                // (tc + d) is the SOURCE column, i.e. where this column came
                // from; it is always <= COLS-1 so the product is <= 300.
                src = {4'd0, tc} * 9'd20 + dpx;
                left = src - ((shift_px < dpx) ? shift_px : dpx);

                // left = src - min(...) is never negative (src >= dpx), so
                // px0 - left wraps to >= 512 - 300 = 212 when px0 < left and
                // ONE comparison `off < 20` is exactly the original
                // `px0 >= left && px0 < left+20`.  `off` is the logo column.
                off = px0 - left;
                if (off < 9'd20) begin
                    matched_addr = AW'(cy0)*COLS + AW'(tc);
                    rlx   = off[4:0];
                    found = 1'b1;
                end
            end
            matched = found;
        end

        default: ;
        endcase
    end

    // S1 : register the animation result
    logic          req1, matched1;
    logic [AW-1:0] addr1;
    logic [4:0]    rlx1, rly1;

    always_ff @(posedge clk) begin
        if (rst) begin
            req1     <= 1'b0;
            matched1 <= 1'b0;
            addr1    <= '0;
            rlx1     <= 5'd0;
            rly1     <= 5'd0;
        end else begin
            req1     <= req0;
            matched1 <= matched;
            addr1    <= matched_addr;
            rlx1     <= rlx;
            rly1     <= rly;
        end
    end

    // board_rd_data is combinational from addr1
    assign board_rd_addr = addr1;

    // ==================================================================
    // S2 : the cell id is available now, together with rlx1 / rly1
    // ==================================================================
    logic [2:0]  id2;
    logic        empty2;
    logic        req2;
    logic [4:0]  rlx2, rly2;      // logo coords, delayed with id2

    // a block is shown only if something covers the pixel and the cell is not
    // EMPTY
    wire shown = matched1 && (board_rd_data != EMPTY);

    always_ff @(posedge clk) begin
        if (rst) begin
            id2    <= 3'd0;
            empty2 <= 1'b1;
            req2   <= 1'b0;
            rlx2   <= 5'd0;
            rly2   <= 5'd0;
        end else begin
            // when nothing is shown the id only feeds the unused logo address;
            // use 0 so the address always stays inside logo_ram (3'd7 would
            // give 7*400 = 2800, past the 2048-word memory).
            id2    <= shown ? board_rd_data : 3'd0;
            empty2 <= !shown;
            req2   <= req1;
            rlx2   <= rlx1;
            rly2   <= rly1;
        end
    end

    // ==================================================================
    // S3 : rom_addr for this request (all three fields from the same pixel)
    // ==================================================================
    // 12-bit intermediates: id*400 <= 1600 and ly*20 <= 380 - see note 2.
    // The sum is <= 1600 + 380 + 19 = 1999, so narrowing to 11 bits is exact.
    logic [11:0] rom_id, rom_ly;
    always_comb begin
        rom_id = {9'd0, id2} * 12'd400;
        rom_ly = {7'd0, rly2} * 12'd20;
    end

    assign rom_addr = RA_W'(rom_id + rom_ly + {7'd0, rlx2});

    // stage 3 registers: only the request flag and the empty flag are needed,
    // rom_data comes straight from logo_ram's registered read port.
    logic req3, empty3;

    always_ff @(posedge clk) begin
        if (rst) begin
            req3   <= 1'b0;
            empty3 <= 1'b1;
        end else begin
            req3   <= req2;
            empty3 <= empty2;
        end
    end

    // ==================================================================
    // S4 : emit the colour (rom_data is this pixel's logo word)
    // ==================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            pix_color <= BG_COLOR;
            pix_valid <= 1'b0;
        end else begin
            pix_color <= empty3 ? BG_COLOR : rom_data;
            pix_valid <= req3;
        end
    end
endmodule
