// game_ctrl.sv
//
// The game from prompt.txt #4: a one-pixel-wide line grows from (1,1).
//
//   * button released : one dot every STEP_MS, down and to the right
//   * button pressed  : one dot every STEP_MS, up and to the right
//   * reaching x=319 or x=0 : the HORIZONTAL direction reverses
//   * before drawing a dot, the frame buffer is checked; if the target pixel
//     is already set the game is over and everything stops
//
// The vertical direction never reverses (the button only chooses up or down),
// so y clamps at the top and bottom edges; see "WHAT THIS GAME ACTUALLY DOES"
// below.
//
// ---------------------------------------------------------------------------
// TWO DESTINATIONS PER DOT
// ---------------------------------------------------------------------------
// Every accepted dot is written to BOTH:
//
//   1. the frame buffer, because it is the collision model. It holds the
//      playfield lines and the trail of the moving line, so the next dot's
//      read-before-write test is what detects a collision.
//   2. the panel, as a single 1x1 rectangle write ("ドット単位で描画").
//
// The panel is NOT a scan-out of the frame buffer any more: the ILI9341 keeps
// its own GRAM, so a dot only has to be sent once, when it is drawn. That is
// why this module requests one 1x1 window per dot instead of relying on the
// whole buffer being streamed every frame.
//
// ---------------------------------------------------------------------------
// FRAME SYNCHRONISATION (LOCK_TO_FRAME)
// ---------------------------------------------------------------------------
// STEP_MS becomes a MINIMUM and the period is rounded UP to a whole number of
// frame periods:
//
//   period = ceil(STEP_MS / FRAME_PERIOD_MS) * FRAME_PERIOD_MS
//
// Without the rounding, the number of dots that land in one panel refresh
// keeps changing (0, 0, 1, 0, 1, ...) and the line looks jerky even when
// everything else is correct. The rounding is done at elaboration time from
// integer parameters (no real arithmetic, which synthesis tools do not support
// in parameter expressions).
//
// ---------------------------------------------------------------------------
// WHAT THIS GAME ACTUALLY DOES (important)
// ---------------------------------------------------------------------------
// Starting at (1,1) moving right, the head reaches (25,25) first and stops
// there: that is the first playfield line. The x=319 reversal DOES happen
// (e.g. from (315,10)) but the head then retraces its own trail and stops
// immediately. The x=0 reversal can never happen from (1,1) moving right,
// because x and y advance together and the screen is wider (320) than it is
// tall (240), so y hits an edge first; it exists for START_DIR_R = 0 and for
// any future start position, and is covered by the unit tests.

