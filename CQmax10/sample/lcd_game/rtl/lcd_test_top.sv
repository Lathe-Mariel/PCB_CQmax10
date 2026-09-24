// lcd_test_top.sv
//
// The LCD line game (prompt.txt #1..#4).
//
// ---------------------------------------------------------------------------
// HOW THE PANEL IS DRIVEN
// ---------------------------------------------------------------------------
// The ILI9341 keeps the picture in its OWN GRAM, so this design does NOT scan
// a frame buffer out to the panel any more. Instead the panel is written with
// windowed rectangle commands (CASET/PASET/RAMWR + pixels):
//
//   * the whole screen is filled with the background colour once
//   * the playfield lines are drawn as one rectangle per line ("行単位")
//   * the game draws one 1x1 rectangle per dot ("ドット単位")
//
// The 320x240 1-bit frame buffer is still there, but only as the COLLISION
// MODEL for the game (and to remember the playfield lines), never as a display
// source. See framebuffer.v.
//
// ---------------------------------------------------------------------------
// START-UP ("initialisation")
// ---------------------------------------------------------------------------
//   1. the frame buffer is cleared
//   2. the panel is filled with the background colour (one full-screen window)
//   3. the nine playfield lines are drawn
//   4. twenty 2x2 dots are scattered at pseudo-random positions (prompt.txt #5)
//   5. the game starts
//
// The nine lines alternate between "left half + 40 px gap at the right" and
// "40 px gap at the left + right half":
//
//   (0,25)-(279,25)   (40,50)-(319,50)
//   (0,75)-(279,75)   (40,100)-(319,100)
//   (0,125)-(279,125) (40,150)-(319,150)
//   (0,175)-(279,175) (40,200)-(319,200)
//   (0,225)-(279,225)
//
// ---------------------------------------------------------------------------
// GAME (#4)
// ---------------------------------------------------------------------------
// game_ctrl grows a moving 1-dot line from (1,1). It goes down-right while the
// button is released and up-right while it is pressed, and it bounces off x=0
// and x=319. Before each dot it reads the frame buffer, and if the target pixel
// is already set the game is over and everything stops.
//
// The dot period is locked to the frame period (LOCK_TO_FRAME) so the line
// advances a constant number of dots per displayed refresh; see game_ctrl.sv.
//
//   clk (PIN_88, 50 MHz)
//     -> reset_sync  -> internal synchronous active-high reset
//     -> framebuffer (320x240x1) : collision model only
//        write port : line_draw during start-up, game_ctrl afterwards
//        read port  : game_ctrl pixel test (line_draw uses it while drawing)
//     -> lcd_ili9341_ctrl : init sequence + windowed rectangle writes
//        the fill, each playfield line and each dot are one rectangle
//
// There is no frame_seq and no pixel scan-out: the panel is only written when
// something actually changes.

