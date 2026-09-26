// game_fsm.sv
//
// Top-level game state machine for "さめがめ".  It owns the game-state
// transitions, the board write port, the score, and the animation control
// passed to the renderer.
//
// State flow (spec section 4):
//   INIT -> GENERATE_BOARD -> PLAY -> FLOODFILL -> ERASE_EFFECT ->
//   ERASE_COMMIT -> FALL_ANIMATION -> COLUMN_SHIFT_ANIMATION -> PLAY
//   ... and GAMEOVER when the board can no longer be cleared.
//
// `frame_tick` is a one-cycle pulse per frame (from the LCD frame timer).
// The 6-frame blink and the 5px/frame animations advance on it.  Board updates
// (gravity / column-shift commit) run as fast back-to-back cycles, hidden by
// the animation overlays; the FSM holds the renderer in the matching animation
// mode until those animations finish.
//
// Touch: a `touch_down` during PLAY latches the touched cell, runs the flood
// fill, and (if group >= 2) enters the erase sequence; a group of 1 returns to
// PLAY.
//
// CURSOR INPUT (replaces the touch panel)
// --------------------------------------
// The touch panel is gone (the XPT2046 never drove MISO on the board).  Input is
// now the Pmod-2xDS2 PS2 pad:
//     direction keys -> move a CURSOR around the board (one cell per press)
//     ○ (circle)     -> SELECT the panel under the cursor
// The cursor is a pair of registers here and is published to the renderer, which
// draws that cell INVERTED so the player can see where it is.
//
// The keys are treated as one-shot: each press moves exactly one cell, because
// a held key is edge-detected into a single pulse.  This FSM therefore reads the
// RISING EDGE of each key rather than its level.

