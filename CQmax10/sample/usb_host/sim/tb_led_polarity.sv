`timescale 1ns/1ps
`default_nettype none

// Verifies the board LED polarity convention and the key-activity mapping.
//
// The CQ-MAX10-A board LEDs are wired
//     +3V3 -> series R -> LED anode -> LED cathode -> FPGA pin
// so the FPGA pin SINK current: the pin must be driven LOW to light the LED.
//
// This testbench models that external circuit (a pull-up to +3V3 through the LED
// and a series resistor) and asserts that:
//   1. a "key held" condition lights the LED,
//   2. no key held leaves the LED dark,
//   3. the LED is dark while the keyboard is absent,
//   4. on reset the LED is dark,
//   5. an undriven (tri-stated) or high pin does NOT light the LED.
module tb_led_polarity;

    localparam int CLK_HZ  = 100_000;
    localparam int HOLD_MS = 1;

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

    // ---- model of the board LED hardware -------------------------------
    // Node is pulled up to +3V3 through R + LED. The FPGA pin sinks current.
    // `led_on` is true when current can flow, i.e. the pin is driven LOW.
    // A tri-stated pin leaves the LED dark because the LED's forward drop plus
    // the resistor still limits current to a negligible level.
    function automatic logic led_is_on(input logic pin_driven_low, input logic pin_oe);
        led_is_on = pin_oe && !pin_driven_low;
    endfunction

    // Reproduce the output inversion applied at the top-level pins.
    logic led1_on;
    assign led1_on = led_is_on(~led_key, 1'b1);

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

        // (4) dark during reset.
        check(led1_on == 1'b0, "LED dark while reset is asserted");

        rst_n = 1'b1;
        repeat (6) @(posedge clk);

        // (2)/(3) dark with no key held.
        check(led1_on == 1'b0, "LED dark when no key is held");

        // (1) key held -> LED lit.
        key_down_async = 1'b1;
        repeat (8) @(posedge clk);
        check(led_key == 1'b1, "key level propagates through the synchronizer");
        check(led1_on == 1'b1, "LED LIT while a key is held (pin driven LOW)");
        check(led_event == 1'b1, "key event pulse asserted");

        // release -> dark again.
        key_down_async = 1'b0;
        repeat (8) @(posedge clk);
        check(led1_on == 1'b0, "LED dark again after the key is released");

        // (5) an undriven pin must not light the LED.
        check(led_is_on(1'b0, 1'b0) == 1'b0, "tri-stated pin leaves the LED dark");

        // Polarity sanity: driving the pin HIGH must not light the LED.
        check(led_is_on(1'b1, 1'b1) == 1'b0, "pin driven HIGH leaves the LED dark");
        check(led_is_on(1'b0, 1'b1) == 1'b1, "pin driven LOW lights the LED");

        if (errors == 0) $display("tb_led_polarity: PASS");
        else             $display("tb_led_polarity: FAIL (%0d errors)", errors);

        $finish;
    end

endmodule

`default_nettype wire
