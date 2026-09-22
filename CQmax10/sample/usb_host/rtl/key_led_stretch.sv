`default_nettype none

// ---------------------------------------------------------------------------
// key_led_stretch
//
// Turns USB keyboard activity into human-visible LED indications.
//
// The USB HID host core runs on a 12 MHz clock, so the key state arrives
// asynchronously to the 50 MHz system clock. This block lives entirely in the
// system clock domain and recovers that asynchronous level with a 2-FF
// synchronizer followed by a short stability filter. The level is held for
// milliseconds by the HID core, so the filter only rejects glitches caused by
// metastability on the very first sampler; it does not delay real presses.
//
//   key_down_async - level from the USB clock domain, high while any key is held
//
//   led_key        - high for as long as a key is held
//   led_event      - one stretched pulse per newly received key code, so even a
//                    very short key tap stays visible on the LED
// ---------------------------------------------------------------------------
module key_led_stretch #(
    parameter int CLK_HZ  = 50_000_000,
    parameter int HOLD_MS = 120
) (
    input  wire logic clk,
    input  wire logic rst_n,

    input  wire logic key_down_async,

    output logic      led_key,
    output logic      led_event
);

    // Pulse width used to make a single key event visible on an LED.
    localparam int HOLD_CYCLES = (CLK_HZ / 1000) * HOLD_MS;

    // Time the asynchronous level must hold steady before it is accepted.
    localparam int SETTLE_CYCLES = (CLK_HZ >= 100_000) ? (CLK_HZ / 100_000) : 0;

    logic [1:0]  key_sync;
    logic        key_stable;
    logic        key_stable_d;
    logic [15:0] settle_cnt;
    logic [31:0] hold_cnt;

    wire key_new_press = key_stable & ~key_stable_d;
    wire hold_busy     = (hold_cnt != 32'd0);

    // 2-FF synchronizer plus glitch filter.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync   <= 2'b00;
            key_stable <= 1'b0;
            settle_cnt <= 16'd0;
        end else begin
            key_sync <= {key_sync[0], key_down_async};

            if (key_sync[1] == key_stable) begin
                settle_cnt <= 16'd0;
            end else if (settle_cnt >= SETTLE_CYCLES) begin
                key_stable <= key_sync[1];
                settle_cnt <= 16'd0;
            end else begin
                settle_cnt <= settle_cnt + 16'd1;
            end
        end
    end

    // Rising-edge detect plus hold timer for the "key code received" LED.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_stable_d <= 1'b0;
            hold_cnt     <= 32'd0;
        end else begin
            key_stable_d <= key_stable;

            if (key_new_press) begin
                hold_cnt <= HOLD_CYCLES;
            end else if (hold_busy) begin
                hold_cnt <= hold_cnt - 32'd1;
            end
        end
    end

    assign led_key   = key_stable;
    assign led_event = key_new_press | hold_busy;

endmodule

`default_nettype wire
