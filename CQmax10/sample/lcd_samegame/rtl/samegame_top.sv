// samegame_top.sv
//
// Top level of the "さめがめ" FPGA game.  Wires the LCD/TFT controller, the
// PS2 pad reader, the game logic, the board memory, the logo ROM and the
// renderer together.
//
// INPUT DEVICE: Pmod-2xDS2 (Sipeed) - a PLAYSTATION 2 controller port.
// ---------------------------------------------------------------------------
// The touch panel was ABANDONED.  MEASURED on the board, the XPT2046 never
// drove MISO on any socket that could be probed (every conversion returned
// 12'hFFF and the pad never went low in a whole 24-clock transfer), so no press
// could ever be detected.  Pmod-2xDS2 replaces it:
//     up / down / left / right  -> move the cursor
//     ○ (circle)                -> select the panel under the cursor
// See ps2_controller.sv for the protocol.
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
//   led         PIN_85
//   led0..led3  PIN_122,123,120,121
//
// Pmod-2xDS2 (PS2 pad) pins are in the .qsf; see ps2_controller.sv.
//
// NOTE the PMOD-TFTLCD's LCD connector (81/78/75/77) is verified working and
// must not be disturbed by the input device change.
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

    // ---- Pmod-2xDS2 (PS2 pad) ----
    // NOTE ps_cmd/ps_clk/ps_sel are driven BY this design (it is the bus
    // master); only ps_dat comes back from the pad.
    output logic ps_sel,
    output logic ps_clk,
    output logic ps_cmd,
    input  logic ps_dat,

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
    //  pix_color_raw = renderer output.  Kept as a separate name so a bring-up
    //  overlay can be re-inserted here later without touching the renderer or the
    //  LCD controller (see the note where the two are joined).
    logic [15:0] pix_color_raw;
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

    // ---- input device: Pmod-2xDS2 (PS2 pad) ----
    //
    // Replaces the touch panel, which is gone (the XPT2046 never drove MISO on
    // the board).  The decoded buttons are ACTIVE HIGH levels here; game_fsm
    // edge-detects them so one press = one cursor step.
    logic pad_up, pad_down, pad_left, pad_right, pad_circle, pad_cross;
    logic pad_ok;
    logic [7:0] pad_rx0, pad_rx1, pad_rx2, pad_rx3, pad_rx4;
    logic       pad_dat_low;
    logic [3:0] pad_polls;
    logic       pad_loopback;
    logic       pad_dat_high_idle;
    logic       pad_dat_high_act;
    logic [2:0] pad_sig_idx;
    logic [3:0] pad_sig_hits;

    ps2_controller #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ)
    ) u_pad (
        .clk(clk), .rst(rst),
        .ps_sel(ps_sel), .ps_clk(ps_clk), .ps_cmd(ps_cmd), .ps_dat(ps_dat),
        .up(pad_up), .down(pad_down), .left(pad_left), .right(pad_right),
        .circle(pad_circle), .btn_cross(pad_cross),
        .pad_ok(pad_ok),
        .dbg_rx0(pad_rx0), .dbg_rx1(pad_rx1),
        .dbg_rx2(pad_rx2), .dbg_rx3(pad_rx3), .dbg_rx4(pad_rx4),
        .dbg_dat_low(pad_dat_low), .dbg_polls(pad_polls),
        .dbg_dat_high_idle(pad_dat_high_idle),
        .dbg_dat_high_act(pad_dat_high_act),
        .dbg_sig_idx(pad_sig_idx),
        .dbg_sig_hits(pad_sig_hits),
        .dbg_loopback(pad_loopback)
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

    // ---- logo store : UFM (On-Chip Flash) -> bootloader -> writable M9K RAM ----
    logic [RA_W-1:0] rom_addr;
    logic [15:0] rom_data;

    // logo_ram write port (driven by bootloader)
    logic           ram_wr_en;
    logic [RA_W-1:0] ram_wr_addr;
    logic [15:0]    ram_wr_data;

    // Boot results (driven by the bootloader below).
    logic        boot_done;
    logic        boot_fail;
    logic        boot_blank;
    logic        boot_beat;
    logic [1:0]  boot_pix;

    logo_ram #(.ROM_DEPTH(2000), .MEM_DEPTH(2048), .AW(RA_W), .DW(16)) u_ram (
        .clk(clk),
        .rd_addr(rom_addr), .rd_data(rom_data),
        .wr_en(ram_wr_en), .wr_addr(ram_wr_addr), .wr_data(ram_wr_data)
    );

    // An ERASED UFM reads back as all ones, so every logo pixel would become
    // RGB565 16'hFFFF and the whole panel would turn SOLID WHITE - while
    // boot_done is high and boot_fail is low, i.e. with every LED looking
    // healthy.  Force black instead: a black panel plus led3 lit is a failure
    // nobody can mistake for "working".
    //
    // NOTE the mux is on the READ path only, so the real content is still what
    // the bootloader copied (boot_blank just decides whether to SHOW it).
    logic [15:0] rom_data_eff;
    assign rom_data_eff = boot_blank ? 16'h0000 : rom_data;

    // UFM Avalon-MM data slave signals (master side)
    logic        flash_read;
    logic [12:0] flash_addr;
    logic        flash_waitrequest;
    logic        flash_readdatavalid;
    logic [31:0] flash_readdata;

    ufm_bootloader #(
        .PIXELS(2000), .RAM_AW(RA_W), .RAM_DW(16),
        .WATCH_CYCLES(6000), .MAX_RETRIES(2)
    ) u_boot (
        .clk(clk), .rst(rst),
        .flash_read(flash_read), .flash_addr(flash_addr),
        .flash_waitrequest(flash_waitrequest),
        .flash_readdatavalid(flash_readdatavalid),
        .flash_readdata(flash_readdata),
        .ram_wr_en(ram_wr_en), .ram_wr_addr(ram_wr_addr), .ram_wr_data(ram_wr_data),
        .boot_done(boot_done), .boot_fail(boot_fail), .boot_blank(boot_blank),
        .boot_beat(boot_beat), .boot_pix(boot_pix)
    );

    logo_flash u_ufm (
        .ufm_clock_clk          (clk),
        .ufm_reset_reset_n      (~rst),
        .ufm_data_address       (flash_addr),
        .ufm_data_read          (flash_read),
        .ufm_data_writedata     (32'd0),
        .ufm_data_write         (1'b0),
        .ufm_data_readdata      (flash_readdata),
        .ufm_data_waitrequest   (flash_waitrequest),
        .ufm_data_readdatavalid (flash_readdatavalid),
        .ufm_data_burstcount    (4'd1),
        .ufm_csr_address        (1'b0),
        .ufm_csr_read           (1'b0),
        .ufm_csr_writedata      (32'd0),
        .ufm_csr_write          (1'b0),
        .ufm_csr_readdata       ()
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

    // Hold the game logic in reset until the logos are resident in RAM, so the
    // renderer never scans uninitialised logo memory.
    logic game_rst;
    assign game_rst = rst | ~boot_done;

    logic [3:0] cursor_x, cursor_y;
    logic       cursor_on;

    game_fsm #(.COLS(COLS), .ROWS(ROWS), .CELLS(CELLS), .AW(AW)) u_game (
        .clk(clk), .rst(game_rst),
        .frame_tick(frame_tick),
        // Pmod-2xDS2: direction keys move the cursor, ○ selects
        .key_up(pad_up), .key_down(pad_down),
        .key_left(pad_left), .key_right(pad_right),
        .key_select(pad_circle),
        .cur_x(cursor_x), .cur_y(cursor_y), .cur_on(cursor_on),
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
        .pix_color(pix_color_raw), .pix_valid(pix_valid),
        .board_rd_addr(rd_addr_a), .board_rd_data(rd_data_a),
        .rom_addr(rom_addr), .rom_data(rom_data_eff),
        .anim_mode(anim_mode), .blink_mask(blink_mask), .blink_on(blink_on),
        .fall_px(fall_px), .fall_dist(fall_dist),
        .shift_px(shift_px), .shift_dist(shift_dist),
        // cursor overlay: that cell is drawn inverted
        .cur_on(cursor_on), .cur_x(cursor_x), .cur_y(cursor_y),
        // game-over banner: a red band over the top of the board, cleared as soon
        // as ○ starts a new game (game_fsm lowers it in S_INIT)
        .game_over(game_over)
    );

    // ---- renderer -> LCD ----
    //
    // A bring-up ON-SCREEN SCOPE used to sit between these two (`ps2_scope.sv`):
    // it painted the raw PS2 reply bytes and a per-half-period logic capture of
    // ps_dat/ps_clk/ps_cmd over this corner of the panel.  It earned its place -
    // the trace is what exposed the extra clock pulse that was slipping every
    // reply byte by one bit - but the pad decodes correctly now, so it has been
    // removed and the renderer drives the panel directly again.
    //
    // `pix_color_raw` is kept as a distinct name so an overlay can be dropped back
    // in here without touching the renderer or the LCD controller.
    assign pix_color = pix_color_raw;

    // The board clears itself after reset (board_memory does this on reset),
    // so board_clr_start can stay deasserted here.  The game FSM generates a
    // fresh board immediately after reset.
    assign board_clr_start = 1'b0;

    // ---- LEDs (active low) ----
    //
    // Every LED is ACTIVE LOW, so LIT = the signal is 1.  (Getting this
    // backwards once produced a completely wrong diagnosis, so read the
    // polarity first, always.)
    //
    // ------------------------------------------------------------------ #
    // THE LEDs SHOW *HOW MANY TIMES THE SIGNATURE WAS RECEIVED* - static code
    //
    // MEASURED, step by step, on the board:
    //     dat_high_idle = 1   the line rises HIGH while idle -> pull-up works
    //     dat_high_act  = 1   it rises HIGH during a poll     -> pad releases it
    //     dat_low       = 1   it also goes LOW during a poll  -> pad drives zeros
    //   and yet 0x5A was found in NONE of the five reply bytes.
    //
    // 0x5A is BIT-SYMMETRIC (01011010 reversed is still 01011010), so a wrong bit
    // ORDER cannot explain that.  What CAN explain it on an open-drain bus is
    // MARGIN: the pad pulls the line low quickly but it only returns high through
    // the weak pull-up and the ribbon's capacitance, so an alternating pattern
    // like 0x5A is the first thing to be corrupted when the bit clock is too
    // fast for the rise time.
    //
    // That failure mode is INTERMITTENT, and the previous readout could not show
    // it: the signature index came from the LATEST poll only, so one bad poll hid
    // every earlier success.  This display fixes that by showing a COUNT.
    //
    //   led0..led3 = a 4-bit binary number, led0 the LSB, led3 the MSB.
    //                LIT = 1 (all LEDs are ACTIVE LOW).
    //                The number is how many polls have contained 0x5A, saturated
    //                at 15.
    //
    // HOW TO READ IT - and this one number decides the remaining work:
    //
    //   0  (all four DARK)  -> the signature has NEVER been received.  The bytes
    //                          genuinely never contain 0x5A, so the framing or the
    //                          bit order is wrong. The slower clock did not help.
    //   1..14               -> the signature IS being received, just not every
    //                          poll.  THE FRAMING IS CORRECT and only the MARGIN
    //                          is short; lowering the bit clock further will fix
    //                          it.  ANY non-zero value other than 15 means this.
    //   15 (all four LIT)   -> every poll succeeded (the count saturated). The
    //                          decode is fully working; ignore the other LEDs.
    //
    // NOTE 0 and 15 are the all-dark and all-lit extremes and both are
    // unmistakable, which is why the count is shown saturated at 15 rather than
    // scaled.
    //
    // These are BRING-UP leds.  Once the pad works they reduce to
    // `led = ~pad_ok` and led0..3 are freed or repurposed to the score.
    // ------------------------------------------------------------------ #
    logic boot_bad;
    assign boot_bad = boot_fail | boot_blank;
    wire   boot_ok  = boot_done & ~boot_bad;

    // `boot_beat` (bootloader alive) and `boot_pix` (a sample of what the flash
    // actually returned) are intentionally NOT routed to an LED: there are only
    // five pins and every one of them already carries a signal that matters
    // more.  They are kept so a SignalTap probe can read the raw flash content
    // if a future bring-up needs it.
    logic unused_boot_beat;
    logic [1:0] unused_boot_pix;
    assign unused_boot_beat = boot_beat;
    assign unused_boot_pix  = boot_pix;
    // boot_ok stays referenced so it is not swept away and remains probe-able.
    logic unused_boot_ok;
    assign unused_boot_ok = boot_ok;

    // Keep everything a SignalTap probe might want alive so it is not optimised
    // away: the raw reply bytes, the signature index, the DAT-level flags (which
    // already ruled OUT wiring, power and the pull-up) and the button signals.
    logic unused_pad;
    assign unused_pad = pad_cross ^ pad_left ^ pad_right ^ pad_circle
                      ^ pad_down ^ pad_up ^ pad_rx0 ^ pad_rx1 ^ pad_rx2
                      ^ pad_rx3 ^ pad_rx4;
    logic unused_diag;
    assign unused_diag = (|pad_polls) | pad_loopback | pad_dat_low
                       | pad_dat_high_idle | pad_dat_high_act
                       ^ pad_sig_idx[0] ^ pad_sig_idx[1];

    // ------------------------------------------------------------------
    // LEDs  (all ACTIVE LOW, so LIT = the signal is 1)
    // ------------------------------------------------------------------
    // The bring-up build spent these five pins on the PS2 diagnostics (pad_ok and
    // the signature-hit count).  The pad decodes correctly now, so they go back to
    // showing the SCORE, which is what the specification asks for.
    //
    // The 16-bit score is shown as its low four bits plus a "non-zero" lamp:
    //   led  = the score is not zero
    //   led0 = score bit 0   (LSB)
    //   led1 = score bit 1
    //   led2 = score bit 2
    //   led3 = score bit 3
    assign led  = ~(|score);
    assign led0 = ~score[0];
    assign led1 = ~score[1];
    assign led2 = ~score[2];
    assign led3 = ~score[3];
endmodule
