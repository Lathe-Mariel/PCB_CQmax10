// probe_ff.sv - does floodfill_engine terminate on a FULL board?
`timescale 1ns/1ps
module probe_ff;
    localparam int COLS=16, ROWS=12, CELLS=COLS*ROWS, AW=8;
    logic clk=0; always #10 clk=~clk;
    logic rst=1;
    logic start; logic [3:0] sx, sy;
    logic [AW-1:0] rd_addr; logic [2:0] rd_data;
    logic done, busy; logic [7:0] count; logic [CELLS-1:0] mask;
    logic tgt_empty;

    logic [2:0] mem [0:CELLS-1];
    assign rd_data = mem[rd_addr];

    floodfill_engine u_ff (
        .clk(clk), .rst(rst), .start(start), .start_x(sx), .start_y(sy),
        .board_rd_addr(rd_addr), .board_rd_data(rd_data),
        .done(done), .count(count), .mask(mask),
        .target_empty(tgt_empty), .busy(busy)
    );

    int ncycles;
    initial begin
        start=0; sx=0; sy=0;
        // full board: id = (cx*3+cy*5)%5, as tb_game_fsm's generated board
        for (int r=0;r<ROWS;r++) for (int c=0;c<COLS;c++) mem[r*COLS+c] = 3'((c*3+r*5)%5);
        repeat (5) @(posedge clk); rst=0; repeat (2) @(posedge clk);

        for (int s = 0; s < 6; s++) begin
            sx = 4'(s); sy = 4'(s);
            start <= 1'b1; @(posedge clk); start <= 1'b0;
            ncycles = 0;
            while (!done && ncycles < 100000) begin @(posedge clk); ncycles++; end
            $display("seed(%0d,%0d) id=%0d done=%0b after %0d cycles count=%0d tgt_empty=%0b",
                     s, s, mem[s*COLS+s], done, ncycles, count, tgt_empty);
            if (!done) begin $display("  *** FLOODFILL HUNG ***"); end
            @(posedge clk);
        end
        $finish;
    end
endmodule
