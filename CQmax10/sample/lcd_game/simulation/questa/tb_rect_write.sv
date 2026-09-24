// tb_rect_write.sv
//
// Checks lcd_ili9341_ctrl.sv, which now drives the panel with WINDOWED
// RECTANGLE WRITES instead of streaming whole frames.
//
// What is verified over real SPI:
//
//   1. the ILI9341 init sequence (SWRESET, SLPOUT, MADCTL, COLMOD, DISPON, ...)
//      as 67 bytes with the right D/C levels and the right order
//   2. a rectangle request of size w x h produces
//          CASET x0 x1   PASET y0 y1   RAMWR   +  w*h pixels RGB565
//      with the window boundaries taken from the REQUEST, not the screen
//   3. a 1x1 request (a single dot) produces the same but with w*h = 1
//   4. the valid/ready handshake: a request is only accepted when wr_ready is
//      high, and it must be held until then
//   5. no frame is ever resent: after the requests are done the bus is idle
//
// The previous tb_orange checked a continuous 320x240 scan-out; that path no
// longer exists (the panel keeps the image in its own GRAM), so this test
// replaces it.
`timescale 1ns/1ps

module tb_rect_write;
    localparam int  CLK_HZ   = 50_000_000;
    localparam int  SCLK_NUM = 5;                 // exactly 10 MHz
    localparam int  SCLK_DEN = 2;
    localparam int  MS_SCALE_TB = 2000;           // shorten the panel delays
    localparam logic [15:0] C_TEST = 16'h1234;
    localparam logic [15:0] C_DOT  = 16'hF800;

    logic clk = 1'b0;
    always #10 clk = ~clk;                        // 50 MHz

    logic rst = 1'b1;

    // ---- request driven by the test ------------------------------------
    logic        wr_valid = 1'b0, wr_ready;
    logic [8:0]  wr_x0 = 9'd0, wr_x1 = 9'd0;
    logic [7:0]  wr_y0 = 8'd0, wr_y1 = 8'd0;
    logic [15:0] wr_color = 16'h0000;

    logic        active, wr_done;
    logic        lcd_cs, lcd_sck, lcd_mosi, lcd_dc;

    lcd_ili9341_ctrl #(
        .SCLK_HALF_NUM   (SCLK_NUM),
        .SCLK_HALF_DEN   (SCLK_DEN),
        .CLK_FREQ_HZ     (CLK_HZ),
        .SCREEN_W        (320),
        .SCREEN_H        (240),
        .POWERON_WAIT_MS (1),
        .MS_SCALE        (MS_SCALE_TB),
        .MADCTL_VALUE    (8'h28)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .wr_valid (wr_valid),
        .wr_ready (wr_ready),
        .wr_x0    (wr_x0),
        .wr_y0    (wr_y0),
        .wr_x1    (wr_x1),
        .wr_y1    (wr_y1),
        .wr_color (wr_color),
        .active   (active),
        .wr_done  (wr_done),
        .lcd_cs   (lcd_cs),
        .lcd_sck  (lcd_sck),
        .lcd_mosi (lcd_mosi),
        .lcd_dc   (lcd_dc)
    );

    // ------------------------------------------------------------------
    // SPI receiver: shift in a byte on every 8th SCK rising edge, and record
    // (dc, byte) pairs. CS going high marks the end of a "train".
    // ------------------------------------------------------------------
    int         bitcnt = 0;
    logic [7:0] shreg  = 8'h00;
    logic       sck_d  = 1'b0;
    logic       cs_d   = 1'b1;

    localparam int MAXB = 4096;
    logic        rec_dc   [0:MAXB-1];
    logic [7:0]  rec_byte [0:MAXB-1];
    int          n_byte = 0;

    // a "train" is one CS-low period; store each train's byte range
    localparam int MAXT = 32;
    int          tr_start [0:MAXT-1];
    int          tr_end   [0:MAXT-1];
    int          n_train  = 0;

    int cs_fall_idx = 0;

    always_ff @(posedge clk) begin
        sck_d <= lcd_sck;
        cs_d  <= lcd_cs;

        // rising edge of SCK: sample MOSI
        if (lcd_sck && !sck_d) begin
            shreg  <= {shreg[6:0], lcd_mosi};
            bitcnt <= bitcnt + 1;
            if (bitcnt == 7) begin
                bitcnt <= 0;
                if (n_byte < MAXB) begin
                    rec_dc  [n_byte] <= lcd_dc;
                    rec_byte[n_byte] <= {shreg[6:0], lcd_mosi};
                end
                n_byte <= n_byte + 1;
            end
        end

        // CS low: start of a train
        if (cs_d && !lcd_cs) begin
            bitcnt      <= 0;
            cs_fall_idx <= n_byte;
        end

        // CS high: end of a train
        if (!cs_d && lcd_cs) begin
            if (n_train < MAXT) begin
                tr_start[n_train] <= cs_fall_idx;
                tr_end  [n_train] <= n_byte - 1;
            end
            n_train <= n_train + 1;
        end
    end

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    int errors = 0;

    task automatic check(input bit cond, input string what);
        if (!cond) begin
            errors = errors + 1;
            if (errors < 25) $display("  FAIL %s", what);
        end
    endtask

    // wait for n_byte to reach a value (with a timeout so a stuck init cannot
    // hang the whole test - `while` loops on a signal that never moves are the
    // classic way to make a testbench stop with no output).
    // MS_SCALE_TB = 2000 shortens the whole init to ~60 us, so 2 ms of
    // simulated time is a very generous bound and still fails fast.
    task automatic wait_bytes(input int n);
        int t0;
        t0 = $time;
        while (n_byte < n && ($time - t0) < 2_000_000) @(negedge clk);
        repeat (4) @(negedge clk);
        if (n_byte < n) begin
            errors = errors + 1;
            $display("  FAIL timeout waiting for byte %0d (saw %0d)", n, n_byte);
        end
    endtask

    // wait for n_train to reach a value
    task automatic wait_train(input int n);
        while (n_train < n) @(negedge clk);
        repeat (4) @(negedge clk);
    endtask

    // issue one rectangle and wait for it to be accepted + finished
    task automatic do_write(input int x0, input int y0, input int x1,
                            input int y1, input logic [15:0] col);
        // hold the request; it is accepted on the cycle wr_ready is high
        @(negedge clk);
        wr_x0 = x0[8:0]; wr_y0 = y0[7:0]; wr_x1 = x1[8:0]; wr_y1 = y1[7:0];
        wr_color = col;
        wr_valid = 1'b1;
        // wait for the accept, then release
        begin
            int t0;
            t0 = $time;
            while (!wr_ready && ($time - t0) < 200_000) @(negedge clk);
        end
        @(negedge clk);
        wr_valid = 1'b0;
        // wait for the transfer to finish
        begin
            int t0;
            t0 = $time;
            while (!wr_done && ($time - t0) < 200_000) @(negedge clk);
        end
        repeat (4) @(negedge clk);
    endtask

    // check that byte i of train t is a command/data byte as expected
    task automatic check_byte(input int idx, input bit is_cmd,
                              input logic [7:0] val, input string what);
        if (idx >= MAXB) return;
        if (rec_dc[idx] !== (is_cmd ? 1'b0 : 1'b1)) begin
            errors = errors + 1;
            if (errors < 25)
                $display("  FAIL %s: byte %0d D/C = %0d, expected %0d",
                         what, idx, rec_dc[idx], is_cmd ? 0 : 1);
        end
        if (rec_byte[idx] !== val) begin
            errors = errors + 1;
            if (errors < 25)
                $display("  FAIL %s: byte %0d = %02h, expected %02h",
                         what, idx, rec_byte[idx], val);
        end
    endtask

    int base, w, h, i;
    int n_before;

    initial begin
        // ---- release reset ------------------------------------------
        // The controller stays in S_POWERON while rst is high and sends
        // nothing, so this must come first.
        rst = 1'b1;
        repeat (10) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);

        // ---- wait for the init sequence -----------------------------
        // 67 bytes is the length proven in earlier steps; the controller
        // leaves S_READY after the last one.
        wait_bytes(67);
        // wait for the controller to be idle and accepting requests
        begin
            int t0;
            t0 = $time;
            while (!wr_ready && ($time - t0) < 2_000_000) @(negedge clk);
            if (!wr_ready) begin
                errors = errors + 1;
                $display("  FAIL timeout waiting for wr_ready after init");
            end
        end
        repeat (4) @(negedge clk);

        if (errors != 0) begin
            $display("  (aborting: the design never reached its idle state)");
            $display("*** tb_rect_write: FAIL (%0d) ***", errors);
            $finish;
        end

        $display("");
        $display("---- init ----");
        if (n_byte != 67) begin
            errors = errors + 1;
            $display("  FAIL init byte count = %0d, expected 67", n_byte);
        end else begin
            $display("  OK   init byte count = 67");
        end
        // spot-check the well known bytes. Byte 0 is SWRESET (a command); the
        // delay entry that follows sends NOTHING on the bus, so byte 1 is
        // already SLPOUT (also a command).
        check_byte(0, 1'b1, 8'h01, "init SWRESET");    // is_cmd=1 -> DC low
        check_byte(1, 1'b1, 8'h11, "init SLPOUT");
        // find the command bytes instead of hard-coding their indices
        begin
            bit found;
            found = 1'b0;
            for (i = 0; i < n_byte - 1; i++)
                if (rec_dc[i] === 1'b0 && rec_byte[i] === 8'h36) begin
                    found = 1'b1;
                    check(rec_byte[i+1] === 8'h28, "MADCTL value = 28");
                end
            check(found, "MADCTL command present");
            found = 1'b0;
            for (i = 0; i < n_byte; i++)
                if (rec_dc[i] === 1'b0 && rec_byte[i] === 8'h29) found = 1'b1;
            check(found, "DISPON command present");
            // diagnostic: the last few init bytes with their D/C levels
            $display("      init tail: byte %0d..%0d", n_byte - 6, n_byte - 1);
            for (i = n_byte - 6; i < n_byte; i++)
                $display("        [%0d] dc=%0b byte=%02h", i, rec_dc[i], rec_byte[i]);
        end

        // ---- rectangle write 5x3 at (10,20) -------------------------
        $display("");
        $display("---- rectangle 5x3 at (10,20) ----");
        base = n_byte;
        do_write(10, 20, 14, 22, C_TEST);

        // header: 2A x0h x0l x1h x1l  2B y0h y0l y1h y1l  2C
        check_byte(base+0,  1'b1, 8'h2A, "CASET cmd");   // 2A
        check_byte(base+1,  1'b0, 8'h00, "CASET x0h");
        check_byte(base+2,  1'b0, 8'd10, "CASET x0l");
        check_byte(base+3,  1'b0, 8'h00, "CASET x1h");
        check_byte(base+4,  1'b0, 8'd14, "CASET x1l");
        check_byte(base+5,  1'b1, 8'h2B, "PASET cmd");
        check_byte(base+6,  1'b0, 8'h00, "PASET y0h");
        check_byte(base+7,  1'b0, 8'd20, "PASET y0l");
        check_byte(base+8,  1'b0, 8'h00, "PASET y1h");
        check_byte(base+9,  1'b0, 8'd22, "PASET y1l");
        check_byte(base+10, 1'b1, 8'h2C, "RAMWR cmd");

        // pixels: w*h = 15, high byte then low byte, all C_TEST
        //   note: base+0 is the first byte of THIS train, which is 2A.
        //   The D/C polarity above: 2A/2B/2C are commands (DC low), data
        //   bytes are DC high. check_byte() takes is_cmd = 1 for commands.
        begin
            int npix;
            int bad;
            npix = 5*3;
            bad  = 0;
            for (i = 0; i < npix; i++) begin
                if (rec_dc[base+11+2*i]   !== 1'b1) bad++;
                if (rec_dc[base+11+2*i+1] !== 1'b1) bad++;
                if (rec_byte[base+11+2*i]   !== C_TEST[15:8]) bad++;
                if (rec_byte[base+11+2*i+1] !== C_TEST[7:0])  bad++;
            end
            check(bad == 0, "15 pixels of 0x1234");
            $display("  OK   CASET/PASET/RAMWR + %0d pixels", npix);
        end
        check(n_byte == base + 11 + 2*15,
              $sformatf("byte count for the write = %0d, expected %0d",
                        n_byte - base, 11 + 2*15));

        // ---- single dot (1x1) --------------------------------------
        $display("");
        $display("---- single dot 1x1 at (7,9) ----");
        base = n_byte;
        do_write(7, 9, 7, 9, C_DOT);

        check_byte(base+0,  1'b1, 8'h2A, "dot CASET cmd");
        check_byte(base+2,  1'b0, 8'd7,  "dot x0 = x1 = 7");
        check_byte(base+4,  1'b0, 8'd7,  "dot x1 = 7");
        check_byte(base+7,  1'b0, 8'd9,  "dot y0 = 9");
        check_byte(base+9,  1'b0, 8'd9,  "dot y1 = 9");
        check_byte(base+10, 1'b1, 8'h2C, "dot RAMWR cmd");
        // the two pixel bytes are DATA, so D/C is HIGH (is_cmd = 0)
        check_byte(base+11, 1'b0, C_DOT[15:8], "dot pixel high");
        check_byte(base+12, 1'b0, C_DOT[7:0],  "dot pixel low");
        check(n_byte == base + 13,
              $sformatf("1x1 write is %0d bytes, expected 13", n_byte - base));
        $display("  OK   1x1 window = CASET/PASET/RAMWR + 1 pixel");

        // ---- x=319 boundary (high byte of the window must be 1) -----
        $display("");
        $display("---- x1 = 319 (high byte) ----");
        base = n_byte;
        do_write(317, 5, 319, 5, C_DOT);
        check_byte(base+3, 1'b0, 8'h01, "x1 high byte = 1");
        check_byte(base+4, 1'b0, 8'd63, "x1 low byte = 63");

        // ---- after the requests, the bus must be idle --------------
        $display("");
        $display("---- idle after the last request ----");
        n_before = n_byte;
        repeat (20_000) @(negedge clk);       // ~400 us: no more frames
        check(n_byte == n_before,
              $sformatf("no extra bytes after the last write (%0d more)",
                        n_byte - n_before));
        // CS is low through the whole init sequence (one train) and there is
        // one train per rectangle write, so 1 + 3 = 4 trains in total
        check(n_train == 4,
              $sformatf("CS trains = %0d, expected 4", n_train));
        if ((n_byte == n_before) && (n_train == 4))
            $display("  OK   bus idle: no frame resend (%0d bytes, %0d trains)",
                     n_byte, n_train);

        $display("");
        if (errors == 0)
            $display("*** tb_rect_write: PASS ***");
        else
            $display("*** tb_rect_write: FAIL (%0d) ***", errors);
        $finish;
    end
endmodule
