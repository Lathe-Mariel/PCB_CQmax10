// line_draw.sv
//
// Writes a LIST of horizontal lines into the 1-bit frame buffer:
//   for each i :  (LINE_X0[i], LINE_Y[i]) - (LINE_X1[i], LINE_Y[i])   inclusive
//
// A single `start` pulse draws every line of the table, one line after the
// other, and then leaves the frame buffer alone. `busy` stays high until the
// whole list is done. Nothing is erased: whatever the caller wants gone must
// be cleared first (the frame buffer's `clr_start` does that).
//
// The frame buffer stores 32 horizontally adjacent pixels per 32-bit word, so
// the fastest way to draw a horizontal line is one read-modify-write per word
// instead of one per pixel:
//
//   word address = LINE_Y[i]*WORDS_PER_ROW + wx
//   - whole word inside the span : the mask is all ones
//   - first / last partial word  : the mask is the bit range of the line
//
// Every word is written as (read data | mask), so the first and last partial
// words keep the pixels that were already there. The frame buffer's read port
// is synchronous (registered output, so Quartus can infer an M9K), which is
// why the FSM has a separate L_WAITDATA state between presenting the address
// and using the data. For the words whose mask is all ones the read data is
// irrelevant, but reading them anyway keeps the FSM uniform.
//
// The line table is a set of constant parameter arrays, so the geometry of a
// line is looked up with the running line counter (a small mux) and the bit
// masks are computed with two variable shifts. That keeps the module at one
// copy of the datapath no matter how many lines the table holds.
//
// Limit: the line counter is 4 bits, so N_LINES must be <= 16. The word index
// inside a row is 4 bits, so FIELD_W must be <= 512.
//
// Draw time: ~3 clocks per word, i.e. up to ~30 clocks (0.6 us) per 320-wide
// line and ~5 us for nine of them. The first frame is scanned out ~150 ms
// after power-on (panel init), so the lines are in place long before that; no
// double buffering or tear handling is needed.

