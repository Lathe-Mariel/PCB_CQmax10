// tb_renderer.sv
//
// Focused test of lcd_renderer + board_memory + logo_ram (the pixel path of
// `samegame_top`).
//
// The logo store is loaded with the *identity* pattern  mem[a] = a, so the
// expected colour for a pixel is simply the logo ROM address it should fetch:
//
//     expected = 400*id + 20*(y%20) + (x%20)      (id = 0..4)
//     expected = BG_COLOR                          (id = EMPTY)
//
// Tests:
//   1. static sweep   : every one of the 320x240 pixels, against the model
//   2. fall end       : anim_mode 2 with fall_px past the end == static image
//   3. shift end      : anim_mode 3 with shift_px past the end == static image
//   4. fall middle    : one block, hand-computed position at fall_px = 20
//   5. blink          : cells in blink_mask are blanked while blink_on == 0
//
// The pixels are streamed back-to-back (one request per clock, like the LCD
// controller does) and the k-th `pix_valid` is compared with the k-th request,
// so the test also proves that exactly one pixel comes back per request.

`timescale 1ns/1ps

module tb_renderer;
    localparam int COLS    = 16;
    localparam int ROWS    = 12;
    localparam int CELLS   = COLS * ROWS;
    localparam int AW      = 8;
    localparam int RA_W    = 11;
    localparam int SCREEN_W = COLS * 20;      // 320
    localparam int SCREEN_H = ROWS * 20;      // 240
    localparam logic [2:0] EMPTY = 3'b111;
    localparam logic [15:0] BG_COLOR = 16'h0000;

    logic clk = 1'b0;
    always #10 clk = ~clk;                    // 50 MHz

    logic rst = 1'b1;

    // ---- board memory ----
    logic          bm_wr_en;
    logic [AW-1:0] bm_wr_addr;
    logic [2:0]    bm_wr_data;
    logic          bm_clr_start, bm_clr_busy;
    logic [AW-1:0] bm_rd_addr_a;
    logic [2:0]    bm_rd_data_a;

    board_memory #(.COLS(COLS), .ROWS(ROWS), .AW(AW)) u_bm (
        .clk(clk), .rst(rst),
        .wr_en(bm_wr_en), .wr_addr(bm_wr_addr), .wr_data(bm_wr_data),
        .clr_start(bm_clr_start), .clr_busy(bm_clr_busy),
        .rd_addr_a(bm_rd_addr_a), .rd_data_a(bm_rd_data_a),
        .rd_addr_b(AW'(0)), .rd_data_b(),
        .rd_col(4'd0), .col_data()
    );

    // ---- logo store (identity pattern) ----
    logic [RA_W-1:0] ram_addr;
    logic [15:0]     ram_data;
    logic            ram_wr_en;
    logic [RA_W-1:0] ram_wr_addr;
    logic [15:0]     ram_wr_data;

    logo_ram #(.ROM_DEPTH(2000), .MEM_DEPTH(2048), .AW(RA_W), .DW(16)) u_ram (
        .clk(clk),
        .rd_addr(ram_addr), .rd_data(ram_data),
        .wr_en(ram_wr_en), .wr_addr(ram_wr_addr), .wr_data(ram_wr_data)
    );

    // ---- renderer ----
    logic        pix_req, pix_valid;
    logic [8:0]  pix_x;
    logic [7:0]  pix_y;
    logic [15:0] pix_color;

    logic [1:0]        anim_mode;
    logic [CELLS-1:0]  blink_mask;
    logic              blink_on;
    logic [8:0]        fall_px;
    logic [CELLS*4-1:0] fall_dist;
    logic [8:0]        shift_px;
    logic [COLS*4-1:0] shift_dist;

    lcd_renderer #(
        .COLS(COLS), .ROWS(ROWS), .CELLS(CELLS), .AW(AW), .RA_W(RA_W),
        .BG_COLOR(BG_COLOR)
    ) u_render (
        .clk(clk), .rst(rst),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y),
        .pix_color(pix_color), .pix_valid(pix_valid),
        .board_rd_addr(bm_rd_addr_a), .board_rd_data(bm_rd_data_a),
        .rom_addr(ram_addr), .rom_data(ram_data),
        .anim_mode(anim_mode), .blink_mask(blink_mask), .blink_on(blink_on),
        .fall_px(fall_px), .fall_dist(fall_dist),
        .shift_px(shift_px), .shift_dist(shift_dist)
    );

    // ------------------------------------------------------------------
    // reference model
    // ------------------------------------------------------------------
    logic [2:0] ref_cell [0:CELLS-1];         // board contents, column-major? no: row-major

    function automatic logic [2:0] cell_of(input int cx, input int cy);
        cell_of = ref_cell[cy*COLS + cx];
    endfunction

    // expected colour for a *settled* pixel
    function automatic logic [15:0] ref_static(input int x, input int y);
        logic [2:0] id;
        id = cell_of(x/20, y/20);
        if (id == EMPTY) ref_static = BG_COLOR;
        else             ref_static = 16'(400*id + 20*(y%20) + (x%20));
    endfunction

    int errors = 0;
    int checks = 0;
    int first_errors = 0;

    task automatic chk(input string what, input int got, input int exp);
        checks++;
        if (got !== exp) begin
            errors++;
            if (first_errors < 15) begin
                first_errors++;
                $display("  FAIL %s : got 0x%04h expected 0x%04h", what, got, exp);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // stream one image and compare every pixel against ref_static()
    // ------------------------------------------------------------------
    int req_x, req_y;          // coordinates of the request currently on the bus
    int n_req;                 // requests issued
    int n_val;                 // pixels returned
    bit streaming;             // a sweep is in progress

    // capture: the k-th pixel must equal the reference for the k-th request
    task automatic report_pixel(input int k);
        int x, y;
        x = k % SCREEN_W;
        y = k / SCREEN_W;
        chk($sformatf("color(%0d,%0d)", x, y), pix_color, ref_pixel(x, y));
    endtask

    always @(posedge clk) begin
        #1;
        if (pix_valid && streaming) begin
            if (n_val < n_req) report_pixel(n_val);
            n_val++;
        end
    end

    // animation-mode reference models ----------------------------------
    logic [CELLS*4-1:0] ref_fall_dist;
    logic [COLS*4-1:0]  ref_shift_dist;

    function automatic logic [15:0] ref_pixel(input int x, input int y);
        ref_pixel = (anim_mode == 2'd2) ? ref_fall(x, y) :
                    (anim_mode == 2'd3) ? ref_shift(x, y) :
                    (anim_mode == 2'd1) ? ref_blink(x, y) : ref_static(x, y);
    endfunction

    function automatic logic [15:0] ref_fall(input int x, input int y);
        int cx; int found; logic [15:0] col;
        cx = x / 20;
        found = 0;
        col   = BG_COLOR;
        for (int t = 0; t < ROWS; t++) begin
            int d; int dist_px; int top;
            d       = ref_fall_dist[4*(cx*ROWS + t) +: 4];
            dist_px = d * 20;
            top     = t*20 - ((fall_px < dist_px) ? (dist_px - fall_px) : 0);
            if (y >= top && y < top + 20) begin
                logic [2:0] id;
                id = cell_of(cx, t);
                found = 1;
                col   = (id == EMPTY) ? BG_COLOR
                                      : 16'(400*id + 20*(y - top) + (x%20));
            end
        end
        ref_fall = found ? col : BG_COLOR;
    endfunction

    function automatic logic [15:0] ref_shift(input int x, input int y);
        int cy; int found; logic [15:0] col;
        cy = y / 20;
        found = 0;
        col   = BG_COLOR;
        for (int tc = 0; tc < COLS; tc++) begin
            int d; int dist_px; int left;
            d       = ref_shift_dist[4*tc +: 4];
            dist_px = d * 20;
            left    = (tc + d)*20 - ((shift_px < dist_px) ? shift_px : dist_px);
            if (x >= left && x < left + 20) begin
                logic [2:0] id;
                id = cell_of(tc, cy);
                found = 1;
                col   = (id == EMPTY) ? BG_COLOR
                                      : 16'(400*id + 20*(y%20) + (x - left));
            end
        end
        ref_shift = found ? col : BG_COLOR;
    endfunction

    function automatic logic [15:0] ref_blink(input int x, input int y);
        if (blink_mask[(y/20)*COLS + (x/20)] && !blink_on) ref_blink = BG_COLOR;
        else                                               ref_blink = ref_static(x, y);
    endfunction

    // Issue SCREEN_W*SCREEN_H requests using the REAL handshake of the LCD
    // controller: hold pix_req until the renderer answers with pix_valid, and
    // only then present the next pixel.  The renderer is a variable-latency
    // FSM (4 clocks for STATIC/BLINK, ROWS/COLS+4 for FALL/SHIFT), so the
    // back-to-back one-request-per-clock stream used previously would no
    // longer describe its contract.
    task automatic sweep();
        n_req = 0;
        n_val = 0;
        streaming = 1'b1;
        for (int i = 0; i < SCREEN_W*SCREEN_H; i++) begin
            @(negedge clk);
            pix_req = 1'b1;
            pix_x   = 9'(i % SCREEN_W);
            pix_y   = 8'(i / SCREEN_W);
            n_req   = i + 1;
            @(negedge clk);
            pix_req = 1'b0;
            // wait for the answer (pix_valid is a 1-clock pulse)
            while (!pix_valid) @(negedge clk);
            @(negedge clk);
        end
        streaming = 1'b0;
        chk("pixels returned", n_val, SCREEN_W*SCREEN_H);
    endtask

    // ------------------------------------------------------------------
    task automatic write_cell(input int cx, input int cy, input int v);
        bm_wr_en   <= 1'b1;
        bm_wr_addr <= AW'(cy)*COLS + AW'(cx);
        bm_wr_data <= v[2:0];
        @(posedge clk);
        bm_wr_en   <= 1'b0;
        @(posedge clk);
    endtask

    task automatic clear_board();
        bm_clr_start <= 1'b1;
        @(posedge clk);
        bm_clr_start <= 1'b0;
        @(posedge clk);
        while (bm_clr_busy) @(posedge clk);
        for (int i = 0; i < CELLS; i++) ref_cell[i] = EMPTY;
    endtask

    initial begin
        pix_req = 1'b0; pix_x = '0; pix_y = '0;
        bm_wr_en = 1'b0; bm_wr_addr = '0; bm_wr_data = '0;
        bm_clr_start = 1'b0;
        anim_mode = 2'd0;
        blink_mask = '0;
        blink_on = 1'b1;
        fall_px = '0; fall_dist = '0;
        shift_px = '0; shift_dist = '0;
        streaming = 1'b0;
        ref_fall_dist = '0;
        ref_shift_dist = '0;
        for (int i = 0; i < CELLS; i++) ref_cell[i] = EMPTY;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);
        while (bm_clr_busy) @(posedge clk);

        // ---- load the identity pattern into the logo store -----------
        for (int a = 0; a < 2000; a++) begin
            @(negedge clk);
            ram_wr_en   = 1'b1;
            ram_wr_addr = RA_W'(a);
            ram_wr_data = 16'(a);
        end
        @(negedge clk);
        ram_wr_en = 1'b0;

        // ---- a realistic board: 5 logos + a few empty patches --------
        // id = (cx*3 + cy*5) % 5, but leave an empty cross so EMPTY handling
        // is exercised next to real logos.
        for (int cy = 0; cy < ROWS; cy++)
            for (int cx = 0; cx < COLS; cx++) begin
                int v;
                v = (cx*3 + cy*5) % 5;
                if (cx == 3 || cy == 1) v = 7;
                write_cell(cx, cy, v);
                ref_cell[cy*COLS + cx] = v[2:0];
            end

        // ---------------------------------------------------------------
        $display("[1] static sweep (mode 0)");
        anim_mode = 2'd0;
        sweep();
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---------------------------------------------------------------
        // fall: at fall_px past the end every block sits at its settled row,
        // so the image must equal the static image whatever fall_dist says.
        $display("[2] fall end (mode 2, fall_px = 240)");
        for (int c = 0; c < COLS; c++)
            for (int r = 0; r < ROWS; r++)
                ref_fall_dist[4*(c*ROWS + r) +: 4] = 4'((c + r) % 12);
        fall_dist = ref_fall_dist;
        fall_px   = 9'd240;
        anim_mode = 2'd2;
        sweep();
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---------------------------------------------------------------
        $display("[3] shift end (mode 3, shift_px = 320)");
        for (int c = 0; c < COLS; c++)
            ref_shift_dist[4*c +: 4] = 4'(c % 5);
        shift_dist = ref_shift_dist;
        shift_px   = 9'd320;
        anim_mode  = 2'd3;
        sweep();
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---------------------------------------------------------------
        // fall in the middle: single block in column 5, target row 11,
        // fell 3 rows (dist 3). At fall_px = 20 its top is
        //    11*20 - (3*20 - 20) = 220 - 40 = 180
        $display("[4] fall middle (mode 2)");
        clear_board();
        for (int cy = 0; cy < ROWS; cy++)
            for (int cx = 0; cx < COLS; cx++) begin
                int v;
                v = (cx == 5 && cy == 11) ? 2 : 7;
                write_cell(cx, cy, v);
                ref_cell[cy*COLS + cx] = v[2:0];
            end
        ref_fall_dist = '0;
        ref_fall_dist[4*(5*ROWS + 11) +: 4] = 4'd3;
        fall_dist = ref_fall_dist;
        fall_px   = 9'd20;
        anim_mode = 2'd2;
        sweep();
        $display("    checks=%0d errors=%0d", checks, errors);

        // ---------------------------------------------------------------
        // blink: blank exactly the cells of column 0 while blink_on == 0
        $display("[5] blink (mode 1, blink_on = 0)");
        clear_board();
        for (int cy = 0; cy < ROWS; cy++)
            for (int cx = 0; cx < COLS; cx++) begin
                int v;
                v = (cx + cy) % 5;
                write_cell(cx, cy, v);
                ref_cell[cy*COLS + cx] = v[2:0];
            end
        blink_mask = '0;
        for (int cy = 0; cy < ROWS; cy++) blink_mask[cy*COLS + 0] = 1'b1;
        blink_on  = 1'b0;
        anim_mode = 2'd1;
        sweep();
        $display("    checks=%0d errors=%0d", checks, errors);

        $display("================================");
        $display("  checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("  ALL PASS");
        else             $display("  *** FAILURES ***");
        $display("================================");
        $finish;
    end

    // watchdog
    initial begin
        #2_000_000_000;
        $display("TIMEOUT (n_val=%0d)", n_val);
        $finish;
    end
endmodule
