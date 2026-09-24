// floodfill_engine.sv
//
// FIFO-based flood fill (no recursion).  On `start`, the engine finds every
// cell connected (4-neighbour: up/down/left/right) to (start_x, start_y) that
// holds the same block id, and reports the group size on `count` together with
// a one-cycle `done` pulse.
//
// A 256-entry FIFO (192 is the absolute maximum for a 16x12 board) holds
// pending cells.  Each popped cell is expanded one neighbour per cycle so the
// board read stays a single combinational access (no wide fanout).
//
// The `visited` map is a 192-bit bitmask (one bit per cell).  It doubles as the
// erase bitmap: the same mask is exposed via `mask` so the erase engine can
// blink / clear exactly the flooded cells.  `visited` is cleared on `start`.
//
// `count` is the number of cells in the group (>= 2 means erasable).

module floodfill_engine #(
    parameter int COLS = 16,
    parameter int ROWS = 12,
    parameter int CELLS = COLS * ROWS,      // 192
    parameter int AW    = 8,                // cell address width
    parameter int FIFO_DEPTH = 256
)(
    input  logic        clk,
    input  logic        rst,

    input  logic        start,
    input  logic [3:0]  start_x,            // 0..COLS-1
    input  logic [3:0]  start_y,            // 0..ROWS-1

    // board read port B (combinational)
    output logic [AW-1:0] board_rd_addr,
    input  logic [2:0]    board_rd_data,

    output logic        done,
    output logic [7:0]  count,              // group size
    output logic [CELLS-1:0] mask,          // visited bitmap (erase mask)
    output logic        target_empty,       // 1 if the seed cell was EMPTY

    output logic        busy
);
    localparam logic [2:0] EMPTY = 3'b111;
    localparam int FIW = 8;                 // FIFO index width (256 entries)

    typedef enum logic [2:0] {
        S_IDLE, S_SEED, S_POP, S_PROBE0, S_PROBE1, S_PROBE2, S_PROBE3, S_DONE
    } state_t;
    state_t state;

    // ---- FIFO ----
    logic [AW-1:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [FIW-1:0] wr_ptr, rd_ptr;
    wire fifo_empty = (wr_ptr == rd_ptr);

    // ---- visited bitmap & group counter ----
    logic [CELLS-1:0] visited;
    logic [7:0]       group_cnt;
    logic [2:0]       target_id;

    // ---- popped cell ----
    logic [AW-1:0] pop_addr;
    logic [3:0]    pop_x, pop_y;

    logic        seed_empty;

    // ---- probe neighbour ----
    logic [1:0]  phase;
    logic [3:0]  nx, ny;
    logic        in_range;
    logic [AW-1:0] naddr;
    logic        should_push;

    assign pop_addr = fifo_mem[rd_ptr];
    assign pop_x    = pop_addr[3:0];
    assign pop_y    = pop_addr[7:4];

    always_comb begin
        nx = pop_x;
        ny = pop_y;
        in_range = 1'b0;
        case (phase)
        2'd0: begin ny = pop_y - 4'd1; in_range = (pop_y != 4'd0);        end
        2'd1: begin ny = pop_y + 4'd1; in_range = (pop_y != 4'(ROWS-1)); end
        2'd2: begin nx = pop_x - 4'd1; in_range = (pop_x != 4'd0);        end
        2'd3: begin nx = pop_x + 4'd1; in_range = (pop_x != 4'(COLS-1)); end
        default: ;
        endcase
        naddr = AW'(ny) * COLS + AW'(nx);
        // push if in range, not visited, and matches the group id
        should_push = in_range && !visited[naddr] && (board_rd_data == target_id);
    end

    // In S_IDLE the probe address is meaningless; point the read port at the
    // start cell so target_id can be latched from board[start].
    assign board_rd_addr = (state == S_IDLE) ? (AW'(start_y)*COLS + AW'(start_x)) : naddr;

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            visited   <= '0;
            group_cnt <= 8'd0;
            target_id <= 3'd0;
            seed_empty<= 1'b0;
            wr_ptr    <= '0;
            rd_ptr    <= '0;
            done      <= 1'b0;
            phase     <= 2'd0;
        end else begin
            done <= 1'b0;

            case (state)
            S_IDLE: begin
                if (start) begin
                    visited   <= '0;
                    group_cnt <= 8'd0;
                    target_id <= board_rd_data;   // board[start]
                    seed_empty<= (board_rd_data == EMPTY);
                    // seed FIFO with the start cell
                    fifo_mem[0] <= AW'(start_y)*COLS + AW'(start_x);
                    wr_ptr      <= 8'd1;
                    rd_ptr      <= 8'd0;
                    phase       <= 2'd0;
                    state       <= S_SEED;
                end
            end

            // wait one cycle so rd_ptr-based pop_addr is stable
            S_SEED: begin
                if (seed_empty) begin
                    // seed cell is EMPTY: group of zero (nothing to erase)
                    done  <= 1'b1;
                    state <= S_DONE;
                end else begin
                    state <= S_POP;
                end
            end

            S_POP: begin
                if (fifo_empty) begin
                    done  <= 1'b1;
                    state <= S_DONE;
                end else begin
                    // mark the popped cell visited (also counts it)
                    visited[pop_addr] <= 1'b1;
                    group_cnt <= group_cnt + 8'd1;
                    phase <= 2'd0;
                    state <= S_PROBE0;
                end
            end

            S_PROBE0, S_PROBE1, S_PROBE2, S_PROBE3: begin
                if (should_push) begin
                    fifo_mem[wr_ptr] <= naddr;
                    wr_ptr           <= wr_ptr + 8'd1;
                    visited[naddr]   <= 1'b1;   // mark visited on push (BFS-style)
                end
                // advance: next neighbour, or pop the next cell
                if (phase == 2'd3) begin
                    rd_ptr <= rd_ptr + 8'd1;
                    state  <= S_POP;
                end else begin
                    phase <= phase + 1'b1;
                end
            end

            S_DONE: begin
                state <= S_IDLE;
            end
            endcase
        end
    end

    assign mask  = visited;
    assign count = group_cnt;
    assign target_empty = seed_empty;
    assign busy  = (state != S_IDLE);
endmodule
