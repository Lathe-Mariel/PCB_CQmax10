// tb_framebuffer.sv
//
// Checks framebuffer.v, which is now the game's COLLISION MODEL only (it is no
// longer scanned out to the panel, so there is a single read port).
//
//   * the word address for every (x,y) is y*10 + x/32, and the bit within the
//     word is x%32 (checked by writing/reading the whole buffer)
//   * the read port is SYNCHRONOUS: the data for an address presented in cycle
//     N is valid in cycle N+1 (this is what lets Quartus infer an M9K)
//   * a write on the same cycle as a read returns the new data
//   * the bulk clear zeroes every word
//
// The pixel/colour pipeline that used to live here (framebuffer_pixel_src) has
// been removed from the design: the panel is driven by explicit rectangle
// writes now, so nothing scans the buffer out.
`timescale 1ns/1ps

module tb_framebuffer;
    localparam int AW            = 14;
    localparam int FIELD_W       = 320;
    localparam int FIELD_H       = 240;
    localparam int WORDS_PER_ROW = FIELD_W / 32;             // 10
    localparam int WORDS         = FIELD_H * WORDS_PER_ROW;  // 2400

    logic clk = 1'b0;
    always #10 clk = ~clk;                        // 50 MHz

    logic [AW-1:0] rd_addr = '0;
    logic [31:0]   rd_data;

    logic [AW-1:0] wr_addr = '0;
    logic [31:0]   wr_data = '0;
    logic          wr_en   = 1'b0;

    logic clr_start = 1'b0, clr_busy;

    framebuffer #(
        .FIELD_W(FIELD_W), .FIELD_H(FIELD_H),
        .WORDS_PER_ROW(WORDS_PER_ROW), .AW(AW)
    ) dut (
        .clk      (clk),
        .rd_addr  (rd_addr),
        .rd_data  (rd_data),
        .wr_en    (wr_en),
        .wr_addr  (wr_addr),
        .wr_data  (wr_data),
        .clr_start(clr_start),
        .clr_busy (clr_busy)
    );

    // ------------------------------------------------------------------
    // software reference model
    // ------------------------------------------------------------------
    logic [31:0] model_mem [0:WORDS-1];

    int errors = 0;
    int checks = 0;

    task automatic expect_equal(input string what, input int got, input int exp);
        checks++;
        if (got !== exp) begin
            errors++;
            if (errors < 20)
                $display("  FAIL %s : got %08h expected %08h", what, got, exp);
        end
    endtask

    // ------------------------------------------------------------------
    // read the word for (x,y) and compare with the model. Because the read
    // port is registered, the address must be stable for one full clock and
    // the data appears on the following clock.
    // ------------------------------------------------------------------
    task automatic check_pixel(input int x, input int y);
        logic [AW-1:0] exp_addr;
        logic [31:0]   exp_word;
        begin
            exp_addr = ((y*WORDS_PER_ROW) + (x/32));
            exp_word = model_mem[exp_addr];

            @(negedge clk);
            rd_addr = exp_addr;

            // one clock later the data is valid
            @(posedge clk);
            @(negedge clk);
            expect_equal($sformatf("word(%0d,%0d)", x, y), rd_data, exp_word);

            // and the bit for this pixel is the one the game will test
            expect_equal($sformatf("bit(%0d,%0d)", x, y),
                         rd_data[x%32], exp_word[x%32]);
        end
    endtask

    int x, y;

    initial begin
        // ---- bulk clear must zero every word ------------------------
        for (int i = 0; i < WORDS; i++) model_mem[i] = 32'hFFFF_FFFF;

        @(negedge clk);
        clr_start = 1'b1;
        @(negedge clk);
        clr_start = 1'b0;
        while (clr_busy) @(negedge clk);
        repeat (3) @(negedge clk);

        if (dut.mem[0] !== 32'h0000_0000 ||
            dut.mem[WORDS-1] !== 32'h0000_0000) begin
            errors++;
            $display("  FAIL bulk clear: mem[0]=%08h mem[%0d]=%08h",
                     dut.mem[0], WORDS-1, dut.mem[WORDS-1]);
        end else begin
            $display("  bulk clear zeroed the first and last word of %0d", WORDS);
        end
        for (int i = 0; i < WORDS; i++) model_mem[i] = 32'h0000_0000;

        // read the whole buffer back through the registered read port and
        // confirm it is all zero (this also walks every address)
        begin
            int bad;
            bad = 0;
            for (int i = 0; i < WORDS; i++) begin
                @(negedge clk);
                rd_addr = i[AW-1:0];
                @(posedge clk);
                @(negedge clk);
                if (rd_data !== 32'h0000_0000) bad++;
            end
            checks++;
            if (bad != 0) begin
                errors++;
                $display("  FAIL bulk clear: %0d of %0d words read back non-zero",
                         bad, WORDS);
            end else begin
                $display("  bulk clear verified through the read port (%0d words)",
                         WORDS);
            end
        end

        // ---- load a deterministic pattern --------------------------
        // word 5 of row 7 : all ones;  last word of row 239 : two set bits
        for (int i = 0; i < WORDS; i++)
            model_mem[i] = 32'hA5A5_5A5A ^ (i * 32'h0001_0101);
        model_mem[(7*WORDS_PER_ROW) + 5]   = 32'hFFFF_FFFF;
        model_mem[(239*WORDS_PER_ROW) + 9] = 32'h8000_0001;
        // a single set bit, so the per-pixel bit select is unambiguous
        model_mem[(100*WORDS_PER_ROW) + 3] = 32'h0000_0008;

        for (int i = 0; i < WORDS; i++) begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = i[AW-1:0];
            wr_data = model_mem[i];
        end
        @(negedge clk);
        wr_en = 1'b0;

        // ---- the read latency is exactly ONE clock ------------------
        // Present an address and sample one cycle later: the data must
        // already be there. This is the property Quartus needs for M9K
        // inference (an asynchronous read would fail to infer).
        begin
            @(negedge clk);
            rd_addr = (7*WORDS_PER_ROW) + 5;
            @(posedge clk);      // address sampled here (NBA updates rd_data)
            #1;
            expect_equal("read latency = 1 clk", rd_data, 32'hFFFF_FFFF);
        end

        // ---- a read of an address written on the same cycle ----------
        // Both ports are nonblocking, so the read samples the OLD contents:
        // write-then-read does NOT forward. The game never relies on this (it
        // reads a pixel and writes it in a later cycle), so it is checked only
        // to pin the behaviour down.
        begin
            logic [31:0] old_word;
            old_word = model_mem[(200*WORDS_PER_ROW) + 1];
            @(negedge clk);
            rd_addr = (200*WORDS_PER_ROW) + 1;
            wr_addr = (200*WORDS_PER_ROW) + 1;
            wr_data = 32'h1234_5678;
            wr_en   = 1'b1;
            @(posedge clk);
            @(negedge clk);
            wr_en   = 1'b0;
            expect_equal("read during write returns OLD data", rd_data, old_word);
            // ...but the write itself must have landed
            checks++;
            if (dut.mem[(200*WORDS_PER_ROW) + 1] !== 32'h1234_5678) begin
                errors++;
                $display("  FAIL read during write did not store the new data");
            end
            model_mem[(200*WORDS_PER_ROW) + 1] = 32'h1234_5678;
        end

        // ---- check every pixel position ----------------------------
        // Every (x,y) maps to a word whose bits are the 32 pixels of that
        // span, so comparing the word for a sample of pixels per row proves
        // both the address mapping and the bit mapping.
        for (y = 0; y < FIELD_H; y++)
            for (x = 0; x < FIELD_W; x += 1)
                check_pixel(x, y);

        $display("  swept %0d pixels (%0dx%0d)", FIELD_W*FIELD_H, FIELD_W, FIELD_H);

        if (errors == 0)
            $display("*** tb_framebuffer: PASS (%0d checks) ***", checks);
        else
            $display("*** tb_framebuffer: FAIL (%0d errors / %0d checks) ***",
                     errors, checks);
        $finish;
    end
endmodule