module game_ctrl #(
    parameter int CLK_FREQ_HZ   = 50_000_000,
    parameter int MS_SCALE      = 1,      // 1 in hardware; divides delays for simulation
    parameter int STEP_MS       = 10,     // minimum time between dots, in ms

    // round the dot period up to a whole number of frames (see the header)
    parameter bit LOCK_TO_FRAME = 1'b1,
    parameter int FRAME_PERIOD_MS = 250,  // must match the top-level frame period

    parameter int FIELD_W       = 320,
    parameter int FIELD_H       = 240,
    parameter int WORDS_PER_ROW = 10,     // FIELD_W / 32
    parameter int AW            = 14,     // word address width
    parameter int START_X = 1,
    parameter int START_Y = 1,

    // initial horizontal direction: 1 = right (the rule in the prompt),
    // 0 = left. The left-edge reversal is unreachable from (1,1) moving right
    // (the head reaches x=319 first, bounces, and immediately retraces its own
    // trail), so this exists to exercise that branch in simulation and for any
    // future start position.
    parameter bit START_DIR_R = 1'b1,

    parameter logic [15:0] COLOR = 16'hF800   // drawn dot colour (red)
)(
    input  logic clk,
    input  logic rst,

    // control
    input  logic start,          // pulse: begin the game
    output logic running,        // 1 while the game is being played
    output logic game_over,      // latched; stays 1 until reset

    // the game button (debounced): 1 = pressed -> the line grows upwards
    input  logic btn,

    // head of the moving line (for testbenches and LED indicators)
    output logic [8:0] dot_x,
    output logic [7:0] dot_y,

    // frame buffer write port (collision model)
    output logic          fb_wr_en,
    output logic [AW-1:0] fb_wr_addr,
    output logic [31:0]   fb_wr_data,

    // frame buffer read port (pixel test)
    output logic [AW-1:0] fb_rd_addr,
    input  logic [31:0]   fb_rd_data,

    // panel rectangle request: one 1x1 window per dot
    output logic        lcd_valid,
    input  logic        lcd_ready,
    output logic [8:0]  lcd_x0,
    output logic [7:0]  lcd_y0,
    output logic [8:0]  lcd_x1,
    output logic [7:0]  lcd_y1,
    output logic [15:0] lcd_color
);
    // ---- effective dot period --------------------------------------------
    // Integer ceiling division: (n + d - 1) / d, with d clamped to at least 1
    // so the expression is always well defined.
    localparam int FRAME_MS_SAFE = (FRAME_PERIOD_MS > 0) ? FRAME_PERIOD_MS : 1;
    localparam int FRAMES_PER_DOT =
        (STEP_MS + FRAME_MS_SAFE - 1) / FRAME_MS_SAFE;
    localparam int FRAMES_PER_DOT_SAFE = (FRAMES_PER_DOT > 0) ? FRAMES_PER_DOT : 1;
    localparam int STEP_MS_EFF = LOCK_TO_FRAME
                               ? (FRAMES_PER_DOT_SAFE * FRAME_MS_SAFE)
                               : STEP_MS;

    localparam int STEP_CYCLES_I = ((CLK_FREQ_HZ / 1000) / MS_SCALE) * STEP_MS_EFF;
    // a simulation may set MS_SCALE so high that (CLK/1000)/MS_SCALE is 0; the
    // counter would then compare against STEP_CYCLES_I-1 = -1 and never finish.
    localparam int STEP_CYCLES = (STEP_CYCLES_I > 0) ? STEP_CYCLES_I : 1;
    localparam int TW            = $clog2(STEP_CYCLES + 1);

    // Geometry constants. The parameter ints are 32-bit and SIGNED, so they
    // are held in unsigned 32-bit localparams and the narrow copies are taken
    // as SLICES. Assigning the int expression directly to a 9-bit localparam
    // makes Quartus report "Warning (10230) truncated value with size 32 to
    // match size of target (9)", and comparing an int against a logic wire
    // would be a signed/unsigned comparison.
    localparam logic [31:0] LAST_X_W = FIELD_W - 1;
    localparam logic [31:0] LAST_Y_W = FIELD_H - 1;
    localparam logic [31:0] START_X_W = START_X;
    localparam logic [31:0] START_Y_W = START_Y;

    localparam logic [8:0]  LAST_X = LAST_X_W[8:0];
    localparam logic [8:0]  LAST_Y = LAST_Y_W[8:0];
    localparam logic [8:0]  SX     = START_X_W[8:0];
    localparam logic [8:0]  SY     = START_Y_W[8:0];

    // the last value the step counter takes (it counts 0 .. STEP_CYCLES-1).
    // The subtraction goes through a wide localparam first: a bit-select of
    // an expression, like (STEP_CYCLES_I - 1)[TW-1:0], is a syntax error.
    localparam logic [31:0]    STEP_LAST_W = STEP_CYCLES - 1;
    localparam logic [TW-1:0]  STEP_LAST   = STEP_LAST_W[TW-1:0];

    // ---- head position and direction ------------------------------------
    logic [8:0] x, y;
    logic       dir_r;                 // 1 = moving right

    // row_base = y * WORDS_PER_ROW. A real multiply is used rather than the
    // shift-and-add trick, because that only works for WORDS_PER_ROW = 10 and
    // this module is unit-tested on a smaller field (to reach the left-edge
    // bounce, which the 320x240 geometry can never reach). y is 9 bits and
    // WORDS_PER_ROW is 4, so this is a 9x4 multiply.
    wire [AW-1:0] row_base = y * WORDS_PER_ROW[AW-1:0];

    wire [AW-1:0] x_word   = {{(AW-4){1'b0}}, x[8:5]};
    wire [AW-1:0] cur_addr = row_base + x_word;
    wire [4:0]    cur_bit  = x[4:0];

    // ---- next position ---------------------------------------------------
    // hitting a side wall reverses the direction and steps back one pixel
    wire hit_hi = dir_r && (x == LAST_X);
    wire hit_lo = ~dir_r && (x == 9'd0);
    wire bounce = hit_hi || hit_lo;

    wire [8:0] x_fwd  = dir_r ? (x + 9'd1) : (x - 9'd1);
    wire [8:0] x_back = dir_r ? (x - 9'd1) : (x + 9'd1);

    wire [8:0] x_next = bounce ? x_back : x_fwd;
    wire       d_next = bounce ? ~dir_r : dir_r;

    // the vertical direction comes from the button only, clamped to the screen
    wire [8:0] y_up   = (y == 9'd0)     ? 9'd0  : (y - 9'd1);
    wire [8:0] y_down = (y == LAST_Y)   ? LAST_Y: (y + 9'd1);
    wire [8:0] y_next = btn ? y_up : y_down;

    // ---- FSM -------------------------------------------------------------
    // The frame buffer's read port is registered, so the data for an address
    // presented in cycle N is only valid in cycle N+2. The FSM therefore has
    // TWO wait states between presenting the address and using the data:
    //
    //   G_TEST  (cycle 0) : present the address of the pixel to move to
    //   G_WAIT  (cycle 1) : data not valid yet
    //   G_DRAW  (cycle 2) : data valid -> test the bit, then either set it
    //                       (frame buffer write) or declare GAME OVER
    //   G_LCD   : assert the 1x1 panel request
    //   G_LCDW  : hold it until the panel controller accepts it
    //   G_STEP  : hold STEP_MS, then advance the head by one dot
    //
    // G_LCD and G_LCDW exist as SEPARATE states because `lcd_valid` is
    // registered: asserting it and clearing it in the same always block would
    // leave it high for zero cycles (the later assignment wins), so the
    // request would never be seen.
    //
    // The address is unchanged between G_TEST and G_DRAW, so the write targets
    // exactly the pixel that was tested.
    typedef enum logic [2:0] {G_IDLE, G_TEST, G_WAIT, G_DRAW, G_LCD, G_LCDW,
                              G_STEP, G_OVER} st_t;

    st_t     state;
    logic [TW-1:0] step_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= G_IDLE;
            running    <= 1'b0;
            game_over  <= 1'b0;
            x          <= SX;
            y          <= SY;
            dir_r      <= 1'b1;
            step_cnt   <= '0;
            fb_wr_en   <= 1'b0;
            fb_wr_addr <= '0;
            fb_wr_data <= 32'h0000_0000;
            fb_rd_addr <= '0;
            lcd_valid  <= 1'b0;
            lcd_x0     <= 9'd0;
            lcd_y0     <= 8'd0;
            lcd_x1     <= 9'd0;
            lcd_y1     <= 8'd0;
            lcd_color  <= COLOR;
        end else begin
            fb_wr_en <= 1'b0;

            case (state)
                G_IDLE: begin
                    lcd_valid <= 1'b0;
                    if (start) begin
                        x         <= SX;
                        y         <= SY;
                        dir_r     <= START_DIR_R;   // 1 = right
                        step_cnt  <= '0;
                        game_over <= 1'b0;
                        running   <= 1'b1;
                        state     <= G_TEST;
                    end
                end

                // ---- present the address of the pixel to move to --------
                G_TEST: begin
                    fb_rd_addr <= cur_addr;
                    state      <= G_WAIT;
                end

                // ---- wait for the registered read data ------------------
                G_WAIT: begin
                    state <= G_DRAW;
                end

                // ---- test the pixel, then set it ------------------------
                G_DRAW: begin
                    if (fb_rd_data[cur_bit]) begin
                        // something is already drawn here: GAME OVER.
                        // Nothing is written and nothing is sent to the panel,
                        // so the image on the LCD stays as it is.
                        running   <= 1'b0;
                        game_over <= 1'b1;
                        state     <= G_OVER;
                    end else begin
                        // collision model: remember the trail
                        fb_wr_en   <= 1'b1;
                        fb_wr_addr <= cur_addr;
                        fb_wr_data <= fb_rd_data | (32'h0000_0001 << cur_bit);
                        state      <= G_LCD;
                    end
                end

                // ---- draw the dot on the panel --------------------------
                // One 1x1 window. The head coordinates are held for the whole
                // state, so the request is stable while it waits to be taken.
                G_LCD: begin
                    lcd_valid <= 1'b1;
                    lcd_x0    <= x;
                    lcd_x1    <= x;
                    lcd_y0    <= y[7:0];
                    lcd_y1    <= y[7:0];
                    lcd_color <= COLOR;
                    state     <= G_LCDW;
                end

                // hold the request until the controller takes it
                G_LCDW: begin
                    if (lcd_ready) begin
                        lcd_valid <= 1'b0;      // accepted
                        step_cnt  <= '0;
                        state     <= G_STEP;
                    end
                end

                // ---- hold STEP_MS, then advance one dot -----------------
                G_STEP: begin
                    if (step_cnt == STEP_LAST) begin
                        x        <= x_next;
                        y        <= y_next;
                        dir_r    <= d_next;
                        step_cnt <= '0;
                        state    <= G_TEST;
                    end else begin
                        step_cnt <= step_cnt + 1'b1;
                    end
                end

                // ---- frozen: wait for a reset ---------------------------
                G_OVER: begin
                    running   <= 1'b0;
                    lcd_valid <= 1'b0;
                end

                default: state <= G_IDLE;
            endcase
        end
    end

    assign dot_x = x;
    assign dot_y = y[7:0];
endmodule
