// framebuffer_pixel_src.sv
//
// Reads the 1-bit frame buffer and converts it to RGB565 pixels, one pixel
// per request, in the scan order the LCD controller needs.
//
// Frame buffer (framebuffer.v): 320*240 = 76800 bits, packed 32 pixels per
// word (2400 x 32 words). The whole panel is covered by the buffer, so every
// display pixel comes from the frame buffer.
//   bit = 1 -> foreground colour (FG_COLOR)
//   bit = 0 -> background colour (BG_COLOR)
//
// Read latency: 3 clock cycles inside this module (registered address ->
// frame buffer's registered read -> registered colour). The frame buffer's
// read port is synchronous so Quartus can infer an M9K, and the colour stage
// adds one more. The LCD controller just waits for `pix_valid`.
//
// Word address layout inside a row (WORDS_PER_ROW = 10 for a 320-wide screen):
//   word in row = x / 32      = x[8:5]
//   bit  in word = x % 32     = x[4:0]

module framebuffer_pixel_src #(
    parameter int SCREEN_W      = 320,
    parameter int SCREEN_H      = 240,
    parameter int FIELD_W       = 320,
    parameter int FIELD_H       = 240,
    parameter int WORDS_PER_ROW = 10,      // FIELD_W / 32
    parameter int AW            = 14,      // word address width
    parameter logic [15:0] BG_COLOR = 16'h0000,   // bit = 0
    parameter logic [15:0] FG_COLOR = 16'hFFFF    // bit = 1
)(
    input  logic        clk,
    input  logic        rst,

    // request from the LCD controller
    input  logic        pix_req,
    input  logic [8:0]  pix_x,
    input  logic [7:0]  pix_y,

    // pixel returned 3 clock cycles after pix_req
    output logic [15:0] pix_color,
    output logic        pix_valid,

    // read port to the frame buffer
    output logic [AW-1:0] fb_rd_addr,
    input  logic [31:0]   fb_rd_data
);
    // row_base = y * WORDS_PER_ROW. WORDS_PER_ROW is 10 for a 320-wide
    // screen, so this is y*8 + y*2: shift and add, no real multiplier.
    // Both terms are padded to the full AW width so nothing is truncated.
    wire [AW-1:0] row_base = {{(AW-11){1'b0}}, pix_y, 3'b000}      // y*8
                           + {{(AW-9){1'b0}},  pix_y, 1'b0};       // y*2

    // word address for this pixel
    wire [AW-1:0] x_word    = {{(AW-4){1'b0}}, pix_x[8:5]};
    wire [AW-1:0] word_addr = row_base + x_word;

    // ---- pipeline stage 0: register the address -----------------------
    logic [AW-1:0] raddr0;
    logic          req0;
    logic [4:0]    bit0;

    always_ff @(posedge clk) begin
        if (rst) begin
            raddr0 <= '0;
            req0   <= 1'b0;
            bit0   <= 5'd0;
        end else begin
            req0   <= pix_req;
            raddr0 <= word_addr;
            bit0   <= pix_x[4:0];
        end
    end

    assign fb_rd_addr = raddr0;

    // ---- pipeline stage 1: the frame buffer's own registered read ---------
    // fb_rd_data is valid one clock after fb_rd_addr, so carry the bit index
    // and the request flag alongside it.
    logic          req1;
    logic [4:0]    bit1;

    always_ff @(posedge clk) begin
        if (rst) begin
            req1 <= 1'b0;
            bit1 <= 5'd0;
        end else begin
            req1 <= req0;
            bit1 <= bit0;
        end
    end

    // ---- pipeline stage 2: bit select -> RGB565 --------------------------
    // pix_valid must assert for EVERY request, otherwise the LCD controller
    // would wait for a pixel that never arrives and stall part way through
    // the frame.
    always_ff @(posedge clk) begin
        if (rst) begin
            pix_color <= BG_COLOR;
            pix_valid <= 1'b0;
        end else begin
            pix_valid <= req1;
            if (req1)
                pix_color <= fb_rd_data[bit1] ? FG_COLOR : BG_COLOR;
        end
    end
endmodule
