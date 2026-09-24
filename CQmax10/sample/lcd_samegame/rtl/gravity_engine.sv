// gravity_engine.sv
//
// Compresses each column independently after erasure: all non-EMPTY cells in a
// column drop to the bottom, preserving their vertical order, and the vacated
// top cells become EMPTY.
//
// The board is written cell-by-cell through the board_memory single-cell write
// port.  The engine iterates over the 16 columns; for each column it reads the
// packed column word (36 bit = 12 rows x 3 bit) through the column read port,
// builds the compacted word, and writes the changed rows back.
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
    output logic [CELLS*4-1:0] fall_dist
);
    localparam logic [2:0] EMPTY = 3'b111;

    typedef enum logic [1:0] {S_IDLE, S_READ, S_WRITE, S_DONE} state_t;
    state_t state;

    logic [3:0]  col;          // current column 0..COLS-1
    logic [3:0]  row;          // current write row 0..ROWS-1
    logic [35:0] compacted;    // latched rebuilt column
    logic [35:0] compacted_c;  // combinational rebuilt column
    logic [ROWS*4-1:0] fd_c;   // fall distances for current column (combinational)

    assign rd_col = col;

    // build the compacted column + fall distances combinationally from col_data
    logic [2:0] cell_val;
    always_comb begin
        logic [3:0] k;
        compacted_c = {12{EMPTY}};
        fd_c        = '0;
        k = 4'd0;
        // iterate bottom-to-top so the bottom-most non-empty cell keeps the
        // bottom row (preserves vertical order while everything falls down)
        for (int r = ROWS-1; r >= 0; r--) begin
            cell_val = col_data[3*r +: 3];
            if (cell_val != EMPTY) begin
                compacted_c[3*(ROWS-1-k) +: 3] = cell_val;
                // this cell falls from row r to row (ROWS-1-k)
                fd_c[4*(ROWS-1-k) +: 4] = 4'((ROWS-1-k) - r);
                k = k + 4'd1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            col       <= 4'd0;
            row       <= 4'd0;
            wr_en     <= 1'b0;
            done      <= 1'b0;
        end else begin
            wr_en <= 1'b0;
            done  <= 1'b0;

            case (state)
            S_IDLE: begin
                if (start) begin
                    col   <= 4'd0;
                    state <= S_READ;
                end
            end

            // latch the compacted column + fall distances, then start writing
            S_READ: begin
                compacted <= compacted_c;
                fall_dist[4*(col*ROWS) +: 4*ROWS] <= fd_c;
                row       <= 4'd0;
                state     <= S_WRITE;
            end

            S_WRITE: begin
                wr_en   <= 1'b1;
                wr_addr <= AW'(row)*COLS + AW'(col);
                wr_data <= compacted[3*row +: 3];

                if (row == 4'(ROWS-1)) begin
                    if (col == 4'(COLS-1)) begin
                        done  <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        col   <= col + 4'd1;
                        state <= S_READ;
                    end
                end else begin
                    row <= row + 4'd1;
                end
            end

            S_DONE: begin
                state <= S_IDLE;
            end
            endcase
        end
    end

    assign busy = (state != S_IDLE);
endmodule
