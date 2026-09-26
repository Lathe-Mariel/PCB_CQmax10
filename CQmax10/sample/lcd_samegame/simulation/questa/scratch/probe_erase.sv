// probe_erase.sv
//
// Does erase_engine honour its "1 start = erase the masked cells" contract?
//
// The engine is driven against a plain board model.  Each masked cell must be
// written exactly once after BLINK_FRAMES frames, and `done` must be a single
// pulse.
`timescale 1ns/1ps

module probe_erase;
    localparam int CELLS = 192;
    localparam int AW    = 8;

    logic clk = 0;
    always #10 clk = ~clk;
    logic rst = 1;

    logic start;
    logic [CELLS-1:0] mask;
    logic frame_tick;
    logic done, busy, blink_on;
    logic wr_en;
    logic [AW-1:0] wr_addr;
    logic [2:0] wr_data;

    erase_engine #(.CELLS(CELLS), .AW(AW)) u_er (
        .clk(clk), .rst(rst),
        .start(start), .erase_mask(mask), .frame_tick(frame_tick),
        .done(done), .busy(busy), .blink_on(blink_on),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );

    // board model
    logic [2:0] board [0:CELLS-1];
    int writes [0:CELLS-1];
    int done_pulses;
    int blink_toggles;

    always @(posedge clk) begin
        if (wr_en) begin
            board[wr_addr] <= wr_data;
            writes[wr_addr] = writes[wr_addr] + 1;
        end
        if (done) done_pulses = done_pulses + 1;
    end

    logic blink_d;
    always @(posedge clk) begin
        blink_d <= blink_on;
        if (blink_on != blink_d) blink_toggles++;
    end

    int errs;
    task automatic chk(input string what, input int got, input int exp);
        if (got !== exp) begin
            errs++;
            $display("  FAIL %s : got %0d expected %0d", what, got, exp);
        end
    endtask

    task automatic tick();
        @(negedge clk); frame_tick = 1;
        @(negedge clk); frame_tick = 0;
        repeat (6) @(negedge clk);
    endtask

    int ncycles;
    initial begin
        start = 0; frame_tick = 0; mask = '0; errs = 0;
        done_pulses = 0; blink_toggles = 0;
        for (int i = 0; i < CELLS; i++) begin
            board[i] = 3'd2;
            writes[i] = 0;
        end
        repeat (5) @(posedge clk); rst = 0; repeat (2) @(posedge clk);

        // a scattered mask: rows 0 and 3, plus the very first and last cell
        mask = '0;
        for (int c = 0; c < 16; c++) begin
            mask[0*16 + c] = 1'b1;
            mask[3*16 + c] = 1'b1;
        end
        mask[0] = 1'b1;         // already set above
        mask[CELLS-1] = 1'b1;

        // start
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;

        // 6 frame ticks = the blink
        for (int f = 0; f < 7; f++) tick();

        // let the commit finish
        ncycles = 0;
        while (!done && ncycles < 5000) begin @(posedge clk); ncycles++; end
        // `done` and the very last cell write are asserted in the same cycle,
        // so give the board model a few cycles to absorb the last write before
        // checking.
        repeat (4) @(posedge clk);
        $display("done after %0d extra cycles, pulses=%0d, blink_toggles=%0d",
                 ncycles, done_pulses, blink_toggles);

        chk("done asserted", (ncycles < 5000) ? 1 : 0, 1);
        chk("done is a single pulse", done_pulses, 1);

        // every masked cell erased exactly once...
        begin : mask_check
            int bad_once, bad_val;
            bad_once = 0; bad_val = 0;
            for (int i = 0; i < CELLS; i++) begin
                if (mask[i]) begin
                    if (writes[i] != 1) bad_once++;
                    if (board[i] != 3'b111) begin
                        bad_val++;
                        $display("    cell %0d masked but board=%0d writes=%0d col=%0d row=%0d",
                                 i, board[i], writes[i], i % 16, i / 16);
                    end
                end else begin
                    if (writes[i] != 0) bad_once++;
                    if (board[i] != 3'd2) bad_val++;
                end
            end
            $display("masked cells: wrong write count = %0d, wrong value = %0d",
                     bad_once, bad_val);
            chk("each masked cell written exactly once", bad_once, 0);
            chk("masked cells erased, others untouched", bad_val, 0);
        end

        // blink must have produced several toggles over the 6 frames
        chk("blink toggled", (blink_toggles >= 5) ? 1 : 0, 1);

        $display("==========================================");
        $display("  probe_erase: %s", (errs == 0) ? "ALL PASS" : $sformatf("%0d FAILURES", errs));
        $display("==========================================");
        $finish;
    end
endmodule
