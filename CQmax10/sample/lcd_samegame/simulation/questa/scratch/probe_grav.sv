// probe_grav.sv
//
// Does fall_dist really describe the *current* erase?
//
// The renderer treats fall_dist as "per target cell, how far that cell's block
// fell (0 = did not move)".  Gravity runs twice here with two different boards;
// a cell that received a block in the first run and receives nothing in the
// second must report 0 the second time, otherwise the renderer has a stale
// "falling block" entry that can shadow a real one.
`timescale 1ns/1ps

module probe_grav;
    localparam int COLS = 16, ROWS = 12, CELLS = COLS*ROWS, AW = 8;

    logic clk = 0;
    always #10 clk = ~clk;
    logic rst = 1;

    logic start, done, busy;
    logic wr_en;
    logic [AW-1:0] wr_addr;
    logic [2:0] wr_data;
    logic [3:0] rd_col;
    logic [35:0] col_data;
    logic [CELLS*4-1:0] fall_dist;

    // board model with a combinational column read (same as board_memory)
    logic [2:0] board [0:CELLS-1];
    always_comb begin
        col_data = '0;
        for (int r = 0; r < ROWS; r++)
            col_data[3*r +: 3] = board[rd_col + r*COLS];
    end
    always @(posedge clk) if (wr_en) board[wr_addr] <= wr_data;

    gravity_engine u_grav (
        .clk(clk), .rst(rst),
        .start(start), .done(done), .busy(busy),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_col(rd_col), .col_data(col_data),
        .fall_dist(fall_dist)
    );

    int errs;
    task automatic chk(input string what, input int got, input int exp);
        if (got !== exp) begin
            errs++;
            $display("  FAIL %s : got %0d expected %0d", what, got, exp);
        end
    endtask

    function automatic int fd(input int c, input int r);
        fd = fall_dist[4*(c*ROWS + r) +: 4];
    endfunction

    task automatic run_grav();
        @(negedge clk); start <= 1'b1;
        @(negedge clk); start <= 1'b0;
        while (!done) @(posedge clk);
        @(posedge clk);
    endtask

    initial begin
        start = 0; errs = 0;
        for (int i = 0; i < CELLS; i++) board[i] = 3'b111;
        repeat (5) @(posedge clk); rst = 0; repeat (2) @(posedge clk);

        // ---- run 1: column 0 has a block at row 4 only -> it falls 7 rows ----
        board[4*COLS + 0] = 3'd1;
        run_grav();
        $display("run 1: fall_dist(0,11)=%0d (expect 7)", fd(0,11));
        chk("run1 fall_dist(0,11)", fd(0,11), 7);

        // ---- run 2: column 0 is now completely EMPTY, column 5 has a block.
        //      Cell (0,11) receives no block at all in this run, so it must
        //      report distance 0 - with the old code it kept the 7 from run 1
        //      and the renderer drew a phantom falling block in column 0. ----
        for (int i = 0; i < CELLS; i++) board[i] = 3'b111;
        board[11*COLS + 5] = 3'd2;
        run_grav();
        $display("run 2: fall_dist(0,11)=%0d (expect 0)", fd(0,11));
        $display("       fall_dist(0,10)=%0d (expect 0)", fd(0,10));
        chk("run2 fall_dist(0,11) refreshed", fd(0,11), 0);
        chk("run2 fall_dist(0,10) cleared",   fd(0,10), 0);
        chk("run2 column 5 block stays put",  fd(5,11), 0);

        $display("==========================================");
        $display("  probe_grav: %s", (errs == 0) ? "ALL PASS" : $sformatf("%0d FAILURES", errs));
        $display("==========================================");
        $finish;
    end
endmodule
