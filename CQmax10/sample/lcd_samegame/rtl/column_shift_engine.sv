// column_shift_engine.sv
//
// After gravity, empty columns are removed by shifting the non-empty columns
// to the left.  Per the specification:
//
//   input  : A B Empty C D Empty
//   output : A B C D Empty Empty
//
// Implementation is two-phase:
//
//   Phase A (SCAN): read every column through column read port B, latch the
//     column word into a register array, and compute
//       column_empty[c] = 1 if column c has no non-EMPTY cell
//       target_col[c]  = number of non-empty columns strictly left of c
//     (the specification's "new_col" running counter).
//
//   Phase B (REWRITE): clear the whole board to EMPTY (cell-by-cell through
//     the single-cell write port), then write every non-empty column back into
//     its target column.  Clearing first guarantees that vacated columns and
//     the columns on the right become EMPTY regardless of overlap.

module column_shift_engine #(
    parameter int COLS = 16,
    parameter int ROWS = 12,
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

    // board read port B (column word)
    output logic [3:0]  rd_col,
    input  logic [35:0] col_data,

    // empty-column bitmap (spec: column_empty[15:0])
    output logic [COLS-1:0] column_empty,

    // shift distance per target column (in cells), indexed target = column
    output logic [COLS*4-1:0] shift_dist
);
    localparam logic [2:0] EMPTY = 3'b111;

    typedef enum logic [2:0] {
        S_IDLE, S_SCAN, S_SCANW, S_CLEAR, S_WRITE, S_DONE
    } state_t;
    state_t state;

    logic [3:0]  scan_col;     // column index for scan / write phases
    logic [3:0]  dst_cnt;      // number of non-empty columns seen so far
    logic [3:0]  row;          // write row
    logic [35:0] cols [0:COLS-1];      // latched column words
    logic [3:0]  target [0:COLS-1];    // target column per source column
    logic [COLS-1:0] empty_map;

    wire col_is_empty =
        (col_data[2:0]   == EMPTY) && (col_data[5:3]   == EMPTY) &&
        (col_data[8:6]   == EMPTY) && (col_data[11:9]  == EMPTY) &&
        (col_data[14:12] == EMPTY) && (col_data[17:15] == EMPTY) &&
        (col_data[20:18] == EMPTY) && (col_data[23:21] == EMPTY) &&
        (col_data[26:24] == EMPTY) && (col_data[29:27] == EMPTY) &&
        (col_data[32:30] == EMPTY) && (col_data[35:33] == EMPTY);

    assign rd_col = scan_col;

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            scan_col  <= 4'd0;
            dst_cnt   <= 4'd0;
            row       <= 4'd0;
            empty_map <= '0;
            shift_dist<= '0;
            wr_en     <= 1'b0;
            done      <= 1'b0;
        end else begin
            wr_en <= 1'b0;
            done  <= 1'b0;

            case (state)
            S_IDLE: begin
                if (start) begin
                    scan_col  <= 4'd0;
                    dst_cnt   <= 4'd0;
                    empty_map <= '0;
                    shift_dist <= '0;
                    state     <= S_SCAN;
                end
            end

            // issue the read; wait one cycle for col_data
            S_SCAN: begin
                state <= S_SCANW;
            end

            S_SCANW: begin
                cols[scan_col] <= col_data;
                target[scan_col] <= dst_cnt;
                empty_map[scan_col] <= col_is_empty;
                if (!col_is_empty) begin
                    // this column moves from scan_col to dst_cnt: distance
                    // scan_col - dst_cnt, keyed by its TARGET column.
                    shift_dist[4*dst_cnt +: 4] <= 4'(scan_col - dst_cnt);
                    dst_cnt <= dst_cnt + 4'd1;
                end

                if (scan_col == 4'(COLS-1)) begin
                    // phase B: clear all cells first
                    scan_col <= 4'd0;
                    row      <= 4'd0;
                    state    <= S_CLEAR;
                end else begin
                    scan_col <= scan_col + 4'd1;
                    state    <= S_SCAN;
                end
            end

            // clear the whole board cell by cell
            S_CLEAR: begin
                wr_en   <= 1'b1;
                wr_addr <= AW'(row)*COLS + AW'(scan_col);
                wr_data <= EMPTY;

                if (scan_col == 4'(COLS-1)) begin
                    scan_col <= 4'd0;
                    if (row == 4'(ROWS-1)) begin
                        // done clearing; start rewriting non-empty columns
                        scan_col <= 4'd0;
                        row      <= 4'd0;
                        state    <= S_WRITE;
                    end else begin
                        row <= row + 4'd1;
                    end
                end else begin
                    scan_col <= scan_col + 4'd1;
                end
            end

            // rewrite non-empty columns into their target position
            S_WRITE: begin
                if (empty_map[scan_col]) begin
                    // skip empty columns
                    if (scan_col == 4'(COLS-1)) begin
                        done  <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        scan_col <= scan_col + 4'd1;
                    end
                end else begin
                    wr_en   <= 1'b1;
                    wr_addr <= AW'(row)*COLS + AW'(target[scan_col]);
                    wr_data <= cols[scan_col][3*row +: 3];

                    if (row == 4'(ROWS-1)) begin
                        row <= 4'd0;
                        if (scan_col == 4'(COLS-1)) begin
                            done  <= 1'b1;
                            state <= S_DONE;
                        end else begin
                            scan_col <= scan_col + 4'd1;
                        end
                    end else begin
                        row <= row + 4'd1;
                    end
                end
            end

            S_DONE: begin
                state <= S_IDLE;
            end
            endcase
        end
    end

    assign column_empty = empty_map;
    assign busy = (state != S_IDLE);
endmodule
