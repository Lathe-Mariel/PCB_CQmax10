// tb_spi_clk.sv
//
// Focused check of the RATIONAL clock divider in spi_byte_master.sv.
//
// The divider is the only new thing that a full-frame testbench exercises
// slowly, so it is checked here on its own: the SCK bit period and the minimum
// high/low pulse width are measured and compared with the values the
// parameters imply. This runs in well under a second, unlike tb_fps.
//
//   f_sck = f_clk * HALF_DEN / (2 * HALF_NUM)
//
//   HALF_NUM = 5, HALF_DEN = 2  ->  half period 2.5 clk -> bit 5 clk -> 10 MHz
//   HALF_NUM = 2, HALF_DEN = 1  ->  half period 2.0 clk -> bit 4 clk -> 12.5 MHz
//
// Two things matter for the ILI9341:
//   * the AVERAGE frequency (datasheet write limit is 10 MHz)
//   * every half period must still be at least the minimum pulse width; here
//     2 clk = 40 ns, far above the panel's minimum, so the fractional divider
//     can never produce a runt pulse.

`timescale 1ns/1ps

// Measures the SCK waveform of one spi_byte_master instance.
module sck_meter (
    input  logic clk,
    input  logic rst,
    input  logic sck
);
    logic sck_d   = 1'b0;
    logic run     = 1'b0;

    longint cyc       = 0;
    longint rise_t    = 0;      // time of the last rising edge
    longint fall_t    = 0;      // time of the last falling edge
    longint first_rise = -1;
    longint last_rise  = 0;

    int     n_rise    = 0;
    longint min_high  = 64'sh7fff_ffff;
    longint min_low   = 64'sh7fff_ffff;

    always_ff @(posedge clk) begin
        cyc  <= cyc + 1;
        sck_d <= sck;

        if (!rst) run <= 1'b1;

        if (run && sck && !sck_d) begin            // rising edge
            if (first_rise < 0) begin
                first_rise <= cyc;
            end else begin
                // low width = this rise - previous fall
                if ((cyc - fall_t) < min_low) min_low <= cyc - fall_t;
            end
            rise_t    <= cyc;
            last_rise <= cyc;
            n_rise    <= n_rise + 1;
        end

        if (run && !sck && sck_d) begin            // falling edge
            if ((cyc - rise_t) < min_high) min_high <= cyc - rise_t;
            fall_t <= cyc;
        end
    end

    // average bit period in clock cycles, from rise to rise within one byte.
    // Exactly ONE byte is sent per DUT (see the testbench), so there is no
    // inter-byte gap in the span and the average is the true bit period.
    function automatic real avg_bit_cycles();
        if (n_rise < 2) return 0.0;
        return real'(last_rise - first_rise) / real'(n_rise - 1);
    endfunction
endmodule


module tb_spi_clk;
    localparam int CLK_HZ = 50_000_000;

    logic clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    logic rst = 1'b1;
    logic done_a, done_b;
    logic start_a, start_b;

    logic sck_a, mosi_a, busy_a;
    logic sck_b, mosi_b, busy_b;

    // ---- DUT A: 10 MHz (the datasheet limit) ----
    spi_byte_master #(.HALF_NUM(5), .HALF_DEN(2)) dut_a (
        .clk(clk), .rst(rst), .start(start_a), .data_in(8'hA5),
        .sck(sck_a), .mosi(mosi_a), .busy(busy_a), .done(done_a)
    );

    // ---- DUT B: 12.5 MHz (integer divider, the previous setting) ----
    spi_byte_master #(.HALF_NUM(2), .HALF_DEN(1)) dut_b (
        .clk(clk), .rst(rst), .start(start_b), .data_in(8'h5A),
        .sck(sck_b), .mosi(mosi_b), .busy(busy_b), .done(done_b)
    );

    sck_meter mA (.clk(clk), .rst(rst), .sck(sck_a));
    sck_meter mB (.clk(clk), .rst(rst), .sck(sck_b));

    int errors = 0;

    task automatic check_real(input real got, input real want, input real tol,
                              input string what);
        if ((got < (want - tol)) || (got > (want + tol))) begin
            $display("  FAIL %s: got %.3f, want %.3f", what, got, want);
            errors = errors + 1;
        end else begin
            $display("  OK   %s: %.3f", what, got);
        end
    endtask

    task automatic check_int(input int got, input int minv, input string what);
        if (got < minv) begin
            $display("  FAIL %s: got %0d, want >= %0d", what, got, minv);
            errors = errors + 1;
        end else begin
            $display("  OK   %s: %0d clk", what, got);
        end
    endtask

    initial begin
        start_a = 1'b0;
        start_b = 1'b0;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (3) @(negedge clk);

        // exactly one byte each, so there is no inter-byte gap in the SCK span
        start_a = 1'b1;
        start_b = 1'b1;
        @(negedge clk);
        start_a = 1'b0;
        start_b = 1'b0;

        wait (!busy_a);
        repeat (4) @(negedge clk);

        $display("");
        $display("---- HALF_NUM=5 HALF_DEN=2 : expect 10 MHz ----");
        check_real(mA.avg_bit_cycles(), 5.0, 0.001, "SCK bit period (clk)");
        check_real(CLK_HZ / (mA.avg_bit_cycles() * 1.0e6), 10.0, 0.01,
                   "SCK frequency (MHz)");
        check_int(int'(mA.min_high), 2, "min SCK high (clk)");
        check_int(int'(mA.min_low),  2, "min SCK low  (clk)");
        $display("  %0d SCK rising edges in one byte", mA.n_rise);

        $display("");
        $display("---- HALF_NUM=2 HALF_DEN=1 : expect 12.5 MHz ----");
        check_real(mB.avg_bit_cycles(), 4.0, 0.001, "SCK bit period (clk)");
        check_real(CLK_HZ / (mB.avg_bit_cycles() * 1.0e6), 12.5, 0.01,
                   "SCK frequency (MHz)");
        check_int(int'(mB.min_high), 2, "min SCK high (clk)");
        check_int(int'(mB.min_low),  2, "min SCK low  (clk)");
        $display("  %0d SCK rising edges in one byte", mB.n_rise);

        if (mA.n_rise != 8) begin
            $display("  FAIL byte A: %0d SCK pulses, want 8", mA.n_rise);
            errors = errors + 1;
        end
        if (mB.n_rise != 8) begin
            $display("  FAIL byte B: %0d SCK pulses, want 8", mB.n_rise);
            errors = errors + 1;
        end

        $display("");
        if (errors == 0)
            $display("*** tb_spi_clk: PASS ***");
        else
            $display("*** tb_spi_clk: FAIL (%0d) ***", errors);
        $finish;
    end
endmodule
