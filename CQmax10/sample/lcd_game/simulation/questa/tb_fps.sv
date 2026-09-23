// tb_fps.sv
//
// Measures the REAL frame timing of the LCD pipeline, so the achievable frame
// rate can be stated with numbers instead of guesses.
//
// Reports:
//   * the CS-low time of one full frame  = pure transfer time
//   * the time between two frames        = transfer + gap + idle wait
//   * the implied fps of both
//
// The SPI clock is NOT scaled by MS_SCALE (only the panel's millisecond delays
// are), so the transfer numbers here are the real hardware numbers.
`timescale 1ns/1ps

module tb_fps;
    localparam int CLK_HZ      = 50_000_000;
    // SCK = clk * DEN / (2*NUM).  5/2 -> exactly 10 MHz (the datasheet limit);
    // 2/1 -> 12.5 MHz (the previous, faster-than-spec setting) for comparison.
    localparam int SCLK_NUM    = 5;
    localparam int SCLK_DEN    = 2;

    // MS_SCALE shortens ONLY the panel's millisecond waits; the SPI transfer
    // itself always runs at the real SCK rate, so the measured frame time is
    // the real hardware number. 1000 turns the 150 ms power-on wait into
    // 150 us, which is negligible next to a ~140 ms frame, so the frames run
    // back to back and the result is the true maximum frame rate. It also
    // keeps the derived cycle counts far above zero (see frame_seq.sv).
    localparam int MS_SCALE_TB = 1000;

    // Frame request period: 140 ms here becomes 140 us at MS_SCALE=1000, far
    // shorter than the real ~140 ms transfer, so it is never the limiter.
    localparam int FRAME_MS_TB = 140;

    logic clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    logic rst_n = 1'b0;
    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
    end

    logic lcd_cs, lcd_mosi, lcd_sck, lcd_dc;
    logic led, led0, led1, led2, led3;

    // The game is effectively frozen (STEP_MS huge) so the measurement is not
    // disturbed by pixel updates.
    lcd_test_top #(
        .CLK_FREQ_HZ     (CLK_HZ),
        .FRAME_PERIOD_MS (FRAME_MS_TB),
        .POWERON_WAIT_MS (1),
        .SCLK_HALF_NUM   (SCLK_NUM),
        .SCLK_HALF_DEN   (SCLK_DEN),
        .MS_SCALE        (MS_SCALE_TB),
        .MADCTL_VALUE    (8'h28),
        .STEP_MS         (1000000),
        .START_X         (1),
        .START_Y         (1)
    ) dut (
        .clk(clk),
        .btn_rst(rst_n),
        .sw1(1'b1),
        .sw2(1'b0),
        .lcd_cs(lcd_cs), .lcd_mosi(lcd_mosi), .lcd_sck(lcd_sck), .lcd_dc(lcd_dc),
        .led(led), .led0(led0), .led1(led1), .led2(led2), .led3(led3)
    );

    // ------------------------------------------------------------------
    // timing capture
    // ------------------------------------------------------------------
    // Only measurements taken AFTER the start-up sequence are meaningful: the
    // init sequence is a long train of short CS-low bursts and would otherwise
    // be mistaken for a frame. `armed` goes high once the start-up FSM reaches
    // the game state, i.e. once real frames start being scanned out.
    // led0 is ACTIVE LOW, so "game active" is led0 == 1'b0.
    logic armed = 1'b0;

    longint cyc = 0;
    always_ff @(posedge clk) cyc <= cyc + 1;

    logic cs_d = 1'b1;
    longint cs_fall = 0;
    longint cs_low  = 0;          // last CS-low duration of a WHOLE frame
    longint prev_fall = 0;
    longint period  = 0;          // CS-fall to CS-fall
    longint cs_low_max = 0;       // longest CS-low seen after arming
    int     n_cs_low = 0;
    int     n_frame  = 0;

    logic fd_d = 1'b0;
    longint prev_fd = 0;
    longint fd_period = 0;

    always_ff @(posedge clk) begin
        cs_d <= lcd_cs;
        fd_d <= dut.lcd_frame_done;

        if (!rst_n) begin
            armed      <= 1'b0;
            cs_low_max <= 0;
            cs_low     <= 0;
            period     <= 0;
            fd_period  <= 0;
            n_cs_low   <= 0;
            n_frame    <= 0;
            prev_fall  <= 0;
            prev_fd    <= 0;
            cs_fall    <= 0;
        end else begin
            if (led0 == 1'b0) armed <= 1'b1;

            // falling edge of CS: start of a command train
            if (cs_d && !lcd_cs) begin
                if (prev_fall != 0) period <= cyc - prev_fall;
                prev_fall <= cyc;
                cs_fall   <= cyc;
            end
            // rising edge of CS: end of a train
            if (!cs_d && lcd_cs) begin
                if (armed) begin
                    cs_low    <= cyc - cs_fall;
                    n_cs_low  <= n_cs_low + 1;
                    if ((cyc - cs_fall) > cs_low_max)
                        cs_low_max <= cyc - cs_fall;
                end
            end
            // frame_done pulses
            if (dut.lcd_frame_done && !fd_d) begin
                if (armed) begin
                    if (prev_fd != 0) fd_period <= cyc - prev_fd;
                    prev_fd <= cyc;
                    n_frame <= n_frame + 1;
                end
            end
        end
    end

    localparam real NS_PER_CYC = 20.0;              // 50 MHz

    task automatic report(input longint cycles, input string what);
        real us;
        us = cycles * NS_PER_CYC / 1000.0;
        $display("  %-28s %10.0f us   (%0d clk)", what, us, cycles);
    endtask

    int t0;
    longint deadline;
    initial begin
        // The transfer is the REAL 10 MHz SPI and CANNOT be sped up: one whole
        // frame is ~140 ms of simulated time, which takes Questa roughly a
        // minute of wall time. So wait for a SINGLE frame_done. The frame
        // period is max(FRAME_PERIOD_MS, transfer) anyway, because frame_seq's
        // timer runs in parallel with the transfer.
        //
        // The wait is counted in CLOCK CYCLES so it always progresses. It is
        // capped at ~400 ms of simulated time; if the cap is hit the report
        // says so instead of hanging forever (a hang here is how the earlier
        // zero-period bug manifested).
        deadline = 400_000_000 / 20;            // 20 ns per clock
        while (n_frame < 1 && cyc < deadline) @(negedge clk);
        repeat (4) @(negedge clk);

        if (n_frame < 1) begin
            $display("  *** no frame completed within %0d clk - something is stuck ***",
                     deadline);
            $display("      led=%b led0=%b led1=%b (led0 low = game started)",
                     led, led0, led1);
            $finish;
        end

        $display("  frames seen after arming = %0d", n_frame);
        $display("");
        $display("  ---- one full frame (real SPI) ----");
        report(cs_low_max, "CS-low = one whole frame");
        $display("      -> %.1f fps if frames back to back",
                 1.0e9 / (cs_low_max * NS_PER_CYC));
        if (fd_period != 0) begin
            report(fd_period, "frame_done to frame_done");
            $display("      -> %.1f fps with FRAME_PERIOD_MS = %0d",
                     1.0e9 / (fd_period * NS_PER_CYC), FRAME_MS_TB);
        end

        $display("");
        $display("  ---- pixel payload ----");
        $display("      %0d pixels x 16 bit = %0d bit/frame", 320*240, 320*240*16);
        $display("      SCK = %.2f MHz  (NUM=%0d DEN=%0d)",
                 50.0 * SCLK_DEN / (2.0*SCLK_NUM), SCLK_NUM, SCLK_DEN);
        $display("      theoretical minimum = %.1f ms",
                 (320.0*240.0*16.0) / (50.0e6*SCLK_DEN/(2.0*SCLK_NUM)) * 1000.0);

        $finish;
    end
endmodule
