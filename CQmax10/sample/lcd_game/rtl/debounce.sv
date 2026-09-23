// debounce.sv
// Hold-time debouncer for the single push button (sw1, PIN_62).
// ASSUMPTION: the switch is pulled up externally, idle = 1, pressed = 0.
// btn_level is the debounced active-high level: 1 = currently pressed.

module debounce #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int DEBOUNCE_MS = 10
)(
    input  logic clk,
    input  logic rst,
    input  logic btn_in_n,      // raw pin, active low
    output logic btn_level      // debounced, active high (1 = pressed)
);
    localparam int LIMIT = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam int CW    = $clog2(LIMIT + 1);

    // two-flop synchronizer for the asynchronous pin
    logic sync0, sync1;
    always_ff @(posedge clk) begin
        if (rst) begin
            sync0 <= 1'b1;
            sync1 <= 1'b1;
        end else begin
            sync0 <= btn_in_n;
            sync1 <= sync0;
        end
    end

    logic raw, raw_d;
    logic [CW-1:0] cnt;
    logic level;

    assign raw = ~sync1;        // active high internally

    always_ff @(posedge clk) begin
        if (rst) begin
            raw_d <= 1'b0;
            cnt   <= '0;
            level <= 1'b0;
        end else begin
            raw_d <= raw;
            if (raw != raw_d) begin
                cnt <= '0;                     // input moved, restart the timer
            end else if (cnt != LIMIT[CW-1:0]) begin
                cnt <= cnt + 1'b1;
            end else begin
                level <= raw;                  // stable long enough, accept it
            end
        end
    end

    assign btn_level = level;
endmodule
