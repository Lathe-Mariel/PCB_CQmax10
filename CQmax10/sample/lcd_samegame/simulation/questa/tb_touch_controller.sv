// tb_touch_controller.sv
//
// First testbench for touch_controller.  It exists because the touch path had
// NO coverage at all, and two real bugs survived all the way to the board
// because of that:
//
//   1. The pin assignment put touch_cs and touch_mosi on DIFFERENT PMOD
//      connectors (a synthesis/board issue, caught by reading the module
//      schematic - not testable here).
//   2. adc_to_x / adc_to_y divided by a power of two (>>13, i.e. /8192)
//      instead of by the actual ADC span (X_ADC_MAX - X_ADC_MIN = 3700).
//      The reported X could therefore never exceed 144, so the right half of
//      the panel and the bottom half never responded.  THIS testbench covers
//      exactly that, and the coordinate sweep below is the regression guard.
//
// The DUT talks to an XPT2046 model that replies with a chosen ADC value,
// which lets the whole chain (control byte -> 24-bit frame -> 12-bit result ->
// median of 3 -> coordinate conversion -> touch_valid / touch_down) be checked
// against a software reference model rather than hand-written expectations.

// ---------------------------------------------------------------------------
// XPT2046 slave model
//
// ALIGNMENT RULE (derived from what the DUT actually does, not from the
// datasheet figure): the DUT samples MISO on the rising edges where its own
// `spi_bit` counter reads 9..20 inclusive, MSB first, into a 12-bit register
// that it publishes as `spi_result`.  So the panel must drive
//     answer[11] at spi_bit = 9 ... answer[0] at spi_bit = 20
// and anything at all elsewhere.
//
// `spi_bit` is the count BEFORE the increment taken on that edge, which is why
// the model below uses `n` (also pre-increment) directly: both counters start at
// 0 and advance once per SCK period, so n == spi_bit on every rising edge.
//
// The command byte is presented by the DUT during spi_bit 0..7, MSB first, so
// eight samples on n = 0..7 reconstruct it exactly.
//
// NOTE: modelling the datasheet's "12 clocks" as spi_bit 12..23 instead was the
// bug in the first version of this model - it made the DUT capture
// {busy, busy, answer[11:2]} = (3<<10)|(answer>>2), which read as a permanent
// "pressed" state and reported nonsense coordinates.
// ---------------------------------------------------------------------------
module xpt2046_model #(
    parameter bit NO_TOUCH = 1'b0      // 1 = report no pressure at all
)(
    input  logic clk,
    input  logic cs_n,
    input  logic din,
    input  logic sck,
    output logic dout,
    // ADC values returned for each command, driven by the testbench so a whole
    // coordinate sweep can be played in one run.  (These cannot be parameters:
    // a parameter needs a constant expression, and the TB changes them.)
    input  logic [11:0] val_x,
    input  logic [11:0] val_y,
    input  logic [11:0] val_z1,
    // 1 = behave like a MISO line stuck HIGH: every answer is all ones, which
    // is what the board showed (touch_valid froze high because the "pressure"
    // reading was permanently saturated).
    input  logic        stuck_hi
);
    logic [7:0]  shift;
    logic [5:0]  n;            // SCK periods since CS went low
    logic [7:0]  cmd_r;
    logic        cmd_valid;
    logic [11:0] answer;

    logic sck_d;
    always_ff @(posedge clk) sck_d <= sck;
    wire rise = sck & ~sck_d;

    // value to return for the command
    always_comb begin
        if (NO_TOUCH || stuck_hi) answer = 12'hFFF;      // all ones = MISO stuck high
        else if (cmd_r == 8'hD0)  answer = val_x;
        else if (cmd_r == 8'h90)  answer = val_y;
        else if (cmd_r == 8'hB0)  answer = val_z1;
        else                      answer = 12'd0;
    end

    always_ff @(posedge clk) begin
        if (cs_n) begin
            n         <= 6'd0;
            shift     <= 8'd0;
            cmd_valid <= 1'b0;
        end else if (rise) begin
            n <= n + 6'd1;
            if (n < 6'd8) begin
                shift <= {shift[6:0], din};          // 8 command bits, MSB first
            end else if (n == 6'd8) begin
                // `shift` already holds all eight bits sampled on n = 0..7
                cmd_r     <= shift;
                cmd_valid <= 1'b1;
            end
        end
    end

    // ONE driving process (mixing an always_ff and an always_comb driver for the
    // same signal is vopt-7033, which fails elaboration).
    always_comb begin
        if (cs_n || !cmd_valid)                            dout = 1'b1;
        else if (n >= 6'd9 && n <= 6'd20) begin
            logic [4:0] idx;
            idx  = n - 6'd9;                               // 0..11
            dout = answer[11 - idx[3:0]];                  // MSB first
        end else                                           dout = 1'b1;
    end
endmodule


module tb_touch_controller;
    localparam int CLK_HZ = 50_000_000;

    logic clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    logic rst = 1'b1;

    int errors = 0;
    int checks = 0;

    task automatic chk(input string what, input int got, input int exp);
        checks++;
        if (got !== exp) begin
            errors++;
            if (errors <= 25)
                $display("  FAIL %s : got %0d expected %0d", what, got, exp);
        end
    endtask

    // Some checks compare against a software model whose arithmetic differs by
    // design: adc_to_x/y use a Q16 reciprocal multiply-shift instead of a real
    // divider (a divider costs -62 ns of setup slack and is unusable at 50 MHz),
    // so the result can be 1 LSB away from exact integer division.  Allow that.
    task automatic chk_near(input string what, input int got, input int exp, input int tol);
        checks++;
        if (got > exp + tol || got < exp - tol) begin
            errors++;
            if (errors <= 25)
                $display("  FAIL %s : got %0d expected %0d +/-%0d", what, got, exp, tol);
        end
    endtask

    // ---- DUT -----------------------------------------------------------
    logic cs_n, mosi, miso, sck;
    logic touch_valid, touch_down, touch_up;
    logic [8:0] touch_x;
    logic [7:0] touch_y;

    logic [11:0] val_x, val_y, val_z1;
    logic        stuck_mode;

    xpt2046_model u_panel (
        .clk(clk), .cs_n(cs_n), .din(mosi), .sck(sck), .dout(miso),
        .val_x(val_x), .val_y(val_y), .val_z1(val_z1),
        .stuck_hi(stuck_mode)
    );

    logic [2:0] dbg_z1;
    logic       dbg_stuck;
    logic [2:0] dbg_live;
    logic [4:0] dbg_low_idx;
    logic [4:0] dbg_low_idx_alt;
    logic [4:0] dbg_low_idx_fr;
    logic [1:0] dbg_socket;
    logic       miso_alt;
    logic       miso_fr;
    // The two extra sockets are driven by the DUT but nothing is attached to them
    // in this testbench, so their CS/MOSI/SCK outputs simply dangle and their
    // MISO inputs are tied HIGH - which is what an undriven pad reads.  Their
    // liveness bits must therefore stay 0 while socket J2 does go live.
    logic       alt_cs, alt_mosi, alt_sck;
    logic       fr_cs, fr_mosi, fr_sck;

    // ------------------------------------------------------------------
    // FRAME-ALIGNMENT REGRESSION GUARD
    //
    // A well-formed XPT2046 transfer is EXACTLY 24 SCK rising edges while CS is
    // low (8 command + 12 result + acquisition/padding).
    //
    // This check exists because of a real, silent RTL bug: the SPI bit-clock
    // divider free-ran instead of being re-synchronised to the start of a
    // transfer, so a frame could begin on a divider phase whose first event was
    // a FALL.  The 24-clock frame then contained only 23 RISING edges, which
    // shifted the entire command/result pair by one bit - 0xB0 came back as
    // 0x60 and the captured value became `{1, result[11:1]}`.  Everything
    // downstream "worked", just with wrong numbers, so only a structural check
    // like this one catches it.
    // ------------------------------------------------------------------
    int   frame_edges = 0;
    int   bad_frames  = 0;
    logic cs_n_d = 1'b1;
    logic sck_d_tb = 1'b0;

    always_ff @(posedge clk) cs_n_d  <= cs_n;
    always_ff @(posedge clk) sck_d_tb <= sck;

    always_ff @(posedge clk) begin
        if (cs_n) begin
            frame_edges <= 0;
        end else if (sck && !sck_d_tb) begin
            frame_edges <= frame_edges + 1;
        end
        // CS rising edge = end of a transfer.  It must carry 24 edges.
        if (cs_n && !cs_n_d) begin
            if (frame_edges !== 24) begin
                bad_frames <= bad_frames + 1;
                $display("    [frame] MALFORMED: %0d SCK rising edges in one CS-low window (expected 24)",
                         frame_edges);
            end
        end
    end

    // Diagnostic monitor (gated by `mon_on`, set just before phase [4c]).
    //
    // It prints ONE line per completed SPI conversion and shows, side by side,
    // the command the PANEL model thinks it just served (`u_panel.cmd_r`) and
    // what the DUT actually captured (`dut.shift_in` / `dut.spi_result`).
    // That is what distinguishes "the wire is wrong" from "the capture window
    // is off by a bit": a bit-shifted capture of an all-zero answer yields
    // exactly 12'b1000_0000_0000 = 2048.
    bit mon_on = 1'b0;
    always @(posedge clk) begin
        if (mon_on && dut.spi_done)
            $display("    [sd] t=%0t panel_cmd=%h panel_n=%0d dut_shift=%b dut_res=%0d dut_rz=%0d dut_st=%0d",
                     $time, u_panel.cmd_r, u_panel.n, dut.shift_in, dut.spi_result, dut.raw_z1, dut.state);
    end

    touch_controller #(
        .CLK_FREQ_HZ(CLK_HZ),
        .SAMPLE_MS(10),
        // MS_SCALE divides the millisecond counter, so 100 turns the 10 ms
        // sample period into 5000 cycles.  Without it one period is 500,000
        // cycles and the coordinate sweep below would need tens of millions of
        // simulated cycles (minutes of wall clock) for no extra coverage.
        .MS_SCALE(100),
        // MUST match the shipped default in touch_controller.sv (12'd16), so this
        // testbench actually guards the configuration that gets built.
        .TOUCH_THRESH(12'd16),
        .X_ADC_MIN(12'd200), .X_ADC_MAX(12'd3900),
        .Y_ADC_MIN(12'd200), .Y_ADC_MAX(12'd3900)
    ) dut (
        .clk(clk), .rst(rst),
        .touch_cs(cs_n), .touch_mosi(mosi), .touch_miso(miso), .touch_sck(sck),
        .alt_cs(alt_cs), .alt_mosi(alt_mosi), .alt_miso(miso_alt), .alt_sck(alt_sck),
        .fr_cs(fr_cs), .fr_mosi(fr_mosi), .fr_miso(miso_fr), .fr_sck(fr_sck),
        .touch_valid(touch_valid), .touch_x(touch_x), .touch_y(touch_y),
        .touch_down(touch_down), .touch_up(touch_up),
        .dbg_z1(dbg_z1), .dbg_stuck(dbg_stuck),
        .dbg_live(dbg_live),
        .dbg_low_idx(dbg_low_idx),
        .dbg_low_idx_alt(dbg_low_idx_alt),
        .dbg_low_idx_fr(dbg_low_idx_fr),
        .dbg_socket(dbg_socket)
    );

    // One sample period in cycles, matching the DUT's MS_CYCLES * SAMPLE_MS.
    // A coordinate update costs THREE conversions (the median of 3), and each
    // conversion is 24 bits * 32 clocks = 768 cycles, so allow generously more
    // than 3 periods and let the loop settle on a stable reading.
    localparam int PERIOD_CYCLES = 5000;

    // Software reference model of the coordinate conversion, mirroring the
    // INTENDED behaviour (divide by the real span, not by 8192).
    localparam int XMIN = 200, XMAX = 3900;
    localparam int YMIN = 200, YMAX = 3900;

    function automatic int ref_x(input int raw);
        if (raw <= XMIN) return 319;
        if (raw >= XMAX) return 0;
        return ((XMAX - raw) * 319) / (XMAX - XMIN);
    endfunction
    function automatic int ref_y(input int raw);
        if (raw <= YMIN) return 239;
        if (raw >= YMAX) return 0;
        return ((YMAX - raw) * 239) / (YMAX - YMIN);
    endfunction

    // Wait long enough for `n` fresh coordinate updates.  Each update needs 3
    // conversions and a conversion is 768 clocks, while the sample period is
    // PERIOD_CYCLES, so ONE update lands every ~3 periods.  Use 5 periods per
    // update for margin against a sample_req that arrives mid-conversion.
    task automatic wait_updates(input int n);
        repeat (n * 5 * PERIOD_CYCLES) @(posedge clk);
    endtask

    int x_ref, y_ref;

    initial begin
        rst = 1'b1;
        val_x = 12'd2000; val_y = 12'd2000; val_z1 = 12'd1000;
        // stuck_mode MUST be initialised.  Leaving it at X makes the model's
        // `if (NO_TOUCH || stuck_hi)` take the all-ones branch (Questa treats a
        // conditional on X as true), so every conversion returned 12'hFFF and
        // the Z1 meter sat pinned at 7 for the whole run - which looked exactly
        // like a broken meter rather than a testbench bug.
        stuck_mode = 1'b0;
        // The alternate MISO pads are NOT connected in the TB: leave them high,
        // which is what an undriven pad reads.  Their liveness bits must stay 0
        // while the pad the controller actually reads does go low.
        miso_alt = 1'b1;
        miso_fr  = 1'b1;
        repeat (20) @(posedge clk);
        rst = 1'b0;

        // ---------------------------------------------------------------
        $display("[1] no touch: Z1 below threshold -> touch_valid must stay 0");
        val_z1 = 12'd8;                        // < TOUCH_THRESH (16)
        wait_updates(8);
        chk("valid stays low without a press", touch_valid, 0);
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---------------------------------------------------------------
        $display("[2] press: Z1 above threshold -> touch_valid must rise");
        val_z1 = 12'd2000;
        val_x  = 12'd2000;
        val_y  = 12'd2000;
        wait_updates(8);
        chk("valid asserted while pressed", touch_valid, 1);
        $display("    first press: valid=%0b x=%0d y=%0d", touch_valid, touch_x, touch_y);

        // ---------------------------------------------------------------
        // The heart of the matter: sweep the ADC value across its whole range
        // and compare against the reference model.  With the old /8192 divide
        // x can never exceed 144, so most of these fail loudly.
        $display("[3] coordinate sweep (the /8192 regression guard)");
        for (int k = 0; k < 10; k++) begin
            val_x = 12'd200 + (k * (3700 / 9));
            val_y = 12'd200 + (((9 - k) * (3700 / 9)));
            wait_updates(8);
            x_ref = ref_x(val_x);
            y_ref = ref_y(val_y);
            chk_near($sformatf("sweep x @raw=%0d", val_x), touch_x, x_ref, 1);
            chk_near($sformatf("sweep y @raw=%0d", val_y), touch_y, y_ref, 1);
        end
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---------------------------------------------------------------
        $display("[4] full-scale reach: the extremes must be usable");
        val_x = 12'd220; val_y = 12'd220;           // just inside the clamp
        wait_updates(8);
        chk("near X_ADC_MIN reaches a high X", (touch_x > 9'd300) ? 1 : 0, 1);
        val_x = 12'd3880; val_y = 12'd3880;         // just inside the clamp
        wait_updates(8);
        chk("near X_ADC_MAX reaches a low X",  (touch_x < 9'd20) ? 1 : 0, 1);

        // ---------------------------------------------------------------
        // The pad-liveness probe.  The pad the controller reads is driven by
        // the model, so it must go low at least once; the alternate pad is left
        // floating HIGH and must therefore never be flagged.  This is exactly
        // the discrimination the board needs.
        $display("[4b] pad liveness: socket J2 driven, J1/J3 undriven");
        chk("J2 socket flagged live",     dbg_live[2], 1);
        chk("J1 socket NOT live",         dbg_live[1], 0);
        chk("J3 socket NOT live",         dbg_live[0], 0);

        // ---------------------------------------------------------------
        // The Z1 meter.  It reports the magnitude of the last conversion, so a
        // press must light it progressively.  Threshold 16 -> bit0 first.
        $display("[4c] Z1 magnitude meter");
        mon_on = 1'b1;
        val_z1 = 12'd0;                 // released: nothing should light
        wait_updates(8);
        $display("    val_z1=%0d dut.raw_z1=%0d dut.spi_result=%0d dbg_z1=%b state=%0d",
                 val_z1, dut.raw_z1, dut.spi_result, dbg_z1, dut.state);
        chk("Z1 meter dark when released", dbg_z1, 3'b000);
        val_z1 = 12'd100;               // over 16, under 256
        wait_updates(8);
        $display("    val_z1=%0d dut.raw_z1=%0d dut.spi_result=%0d dbg_z1=%b state=%0d",
                 val_z1, dut.raw_z1, dut.spi_result, dbg_z1, dut.state);
        chk("Z1 >= 16 lights bit0 only",   dbg_z1, 3'b001);
        val_z1 = 12'd1000;              // over 256, under 2048
        wait_updates(8);
        $display("    val_z1=%0d dut.raw_z1=%0d dut.spi_result=%0d dbg_z1=%b state=%0d",
                 val_z1, dut.raw_z1, dut.spi_result, dbg_z1, dut.state);
        chk("Z1 >= 256 lights bit1 too",   dbg_z1, 3'b011);
        val_z1 = 12'd3000;              // over 2048 as well
        wait_updates(8);
        $display("    val_z1=%0d dut.raw_z1=%0d dut.spi_result=%0d dbg_z1=%b state=%0d",
                 val_z1, dut.raw_z1, dut.spi_result, dbg_z1, dut.state);
        chk("Z1 >= 2048 lights all three", dbg_z1, 3'b111);

        // ---------------------------------------------------------------
        // The FIRST-LOW-CLOCK probe.  This is the measurement that separates
        // "nothing drives the MISO pad" from "the result is sampled on the
        // wrong clocks" - the two faults that are otherwise indistinguishable.
        //
        // With the model driving answer[11] at clock 9 (matching the DUT's
        // 9..20 window) the FIRST zero must appear at clock 9 for any answer
        // whose bit 11 is 0, i.e. any value below 2048.  The answer used here
        // (val_z1 = 3000) has bit 11 set, so its first 0 is one clock later.
        // Rather than hand-compute that, the TB compares against the model's
        // own first-zero position, which is derived from the same `answer`
        // value the model is driving.
        $display("[4d] first-low-clock probe (dbg_low_idx)");

        // NOTE ON WHICH TRANSFER THIS OBSERVES: the probe publishes on EVERY
        // completed transfer, and once Z1 clears the threshold the controller
        // also reads X and Y - so the LAST transfer before the check is usually
        // Y, not Z1.  (Reading 13 here was exactly right: it is the first-low
        // clock of val_y = 0xF28, since answer[7] = 0 -> 11-7 = 4 -> 9+4 = 13.)
        // To make the expectation independent of which channel is read last,
        // drive ALL THREE channels to the same value.

        // All channels 0 -> bit 11 is 0, so the very first sampled bit is low.
        val_z1 = 12'd0; val_x = 12'd0; val_y = 12'd0;
        wait_updates(8);
        $display("    all-channels=0 dbg_low_idx=%0d (5'h1F=%0d means never low)",
                 dbg_low_idx, 5'h1F);
        chk("all-zero channels -> first low at clock 9", dbg_low_idx, 5'd9);

        // All channels full-scale -> every bit is 1, so the pad never goes low
        // anywhere in the frame -> 5'h1F.  This is the SAME code a completely
        // undriven pad produces, which is why the probe must always be read
        // together with the magnitude meter (dbg_z1).
        val_z1 = 12'hFFF; val_x = 12'hFFF; val_y = 12'hFFF;
        wait_updates(8);
        $display("    all-channels=0xFFF dbg_low_idx=%0d", dbg_low_idx);
        chk("all-ones channels -> never low (5'h1F)", dbg_low_idx, 5'h1F);

        // A mid-range value whose bit 11 is 0: first zero is still at clock 9.
        val_z1 = 12'd1000; val_x = 12'd1000; val_y = 12'd1000;   // 0x3E8
        wait_updates(8);
        $display("    all-channels=0x3E8 dbg_low_idx=%0d", dbg_low_idx);
        chk("0x3E8 channels -> first low at clock 9", dbg_low_idx, 5'd9);

        // And a value whose bit 11 is 1 but bit 10 is 0: the first zero must
        // appear one clock later, at clock 10.  THIS is the check that proves
        // the probe really locates the bit position and is not just reporting a
        // constant.
        val_z1 = 12'd2048; val_x = 12'd2048; val_y = 12'd2048;   // 0x800
        wait_updates(8);
        $display("    all-channels=0x800 dbg_low_idx=%0d", dbg_low_idx);
        chk("0x800 channels -> first low at clock 10", dbg_low_idx, 5'd10);

        // 0xC00 = 1100_0000_0000: bits 11 and 10 are set, bit 9 is 0 -> clock 11.
        val_z1 = 12'd3072; val_x = 12'd3072; val_y = 12'd3072;
        wait_updates(8);
        $display("    all-channels=0xC00 dbg_low_idx=%0d", dbg_low_idx);
        chk("0xC00 channels -> first low at clock 11", dbg_low_idx, 5'd11);

        // ---------------------------------------------------------------
        $display("[5] release: Z1 drops -> touch_valid clears");
        val_z1 = 12'd8;
        wait_updates(10);
        chk("valid cleared after release", touch_valid, 0);
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---------------------------------------------------------------
        // The bring-up probe.  Force the model to return all ones, which is what
        // a MISO line stuck HIGH produces (the touch chip absent / unpowered /
        // not on these pins).  That is the state the board was in: touch_valid
        // came up and never went away, so its LED lit permanently.
        $display("[6] MISO stuck HIGH (all-ones results) -> dbg_stuck must latch");
        stuck_mode = 1'b1;
        val_z1     = 12'd0;             // make the panel look untouched
        wait_updates(24);               // need >16 conversions
        chk("stuck flag latched",      dbg_stuck, 1);
        // an all-ones answer also saturates the meter
        chk("all-ones lights every bit", dbg_z1, 3'b111);
        // and this is exactly why touch_valid froze high: the fake pressure
        // reading is saturated, so it is permanently >= TOUCH_THRESH
        chk("all-ones reads as pressed", touch_valid, 1);
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---------------------------------------------------------------
        // Clearing the stuck condition must clear the verdict: any conversion
        // that is not all ones proves the line is being driven.
        $display("[7] link recovers -> dbg_stuck must clear");
        stuck_mode = 1'b0;
        val_x = 12'd1200; val_y = 12'd2600; val_z1 = 12'd2000;
        wait_updates(24);
        chk("stuck flag cleared", dbg_stuck, 0);
        $display("    checks=%0d errors=%0d", checks, errors);

        $display("================================");
        $display("  checks=%0d errors=%0d malformed_frames=%0d", checks, errors, bad_frames);
        chk("every SCK frame had exactly 24 rising edges", bad_frames, 0);
        $display("  checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("  ALL PASS");
        else             $display("  *** FAILURES ***");
        $display("================================");
        $finish;
    end

    // absolute watchdog.
    // NOTE the time unit is 1 ns (there is no `timescale` here), so a bare
    // "#5000000" is 5 ms = only 250,000 clocks at 50 MHz - which is LESS than
    // phase 1 alone consumes and made the watchdog fire in the middle of the
    // suite.  Budget in real time instead: 200 ms = 10M clocks.
    initial begin
        #200_000_000;
        $display("TIMEOUT: valid=%0b x=%0d y=%0d", touch_valid, touch_x, touch_y);
        errors++;
        $display("  *** FAILURES ***");
        $finish;
    end
endmodule