module line_draw #(
    parameter int FIELD_W       = 320,
    parameter int WORDS_PER_ROW = 10,     // FIELD_W / 32
    parameter int AW            = 14,     // word address width

    // the lines to draw, (LINE_X0[i], LINE_Y[i]) - (LINE_X1[i], LINE_Y[i])
    parameter int N_LINES = 2,
    parameter int LINE_X0 [N_LINES] = '{0, 40},
    parameter int LINE_X1 [N_LINES] = '{279, 319},
    parameter int LINE_Y  [N_LINES] = '{25, 50}
)(
    input  logic          clk,
    input  logic          rst,

    input  logic          start,        // pulse: draw the whole line list
    output logic          busy,

    // frame buffer write port
    output logic          fb_wr_en,
    output logic [AW-1:0] fb_wr_addr,
    output logic [31:0]   fb_wr_data,

    // frame buffer read port (to read back the partial first/last words)
    output logic [AW-1:0] fb_rd_addr,
    input  logic [31:0]   fb_rd_data
);
    localparam int LAST_LINE_I = (N_LINES > 0) ? N_LINES - 1 : 0;
    localparam logic [3:0] LAST_LINE = LAST_LINE_I[3:0];

    // Field geometry as 32-bit values, so the comparisons against the (also
    // 32-bit) table entries are both unsigned and no narrowing conversion
    // warning is produced. The narrow copies feed the datapath, and they are
    // taken as a SLICE of the wide constant rather than by assigning the
    // int expression directly (that would be a 32 -> 9 bit truncation, which
    // Quartus reports as Warning 10230).
    localparam logic [31:0] FIELD_W_W  = FIELD_W;
    localparam logic [31:0] LAST_COL_W = FIELD_W - 1;
    localparam logic [8:0]  LAST_COL   = LAST_COL_W[8:0];

    // ---- line table lookup ----------------------------------------------
    // The table is constant, so indexing it with the running line counter
    // just builds a small mux.
    logic [3:0] li;                       // index of the line being drawn

    wire [31:0] t_x0 = LINE_X0[li];
    wire [31:0] t_x1 = LINE_X1[li];
    wire [31:0] t_y  = LINE_Y [li];

    wire [8:0] cur_x0 = t_x0[8:0];
    // clamp the end of the line to the last column: the word address is
    // row_base + x/32, so an x1 beyond the row would step into the next row's
    // words instead of stopping at the row edge (only ever matters for a
    // parameter table with an over-long line)
    wire [8:0] cur_x1 = (t_x1 > LAST_COL_W) ? LAST_COL : t_x1[8:0];
    wire [7:0] cur_y  = t_y [7:0];

    // an empty or reversed span has nothing to draw; skip it instead of
    // running the word loop off the end of the row
    wire cur_valid = (t_x0 <= t_x1) && (t_x0 < FIELD_W_W);

    // ---- geometry of the line currently being drawn ----------------------
    // latched from the table when the line starts
    logic [8:0] x0_c, x1_c;
    logic [7:0] y_c;
    logic [7:0] wx;                       // word index inside the row

    // word index and bit index of the two ends of the current line
    wire [7:0] wx0_w = {3'b000, x0_c[8:5]};   // x0 / 32
    wire [4:0] b0_w  = x0_c[4:0];             // x0 % 32
    wire [7:0] wx1_w = {3'b000, x1_c[8:5]};   // x1 / 32
    wire [4:0] b1_w  = x1_c[4:0];             // x1 % 32

    // row_base = y * WORDS_PER_ROW. WORDS_PER_ROW is 10 for a 320-wide
    // screen, so this is y*8 + y*2: shift and add, no real multiplier.
    wire [AW-1:0] row_base = {{(AW-11){1'b0}}, y_c, 3'b000}      // y*8
                           + {{(AW-9){1'b0}},  y_c, 1'b0};       // y*2

    wire [AW-1:0] wx_slice = {{(AW-4){1'b0}}, wx[3:0]};
    wire [AW-1:0] cur_addr = row_base + wx_slice;

    // ---- bit mask for the word being written -----------------------------
    // Bits lo..hi of this word belong to the line:
    //   lo = b0 on the first word of the line, else 0
    //   hi = b1 on the last  word of the line, else 31
    // mask = (all ones << lo) & ~(all ones << (hi+1))
    // A left shift of 32 or more on a 32-bit value yields 0, which is exactly
    // what is wanted for hi = 31 (no upper cut) and lo = 0 (no lower cut).
    wire        is_first = (wx == wx0_w);
    wire        is_last  = (wx == wx1_w);
    wire [4:0]  m_lo_sh  = is_first ? b0_w : 5'd0;
    wire [5:0]  m_hi_sh  = is_last  ? ({1'b0, b1_w} + 6'd1) : 6'd32;
    wire [31:0] m_lo     = 32'hFFFF_FFFF << m_lo_sh;
    wire [31:0] m_hi     = ~(32'hFFFF_FFFF << m_hi_sh);
    wire [31:0] mask_c   = m_lo & m_hi;

    // ---- FSM ------------------------------------------------------------
    // L_LOAD     : latch the geometry of line `li`, start at its first word
    // L_READ     : present the word address, latch its mask
    // L_WAITDATA : wait for the frame buffer's registered read to return
    // L_WRITE    : write rd_data | mask, then step to the next word or line
    typedef enum logic [2:0] {L_IDLE, L_LOAD, L_READ, L_WAITDATA, L_WRITE} state_t;
    state_t state;

    logic [31:0] mask;            // mask for the word being written
    logic        last_word;

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= L_IDLE;
            fb_wr_en   <= 1'b0;
            fb_wr_addr <= '0;
            fb_wr_data <= 32'h0000_0000;
            fb_rd_addr <= '0;
            li         <= 4'd0;
            x0_c       <= 9'd0;
            x1_c       <= 9'd0;
            y_c        <= 8'd0;
            wx         <= 8'd0;
            mask       <= 32'h0000_0000;
            last_word  <= 1'b0;
        end else begin
            fb_wr_en <= 1'b0;

            case (state)
                L_IDLE: begin
                    if (start) begin
                        li    <= 4'd0;
                        state <= L_LOAD;
                    end
                end

                // ---- latch the line to draw ---------------------------
                // The table is only read here, one entry per line, so the
                // running counter never indexes outside it.
                L_LOAD: begin
                    if (cur_valid) begin
                        x0_c  <= cur_x0;
                        x1_c  <= cur_x1;
                        y_c   <= cur_y;
                        wx    <= {3'b000, cur_x0[8:5]};   // start at x0/32
                        state <= L_READ;
                    end else if (li == LAST_LINE) begin
                        state <= L_IDLE;               // nothing left to draw
                    end else begin
                        li    <= li + 4'd1;            // skip the empty line
                        state <= L_LOAD;
                    end
                end

                // ---- present the address of this word ------------------
                L_READ: begin
                    fb_rd_addr <= cur_addr;
                    mask       <= mask_c;
                    last_word  <= (wx == wx1_w);
                    state      <= L_WAITDATA;
                end

                // ---- wait for the registered read data ----------------
                L_WAITDATA: begin
                    state <= L_WRITE;
                end

                // ---- write the merged word ----------------------------
                L_WRITE: begin
                    fb_wr_en   <= 1'b1;
                    fb_wr_addr <= cur_addr;
                    fb_wr_data <= fb_rd_data | mask;

                    if (last_word) begin
                        // end of this line: stop only if it was the last one
                        if (li == LAST_LINE) begin
                            state <= L_IDLE;
                        end else begin
                            li    <= li + 4'd1;
                            state <= L_LOAD;
                        end
                    end else begin
                        wx    <= wx + 8'd1;
                        state <= L_READ;
                    end
                end

                default: state <= L_IDLE;
            endcase
        end
    end

    assign busy = (state != L_IDLE);
endmodule
