// lcd_test_top.sv
//
// Step 1 of the LCD game project: prove the whole display chain works by
// filling the entire 320x240 panel with one solid colour (orange).
//
//   clk (PIN_88, 50 MHz)
//     -> reset_sync  -> internal synchronous active-high reset
//     -> lcd_ili9341_ctrl : powers on, runs the ILI9341 init ROM, then
//                           accepts whole-frame requests and scans the
//                           frame out as a stream of RGB565 pixels
//     -> framebuffer (320x200x1) : the 1-bit game frame buffer
//     -> framebuffer_pixel_src   : 1 bit -> RGB565 colour lookup
//     -> frame_seq               : asks for a new frame every 250 ms
//
// Because the frame buffer is bulk-cleared to 0 after reset and bit 0 maps
// to orange, the panel comes up fully orange. Step 2 (the line game) only
// has to write 1s into the frame buffer; the pixel source already maps 1 to
// white, and the 320x40 strip below the game field is drawn from
// INFO_COLOR.

module lcd_test_top #(
    parameter int CLK_FREQ_HZ      = 50_000_000,
    parameter int FRAME_PERIOD_MS  = 250,
    parameter int POWERON_WAIT_MS  = 150,
    parameter int SCLK_HALF_CYCLES = 2,
    parameter int MS_SCALE         = 1,      // 1 in hardware; divide delays for simulation
    parameter logic [7:0] MADCTL_VALUE = 8'h28,

    // frame buffer colour LUT
    parameter logic [15:0] COLOR_BIT0 = 16'hFD20,  // cleared pixels: orange
    parameter logic [15:0] COLOR_BIT1 = 16'hFFFF,  // drawn pixels : white
    parameter logic [15:0] COLOR_INFO = 16'hFD20   // 320x40 info strip: orange
)(
    input  logic clk,          // PIN_88, 50 MHz
    input  logic btn_rst,      // PIN_17, active low
    input  logic sw1,          // PIN_62, game button (idle high)
    input  logic sw2,          // PIN_48

    output logic lcd_cs,       // PIN_81, active low
    output logic lcd_mosi,     // PIN_78
    output logic lcd_sck,      // PIN_75
    output logic lcd_dc,       // PIN_77

    output logic led,          // PIN_85,  active low
    output logic led0,         // PIN_122, active low
    output logic led1,         // PIN_123, active low
    output logic led2,         // PIN_120, active low
    output logic led3          // PIN_121, active low
);
    // ------------------------------------------------------------------
    // reset + button
    // ------------------------------------------------------------------
    logic rst;
    reset_sync u_reset (
        .clk       (clk),
        .btn_rst_n (btn_rst),
        .rst       (rst)
    );

    logic btn_level;
    debounce #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .DEBOUNCE_MS(10)
    ) u_debounce (
        .clk      (clk),
        .rst      (rst),
        .btn_in_n (sw1),
        .btn_level(btn_level)
    );

    // ------------------------------------------------------------------
    // frame buffer + pixel source
    // ------------------------------------------------------------------
    localparam int AW = 14;                 // 2000 words -> 11 bits used

    logic        clr_start;
    logic        clr_busy;
    logic [AW-1:0] fb_rd_addr, fb_wr_addr;
    logic [31:0]   fb_rd_data, fb_wr_data;
    logic          fb_wr_en;

    framebuffer #(
        .FIELD_W(320),
        .FIELD_H(200),
        .AW     (AW)
    ) u_fb (
        .clk      (clk),
        .rd_addr  (fb_rd_addr),
        .rd_data  (fb_rd_data),
        .wr_en    (fb_wr_en),
        .wr_addr  (fb_wr_addr),
        .wr_data  (fb_wr_data),
        .clr_start(clr_start),
        .clr_busy (clr_busy)
    );

    logic        pix_req, pix_valid;
    logic [8:0]  pix_x;
    logic [7:0]  pix_y;
    logic [15:0] pix_color;

    framebuffer_pixel_src #(
        .SCREEN_W  (320),
        .SCREEN_H  (240),
        .FIELD_W   (320),
        .FIELD_H   (200),
        .AW        (AW),
        .BG_COLOR  (COLOR_BIT0),
        .FG_COLOR  (COLOR_BIT1),
        .INFO_COLOR(COLOR_INFO)
    ) u_pixsrc (
        .clk       (clk),
        .rst       (rst),
        .pix_req   (pix_req),
        .pix_x     (pix_x),
        .pix_y     (pix_y),
        .pix_color (pix_color),
        .pix_valid (pix_valid),
        .fb_rd_addr(fb_rd_addr),
        .fb_rd_data(fb_rd_data)
    );

    // The frame buffer is cleared once, right after reset. Step 2 will
    // replace this with the game logic's write port; the interface is
    // already there (fb_wr_en / fb_wr_addr / fb_wr_data).
    always_ff @(posedge clk) begin
        if (rst)
            clr_start <= 1'b1;
        else if (clr_busy)
            clr_start <= 1'b0;
    end

    // Step 1 has no game logic yet, so the write port is idle and the buffer
    // is cleared to 0 once after reset. Step 2 drives these from the game
    // logic instead.
    //
    // NOTE: with this idle write port Quartus constant-folds the RAM away
    // (0 memory bits reported). The M9K inference itself was verified by
    // temporarily driving the port from sw2: 64,000 memory bits = 320*200,
    // i.e. exactly one M9K block of the 10M08 (613 LEs, timing met).
    assign fb_wr_en   = 1'b0;
    assign fb_wr_addr = '0;
    assign fb_wr_data = 32'h0000_0000;

    // ------------------------------------------------------------------
    // LCD controller + frame pacing
    // ------------------------------------------------------------------
    logic lcd_ready;
    logic lcd_active;
    logic lcd_frame_done;
    logic req_valid;
    logic [1:0] req_cmd;
    logic frame_active;

    lcd_ili9341_ctrl #(
        .SCLK_HALF_CYCLES(SCLK_HALF_CYCLES),
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .SCREEN_W        (320),
        .SCREEN_H        (240),
        .POWERON_WAIT_MS (POWERON_WAIT_MS),
        .MS_SCALE        (MS_SCALE),
        .MADCTL_VALUE    (MADCTL_VALUE)
    ) u_lcd (
        .clk       (clk),
        .rst       (rst),
        .req_valid (req_valid),
        .req_ready (lcd_ready),
        .req_cmd   (req_cmd),
        .pix_req   (pix_req),
        .pix_x     (pix_x),
        .pix_y     (pix_y),
        .pix_color (pix_color),
        .pix_valid (pix_valid),
        .active    (lcd_active),
        .frame_done(lcd_frame_done),
        .lcd_cs    (lcd_cs),
        .lcd_sck   (lcd_sck),
        .lcd_mosi  (lcd_mosi),
        .lcd_dc    (lcd_dc)
    );

    frame_seq #(
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .FRAME_PERIOD_MS (FRAME_PERIOD_MS),
        .MS_SCALE        (MS_SCALE)
    ) u_fseq (
        .clk          (clk),
        .rst          (rst),
        // do not start a frame before the panel is initialised AND the
        // frame buffer has been cleared, otherwise the first frame would
        // scan out uninitialised memory
        .ready        (lcd_ready && !clr_busy),
        .req_valid    (req_valid),
        .req_cmd      (req_cmd),
        .frame_active (frame_active)
    );

    // ------------------------------------------------------------------
    // LEDs (all active low)
    // ------------------------------------------------------------------
    logic heartbeat;
    always_ff @(posedge clk) begin
        if (rst)
            heartbeat <= 1'b0;
        else if (lcd_frame_done)
            heartbeat <= ~heartbeat;      // toggles once per completed frame
    end

    assign led  = ~lcd_ready;          // off until panel init is finished
    assign led0 = ~lcd_active;         // lit while a frame is scanned out
    assign led1 = ~heartbeat;          // frame heartbeat (toggles per frame)
    assign led2 = ~sw2;                // mirrors switch 2
    assign led3 = ~btn_level;          // lit while the game button is pressed

endmodule