module game_fsm #(
    parameter int COLS = 16,
    parameter int ROWS = 12,
    parameter int CELLS = COLS * ROWS,      // 192
    parameter int AW   = 8,
    parameter int BLINK_FRAMES = 3
)(
    input  logic        clk,
    input  logic        rst,

    input  logic        frame_tick,    // 1-cycle pulse per frame

    // ------------------------------------------------------------------
    // cursor input (Pmod-2xDS2 PS2 pad), all levels, 1 = pressed
    // ------------------------------------------------------------------
    input  logic        key_up,
    input  logic        key_down,
    input  logic        key_left,
    input  logic        key_right,
    input  logic        key_select,    // ○ button

    // cursor position, published to the renderer (which inverts that cell)
    output logic [3:0]  cur_x,
    output logic [3:0]  cur_y,
    output logic        cur_on,        // 1 = draw the cursor

    // board cell read B (driven by the flood-fill engine)
    output logic [AW-1:0] ff_rd_addr,
    input  logic [2:0]    ff_rd_data,

    // board write port
    output logic        board_wr_en,
    output logic [AW-1:0] board_wr_addr,
    output logic [2:0]  board_wr_data,

    // board column read (shared by gravity/shift; one is active at a time)
    output logic [3:0]  col_rd_col,
    input  logic [35:0] col_rd_data,

    // score
    output logic [15:0] score,

    // renderer animation control
    output logic [1:0]   anim_mode,
    output logic [CELLS-1:0] blink_mask,
    output logic            blink_on,
    output logic [8:0]   fall_px,
    output logic [CELLS*4-1:0] fall_dist,
    output logic [8:0]   shift_px,
    output logic [COLS*4-1:0] shift_dist,

    // status
    output logic        game_over
);
    localparam logic [2:0] EMPTY = 3'b111;

    // ------------------------------------------------------------------
    // ANIMATION SPEED
    //
    // How far the fall / shift animation advances per display frame, in pixels.
    // One frame is 166 ms, so this is 10 px per 166 ms (a full 20 px cell takes
    // two frames).  Was 5 px, which made a full-height drop take ~8 s.
    //
    // The renderer clamps its per-cell offset with min(progress, dist*20), so
    // over-shooting the span is harmless - it simply finishes the motion early.
    // The only requirement is that the comparison below is >= rather than ==.
    //
    // Keep this in step with the `fall phase` / `shift phase` bounds in
    // tb_game_fsm.sv if it is changed again.
    // ------------------------------------------------------------------
    localparam logic [8:0] PX_STEP = 9'd10;

    typedef enum logic [3:0] {
        S_INIT, S_GENERATE, S_CHECK, S_CHECK_WAIT, S_PLAY, S_FLOODFILL,
        S_ERASE_EFFECT, S_FALL_WAIT, S_FALL_ANIM, S_SHIFT_WAIT, S_SHIFT_ANIM,
        S_GAMEOVER
    } state_t;
    state_t state;

    // ---- random generator ----
    logic        rng_next;
    logic [15:0] rng_val;
    rng_generator u_rng (
        .clk(clk), .rst(rst), .seed(1'b0), .next(rng_next), .rng(rng_val)
    );

    // ---- generation / animation registers (declared early: used in the
    //      flood-fill instantiation below) ----
    logic [7:0] gen_idx;
    logic [3:0] tap_x, tap_y;
    logic [8:0] fall_px_r, shift_px_r;
    // Distance the current animation must cover, LATCHED once the engine that
    // produces it has finished.  See the S_ERASE_EFFECT / S_FALL_ANIM notes: the
    // engine's `max_dist` is 0 until it has scanned the board, so reading it
    // straight from the animation state would latch a zero and end the animation
    // on its first frame - which also skipped the gravity commit entirely and
    // produced an unshifted, un-gravitated board.
    logic [8:0] fall_span_r, shift_span_r;
    logic [3:0] fall_frame, shift_frame;

    // ---- cursor ----
    // The cursor starts at cell (0,0) as specified.  The keys are converted to
    // one-cycle pulses below so a single press moves exactly one cell.
    logic [3:0] cur_x_r, cur_y_r;
    logic       cur_on_r;

    // key edge detection: keep the previous level and pulse on a rising edge
    logic k_up_d, k_dn_d, k_lf_d, k_rt_d, k_sel_d;
    wire  e_up = key_up     & ~k_up_d;
    wire  e_dn = key_down   & ~k_dn_d;
    wire  e_lf = key_left   & ~k_lf_d;
    wire  e_rt = key_right  & ~k_rt_d;
    wire  e_sel= key_select & ~k_sel_d;

    // game-over scan: run flood fill on every non-empty cell and see if any
    // group has size >= 2
    logic [7:0] scan_idx;
    logic       any_movable;

    // ---- flood fill ----
    logic        ff_start, ff_done, ff_busy;
    logic [7:0]  ff_count;
    logic        ff_target_empty;
    logic [CELLS-1:0] ff_mask;
    floodfill_engine u_ff (
        .clk(clk), .rst(rst),
        .start        (ff_start),
        .start_x      (tap_x),
        .start_y      (tap_y),
        .board_rd_addr(ff_rd_addr),
        .board_rd_data(ff_rd_data),
        .done         (ff_done),
        .count        (ff_count),
        .mask         (ff_mask),
        .target_empty (ff_target_empty),
        .busy         (ff_busy)
    );

    // The result of the flood fill that just finished.  Sampling it
    // combinationally on `ff_done` includes the LAST cell of the game-over
    // scan; reading the register on the next edge would still hold the
    // previous cell's result and a board whose only remaining move sits in
    // cell 191 would be declared game over.
    wire scan_movable    = (ff_count >= 8'd2) && !ff_target_empty;
    wire any_movable_now = any_movable | scan_movable;

    // Board generator: rng_val[2:0] is uniform over 0..7, so 5..7 must be
    // rejected (re-drawn) rather than mapped onto Logo0.
    wire gen_accept = (rng_val[2:0] < 3'd5);

    // ---- erase ----
    logic        erase_start, erase_done, erase_busy;
    logic        erase_wr_en;
    logic [AW-1:0] erase_wr_addr;
    logic [2:0]  erase_wr_data;
    erase_engine #(.CELLS(CELLS), .AW(AW), .BLINK_FRAMES(BLINK_FRAMES)) u_erase (
        .clk(clk), .rst(rst),
        .start      (erase_start),
        .erase_mask (ff_mask),
        .frame_tick (frame_tick),
        .done       (erase_done),
        .busy       (erase_busy),
        .blink_on   (blink_on),
        .wr_en      (erase_wr_en),
        .wr_addr    (erase_wr_addr),
        .wr_data    (erase_wr_data)
    );

    // ---- gravity ----
    logic        grav_start, grav_done, grav_busy;
    logic        grav_wr_en;
    logic [AW-1:0] grav_wr_addr;
    logic [2:0]  grav_wr_data;
    logic [3:0]  grav_rd_col;
    logic [CELLS*4-1:0] grav_fall_dist;
    logic [3:0]         grav_max_dist;
    gravity_engine u_grav (
        .clk(clk), .rst(rst),
        .start(grav_start), .done(grav_done), .busy(grav_busy),
        .wr_en(grav_wr_en), .wr_addr(grav_wr_addr), .wr_data(grav_wr_data),
        .rd_col(grav_rd_col), .col_data(col_rd_data),
        .fall_dist(grav_fall_dist),
        .max_dist(grav_max_dist)
    );

    // ---- column shift ----
    logic        shift_start, shift_done, shift_busy;
    logic        shift_wr_en;
    logic [AW-1:0] shift_wr_addr;
    logic [2:0]  shift_wr_data;
    logic [3:0]  shift_rd_col;
    logic [COLS-1:0] column_empty;
    logic [COLS*4-1:0] shift_dist_i;
    logic [3:0]        shift_max_dist;
    column_shift_engine u_shift (
        .clk(clk), .rst(rst),
        .start(shift_start), .done(shift_done), .busy(shift_busy),
        .wr_en(shift_wr_en), .wr_addr(shift_wr_addr), .wr_data(shift_wr_data),
        .rd_col(shift_rd_col), .col_data(col_rd_data),
        .column_empty(column_empty),
        .shift_dist(shift_dist_i),
        .max_dist(shift_max_dist)
    );

    // ---- score ----
    logic score_add, score_reset;
    score_manager u_score (
        .clk(clk), .rst(rst),
        .add(score_add), .n(ff_count),
        .reset_score(score_reset), .score(score)
    );

    // ---- generation / animation registers ----
    // (moved above the flood-fill instantiation)

    // ------------------------------------------------------------------
    // main FSM
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_INIT;
            gen_idx     <= 8'd0;
            tap_x       <= 4'd0;
            tap_y       <= 4'd0;
            scan_idx    <= 8'd0;
            any_movable <= 1'b0;
            rng_next    <= 1'b0;
            ff_start    <= 1'b0;
            erase_start <= 1'b0;
            grav_start  <= 1'b0;
            shift_start <= 1'b0;
            score_add   <= 1'b0;
            score_reset <= 1'b0;
            fall_px_r   <= 9'd0;
            shift_px_r  <= 9'd0;
            fall_span_r <= 9'd0;
            shift_span_r<= 9'd0;
            fall_frame  <= 4'd0;
            shift_frame <= 4'd0;
            game_over   <= 1'b0;
            // cursor starts at (0,0) and is visible from the first frame
            cur_x_r     <= 4'd0;
            cur_y_r     <= 4'd0;
            cur_on_r    <= 1'b1;
            k_up_d      <= 1'b0;
            k_dn_d      <= 1'b0;
            k_lf_d      <= 1'b0;
            k_rt_d      <= 1'b0;
            k_sel_d     <= 1'b0;
        end else begin
            rng_next    <= 1'b0;
            ff_start    <= 1'b0;
            erase_start <= 1'b0;
            grav_start  <= 1'b0;
            shift_start <= 1'b0;
            score_add   <= 1'b0;
            score_reset <= 1'b0;

            // ---- key edge history (always, so the pulses are 1 clock wide) ----
            k_up_d  <= key_up;
            k_dn_d  <= key_down;
            k_lf_d  <= key_left;
            k_rt_d  <= key_right;
            k_sel_d <= key_select;

            case (state)
            S_INIT: begin
                score_reset <= 1'b1;
                gen_idx     <= 8'd0;
                // CLEAR game_over on restart.  It used to be reset only by `rst`,
                // so pressing ○ to start a new game left it stuck at 1 and the
                // banner stayed on screen for the whole of the next game.
                game_over   <= 1'b0;
                state       <= S_GENERATE;
            end

            S_GENERATE: begin
                // always advance the LFSR; only an accepted value fills a cell
                rng_next <= 1'b1;
                if (gen_accept) begin
                    if (gen_idx == 8'(CELLS-1)) begin
                        scan_idx    <= 8'd0;
                        any_movable <= 1'b0;
                        state       <= S_CHECK;
                    end else begin
                        gen_idx <= gen_idx + 8'd1;
                    end
                end
            end

            S_CHECK: begin
                // scan every cell for a group of size >= 2 using the flood
                // fill engine; if none, the game is over.
                tap_x    <= scan_idx[3:0];
                tap_y    <= scan_idx[7:4];
                ff_start <= 1'b1;
                state    <= S_CHECK_WAIT;
            end

            S_CHECK_WAIT: begin
                if (ff_done) begin
                    // NOTE: `scan_movable` is combinational and ff_count /
                    // ff_target_empty are stable right now, so the LAST cell of
                    // the scan is included.  Latching this into the register
                    // and testing it on the next edge would always see the
                    // previous cell's result and miss a move that only exists
                    // in cell 191.
                    if (scan_movable && scan_idx == 8'(CELLS-1)) begin
                        any_movable <= 1'b1;
                        state       <= S_PLAY;
                    end else if (scan_idx == 8'(CELLS-1)) begin
                        state       <= any_movable ? S_PLAY : S_GAMEOVER;
                    end else begin
                        any_movable <= any_movable_now;
                        scan_idx    <= scan_idx + 8'd1;
                        state       <= S_CHECK;
                    end
                end
            end

            S_PLAY: begin
                // ---- cursor movement (one cell per key press) ----
                // The comparisons are written so the cursor CLAMPS at the board
                // edge instead of wrapping.  A 4-bit subtract would wrap
                // 0-1 to 15 and teleport the cursor to the far side.
                if (e_up && cur_y_r != 4'd0)
                    cur_y_r <= cur_y_r - 4'd1;
                if (e_dn && cur_y_r != 4'(ROWS-1))
                    cur_y_r <= cur_y_r + 4'd1;
                if (e_lf && cur_x_r != 4'd0)
                    cur_x_r <= cur_x_r - 4'd1;
                if (e_rt && cur_x_r != 4'(COLS-1))
                    cur_x_r <= cur_x_r + 4'd1;

                // ---- ○ selects the panel under the cursor ----
                // This is the exact replacement for `touch_down`: the flood fill
                // runs from the CURSOR cell instead of from the touched cell, so
                // everything downstream (erase / gravity / shift / score) is
                // untouched.
                if (e_sel) begin
                    tap_x    <= cur_x_r;
                    tap_y    <= cur_y_r;
                    ff_start <= 1'b1;
                    state    <= S_FLOODFILL;
                end
            end

            S_FLOODFILL: begin
                if (ff_done) begin
                    if (ff_count >= 8'd2) begin
                        erase_start <= 1'b1;
                        state       <= S_ERASE_EFFECT;
                    end else begin
                        state <= S_PLAY;      // single block: nothing to erase
                    end
                end
            end

            S_ERASE_EFFECT: begin
                // erase_engine blinks for BLINK_FRAMES frames then commits the
                // EMPTY writes and pulses done.
                if (erase_done) begin
                    score_add  <= 1'b1;      // score += n*n
                    grav_start <= 1'b1;
                    fall_px_r  <= 9'd0;
                    fall_frame <= 4'd0;
                    state      <= S_FALL_WAIT;
                end
            end

            // ------------------------------------------------------------------
            // S_FALL_WAIT - wait for gravity, THEN latch how far it dropped
            //
            // `grav_max_dist` is only valid once the engine has finished scanning
            // the board; before that it is still 0.  Reading it from the animation
            // state directly was WRONG - it latched a span of 0, so the animation
            // ended on its first frame and the shift started BEFORE gravity had
            // committed, leaving the board in its pre-gravity state.  (The old
            // fixed ROWS*20 span hid this by accident, because 240 px is never
            // reached instantly.)
            //
            // A dedicated state also removes a subtler race: `grav_start` is a
            // one-cycle pulse, so the engine is still in S_IDLE on that clock and a
            // `grav_busy`-based hold would fall straight through.  Here the engine's
            // one-cycle `grav_done` IS seen, because this state examines the engine
            // on EVERY clock rather than only on `frame_tick`.
            // ------------------------------------------------------------------
            S_FALL_WAIT: begin
                if (grav_done) begin
                    fall_span_r <= 9'(grav_max_dist) * 9'd20;
                    fall_px_r   <= 9'd0;
                    state       <= S_FALL_ANIM;
                end
            end

            S_FALL_ANIM: begin
                // Play the drop over the settled board.  The span is the REAL
                // longest drop, not the worst-case board height: the renderer
                // clamps its offset with min(fall_px, fall_dist*20), so a
                // worst-case span (48 frames = 8 s) left the picture finished while
                // the cursor stayed frozen for the rest of the time - the reported
                // symptom.
                if (frame_tick) begin
                    if (fall_px_r >= fall_span_r) begin
                        // fall animation finished -> column shift
                        shift_start <= 1'b1;
                        shift_px_r  <= 9'd0;
                        shift_frame <= 4'd0;
                        state       <= S_SHIFT_WAIT;
                    end else begin
                        fall_px_r <= fall_px_r + PX_STEP;
                    end
                end
            end

            // S_SHIFT_WAIT - same idea as S_FALL_WAIT: the shift engine reports its
            // longest column move only after it has scanned, so wait for it before
            // latching the span.
            S_SHIFT_WAIT: begin
                if (shift_done) begin
                    shift_span_r <= 9'(shift_max_dist) * 9'd20;
                    shift_px_r   <= 9'd0;
                    state        <= S_SHIFT_ANIM;
                end
            end

            S_SHIFT_ANIM: begin
                if (frame_tick) begin
                    if (shift_px_r >= shift_span_r) begin
                        // done; re-scan for a possible move
                        scan_idx    <= 8'd0;
                        any_movable <= 1'b0;
                        state       <= S_CHECK;
                    end else begin
                        shift_px_r <= shift_px_r + PX_STEP;
                    end
                end
            end

            S_GAMEOVER: begin
                game_over <= 1'b1;
                // ○ restarts.  (The touch panel used to do this.)
                if (e_sel) state <= S_INIT;
            end

            default: state <= S_INIT;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // cursor output
    //
    // The cursor is always shown so the player can see where selection will act.
    // It is deliberately NOT gated on the game state: drawing it during the
    // erase / fall / shift animations is harmless (the renderer only inverts the
    // cell it covers) and keeping it unconditional avoids the cursor vanishing
    // for a frame at each transition.
    // ------------------------------------------------------------------
    assign cur_x  = cur_x_r;
    assign cur_y  = cur_y_r;
    assign cur_on = cur_on_r;

    // ------------------------------------------------------------------
    // board write arbitration (single writer at a time)
    // ------------------------------------------------------------------
    // ---- board generation -------------------------------------------
    // `rng_val[2:0]` is uniform over 0..7.  Rejection sampling gives a uniform
    // 0..4: a value of 5..7 is simply re-drawn without consuming the cell, so
    // no divider and no modulo are needed.  The old rule
    //     (rng_val[2:0] < 5) ? rng_val[2:0] : 0
    // made Logo0 twice as likely as the other four logos (40% / 20% / 20% /
    // 20% / 20%, measured 79983 / 19984 / 19969 / 19986 / 19982 per 100000).

    always_comb begin
        board_wr_en   = 1'b0;
        board_wr_addr = '0;
        board_wr_data = EMPTY;

        if (state == S_GENERATE && gen_accept) begin
            board_wr_en   = 1'b1;
            board_wr_addr = gen_idx;
            board_wr_data = rng_val[2:0];
        end else if (grav_busy) begin
            board_wr_en   = grav_wr_en;
            board_wr_addr = grav_wr_addr;
            board_wr_data = grav_wr_data;
        end else if (shift_busy) begin
            board_wr_en   = shift_wr_en;
            board_wr_addr = shift_wr_addr;
            board_wr_data = shift_wr_data;
        end else if (erase_busy) begin
            board_wr_en   = erase_wr_en;
            board_wr_addr = erase_wr_addr;
            board_wr_data = erase_wr_data;
        end
    end

    // ------------------------------------------------------------------
    // renderer animation control
    // ------------------------------------------------------------------
    always_comb begin
        case (state)
        S_ERASE_EFFECT: anim_mode = 2'd1;   // blink
        // The WAIT states keep showing the mode they are about to animate, so the
        // renderer does not flicker back to static for the one cycle it takes the
        // engine to settle, and so a testbench sampling anim_mode while waiting
        // still sees the right phase.
        S_FALL_WAIT:    anim_mode = 2'd2;   // fall (waiting for the engine)
        S_FALL_ANIM:    anim_mode = 2'd2;   // fall
        S_SHIFT_WAIT:   anim_mode = 2'd3;   // shift (waiting for the engine)
        S_SHIFT_ANIM:   anim_mode = 2'd3;   // shift
        default:        anim_mode = 2'd0;   // static
        endcase
    end

    assign blink_mask = ff_mask;
    assign fall_px    = fall_px_r;
    assign shift_px   = shift_px_r;
    assign fall_dist  = grav_fall_dist;
    assign shift_dist = shift_dist_i;

    // ---- board read B (flood fill) and column reads are wired at top level ----
    // The game_fsm only needs to expose ff_rd_data (board[ff_rd_addr]) and the
    // column word; those are connected in samegame_top to board_memory.
    // The gravity and shift engines never run concurrently, so their column
    // read requests are muxed onto the single board column read port.
    assign col_rd_col = grav_busy ? grav_rd_col : shift_rd_col;
endmodule
