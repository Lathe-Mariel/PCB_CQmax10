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
//   touch_cs    PIN_134
//   touch_mosi  PIN_135
//   touch_miso  PIN_132
//   touch_sck   PIN_130
//   led         PIN_85
//   led0..led3  PIN_122,123,120,121
//
// On the PMOD-TFTLCD module the LCD and the touch controller are on TWO
// SEPARATE PMOD connectors, so these two groups must NOT be merged: the LCD is
// verified working on 81/78/75/77 and the touch controller is a self-contained
// 4-signal PMOD (CS, MOSI, MISO, CLK) on 134/135/132/130.  See
// touch_controller.sv for the derivation from the module schematic.
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
    input  logic touch_miso_alt,     // candidate MISO, socket J1 - see touch_controller
    input  logic touch_miso_fr,      // candidate MISO, third socket
    output logic touch_sck,
    // The two extra sockets receive copies of the touch traffic (see
    // touch_controller).  Only the socket the touch connector is really
    // plugged into will answer.
    output logic alt_cs,
    output logic alt_mosi,
    output logic alt_sck,
    output logic fr_cs,
    output logic fr_mosi,
    output logic fr_sck,

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
    logic [2:0] touch_dbg_z1;
    logic       touch_dbg_stuck;
    logic [2:0] touch_dbg_live;
    logic [1:0] touch_dbg_socket;
    logic [4:0] touch_dbg_low_idx;
    logic [4:0] touch_dbg_low_idx_alt;
    logic [4:0] touch_dbg_low_idx_fr;
    touch_controller #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .MS_SCALE(MS_SCALE)
    ) u_touch (
        .clk(clk), .rst(rst),
        .touch_cs(touch_cs), .touch_mosi(touch_mosi), .touch_miso(touch_miso), .touch_sck(touch_sck),
        .alt_cs(alt_cs), .alt_mosi(alt_mosi), .alt_miso(touch_miso_alt), .alt_sck(alt_sck),
        .fr_cs(fr_cs), .fr_mosi(fr_mosi), .fr_miso(touch_miso_fr), .fr_sck(fr_sck),
        .touch_valid(touch_valid), .touch_x(touch_x), .touch_y(touch_y),
        .touch_down(touch_down), .touch_up(touch_up),
        .dbg_z1(touch_dbg_z1), .dbg_stuck(touch_dbg_stuck),
        .dbg_live(touch_dbg_live),
        .dbg_low_idx(touch_dbg_low_idx),
        .dbg_low_idx_alt(touch_dbg_low_idx_alt),
        .dbg_low_idx_fr(touch_dbg_low_idx_fr),
        .dbg_socket(touch_dbg_socket)
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

    game_fsm #(.COLS(COLS), .ROWS(ROWS), .CELLS(CELLS), .AW(AW)) u_game (
        .clk(clk), .rst(game_rst),
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
        .rom_addr(rom_addr), .rom_data(rom_data_eff),
        .anim_mode(anim_mode), .blink_mask(blink_mask), .blink_on(blink_on),
        .fall_px(fall_px), .fall_dist(fall_dist),
        .shift_px(shift_px), .shift_dist(shift_dist)
    );

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
    //   led  (PIN_85)  : ~socket_live.  LIT = the touch chip was found and is
    //                     being read (any of J2/J4/J6 answered).
    //   led0 (PIN_122) : ~heartbeat, toggles once per completed frame (~6 Hz)
    //                    so it always BLINKS while frames are scanned.
    //   led1 (PIN_123) : ~dbg_socket[0]  |  together these two form a binary
    //   led2 (PIN_120) : ~dbg_socket[1]  |  SOCKET CODE (both ACTIVE LOW, so a
    //                    LIT LED is a 1 bit):
    //
    //                        led1 led2   socket the touch chip was found on
    //                        --------------------------------
    //                         lit  lit    3 = J6   (141/140/131/127)
    //                         lit dark    2 = J4   (101/100/105/106)
    //                        dark  lit    1 = J2   (60/58/56/50)
    //                        dark dark    0 = NONE found
    //
    //                     Read it as a binary number: led1 is the 2s bit, led2
    //                     the 1s bit.  "dark dark" (+ led3 lit) means the touch
    //                     connector is on none of the probed sockets.
    //   led3 (PIN_121) : ~touch_dbg_stuck.  LIT = 16 consecutive conversions all
    //                    returned 12'hFFF, i.e. NOTHING is answering.
    //
    // WHY THE PINS HAD TO BE FOUND THIS WAY:
    //   The module puts its LCD on one PMOD connector and its touch controller on
    //   a SECOND.  The touch port carries CS, MOSI, MISO and CLK on the module
    //   connector's pins 1..4, and the board exposes those on pins 7,8,9,10 of
    //   EVERY socket.  Which socket the touch connector lands on depends only on
    //   the module's mechanical layout - it cannot be derived from a netlist, and
    //   guessing it has already cost several builds.  So this build DRIVES the
    //   remaining candidates (J4 and J6; J2/J1/J3 were measured dead) with
    //   identical SPI traffic, watches all three MISO pins, and AUTO-SELECTS the
    //   one that answers - so if the chip is there, touch works in this build.
    //
    // NOTE the extra CS/MOSI/SCK outputs also drive sockets that are unused by
    // this project, so the duplicated traffic cannot disturb anything.
    wire socket_live   = (touch_dbg_socket != 2'd0);
    wire [1:0] sock    = touch_dbg_socket;
    // `boot_ok` stays referenced so it is not swept away and remains probe-able.
    logic boot_bad;
    assign boot_bad = boot_fail | boot_blank;
    wire   boot_ok  = boot_done & ~boot_bad;

    logic heartbeat;
    always_ff @(posedge clk) begin
        if (rst) heartbeat <= 1'b0;
        else if (lcd_frame_done) heartbeat <= ~heartbeat;
    end

    // `touch_valid`, `touch_down`, `touch_x` and `touch_y` are fully wired to
    // game_fsm (see the instantiation above) and need no LED: this build's LEDs
    // answer the ONE question still open - which socket the touch chip is on.

    // `boot_beat` (bootloader alive) and `boot_pix` (a sample of what the flash
    // actually returned) are intentionally NOT routed to an LED: there are only
    // five pins and every one of them already carries a signal that matters
    // more.  They are kept so a SignalTap probe can read the raw flash content
    // if a future bring-up needs it.
    logic unused_boot_beat;
    logic [1:0] unused_boot_pix;
    assign unused_boot_beat = boot_beat;
    assign unused_boot_pix  = boot_pix;
    logic unused_boot_ok;
    assign unused_boot_ok = boot_ok;

    // The Z1 meter, the stuck flag and the first-low-clock indices are off the
    // pins (they saturated to the same pattern for every fault).  Keep them
    // alive so SignalTap can still observe them.
    logic [2:0] unused_dbg_z1;
    logic [2:0] unused_dbg_live;
    logic [4:0] unused_idx_j2, unused_idx_j4, unused_idx_j6;
    assign unused_dbg_z1    = touch_dbg_z1;
    assign unused_dbg_live  = touch_dbg_live;
    assign unused_idx_j2    = touch_dbg_low_idx;
    assign unused_idx_j4    = touch_dbg_low_idx_alt;
    assign unused_idx_j6    = touch_dbg_low_idx_fr;

    assign led  = ~socket_live;          // LIT = a socket was found and is read
    assign led0 = ~heartbeat;            // frame heartbeat (blinks ~6 Hz)
    assign led1 = ~sock[0];              // socket code bit 0 (1s)
    assign led2 = ~sock[1];              // socket code bit 1 (2s)
    assign led3 = ~touch_dbg_stuck;      // LIT = nothing is answering
endmodule
