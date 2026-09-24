// erase_engine.sv
//
// Erases the flooded group after a 6-frame blink effect.  On `start`, the
// engine latches the erase mask (the flood-fill bitmap) and begins blinking:
// for 6 frames it toggles `blink_on` between 1 and 0 once per frame so the
// renderer can blank the affected blocks.  After BLINK_FRAMES frames it writes
// EMPTY into every cell in the mask (via the single-cell write port) and
// pulses `done`.
//
// `frame_tick` is a one-cycle pulse marking the start of a new frame; it is
// produced by the game FSM from the LCD frame timing.

module erase_engine #(
    parameter int CELLS = 192,
    parameter int AW    = 8,
    parameter int BLINK_FRAMES = 6
)(
    input  logic        clk,
    input  logic        rst,

    input  logic        start,
    input  logic [CELLS-1:0] erase_mask,

    input  logic        frame_tick,    // 1-cycle pulse per frame

    output logic        done,
    output logic        busy,

    // blink indicator for the renderer (1 = show block, 0 = blank)
    output logic        blink_on,

    // board write port (single cell)
    output logic        wr_en,
    output logic [AW-1:0] wr_addr,
    output logic [2:0]  wr_data
);
    localparam logic [2:0] EMPTY = 3'b111;

    typedef enum logic [1:0] {S_IDLE, S_BLINK, S_COMMIT, S_DONE} state_t;
    state_t state;

    logic [CELLS-1:0] mask;
    logic [2:0]       frame_cnt;
    logic [AW-1:0]    idx;         // cell index 0..CELLS-1
    logic             blink;

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            mask      <= '0;
            frame_cnt <= 3'd0;
            idx       <= '0;
            blink     <= 1'b1;
            wr_en     <= 1'b0;
            done      <= 1'b0;
        end else begin
            wr_en <= 1'b0;
            done  <= 1'b0;

            case (state)
            S_IDLE: begin
                if (start) begin
                    mask      <= erase_mask;
                    frame_cnt <= 3'd0;
                    blink     <= 1'b1;
                    state     <= S_BLINK;
                end
            end

            S_BLINK: begin
                if (frame_tick) begin
                    blink <= ~blink;
                    if (frame_cnt == 3'(BLINK_FRAMES-1)) begin
                        idx   <= '0;
                        state <= S_COMMIT;
                    end else begin
                        frame_cnt <= frame_cnt + 3'd1;
                    end
                end
            end

            S_COMMIT: begin
                // write EMPTY into the next masked cell, skipping non-masked
                // cells (one cell per cycle).
                if (mask[idx]) begin
                    wr_en   <= 1'b1;
                    wr_addr <= idx;
                    wr_data <= EMPTY;
                end

                if (idx == AW'(CELLS-1)) begin
                    done  <= 1'b1;
                    state <= S_DONE;
                end else begin
                    idx <= idx + 8'd1;
                end
            end

            S_DONE: begin
                state <= S_IDLE;
            end
            endcase
        end
    end

    assign blink_on = blink;
    assign busy = (state != S_IDLE);
endmodule
