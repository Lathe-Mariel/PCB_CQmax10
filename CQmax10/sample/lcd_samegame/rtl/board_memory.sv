// board_memory.sv
//
// The 16x12 game board.  Each cell holds a 3-bit block id (0..4 = Logo0..4,
// 7 = Empty).  The board is stored in plain registers (192 x 3 bit) so every
// read is combinational: the renderer, the flood-fill engine and the
// gravity/shift engines can all read arbitrary cells in the same clock cycle
// with zero latency and no port contention.
//
// Ports:
//   * single-cell write   (wr_en / wr_addr / wr_data)
//   * bulk clear -> EMPTY (clr_start / clr_busy)
//   * cell read A (renderer)      : rd_addr_a  -> rd_data_a
//   * cell read B (flood fill)    : rd_addr_b  -> rd_data_b
//   * column read  (gravity/shift): rd_col     -> col_data[35:0]
//
// Cell address = cy*COLS + cx.  A column word packs rows 0..ROWS-1 LSB-first:
//   col_data[3*r +: 3] = cell (cx = col, cy = r).

module board_memory #(
    parameter int COLS = 16,
    parameter int ROWS = 12,
    parameter int AW   = 8               // ceil(log2(COLS*ROWS))
)(
    input  logic        clk,
    input  logic        rst,

    // ---- single-cell write ----
    input  logic        wr_en,
    input  logic [AW-1:0] wr_addr,
    input  logic [2:0]  wr_data,

    // ---- bulk clear ----
    input  logic        clr_start,
    output logic        clr_busy,

    // ---- cell read A (renderer) ----
    input  logic [AW-1:0] rd_addr_a,
    output logic [2:0]  rd_data_a,

    // ---- cell read B (flood fill) ----
    input  logic [AW-1:0] rd_addr_b,
    output logic [2:0]  rd_data_b,

    // ---- column read (gravity / column shift) ----
    input  logic [3:0]  rd_col,
    output logic [35:0] col_data
);
    localparam int DEPTH = COLS * ROWS;          // 192
    localparam logic [2:0] EMPTY = 3'b111;

    logic [2:0] cells [0:DEPTH-1];

    logic [AW-1:0] clr_addr;
    logic          clearing;

    // ---- write / clear (single write port) ----
    always_ff @(posedge clk) begin
        if (wr_en) begin
            cells[wr_addr] <= wr_data;
        end else if (clearing) begin
            cells[clr_addr] <= EMPTY;
        end
    end

    // ---- combinational reads ----
    assign rd_data_a = cells[rd_addr_a];
    assign rd_data_b = cells[rd_addr_b];

    always_comb begin
        col_data = '0;
        for (int r = 0; r < ROWS; r++)
            col_data[3*r +: 3] = cells[rd_col + r*COLS];
    end

    // ---- clear FSM (auto-clear after reset) ----
    always_ff @(posedge clk) begin
        if (rst) begin
            clearing <= 1'b1;
            clr_addr <= '0;
        end else if (clr_start) begin
            clearing <= 1'b1;
            clr_addr <= '0;
        end else if (clearing) begin
            if (clr_addr == AW'(DEPTH-1))
                clearing <= 1'b0;
            else
                clr_addr <= clr_addr + 1'b1;
        end
    end

    assign clr_busy = clearing;
endmodule
