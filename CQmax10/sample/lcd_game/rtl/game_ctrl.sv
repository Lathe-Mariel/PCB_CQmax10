// game_ctrl.sv
//
// The moving line of the game (step 4). The static line table drawn during
// start-up is the "playfield"; this module grows one dot at a time from
// (START_X, START_Y) and stops as soon as it would touch anything already
// drawn.
//
// Rules implemented (prompt.txt #4):
//   * the moving line starts at (1,1)
//   * button (PIN_62) NOT pressed : one dot every STEP_MS, down-right
//   * button pressed              : one dot every STEP_MS, up-right
//   * hitting x = FIELD_W-1 (319) : reverse the horizontal direction
//   * hitting x = 0               : reverse the horizontal direction
//   * before drawing a dot, read the frame buffer. If the pixel is already
//     set, that is GAME OVER and all processing stops.
//
// The moving line starts at (START_X, START_Y) - (1,1) by default - and that
// first pixel IS part of the line: the FSM tests it and draws it before
// moving on, so the "already drawn?" check covers the start position too.
//
// WHY A SECOND READ PORT: the LCD scans the frame buffer out continuously, so
// its read port (A) is busy for most of every frame. The pixel test here needs
// its own address in an unrelated cycle, so it uses read port B. Both ports are
// synchronous, which is what lets Quartus keep the buffer in one M9K.
//
// WHY A SECOND READ PORT: the LCD scans the frame buffer out continuously, so
// its read port (A) is busy for most of every frame. The pixel test here needs
// its own address in an unrelated cycle, so it uses read port B. Both ports are
// synchronous, which is what lets Quartus keep the buffer in one M9K.
//
// The horizontal bounce is implemented by reversing AND stepping back one
// pixel, so the head never leaves the screen (at 319 it moves to 318). The
// trail is diagonal at every step because the vertical direction always
// changes the row, so a bounce always lands on a fresh pixel rather than on
// its own trail.
//
// The vertical direction is never reversed by the rules. y is therefore
// CLAMPED to the screen (0 .. FIELD_H-1) so the head cannot run off the top or
// bottom. Note the consequence: while y is clamped, the head travels
// horizontally, and bouncing then does retrace its own trail - which the
// "already drawn" test correctly reports as GAME OVER. On a 320x240 field this
// is what happens in practice: x and y advance at the same rate on a diagonal,
// and the field is wider than it is tall, so y reaches an edge long before x
// can travel from one side to the other.
//
// Dot rate: STEP_CYCLES + 3 clocks per dot. The 3 clocks are the TEST/WAIT/
// DRAW states, i.e. 60 ns against a STEP_MS of tens of ms, so the rate is
// STEP_MS per dot for any practical purpose.
//
// FRAME SYNCHRONISATION (LOCK_TO_FRAME)
// The panel only shows the frame buffer at FRAME_PERIOD_MS intervals, so a dot
// that arrives mid-frame is not visible until the NEXT frame. If the dot period
// is not a multiple of the frame period, the number of dots that appear per
// frame keeps changing (e.g. 2, 3, 2, 3, ...) and the moving line looks jerky
// even when nothing else is wrong.
//
// With LOCK_TO_FRAME set, STEP_MS becomes a MINIMUM and the period is rounded
// UP to a whole number of frame periods:
//
//   period = ceil(STEP_MS / FRAME_PERIOD_MS) * FRAME_PERIOD_MS
//
// Every displayed frame then shows exactly that many new dots, so the line
// moves at a constant, regular speed - which reads as smooth far more than a
// raw frame-rate increase does.
//
// The rounding is done at elaboration time from integer parameters (no real
// arithmetic, which synthesis tools do not support in parameter expressions),
// and the frame period used here is the MINIMUM frame period. The real period
// can be longer when the frame transfer itself is slower than FRAME_PERIOD_MS
// (SPI-bound), in which case the dot rate simply follows the transfer and stays
// in step anyway.

module game_ctrl #(
    parameter int CLK_FREQ_HZ   = 50_000_000,
    parameter int MS_SCALE      = 1,      // 1 in hardware; divides delays for simulation
    parameter int STEP_MS       = 10,     // minimum time between dots, in ms

    // round the dot period up to a whole number of frames (see the header)
    parameter bit LOCK_TO_FRAME = 1'b1,
    parameter int FRAME_PERIOD_MS = 250,  // must match the frame_seq parameter

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
    parameter bit START_DIR_R = 1'b1
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

    // frame buffer write port
    output logic          fb_wr_en,
    output logic [AW-1:0] fb_wr_addr,
    output logic [31:0]   fb_wr_data,

    // frame buffer read port B (pixel test)
    output logic [AW-1:0] fb_rd_addr,
    input  logic [31:0]   fb_rd_data
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
    //   G_DRAW  (cycle 2) : data valid -> test the bit, then either set it or
    //                       declare GAME OVER (address is unchanged, so the
    //                       write targets the pixel that was tested)
    //   G_STEP            : hold STEP_MS, then advance the head by one dot
    typedef enum logic [2:0] {G_IDLE, G_TEST, G_WAIT, G_DRAW, G_STEP, G_OVER} st_t;

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
        end else begin
            fb_wr_en <= 1'b0;

            case (state)
                G_IDLE: begin
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
                        // Nothing is written; the image stays on the panel.
                        running   <= 1'b0;
                        game_over <= 1'b1;
                        state     <= G_OVER;
                    end else begin
                        fb_wr_en   <= 1'b1;
                        fb_wr_addr <= cur_addr;
                        fb_wr_data <= fb_rd_data | (32'h0000_0001 << cur_bit);
                        step_cnt   <= '0;
                        state      <= G_STEP;
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

                // ---- frozen: wait for a reset --------------------------
                G_OVER: begin
                    running <= 1'b0;
                end

                default: state <= G_IDLE;
            endcase
        end
    end

    assign dot_x = x;
    assign dot_y = y[7:0];
endmodule
