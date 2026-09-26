// tb_ufm_boot.sv
//
// Focused test of `ufm_bootloader` + `logo_ram` against a model of the MAX 10
// On-Chip Flash (UFM) Avalon-MM data slave.
//
// This is the ONE path that no other testbench covers: in hardware the 2000
// logo pixels are copied UFM -> logo_ram at power-up, and `boot_done` gates the
// whole game FSM (samegame_top: `game_rst = rst | ~boot_done`).  If the copy
// never completes, the board stays EMPTY and the renderer paints every pixel
// with BG_COLOR (0x0000) - a completely black panel, which is exactly the
// hardware symptom while simulation passes.
//
// ---------------------------------------------------------------------------
// The trap this test models
// ---------------------------------------------------------------------------
// The UFM data slave uses `waitrequest` as "the read is still running", NOT as
// "the command was not accepted".  Reading
//   altera_onchip_flash_avmm_data_controller.v
//   (READ_STATE_* / READ_VALID_* / read_wait / read_wait_neg):
//     * readdatavalid is asserted from READ_VALID_PRE_READING, which is
//       triggered by avmm_readdata_ready from READ_STATE_READY;
//     * waitrequest is `read_wait | read_wait_neg` with read_wait cleared in
//       READ_STATE_CLEAR, and read_wait_neg adds a further cycle.
//   => readdatavalid PULSES BEFORE waitrequest is released.
// A master that waits for !waitrequest before sampling readdatavalid misses the
// 1-cycle pulse and hangs forever.
//
// Both orderings are tested so the bootloader can be shown to be immune to the
// ordering rather than tuned to one of them:
//   instance A : readdatavalid BEFORE waitrequest falls (the real IP)
//   instance B : readdatavalid AFTER  waitrequest falls (the other order)
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// UFM Avalon-MM data slave model.
//
// Faithful to altera_onchip_flash_avmm_data_controller.v in the two ways that
// matter for this test:
//   * waitrequest is COMBINATIONAL and high from the cycle the read command is
//     seen until the transfer completes
//       (real IP: `~is_read_busy && avmm_read` / `read_wait | read_wait_neg`),
//     so the master MUST sample it after the command, not before.
//   * readdata = {16'h0, address} so the TB can verify the data path.
//
// RDV_CYCLE / DONE_CYCLE are independent on purpose: RDV_CYCLE < DONE_CYCLE
// reproduces "readdatavalid pulses BEFORE waitrequest is released", which is
// what the real read FSM does (avmm_readdata_ready in READ_STATE_READY feeds
// READ_VALID_PRE_READING two states before read_wait is cleared in
// READ_STATE_CLEAR).
// ---------------------------------------------------------------------------
module ufm_model #(
    parameter int RDV_CYCLE  = 8,     // readdatavalid pulses at this cycle
    parameter int DONE_CYCLE = 10,    // waitrequest is released at this cycle
    // 1 = behave like an ERASED flash: every word reads back as all ones.
    // That is what makes the panel turn solid WHITE in the field, and it is
    // what `boot_blank` has to detect.
    parameter bit BLANK      = 1'b0
)(
    input  logic        clk,
    input  logic        rst,

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
        if (rst) begin
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
                if ((cnt + 1) == RDV_CYCLE)  readdatavalid <= 1'b1;
                if ((cnt + 1) >= END_CYCLE)  busy          <= 1'b0;
            end
        end
    end

    // COMBINATIONAL, exactly like the real data controller: high while the
    // command is being accepted or a transfer is running.  DONE_CYCLE chooses
    // when it is released relative to the readdatavalid pulse.
    assign waitrequest = (busy && (cnt < DONE_CYCLE)) | read;

    assign readdata = BLANK ? 32'hFFFF_FFFF : {16'h0000, a_lat};
endmodule


