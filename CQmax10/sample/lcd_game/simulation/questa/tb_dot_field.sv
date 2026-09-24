// tb_dot_field.sv
//
// Checks dot_field.sv, the "random dots" of prompt.txt #5:
//
//   * N_DOTS rectangles of DOT_W x DOT_H, scattered at pseudo-random positions
//   * written to BOTH destinations: the frame buffer (the collision model) and
//     the panel (one rectangle request per dot)
//
// WHAT IS CHECKED
//
//   1. COUNT      exactly N_DOTS panel requests, in order
//   2. GEOMETRY   every request is a DOT_W x DOT_H rectangle
//                 (x1 = x0+DOT_W-1, y1 = y0+DOT_H-1)
//   3. RANGE      every dot lies inside (X_MIN,Y_MIN)-(X_MAX,Y_MAX) and a
//                 whole dot fits on the panel (x0+DOT_W-1 <= 319, y0+DOT_H-1 <= 239)
//   4. FRAME BUF  the buffer contains EXACTLY the dot pixels and nothing else
//                 (all 2400 words compared against a reference model built
//                 from the captured positions)
//   5. VARIETY    the positions are not all the same, and both X and Y move
//                 around rather than creeping in one direction - a trivial
//                 "always 2,2" or "x = x+1" implementation must fail
//   6. RE-SEED    a second run reproduces the SAME sequence (the generator is
//                 deterministic and re-seeded from SEED on every `start`)
//   7. DIFF SEED  a different SEED gives a different sequence
//
// The generator itself is checked independently by a software model: the LFSR
// is stepped in the testbench exactly as the RTL does (the TB owns the seed,
// the polynomial and the rejection rule) and the predicted positions must be
// the observed ones, dot by dot. That pins the hardware sequence to the
// documented algorithm even if the RTL is rewritten.
//
// The LCD side uses the same "ready is high 6 of 8 cycles" model as
// tb_line_draw, so the valid/ready hold is exercised as well.
`timescale 1ns/1ps

// ----------------------------------------------------------------------
// One run: draw the dots, then compare requests + buffer + variety.
// ----------------------------------------------------------------------
module dot_case #(
    parameter int  N        = 20,
    parameter int  DW       = 2,
    parameter int  DH       = 2,
    parameter int  XMIN     = 2,
    parameter int  XMAX     = 318,
    parameter int  YMIN     = 2,
    parameter int  YMAX     = 318,
    parameter logic [31:0] SEED = 32'hACE1_2345,
    parameter bit  REPEAT   = 1'b0   // run twice and require the same sequence
)(
    input  logic clk,
    output bit   done,
    output int   errs,
    output int   sig_first_x,          // first dot position, for cross-case compare
    output int   sig_first_y
);
    localparam int FIELD_W       = 320;
    localparam int FIELD_H       = 240;
    localparam int WORDS_PER_ROW = FIELD_W / 32;             // 10
    localparam int WORDS         = FIELD_H * WORDS_PER_ROW;  // 2400
    localparam int AW            = 14;
    localparam logic [15:0] COLOR = 16'hF81F;

    logic          start = 1'b0, busy;
    logic          fb_wr_en;
    logic [AW-1:0] fb_wr_addr, fb_rd_addr;
    logic [31:0]   fb_wr_data, fb_rd_data;
    logic          clr_start = 1'b0, clr_busy;
    logic          rst = 1'b0;

    logic        lcd_valid, lcd_ready;
    logic [8:0]  lcd_x0, lcd_x1;
    logic [7:0]  lcd_y0, lcd_y1;
    logic [15:0] lcd_color;

    dot_field #(
        .FIELD_W(FIELD_W), .FIELD_H(FIELD_H),
        .WORDS_PER_ROW(WORDS_PER_ROW), .AW(AW),
        .N_DOTS(N), .DOT_W(DW), .DOT_H(DH),
        .X_MIN(XMIN), .X_MAX(XMAX), .Y_MIN(YMIN), .Y_MAX(YMAX),
        .SEED(SEED), .COLOR(COLOR)
    ) dut (
        .clk(clk), .rst(rst),
        .start(start), .busy(busy),
        .fb_wr_en(fb_wr_en), .fb_wr_addr(fb_wr_addr), .fb_wr_data(fb_wr_data),
        .fb_rd_addr(fb_rd_addr), .fb_rd_data(fb_rd_data),
        .lcd_valid(lcd_valid), .lcd_ready(lcd_ready),
        .lcd_x0(lcd_x0), .lcd_y0(lcd_y0), .lcd_x1(lcd_x1), .lcd_y1(lcd_y1),
        .lcd_color(lcd_color)
    );

    framebuffer #(
        .FIELD_W(FIELD_W), .FIELD_H(FIELD_H),
        .WORDS_PER_ROW(WORDS_PER_ROW), .AW(AW)
    ) fb (
        .clk(clk),
        .rd_addr(fb_rd_addr), .rd_data(fb_rd_data),
        .wr_en(fb_wr_en), .wr_addr(fb_wr_addr), .wr_data(fb_wr_data),
        .clr_start(clr_start), .clr_busy(clr_busy)
    );

    // ---- LCD request capture -------------------------------------------
    int unsigned free_cnt = 0;
    int          n_req    = 0;

    localparam int MAX_REQ = 64;
    int          req_x0 [0:MAX_REQ-1];
    int          req_x1 [0:MAX_REQ-1];
    int          req_y0 [0:MAX_REQ-1];
    int          req_y1 [0:MAX_REQ-1];
    int          req_col[0:MAX_REQ-1];

    always_ff @(posedge clk) free_cnt <= free_cnt + 1;

    // ready high 6 of every 8 cycles (same model as tb_line_draw)
    assign lcd_ready = (free_cnt[2:0] != 3'd6) && (free_cnt[2:0] != 3'd7);

    always_ff @(posedge clk) begin
        if (lcd_valid && lcd_ready) begin
            if (n_req < MAX_REQ) begin
                req_x0 [n_req] <= int'(lcd_x0);
                req_x1 [n_req] <= int'(lcd_x1);
                req_y0 [n_req] <= int'(lcd_y0);
                req_y1 [n_req] <= int'(lcd_y1);
                req_col[n_req] <= int'(lcd_color);
            end
            n_req <= n_req + 1;
        end
    end

    // ---- software model of the LFSR -------------------------------------
    // Same 32-bit Galois LFSR (taps 32,22,2,1) and the same rejection rule as
    // the RTL. `lfsr_bit[i]` returns bit i of the register after one step,
    // which is how the RTL builds its candidate.
    logic [31:0] lfsr_ref;
    int          pred_x [0:MAX_REQ-1];
    int          pred_y [0:MAX_REQ-1];

    function automatic logic [31:0] lfsr_step(input logic [31:0] v);
        logic fb_bit;
        begin
            fb_bit   = v[31] ^ v[21] ^ v[1] ^ v[0];
            lfsr_step = {v[30:0], fb_bit};
        end
    endfunction

    task automatic build_prediction;
        int i, tries;
        int xlast, ylast;
        begin
            xlast = (XMAX > (FIELD_W - DW)) ? (FIELD_W - DW) : XMAX;
            ylast = (YMAX > (FIELD_H - DH)) ? (FIELD_H - DH) : YMAX;
            lfsr_ref = SEED;
            for (i = 0; i < N; i++) begin
                // X: step until in range
                tries = 0;
                forever begin
                    lfsr_ref = lfsr_step(lfsr_ref);
                    tries++;
                    if ((int'(lfsr_ref[8:0]) >= XMIN) && (int'(lfsr_ref[8:0]) <= xlast)) begin
                        pred_x[i] = int'(lfsr_ref[8:0]);
                        break;
                    end
                    if (tries > 200) begin
                        $display("  FAIL prediction did not converge for X (dot %0d)", i);
                        pred_x[i] = -1;
                        break;
                    end
                end
                // Y: step until in range
                tries = 0;
                forever begin
                    lfsr_ref = lfsr_step(lfsr_ref);
                    tries++;
                    if ((int'(lfsr_ref[7:0]) >= YMIN) && (int'(lfsr_ref[7:0]) <= ylast)) begin
                        pred_y[i] = int'(lfsr_ref[7:0]);
                        break;
                    end
                    if (tries > 200) begin
                        $display("  FAIL prediction did not converge for Y (dot %0d)", i);
                        pred_y[i] = -1;
                        break;
                    end
                end
            end
        end
    endtask

    logic [31:0] exp_mem [0:WORDS-1];
    int          errors;

    // ---- one run of the DUT ---------------------------------------------
    task automatic run_once(output int got_n);
        begin
            @(negedge clk);
            clr_start = 1'b1;
            @(negedge clk);
            clr_start = 1'b0;
            while (clr_busy) @(negedge clk);
            repeat (2) @(negedge clk);

            n_req = 0;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            fork : watchdog
                begin
                    int t0;
                    t0 = $time;
                    while (busy || lcd_valid) begin
                        @(posedge clk);
                        if ($time - t0 > 500_000) begin
                            $display("  FAIL dot_field timed out in state %0d", dut.state);
                            errors++;
                            disable watchdog;
                        end
                    end
                end
            join
            repeat (2) @(negedge clk);
            got_n = n_req;
        end
    endtask

    int n1, n2;

    initial begin : case_body
        int xlast, ylast;
        errors = 0;
        errs   = 0;
        done   = 1'b0;
        sig_first_x = -1;
        sig_first_y = -1;

        xlast = (XMAX > (FIELD_W - DW)) ? (FIELD_W - DW) : XMAX;
        ylast = (YMAX > (FIELD_H - DH)) ? (FIELD_H - DH) : YMAX;

        build_prediction;

        // ================= run 1 =================
        run_once(n1);

        // ---- 1. count ------------------------------------------------
        if (n1 != N) begin
            $display("  FAIL dot_field: %0d requests, expected %0d", n1, N);
            errors++;
        end

        // ---- 2/3. geometry and range ---------------------------------
        for (int i = 0; i < N && i < MAX_REQ; i++) begin
            if (req_x1[i] - req_x0[i] != DW-1 || req_y1[i] - req_y0[i] != DH-1) begin
                if (errors < 6)
                    $display("  FAIL dot %0d size: (%0d,%0d)-(%0d,%0d) is not %0dx%0d",
                             i, req_x0[i], req_y0[i], req_x1[i], req_y1[i], DW, DH);
                errors++;
            end
            if (req_x0[i] < XMIN || req_x0[i] > xlast ||
                req_y0[i] < YMIN || req_y0[i] > ylast) begin
                if (errors < 6)
                    $display("  FAIL dot %0d out of range: (%0d,%0d), allowed (%0d,%0d)-(%0d,%0d)",
                             i, req_x0[i], req_y0[i], XMIN, YMIN, xlast, ylast);
                errors++;
            end
            if (req_x0[i] + DW - 1 >= FIELD_W || req_y0[i] + DH - 1 >= FIELD_H) begin
                if (errors < 6)
                    $display("  FAIL dot %0d runs off the panel: (%0d,%0d)+%0dx%0d",
                             i, req_x0[i], req_y0[i], DW, DH);
                errors++;
            end
            if (req_col[i] !== int'(COLOR)) begin
                if (errors < 6)
                    $display("  FAIL dot %0d colour %04h, expected %04h",
                             i, req_col[i], COLOR);
                errors++;
            end
        end

        // ---- 5. the sequence matches the software model ---------------
        // This is the real check of the pseudo-random sequence: the TB owns
        // the seed, the polynomial and the rejection rule, so the hardware
        // must reproduce them exactly.
        for (int i = 0; i < N && i < MAX_REQ; i++) begin
            if (req_x0[i] !== pred_x[i] || req_y0[i] !== pred_y[i]) begin
                if (errors < 6)
                    $display("  FAIL dot %0d = (%0d,%0d), model says (%0d,%0d)",
                             i, req_x0[i], req_y0[i], pred_x[i], pred_y[i]);
                errors++;
            end
        end

        // ---- 4. frame buffer content ---------------------------------
        // The buffer must hold EXACTLY the dot pixels: every other bit clear,
        // and every dot pixel set. Built from the PREDICTED positions, so a
        // wrong position is caught here as well as by the request check.
        for (int i = 0; i < WORDS; i++) exp_mem[i] = 32'h0000_0000;
        for (int d = 0; d < N; d++) begin
            if (pred_x[d] < 0 || pred_y[d] < 0) continue;
            for (int dy = 0; dy < DH; dy++) begin
                for (int dx = 0; dx < DW; dx++) begin
                    int px, py;
                    px = pred_x[d] + dx;
                    py = pred_y[d] + dy;
                    exp_mem[(py*WORDS_PER_ROW) + (px/32)][px%32] = 1'b1;
                end
            end
        end
        for (int i = 0; i < WORDS; i++) begin
            if (fb.mem[i] !== exp_mem[i]) begin
                if (errors < 8)
                    $display("  FAIL buffer word %0d = %08h expected %08h",
                             i, fb.mem[i], exp_mem[i]);
                errors++;
            end
        end

        // ---- 6/7. variety and determinism ----------------------------
        // Variety: not all dots in the same place, and both coordinates use
        // more than one value (a creeping counter would fail).
        begin
            bit same_xy, x_moves, y_moves;
            same_xy = 1'b1;
            x_moves = 1'b0;
            y_moves = 1'b0;
            for (int i = 1; i < N && i < MAX_REQ; i++) begin
                if (req_x0[i] != req_x0[0] || req_y0[i] != req_y0[0]) same_xy = 1'b0;
                if (req_x0[i] != req_x0[0]) x_moves = 1'b1;
                if (req_y0[i] != req_y0[0]) y_moves = 1'b1;
            end
            if (N > 1 && same_xy) begin
                $display("  FAIL the PRNG produced the same position %0d times", N);
                errors++;
            end
            if (N > 1 && !x_moves) begin
                $display("  FAIL X never changed");
                errors++;
            end
            if (N > 1 && !y_moves) begin
                $display("  FAIL Y never changed");
                errors++;
            end
        end

        // determinism: re-running from the same SEED must give the same dots
        if (REPEAT) begin
            run_once(n2);
            if (n2 != n1) begin
                $display("  FAIL re-run produced %0d requests, expected %0d", n2, n1);
                errors++;
            end
            for (int i = 0; i < N && i < MAX_REQ; i++) begin
                if (req_x0[i] !== pred_x[i] || req_y0[i] !== pred_y[i]) begin
                    if (errors < 8)
                        $display("  FAIL re-run dot %0d = (%0d,%0d), expected (%0d,%0d) (not re-seeded?)",
                                 i, req_x0[i], req_y0[i], pred_x[i], pred_y[i]);
                    errors++;
                end
            end
        end

        if (N > 0 && n1 > 0) begin
            sig_first_x = req_x0[0];
            sig_first_y = req_y0[0];
        end

        if (errors == 0)
            $display("  OK   %0d dots of %0dx%0d in (%0d,%0d)-(%0d,%0d): sequence, range, buffer all correct (first = (%0d,%0d))",
                     N, DW, DH, XMIN, YMIN, xlast, ylast, req_x0[0], req_y0[0]);
        else
            $display("  FAIL %0d dots: %0d errors", N, errors);

        errs = errors;
        done = 1'b1;
    end
endmodule

// ----------------------------------------------------------------------
// Top
// ----------------------------------------------------------------------
module tb_dot_field;
    localparam int CASES = 7;

    logic clk = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    bit done [0:CASES-1];
    int errs [0:CASES-1];
    int sx   [0:CASES-1];
    int sy   [0:CASES-1];

    // the real configuration of the design
    dot_case #(.N(20), .DW(2), .DH(2),
               .XMIN(2), .XMAX(318), .YMIN(2), .YMAX(318),
               .SEED(32'hACE1_2345), .REPEAT(1'b1)) c0
        (.clk(clk), .done(done[0]), .errs(errs[0]),
         .sig_first_x(sx[0]), .sig_first_y(sy[0]));

    // same seed -> the same first dot (determinism across instances, not only
    // across re-runs within one instance)
    dot_case #(.N(20), .DW(2), .DH(2),
               .XMIN(2), .XMAX(318), .YMIN(2), .YMAX(318),
               .SEED(32'hACE1_2345), .REPEAT(1'b0)) c1
        (.clk(clk), .done(done[1]), .errs(errs[1]),
         .sig_first_x(sx[1]), .sig_first_y(sy[1]));

    // a different seed must give a different sequence
    dot_case #(.N(20), .DW(2), .DH(2),
               .XMIN(2), .XMAX(318), .YMIN(2), .YMAX(318),
               .SEED(32'h1234_5678), .REPEAT(1'b0)) c2
        (.clk(clk), .done(done[2]), .errs(errs[2]),
         .sig_first_x(sx[2]), .sig_first_y(sy[2]));

    // 1x1 dots: the same datapath with a single pixel per dot
    dot_case #(.N(8), .DW(1), .DH(1),
               .XMIN(2), .XMAX(318), .YMIN(2), .YMAX(318),
               .SEED(32'hACE1_2345), .REPEAT(1'b0)) c3
        (.clk(clk), .done(done[3]), .errs(errs[3]),
         .sig_first_x(sx[3]), .sig_first_y(sy[3]));

    // 3x3 dots: nine read-modify-writes per dot
    dot_case #(.N(6), .DW(3), .DH(3),
               .XMIN(2), .XMAX(318), .YMIN(2), .YMAX(318),
               .SEED(32'hACE1_2345), .REPEAT(1'b0)) c4
        (.clk(clk), .done(done[4]), .errs(errs[4]),
         .sig_first_x(sx[4]), .sig_first_y(sy[4]));

    // a narrow range: rejection sampling has to work hard in X
    dot_case #(.N(4), .DW(2), .DH(2),
               .XMIN(10), .XMAX(20), .YMIN(200), .YMAX(210),
               .SEED(32'hACE1_2345), .REPEAT(1'b0)) c5
        (.clk(clk), .done(done[5]), .errs(errs[5]),
         .sig_first_x(sx[5]), .sig_first_y(sy[5]));

    // a Y range that runs off the bottom of the panel must be clamped, not
    // wrapped: (2,2)-(318,318) is asked for but only 240 rows exist
    dot_case #(.N(20), .DW(2), .DH(2),
               .XMIN(2), .XMAX(318), .YMIN(2), .YMAX(318),
               .SEED(32'h0BAD_F00D), .REPEAT(1'b0)) c6
        (.clk(clk), .done(done[6]), .errs(errs[6]),
         .sig_first_x(sx[6]), .sig_first_y(sy[6]));

    int total;
    initial begin
        total = 0;
        for (int i = 0; i < CASES; i++) while (!done[i]) @(posedge clk);
        for (int i = 0; i < CASES; i++) total += errs[i];
        // the two instances with the same seed start from the same dot
        if (sx[0] != sx[1] || sy[0] != sy[1]) begin
            $display("  FAIL same SEED gave different first dots: (%0d,%0d) vs (%0d,%0d)",
                     sx[0], sy[0], sx[1], sy[1]);
            total++;
        end
        // a different seed starts somewhere else
        if (sx[0] == sx[2] && sy[0] == sy[2]) begin
            $display("  FAIL a different SEED gave the same first dot (%0d,%0d)",
                     sx[0], sy[0]);
            total++;
        end

        if (total == 0)
            $display("*** tb_dot_field: PASS (%0d cases, PRNG + range + buffer) ***", CASES);
        else
            $display("*** tb_dot_field: FAIL (%0d errors) ***", total);
        $finish;
    end
endmodule
