// tb_orange.sv
//
// End-to-end check of the design over real SPI: a 320x240 1-bit frame buffer
// shown on the panel, with the Step 3 playfield of red horizontal lines and
// the Step 4 moving line on top of it.
//
//   1. after reset the panel receives the ILI9341 init sequence
//      (SWRESET, SLPOUT, MADCTL, COLMOD, DISPON, ...) as SPI bytes with the
//      right D/C levels and the right inter-command delays
//   2. every frame request produces
//          CASET 00 00 01 3F  PASET 00 00 00 EF  RAMWR
//      followed by exactly 320*240 RGB565 pixels, row major
//   3. every pixel is the orange background EXCEPT the playfield lines and
//      the pixels the moving line has reached, which are red. The nine line
//      rows are checked across their FULL width, so a line that is too long,
//      too short or on the wrong row shows up.
//   4. the next frame request repeats the same transfer
//   5. the moving line is actually growing (it has drawn at least a few dots
//      by the time the first frame is scanned out, and LED0 is lit)
//
// Time scale: the design's millisecond delays are scaled down via MS_SCALE so
// the test runs in a reasonable time. The SPI side is NOT scaled: it runs at
// the real clk/4 = 12.5 MHz, so one frame still takes ~113 ms of simulated
// time, which is where most of the run time goes.
//
// IMPORTANT: MS_SCALE scales the design's own millisecond delays, but NOT the
// game's dot period (that has its own STEP_MS parameter). The test passes
// STEP_MS = 1, so with MS_SCALE = 5 a dot takes 1000 clocks = 20 us and the
// whole game (23 dots before it collides with the playfield) is over in
// ~0.5 ms - long before the panel init finishes (~3 ms). The image scanned out
// is therefore STATIC and can be compared against the reference model exactly.
// The real 10 ms dot period is covered by the timing check in tb_game.
`timescale 1ns/1ps

module tb_orange;
    localparam int CLK_HZ        = 50_000_000;
    // SCK = clk * DEN / (2*NUM); 2/1 reproduces the old integer divider clk/4.
    // Keep it here so this testbench's timing model is unchanged.
    localparam int SCLK_NUM      = 2;                    // SCK = clk/4 = 12.5 MHz
    localparam int SCLK_DEN      = 1;
    localparam int MS_SCALE_TB   = 5;                    // 1 ms -> 200 us
    localparam int MS_CYCLES     = (CLK_HZ/1000)/MS_SCALE_TB;   // 10000 clk
    localparam int CYCLE_NS      = 20;                   // 50 MHz
    localparam int FRAME_MS_TB   = 1;

    localparam int NPIX          = 320*240;
    localparam int FRAME_BYTES   = 11 + 2*NPIX;

    localparam logic [15:0] C_BG   = 16'hFD20;           // orange background
    localparam logic [15:0] C_LINE = 16'hF800;           // red line

    // the playfield table under test, same as lcd_test_top's defaults
    localparam int N_LINES = 9;
    localparam int T_X0 [N_LINES] = '{  0,  40,   0,  40,   0,  40,   0,  40,   0};
    localparam int T_X1 [N_LINES] = '{279, 319, 279, 319, 279, 319, 279, 319, 279};
    localparam int T_Y  [N_LINES] = '{ 25,  50,  75, 100, 125, 150, 175, 200, 225};

    // ---- the moving line ------------------------------------------
    // The game starts at (1,1) and, with the button released, moves one dot
    // down-right per STEP_MS. STEP_MS=1 with MS_SCALE=5 gives 20 us per dot,
    // so the game is over long before the first frame is scanned out and the
    // image is static:
    //
    //   the START pixel (1,1) is tested and drawn as part of the line
    //   dot k     then targets (START_X+k, START_Y+k)
    //   the first target on the playfield line y=25 is (25,25), so (1,1)..(24,24)
    //   are drawn (24 pixels: 1 start + 23 moves) and the game stops there
    localparam int FIRST_DOT = 1;
    localparam int LAST_DOT  = 24;
    localparam int N_DOTS    = LAST_DOT - FIRST_DOT + 1;   // 24
    localparam int COLL_X    = 25;
    localparam int COLL_Y    = 25;

    function automatic bit on_playfield(input int px, input int py);
        on_playfield = 1'b0;
        for (int k = 0; k < N_LINES; k++)
            if (py == T_Y[k] && px >= T_X0[k] && px <= T_X1[k]) on_playfield = 1'b1;
    endfunction

    // the moving line is the diagonal (k,k) for k = FIRST_DOT .. LAST_DOT
    function automatic bit on_moving(input int px, input int py);
        on_moving = (px == py) && (px >= FIRST_DOT) && (px <= LAST_DOT);
    endfunction

    // anything drawn is red; everything else is the orange background
    function automatic bit should_be_red(input int px, input int py);
        should_be_red = on_playfield(px, py) || on_moving(px, py);
    endfunction

    function automatic bit on_any_line_row(input int py);
        on_any_line_row = 1'b0;
        for (int k = 0; k < N_LINES; k++)
            if (py == T_Y[k]) on_any_line_row = 1'b1;
    endfunction

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
        .SCLK_HALF_NUM   (SCLK_NUM),
        .SCLK_HALF_DEN   (SCLK_DEN),
        .MS_SCALE        (MS_SCALE_TB),
        .MADCTL_VALUE    (8'h28),
        .STEP_MS         (1),              // shrink the dot period for the test
        .LOCK_TO_FRAME   (1'b0),           // keep an exact 1 ms dot period
        .START_X         (1),
        .START_Y         (1),
        .N_LINES         (N_LINES),
        .LINE_X0         (T_X0),
        .LINE_X1         (T_X1),
        .LINE_Y          (T_Y),
        .COLOR_BIT0      (C_BG),
        .COLOR_BIT1      (C_LINE)
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
    int    nbad_bg;
    int    nbad_line;
    int    nbad_dot;
    int    nbad_gap;
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

        // Sample pixels: every sampled pixel must match the reference model,
        // which is the playfield plus the moving diagonal. The nine playfield
        // rows are checked across their FULL width (both the drawn and the
        // not-drawn part) AND the moving diagonal is checked dot by dot, so a
        // line that is too long/short/on the wrong row and a moving line that
        // grew the wrong way both show up. A spread of other rows proves the
        // rest of the panel is untouched.
        saw   = 0;
        nbad_bg   = 0;
        nbad_line = 0;
        nbad_dot  = 0;
        nbad_gap  = 0;
        for (i = 0; i < NPIX; i++) begin
            logic [7:0] hi, lo;
            int         px, py;
            logic [15:0] got, exp;
            bit         red, is_row, is_dot, is_gap;
            px = i % 320;
            py = i / 320;

            is_row = on_playfield(px, py) || on_any_line_row(py);
            is_dot = on_moving(px, py) ||
                     (px == py && (px == LAST_DOT+1));
            // the two diagonals that must NOT be drawn: just before the start
            // pixel and the colliding dot
            is_gap = !should_be_red(px, py) && (px == py) &&
                     ((px == COLL_X) || (px == FIRST_DOT-1));
            red    = should_be_red(px, py);

            if (!(is_row || is_dot || is_gap || (i % 977) == 0))
                continue;

            hi  = frame_bytes[11 + 2*i    ].data;
            lo  = frame_bytes[11 + 2*i + 1].data;
            got = {hi, lo};
            saw++;

            exp = red ? C_LINE : C_BG;

            if (!red) begin
                if (got !== exp) begin
                    if (nbad_bg < 5)
                        $display("  FAIL bg pixel (%0d,%0d) = %04h expected %04h",
                                 px, py, got, exp);
                    // the two diagonals just outside the moving line are the
                    // interesting ones: the start head must not be drawn and
                    // the colliding dot must not be drawn
                    if (is_gap) nbad_gap++;
                    nbad_bg++;
                end
            end else if (on_moving(px, py)) begin
                if (got !== exp) begin
                    if (nbad_dot < 5)
                        $display("  FAIL moving dot (%0d,%0d) = %04h expected %04h",
                                 px, py, got, exp);
                    nbad_dot++;
                end
            end else begin
                if (got !== exp) begin
                    if (nbad_line < 5)
                        $display("  FAIL line pixel (%0d,%0d) = %04h expected %04h",
                                 px, py, got, exp);
                    nbad_line++;
                end
            end

            if (frame_bytes[11 + 2*i].dc !== 1'b1 ||
                frame_bytes[11 + 2*i + 1].dc !== 1'b1) begin
                if (total_errors < 10)
                    $display("  FAIL pixel %0d dc levels", i);
                total_errors++;
            end
        end
        total_checks += 4;
        if (nbad_line != 0) begin
            total_errors++;
            $display("  FAIL %0d playfield pixels were not red", nbad_line);
        end
        if (nbad_dot != 0) begin
            total_errors++;
            $display("  FAIL %0d moving-line pixels were not drawn", nbad_dot);
        end
        if (nbad_gap != 0) begin
            total_errors++;
            $display("  FAIL %0d pixels were drawn that should be orange (start head / collision dot)",
                     nbad_gap);
        end
        if (nbad_bg != 0) begin
            total_errors++;
            $display("  FAIL %0d pixels outside a line were not orange", nbad_bg);
        end
        $display("  frame 1: sampled %0d of %0d pixels (playfield rows full width + the moving diagonal)",
                 saw, NPIX);
        $display("  moving line: %0d pixels (1,1)..(%0d,%0d), GAME OVER at (%0d,%0d)",
                 N_DOTS, LAST_DOT, LAST_DOT, COLL_X, COLL_Y);

        // the head must be sitting on the colliding dot and the game must have
        // stopped: check LED0 (playfield done / game running, active low) and
        // LED2 (GAME OVER, active low)
        check_equal("led0 (playfield + game)", led0, 1'b0);
        check_equal("led2 (GAME OVER)",        led2, 1'b0);
        if (dut.dot_x !== COLL_X || dut.dot_y !== COLL_Y) begin
            total_errors++;
            $display("  FAIL game head at (%0d,%0d), expected (%0d,%0d)",
                     dut.dot_x, dut.dot_y, COLL_X, COLL_Y);
        end else begin
            total_checks++;
        end
        if (dut.game_over !== 1'b1) begin
            total_errors++;
            $display("  FAIL game_over is not set");
        end else begin
            total_checks++;
        end

        // ------------------- 3. frame 2 repeats ----------------------
        start_new_capture();
        $display("  ---- frame 2 ----");
        wait_bytes(11);
        check_equal("frame2 CASET cmd", frame_bytes[0].data, 8'h2A);
        check_equal("frame2 x1l",       frame_bytes[4].data, 8'h3F);
        check_equal("frame2 y1l",       frame_bytes[9].data, 8'hEF);
        check_equal("frame2 RAMWR cmd", frame_bytes[10].data, 8'h2C);
        wait_bytes(11 + 2*NPIX);
        wait_cs_high();
        check_equal("frame 2 byte count", byte_cnt, FRAME_BYTES);

        // spot-check the lines in the second frame too: a pixel inside line 0
        // must be red, a pixel in the 40 px gap to its right must be orange,
        // and the row just above the line must be orange as well
        begin
            int off_l1, off_l2, off_gap, off_above;
            off_l1    = 11 + 2*(T_Y[0]*320 + 160);      // inside line 0
            off_l2    = 11 + 2*(T_Y[1]*320 + 300);      // inside line 1 (40..319)
            off_gap   = 11 + 2*(T_Y[0]*320 + 290);      // right of line 0 (ends 279)
            off_above = 11 + 2*((T_Y[0]-1)*320 + 160);  // one row above line 0
            check_equal("frame2 line0 pixel hi", frame_bytes[off_l1  ].data, C_LINE[15:8]);
            check_equal("frame2 line0 pixel lo", frame_bytes[off_l1+1].data, C_LINE[7:0]);
            check_equal("frame2 line1 pixel hi", frame_bytes[off_l2  ].data, C_LINE[15:8]);
            check_equal("frame2 line1 pixel lo", frame_bytes[off_l2+1].data, C_LINE[7:0]);
            check_equal("frame2 gap pixel hi",   frame_bytes[off_gap  ].data, C_BG[15:8]);
            check_equal("frame2 gap pixel lo",   frame_bytes[off_gap+1].data, C_BG[7:0]);
            check_equal("frame2 bg pixel hi",    frame_bytes[off_above ].data, C_BG[15:8]);
            check_equal("frame2 bg pixel lo",    frame_bytes[off_above+1].data, C_BG[7:0]);
        end

        // ------------------- 4. LEDs ---------------------------------
        // LED2 (GAME OVER) and LED0 (playfield done) are checked right after
        // frame 1, while the game is still running. Here only the button LED
        // is left, and it must be off because the test never presses it.
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
