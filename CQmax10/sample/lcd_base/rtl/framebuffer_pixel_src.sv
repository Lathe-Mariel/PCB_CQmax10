// framebuffer_pixel_src.sv
//
// Reads the 1-bit frame buffer and converts it to RGB565 pixels, one pixel
// per request, in the scan order the LCD controller needs.
//
// Frame buffer (framebuffer.v): 320*200 = 64000 bits, packed 32 pixels per
// word (2000 x 32 words).
//   bit = 1 -> foreground colour (FG_COLOR)
//   bit = 0 -> background colour (BG_COLOR)
// Anything outside the 320x200 game field (the 320x40 info strip at the
// bottom of the 320x240 panel) gets INFO_COLOR.
//
// Read latency: 2 clock cycles (registered address -> memory output ->
// registered colour). The LCD controller just waits for `pix_valid`.
//
// Word address layout inside a row: 10 words of 32 pixels = 320 pixels.
//   word in row = x[8:5]      (4 bits, 0..9)
//   bit  in word = x[4:0]     (5 bits)

module framebuffer_pixel_src #(
    parameter int SCREEN_W  = 320,
    parameter int SCREEN_H  = 240,
    parameter int FIELD_W   = 320,
    parameter int FIELD_H   = 200,
    parameter int AW        = 14,          // word address width
    parameter int WORDS_PER_ROW = 10,      // FIELD_W / 32
    parameter logic [15:0] BG_COLOR   = 16'h0000,
    parameter logic [15:0] FG_COLOR   = 16'hFFFF,
    parameter logic [15:0] INFO_COLOR = 16'h0000
)(
    input  logic        clk,
    input  logic        rst,

    // request from the LCD controller
    input  logic        pix_req,
    input  logic [8:0]  pix_x,
    input  logic [7:0]  pix_y,

    // pixel returned 2 clock cycles after pix_req
    output logic [15:0] pix_color,
    output logic        pix_valid,

    // read port to the frame buffer
    output logic [AW-1:0] fb_rd_addr,
    input  logic [31:0]   fb_rd_data
);
    localparam logic [8:0] FIELD_W_C = FIELD_W[8:0];
    localparam logic [7:0] FIELD_H_C = FIELD_H[7:0];

    wire in_field = (pix_x < FIELD_W_C) && (pix_y < FIELD_H_C);

    // row_base = y * 10 = y*8 + y*2, in a full-width (AW-bit) vector so that
    // the addition below never needs truncation.
    wire [AW-1:0] row_base  = {{(AW-11){1'b0}}, pix_y, 3'b000}
                            + {{(AW-10){1'b0}}, pix_y, 1'b0};

    // word address for this pixel (word in row = x[8:5], bit in word = x[4:0])
    wire [AW-1:0] x_word    = {{(AW-4){1'b0}}, pix_x[8:5]};
    wire [AW-1:0] word_addr = row_base + x_word;

    // ---- pipeline stage 0: register the address -----------------------
    logic [AW-1:0] raddr0;
    logic          req0;
    logic          in_field0;
    logic [4:0]    bit0;

    always_ff @(posedge clk) begin
        if (rst) begin
            raddr0    <= '0;
            req0      <= 1'b0;
            in_field0 <= 1'b0;
            bit0      <= 5'd0;
        end else begin
            req0      <= pix_req;
            in_field0 <= in_field;
            raddr0    <= word_addr;
            bit0      <= pix_x[4:0];
        end
    end

    assign fb_rd_addr = raddr0;

    // ---- pipeline stage 1: bit select -> RGB565 -----------------------
    // NOTE: pix_valid must assert for EVERY request, including rows outside
    // the 320x200 game field, otherwise the LCD controller would wait for a
    // pixel that never arrives and stall part way through the frame.
    always_ff @(posedge clk) begin
        if (rst) begin
            pix_color <= INFO_COLOR;
            pix_valid <= 1'b0;
        end else begin
            pix_valid <= req0;
            if (req0 && in_field0)
                pix_color <= fb_rd_data[bit0] ? FG_COLOR : BG_COLOR;
            else
                pix_color <= INFO_COLOR;     // info strip / panel margin
        end
    end
endmodule
