// frame_seq.sv
//
// Issues one CMD_FRAME request to the LCD controller every FRAME_PERIOD_MS,
// once the controller reports that it is ready (panel init finished).
// `req_valid` is held until the controller acknowledges it with `req_ready`.

module frame_seq #(
    parameter int CLK_FREQ_HZ     = 50_000_000,
    parameter int FRAME_PERIOD_MS = 250,
    parameter int MS_SCALE        = 1        // 1 in hardware; divide delays for simulation
)(
    input  logic clk,
    input  logic rst,

    input  logic ready,          // LCD controller accepting requests
    output logic req_valid,
    output logic [1:0] req_cmd,  // always 2'b10 = CMD_FRAME

    output logic frame_active    // 1 while a frame request is outstanding
);
    localparam int PERIOD = ((CLK_FREQ_HZ / 1000) / MS_SCALE) * FRAME_PERIOD_MS;

    typedef enum logic [1:0] {F_WAIT_INIT, F_WAIT_PERIOD, F_REQ} state_t;
    state_t state;

    logic [31:0] timer;

    assign req_cmd = 2'b10;      // CMD_FRAME

    always_ff @(posedge clk) begin
        if (rst) begin
            state    <= F_WAIT_INIT;
            timer    <= '0;
            req_valid<= 1'b0;
        end else begin
            case (state)
                F_WAIT_INIT: begin
                    if (ready) begin
                        timer <= '0;
                        state <= F_WAIT_PERIOD;
                    end
                end

                F_WAIT_PERIOD: begin
                    if (timer == 32'(PERIOD) - 1) begin
                        timer     <= '0;
                        req_valid <= 1'b1;
                        state     <= F_REQ;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                F_REQ: begin
                    if (ready) begin
                        req_valid <= 1'b0;
                        state     <= F_WAIT_PERIOD;
                    end
                end

                default: state <= F_WAIT_INIT;
            endcase
        end
    end

    assign frame_active = (state == F_REQ);
endmodule
