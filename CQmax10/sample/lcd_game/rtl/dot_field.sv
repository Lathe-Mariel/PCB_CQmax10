// dot_field.sv
//
// Scatters N_DOTS small rectangles (DOT_W x DOT_H, default 2x2) over the
// playfield at PSEUDO-RANDOM positions (prompt.txt #5), at the very end of the
// start-up sequence.
//
// ---------------------------------------------------------------------------
// WHY BOTH DESTINATIONS
// ---------------------------------------------------------------------------
// Since Step 6 the frame buffer is NOT displayed: it is only the collision
// model, and the panel is written directly with windowed rectangle commands.
// So a dot has to be written to TWO places, exactly like the playfield lines
// and the moving line:
//
//   * the frame buffer, so the game stops when the moving line reaches it
//   * the panel, as one DOT_W x DOT_H rectangle ("点を描画")
//
// ---------------------------------------------------------------------------
// THE PSEUDO-RANDOM SEQUENCE
// ---------------------------------------------------------------------------
// A 32-bit maximal-length LFSR (Galois/right-shifting, taps 32,22,2,1) is used
// as a simple pseudo-random number generator. It is a shift register with one
// XOR feedback, so it costs a handful of LEs and produces a sequence of length
// 2^32-1 that passes through every non-zero 32-bit value exactly once before
// repeating. It must never be seeded with 0 (an all-zero LFSR is a fixed
// point), so SEED is a non-zero constant.
//
//   feedback = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]
//   lfsr     <= {lfsr[30:0], feedback}      // one step
//
// A candidate coordinate is taken from the low bits of the register AFTER a
// step:
//
//   candidate X = lfsr_next[8:0]     (0..511)
//   candidate Y = lfsr_next[7:0]     (0..255)
//
// The candidate is used only if it falls inside the allowed range; otherwise
// the LFSR is stepped again and a new candidate is tried. This is rejection
// sampling: it needs NO divider and no modulo (both would cost real logic
// here), only a comparator, and because a maximal LFSR visits every 9-bit /
// 8-bit pattern it is guaranteed to terminate. The X range is 317 of 512 codes
// wide (~62 % hit rate) and Y is 237 of 256 (~93 %), so the expected number of
// tries is ~1.6 and ~1.08 per coordinate.
//
// Rejection sampling also keeps the distribution FLAT over the allowed range.
// Clamping an out-of-range candidate instead would pile dots onto the edges,
// and a modulo would need a divider.
//
// ---------------------------------------------------------------------------
// THE ALLOWED RANGE
// ---------------------------------------------------------------------------
// The range asked for is (2,2)-(318,318), which is a square. The panel is only
// 320x240, so a Y of 318 is off-screen: Y_MAX is clamped to
// FIELD_H - DOT_H (238), the last row where a whole 2x2 dot still fits. Y_MIN
// is 2, so no dot lands in the 2-pixel border.
//
// ---------------------------------------------------------------------------
// TIMING
// ---------------------------------------------------------------------------
// Each pixel of a dot costs one word read-modify-write (three clocks) plus
// one panel request for the whole dot at the end, so 20 dots of 2x2 are about
// 20*(4*3+2) = 280 clocks - nothing compared with the full-screen fill that
// precedes them.
//
// The dot is written one PIXEL at a time. That is deliberately the simple
// version: OR-ing a single bit into a word and writing the word back is
// idempotent, so a word that receives two pixels of the same dot (which happens
// whenever the dot straddles a word boundary) can simply be read, OR-ed and
// written twice - the second read already sees the first write, because three
// clocks separate the two read-modify-write pairs. No mask arithmetic is
// needed and the operation is obviously correct.
//
// The rectangle is walked with two counters (dx, dy) rather than by dividing a
// linear pixel index by DOT_W, because a division would be real logic. The
// counters also keep the module independent of DOT_W/DOT_H being powers of two.

