// lcd_renderer.sv
//
// Turns LCD scan pixels (320x240) into RGB565.  The board is the single source
// of truth and always holds the *settled* (post-commit) state; the three
// animation overlays are drawn by offsetting blocks/columns away from their
// settled position, so the board read stays a simple cell lookup.
//
//   anim_mode 0 (STATIC) : settled board
//   anim_mode 1 (BLINK)  : erase effect; cells in `blink_mask` are blanked
//                           while `blink_on` is low (6-frame blink)
//   anim_mode 2 (FALL)   : each non-empty cell (cx,t) is drawn shifted UP by
//                           its remaining fall distance:
//                           top = t*20 - min(fall_px, fall_dist[cx,t]*20)
//   anim_mode 3 (SHIFT)  : each column (tc) is drawn shifted RIGHT by its
//                           remaining slide distance (it slides right->left):
//                           left = (tc + shift_dist[tc])*20
//                                  - min(shift_px, shift_dist[tc]*20)
//
// `fall_dist` / `shift_dist` are indexed by the *target* (settled) cell /
// column, and are produced by the gravity / column-shift engines.
//
// Read pipeline (3 cycles, pix_valid asserted for every request):
//   stage0 : resolve matched cell + logo coords + empty flag
//            rom_addr = id*400 + ly*20 + lx  (combinational)
//   stage1 : register req / empty / rom data
//   stage2 : emit colour
//
// id*400 = id*256 + id*128 + id*16 ; ly*20 = ly*16 + ly*4.

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

    logic [3:0] cx, cy;
    logic [4:0] lx, ly;

    // ---- divide pixel coords by 20 (combinational) ----
    // Reciprocal multiply: floor(x/20) = (x*410) >> 13, exact for 0..319.
    //   cx = pix_x/20   lx = pix_x - cx*20
    //   cy = pix_y/20   ly = pix_y - cy*20
    // cx*20 = cx*16 + cx*4 (shift-and-add, no multiplier).
    logic [17:0] mx, my;
    always_comb begin
        mx = pix_x * 9'd410;
        my = {1'b0, pix_y} * 9'd410;
        cx = mx[16:13];
        cy = my[16:13];
        lx = pix_x - (cx * 5'd20);
        ly = pix_y - (cy * 5'd20);
    end

    // ---- resolve the source cell + logo coords for this pixel ----
    logic [AW-1:0] matched_addr;
    logic [4:0]    rlx, rly;
    logic          is_empty;

    always_comb begin
        matched_addr = AW'(cy)*COLS + AW'(cx);
        rlx  = lx;
        rly  = ly;
        is_empty = 1'b0;

        case (anim_mode)
        2'd0: begin
            is_empty = (board_rd_data == EMPTY);
        end

        2'd1: begin
            if (blink_mask[matched_addr] && !blink_on)
                is_empty = 1'b1;
            else
                is_empty = (board_rd_data == EMPTY);
        end

        2'd2: begin
            // fall: for each target row t in this column, compute its
            // displayed top and pick the one covering pix_y.  A block that
            // fell d rows starts at (t-d)*20 and ends at t*20, moving DOWN
            // at 5px/frame; displayed top = t*20 - (dist_px - fall_px).
            logic found;
            found  = 1'b0;
            is_empty = 1'b1;
            for (int t = 0; t < ROWS; t++) begin
                logic [3:0] d;
                logic [8:0] dist_px, top;
                d       = fall_dist[4*(cx*ROWS + t) +: 4];
                dist_px = d * 9'd20;
                top     = t*20 - ((fall_px < dist_px) ? (dist_px - fall_px) : 9'd0);
                if (pix_y >= top && pix_y < top + 9'd20) begin
                    matched_addr = AW'(t)*COLS + AW'(cx);
                    rly  = pix_y - top;
                    found = 1'b1;
                end
            end
            if (found) is_empty = (board_rd_data == EMPTY);
        end

        2'd3: begin
            // shift: for each target column tc, compute its displayed left
            // and pick the one covering pix_x.
            logic found;
            found  = 1'b0;
            is_empty = 1'b1;
            for (int tc = 0; tc < COLS; tc++) begin
                logic [3:0] d;
                logic [8:0] dist_px, left;
                d       = shift_dist[4*tc +: 4];
                dist_px = d * 9'd20;
                left    = (tc + d)*20 - ((shift_px < dist_px) ? shift_px : dist_px);
                if (pix_x >= left && pix_x < left + 9'd20) begin
                    matched_addr = AW'(cy)*COLS + AW'(tc);
                    rlx  = pix_x - left;
                    found = 1'b1;
                end
            end
            if (found) is_empty = (board_rd_data == EMPTY);
        end

        default: is_empty = 1'b0;
        endcase

        board_rd_addr = matched_addr;
    end

    // ---- pipeline ----
    // stage0 : latch resolved cell id + logo coords + empty flag
    //          (rom_addr is combinational from these registers)
    // stage1 : ROM registered read -> rom_data
    // stage2 : register empty flag + rom_data, emit colour
    logic [2:0]  id0;
    logic [4:0]  lx0, ly0;
    logic        empty0;
    logic        req0, req1, req2;
    logic [15:0] rom_d;
    logic        empty1;

    always_ff @(posedge clk) begin
        if (rst) begin
            req0   <= 1'b0;
            id0    <= EMPTY;
            lx0    <= 5'd0;
            ly0    <= 5'd0;
            empty0 <= 1'b1;
        end else begin
            req0   <= pix_req;
            id0    <= is_empty ? EMPTY : board_rd_data;
            lx0    <= rlx;
            ly0    <= rly;
            empty0 <= is_empty;
        end
    end

    // stage1 -> stage2
    always_ff @(posedge clk) begin
        if (rst) begin
            req1   <= 1'b0;
            req2   <= 1'b0;
            rom_d  <= 16'h0000;
            empty1 <= 1'b1;
            pix_color <= BG_COLOR;
            pix_valid <= 1'b0;
        end else begin
            req1   <= req0;
            rom_d  <= rom_data;
            empty1 <= empty0;

            req2      <= req1;
            pix_color <= empty1 ? BG_COLOR : rom_d;
            pix_valid <= req2;
        end
    end

    // rom address from stage0 registers (combinational)
    assign rom_addr = (id0 * 12'd400) + (ly0 * 12'd20) + lx0;
endmodule
