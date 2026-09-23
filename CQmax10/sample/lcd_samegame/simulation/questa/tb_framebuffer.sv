// tb_framebuffer.sv
//
// Checks framebuffer.v + framebuffer_pixel_src.sv:
//   * the word address produced for every (x,y) equals y*10 + x/32
//   * the colour returned for every (x,y) matches a software reference model
//   * the 320x40 info strip below the game field uses INFO_COLOR
//   * the read pipeline really is 2 cycles deep
`timescale 1ns/1ps

module tb_framebuffer;
    localparam int AW      = 14;
    localparam int WORDS   = 2000;
    localparam int FIELD_W = 320;
    localparam int FIELD_H = 200;
    localparam int SCREEN_W= 320;
    localparam int SCREEN_H= 240;

    localparam logic [15:0] C_BIT0 = 16'hFD20;   // orange (cleared pixel)
    localparam logic [15:0] C_BIT1 = 16'hF800;   // red    (set pixel)
    localparam logic [15:0] C_INFO = 16'h001F;   // blue   (info strip)

    logic clk = 1'b0;
    always #10 clk = ~clk;                        // 50 MHz

    logic rst = 1'b1;

    logic          pix_req = 1'b0, pix_valid;
    logic [8:0]    pix_x = 9'd0;
    logic [7:0]    pix_y = 8'd0;
    logic [15:0]   pix_color;
    logic [AW-1:0] fb_rd_addr;
    logic [31:0]   fb_rd_data;

    logic [AW-1:0] wr_addr = '0;
    logic [31:0]   wr_data = '0;
    logic          wr_en   = 1'b0;

    logic clr_start = 1'b0, clr_busy;

    framebuffer #(
        .FIELD_W(FIELD_W), .FIELD_H(FIELD_H), .AW(AW)
    ) dut_fb (
        .clk(clk), .rd_addr(fb_rd_addr), .rd_data(fb_rd_data),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .clr_start(clr_start), .clr_busy(clr_busy)
    );

    framebuffer_pixel_src #(
        .SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H),
        .FIELD_W(FIELD_W), .FIELD_H(FIELD_H), .AW(AW),
        .BG_COLOR(C_BIT0), .FG_COLOR(C_BIT1), .INFO_COLOR(C_INFO)
    ) dut_pix (
        .clk(clk), .rst(rst),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y),
        .pix_color(pix_color), .pix_valid(pix_valid),
        .fb_rd_addr(fb_rd_addr), .fb_rd_data(fb_rd_data)
    );

    // ------------------------------------------------------------------
    // software reference model of the frame buffer
    // ------------------------------------------------------------------
    logic [31:0] model_mem [0:WORDS-1];

    function automatic logic model_bit(input int x, input int y);
        model_bit = model_mem[(y*10) + (x/32)][x%32];
    endfunction

    int errors = 0;
    int checks = 0;

    task automatic expect_equal(input string what, input int got, input int exp);
        checks++;
        if (got !== exp) begin
            errors++;
            if (errors < 20)
                $display("  FAIL %s : got %0d expected %0d", what, got, exp);
        end
    endtask

    // ------------------------------------------------------------------
    // read one pixel and compare against the reference model
    // ------------------------------------------------------------------
    task automatic check_pixel(input int x, input int y);
        int exp_addr;
        logic [15:0] exp_col;
        begin
            @(negedge clk);
            pix_req = 1'b1;
            pix_x   = x[8:0];
            pix_y   = y[7:0];

            @(posedge clk);           // 1 clk after the request: address stage
            #1;

            if (y < FIELD_H)
                exp_addr = (y*10) + (x/32);
            else
                exp_addr = 2000;   // outside the field the address stage is 0,
                                   // but the last address presented still shows
            expect_equal($sformatf("rd_addr(%0d,%0d)", x, y),
                         (y < FIELD_H) ? fb_rd_addr : 0,
                         (y < FIELD_H) ? exp_addr : 0);

            // wait for the colour, it must arrive exactly 2 clk after req
            @(posedge clk);
            #1;
            expect_equal($sformatf("valid(%0d,%0d)", x, y),
                         pix_valid, 1);

            // outside the game field the info strip colour is used and the
            // buffer is not read at all
            exp_col = (y < FIELD_H) ? (model_bit(x, y) ? C_BIT1 : C_BIT0)
                                    : C_INFO;

            expect_equal($sformatf("color(%0d,%0d)", x, y),
                         pix_color, exp_col);

            @(negedge clk);
            pix_req = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    int x, y, w;
    int t_start, t_end;
    initial begin
        // ---- load a deterministic pattern into the frame buffer -------
        // word (0,0..) : alternating bits; word 5 of row 7 : all ones; ...
        for (int i = 0; i < WORDS; i++) model_mem[i] = 32'h0000_0000;
        for (int i = 0; i < WORDS; i++)
            model_mem[i] = 32'hA5A5_5A5A ^ (i * 32'h0001_0101);
        model_mem[(7*10) + 5] = 32'hFFFF_FFFF;   // full word in row 7
        model_mem[(199*10) + 9] = 32'h0000_0001; // last word of the last row

        @(negedge clk);
        clr_start = 1'b1;
        @(negedge clk);
        clr_start = 1'b0;
        // let the clear walk the whole buffer, then load the pattern
        while (clr_busy) @(negedge clk);

        for (int i = 0; i < WORDS; i++) begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = i[AW-1:0];
            wr_data = model_mem[i];
        end
        @(negedge clk);
        wr_en = 1'b0;

        // ---- release reset and check every pixel position -------------
        rst = 1'b0;
        repeat (4) @(negedge clk);

        t_start = $time;
        for (y = 0; y < SCREEN_H; y++)
            for (x = 0; x < SCREEN_W; x++)
                check_pixel(x, y);
        t_end = $time;
        $display("  swept %0d pixels in %0d ns", checks, t_end - t_start);

        if (errors == 0)
            $display("*** tb_framebuffer: PASS (%0d checks) ***", checks);
        else
            $display("*** tb_framebuffer: FAIL (%0d errors / %0d checks) ***",
                     errors, checks);
        $finish;
    end
endmodule