module dot_field #(
    parameter int FIELD_W       = 320,
    parameter int FIELD_H       = 240,
    parameter int WORDS_PER_ROW = 10,     // FIELD_W / 32
    parameter int AW            = 14,     // word address width

    parameter int N_DOTS        = 20,     // how many dots to scatter
    parameter int DOT_W         = 2,
    parameter int DOT_H         = 2,

    // the requested position range. X_MAX/Y_MAX are clamped below so a whole
    // dot always fits on the panel.
    parameter int X_MIN         = 2,
    parameter int X_MAX         = 318,
    parameter int Y_MIN         = 2,
    parameter int Y_MAX         = 318,

    parameter logic [31:0] SEED = 32'hACE1_2345,   // must be non-zero

    parameter logic [15:0] COLOR = 16'hF81F        // purple (magenta)
)(
    input  logic          clk,
    input  logic          rst,

    input  logic          start,        // pulse: scatter N_DOTS dots
    output logic          busy,

    // frame buffer write port
    output logic          fb_wr_en,
    output logic [AW-1:0] fb_wr_addr,
    output logic [31:0]   fb_wr_data,

    // frame buffer read port (partial read-modify-write of each word)
    output logic [AW-1:0] fb_rd_addr,
    input  logic [31:0]   fb_rd_data,

    // panel rectangle request (one per dot)
    output logic          lcd_valid,
    input  logic          lcd_ready,
    output logic [8:0]    lcd_x0,
    output logic [7:0]    lcd_y0,
    output logic [8:0]    lcd_x1,
    output logic [7:0]    lcd_y1,
    output logic [15:0]   lcd_color
);
    // last position where a whole dot still fits on the panel. `int` is signed,
    // so the parameters are widened to unsigned 32-bit values before they are
    // compared; the narrow datapath values are then taken as a SLICE of the
    // constant (assigning the int expression directly would be a 32 -> 9 bit
    // truncation, which Quartus reports as Warning 10230).
    localparam logic [31:0] X_LAST_W = (X_MAX > (FIELD_W - DOT_W)) ? (FIELD_W - DOT_W)
                                                                    : X_MAX;
    localparam logic [31:0] Y_LAST_W = (Y_MAX > (FIELD_H - DOT_H)) ? (FIELD_H - DOT_H)
                                                                    : Y_MAX;
    localparam logic [8:0]  X_LAST   = X_LAST_W[8:0];
    localparam logic [7:0]  Y_LAST   = Y_LAST_W[7:0];

    localparam logic [31:0] X_FIRST_W = X_MIN;
    localparam logic [31:0] Y_FIRST_W = Y_MIN;
    localparam logic [8:0]  X_FIRST   = X_FIRST_W[8:0];
    localparam logic [7:0]  Y_FIRST   = Y_FIRST_W[7:0];

    // The dot counter is 5 bits, so up to 32 dots can be drawn in one call.
    localparam logic [31:0] DW_LAST_W = DOT_W - 1;
    localparam logic [31:0] DH_LAST_W = DOT_H - 1;
    localparam logic [3:0]  DW_LAST  = DW_LAST_W[3:0];   // last dx (0-based)
    localparam logic [3:0]  DH_LAST  = DH_LAST_W[3:0];   // last dy (0-based)
    localparam logic [4:0] DOT_LAST = N_DOTS[4:0] - 5'd1;         // 0-based

    // ---- pseudo-random number generator --------------------------------
    logic [31:0] lfsr;
    wire         lfsr_fb   = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];
    wire [31:0]  lfsr_next = {lfsr[30:0], lfsr_fb};

    // candidate coordinates, taken from the register AFTER one step
    wire [8:0] x_cand = lfsr_next[8:0];
    wire [7:0] y_cand = lfsr_next[7:0];

    wire x_ok = (x_cand >= X_FIRST) && (x_cand <= X_LAST);
    wire y_ok = (y_cand >= Y_FIRST) && (y_cand <= Y_LAST);

    // ---- dot state ------------------------------------------------------
    // The dot rectangle is walked with two counters rather than by dividing a
    // linear pixel index by DOT_W, because a division would be real logic.
    logic [4:0] dot_i;                    // which dot is being drawn
    logic [3:0] dx_i;                     // column inside the dot
    logic [3:0] dy_i;                     // row inside the dot
    logic [8:0] x_c, x1_c;                // latched dot position
    logic [7:0] y_c, y1_c;

    wire [8:0] px = x_c + {5'b0, dx_i};              // pixel column
    wire [7:0] py = y_c + {4'b0, dy_i};              // pixel row

    // word address = y*WORDS_PER_ROW + x/32. WORDS_PER_ROW is 10 for a
    // 320-wide screen, so y*10 is y*8 + y*2: shift and add, no multiplier.
    wire [AW-1:0] row_base = {{(AW-11){1'b0}}, py, 3'b000}     // py*8
                           + {{(AW-9){1'b0}},  py, 1'b0};      // py*2
    wire [AW-1:0] px_slice = {{(AW-4){1'b0}}, px[8:5]};        // px/32
    wire [AW-1:0] pix_addr = row_base + px_slice;

    wire [4:0]  pix_bit = px[4:0];                             // px%32
    wire [31:0] pix_mask = 32'h0000_0001 << pix_bit;

    // ---- FSM ------------------------------------------------------------
    // D_IDLE  : waiting for `start`
    // D_X     : step the LFSR until an in-range X candidate appears
    // D_Y     : same for Y
    // D_READ  : present the word address of the current pixel
    // D_WAIT  : wait for the frame buffer's registered read
    // D_WRITE : write (read data | the pixel's bit)
    // D_LCD   : assert the panel rectangle for the finished dot
    // D_LCDW  : hold it until the controller accepts it
    //
    // D_LCD and D_LCDW are SEPARATE states because `lcd_valid` is a register:
    // asserting it and clearing it in the same always block would leave it
    // high for zero cycles (the later assignment wins) and the request would
    // never be seen at all.
    typedef enum logic [3:0] {D_IDLE, D_X, D_Y,
                              D_READ, D_WAIT, D_WRITE,
                              D_LCD, D_LCDW} state_t;
    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= D_IDLE;
            lfsr       <= SEED;
            dot_i      <= 5'd0;
            dx_i       <= 4'd0;
            dy_i       <= 4'd0;
            x_c        <= 9'd0;
            y_c        <= 8'd0;
            x1_c       <= 9'd0;
            y1_c       <= 8'd0;
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
                D_IDLE: begin
                    lcd_valid <= 1'b0;
                    if (start) begin
                        lfsr  <= SEED;
                        dot_i <= 5'd0;
                        state <= D_X;
                    end
                end

                // ---- pick an X inside the range -----------------------
                // Rejection sampling: step, look, use it or step again.
                D_X: begin
                    lfsr <= lfsr_next;
                    if (x_ok) begin
                        x_c   <= x_cand;
                        x1_c  <= x_cand + {5'b0, DW_LAST[3:0]};   // last column
                        state <= D_Y;
                    end
                end

                // ---- pick a Y inside the range ------------------------
                D_Y: begin
                    lfsr <= lfsr_next;
                    if (y_ok) begin
                        y_c   <= y_cand;
                        y1_c  <= y_cand + {4'b0, DH_LAST[3:0]};   // last row
                        dx_i  <= 4'd0;
                        dy_i  <= 4'd0;
                        state <= D_READ;
                    end
                end

                // ---- present the address of this pixel ---------------
                D_READ: begin
                    fb_rd_addr <= pix_addr;
                    state      <= D_WAIT;
                end

                // ---- wait for the registered read data ---------------
                D_WAIT: begin
                    state <= D_WRITE;
                end

                // ---- set the pixel's bit -----------------------------
                D_WRITE: begin
                    fb_wr_en   <= 1'b1;
                    fb_wr_addr <= pix_addr;
                    fb_wr_data <= fb_rd_data | pix_mask;

                    if (dx_i == DW_LAST) begin
                        dx_i <= 4'd0;                    // next row of the dot
                        if (dy_i == DH_LAST) begin
                            state <= D_LCD;              // dot done, now the panel
                        end else begin
                            dy_i  <= dy_i + 4'd1;
                            state <= D_READ;
                        end
                    end else begin
                        dx_i  <= dx_i + 4'd1;
                        state <= D_READ;
                    end
                end

                // ---- panel rectangle for the whole dot ---------------
                D_LCD: begin
                    lcd_valid <= 1'b1;
                    lcd_x0    <= x_c;
                    lcd_x1    <= x1_c;
                    lcd_y0    <= y_c;
                    lcd_y1    <= y1_c;
                    lcd_color <= COLOR;
                    state     <= D_LCDW;
                end

                // hold the request until the controller takes it
                D_LCDW: begin
                    if (lcd_ready) begin
                        lcd_valid <= 1'b0;           // accepted
                        if (dot_i == DOT_LAST) begin
                            state <= D_IDLE;
                        end else begin
                            dot_i <= dot_i + 5'd1;
                            state <= D_X;
                        end
                    end
                end

                default: state <= D_IDLE;
            endcase
        end
    end

    assign busy = (state != D_IDLE);
endmodule
