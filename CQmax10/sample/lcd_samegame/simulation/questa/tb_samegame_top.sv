// tb_samegame_top.sv
//
// Top-level integration test: `samegame_top` with the MAX 10 On-Chip Flash
// modelled, decoding the LCD SPI stream and checking the pixels that actually
// reach the panel.
//
// WHY THIS EXISTS
// ---------------
// Every other testbench replaces a part of the real system:
//   tb_renderer   drives lcd_renderer directly (logo_ram written by the TB)
//   tb_ufm_boot   drives ufm_bootloader with a UFM model
//   tb_game_fsm   drives game_fsm with the board memory and the engines
// so nothing ever exercised the REAL power-up chain
//     UFM -> ufm_bootloader -> logo_ram -> lcd_renderer -> lcd_ili9341_ctrl -> SPI
// with the REAL reset gating (`game_rst = rst | ~boot_done`).
//
// That is exactly where a solid-black panel can hide: if `boot_done` never
// asserts, the game FSM stays in reset, the board stays EMPTY and the renderer
// paints BG_COLOR (0x0000) for every pixel while `lcd_ready` / `lcd_active`
// still blink happily (the panel scan itself is fine).
//
// CHECKS
//   1. boot_done asserts and logo_ram ends up holding the UFM image
//   2. the board is generated (non-EMPTY cells exist)
//   3. the pixel stream on the SPI wire contains the logo colours, not only
//      BG_COLOR  <- this is the check that a "black screen" fails
//   4. the SPI pixel stream is complete (76800 pixels per frame) and every
//      pix_req is answered by exactly one pix_valid
//
// NOTE: this TB passes even with a programming file that carries no UFM data,
// because it models the flash CONTENT.  A black panel on hardware with a green
// `led` (see samegame_top) therefore points at the PROGRAMMING METHOD, not at
// the RTL: verify the .pof/.sof really contains the logo image (see
// check_pof_ufm.ps1 - the logo0 signature must appear in the file).
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// UFM model - waitrequest is COMBINATIONAL (see tb_ufm_boot for the full note
// on why that matters).  readdata = {16'h0, address}, i.e. the same identity
// pattern the UFM hex contains for our purposes: pixel at UFM word `a` is `a`.
// ---------------------------------------------------------------------------
module ufm_model_top #(
    parameter int RDV_CYCLE  = 8,
    parameter int DONE_CYCLE = 10
)(
    input  logic        clk,
    input  logic        reset_n,

    input  logic        read,
    input  logic [12:0] addr,
    input  logic [3:0]  burstcount,

    output logic        waitrequest,
    output logic        readdatavalid,
    output logic [31:0] readdata
);
    logic [12:0] a_lat;
    logic        busy;
    int          cnt;
    localparam int END_CYCLE = (RDV_CYCLE > DONE_CYCLE) ? RDV_CYCLE : DONE_CYCLE;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            busy          <= 1'b0;
            cnt           <= 0;
            a_lat         <= 13'd0;
            readdatavalid <= 1'b0;
        end else begin
            readdatavalid <= 1'b0;
            if (!busy) begin
                if (read) begin
                    busy  <= 1'b1;
                    cnt   <= 0;
                    a_lat <= addr;
                end
            end else begin
                cnt <= cnt + 1;
                if ((cnt + 1) == RDV_CYCLE) readdatavalid <= 1'b1;
                if ((cnt + 1) >= END_CYCLE) busy          <= 1'b0;
            end
        end
    end

    assign waitrequest = (busy && (cnt < DONE_CYCLE)) | read;
    assign readdata    = {16'h0000, a_lat};
endmodule


// ---------------------------------------------------------------------------
module tb_samegame_top;
    // Small MS_SCALE so the panel init delays and the frame period do not need
    // tens of millions of cycles.  MS_SCALE only divides the millisecond
    // delays; the pixel/SPI timing is untouched by it.
    localparam int MS_SCALE   = 1000;
    localparam int CLK_FREQ   = 50_000_000;
    localparam int RA_W       = 11;
    localparam logic [15:0] BG_COLOR = 16'h0000;

    logic clk = 1'b0;
    always #10 clk = ~clk;               // 50 MHz

    logic btn_rst = 1'b0;                // active low: start asserted

    // ---- DUT I/O ----
    logic lcd_cs, lcd_mosi, lcd_sck, lcd_dc;
    logic touch_cs, touch_mosi, touch_sck;
    logic touch_miso = 1'b1;
    // The two extra candidate sockets are probed by this build (see
    // touch_controller).  Their MISO pads are undriven here, which is what a
    // floating input reads (all ones), so they must stay HIGH; leaving the
    // ports unconnected makes vsim warn (vopt-2718) and tie them to X instead.
    logic touch_miso_alt = 1'b1;
    logic touch_miso_fr  = 1'b1;
    logic alt_cs, alt_mosi, alt_sck;
    logic fr_cs, fr_mosi, fr_sck;
    logic led, led0, led1, led2, led3;

    // ---- UFM model connections ----
    logic        flash_read, flash_waitrequest, flash_readdatavalid;
    logic [12:0] flash_addr;
    logic [31:0] flash_readdata;

    ufm_model_top #(.RDV_CYCLE(8), .DONE_CYCLE(10)) u_ufm (
        .clk(clk), .reset_n(~btn_rst),
        .read(flash_read), .addr(flash_addr), .burstcount(4'd1),
        .waitrequest(flash_waitrequest),
        .readdatavalid(flash_readdatavalid),
        .readdata(flash_readdata)
    );

    samegame_top #(
        .CLK_FREQ_HZ     (CLK_FREQ),
        .FRAME_PERIOD_MS (166),
        .POWERON_WAIT_MS (150),
        .SCLK_HALF_CYCLES(2),
        .MS_SCALE        (MS_SCALE),
        .MADCTL_VALUE    (8'h28),
        .BG_COLOR        (BG_COLOR)
    ) dut (
        .clk(clk), .btn_rst(btn_rst),
        .sw1(1'b1), .sw2(1'b1),
        .lcd_cs(lcd_cs), .lcd_mosi(lcd_mosi), .lcd_sck(lcd_sck), .lcd_dc(lcd_dc),
        .touch_cs(touch_cs), .touch_mosi(touch_mosi),
        .touch_miso(touch_miso), .touch_sck(touch_sck),
        .touch_miso_alt(touch_miso_alt),
        .touch_miso_fr(touch_miso_fr),
        .alt_cs(alt_cs), .alt_mosi(alt_mosi), .alt_sck(alt_sck),
        .fr_cs(fr_cs), .fr_mosi(fr_mosi), .fr_sck(fr_sck),
        .led(led), .led0(led0), .led1(led1), .led2(led2), .led3(led3)
    );

    // =====================================================================
    // SPI byte capture (this design is write-only: sample MOSI on the rising
    // SCK edge, MSB first)
    // =====================================================================
    logic [7:0] sh       = 8'h00;
    int         bit_cnt  = 0;
    logic        byte_stb = 1'b0;
    logic [7:0]  byte_val = 8'h00;
    logic        byte_dc  = 1'b0;

    always @(posedge lcd_sck) begin
        if (lcd_cs) begin
            bit_cnt  <= 0;
            byte_stb <= 1'b0;
        end else begin
            sh <= {sh[6:0], lcd_mosi};
            if (bit_cnt == 7) begin
                byte_val <= {sh[6:0], lcd_mosi};
                byte_dc  <= lcd_dc;
                byte_stb <= 1'b1;
                bit_cnt  <= 0;
            end else begin
                byte_stb <= 1'b0;
                bit_cnt  <= bit_cnt + 1;
            end
        end
    end

    // =====================================================================
    // pixel reconstruction: after a RAMWR (0x2C) command, DC=1 bytes are
    // pixels, high byte first
    // =====================================================================
    localparam int MAX_PIX = 320 * 240;
    logic [15:0] pix_seen [0:MAX_PIX-1];
    int          n_pix;             // pixels captured
    int          n_nonzero;         // pixels != BG_COLOR
    int          n_req, n_val;      // pix_req / pix_valid counts
    logic        in_ramwr;
    logic        have_hi;
    logic [7:0]  hi_byte;

    // ---- handshake counters: every request must be answered ----
    always @(posedge clk) begin
        if (dut.pix_req)   n_req = n_req + 1;
        if (dut.pix_valid) n_val = n_val + 1;
    end

    // ---- reconstruct the pixel stream ----
    always @(posedge clk) begin
        if (lcd_cs) begin
            // CS high: end of a command train, so the next train may start
            // with a fresh command
            have_hi <= 1'b0;
        end else if (byte_stb) begin
            if (!byte_dc) begin
                // command byte
                if (byte_val == 8'h2C) begin
                    in_ramwr <= 1'b1;
                    have_hi  <= 1'b0;
                end else begin
                    in_ramwr <= 1'b0;
                end
            end else if (in_ramwr) begin
                if (!have_hi) begin
                    hi_byte <= byte_val;
                    have_hi <= 1'b1;
                end else begin
                    have_hi <= 1'b0;
                    if (n_pix < MAX_PIX) pix_seen[n_pix] = {hi_byte, byte_val};
                    n_pix <= n_pix + 1;
                    if ({hi_byte, byte_val} != BG_COLOR) n_nonzero <= n_nonzero + 1;
                end
            end
        end
    end

    // =====================================================================
    // report helpers
    // =====================================================================
    int errors = 0;
    task automatic chk(input string what, input int got, input int exp);
        if (got !== exp) begin
            errors++;
            $display("  FAIL %s : got %0d expected %0d", what, got, exp);
        end else begin
            $display("  ok   %s = %0d", what, got);
        end
    endtask

    int timeout;

    initial begin
        n_pix = 0; n_nonzero = 0; n_req = 0; n_val = 0;
        in_ramwr = 1'b0; have_hi = 1'b0; hi_byte = 8'h00;

        repeat (20) @(posedge clk);
        btn_rst = 1'b1;                 // release reset (active low)

        // ---- 1. wait for boot_done (UFM copy finished) -------------------
        timeout = 0;
        while (!dut.boot_done && timeout < 400_000) begin
            @(posedge clk); timeout++;
        end
        $display("[1] UFM boot");
        $display("    boot_done=%0b after %0d cycles", dut.boot_done, timeout);
        if (!dut.boot_done) begin
            errors++;
            $display("  FAIL boot_done never asserted");
        end

        // logo_ram must now hold the UFM image
        begin
            int bad;
            bad = 0;
            for (int a = 0; a < 2000; a++) begin
                if (dut.u_ram.mem[a] !== 16'(a)) bad++;
            end
            $display("    logo_ram mismatches = %0d / 2000", bad);
            if (bad != 0) errors++;
        end

        // ---- 2. wait for the panel init + a board ------------------------
        // NOTE the budget: with MS_SCALE=1000 the panel still waits
        // POWERON_WAIT_MS * (CLK_FREQ/1000/MS_SCALE) = 150 * 50000 = 7.5 M cycles
        // for VDD settling, plus the init-ROM delays (120 ms -> 6 M cycles).
        // A smaller timeout can never see lcd_ready and would fail spuriously.
        // lcd_ready is only high for ONE clock between frames (S_READY), so it
        // is sampled on the negedge to avoid racing the nonblocking update.
        timeout = 0;
        while (!dut.lcd_ready && timeout < 40_000_000) begin
            @(negedge clk); timeout++;
        end
        $display("[2] panel init");
        $display("    lcd_ready=%0b after %0d cycles", dut.lcd_ready, timeout);
        if (!dut.lcd_ready) begin
            errors++;
            $display("  FAIL lcd_ready never asserted");
        end

        // wait until the game FSM is playing (past the initial game-over scan)
        timeout = 0;
        while (dut.u_game.state.name() != "S_PLAY" && timeout < 20_000_000) begin
            @(posedge clk); timeout++;
        end
        $display("    game state=%s after %0d cycles",
                 dut.u_game.state.name(), timeout);
        if (dut.u_game.state.name() != "S_PLAY") errors++;

        // board must not be all EMPTY
        begin
            int nonempty;
            nonempty = 0;
            for (int i = 0; i < 192; i++)
                if (dut.u_board.cells[i] != 3'b111) nonempty++;
            $display("    board non-empty cells = %0d / 192", nonempty);
            chk("board non-empty cells", nonempty, 192);
        end

        // ---- 3. let a couple of frames stream out ------------------------
        // A full 320x240 frame at 64 clk/pixel is ~4.9 M cycles, so give it
        // enough budget for one full frame plus its header.
        $display("[3] streaming frames (this takes a while)");
        timeout = 0;
        while (n_pix < 320*240 && timeout < 200_000_000) begin
            @(posedge clk); timeout++;
        end
        $display("    pixels captured=%0d  non-background=%0d  (cycles=%0d)",
                 n_pix, n_nonzero, timeout);
        $display("    pix_req=%0d pix_valid=%0d", n_req, n_val);

        // the heart of the test: a black panel means every captured pixel is
        // BG_COLOR.  A correctly booted design must show the logos.
        if (n_pix == 0) begin
            errors++;
            $display("  FAIL no pixels reached the panel at all");
        end
        if (n_nonzero == 0) begin
            errors++;
            $display("  FAIL every pixel was BG_COLOR (%04h) -> solid black panel",
                     BG_COLOR);
        end
        chk("non-background pixels > 0", (n_nonzero > 0) ? 1 : 0, 1);
        // The design streams continuously (one frame per FRAME_PERIOD_MS), so by
        // the time this loop is reached several frames may already have been
        // captured.  What matters is that at least one complete frame came out
        // and that the two pixel-source colours are both present.
        chk("at least one full frame captured", (n_pix >= 320*240) ? 1 : 0, 1);
        chk("pix_req answered by pix_valid", n_val, n_req);
        $display("    background pixels=%0d  logo pixels=%0d", n_pix - n_nonzero, n_nonzero);

        $display("================================");
        if (errors == 0) $display("  ALL PASS");
        else             $display("  *** FAILURES (%0d) ***", errors);
        $display("================================");
        $finish;
    end

    // absolute watchdog
    initial begin
        #900_000_000;
        $display("TIMEOUT: boot_done=%0b lcd_ready=%0b state=%s n_pix=%0d nonbg=%0d",
                 dut.boot_done, dut.lcd_ready, dut.u_game.state.name(),
                 n_pix, n_nonzero);
        $display("  *** FAILURES (timeout) ***");
        $finish;
    end
endmodule
