// lcd_test_top.sv
//
// The LCD line game (prompt.txt #1..#4).
//
// START-UP ("initialisation"): the 320x240 1-bit frame buffer is cleared and
// a table of nine red horizontal lines is drawn into it:
//
//   (0,25)-(279,25)   (40,50)-(319,50)
//   (0,75)-(279,75)   (40,100)-(319,100)
//   (0,125)-(279,125) (40,150)-(319,150)
//   (0,175)-(279,175) (40,200)-(319,200)
//   (0,225)-(279,225)
//
// These alternate between "left half + 40 px gap at the right" and "40 px gap
// at the left + right half" and form the playfield.
//
// GAME (#4): after that initialisation the game starts and game_ctrl grows a
// moving 1-dot line from (1,1). It goes down-right while the button is released
// and up-right while it is pressed, and it bounces off x=0 and x=319. Before
// each dot it reads the frame buffer, and if the target pixel is already set
// the game is over and everything stops.
//
// The dot period is locked to the frame period (LOCK_TO_FRAME) so the line
// advances a constant number of dots per displayed frame; see game_ctrl.sv.
//
//   clk (PIN_88, 50 MHz)
//     -> reset_sync  -> internal synchronous active-high reset
//     -> framebuffer (320x240x1) : cleared, then the playfield is drawn
//        read port A -> framebuffer_pixel_src -> lcd_ili9341_ctrl (scan-out)
//        read port B -> game_ctrl (pixel test before drawing)
//        write port : line_draw during start-up, game_ctrl afterwards
//     -> frame_seq : asks for a new frame every FRAME_PERIOD_MS (150 ms)
//
// Bit 0 of the frame buffer is the orange background, bit 1 is anything drawn
// (the playfield lines and the moving line, both red).
module lcd_test_top #(
    parameter int CLK_FREQ_HZ      = 50_000_000,

    // Frame request period. This is a MINIMUM: if the transfer itself takes
    // longer the next frame simply starts as soon as the panel is ready. Set it
    // just above the transfer time (see README) - anything larger is pure idle
    // time that lowers the frame rate for free.
    parameter int FRAME_PERIOD_MS  = 150,

    parameter int POWERON_WAIT_MS  = 150,

    // SCK = CLK_FREQ_HZ * SCLK_HALF_DEN / (2 * SCLK_HALF_NUM).
    // The ILI9341 datasheet limits the write clock to 10 MHz, and 10 MHz is NOT
    // reachable with an integer divider from 50 MHz (that only gives 25, 12.5,
    // 8.33, 6.25 ...). The divider is therefore rational: 5/2 gives exactly
    // 50*2/(2*5) = 10 MHz, the datasheet limit.
    parameter int SCLK_HALF_NUM = 5,  // half period = 5/2 clk
    parameter int SCLK_HALF_DEN = 2,  // -> SCK = 10 MHz (datasheet max)
    parameter int MS_SCALE         = 1,      // 1 in hardware; divide delays for simulation
    parameter logic [7:0] MADCTL_VALUE = 8'h28,

    // the horizontal lines written into the frame buffer, as a table:
    //   (LINE_X0[i], LINE_Y[i]) - (LINE_X1[i], LINE_Y[i])  inclusive
    parameter int N_LINES = 9,
    parameter int LINE_X0 [N_LINES] = '{  0,  40,   0,  40,   0,  40,   0,  40,   0},
    parameter int LINE_X1 [N_LINES] = '{279, 319, 279, 319, 279, 319, 279, 319, 279},
    parameter int LINE_Y  [N_LINES] = '{ 25,  50,  75, 100, 125, 150, 175, 200, 225},

    // the moving line of the game
    //
    // STEP_MS is the MINIMUM time between two dots. It is rounded up to a whole
    // number of FRAME_PERIOD_MS so the line advances a constant number of dots
    // per displayed frame (see the header of game_ctrl.sv). Without that, the
    // dots land mid-frame and the number that become visible per frame varies
    // from frame to frame, which looks jerky even with everything else correct.
    parameter int STEP_MS  = 40,   // minimum dot period in ms
    parameter bit LOCK_TO_FRAME = 1'b1,
    parameter int START_X  = 1,    // start position of the moving line
    parameter int START_Y  = 1,

    // frame buffer colour LUT
    parameter logic [15:0] COLOR_BIT0 = 16'hFD20,  // bit 0: background (orange)
    parameter logic [15:0] COLOR_BIT1 = 16'hF800   // bit 1: drawn pixel (red)
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
    localparam int AW            = 14;      // word address width (2400 words)
    localparam int WORDS_PER_ROW = 320 / 32; // 10

    logic          clr_start, clr_busy;
    logic [AW-1:0] fb_rd_addr, fb_rd2_addr, fb_wr_addr;
    logic [31:0]   fb_rd_data, fb_rd2_data, fb_wr_data;
    logic          fb_wr_en;

    // READ PORTS: port A feeds the LCD scan-out and runs for most of every
    // frame, so the start-up line drawer and the game both use port B. The
    // game only starts after the line drawer is finished, so those two can
    // share port B without any arbitration.
    // WRITE PORT: line_draw owns it during start-up, game_ctrl afterwards.
    logic [AW-1:0] src_rd_addr, line_rd_addr, game_rd_addr;
    logic [AW-1:0] line_wr_addr, game_wr_addr;
    logic [31:0]   line_wr_data, game_wr_data;
    logic          line_wr_en,   game_wr_en;
    logic          game_active;          // start-up done -> the game owns it all

    assign fb_rd2_addr = game_active ? game_rd_addr : line_rd_addr;
    assign fb_wr_en    = game_active ? game_wr_en   : line_wr_en;
    assign fb_wr_addr  = game_active ? game_wr_addr : line_wr_addr;
    assign fb_wr_data  = game_active ? game_wr_data : line_wr_data;

    framebuffer #(
        .FIELD_W      (320),
        .FIELD_H      (240),
        .WORDS_PER_ROW(WORDS_PER_ROW),
        .AW           (AW)
    ) u_fb (
        .clk      (clk),
        .rd_addr  (fb_rd_addr),
        .rd_data  (fb_rd_data),
        .rd2_addr (fb_rd2_addr),
        .rd2_data (fb_rd2_data),
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
        .SCREEN_W     (320),
        .SCREEN_H     (240),
        .FIELD_W      (320),
        .FIELD_H      (240),
        .WORDS_PER_ROW(WORDS_PER_ROW),
        .AW           (AW),
        .BG_COLOR     (COLOR_BIT0),
        .FG_COLOR     (COLOR_BIT1)
    ) u_pixsrc (
        .clk       (clk),
        .rst       (rst),
        .pix_req   (pix_req),
        .pix_x     (pix_x),
        .pix_y     (pix_y),
        .pix_color (pix_color),
        .pix_valid (pix_valid),
        .fb_rd_addr(src_rd_addr),
        .fb_rd_data(fb_rd_data)
    );

    assign fb_rd_addr = src_rd_addr;      // port A: the LCD scan-out only

    // ------------------------------------------------------------------
    // start-up sequence: clear the buffer, draw the playfield, start the game
    // ------------------------------------------------------------------
    // CONTRACT: line_draw draws its ENTIRE table out of a single `start`
    // pulse and holds `busy` high until the last word is written. So exactly
    // one start is issued here. Issuing one start per line would draw all
    // N_LINES lines N_LINES times over (harmless for identical pixels, but
    // wrong for any line that is meant to be conditional).
    //
    // WAITING FOR `busy` NEEDS TWO STATES. `line_start` and `line_busy` are
    // both registered, so one cycle after the pulse the drawer has not yet
    // asserted `busy`. Testing `!busy` immediately would fall straight through
    // and hand the write port to the game while the playfield was still being
    // drawn - which silently leaves most of the playfield missing (and made
    // the game collide with a half-built image). So I_DRAW_BUSY waits for
    // `busy` to RISE, and only then does I_DRAW_WAIT wait for it to fall.
    //
    // I_GAME_BEGIN pulses game_start for one cycle and, at the same time,
    // moves the write port and read port B from line_draw to game_ctrl.
    // game_ctrl leaves its own read address alone and does not assert its
    // write enable until it is out of G_IDLE, so nothing is disturbed while
    // the mux changes over.
    typedef enum logic [2:0] {I_CLEAR, I_CLEAR_WAIT, I_DRAW, I_DRAW_BUSY,
                              I_DRAW_WAIT, I_DRAW_GAP, I_READY,
                              I_GAME_BEGIN} init_t;
    init_t init_state;
    logic  line_start;
    logic  line_busy;
    logic  game_start;

    always_ff @(posedge clk) begin
        if (rst) begin
            init_state <= I_CLEAR;
            clr_start  <= 1'b1;
            line_start <= 1'b0;
            game_start <= 1'b0;
        end else begin
            line_start <= 1'b0;
            game_start <= 1'b0;

            case (init_state)
                I_CLEAR: begin
                    clr_start  <= 1'b0;         // the clear is now running
                    init_state <= I_CLEAR_WAIT;
                end
                I_CLEAR_WAIT: begin
                    if (!clr_busy) init_state <= I_DRAW;
                end
                I_DRAW: begin
                    line_start <= 1'b1;         // one pulse = the whole table
                    init_state <= I_DRAW_BUSY;
                end
                I_DRAW_BUSY: begin
                    if (line_busy) init_state <= I_DRAW_WAIT;
                end
                I_DRAW_WAIT: begin
                    if (!line_busy) init_state <= I_DRAW_GAP;
                end
                I_DRAW_GAP: begin
                    init_state <= I_READY;      // let the last write land
                end
                I_READY: begin
                    init_state <= I_GAME_BEGIN; // playfield complete
                end
                I_GAME_BEGIN: begin
                    game_start <= 1'b1;         // one pulse: game_ctrl takes over
                    init_state <= I_GAME_BEGIN; // game_ctrl owns the buffer now
                end
                default: init_state <= I_CLEAR;
            endcase
        end
    end

    // once start-up is over, the game owns the write port and read port B
    assign game_active = (init_state == I_GAME_BEGIN);

    line_draw #(
        .FIELD_W      (320),
        .WORDS_PER_ROW(WORDS_PER_ROW),
        .AW           (AW),
        .N_LINES      (N_LINES),
        .LINE_X0      (LINE_X0),
        .LINE_X1      (LINE_X1),
        .LINE_Y       (LINE_Y)
    ) u_line (
        .clk       (clk),
        .rst       (rst),
        .start     (line_start),
        .busy      (line_busy),
        .fb_wr_en  (line_wr_en),
        .fb_wr_addr(line_wr_addr),
        .fb_wr_data(line_wr_data),
        .fb_rd_addr(line_rd_addr),
        .fb_rd_data(fb_rd2_data)
    );

    // ------------------------------------------------------------------
    // the game: the moving line
    // ------------------------------------------------------------------
    logic [8:0] dot_x;
    logic [7:0] dot_y;
    logic       game_running, game_over;

    game_ctrl #(
        .CLK_FREQ_HZ    (CLK_FREQ_HZ),
        .MS_SCALE       (MS_SCALE),
        .STEP_MS        (STEP_MS),
        .LOCK_TO_FRAME  (LOCK_TO_FRAME),
        .FRAME_PERIOD_MS(FRAME_PERIOD_MS),
        .FIELD_W        (320),
        .FIELD_H        (240),
        .WORDS_PER_ROW  (WORDS_PER_ROW),
        .AW             (AW),
        .START_X        (START_X),
        .START_Y        (START_Y)
    ) u_game (
        .clk       (clk),
        .rst       (rst),
        .start     (game_start),
        .running   (game_running),
        .game_over (game_over),
        .btn       (btn_level),
        .dot_x     (dot_x),
        .dot_y     (dot_y),
        .fb_wr_en  (game_wr_en),
        .fb_wr_addr(game_wr_addr),
        .fb_wr_data(game_wr_data),
        .fb_rd_addr(game_rd_addr),
        .fb_rd_data(fb_rd2_data)
    );

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
        .SCLK_HALF_NUM(SCLK_HALF_NUM),
        .SCLK_HALF_DEN(SCLK_HALF_DEN),
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
        // do not start a frame before the panel is initialised AND the frame
        // buffer is fully drawn, otherwise the first frame would scan out a
        // half-built image
        .ready        (lcd_ready && (init_state == I_GAME_BEGIN)),
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

    assign led  = ~lcd_ready;                     // panel init done
    assign led0 = ~(init_state == I_GAME_BEGIN);   // playfield drawn, game running
    assign led1 = ~heartbeat;                     // frame heartbeat
    assign led2 = ~game_over;                     // GAME OVER (latched), else mirrors sw2
    assign led3 = ~btn_level;                     // button pressed

endmodule
