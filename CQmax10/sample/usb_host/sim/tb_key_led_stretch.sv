`timescale 1ns/1ps
`default_nettype none

// Smoke test for key_led_stretch.
//
// Uses a small CLK_HZ so the hold/settle timers are short enough to simulate.
// Verified behaviour:
//   1. led_key follows an asynchronous key level after 2-FF sync + filter.
//   2. led_event pulses on a new key press and stays high for HOLD_MS.
//   3. A very short key tap still produces a visible stretched pulse.
//   4. Releasing the key does not produce a second event pulse.
module tb_key_led_stretch;

    localparam int CLK_HZ  = 100_000;   // 100 kHz -> 10 us period
    localparam int HOLD_MS = 1;         // 1000 cycles hold
    localparam int HOLD_CYCLES = (CLK_HZ / 1000) * HOLD_MS;

    logic clk;
    logic rst_n;
    logic key_down_async;
    logic led_key;
    logic led_event;

    int errors = 0;

    key_led_stretch #(
        .CLK_HZ  (CLK_HZ),
        .HOLD_MS (HOLD_MS)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_down_async (key_down_async),
        .led_key        (led_key),
        .led_event      (led_event)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check(input logic cond, input string msg);
        begin
            if (!cond) begin
                $display("FAIL: %s", msg);
                errors++;
            end
        end
    endtask

    initial begin
        rst_n          = 1'b0;
        key_down_async = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        check(!led_key && !led_event, "idle after reset");

        // --- Press: led_key rises, led_event pulses ---
        key_down_async = 1'b1;
        repeat (8) @(posedge clk);
        check(led_key == 1'b1,   "led_key high while a key is held");
        check(led_event == 1'b1, "led_event high after a new key press");

        // Hold should outlive a held key.
        repeat (HOLD_CYCLES + 100) @(posedge clk);
        check(led_key == 1'b1,   "led_key stays high during a long hold");
        check(led_event == 1'b0, "led_event expires while the key is still held");

        // --- Release: no new event pulse, led_key falls ---
        key_down_async = 1'b0;
        repeat (8) @(posedge clk);
        check(led_key == 1'b0,   "led_key falls after release");
        check(led_event == 1'b0, "release does not generate a second event");

        // --- Very short tap still lights the event LED ---
        key_down_async = 1'b1;
        repeat (8) @(posedge clk);
        key_down_async = 1'b0;
        repeat (40) @(posedge clk);      // well past the sync latency
        check(led_event == 1'b1, "short tap still produces a stretched pulse");
        check(led_key == 1'b0,   "led_key reflects the released key");

        repeat (HOLD_CYCLES + 100) @(posedge clk);
        check(led_event == 1'b0, "stretched pulse expires");

        if (errors == 0) $display("tb_key_led_stretch: PASS");
        else             $display("tb_key_led_stretch: FAIL (%0d errors)", errors);

        $finish;
    end

endmodule

`default_nettype wire
