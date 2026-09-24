// samegame_top.sv
//
// Top level of the "さめがめ" FPGA game.  Wires the LCD/TFT controller, the
// touch controller, the game logic, the board memory, the logo ROM and the
// renderer together.
//
// Pin map (from the board schematic):
//   clk         PIN_88   (50 MHz)
//   btn_rst     PIN_17   (active low)
//   sw1         PIN_62   (game button; reserved for future / restart)
//   sw2         PIN_48   (unused)
//   lcd_cs      PIN_81
//   lcd_mosi    PIN_78
//   lcd_sck     PIN_75
//   lcd_dc      PIN_77
//   touch_cs    PIN_134  (TENTATIVE)
//   touch_mosi  PIN_135  (TENTATIVE)
//   touch_miso  PIN_132  (TENTATIVE)
//   touch_sck   PIN_130  (TENTATIVE)
//   led         PIN_85
//   led0..led3  PIN_122,123,120,121
//
// The board memory keeps the *settled* board; the renderer draws the three
// animation overlays (blink / fall / shift) by offsetting blocks away from
// their settled position, so the board read stays a simple cell lookup.

module samegame_top #(
    parameter int CLK_FREQ_HZ      = 50_000_000,
    parameter int FRAME_PERIOD_MS  = 166,     // ~6 fps
    parameter int POWERON_WAIT_MS  = 150,
    parameter int SCLK_HALF_CYCLES = 2,
    parameter int MS_SCALE         = 1,
    parameter logic [7:0] MADCTL_VALUE = 8'h28,
    parameter logic [15:0] BG_COLOR   = 16'h0000
)(
    input  logic clk,
    input  logic btn_rst,

    input  logic sw1,
    input  logic sw2,

    output logic lcd_cs,
    output logic lcd_mosi,
    output logic lcd_sck,
    output logic lcd_dc,

    output logic touch_cs,
    output logic touch_mosi,
    input  logic touch_miso,
    output logic touch_sck,

    output logic led,
    output logic led0,
    output logic led1,
    output logic led2,
    output logic led3
);
    localparam int COLS = 16;
    localparam int ROWS = 12;
    localparam int CELLS = COLS * ROWS;     // 192
    localparam int AW = 8;                  // cell address width
    localparam int RA_W = 11;               // logo ROM address width (0..1999)

    // ---- reset + button ----
    logic rst;
    reset_sync u_reset (.clk(clk), .btn_rst_n(btn_rst), .rst(rst));

    logic sw1_level;
    debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(10)) u_sw1 (
        .clk(clk), .rst(rst), .btn_in_n(sw1), .btn_level(sw1_level)
    );

    // ---- LCD controller + frame pacing ----
    logic lcd_ready, lcd_active, lcd_frame_done;
    logic req_valid;
    logic [1:0] req_cmd;
    logic frame_active;
    logic pix_req, pix_valid;
    logic [8:0] pix_x;
    logic [7:0] pix_y;
    logic [15:0] pix_color;

    lcd_ili9341_ctrl #(
        .SCLK_HALF_CYCLES(SCLK_HALF_CYCLES),
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .SCREEN_W        (320),
        .SCREEN_H        (240),
        .POWERON_WAIT_MS (POWERON_WAIT_MS),
        .MS_SCALE        (MS_SCALE),
        .MADCTL_VALUE    (MADCTL_VALUE)
    ) u_lcd (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(lcd_ready), .req_cmd(req_cmd),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y),
        .pix_color(pix_color), .pix_valid(pix_valid),
        .active(lcd_active), .frame_done(lcd_frame_done),
        .lcd_cs(lcd_cs), .lcd_sck(lcd_sck), .lcd_mosi(lcd_mosi), .lcd_dc(lcd_dc)
    );

    frame_seq #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .FRAME_PERIOD_MS(FRAME_PERIOD_MS),
        .MS_SCALE(MS_SCALE)
    ) u_fseq (
        .clk(clk), .rst(rst),
        .ready(lcd_ready),
        .req_valid(req_valid), .req_cmd(req_cmd), .frame_active(frame_active)
    );

    // ---- frame tick (one pulse per completed frame) ----
    logic frame_tick;
    assign frame_tick = lcd_frame_done;

    // ---- touch controller ----
    logic touch_valid, touch_down, touch_up;
    logic [8:0] touch_x;
    logic [7:0] touch_y;
    touch_controller #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .MS_SCALE(MS_SCALE)
    ) u_touch (
        .clk(clk), .rst(rst),
        .touch_cs(touch_cs), .touch_mosi(touch_mosi), .touch_miso(touch_miso), .touch_sck(touch_sck),
        .touch_valid(touch_valid), .touch_x(touch_x), .touch_y(touch_y),
        .touch_down(touch_down), .touch_up(touch_up)
    );

    // ---- board memory ----
    logic        board_wr_en;
    logic [AW-1:0] board_wr_addr;
    logic [2:0]  board_wr_data;
    logic        board_clr_start;
    logic        board_clr_busy;

    // cell read A (renderer)
    logic [AW-1:0] rd_addr_a;
    logic [2:0]    rd_data_a;
    // cell read B (flood fill)
    logic [AW-1:0] ff_rd_addr;
    logic [2:0]    ff_rd_data;
    // column read
    logic [3:0]  col_rd_col;
    logic [35:0] col_rd_data;

    board_memory #(.COLS(COLS), .ROWS(ROWS), .AW(AW)) u_board (
        .clk(clk), .rst(rst),
        .wr_en(board_wr_en), .wr_addr(board_wr_addr), .wr_data(board_wr_data),
        .clr_start(board_clr_start), .clr_busy(board_clr_busy),
        .rd_addr_a(rd_addr_a), .rd_data_a(rd_data_a),
        .rd_addr_b(ff_rd_addr), .rd_data_b(ff_rd_data),
        .rd_col(col_rd_col), .col_data(col_rd_data)
    );

    // ---- logo ROM ----
    logic [RA_W-1:0] rom_addr;
    logic [15:0] rom_data;
    logo_rom #(.ROM_DEPTH(2000), .AW(RA_W)) u_rom (
        .clk(clk), .rd_addr(rom_addr), .rd_data(rom_data)
    );

    // ---- game FSM ----
    logic [15:0] score;
    logic [1:0]  anim_mode;
    logic [CELLS-1:0] blink_mask;
    logic        blink_on;
    logic [8:0]  fall_px;
    logic [CELLS*4-1:0] fall_dist;
    logic [8:0]  shift_px;
    logic [COLS*4-1:0] shift_dist;
    logic        game_over;

    game_fsm #(.COLS(COLS), .ROWS(ROWS), .CELLS(CELLS), .AW(AW)) u_game (
        .clk(clk), .rst(rst),
        .frame_tick(frame_tick),
        .touch_valid(touch_valid), .touch_x(touch_x), .touch_y(touch_y),
        .touch_down(touch_down), .touch_up(touch_up),
        .ff_rd_addr(ff_rd_addr), .ff_rd_data(ff_rd_data),
        .board_wr_en(board_wr_en), .board_wr_addr(board_wr_addr), .board_wr_data(board_wr_data),
        .col_rd_col(col_rd_col), .col_rd_data(col_rd_data),
        .score(score),
        .anim_mode(anim_mode), .blink_mask(blink_mask), .blink_on(blink_on),
        .fall_px(fall_px), .fall_dist(fall_dist),
        .shift_px(shift_px), .shift_dist(shift_dist),
        .game_over(game_over)
    );

    // ---- renderer ----
    lcd_renderer #(
        .COLS(COLS), .ROWS(ROWS), .CELLS(CELLS), .AW(AW), .RA_W(RA_W),
        .BG_COLOR(BG_COLOR)
    ) u_render (
        .clk(clk), .rst(rst),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y),
        .pix_color(pix_color), .pix_valid(pix_valid),
        .board_rd_addr(rd_addr_a), .board_rd_data(rd_data_a),
        .rom_addr(rom_addr), .rom_data(rom_data),
        .anim_mode(anim_mode), .blink_mask(blink_mask), .blink_on(blink_on),
        .fall_px(fall_px), .fall_dist(fall_dist),
        .shift_px(shift_px), .shift_dist(shift_dist)
    );

    // The board clears itself after reset (board_memory does this on reset),
    // so board_clr_start can stay deasserted here.  The game FSM generates a
    // fresh board immediately after reset.
    assign board_clr_start = 1'b0;

    // ---- LEDs (active low) ----
    logic heartbeat;
    always_ff @(posedge clk) begin
        if (rst) heartbeat <= 1'b0;
        else if (lcd_frame_done) heartbeat <= ~heartbeat;
    end

    assign led  = ~lcd_ready;          // off until panel init finished
    assign led0 = ~lcd_active;         // lit while a frame is scanned out
    assign led1 = ~heartbeat;          // frame heartbeat
    assign led2 = ~game_over;          // lit when the game is over
    assign led3 = ~touch_valid;        // lit while the panel is touched
endmodule