// ---------------------------------------------------------------------------
module tb_ufm_boot;
    localparam int PIXELS = 2000;
    localparam int RA_W   = 11;

    logic clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    logic rst = 1'b1;

    int errors = 0;
    int checks = 0;

    task automatic chk(input string what, input int got, input int exp);
        checks++;
        if (got !== exp) begin
            errors++;
            if (errors <= 20)
                $display("  FAIL %s : got %0d expected %0d", what, got, exp);
        end
    endtask

    // =====================================================================
    // DUT instance A : readdatavalid arrives BEFORE waitrequest falls
    // =====================================================================
    logic        a_read, a_wreq, a_rdv;
    logic [12:0] a_addr;
    logic [31:0] a_rdata;
    logic        a_wr_en;
    logic [RA_W-1:0] a_wr_addr;
    logic [15:0] a_wr_data;
    logic        a_boot_done;
    logic        a_boot_blank;

    logic [RA_W-1:0] a_rd_addr;
    logic [15:0]     a_rd_data;
    logic            a_boot_fail;
    logic [RA_W-1:0] d_rd_addr;
    logic [15:0]     d_rd_data;

    int a_writes;

    ufm_model #(.RDV_CYCLE(8), .DONE_CYCLE(10)) u_ufm_a (
        .clk(clk), .rst(rst),
        .read(a_read), .addr(a_addr), .burstcount(4'd1),
        .waitrequest(a_wreq), .readdatavalid(a_rdv), .readdata(a_rdata)
    );

    ufm_bootloader #(.PIXELS(PIXELS), .RAM_AW(RA_W), .RAM_DW(16)) u_boot_a (
        .clk(clk), .rst(rst),
        .flash_read(a_read), .flash_addr(a_addr),
        .flash_waitrequest(a_wreq),
        .flash_readdatavalid(a_rdv),
        .flash_readdata(a_rdata),
        .ram_wr_en(a_wr_en), .ram_wr_addr(a_wr_addr), .ram_wr_data(a_wr_data),
        .boot_done(a_boot_done), .boot_fail(a_boot_fail),
        .boot_blank(a_boot_blank), .boot_beat(), .boot_pix()
    );

    logo_ram #(.ROM_DEPTH(PIXELS), .MEM_DEPTH(2048), .AW(RA_W), .DW(16)) u_ram_a (
        .clk(clk),
        .rd_addr(a_rd_addr), .rd_data(a_rd_data),
        .wr_en(a_wr_en), .wr_addr(a_wr_addr), .wr_data(a_wr_data)
    );

    // count writes without an always_ff (a plain level counter is enough and
    // keeps the whole TB free of always_ff-driven variables)
    wire a_wr_pulse = a_wr_en;

    // =====================================================================
    // DUT instance B : readdatavalid arrives AFTER waitrequest falls
    // =====================================================================
    logic        b_read, b_wreq, b_rdv;
    logic [12:0] b_addr;
    logic [31:0] b_rdata;
    logic        b_wr_en;
    logic [RA_W-1:0] b_wr_addr;
    logic [15:0] b_wr_data;
    logic        b_boot_done;

    logic [RA_W-1:0] b_rd_addr;
    logic [15:0]     b_rd_data;
    logic            b_boot_fail;

    int b_writes;

    ufm_model #(.RDV_CYCLE(12), .DONE_CYCLE(10)) u_ufm_b (
        .clk(clk), .rst(rst),
        .read(b_read), .addr(b_addr), .burstcount(4'd1),
        .waitrequest(b_wreq), .readdatavalid(b_rdv), .readdata(b_rdata)
    );

    ufm_bootloader #(.PIXELS(PIXELS), .RAM_AW(RA_W), .RAM_DW(16)) u_boot_b (
        .clk(clk), .rst(rst),
        .flash_read(b_read), .flash_addr(b_addr),
        .flash_waitrequest(b_wreq),
        .flash_readdatavalid(b_rdv),
        .flash_readdata(b_rdata),
        .ram_wr_en(b_wr_en), .ram_wr_addr(b_wr_addr), .ram_wr_data(b_wr_data),
        .boot_done(b_boot_done), .boot_fail(b_boot_fail),
        .boot_blank(), .boot_beat(), .boot_pix()
    );

    logo_ram #(.ROM_DEPTH(PIXELS), .MEM_DEPTH(2048), .AW(RA_W), .DW(16)) u_ram_b (
        .clk(clk),
        .rd_addr(b_rd_addr), .rd_data(b_rd_data),
        .wr_en(b_wr_en), .wr_addr(b_wr_addr), .wr_data(b_wr_data)
    );

    wire b_wr_pulse = b_wr_en;

    // =====================================================================
    // DUT instance C : the flash NEVER answers - this is the "boot_done stayed
    // low on hardware and the panel was black" symptom.  With a short watchdog
    // and few retries the bootloader must abort each word, raise boot_fail and
    // still reach boot_done so the game FSM is never held in reset for ever.
    // =====================================================================
    logic        c_read, c_wreq, c_rdv;
    logic [12:0] c_addr;
    logic [31:0] c_rdata = 32'h0;
    logic        c_wr_en;
    logic [RA_W-1:0] c_wr_addr;
    logic [15:0] c_wr_data;
    logic        c_boot_done, c_boot_fail;

    // a dead slave: waitrequest is stuck high and readdatavalid never pulses
    assign c_wreq = 1'b1;
    assign c_rdv  = 1'b0;

    int c_writes;

    ufm_bootloader #(
        .PIXELS(PIXELS), .RAM_AW(RA_W), .RAM_DW(16),
        .WATCH_CYCLES(200), .MAX_RETRIES(2)
    ) u_boot_c (
        .clk(clk), .rst(rst),
        .flash_read(c_read), .flash_addr(c_addr),
        .flash_waitrequest(c_wreq),
        .flash_readdatavalid(c_rdv),
        .flash_readdata(c_rdata),
        .ram_wr_en(c_wr_en), .ram_wr_addr(c_wr_addr), .ram_wr_data(c_wr_data),
        .boot_done(c_boot_done), .boot_fail(c_boot_fail),
        .boot_blank(), .boot_beat(), .boot_pix()
    );

    wire c_wr_pulse = c_wr_en;

    // =====================================================================
    // DUT instance D : the flash block is still IN ITS INTERNAL RESET when the
    // bootloader starts (waitrequest held high until RESET_CYCLES, then normal
    // operation).  `avmm_waitrequest = ~reset_n | ...`, so a master that pulses
    // read before the block is ready loses the command; this instance checks
    // that the S_REQ wait handles that case.
    // =====================================================================
    logic        d_read, d_rdv;
    logic [12:0] d_addr;
    logic [31:0] d_rdata;
    logic        d_wr_en;
    logic [RA_W-1:0] d_wr_addr;
    logic [15:0] d_wr_data;
    logic        d_boot_done, d_boot_fail;

    localparam int D_RESET_CYCLES = 500;
    int          d_cycle;

    logic d_wreq;
    wire  d_wreq_internal;

    always @(posedge clk) begin
        if (rst) d_cycle <= 0;
        else if (d_cycle < D_RESET_CYCLES) d_cycle <= d_cycle + 1;
    end

    // reset period: waitrequest high, no data.  Afterwards: the good model.
    ufm_model #(.RDV_CYCLE(8), .DONE_CYCLE(10)) u_ufm_d (
        .clk(clk), .rst(rst),
        .read(d_read), .addr(d_addr), .burstcount(4'd1),
        .waitrequest(d_wreq_internal), .readdatavalid(d_rdv), .readdata(d_rdata)
    );

    assign d_wreq = (d_cycle < D_RESET_CYCLES) ? 1'b1 : d_wreq_internal;

    int d_writes;

    ufm_bootloader #(.PIXELS(PIXELS), .RAM_AW(RA_W), .RAM_DW(16)) u_boot_d (
        .clk(clk), .rst(rst),
        .flash_read(d_read), .flash_addr(d_addr),
        .flash_waitrequest(d_wreq),
        .flash_readdatavalid(d_rdv),
        .flash_readdata(d_rdata),
        .ram_wr_en(d_wr_en), .ram_wr_addr(d_wr_addr), .ram_wr_data(d_wr_data),
        .boot_done(d_boot_done), .boot_fail(d_boot_fail),
        .boot_blank(), .boot_beat(), .boot_pix()
    );

    wire d_wr_pulse = d_wr_en;

    // =====================================================================
    // DUT instance E : an ERASED flash - every word reads back 0xFFFFFFFF
    //
    // This is the "solid WHITE panel" case seen on the board: nothing times
    // out (so boot_fail stays 0) but the whole image is all ones.  boot_blank
    // must be raised, otherwise the failure is completely silent.
    // =====================================================================
    logic        e_read, e_wreq, e_rdv;
    logic [12:0] e_addr;
    logic [31:0] e_rdata;
    logic        e_wr_en;
    logic [RA_W-1:0] e_wr_addr;
    logic [15:0] e_wr_data;
    logic        e_boot_done, e_boot_fail, e_boot_blank;
    logic [1:0]  e_boot_pix;

    ufm_model #(.RDV_CYCLE(8), .DONE_CYCLE(10), .BLANK(1'b1)) u_ufm_e (
        .clk(clk), .rst(rst),
        .read(e_read), .addr(e_addr), .burstcount(4'd1),
        .waitrequest(e_wreq), .readdatavalid(e_rdv), .readdata(e_rdata)
    );

    int e_writes;

    ufm_bootloader #(.PIXELS(PIXELS), .RAM_AW(RA_W), .RAM_DW(16)) u_boot_e (
        .clk(clk), .rst(rst),
        .flash_read(e_read), .flash_addr(e_addr),
        .flash_waitrequest(e_wreq),
        .flash_readdatavalid(e_rdv),
        .flash_readdata(e_rdata),
        .ram_wr_en(e_wr_en), .ram_wr_addr(e_wr_addr), .ram_wr_data(e_wr_data),
        .boot_done(e_boot_done), .boot_fail(e_boot_fail),
        .boot_blank(e_boot_blank), .boot_beat(), .boot_pix(e_boot_pix)
    );

    wire e_wr_pulse = e_wr_en;

    // ---------------------------------------------------------------------
    // check one logo store through its registered read port
    // ---------------------------------------------------------------------
    task automatic check_ram_a();
        for (int a = 0; a < PIXELS; a++) begin
            @(negedge clk);
            a_rd_addr = RA_W'(a);
            @(posedge clk);
            #1;
            @(posedge clk);
            #1;
            chk($sformatf("A logo_ram[%0d]", a), a_rd_data, a & 16'hFFFF);
        end
    endtask

    task automatic check_ram_b();
        for (int a = 0; a < PIXELS; a++) begin
            @(negedge clk);
            b_rd_addr = RA_W'(a);
            @(posedge clk);
            #1;
            @(posedge clk);
            #1;
            chk($sformatf("B logo_ram[%0d]", a), b_rd_data, a & 16'hFFFF);
        end
    endtask

    // ---------------------------------------------------------------------
    // write counters
    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst) begin
            if (a_wr_pulse) a_writes = a_writes + 1;
            if (b_wr_pulse) b_writes = b_writes + 1;
            if (c_wr_pulse) c_writes = c_writes + 1;
            if (d_wr_pulse) d_writes = d_writes + 1;
            if (e_wr_pulse) e_writes = e_writes + 1;
        end
    end

    int timeout;

    initial begin
        a_rd_addr = '0; b_rd_addr = '0;
        a_writes = 0; b_writes = 0; c_writes = 0; d_writes = 0; e_writes = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        // ---- wait for both good bootloaders, with a watchdog ------------
        // The copy needs ~12 cycles per pixel, so give it plenty of room.
        timeout = 0;
        while (!(a_boot_done && b_boot_done) && timeout < 200_000) begin
            @(posedge clk);
            timeout++;
        end

        $display("[1] UFM -> logo_ram boot");
        $display("    A: boot_done=%0b writes=%0d   (readdatavalid BEFORE waitrequest)",
                 a_boot_done, a_writes);
        $display("    B: boot_done=%0b writes=%0d   (readdatavalid AFTER  waitrequest)",
                 b_boot_done, b_writes);
        if (!a_boot_done) begin
            errors++;
            $display("  FAIL A: boot_done never asserted (timeout=%0d cycles)", timeout);
        end
        if (!b_boot_done) begin
            errors++;
            $display("  FAIL B: boot_done never asserted (timeout=%0d cycles)", timeout);
        end
        checks += 2;
        chk("A writes", a_writes, PIXELS);
        chk("B writes", b_writes, PIXELS);
        chk("A boot_fail", a_boot_fail, 0);
        chk("B boot_fail", b_boot_fail, 0);

        // ---- verify the copied image ------------------------------------
        $display("[2] copied image contents");
        check_ram_a();
        check_ram_b();
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---- the dead-slave case: must NOT hang, must flag the failure ---
        $display("[3] dead UFM slave (watchdog / retry / boot_fail)");
        timeout = 0;
        while (!c_boot_done && timeout < 2_000_000) begin
            @(posedge clk);
            timeout++;
        end
        $display("    C: boot_done=%0b boot_fail=%0b writes=%0d (cycles=%0d)",
                 c_boot_done, c_boot_fail, c_writes, timeout);
        chk("C boot_done asserted (no hang)", c_boot_done, 1);
        chk("C boot_fail raised",            c_boot_fail, 1);
        chk("C wrote nothing",               c_writes, 0);

        // ---- the flash still in reset when the bootloader starts ---------
        $display("[4] flash in its internal reset at start (waitrequest held high)");
        timeout = 0;
        while (!d_boot_done && timeout < 2_000_000) begin
            @(posedge clk);
            timeout++;
        end
        $display("    D: boot_done=%0b boot_fail=%0b writes=%0d (cycles=%0d)",
                 d_boot_done, d_boot_fail, d_writes, timeout);
        chk("D boot_done asserted", d_boot_done, 1);
        chk("D boot_fail clear",    d_boot_fail, 0);
        chk("D wrote every pixel",  d_writes, PIXELS);
        if (d_writes != 0) begin
            // the very first word must be correct too (the one that was issued
            // while the block was not ready yet)
            @(negedge clk); d_rd_addr = RA_W'(0);
            @(posedge clk); #1; @(posedge clk); #1;
            chk("D logo_ram[0] (first word)", d_rd_data, 0);
        end

        // ---- the ERASED-flash case: the "solid white panel" ---------------
        $display("[5] erased flash (every word 0xFFFFFFFF) -> boot_blank");
        timeout = 0;
        while (!e_boot_done && timeout < 2_000_000) begin
            @(posedge clk);
            timeout++;
        end
        $display("    E: boot_done=%0b boot_fail=%0b boot_blank=%0b writes=%0d (cycles=%0d)",
                 e_boot_done, e_boot_fail, e_boot_blank, e_writes, timeout);
        chk("E boot_done asserted (no hang)", e_boot_done,  1);
        // an erased flash does NOT time out, so boot_fail must stay low...
        chk("E boot_fail clear",              e_boot_fail,  0);
        // ...but boot_blank MUST catch it, or the white panel is silent
        chk("E boot_blank raised",            e_boot_blank, 1);
        chk("E wrote every pixel",            e_writes,     PIXELS);
        // and the sample of the raw flash content must show all ones
        chk("E boot_pix shows erased flash",  e_boot_pix,   2'b11);

        // sanity: the GOOD instances must NOT be flagged blank
        chk("A boot_blank clear (real image)", a_boot_blank, 0);

        $display("================================");
        $display("  checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("  ALL PASS");
        else             $display("  *** FAILURES ***");
        $display("================================");
        $finish;
    end

    // absolute watchdog
    initial begin
        #50_000_000;                    // 50 ms of simulated time
        $display("TIMEOUT: A boot_done=%0b writes=%0d / B boot_done=%0b writes=%0d",
                 a_boot_done, a_writes, b_boot_done, b_writes);
        $display("         A state=%s  C state=%s boot_done=%0b boot_fail=%0b",
                 u_boot_a.state.name(), u_boot_c.state.name(),
                 c_boot_done, c_boot_fail);
        errors++;
        $display("  *** FAILURES ***");
        $finish;
    end
endmodule
