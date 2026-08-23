`timescale 1ns/1ps
// =============================================================================
// tb_top_matrix_led.sv
// -----------------------------------------------------------------------------
// Quick functional sanity testbench. Overrides the timing parameters to tiny
// values so a couple of full digits' worth of scanning can be observed in a
// short simulation run (ModelSim/QuestaSim/Questa-Intel-Starter, or any
// SystemVerilog simulator). Not meant to model real-world timing -- it only
// checks that the shift/latch/scan sequencing behaves as expected.
// =============================================================================
module tb_top_matrix_led;

    localparam int CLK_FREQ_HZ_TB      = 1000;  // fictitious, just to scale ticks down
    localparam int SHIFT_HALF_PERIOD_TB = 2;
    localparam int ROW_HOLD_TICKS_TB    = 10;
    localparam int DIGIT_HOLD_TICKS_TB  = 200;  // a handful of rows per digit
    localparam int CLR_PULSE_TICKS_TB   = 3;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic ROW, COL_GREEN, COL_RED;
    logic CLR1, CLR2, CLR3;
    logic RCLOCK, CLOCK;

    // 10 ns period system clock for simulation purposes only
    always #5 clk = ~clk;

    top_matrix_led #(
        .CLK_FREQ_HZ       (CLK_FREQ_HZ_TB),
        .SHIFT_HALF_PERIOD (SHIFT_HALF_PERIOD_TB),
        .ROW_HOLD_TICKS    (ROW_HOLD_TICKS_TB),
        .DIGIT_HOLD_TICKS  (DIGIT_HOLD_TICKS_TB),
        .CLR_PULSE_TICKS   (CLR_PULSE_TICKS_TB)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .ROW       (ROW),
        .COL_GREEN (COL_GREEN),
        .COL_RED   (COL_RED),
        .CLR1      (CLR1),
        .CLR3      (CLR3),
        .CLR2      (CLR2),
        .RCLOCK    (RCLOCK),
        .CLOCK     (CLOCK)
    );

    // count RCLOCK rising edges -> should see exactly 8 per digit-row scan cycle
    int latch_count = 0;
    always @(posedge RCLOCK) latch_count++;

    initial begin
        $display("[%0t] reset asserted", $time);
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        $display("[%0t] reset released", $time);

        // run long enough to cover several digits
        repeat (3000) @(posedge clk);

        $display("[%0t] total RCLOCK (latch) pulses observed = %0d", $time, latch_count);
        $display("[%0t] final digit_idx = %0d", $time, dut.digit_idx);
        $finish;
    end

    // waveform dump (optional)
    initial begin
        $dumpfile("tb_top_matrix_led.vcd");
        $dumpvars(0, tb_top_matrix_led);
    end

endmodule
