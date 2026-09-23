// frame_seq.sv
//
// Issues one CMD_FRAME request to the LCD controller every FRAME_PERIOD_MS,
// once the controller reports that it is ready (panel init finished).
// `req_valid` is held until the controller acknowledges it with `req_ready`.
//
// TIMING MODEL
// The period is measured from the START of one frame to the start of the next,
// so the timer runs IN PARALLEL with the transfer:
//
//     visible frame period = max(FRAME_PERIOD_MS, transfer time)
//
// The timer saturates at FRAME_PERIOD_MS while the controller is still busy,
// and the request goes out on the first cycle the controller is ready again.
// That matters because at the ILI9341 datasheet clock a 320x240 frame transfer
// (~140 ms) is close to the default FRAME_PERIOD_MS (150 ms): if the timer
// instead started only AFTER the transfer (a serial wait), the period would be
// `FRAME_PERIOD_MS + transfer` and the frame rate would drop for free. Set
// FRAME_PERIOD_MS just above the transfer time (see README section 5).

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
    // ((CLK/1000)/MS_SCALE) can be 0 if MS_SCALE is larger than CLK/1000 (a
    // simulation may do this to shrink the panel delays). PERIOD would then be
    // 0, and the comparison below of `timer == PERIOD-1` would use 0-1 =
    // 0xFFFFFFFF, which never matches -> the FSM would stop issuing frames and
    // the testbench would hang with no error. Clamp to at least one cycle.
    localparam int MS_CYCLES = (CLK_FREQ_HZ / 1000) / MS_SCALE;
    localparam int MS_CYCLES_SAFE = (MS_CYCLES > 0) ? MS_CYCLES : 1;
    localparam int PERIOD = MS_CYCLES_SAFE * FRAME_PERIOD_MS;

    // one before the period, so the timer can saturate there while waiting for
    // `ready` and still fire on the next cycle the controller is free
    localparam logic [31:0] PERIOD_LAST = 32'(PERIOD) - 32'd1;

    typedef enum logic [1:0] {F_WAIT_INIT, F_RUN, F_REQ} state_t;
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
                        state <= F_RUN;
                    end
                end

                // free-running period timer; issues as soon as BOTH the period
                // has elapsed and the controller can take a new frame
                F_RUN: begin
                    if (timer == PERIOD_LAST) begin
                        if (ready) begin
                            timer     <= '0;
                            req_valid <= 1'b1;
                            state     <= F_REQ;
                        end
                        // else hold the timer saturated and re-check next clk
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                F_REQ: begin
                    if (ready) begin
                        req_valid <= 1'b0;
                        timer     <= '0;
                        state     <= F_RUN;
                    end
                end

                default: state <= F_WAIT_INIT;
            endcase
        end
    end

    assign frame_active = (state == F_REQ);
endmodule
