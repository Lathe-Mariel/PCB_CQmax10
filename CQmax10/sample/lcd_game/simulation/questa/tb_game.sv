// tb_game.sv
//
// Checks game_ctrl.sv against the rules in prompt.txt #4, against a real
// framebuffer so the "is something already drawn here?" test runs on actual
// memory.
//
// METHOD
//   1. run a software reference trajectory with the same rules, stopping at
//      the first collision (or at MAX_DOTS)
//   2. load the reference picture into the frame buffer through the write
//      port, while the DUT is held in reset
//   3. release the DUT, start the game, and COUNT its frame-buffer writes;
//      wait until it has drawn exactly the number of dots the reference drew
//   4. compare the head, game_over/running, and EVERY word of the image
//
// Counting writes is what makes this exact: the DUT never stops on its own
// while nothing is in the way, so waiting for `game_over` would hang. The same
// counter proves that a colliding dot is NOT drawn.
//
// THE START PIXEL IS PART OF THE LINE. The DUT tests and draws (START_X,
// START_Y) before taking its first step, so the reference starts by placing
// that pixel too. With the default start at (1,1) it is in open space and the
// first thing the line meets is the playfield.
//
// NO ARRAY PARAMETERS: the playfield is described by a small number of scalar
// rectangles/segments (PX0/PY/X1/ROWS/etc.) because a '{...} array literal is
// not accepted in a parameter override by this Questa version.
//
// FIELD GEOMETRY
//   The real field is 320x240, used by most cases. The LEFT-EDGE rule cannot be
//   reached from (1,1) heading right (the head hits x=319 first, reverses, and
//   then immediately runs into its own trail), so that case uses a small field
//   of the same shape plus START_DIR_R=0 to head left from the start.
`timescale 1ns/1ps

module game_case #(
    // field geometry
    parameter int CASE_W    = 320,
    parameter int CASE_H    = 240,
    parameter int CASE_WPR  = 10,
    parameter int CASE_AW   = 14,

    // playfield: SEG_N horizontal segments, segment k from (PX0[k],PY[k]) to
    // (PX1[k],PY[k]) inclusive. The arrays are always 16 entries (unused ones
    // are ignored) because a shorter literal would leave the tail undefined.
    parameter int SEG_N       = 0,
    parameter int PX0  [16]   = '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    parameter int PX1  [16]   = '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    parameter int PY   [16]   = '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},

    // button level per dot: bit d = the button for dot d
    parameter int MAX_DOTS         = 400,
    parameter logic [MAX_DOTS-1:0] BTN_MASK = '0,

    parameter int START_X          = 1,
    parameter int START_Y          = 1,
    parameter bit START_DIR_R      = 1'b1
)(
    input  logic clk,
    output bit   done,
    output int   errs
);
    localparam int FIELD_W       = CASE_W;
    localparam int FIELD_H       = CASE_H;
    localparam int WORDS_PER_ROW = CASE_WPR;
    localparam int AW            = CASE_AW;
    localparam int WORDS         = FIELD_H * WORDS_PER_ROW;

    localparam int MS_SCALE_CASE = 500;                       // 10 ms -> 1000 clk

    logic rst   = 1'b1;
    logic start = 1'b0;
    logic running, game_over;
    logic [8:0] dot_x;
    logic [7:0] dot_y;

    logic          pre_wr_en   = 1'b0;
    logic [AW-1:0] pre_wr_addr = '0;
    logic [31:0]   pre_wr_data = '0;

    logic          game_wr_en;
    logic [AW-1:0] game_wr_addr, fb_rd_addr;
    logic [31:0]   game_wr_data, fb_rd_data;

    // the preload port and the DUT's write port are muxed: the preload only
    // runs while the DUT is in reset (so the DUT cannot write), and the DUT
    // owns the port afterwards (so the preload cannot write)
    logic          fb_wr_en;
    logic [AW-1:0] fb_wr_addr;
    logic [31:0]   fb_wr_data;
    assign fb_wr_en   = pre_wr_en | game_wr_en;
    assign fb_wr_addr = pre_wr_en ? pre_wr_addr : game_wr_addr;
    assign fb_wr_data = pre_wr_en ? pre_wr_data : game_wr_data;

    logic [AW-1:0] rd_a_addr = '0;      // read port A unused in this test
    logic [31:0]   rd_a_data;
    logic          clr_start = 1'b0, clr_busy;

    logic btn;
    int   dot_idx;                      // dots drawn so far, per the DUT

    game_ctrl #(
        .CLK_FREQ_HZ  (50_000_000),
        .MS_SCALE     (MS_SCALE_CASE),
        .STEP_MS      (10),
        .LOCK_TO_FRAME(1'b0),          // rule test: exact 10 ms dots, no rounding
        .FIELD_W      (FIELD_W),
        .FIELD_H      (FIELD_H),
        .WORDS_PER_ROW(WORDS_PER_ROW),
        .AW           (AW),
        .START_X      (START_X),
        .START_Y      (START_Y),
        .START_DIR_R  (START_DIR_R)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .start     (start),
        .running   (running),
        .game_over (game_over),
        .btn       (btn),
        .dot_x     (dot_x),
        .dot_y     (dot_y),
        .fb_wr_en  (game_wr_en),
        .fb_wr_addr(game_wr_addr),
        .fb_wr_data(game_wr_data),
        .fb_rd_addr(fb_rd_addr),
        .fb_rd_data(fb_rd_data)
    );

    framebuffer #(
        .FIELD_W(FIELD_W), .FIELD_H(FIELD_H),
        .WORDS_PER_ROW(WORDS_PER_ROW), .AW(AW)
    ) fb (
        .clk(clk),
        .rd_addr(rd_a_addr),   .rd_data(rd_a_data),
        .rd2_addr(fb_rd_addr), .rd2_data(fb_rd_data),
        .wr_en(fb_wr_en), .wr_addr(fb_wr_addr), .wr_data(fb_wr_data),
        .clr_start(clr_start), .clr_busy(clr_busy)
    );

    // Button schedule. The reference uses BTN_MASK[d] to move OUT of dot d, and
    // the DUT reads `btn` during the hold after it has drawn dot d - by which
    // time dot_idx has already been incremented to d+1. So the index handed to
    // the DUT is dot_idx-1 (clamped, because dot_idx is 0 before the first dot
    // has been drawn).
    int sched_i;
    always_comb begin
        if (dot_idx <= 1)           sched_i = 0;
        else if (dot_idx > MAX_DOTS) sched_i = MAX_DOTS - 1;
        else                         sched_i = dot_idx - 1;
    end
    assign btn = BTN_MASK[sched_i];

    // count the dots the DUT draws
    always_ff @(posedge clk) begin
        if (rst) dot_idx <= 0;
        else if (game_wr_en) dot_idx <= dot_idx + 1;
    end

    // ------------------------------------------------------------------
    // reference models
    //   pre_model : the playfield only - this is what gets loaded into the
    //               frame buffer before the game starts. Loading the moving
    //               line too would make the DUT collide with itself at once.
    //   model     : playfield + the whole trajectory - this is what the image
    //               must look like at the end.
    // ------------------------------------------------------------------
    logic [31:0] pre_model [0:WORDS-1];
    logic [31:0] model     [0:WORDS-1];
    int          exp_x [0:MAX_DOTS+2];
    int          exp_y [0:MAX_DOTS+2];
    int          exp_n;
    bit          collided;
    int          coll_x, coll_y;

    function automatic void pre_set(input int x, input int y);
        pre_model[(y*WORDS_PER_ROW) + (x/32)][x%32] = 1'b1;
    endfunction

    function automatic bit pre_get(input int x, input int y);
        pre_get = pre_model[(y*WORDS_PER_ROW) + (x/32)][x%32];
    endfunction

    function automatic void model_set(input int x, input int y);
        model[(y*WORDS_PER_ROW) + (x/32)][x%32] = 1'b1;
    endfunction

    function automatic bit model_get(input int x, input int y);
        model_get = model[(y*WORDS_PER_ROW) + (x/32)][x%32];
    endfunction

    function automatic bit on_playfield(input int x, input int y);
        on_playfield = 1'b0;
        for (int k = 0; k < SEG_N; k++)
            if (y == PY[k] && x >= PX0[k] && x <= PX1[k]) on_playfield = 1'b1;
    endfunction

    int  errors;
    int  got_running, got_over, got_x, got_y;
    int  t0;

    initial begin : case_body
        errors = 0;
        errs   = 0;
        done   = 1'b0;

        // ---- playfield, then the reference trajectory ----------------
        // The moving line's "already drawn?" test runs against the playfield
        // ALONE, so the trajectory is simulated on top of pre_model and the
        // final picture is kept in model.
        begin
            int x, y, nx, ny;
            bit dir_r, nd, b, coll;

            x        = START_X;
            y        = START_Y;
            dir_r    = START_DIR_R;
            exp_n    = 0;
            collided = 1'b0;
            coll_x   = -1;
            coll_y   = -1;

            for (int i = 0; i < WORDS; i++) begin
                pre_model[i] = 32'h0000_0000;
                model[i]     = 32'h0000_0000;
            end
            for (int sy = 0; sy < FIELD_H; sy++)
                for (int sx = 0; sx < FIELD_W; sx++)
                    if (on_playfield(sx, sy)) begin
                        pre_set(sx, sy);
                        model_set(sx, sy);
                    end

            // the start pixel
            coll = pre_get(x, y);
            if (coll) begin
                collided = 1'b1;
                coll_x   = x;
                coll_y   = y;
            end else begin
                model_set(x, y);
                exp_x[0] = x;
                exp_y[0] = y;
                exp_n    = 1;
            end

            for (int d = 0; d < MAX_DOTS && !collided; d++) begin
                b = BTN_MASK[d];

                // --- one step of the rules --------------------------
                begin
                    bit hit_hi, hit_lo;
                    hit_hi = dir_r  && (x == FIELD_W-1);
                    hit_lo = (!dir_r) && (x == 0);
                    if (hit_hi || hit_lo) begin
                        nd = !dir_r;
                        nx = dir_r ? (x - 1) : (x + 1);
                    end else begin
                        nd = dir_r;
                        nx = dir_r ? (x + 1) : (x - 1);
                    end
                    if (b) ny = (y == 0)         ? 0         : (y - 1);
                    else   ny = (y == FIELD_H-1) ? FIELD_H-1 : (y + 1);
                end

                // the test is against the picture built so far, which starts
                // as the playfield and then includes the moving line
                coll = model_get(nx, ny);
                if (coll) begin
                    collided = 1'b1;
                    coll_x   = nx;
                    coll_y   = ny;
                    break;
                end

                model_set(nx, ny);
                exp_x[exp_n] = nx;
                exp_y[exp_n] = ny;
                exp_n        = exp_n + 1;
                x     = nx;
                y     = ny;
                dir_r = nd;
            end
        end

        // ---- load the PLAYFIELD into the frame buffer ---------------
        rst = 1'b1;
        repeat (4) @(negedge clk);
        for (int i = 0; i < WORDS; i++) begin
            @(negedge clk);
            pre_wr_en   <= 1'b1;
            pre_wr_addr <= i[AW-1:0];
            pre_wr_data <= pre_model[i];
        end
        @(negedge clk);
        pre_wr_en <= 1'b0;
        repeat (2) @(negedge clk);

        // ---- run the DUT -------------------------------------------
        repeat (2) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // ---- wait for the DUT --------------------------------------
        // If the reference ran into something, the DUT needs a whole step
        // period (STEP_CYCLES clocks) to reach its GAME OVER decision, so wait
        // for `game_over` itself. Otherwise wait until it has drawn every dot
        // the reference drew - it never stops on its own in that case.
        t0 = $time;
        if (collided) begin
            while (!game_over && ($time - t0) < 100_000_000) @(negedge clk);
            if ($time - t0 >= 100_000_000) begin
                errors++;
                $display("  FAIL the reference collided at (%0d,%0d) but game_over never asserted",
                         coll_x, coll_y);
            end
        end else begin
            while (dot_idx < exp_n && ($time - t0) < 100_000_000) @(negedge clk);
            if ($time - t0 >= 100_000_000) begin
                errors++;
                $display("  FAIL %0d dots drawn of %0d before the timeout",
                         dot_idx, exp_n);
            end
        end
        repeat (8) @(negedge clk);          // let the last write settle

        // ---- snapshot the observable state -------------------------
        got_running = running;
        got_over    = game_over;
        got_x       = dot_x;
        got_y       = dot_y;

        // ---- checks ------------------------------------------------
        if (collided) begin
            if (got_over !== 1) begin
                errors++;
                $display("  FAIL reference collided at (%0d,%0d) but game_over=%0d",
                         coll_x, coll_y, got_over);
            end
            if (got_running !== 0) begin
                errors++;
                $display("  FAIL GAME OVER but running=1");
            end
            if (got_x !== coll_x || got_y !== coll_y) begin
                errors++;
                $display("  FAIL head stopped at (%0d,%0d), expected (%0d,%0d)",
                         got_x, got_y, coll_x, coll_y);
            end
            if (dot_idx !== exp_n) begin
                errors++;
                $display("  FAIL %0d dots drawn, expected %0d (collision not drawn)",
                         dot_idx, exp_n);
            end
        end else begin
            if (got_over !== 0) begin
                errors++;
                $display("  FAIL unexpected GAME OVER at (%0d,%0d)", got_x, got_y);
            end
            if (exp_n > 0 && (got_x !== exp_x[exp_n-1] || got_y !== exp_y[exp_n-1])) begin
                errors++;
                $display("  FAIL head at (%0d,%0d), expected (%0d,%0d)",
                         got_x, got_y, exp_x[exp_n-1], exp_y[exp_n-1]);
            end
        end

        // ---- the whole image --------------------------------------
        for (int i = 0; i < WORDS; i++) begin
            if (fb.mem[i] !== model[i]) begin
                if (errors < 6)
                    $display("  FAIL word %0d = %08h expected %08h",
                             i, fb.mem[i], model[i]);
                errors++;
            end
        end

        if (errors == 0) begin
            if (collided)
                $display("  OK   %0d dots then GAME OVER at (%0d,%0d) [field %0dx%0d]",
                         exp_n, coll_x, coll_y, FIELD_W, FIELD_H);
            else
                $display("  OK   %0d dots, no collision [field %0dx%0d]",
                         exp_n, FIELD_W, FIELD_H);
        end else begin
            $display("  FAIL %0d errors [field %0dx%0d]", errors, FIELD_W, FIELD_H);
        end

        errs = errors;
        done = 1'b1;
    end
endmodule

// ----------------------------------------------------------------------
// Top: all cases run concurrently on one clock.
// ----------------------------------------------------------------------
module tb_game;
    localparam int CASES = 8;
    localparam int MAXD  = 64;

    logic clk = 1'b0;
    always #10 clk = ~clk;                     // 50 MHz

    bit done [0:CASES-1];
    int errs [0:CASES-1];

    localparam int SEG_NONE = 0;
    localparam int Z16 [16] = '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};

    // c0: button released -> down-right from (1,1)
    game_case #(
        .SEG_N(SEG_NONE), .PX0(Z16), .PX1(Z16), .PY(Z16),
        .MAX_DOTS(6), .BTN_MASK(6'd0),
        .START_X(1), .START_Y(1)
    ) c0_down_right (.clk(clk), .done(done[0]), .errs(errs[0]));

    // c1: button pressed from y=0 -> the row stays at 0, dots run right
    game_case #(
        .SEG_N(SEG_NONE), .PX0(Z16), .PX1(Z16), .PY(Z16),
        .MAX_DOTS(6), .BTN_MASK(6'b111111),
        .START_X(1), .START_Y(0)
    ) c1_up_right (.clk(clk), .done(done[1]), .errs(errs[1]));

    // c2: right-edge bounce. From (315,10) going down-right, x reaches 319
    //     after 4 dots and reverses (the row keeps advancing).
    game_case #(
        .SEG_N(SEG_NONE), .PX0(Z16), .PX1(Z16), .PY(Z16),
        .MAX_DOTS(12), .BTN_MASK(12'd0),
        .START_X(315), .START_Y(10)
    ) c2_right_bounce (.clk(clk), .done(done[2]), .errs(errs[2]));

    // c3: left-edge reversal, wide+short field and START_DIR_R=0 so the very
    //     first move can reach x=0.
    game_case #(
        .CASE_W(64), .CASE_H(4), .CASE_WPR(2), .CASE_AW(11),
        .SEG_N(SEG_NONE), .PX0(Z16), .PX1(Z16), .PY(Z16),
        .MAX_DOTS(12), .BTN_MASK(12'd0),
        .START_X(5), .START_Y(1), .START_DIR_R(1'b0)
    ) c3_left_bounce (.clk(clk), .done(done[3]), .errs(errs[3]));

    // c4: 3 dots down, then 4 dots up (bit d = the button level for dot d)
    game_case #(
        .SEG_N(SEG_NONE), .PX0(Z16), .PX1(Z16), .PY(Z16),
        .MAX_DOTS(7), .BTN_MASK(7'b0001111),
        .START_X(50), .START_Y(50)
    ) c4_button (.clk(clk), .done(done[4]), .errs(errs[4]));

    // c5: GAME OVER on a playfield pixel exactly on the trajectory. Button held
    //     from (0,5): the row clamps to 0 and the dots run right along row 0,
    //     so put a one-pixel segment at (6,0).
    game_case #(
        .SEG_N(1),
        .PX0('{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}),
        .PX1('{6,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}),
        .PY ('{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}),
        .MAX_DOTS(20), .BTN_MASK(20'hFFFFF),
        .START_X(0), .START_Y(5)
    ) c5_game_over (.clk(clk), .done(done[5]), .errs(errs[5]));

    // c6: the real 9-line playfield, button released. The moving line starts at
    //     (1,1) in open space and hits the first line (y=25) at (25,25).
    game_case #(
        .SEG_N(9),
        .PX0('{  0,  40,   0,  40,   0,  40,   0,  40,   0,0,0,0,0,0,0,0}),
        .PX1('{279, 319, 279, 319, 279, 319, 279, 319, 279,0,0,0,0,0,0,0}),
        .PY ('{ 25,  50,  75, 100, 125, 150, 175, 200, 225,0,0,0,0,0,0,0}),
        .MAX_DOTS(60), .BTN_MASK({60{1'b0}}),
        .START_X(1), .START_Y(1)
    ) c6_playfield (.clk(clk), .done(done[6]), .errs(errs[6]));

    // c7: bounce, then run into its own trail -> GAME OVER. On the 64x4 field
    //     from (57,0) with the button held: x hits 63, reverses, comes back
    //     down the same row and meets its own line.
    game_case #(
        .CASE_W(64), .CASE_H(4), .CASE_WPR(2), .CASE_AW(11),
        .SEG_N(SEG_NONE), .PX0(Z16), .PX1(Z16), .PY(Z16),
        .MAX_DOTS(60), .BTN_MASK(60'hFFFF_FFFF_FFFF_FFFF),
        .START_X(57), .START_Y(0)
    ) c7_bounce_then_stop (.clk(clk), .done(done[7]), .errs(errs[7]));

    int total_errors;
    int case_done;
    int t0;
    initial begin
        total_errors = 0;

        for (int i = 0; i < CASES; i++) begin
            t0 = $time;
            while (!done[i]) begin
                @(posedge clk);
                if ($time - t0 > 200_000_000) begin
                    $display("  FAIL case %0d never finished", i);
                    total_errors++;
                    break;
                end
            end
        end

        for (int i = 0; i < CASES; i++) total_errors += errs[i];

        case_done = 0;
        for (int i = 0; i < CASES; i++) case_done += done[i];
        if (case_done != CASES) begin
            total_errors++;
            $display("  FAIL only %0d of %0d case bodies ran", case_done, CASES);
        end

        if (total_errors == 0)
            $display("*** tb_game: PASS (%0d cases) ***", CASES);
        else
            $display("*** tb_game: FAIL (%0d errors over %0d cases) ***",
                     total_errors, CASES);
        $finish;
    end
endmodule
