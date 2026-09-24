// tb_line_draw.sv
//
// Checks line_draw.sv, which now writes EACH playfield line to two places:
//
//   1. the frame buffer (the game's collision model), one read-modify-write
//      per 32-pixel word
//   2. the panel, as ONE rectangle request per line ("行単位で描画")
//
// Both are verified:
//   * the ENTIRE 320x240 buffer is compared against a software reference model,
//     so a stray write anywhere shows up immediately
//   * every LCD request the module emits is collected and compared against the
//     table: there must be exactly one per non-empty line, with
//     x0..x1 = the (clamped) span, y0 = y1 = the line's row, and the colour
//
// Each case gets its own line_draw + framebuffer instance, so the cases are
// independent and run concurrently on one clock. The LCD side is modelled with
// a simple ready that is high most of the time, with some de-asserted cycles so
// the valid/ready handshake is actually exercised (the module must hold the
// request until it is accepted).
//
// The single-line cases deliberately cover the logic that a full-width line
// never exercises:
//   c0  (0,15)-(319,15)   full width, 10 whole words, no partial masks
//   c1  (17,20)-(301,20)  both ends part-way into their word -> partial masks
//   c2  (5,40)-(10,40)    start and end inside the SAME word
//   c3  (31,60)-(32,60)   crosses a word boundary, bit 31 -> bit 0
//   c4  (0,239)-(319,239) the last row of the buffer (highest address)
//
// The multi-line cases cover the table sequencing:
//   c5  the nine real lines of the design, one of them a single pixel
//   c6  two OVERLAPPING lines on the same row -> read-modify-write must OR
//   c7  16 lines (the size of the line counter) spread over the panel
//   c8  an empty line (x0 > x1) mixed into the table -> must be skipped
//   c9  a line whose x1 runs past the row (400) -> must stop at column 319
//       instead of spilling into the next row's words
`timescale 1ns/1ps

// ----------------------------------------------------------------------
// One self-checking case: clear, draw the whole line table, compare every
// word of the buffer AND every LCD request against the reference model.
// ----------------------------------------------------------------------
module line_case #(
    parameter int N      = 1,
    parameter int X0 [N] = '{0},
    parameter int X1 [N] = '{319},
    parameter int Y  [N] = '{15}
)(
    input  logic clk,
    output bit   done,
    output int   errs
);
    localparam int FIELD_W       = 320;
    localparam int FIELD_H       = 240;
    localparam int WORDS_PER_ROW = FIELD_W / 32;             // 10
    localparam int WORDS         = FIELD_H * WORDS_PER_ROW;  // 2400
    localparam int AW            = 14;
    localparam logic [15:0] COLOR = 16'hF800;

    logic          start = 1'b0, busy;
    logic          fb_wr_en;
    logic [AW-1:0] fb_wr_addr, fb_rd_addr;
    logic [31:0]   fb_wr_data, fb_rd_data;
    logic          clr_start = 1'b0, clr_busy;
    logic          rst = 1'b0;

    // ---- LCD request port ---------------------------------------------
    logic        lcd_valid, lcd_ready;
    logic [8:0]  lcd_x0, lcd_x1;
    logic [7:0]  lcd_y0, lcd_y1;
    logic [15:0] lcd_color;

    line_draw #(
        .FIELD_W(FIELD_W), .WORDS_PER_ROW(WORDS_PER_ROW), .AW(AW),
        .COLOR(COLOR),
        .N_LINES(N), .LINE_X0(X0), .LINE_X1(X1), .LINE_Y(Y)
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
    // A simple model: ready is high, but it drops for a couple of cycles every
    // few clocks so the module has to hold the request. Each accepted request
    // is stored so it can be compared against the table afterwards.
    int unsigned free_cnt = 0;
    int          n_req    = 0;

    localparam int MAX_REQ = 16;
    int          req_x0 [0:MAX_REQ-1];
    int          req_x1 [0:MAX_REQ-1];
    int          req_y0 [0:MAX_REQ-1];
    int          req_y1 [0:MAX_REQ-1];
    int          req_col[0:MAX_REQ-1];

    always_ff @(posedge clk) begin
        free_cnt <= free_cnt + 1;
    end

    // ready drops while free_cnt is in a small window, i.e. ready is high
    // 6 out of every 8 cycles
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

    logic [31:0] exp_mem [0:WORDS-1];
    int          errors;

    // the expected LCD requests: one per non-empty line, x1 clamped
    int          exp_x0 [0:N-1];
    int          exp_x1 [0:N-1];
    int          exp_y  [0:N-1];
    int          exp_n     = 0;

    initial begin : case_body
        errors    = 0;
        errs      = 0;
        done      = 1'b0;

        // ---- clear the whole buffer --------------------------------
        @(negedge clk);
        clr_start = 1'b1;
        @(negedge clk);
        clr_start = 1'b0;
        while (clr_busy) @(negedge clk);
        repeat (2) @(negedge clk);

        // ---- draw the line -----------------------------------------
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        begin
            int t0;
            t0 = $time;
            while (busy || lcd_valid) begin
                @(posedge clk);
                if ($time - t0 > 200_000) begin
                    $display("  FAIL case (%0d lines) timed out in state %0d",
                             N, dut.state);
                    errors++;
                    errs   = errors;
                    done   = 1'b1;
                    disable case_body;
                end
            end
        end
        repeat (2) @(negedge clk);

        // ---- reference model: zeros, then every line's pixels set ----
        // Overlapping lines are OR-ed together, which is exactly what the
        // read-modify-write datapath does. The end column is clamped to the
        // field width, matching the RTL.
        for (int i = 0; i < WORDS; i++) exp_mem[i] = 32'h0000_0000;
        for (int k = 0; k < N; k++) begin
            int ex1;
            ex1 = (X1[k] > FIELD_W-1) ? FIELD_W-1 : X1[k];
            for (int x = X0[k]; x <= ex1; x++)
                exp_mem[(Y[k]*WORDS_PER_ROW) + (x/32)][x%32] = 1'b1;
        end

        // ---- compare every word of the collision model --------------
        for (int i = 0; i < WORDS; i++) begin
            if (fb.mem[i] !== exp_mem[i]) begin
                if (errors < 5)
                    $display("  FAIL case (%0d lines): word %0d = %08h expected %08h",
                             N, i, fb.mem[i], exp_mem[i]);
                errors++;
            end
        end

        // ---- compare the LCD requests against the table ------------
        // One rectangle per NON-EMPTY line, same order as the table.
        for (int k = 0; k < N; k++) begin
            int ex1;
            ex1 = (X1[k] > FIELD_W-1) ? FIELD_W-1 : X1[k];
            if ((X0[k] <= X1[k]) && (X0[k] < FIELD_W)) begin
                exp_x0[exp_n] = X0[k];
                exp_x1[exp_n] = ex1;
                exp_y [exp_n] = Y [k];
                exp_n = exp_n + 1;
            end
        end

        if (n_req != exp_n) begin
            if (errors < 8)
                $display("  FAIL case (%0d lines): %0d LCD requests, expected %0d",
                         N, n_req, exp_n);
            errors++;
        end
        for (int k = 0; k < exp_n && k < n_req && k < MAX_REQ; k++) begin
            if (req_x0[k] !== exp_x0[k] || req_x1[k] !== exp_x1[k] ||
                req_y0[k] !== exp_y [k] || req_y1[k] !== exp_y[k] ||
                req_col[k] !== int'(COLOR)) begin
                if (errors < 8)
                    $display("  FAIL case (%0d lines): LCD req %0d = (%0d,%0d)-(%0d,%0d) col %04h, expected (%0d,%0d)-(%0d,%0d) col %04h",
                             N, k, req_x0[k], req_y0[k], req_x1[k], req_y1[k],
                             req_col[k], exp_x0[k], exp_y[k], exp_x1[k], exp_y[k],
                             COLOR);
                errors++;
            end
        end

        if (errors == 0)
            $display("  OK   %0d line(s): all %0d words + %0d LCD reqs correct",
                     N, WORDS, exp_n);
        else
            $display("  FAIL %0d line(s): %0d errors", N, errors);

        errs = errors;
        done = 1'b1;
    end
endmodule

// ----------------------------------------------------------------------
// Top: run all the cases concurrently against a shared clock.
// ----------------------------------------------------------------------
module tb_line_draw;
    localparam int CASES = 10;

    logic clk = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    // done/errs MUST be 2-state here, otherwise they are x at time 0 and the
    // "wait until done[i]" loop below falls straight through -> every case is
    // skipped and the test reports a vacuous PASS at time 0. `bit` makes them
    // 0 to start with.
    bit done [0:CASES-1];
    int errs [0:CASES-1];

    // ---- single-line cases (masks, boundaries, last row) ------------
    line_case #(.N(1), .X0('{0}),  .X1('{319}), .Y('{15 })) c0
        (.clk(clk), .done(done[0]), .errs(errs[0]));
    line_case #(.N(1), .X0('{17}), .X1('{301}), .Y('{20 })) c1
        (.clk(clk), .done(done[1]), .errs(errs[1]));
    line_case #(.N(1), .X0('{5}),  .X1('{10}),  .Y('{40 })) c2
        (.clk(clk), .done(done[2]), .errs(errs[2]));
    line_case #(.N(1), .X0('{31}), .X1('{32}),  .Y('{60 })) c3
        (.clk(clk), .done(done[3]), .errs(errs[3]));
    line_case #(.N(1), .X0('{0}),  .X1('{319}), .Y('{239})) c4
        (.clk(clk), .done(done[4]), .errs(errs[4]));

    // ---- the nine real lines of the design -------------------------
    line_case #(
        .N (9),
        .X0('{  0,  40,   0,  40,   0,  40,   0,  40,   0}),
        .X1('{279, 319, 279, 319, 279, 319, 279, 319, 279}),
        .Y ('{ 25,  50,  75, 100, 125, 150, 175, 200, 225})
    ) c5 (.clk(clk), .done(done[5]), .errs(errs[5]));

    // ---- two overlapping lines on the same row (OR semantics) ------
    line_case #(
        .N (2),
        .X0('{0,   100}),
        .X1('{200, 319}),
        .Y ('{100, 100})
    ) c6 (.clk(clk), .done(done[6]), .errs(errs[6]));

    // ---- 16 lines: the whole range of the line counter -------------
    line_case #(
        .N (16),
        .X0('{0,10,20,30,40,50,60,70,    0, 5,99,31,32,  7, 8,  0}),
        .X1('{319,319,319,319,319,319,319,319, 319, 5,99,31,32, 63, 8,239}),
        .Y ('{0,15,30,45,60,75,90,105,  120,135,150,165,180,195,210,225})
    ) c7 (.clk(clk), .done(done[7]), .errs(errs[7]));

    // ---- an empty line has to be skipped without disturbing the rest
    line_case #(
        .N (3),
        .X0('{  0,  40,   0}),
        .X1('{100,  10, 200}),      // entry 1 is x0=40 > x1=10
        .Y ('{ 10,  40,  70})
    ) c8 (.clk(clk), .done(done[8]), .errs(errs[8]));

    // ---- x1 past the right edge must stop at column 319 ------------
    line_case #(.N(1), .X0('{300}), .X1('{400}), .Y('{200})) c9
        (.clk(clk), .done(done[9]), .errs(errs[9]));

    int total_errors;
    int case_done;
    int t0;
    initial begin
        total_errors = 0;

        // wait for every case to finish
        for (int i = 0; i < CASES; i++) begin
            t0 = $time;
            while (!done[i]) begin
                @(posedge clk);
                if ($time - t0 > 1_000_000) begin
                    $display("  FAIL case %0d never finished", i);
                    total_errors++;
                    break;
                end
            end
        end

        for (int i = 0; i < CASES; i++) total_errors += errs[i];

        // every case body sets done[] only at the very end, so a short count
        // means a body never ran and the test must not report a pass
        case_done = 0;
        for (int i = 0; i < CASES; i++) case_done += done[i];
        if (case_done != CASES) begin
            total_errors++;
            $display("  FAIL only %0d of %0d case bodies ran", case_done, CASES);
        end

        if (total_errors == 0)
            $display("*** tb_line_draw: PASS (%0d cases, words + LCD requests) ***",
                     CASES);
        else
            $display("*** tb_line_draw: FAIL (%0d errors over %0d cases) ***",
                     total_errors, CASES);
        $finish;
    end
endmodule
