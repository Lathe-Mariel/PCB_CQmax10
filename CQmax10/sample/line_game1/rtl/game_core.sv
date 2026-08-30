// game_core.sv
// "1-key line game": a 1px line grows from (0,0) toward the bottom-right.
// While Button A is held, the line's Y direction flips to upward; released,
// it goes downward. The line bounces off the left/right field edges.
// Game over when the line touches Y=0/Y=FIELD_H edges from the inside, or
// crosses a pixel it has already drawn. After game over: wait ~2s, then
// wait for a fresh button press to restart.
//
// Talks to lcd_ili9341_ctrl over the req_valid/req_ready FILL_RECT command
// interface (a 1x1 FILL_RECT is used as the "draw pixel" primitive).
import font5x7_pkg::*;

module game_core #(
    parameter int FIELD_W          = 320,
    parameter int FIELD_H          = 200,
    parameter int SCREEN_W         = 320,
    parameter int SCREEN_H         = 240,
    parameter int CLK_FREQ_HZ      = 50_000_000,
    parameter int STEP_MS          = 20,     // game speed: ms per pixel step
    parameter int GAMEOVER_WAIT_MS = 2000
)(
    input  logic clk,
    input  logic rst,
    input  logic btn_level,      // debounced, 1 = pressed

    output logic        req_valid,
    input  logic        req_ready,
    output logic [1:0]  req_cmd,
    output logic [8:0]  req_x,
    output logic [7:0]  req_y,
    output logic [8:0]  req_w,
    output logic [8:0]  req_h,
    output logic [15:0] req_color
);
    localparam logic [1:0] CMD_INIT = 2'b01;
    localparam logic [1:0] CMD_FILL = 2'b10;

    localparam logic [15:0] COLOR_BG     = 16'h0000; // black
    localparam logic [15:0] COLOR_LINE   = 16'hFFFF; // white
    localparam logic [15:0] COLOR_DIV    = 16'h39E7; // dim grey divider
    localparam logic [15:0] COLOR_DIGIT  = 16'h07E0; // green score digits

    // score readout geometry (in the 320x40 info area, y = FIELD_H..SCREEN_H-1)
    localparam int DIGITS      = 5;
    localparam int CELL_PX     = 3;   // each font pixel drawn as CELL_PX x CELL_PX
    localparam int GLYPH_W     = 5 * CELL_PX;
    localparam int GLYPH_H     = 7 * CELL_PX;
    localparam int DIGIT_PITCH = GLYPH_W + 4;
    localparam int SCORE_X0    = 8;
    localparam int SCORE_Y0    = FIELD_H + 8;

    localparam int STEP_CYCLES     = (CLK_FREQ_HZ / 1000) * STEP_MS;
    localparam int GAMEOVER_CYCLES = (CLK_FREQ_HZ / 1000) * GAMEOVER_WAIT_MS;

    // -----------------------------------------------------------------
    // Collision bitmap: 1 bit per field pixel, inferred as on-chip RAM.
    // FIELD_W*FIELD_H = 320*200 = 64000 bits.
    // -----------------------------------------------------------------
    localparam int MEM_DEPTH = FIELD_W * FIELD_H;
    localparam int ADDR_W    = $clog2(MEM_DEPTH);

    logic collision_mem [0:MEM_DEPTH-1];
    logic [ADDR_W-1:0] mem_addr;
    logic               mem_we;
    logic               mem_wdata;
    logic               mem_rdata;
    logic [ADDR_W-1:0] clr_cnt;

    always_ff @(posedge clk) begin
        if (mem_we)
            collision_mem[mem_addr] <= mem_wdata;
        mem_rdata <= collision_mem[mem_addr]; // synchronous (registered) read
    end

    // -----------------------------------------------------------------
    // game state
    // -----------------------------------------------------------------
    typedef enum logic [4:0] {
        S_LCD_INIT, S_LCD_INIT_WAIT,
        S_MEM_CLEAR,
        S_FIELD_CLEAR, S_FIELD_CLEAR_WAIT,
        S_DIV_LINE, S_DIV_LINE_WAIT,
        S_INFO_CLEAR, S_INFO_CLEAR_WAIT,
        S_ORIGIN_ADDR, S_ORIGIN_MARK, S_ORIGIN_DRAW, S_ORIGIN_DRAW_WAIT,
        S_RUN_WAIT_TICK,
        S_RUN_COMPUTE,
        S_RUN_COLL_ADDR, S_RUN_COLL_READ,
        S_RUN_DRAW, S_RUN_DRAW_WAIT,
        S_RUN_COMMIT,
        S_SCORE_BCD, S_SCORE_BCD_ITER,
        S_SCORE_CELL_NEXT, S_SCORE_CELL_DRAW, S_SCORE_CELL_WAIT,
        S_GAMEOVER_DELAY,
        S_GAMEOVER_WAIT_RELEASE,
        S_GAMEOVER_WAIT_PRESS
    } state_t;

    state_t state;

    // position / direction
    logic [8:0]        pos_x;
    logic [7:0]        pos_y;
    logic signed [1:0] dir_x;      // +1 / -1
    logic signed [1:0] ndx, ndy;
    logic signed [10:0] next_x_s;
    logic signed [10:0] next_y_s;
    logic [8:0]         next_x;
    logic [7:0]         next_y;
    logic                y_out_of_range;

    // score
    logic [16:0] score;
    logic [16:0] score_shown;

    // timers
    logic [31:0] tick_cnt;
    logic [31:0] go_cnt;

    // button edge tracking for restart
    logic btn_prev;

    // BCD conversion (double-dabble)
    logic [36:0] dd_sr;   // {20-bit BCD, 17-bit remaining binary}
    logic [4:0]  dd_iter;
    logic [3:0]  digit [0:DIGITS-1];

    // score cell scan (digit index, glyph row, glyph col)
    logic [2:0] cell_digit;
    logic [2:0] cell_row;
    logic [2:0] cell_col;

    // -----------------------------------------------------------------
    // combinational: X bounce, Y direction from button, collision addr
    // -----------------------------------------------------------------
    always_comb begin
        ndx = dir_x;
        if (pos_x == FIELD_W - 1 && dir_x == 2'sd1)
            ndx = -2'sd1;
        else if (pos_x == 0 && dir_x == -2'sd1)
            ndx = 2'sd1;

        ndy = btn_level ? -2'sd1 : 2'sd1;

        next_x_s = $signed({2'b00, pos_x}) + ndx;
        next_y_s = $signed({3'b000, pos_y}) + ndy;

        next_x = next_x_s[8:0];
        next_y = next_y_s[7:0];

        y_out_of_range = (next_y_s < 0) || (next_y_s > $signed(FIELD_H - 1));
    end

    // address = y*FIELD_W + x  (FIELD_W = 320 = 256+64, i.e. shift-add)
    function automatic logic [ADDR_W-1:0] field_addr(input logic [8:0] x, input logic [7:0] y);
        field_addr = (ADDR_W)'((y << 8) + (y << 6) + x);
    endfunction

    // -----------------------------------------------------------------
    // main FSM
    // -----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_LCD_INIT;
            req_valid   <= 1'b0;
            req_cmd     <= CMD_INIT;
            mem_we      <= 1'b0;
            score       <= '0;
            score_shown <= {17{1'b1}}; // force first refresh to redraw
            dir_x       <= 2'sd1;
            pos_x       <= '0;
            pos_y       <= '0;
            digit[0]    <= 4'd0; digit[1] <= 4'd0; digit[2] <= 4'd0;
            digit[3]    <= 4'd0; digit[4] <= 4'd0;
            btn_prev    <= 1'b0;
            clr_cnt     <= '0;
        end else begin
            mem_we    <= 1'b0;
            req_valid <= req_valid && !req_ready; // clear once accepted

            case (state)
            // -------- power-up: init panel, clear collision RAM & screen ----
            S_LCD_INIT: begin
                req_cmd   <= CMD_INIT;
                req_valid <= 1'b1;
                state     <= S_LCD_INIT_WAIT;
            end
            S_LCD_INIT_WAIT: if (!req_valid && req_ready) state <= S_MEM_CLEAR;

            S_MEM_CLEAR: begin
                mem_we    <= 1'b1;
                mem_wdata <= 1'b0;
                mem_addr  <= clr_cnt;
                if (clr_cnt == ADDR_W'(MEM_DEPTH - 1)) begin
                    clr_cnt <= '0;
                    state   <= S_FIELD_CLEAR;
                end else begin
                    clr_cnt <= clr_cnt + 1'b1;
                end
            end

            S_FIELD_CLEAR: begin
                req_cmd   <= CMD_FILL;
                req_x     <= 9'd0;  req_y <= 8'd0;
                req_w     <= FIELD_W[8:0]; req_h <= SCREEN_H[8:0];
                req_color <= COLOR_BG;
                req_valid <= 1'b1;
                state     <= S_FIELD_CLEAR_WAIT;
            end
            S_FIELD_CLEAR_WAIT: if (!req_valid && req_ready) state <= S_DIV_LINE;

            S_DIV_LINE: begin
                req_cmd   <= CMD_FILL;
                req_x     <= 9'd0;  req_y <= FIELD_H[7:0];
                req_w     <= FIELD_W[8:0]; req_h <= 9'd1;
                req_color <= COLOR_DIV;
                req_valid <= 1'b1;
                state     <= S_DIV_LINE_WAIT;
            end
            S_DIV_LINE_WAIT: if (!req_valid && req_ready) state <= S_ORIGIN_ADDR;

            // -------- draw the origin pixel (0,0) and start the run ---------
            S_ORIGIN_ADDR: begin
                pos_x <= 9'd0; pos_y <= 8'd0; dir_x <= 2'sd1; score <= 17'd1;
                mem_addr <= field_addr(9'd0, 8'd0);
                state <= S_ORIGIN_MARK;
            end
            S_ORIGIN_MARK: begin
                mem_we   <= 1'b1;
                mem_wdata<= 1'b1;
                state    <= S_ORIGIN_DRAW;
            end
            S_ORIGIN_DRAW: begin
                req_cmd   <= CMD_FILL;
                req_x     <= 9'd0; req_y <= 8'd0;
                req_w     <= 9'd1; req_h <= 9'd1;
                req_color <= COLOR_LINE;
                req_valid <= 1'b1;
                state     <= S_ORIGIN_DRAW_WAIT;
            end
            S_ORIGIN_DRAW_WAIT: if (!req_valid && req_ready) begin
                tick_cnt <= '0;
                state    <= S_RUN_WAIT_TICK;
            end

            // -------------------------- main run loop ------------------------
            S_RUN_WAIT_TICK: begin
                if (tick_cnt == STEP_CYCLES - 1) begin
                    tick_cnt <= '0;
                    state    <= S_RUN_COMPUTE;
                end else begin
                    tick_cnt <= tick_cnt + 1'b1;
                end
            end

            S_RUN_COMPUTE: begin
                if (y_out_of_range) begin
                    go_cnt <= '0;
                    state  <= S_GAMEOVER_DELAY;
                end else begin
                    mem_addr <= field_addr(next_x, next_y);
                    state    <= S_RUN_COLL_ADDR;
                end
            end
            S_RUN_COLL_ADDR: state <= S_RUN_COLL_READ; // 1 cycle for sync-read latency
            S_RUN_COLL_READ: begin
                if (mem_rdata) begin
                    go_cnt <= '0;
                    state  <= S_GAMEOVER_DELAY;
                end else begin
                    state <= S_RUN_DRAW;
                end
            end

            S_RUN_DRAW: begin
                req_cmd   <= CMD_FILL;
                req_x     <= next_x; req_y <= next_y;
                req_w     <= 9'd1;   req_h <= 9'd1;
                req_color <= COLOR_LINE;
                req_valid <= 1'b1;
                state     <= S_RUN_DRAW_WAIT;
            end
            S_RUN_DRAW_WAIT: if (!req_valid && req_ready) state <= S_RUN_COMMIT;

            S_RUN_COMMIT: begin
                mem_we    <= 1'b1;
                mem_wdata <= 1'b1;
                pos_x     <= next_x;
                pos_y     <= next_y;
                dir_x     <= ndx;
                score     <= score + 17'd1;
                state     <= S_SCORE_BCD;
            end

            // -------- score -> BCD (double-dabble, DIGITS*4=20 bit result) --
            S_SCORE_BCD: begin
                dd_sr   <= {20'd0, score};
                dd_iter <= '0;
                state   <= S_SCORE_BCD_ITER;
            end
            S_SCORE_BCD_ITER: begin
                logic [19:0] bcd_part, bcd_adj;
                bcd_part = dd_sr[36:17];
                bcd_adj[3:0]   = (bcd_part[3:0]   >= 5) ? bcd_part[3:0]   + 4'd3 : bcd_part[3:0];
                bcd_adj[7:4]   = (bcd_part[7:4]   >= 5) ? bcd_part[7:4]   + 4'd3 : bcd_part[7:4];
                bcd_adj[11:8]  = (bcd_part[11:8]  >= 5) ? bcd_part[11:8]  + 4'd3 : bcd_part[11:8];
                bcd_adj[15:12] = (bcd_part[15:12] >= 5) ? bcd_part[15:12] + 4'd3 : bcd_part[15:12];
                bcd_adj[19:16] = (bcd_part[19:16] >= 5) ? bcd_part[19:16] + 4'd3 : bcd_part[19:16];
                dd_sr <= {bcd_adj, dd_sr[16:0]} << 1;
                if (dd_iter == 5'd16) begin
                    digit[4] <= bcd_adj[19:16]; digit[3] <= bcd_adj[15:12];
                    digit[2] <= bcd_adj[11:8];  digit[1] <= bcd_adj[7:4];
                    digit[0] <= bcd_adj[3:0];
                    cell_digit <= '0; cell_row <= '0; cell_col <= '0;
                    state <= (score != score_shown) ? S_SCORE_CELL_DRAW : S_RUN_WAIT_TICK;
                    score_shown <= score;
                end else begin
                    dd_iter <= dd_iter + 5'd1;
                end
            end

            // -------- redraw every score digit cell (simple, always fresh) --
            S_SCORE_CELL_DRAW: begin
                logic [4:0] glyph_row;
                glyph_row = digit_row(digit[DIGITS-1-cell_digit], cell_row);
                req_cmd   <= CMD_FILL;
                req_x     <= (SCORE_X0 + cell_digit*DIGIT_PITCH + cell_col*CELL_PX);
                req_y     <= (SCORE_Y0 + cell_row*CELL_PX);
                req_w     <= CELL_PX[8:0];
                req_h     <= CELL_PX[8:0];
                req_color <= glyph_row[4-cell_col] ? COLOR_DIGIT : COLOR_BG;
                req_valid <= 1'b1;
                state     <= S_SCORE_CELL_WAIT;
            end
            S_SCORE_CELL_WAIT: if (!req_valid && req_ready) state <= S_SCORE_CELL_NEXT;
            S_SCORE_CELL_NEXT: begin
                if (cell_col == 3'd4) begin
                    cell_col <= '0;
                    if (cell_row == 3'd6) begin
                        cell_row <= '0;
                        if (cell_digit == DIGITS-1) begin
                            state <= S_RUN_WAIT_TICK;
                        end else begin
                            cell_digit <= cell_digit + 3'd1;
                            state <= S_SCORE_CELL_DRAW;
                        end
                    end else begin
                        cell_row <= cell_row + 3'd1;
                        state <= S_SCORE_CELL_DRAW;
                    end
                end else begin
                    cell_col <= cell_col + 3'd1;
                    state <= S_SCORE_CELL_DRAW;
                end
            end

            // -------------------------- game over ----------------------------
            S_GAMEOVER_DELAY: begin
                if (go_cnt == GAMEOVER_CYCLES - 1)
                    state <= S_GAMEOVER_WAIT_RELEASE;
                else
                    go_cnt <= go_cnt + 1'b1;
            end
            S_GAMEOVER_WAIT_RELEASE: if (!btn_level) state <= S_GAMEOVER_WAIT_PRESS;
            S_GAMEOVER_WAIT_PRESS: begin
                if (btn_level && !btn_prev) begin
                    score_shown <= {17{1'b1}};
                    state <= S_MEM_CLEAR;
                end
            end

            default: state <= S_LCD_INIT;
            endcase

            btn_prev <= btn_level;
        end
    end

endmodule