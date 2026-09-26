// gravity_engine.sv
//
// Compresses each column independently after erasure: all non-EMPTY cells in a
// column drop to the bottom, preserving their vertical order, and the vacated
// top cells become EMPTY.
//
// The board is written cell-by-cell through the board_memory single-cell write
// port.  To keep the logic small, compaction is done *sequentially* (one cell
// per cycle) instead of with a wide combinational priority encoder:
//
//   For each column:
//     1. clear all ROWS cells to EMPTY (sequential)
//     2. scan rows bottom-to-top; for each non-EMPTY cell write it to the
//        current destination row (starting at the bottom) and record its fall
//        distance (dst - src), then move the destination up one row.
//
// It also emits `fall_dist`: for each *target* cell (col, dst_row), the number
// of rows it fell (0 for cells that do not move).  The renderer uses this to
// draw the falling animation.
//
// Row 0 is the TOP row, row 11 is the BOTTOM row.  "Falling" moves toward
// higher row indices.

module gravity_engine #(
    parameter int COLS = 16,
    parameter int ROWS = 12,
    parameter int CELLS = COLS * ROWS,      // 192
    parameter int AW   = 8
)(
    input  logic        clk,
    input  logic        rst,

    input  logic        start,
    output logic        done,
    output logic        busy,

    // board write port (single cell)
    output logic        wr_en,
    output logic [AW-1:0] wr_addr,
    output logic [2:0]  wr_data,

    // board column read
    output logic [3:0]  rd_col,
    input  logic [35:0] col_data,

    // fall distance per target cell (in rows), indexed target = col*ROWS+row
    output logic [CELLS*4-1:0] fall_dist,

    // ------------------------------------------------------------------
    // LONGEST DROP THIS PASS, in rows.
    //
    // WHY THIS PORT EXISTS
    // --------------------
    // The fall animation used to be timed by the WORST-CASE board height
    // (ROWS*20 px), so the FSM waited ~48 frames (8 s at 166 ms/frame) after EVERY
    // erase, no matter how far anything actually dropped.  The renderer clamps the
    // offset with min(fall_px, fall_dist*20), so the picture finished moving in a
    // few frames and then the cursor sat frozen on a finished board for the rest
    // of the 8 seconds.  Reporting the real maximum lets the FSM stop when the
    // motion is over.
    //
    // It is a plain running maximum, accumulated in the SAME state that already
    // computes the per-cell distance, so it costs one comparator and no extra
    // pass over the board.
    // ------------------------------------------------------------------
    output logic [3:0]  max_dist
);
    localparam logic [2:0] EMPTY = 3'b111;

    typedef enum logic [2:0] {
        S_IDLE, S_LATCH, S_CLEAR, S_SCAN, S_NEXT, S_DONE
    } state_t;
    state_t state;

    logic [3:0]  col;          // current column 0..COLS-1
    logic [3:0]  row;          // current row 0..ROWS-1 (clear / scan pointer)
    logic [3:0]  dst;          // destination row (moves up as cells are placed)
    logic [35:0] col_latch;    // original column word (captured before clear)
    logic [3:0]  max_r;        // running maximum of dst - row over this pass

    assign rd_col = col;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            col   <= 4'd0;
            row   <= 4'd0;
            dst   <= 4'd0;
            wr_en <= 1'b0;
            done  <= 1'b0;
            max_r <= 4'd0;
        end else begin
            wr_en <= 1'b0;
            done  <= 1'b0;

            case (state)
            S_IDLE: begin
                if (start) begin
                    col   <= 4'd0;
                    max_r <= 4'd0;          // reset the running maximum per pass
                    state <= S_LATCH;
                end
            end

            // capture the column word before we overwrite the board
            S_LATCH: begin
                col_latch <= col_data;
                row       <= 4'd0;
                dst       <= 4'(ROWS-1);
                state     <= S_CLEAR;
            end

            // clear the whole column to EMPTY
            S_CLEAR: begin
                wr_en   <= 1'b1;
                wr_addr <= AW'(row)*COLS + AW'(col);
                wr_data <= EMPTY;
                if (row == 4'(ROWS-1)) begin
                    row   <= 4'(ROWS-1);   // scan bottom-to-top
                    state <= S_SCAN;
                end else begin
                    row <= row + 4'd1;
                end
            end

            // scan rows bottom-to-top; write non-EMPTY cells into `dst`
            S_SCAN: begin
                if (col_latch[3*row +: 3] != EMPTY) begin
                    wr_en   <= 1'b1;
                    wr_addr <= AW'(dst)*COLS + AW'(col);
                    wr_data <= col_latch[3*row +: 3];
                    fall_dist[4*(col*ROWS + dst) +: 4] <= 4'(dst - row);
                    // track the longest drop seen so far (this cell's distance
                    // is `dst - row`, and `dst` only ever moves up)
                    if (4'(dst - row) > max_r)
                        max_r <= 4'(dst - row);
                    if (dst != 4'd0)
                        dst <= dst - 4'd1;
                end

                if (row == 4'd0) begin
                    state <= S_NEXT;
                end else begin
                    row <= row - 4'd1;
                end
            end

            S_NEXT: begin
                if (col == 4'(COLS-1)) begin
                    done  <= 1'b1;
                    state <= S_DONE;
                end else begin
                    col   <= col + 4'd1;
                    state <= S_LATCH;
                end
            end

            S_DONE: begin
                state <= S_IDLE;
            end
            endcase
        end
    end

    assign busy     = (state != S_IDLE);
    assign max_dist = max_r;
endmodule
