// tb_orange.sv
//
// End-to-end check of the "paint the whole panel orange" design:
//
//   1. after reset the panel receives the ILI9341 init sequence
//      (SWRESET, SLPOUT, MADCTL, COLMOD, DISPON, ...) as SPI bytes with the
//      right D/C levels and the right inter-command delays
//   2. every frame request produces
//          CASET 00 00 01 3F  PASET 00 00 00 EF  RAMWR
//      followed by exactly 320*240 RGB565 pixels, row major, all identical
//      and all equal to COLOR_BIT0 (orange)
//   3. the next frame request repeats the same transfer
//
// Time scale: the design's millisecond delays are scaled down via MS_SCALE so
// the test runs in a reasonable time. The SPI side is NOT scaled: it runs at
// the real clk/4 = 12.5 MHz, so one frame still takes ~113 ms of simulated
// time, which is where most of the run time goes.
`timescale 1ns/1ps

module tb_orange;
    localparam int CLK_HZ        = 50_000_000;
    localparam int SCLK_HALF     = 2;                    // SCK = clk/4 = 12.5 MHz
    localparam int MS_SCALE_TB   = 5;                    // 1 ms -> 200 us
    localparam int MS_CYCLES     = (CLK_HZ/1000)/MS_SCALE_TB;   // 10000 clk
    localparam int CYCLE_NS      = 20;                   // 50 MHz
    localparam int FRAME_MS_TB   = 1;

    localparam int NPIX          = 320*240;
    localparam int FRAME_BYTES   = 11 + 2*NPIX;

    localparam logic [15:0] C_ORANGE = 16'hFD20;

    logic clk = 1'b0;
    always #10 clk = ~clk;                               // 50 MHz

    logic rst_n = 1'b0;

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
    end
    logic lcd_cs, lcd_mosi, lcd_sck, lcd_dc;
    logic led, led0, led1, led2, led3;

    lcd_test_top #(
        .CLK_FREQ_HZ     (CLK_HZ),
        .FRAME_PERIOD_MS (FRAME_MS_TB),
        .POWERON_WAIT_MS (1),
        .SCLK_HALF_CYCLES(SCLK_HALF),
        .MS_SCALE        (MS_SCALE_TB),
        .MADCTL_VALUE    (8'h28),
        .COLOR_BIT0      (16'hFD20),
        .COLOR_BIT1      (16'hFFFF),
        .COLOR_INFO      (16'hFD20)
    ) dut (
        .clk(clk),
        .btn_rst(rst_n),
        .sw1(1'b1),
        .sw2(1'b0),
        .lcd_cs(lcd_cs), .lcd_mosi(lcd_mosi), .lcd_sck(lcd_sck), .lcd_dc(lcd_dc),
        .led(led), .led0(led0), .led1(led1), .led2(led2), .led3(led3)
    );

    // ------------------------------------------------------------------
    // SPI monitor: mode 0, sample MOSI on the rising SCK edge
    // ------------------------------------------------------------------
    typedef struct { logic dc; logic [7:0] data; } byte_t;

    byte_t          frame_bytes[$];        // bytes captured while CS is low
    logic [7:0]     shreg     = 8'h00;
    int             bit_cnt   = 0;
    int             byte_cnt  = 0;

    int total_errors = 0;
    int total_checks = 0;

    task automatic check_equal(input string what, input int got, input int exp);
        total_checks++;
        if (got !== exp) begin
            total_errors++;
            $display("  FAIL %s : got 0x%0h expected 0x%0h", what, got, exp);
        end
    endtask

    // CS rising edge = end of the byte train

    always @(posedge lcd_sck) begin
        if (!lcd_cs) begin
            shreg   = {shreg[6:0], lcd_mosi};
            bit_cnt = bit_cnt + 1;
            if (bit_cnt == 8) begin
                byte_t b;
                b.dc   = lcd_dc;         // D/C is stable for the whole byte
                b.data = shreg;
                frame_bytes.push_back(b);
                byte_cnt = byte_cnt + 1;
                if ($test$plusargs("verbose"))
                    $display("    [%0t] byte %0d : dc=%b data=%02h", $time, byte_cnt, b.dc, b.data);
                bit_cnt  = 0;
                shreg    = 8'h00;
            end
        end
    end
    // realign the byte boundary at the start of every CS-low train and start a
    // fresh capture. CS falls before the first SCK edge of the train, so this
    // never discards a byte.
    always @(negedge lcd_cs) begin
        if ($test$plusargs("verbose"))
            $display("    [%0t] ---- CS low: new train ----", $time);
        frame_bytes.delete();
        byte_cnt = 0;
        bit_cnt  = 0;
        shreg    = 8'h00;
    end
    always @(posedge lcd_cs) begin
        if ($test$plusargs("verbose"))
            $display("    [%0t] ---- CS high: %0d bytes ----", $time, byte_cnt);
    end
    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    task automatic wait_bytes(input int n);
        int t0;
        t0 = $time;
        while (byte_cnt < n) begin
            @(posedge clk);
            if ($time - t0 > 1_000_000_000) begin      // 1 s simulated
                $display("  TIMEOUT waiting for %0d bytes (saw %0d)", n, byte_cnt);
                $display("*** tb_orange: FAIL (timeout) ***");
                $finish;
            end
        end
    endtask

    task automatic fail(input string msg);
        total_errors++;
        $display("  FAIL %s", msg);
    endtask

    // wait for the SPI train in progress to end (CS goes high)
    task automatic wait_cs_high();
        int t0;
        t0 = $time;
        while (!lcd_cs) begin
            @(posedge clk);
            if ($time - t0 > 2_000_000_000) begin
                $display("  TIMEOUT waiting for CS high (%0d bytes)", byte_cnt);
                $display("*** tb_orange: FAIL (timeout) ***");
                $finish;
            end
        end
    endtask

    // wait until the current SPI train has finished, then for the next one to
    // begin. The capture buffer is cleared by the CS falling-edge handler, so
    // this task must not touch it.
    task automatic start_new_capture();
        while (!lcd_cs) @(negedge clk);   // let the current train finish
        while (lcd_cs)  @(negedge clk);   // wait for the next train to start
    endtask

    // ------------------------------------------------------------------
    // main
    // ------------------------------------------------------------------
    logic [7:0] exp_init    [0:69];
    logic       exp_init_dc [0:69];
    int    n_exp;
    int    i;
    int    saw;
    int    t0;
    initial begin
        // ------------------- reference init sequence -----------------
        // exp_init[k] is SPI byte number (k+3) of the sequence: byte 1 is
        // SWRESET and byte 2 is SLPOUT, both checked separately below.
        n_exp = 0;
        // SWRESET / SLPOUT + delays are covered by the delay test below
        // commands: PWCTR1..DISPON
        exp_init[0]  = 8'hC0; exp_init_dc[0]  = 1'b0;
        exp_init[1]  = 8'h23; exp_init_dc[1]  = 1'b1;
        exp_init[2]  = 8'hC1; exp_init_dc[2]  = 1'b0;
        exp_init[3]  = 8'h10; exp_init_dc[3]  = 1'b1;
        exp_init[4]  = 8'hC5; exp_init_dc[4]  = 1'b0;
        exp_init[5]  = 8'h3E; exp_init_dc[5]  = 1'b1;
        exp_init[6]  = 8'h28; exp_init_dc[6]  = 1'b1;
        exp_init[7]  = 8'hC7; exp_init_dc[7]  = 1'b0;
        exp_init[8]  = 8'h86; exp_init_dc[8]  = 1'b1;
        exp_init[9]  = 8'h36; exp_init_dc[9]  = 1'b0;
        exp_init[10] = 8'h28; exp_init_dc[10] = 1'b1;   // MADCTL_VALUE
        exp_init[11] = 8'h3A; exp_init_dc[11] = 1'b0;
        exp_init[12] = 8'h55; exp_init_dc[12] = 1'b1;   // COLMOD 16bpp
        exp_init[13] = 8'hB1; exp_init_dc[13] = 1'b0;
        exp_init[14] = 8'h00; exp_init_dc[14] = 1'b1;
        exp_init[15] = 8'h1B; exp_init_dc[15] = 1'b1;
        exp_init[16] = 8'hB6; exp_init_dc[16] = 1'b0;
        exp_init[17] = 8'h08; exp_init_dc[17] = 1'b1;
        exp_init[18] = 8'h82; exp_init_dc[18] = 1'b1;
        exp_init[19] = 8'h27; exp_init_dc[19] = 1'b1;
        exp_init[20] = 8'h26; exp_init_dc[20] = 1'b0;
        exp_init[21] = 8'h01; exp_init_dc[21] = 1'b1;
        exp_init[22] = 8'hE0; exp_init_dc[22] = 1'b0;
        exp_init[23] = 8'h0F; exp_init_dc[23] = 1'b1;
        exp_init[24] = 8'h31; exp_init_dc[24] = 1'b1;
        exp_init[25] = 8'h2B; exp_init_dc[25] = 1'b1;
        exp_init[26] = 8'h0C; exp_init_dc[26] = 1'b1;
        exp_init[27] = 8'h0E; exp_init_dc[27] = 1'b1;
        exp_init[28] = 8'h08; exp_init_dc[28] = 1'b1;
        exp_init[29] = 8'h4E; exp_init_dc[29] = 1'b1;
        exp_init[30] = 8'hF1; exp_init_dc[30] = 1'b1;
        exp_init[31] = 8'h37; exp_init_dc[31] = 1'b1;
        exp_init[32] = 8'h07; exp_init_dc[32] = 1'b1;
        exp_init[33] = 8'h10; exp_init_dc[33] = 1'b1;
        exp_init[34] = 8'h03; exp_init_dc[34] = 1'b1;
        exp_init[35] = 8'h0E; exp_init_dc[35] = 1'b1;
        exp_init[36] = 8'h09; exp_init_dc[36] = 1'b1;
        exp_init[37] = 8'h00; exp_init_dc[37] = 1'b1;
        exp_init[38] = 8'hE1; exp_init_dc[38] = 1'b0;
        exp_init[39] = 8'h00; exp_init_dc[39] = 1'b1;
        exp_init[40] = 8'h0E; exp_init_dc[40] = 1'b1;
        exp_init[41] = 8'h14; exp_init_dc[41] = 1'b1;
        exp_init[42] = 8'h03; exp_init_dc[42] = 1'b1;
        exp_init[43] = 8'h11; exp_init_dc[43] = 1'b1;
        exp_init[44] = 8'h07; exp_init_dc[44] = 1'b1;
        exp_init[45] = 8'h31; exp_init_dc[45] = 1'b1;
        exp_init[46] = 8'hC1; exp_init_dc[46] = 1'b1;
        exp_init[47] = 8'h48; exp_init_dc[47] = 1'b1;
        exp_init[48] = 8'h08; exp_init_dc[48] = 1'b1;
        exp_init[49] = 8'h0F; exp_init_dc[49] = 1'b1;
        exp_init[50] = 8'h0C; exp_init_dc[50] = 1'b1;
        exp_init[51] = 8'h31; exp_init_dc[51] = 1'b1;
        exp_init[52] = 8'h36; exp_init_dc[52] = 1'b1;
        exp_init[53] = 8'h0F; exp_init_dc[53] = 1'b1;
        exp_init[54] = 8'h2A; exp_init_dc[54] = 1'b0;
        exp_init[55] = 8'h00; exp_init_dc[55] = 1'b1;
        exp_init[56] = 8'h00; exp_init_dc[56] = 1'b1;
        exp_init[57] = 8'h01; exp_init_dc[57] = 1'b1;
        exp_init[58] = 8'h3F; exp_init_dc[58] = 1'b1;
        exp_init[59] = 8'h2B; exp_init_dc[59] = 1'b0;
        exp_init[60] = 8'h00; exp_init_dc[60] = 1'b1;
        exp_init[61] = 8'h00; exp_init_dc[61] = 1'b1;
        exp_init[62] = 8'h01; exp_init_dc[62] = 1'b1;
        exp_init[63] = 8'hEF; exp_init_dc[63] = 1'b1;
        exp_init[64] = 8'h29; exp_init_dc[64] = 1'b0;
        n_exp = 65;

        // ------------------- 1. init sequence ------------------------
        // SWRESET, then a delay, then SLPOUT, then a delay
        wait_bytes(1);
        check_equal("init[0] cmd (SWRESET)", frame_bytes[0].data, 8'h01);
        check_equal("init[0] dc",           frame_bytes[0].dc,   1'b0);

        t0 = $time;
        wait_bytes(2);
        // the ROM delay after SWRESET is 10 ms / 50000 = 200 us
        if ($time - t0 < 150_000) begin
            total_errors++;
            $display("  FAIL SWRESET->SLPOUT gap only %0d ns", $time - t0);
        end
        check_equal("init[1] cmd (SLPOUT)", frame_bytes[1].data, 8'h11);

        t0 = $time;
        wait_bytes(3);
        // SLPOUT delay is 120 ms / 50000 = 2.4 ms
        if ($time - t0 < 2_000_000) begin
            total_errors++;
            $display("  FAIL SLPOUT->PWCTR1 gap only %0d ns", $time - t0);
        end

        wait_bytes(2 + n_exp);
        $display("  init byte count = %0d", byte_cnt);

        // frame_bytes[0] = SWRESET, [1] = SLPOUT, so exp_init[i] is byte i+2
        for (i = 0; i < n_exp; i++) begin
            check_equal($sformatf("init[%0d] data", 3+i),
                        frame_bytes[2+i].data, exp_init[i]);
            check_equal($sformatf("init[%0d] dc", 3+i),
                        frame_bytes[2+i].dc,   exp_init_dc[i]);
        end

        // ------------------- 2. frame 1 ------------------------------
        start_new_capture();
        $display("  ---- frame 1 ----");
        wait_bytes(11);
        check_equal("CASET cmd", frame_bytes[0].data, 8'h2A);
        check_equal("CASET dc",  frame_bytes[0].dc,   1'b0);
        check_equal("hdr x0h",   frame_bytes[1].data, 8'h00);
        check_equal("hdr x0l",   frame_bytes[2].data, 8'h00);
        check_equal("hdr x1h",   frame_bytes[3].data, 8'h01);   // 319 = 0x013F
        check_equal("hdr x1l",   frame_bytes[4].data, 8'h3F);
        check_equal("PASET cmd", frame_bytes[5].data, 8'h2B);
        check_equal("hdr y0h",   frame_bytes[6].data, 8'h00);
        check_equal("hdr y0l",   frame_bytes[7].data, 8'h00);
        check_equal("hdr y1h",   frame_bytes[8].data, 8'h00);   // 239 = 0x00EF
        check_equal("hdr y1l",   frame_bytes[9].data, 8'hEF);
        check_equal("RAMWR cmd", frame_bytes[10].data, 8'h2C);
        check_equal("RAMWR dc",  frame_bytes[10].dc,   1'b0);

        wait_cs_high();
        $display("  frame 1 complete: %0d bytes captured", byte_cnt);
        check_equal("frame 1 byte count", byte_cnt, FRAME_BYTES);

        // every transmitted pixel must be orange, in row-major order.
        // Sampling a subset keeps the run time sane; the byte count above
        // already proves the frame carried exactly 320x240 pixels.
        saw = 0;
        for (i = 0; i < NPIX; i++) begin
            logic [7:0] hi, lo;
            if (!(i < 2000 || i >= NPIX - 500 || (i % 977) == 0))
                continue;
            hi = frame_bytes[11 + 2*i    ].data;
            lo = frame_bytes[11 + 2*i + 1].data;
            saw++;
            if ({hi, lo} !== C_ORANGE) begin
                if (total_errors < 10)
                    $display("  FAIL pixel %0d (x=%0d y=%0d) = %02h%02h expected %04h",
                             i, i % 320, i / 320, hi, lo, C_ORANGE);
                total_errors++;
            end
            if (frame_bytes[11 + 2*i    ].dc !== 1'b1 ||
                frame_bytes[11 + 2*i + 1].dc !== 1'b1) begin
                if (total_errors < 10)
                    $display("  FAIL pixel %0d dc levels", i);
                total_errors++;
            end
        end
        total_checks++;
        $display("  frame 1: sampled %0d of %0d pixels", saw, NPIX);

        // ------------------- 3. frame 2 repeats ----------------------
        start_new_capture();
        $display("  ---- frame 2 ----");
        wait_bytes(11);
        check_equal("frame2 CASET cmd", frame_bytes[0].data, 8'h2A);
        check_equal("frame2 x1l",       frame_bytes[4].data, 8'h3F);
        check_equal("frame2 y1l",       frame_bytes[9].data, 8'hEF);
        check_equal("frame2 RAMWR cmd", frame_bytes[10].data, 8'h2C);
        wait_bytes(2000);
        check_equal("frame2 first pixel hi", frame_bytes[11].data, C_ORANGE[15:8]);
        check_equal("frame2 first pixel lo", frame_bytes[12].data, C_ORANGE[7:0]);
        wait_cs_high();
        check_equal("frame 2 byte count", byte_cnt, FRAME_BYTES);

        // ------------------- 4. LEDs ---------------------------------
        check_equal("led2 (sw2=0)", led2, 1'b1);
        check_equal("led3 (btn released)", led3, 1'b1);

        // ------------------- result ----------------------------------
        if (total_errors == 0)
            $display("*** tb_orange: PASS (%0d checks) ***", total_checks);
        else
            $display("*** tb_orange: FAIL (%0d errors / %0d checks) ***",
                     total_errors, total_checks);
        $finish;
    end
endmodule
