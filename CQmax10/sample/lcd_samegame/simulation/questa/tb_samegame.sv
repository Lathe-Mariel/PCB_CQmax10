// tb_samegame.sv
//
// Unit + integration tests for the SameGame logic, independent of the LCD SPI
// path (already proven by tb_orange).  Verifies:
//
//   1. board_memory    : write / read / column read / clear
//   2. floodfill       : group detection (connected cells, size, EMPTY seed)
//   3. gravity         : column compaction + fall distances
//   4. column_shift    : empty-column removal + shift distances
//
// The flood-fill / gravity / shift engines are driven directly against a
// shared board_memory, mirroring the game_fsm wiring.

`timescale 1ns/1ps

module tb_samegame;
    localparam int COLS = 16;
    localparam int ROWS = 12;
    localparam int CELLS = COLS * ROWS;
    localparam int AW = 8;

    logic clk = 1'b0;
    always #10 clk = ~clk;                     // 50 MHz

    logic rst = 1'b1;

    // ---- board memory ----
    logic        bm_wr_en;
    logic [AW-1:0] bm_wr_addr;
    logic [2:0]  bm_wr_data;
    logic        bm_clr_start;
    logic        bm_clr_busy;
    logic [AW-1:0] rd_addr_a;
    logic [2:0]  rd_data_a;
    logic [AW-1:0] rd_addr_b;
    logic [2:0]  rd_data_b;
    logic [3:0]  rd_col;
    logic [35:0] col_data;

    board_memory #(.COLS(COLS), .ROWS(ROWS), .AW(AW)) u_bm (
        .clk(clk), .rst(rst),
        .wr_en(bm_wr_en), .wr_addr(bm_wr_addr), .wr_data(bm_wr_data),
        .clr_start(bm_clr_start), .clr_busy(bm_clr_busy),
        .rd_addr_a(rd_addr_a), .rd_data_a(rd_data_a),
        .rd_addr_b(rd_addr_b), .rd_data_b(rd_data_b),
        .rd_col(rd_col), .col_data(col_data)
    );

    // ---- flood fill ----
    logic        ff_start, ff_done, ff_busy, ff_target_empty;
    logic [3:0]  ff_x, ff_y;
    logic [7:0]  ff_count;
    logic [CELLS-1:0] ff_mask;

    floodfill_engine u_ff (
        .clk(clk), .rst(rst),
        .start(ff_start), .start_x(ff_x), .start_y(ff_y),
        .board_rd_addr(rd_addr_b), .board_rd_data(rd_data_b),
        .done(ff_done), .count(ff_count), .mask(ff_mask),
        .target_empty(ff_target_empty), .busy(ff_busy)
    );

    // ---- gravity ----
    logic        grav_start, grav_done, grav_busy;
    logic        grav_wr_en;
    logic [AW-1:0] grav_wr_addr;
    logic [2:0]  grav_wr_data;
    logic [3:0]  grav_rd_col;
    logic [CELLS*4-1:0] grav_fall_dist;

    gravity_engine u_grav (
        .clk(clk), .rst(rst),
        .start(grav_start), .done(grav_done), .busy(grav_busy),
        .wr_en(grav_wr_en), .wr_addr(grav_wr_addr), .wr_data(grav_wr_data),
        .rd_col(grav_rd_col), .col_data(col_data),
        .fall_dist(grav_fall_dist)
    );

    // ---- column shift ----
    logic        shift_start, shift_done, shift_busy;
    logic        shift_wr_en;
    logic [AW-1:0] shift_wr_addr;
    logic [2:0]  shift_wr_data;
    logic [3:0]  shift_rd_col;
    logic [COLS-1:0] column_empty;
    logic [COLS*4-1:0] shift_dist;

    column_shift_engine u_shift (
        .clk(clk), .rst(rst),
        .start(shift_start), .done(shift_done), .busy(shift_busy),
        .wr_en(shift_wr_en), .wr_addr(shift_wr_addr), .wr_data(shift_wr_data),
        .rd_col(shift_rd_col), .col_data(col_data),
        .column_empty(column_empty), .shift_dist(shift_dist)
    );

    // ---- manual write path (testbench-controlled, highest priority) ----
    logic        manual_wr_en;
    logic [AW-1:0] manual_wr_addr;
    logic [2:0]  manual_wr_data;

    assign rd_col     = grav_busy ? grav_rd_col : shift_rd_col;
    assign bm_wr_en   = manual_wr_en ? manual_wr_en :
                        (grav_busy ? grav_wr_en : (shift_busy ? shift_wr_en : 1'b0));
    assign bm_wr_addr = manual_wr_en ? manual_wr_addr :
                        (grav_busy ? grav_wr_addr : shift_wr_addr);
    assign bm_wr_data = manual_wr_en ? manual_wr_data :
                        (grav_busy ? grav_wr_data : shift_wr_data);

    // ---- helpers ----
    int errors = 0;
    int checks = 0;

    task automatic check(input string what, input int got, input int exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("  FAIL %s : got %0d expected %0d", what, got, exp);
        end
    endtask

    task automatic write_cell(input int c, input int r, input int v);
        manual_wr_en   <= 1'b1;
        manual_wr_addr <= AW'(r)*COLS + AW'(c);
        manual_wr_data <= v[2:0];
        @(posedge clk);
        manual_wr_en   <= 1'b0;
        @(posedge clk);
    endtask

    logic [2:0] cell_value;
    task automatic read_cell(input int c, input int r, output logic [2:0] v);
        rd_addr_a = AW'(r)*COLS + AW'(c);
        #1;   // let the combinational read settle
        v = rd_data_a;
    endtask

    // pulse clr_start, then wait for the clear FSM to actually finish
    task automatic clear_board();
        bm_clr_start <= 1'b1;
        @(posedge clk);
        bm_clr_start <= 1'b0;
        @(posedge clk);          // let clearing propagate
        while (bm_clr_busy) @(posedge clk);
    endtask

    // ------------------------------------------------------------------
    // main test
    // ------------------------------------------------------------------
    initial begin
        rd_addr_a = '0;
        manual_wr_en = 1'b0;
        manual_wr_addr = '0;
        manual_wr_data = '0;
        bm_clr_start = 1'b0;
        ff_start = 1'b0;
        grav_start = 1'b0;
        shift_start = 1'b0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------
        // Test 1: board_memory clear (auto-clear after reset)
        // ---------------------------------------------------------------
        $display("[1] board clear after reset");
        while (bm_clr_busy) @(posedge clk);
        for (int c = 0; c < COLS; c++)
            for (int r = 0; r < ROWS; r++) begin
                read_cell(c, r, cell_value);
                check($sformatf("cell(%0d,%0d)=EMPTY", c, r), cell_value, 3'b111);
            end

        // ---------------------------------------------------------------
        // Test 2: flood fill group detection
        // ---------------------------------------------------------------
        $display("[2] flood fill: 2x2 group of Logo0");
        write_cell(0, 0, 0);   // Logo0
        write_cell(1, 0, 0);
        write_cell(0, 1, 0);
        write_cell(1, 1, 0);
        write_cell(2, 0, 1);   // Logo1 (should NOT be in group)

        ff_x <= 4'd0; ff_y <= 4'd0;
        ff_start <= 1'b1;
        @(posedge clk);
        ff_start <= 1'b0;
        while (!ff_done) @(posedge clk);
        check("floodfill group size", ff_count, 4);
        check("floodfill mask bit (0,0)", ff_mask[0], 1);
        check("floodfill mask bit (1,0)", ff_mask[1], 1);
        check("floodfill mask bit (0,1)", ff_mask[16], 1);
        check("floodfill mask bit (1,1)", ff_mask[17], 1);
        check("floodfill mask bit (2,0) NOT in group", ff_mask[2], 0);
        check("floodfill target not empty", ff_target_empty, 0);
        @(posedge clk);

        // ---------------------------------------------------------------
        // Test 3: flood fill on empty cell
        // ---------------------------------------------------------------
        $display("[3] flood fill on empty cell");
        ff_x <= 4'd5; ff_y <= 4'd5;   // empty
        ff_start <= 1'b1;
        @(posedge clk);
        ff_start <= 1'b0;
        while (!ff_done) @(posedge clk);
        check("floodfill empty target_empty", ff_target_empty, 1);
        check("floodfill empty count", ff_count, 0);
        @(posedge clk);

        // ---------------------------------------------------------------
        // Test 4: gravity compaction
        // ---------------------------------------------------------------
        $display("[4] gravity compaction");
        clear_board();

        // column 3: cell(3,2)=Logo2, cell(3,3)=Logo3, rest empty
        write_cell(3, 2, 2);
        write_cell(3, 3, 3);

        grav_start <= 1'b1;
        @(posedge clk);
        grav_start <= 1'b0;
        while (!grav_done) @(posedge clk);
        @(posedge clk);

        read_cell(3, 11, cell_value);
        check("gravity: cell(3,11) = Logo3", cell_value, 3);
        read_cell(3, 10, cell_value);
        check("gravity: cell(3,10) = Logo2", cell_value, 2);
        read_cell(3, 9, cell_value);
        check("gravity: cell(3,9) empty", cell_value, 3'b111);
        // Logo3 was at row 3 -> settled row 11 = 8 cells of fall
        check("gravity fall_dist(3,11)=8", grav_fall_dist[4*(3*ROWS+11) +: 4], 8);
        check("gravity fall_dist(3,10)=8", grav_fall_dist[4*(3*ROWS+10) +: 4], 8);

        // ---------------------------------------------------------------
        // Test 5: column shift
        // ---------------------------------------------------------------
        $display("[5] column shift: A B Empty C D Empty -> A B C D Empty Empty");
        clear_board();

        // fill columns 0,1,3,4 with one block each; leave 2 and 5 empty
        write_cell(0, 11, 0);   // col 0
        write_cell(1, 11, 1);   // col 1
        write_cell(3, 11, 3);   // col 3
        write_cell(4, 11, 4);   // col 4

        shift_start <= 1'b1;
        @(posedge clk);
        shift_start <= 1'b0;
        while (!shift_done) @(posedge clk);
        @(posedge clk);

        check("column_empty[2]", column_empty[2], 1);
        check("column_empty[5]", column_empty[5], 1);
        check("column_empty[0]", column_empty[0], 0);

        // after shift: col0->0, col1->1, col3->2, col4->3
        read_cell(0, 11, cell_value);
        check("shift: cell(0,11)=Logo0", cell_value, 0);
        read_cell(1, 11, cell_value);
        check("shift: cell(1,11)=Logo1", cell_value, 1);
        read_cell(2, 11, cell_value);
        check("shift: cell(2,11)=Logo3", cell_value, 3);
        read_cell(3, 11, cell_value);
        check("shift: cell(3,11)=Logo4", cell_value, 4);
        read_cell(4, 11, cell_value);
        check("shift: cell(4,11) empty", cell_value, 3'b111);
        check("shift_dist[2] (col3->2)=1", shift_dist[4*2 +: 4], 1);
        check("shift_dist[3] (col4->3)=1", shift_dist[4*3 +: 4], 1);

        // ---------------------------------------------------------------
        $display("================================");
        $display("  checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("  ALL PASS");
        else             $display("  *** FAILURES ***");
        $display("================================");
        $finish;
    end

    // watchdog
    initial begin
        #500_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
