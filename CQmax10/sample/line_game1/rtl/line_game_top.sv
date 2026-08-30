// line_game_top.sv
// Top level for the 1-key line game on the CQ-MAX10-A board
// (MAX10 10M08SCE144C8G) driving a PMOD-TFTLCD v1.1 (ILI9341, 320x240).
//
// Pin map (from the project spec):
//   clk      -> pin 85   (50 MHz system clock)
//   btn_rst  -> pin 17   (Reset_n, active low)
//   Button   -> pin 62   (user button, assumed active low w/ pull-up)
//   lcd_cs   -> pin 81
//   lcd_mosi -> pin 78
//   lcd_sck  -> pin 75
//   lcd_dc   -> pin 77
module line_game_top (
    input  logic clk,
    input  logic btn_rst,     // active low
    input  logic Button,      // active low (assumed pulled up)

    output logic lcd_cs,
    output logic lcd_mosi,
    output logic lcd_sck,
    output logic lcd_dc
);

    logic rst;
    reset_sync u_reset (
        .clk       (clk),
        .btn_rst_n (btn_rst),
        .rst       (rst)
    );

    logic btn_level;
    debounce #(
        .CLK_FREQ_HZ(50_000_000),
        .DEBOUNCE_MS(10)
    ) u_debounce (
        .clk      (clk),
        .rst      (rst),
        .btn_in_n (Button),
        .btn_level(btn_level)
    );

    logic        req_valid, req_ready;
    logic [1:0]  req_cmd;
    logic [8:0]  req_x, req_w;
    logic [7:0]  req_y;
    logic [8:0]  req_h;
    logic [15:0] req_color;

    game_core #(
        .FIELD_W (320),
        .FIELD_H (200),
        .SCREEN_W(320),
        .SCREEN_H(240),
        .CLK_FREQ_HZ(50_000_000),
        .STEP_MS(20),
        .GAMEOVER_WAIT_MS(2000)
    ) u_game (
        .clk      (clk),
        .rst      (rst),
        .btn_level(btn_level),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_cmd  (req_cmd),
        .req_x    (req_x),
        .req_y    (req_y),
        .req_w    (req_w),
        .req_h    (req_h),
        .req_color(req_color)
    );

    lcd_ili9341_ctrl #(
        .SCLK_HALF_CYCLES(2),   // 12.5 MHz SPI clock
        .SCREEN_W(320),
        .SCREEN_H(240),
        .MADCTL_VALUE(8'h28)   // landscape; flip to 8'hE8/0x48/0x88 if mirrored
    ) u_lcd (
        .clk      (clk),
        .rst      (rst),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_cmd  (req_cmd),
        .req_x    (req_x),
        .req_y    (req_y),
        .req_w    (req_w),
        .req_h    (req_h),
        .req_color(req_color),
        .lcd_cs   (lcd_cs),
        .lcd_sck  (lcd_sck),
        .lcd_mosi (lcd_mosi),
        .lcd_dc   (lcd_dc)
    );

endmodule