module lcd_test_top #(
    parameter int CLK_FREQ_HZ      = 50_000_000,

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

    // the playfield lines, as a table:
    //   (LINE_X0[i], LINE_Y[i]) - (LINE_X1[i], LINE_Y[i])  inclusive
    parameter int N_LINES = 9,
    parameter int LINE_X0 [N_LINES] = '{  0,  40,   0,  40,   0,  40,   0,  40,   0},
    parameter int LINE_X1 [N_LINES] = '{279, 319, 279, 319, 279, 319, 279, 319, 279},
    parameter int LINE_Y  [N_LINES] = '{ 25,  50,  75, 100, 125, 150, 175, 200, 225},

    // the moving line of the game
    //
    // STEP_MS is the MINIMUM time between two dots. It is rounded up to a whole
    // number of FRAME_PERIOD_MS so the line advances a constant number of dots
    // per displayed refresh (see the header of game_ctrl.sv). Without that, the
    // dots land at uneven phases and the line looks jerky even when everything
    // else is correct.
    parameter int STEP_MS  = 40,   // minimum dot period in ms
    parameter bit LOCK_TO_FRAME = 1'b1,
    parameter int FRAME_PERIOD_MS = 250,  // panel refresh period used for the lock
    parameter int START_X  = 1,    // start position of the moving line
    parameter int START_Y  = 1,

    // the pseudo-random dots (prompt.txt #5): N_DOTS rectangles of DOT_W x
    // DOT_H, scattered over (DOT_X_MIN,DOT_Y_MIN)-(DOT_X_MAX,DOT_Y_MAX).
    // The Y limit is clamped to the panel height inside dot_field.
    parameter int DOT_N    = 20,
    parameter int DOT_W    = 2,
    parameter int DOT_H    = 2,
    parameter int DOT_X_MIN = 2,
    parameter int DOT_X_MAX = 318,
    parameter int DOT_Y_MIN = 2,
    parameter int DOT_Y_MAX = 318,
    parameter logic [31:0] DOT_SEED = 32'hACE1_2345,  // must be non-zero

    // colours (RGB565). Background is drawn on the panel only; the frame
    // buffer is 1 bit and does not store colours at all.
    parameter logic [15:0] COLOR_BIT0 = 16'hFD20,  // background (orange)
    parameter logic [15:0] COLOR_BIT1 = 16'hF800,  // playfield + moving line (red)
    parameter logic [15:0] COLOR_DOT  = 16'hF81F   // random dots (purple)
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
    // frame buffer: collision model only (never scanned out)
    // ------------------------------------------------------------------
    localparam int AW            = 14;      // word address width (2400 words)
    localparam int WORDS_PER_ROW = 320 / 32; // 10
    localparam logic [8:0]  COLS_LAST = 9'd319;
    localparam logic [7:0]  ROWS_LAST = 8'd239;

    logic          clr_start, clr_busy;
    logic [AW-1:0] fb_rd_addr, fb_wr_addr;
    logic [31:0]   fb_rd_data, fb_wr_data;
    logic          fb_wr_en;

    // WRITE PORT: line_draw owns it during start-up, dot_field right after it,
    // game_ctrl afterwards. READ PORT: the same split - line_draw and dot_field
    // read back the words they are merging into, game_ctrl reads the pixel it
    // is about to draw on. The three never overlap, so a plain mux is enough
    // (no arbitration).
    logic [AW-1:0] line_rd_addr, dot_rd_addr, game_rd_addr;
    logic [AW-1:0] line_wr_addr, dot_wr_addr, game_wr_addr;
    logic [31:0]   line_wr_data, dot_wr_data, game_wr_data;
    logic          line_wr_en,   dot_wr_en,   game_wr_en;
    logic          game_active;          // start-up done -> the game owns it all
    logic          dot_active;           // dot_field currently owns the buffer

    assign fb_rd_addr = game_active ? game_rd_addr
                      : (dot_active  ? dot_rd_addr : line_rd_addr);
    assign fb_wr_en   = game_active ? game_wr_en
                      : (dot_active  ? dot_wr_en   : line_wr_en);
    assign fb_wr_addr = game_active ? game_wr_addr
                      : (dot_active  ? dot_wr_addr : line_wr_addr);
    assign fb_wr_data = game_active ? game_wr_data
                      : (dot_active  ? dot_wr_data : line_wr_data);

    framebuffer #(
        .FIELD_W      (320),
        .FIELD_H      (240),
        .WORDS_PER_ROW(WORDS_PER_ROW),
        .AW           (AW)
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

    // ------------------------------------------------------------------
    // LCD controller: init + windowed rectangle writes
    // ------------------------------------------------------------------
    logic        lcd_ready, lcd_active, lcd_done;
    logic        lcd_wr_valid;
    logic [8:0]  lcd_x0, lcd_x1;
    logic [7:0]  lcd_y0, lcd_y1;
    logic [15:0] lcd_color;

    // request sources: the start-up fill, line_draw, dot_field, game_ctrl
    logic        fill_valid, line_valid, dot_valid, game_valid;
    logic [8:0]  fill_x0, fill_x1, line_x0, line_x1, dot_x0, dot_x1,
                 game_x0, game_x1;
    logic [7:0]  fill_y0, fill_y1, line_y0, line_y1, dot_y0, dot_y1,
                 game_y0, game_y1;
    logic [15:0] fill_color, line_color, dot_color, game_color;

    // Priority: the fill first (it is the very first thing the panel shows),
    // then the playfield lines, then the random dots, then the game. Only one
    // of them is ever active - all four are driven by a serial start-up FSM
    // and the game only starts after the others are done - so this is a plain
    // mux rather than arbitration.
    assign lcd_wr_valid = fill_valid | line_valid | dot_valid | game_valid;
    assign lcd_x0 = fill_valid ? fill_x0 : (line_valid ? line_x0
                  : (dot_valid ? dot_x0 : game_x0));
    assign lcd_x1 = fill_valid ? fill_x1 : (line_valid ? line_x1
                  : (dot_valid ? dot_x1 : game_x1));
    assign lcd_y0 = fill_valid ? fill_y0 : (line_valid ? line_y0
                  : (dot_valid ? dot_y0 : game_y0));
    assign lcd_y1 = fill_valid ? fill_y1 : (line_valid ? line_y1
                  : (dot_valid ? dot_y1 : game_y1));
    assign lcd_color = fill_valid ? fill_color
                     : (line_valid ? line_color
                     : (dot_valid  ? dot_color : game_color));

    lcd_ili9341_ctrl #(
        .SCLK_HALF_NUM   (SCLK_HALF_NUM),
        .SCLK_HALF_DEN   (SCLK_HALF_DEN),
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .SCREEN_W        (320),
        .SCREEN_H        (240),
        .POWERON_WAIT_MS (POWERON_WAIT_MS),
        .MS_SCALE        (MS_SCALE),
        .MADCTL_VALUE    (MADCTL_VALUE)
    ) u_lcd (
        .clk       (clk),
        .rst       (rst),
        .wr_valid  (lcd_wr_valid),
        .wr_ready  (lcd_ready),
        .wr_x0     (lcd_x0),
        .wr_y0     (lcd_y0),
        .wr_x1     (lcd_x1),
        .wr_y1     (lcd_y1),
        .wr_color  (lcd_color),
        .active    (lcd_active),
        .wr_done   (lcd_done),
        .lcd_cs    (lcd_cs),
        .lcd_sck   (lcd_sck),
        .lcd_mosi  (lcd_mosi),
        .lcd_dc    (lcd_dc)
    );

    // ------------------------------------------------------------------
    // start-up sequence: clear the buffer, fill the panel, draw the
    // playfield, scatter the random dots
    // ------------------------------------------------------------------
    // The order matters:
    //   1. clear the frame buffer (the collision model starts empty)
    //   2. fill the panel with the background colour - one full-screen window,
    //      so it covers any residue from a previous power-on. The frame buffer
    //      is deliberately NOT involved: bit 0 already means "background".
    //   3. draw the nine lines into the frame buffer AND onto the panel
    //   4. scatter the 20 pseudo-random dots, again into BOTH
    //   5. start the game
    //
    // WAITING FOR `busy` NEEDS TWO STATES. `line_start` and `line_busy` are
    // both registered, so one cycle after the pulse the drawer has not yet
    // asserted `busy`. Testing `!busy` immediately would fall straight through
    // and hand the write port to the game while the playfield was still being
    // drawn - which silently leaves most of the playfield missing (and made
    // the game collide with a half-built image). So I_DRAW_BUSY waits for
    // `busy` to RISE, and only then does I_DRAW_WAIT wait for it to fall.
    //
    // The fill uses the same two-state handshake against `lcd_done`, because
    // `lcd_wr_valid` is registered here and `wr_ready` is registered there.
    typedef enum logic [3:0] {I_CLEAR, I_CLEAR_WAIT,
                              I_FILL, I_FILL_BUSY, I_FILL_WAIT, I_FILL_GAP,
                              I_DRAW, I_DRAW_BUSY, I_DRAW_WAIT, I_DRAW_GAP,
                              I_DOTS, I_DOTS_BUSY, I_DOTS_WAIT, I_DOTS_GAP,
                              I_READY, I_GAME_BEGIN} init_t;
    init_t init_state;
    logic  line_start;
    logic  line_busy;
    logic  dot_start;
    logic  dot_busy;
    logic  game_start;

    always_ff @(posedge clk) begin
        if (rst) begin
            init_state <= I_CLEAR;
            clr_start  <= 1'b1;
            line_start <= 1'b0;
            dot_start  <= 1'b0;
            game_start <= 1'b0;
        end else begin
            line_start <= 1'b0;
            dot_start  <= 1'b0;
            game_start <= 1'b0;

            case (init_state)
                I_CLEAR: begin
                    clr_start  <= 1'b0;         // the clear is now running
                    init_state <= I_CLEAR_WAIT;
                end
                I_CLEAR_WAIT: begin
                    if (!clr_busy) init_state <= I_FILL;
                end

                // ---- full-screen background fill ----------------------
                // The window covers the whole visible area, so the panel ends
                // up uniformly orange whatever was in its GRAM before.
                // `fill_valid` is a combinational function of the state (see
                // below), so it is asserted for as long as these states last.
                I_FILL: begin
                    init_state <= I_FILL_BUSY;
                end
                I_FILL_BUSY: begin
                    // wait for the request to be taken
                    if (lcd_active) begin
                        init_state <= I_FILL_WAIT;
                    end
                end
                I_FILL_WAIT: begin
                    // wait for the transfer to finish
                    if (!lcd_active) init_state <= I_FILL_GAP;
                end
                I_FILL_GAP: begin
                    init_state <= I_DRAW;       // let the CS gap elapse
                end

                // ---- playfield lines ---------------------------------
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
                    init_state <= I_DOTS;       // let the last write land
                end

                // ---- pseudo-random dots (prompt.txt #5) --------------–
                // Same handshake shape as the playfield lines, against
                // dot_field's own busy.
                I_DOTS: begin
                    dot_start  <= 1'b1;         // one pulse = all the dots
                    init_state <= I_DOTS_BUSY;
                end
                I_DOTS_BUSY: begin
                    if (dot_busy) init_state <= I_DOTS_WAIT;
                end
                I_DOTS_WAIT: begin
                    if (!dot_busy) init_state <= I_DOTS_GAP;
                end
                I_DOTS_GAP: begin
                    init_state <= I_READY;      // dots complete
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

    // the fill window is the whole screen, in the background colour
    assign fill_valid = (init_state == I_FILL) || (init_state == I_FILL_BUSY);
    assign fill_x0    = 9'd0;
    assign fill_x1    = COLS_LAST;
    assign fill_y0    = 8'd0;
    assign fill_y1    = ROWS_LAST;
    assign fill_color = COLOR_BIT0;

    // port ownership: dot_field has it while the dots are being scattered,
    // game_ctrl once start-up is over (they never overlap)
    assign dot_active  = (init_state == I_DOTS)      || (init_state == I_DOTS_BUSY)
                      || (init_state == I_DOTS_WAIT)  || (init_state == I_DOTS_GAP);
    assign game_active = (init_state == I_GAME_BEGIN);

    line_draw #(
        .FIELD_W      (320),
        .WORDS_PER_ROW(WORDS_PER_ROW),
        .AW           (AW),
        .COLOR        (COLOR_BIT1),
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
        .fb_rd_data(fb_rd_data),
        .lcd_valid (line_valid),
        .lcd_ready (lcd_ready),
        .lcd_x0    (line_x0),
        .lcd_y0    (line_y0),
        .lcd_x1    (line_x1),
        .lcd_y1    (line_y1),
        .lcd_color (line_color)
    );

    // ------------------------------------------------------------------
    // the pseudo-random dots (prompt.txt #5)
    // ------------------------------------------------------------------
    // Written to BOTH destinations for the same reason as the playfield
    // lines: the panel shows them and the frame buffer remembers them, so a
    // moving line that reaches a dot is GAME OVER.
    dot_field #(
        .FIELD_W      (320),
        .FIELD_H      (240),
        .WORDS_PER_ROW(WORDS_PER_ROW),
        .AW           (AW),
        .N_DOTS       (DOT_N),
        .DOT_W        (DOT_W),
        .DOT_H        (DOT_H),
        .X_MIN        (DOT_X_MIN),
        .X_MAX        (DOT_X_MAX),
        .Y_MIN        (DOT_Y_MIN),
        .Y_MAX        (DOT_Y_MAX),
        .SEED         (DOT_SEED),
        .COLOR        (COLOR_DOT)
    ) u_dots (
        .clk       (clk),
        .rst       (rst),
        .start     (dot_start),
        .busy      (dot_busy),
        .fb_wr_en  (dot_wr_en),
        .fb_wr_addr(dot_wr_addr),
        .fb_wr_data(dot_wr_data),
        .fb_rd_addr(dot_rd_addr),
        .fb_rd_data(fb_rd_data),
        .lcd_valid (dot_valid),
        .lcd_ready (lcd_ready),
        .lcd_x0    (dot_x0),
        .lcd_y0    (dot_y0),
        .lcd_x1    (dot_x1),
        .lcd_y1    (dot_y1),
        .lcd_color (dot_color)
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
        .START_Y        (START_Y),
        .COLOR          (COLOR_BIT1)
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
        .fb_rd_data(fb_rd_data),
        .lcd_valid (game_valid),
        .lcd_ready (lcd_ready),
        .lcd_x0    (game_x0),
        .lcd_y0    (game_y0),
        .lcd_x1    (game_x1),
        .lcd_y1    (game_y1),
        .lcd_color (game_color)
    );

    // ------------------------------------------------------------------
    // LEDs (all active low)
    // ------------------------------------------------------------------
    // The panel is only written when something changes, so there is no frame
    // heartbeat any more; led1 is repurposed to show panel activity.
    logic heartbeat;
    always_ff @(posedge clk) begin
        if (rst)
            heartbeat <= 1'b0;
        else if (lcd_done)
            heartbeat <= ~heartbeat;      // toggles once per panel write
    end

    assign led  = ~lcd_ready;                     // panel init done
    assign led0 = ~(init_state == I_GAME_BEGIN);   // playfield drawn, game running
    assign led1 = ~heartbeat;                     // panel write heartbeat
    assign led2 = ~game_over;                     // GAME OVER (latched)
    assign led3 = ~btn_level;                     // button pressed

endmodule
