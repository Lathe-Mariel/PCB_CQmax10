// ufm_bootloader.sv
//
// Copies the 2000 logo pixels from UFM (On-Chip Flash IP, 32-bit word per
// pixel, pixel in bits [15:0]) into the writable logo_ram at power-up.
//
// ---------------------------------------------------------------------------
// AVALON-MM HANDSHAKE - the trap that used to blank the panel
// ---------------------------------------------------------------------------
// The MAX 10 On-Chip Flash data slave computes
//     avmm_waitrequest = ~reset_n
//                      | (~is_write_busy && avmm_write)
//                      | write_wait_w
//                      | (~is_read_busy && avmm_read)
//                      | (avmm_read && read_wait_w)
//     (altera_onchip_flash_avmm_data_controller.v)
// and `avmm_readdatavalid` is raised from READ_VALID_PRE_READING, which is two
// states BEFORE `read_wait` is cleared in READ_STATE_CLEAR.  Therefore
//
//     readdatavalid PULSES WHILE waitrequest IS STILL HIGH.
//
// A master that waits for !waitrequest and only then looks for readdatavalid
// misses the single-cycle pulse and waits for ever.  That is what the first
// version did: `boot_done` never asserted, samegame_top held the game FSM in
// reset (`game_rst = rst | ~boot_done`), the board stayed EMPTY and the renderer
// painted BG_COLOR (0x0000) over the whole panel - a black screen with
// perfectly healthy LEDs.
//
// Correct sequence used here:
//   1. wait for !waitrequest BEFORE the command.  This also guarantees the IP
//      is out of reset, because `~reset_n` forces waitrequest high.
//   2. hold `flash_read` for TWO cycles.  One is what the IP samples; the second
//      is free insurance.  Holding it longer WOULD hang: while the command is
//      still asserted `(~is_read_busy && avmm_read)` keeps waitrequest high.
//   3. wait ONLY for `readdatavalid`, with `flash_addr` held stable.
//
// ---------------------------------------------------------------------------
// WATCHDOG + FAIL VISIBILITY (added after the first hardware bring-up)
// ---------------------------------------------------------------------------
// A board bring-up must never be able to hang silently with no clue:
//
//   * every read has a watchdog (`WATCH_CYCLES`).  If readdatavalid does not
//     arrive in time the word is abandoned, the FSM re-syncs through S_IDLE and
//     retries it with a completely fresh command.  A healthy UFM read takes
//     ~20 cycles, so this only fires on a real fault.
//   * after `MAX_RETRIES` failures on one word, `boot_done` is asserted ANYWAY
//     so the game and the renderer keep working (they just see whatever the
//     logo RAM holds) and `boot_fail` is raised.
//
// `boot_fail` is exported so samegame_top can show it on an LED.  This makes
// the two failure modes distinguishable on the board with no debugger at all:
//   led(boot_done) off + led(boot_fail) off  -> FSM stuck before the first word
//   led(boot_done) on  + led(boot_fail) on   -> reads time out / UFM is blank
//   led(boot_done) on  + led(boot_fail) off  -> boot is healthy
// ---------------------------------------------------------------------------
// IMPORTANT - WHY WATCH_CYCLES MUST STAY SMALL (a real bring-up trap)
// ---------------------------------------------------------------------------
// The watchdog only helps if a failure is detectable in a reasonable time. The
// first version used 500_000 cycles (~10 ms). With MAX_RETRIES = 3 that is a
// worst case of
//     13 attempts * (WATCH_CYCLES + IDLE/REQ overhead) ~ 6.8 MILLION cycles
// for the FIRST word, and if the UFM data slave is genuinely dead that repeats
// for ALL 2000 words:
//     2000 * 6.8e6 = 1.36e10 cycles = 272 SECONDS at 50 MHz
// so the board would appear completely dead for over four minutes before
// boot_done finally asserted (and the LEDs would mislead you in the meantime).
// A healthy UFM read is only ~20-40 cycles, so a timeout of a few thousand
// cycles is already 100x margin.  6000 cycles ~ 120 us is used here, which
// keeps the worst case for a dead UFM at
//     2000 * 13 * 6000 = 1.56e8 cycles ~ 3.1 SECONDS.
// ---------------------------------------------------------------------------
module ufm_bootloader #(
    parameter int PIXELS      = 2000,      // 5 logos x 20 x 20
    parameter int RAM_AW      = 11,        // logo_ram address width
    parameter int RAM_DW      = 16,        // logo_ram data width (pixel)
    // ~120 us at 50 MHz.  A healthy read needs ~20-40 cycles, so this is a
    // 150x margin; see the note above for why it must NOT be made large.
    parameter int WATCH_CYCLES = 6000,
    parameter int MAX_RETRIES  = 2
)(
    input  logic        clk,
    input  logic        rst,

    // On-Chip Flash Avalon-MM data slave (master side)
    output logic        flash_read,
    output logic [12:0] flash_addr,      // word address 0..8191
    input  logic        flash_waitrequest,
    input  logic        flash_readdatavalid,
    input  logic [31:0] flash_readdata,

    // logo_ram write port
    output logic            ram_wr_en,
    output logic [RAM_AW-1:0] ram_wr_addr,
    output logic [RAM_DW-1:0] ram_wr_data,

    output logic        boot_done,
    output logic        boot_fail,     // 1 = at least one pixel never arrived
    output logic        boot_blank,    // 1 = every word read back as 0xFFFF
    output logic        boot_beat,     // free-running ~3 Hz blink (bring-up)
    output logic [1:0]  boot_pix       // sample of the first pixel read (debug)
);
    typedef enum logic [2:0] {
        S_IDLE,        // (re)start the current word
        S_REQ,         // wait for the IP to accept a command
        S_REQ2,        // hold flash_read for the second cycle
        S_DATA,        // wait for readdatavalid
        S_WRITE,       // store the pixel
        S_NEXT,        // advance / finish
        S_ABORT,       // watchdog fired: abandon this word, retry it
        S_DONE
    } state_t;
    state_t state;

    logic [10:0] addr;         // 0..1999 pixel index (also UFM word addr)
    logic [2:0]  retry_cnt;
    logic [12:0] watch;        // watchdog counter (see WATCH_CYCLES note)
    // Set while every pixel read so far came back as 16'hFFFF.  Only meaningful
    // once the copy has finished; see `boot_blank`.
    logic        all_ones_seen;
    // The first 32 bits the UFM ever returned.  Exported so a future bring-up
    // can see what the flash really contains without a logic analyser.
    logic [31:0] pix0;
    logic        pix0_taken;
    // Free-running bring-up heartbeat.  24 bits so it toggles at ~3 Hz, a rate
    // the eye reads as a clear blink rather than a dim flicker.
    logic [23:0] beat;

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            addr        <= 11'd0;
            retry_cnt   <= 3'd0;
            watch       <= 13'd0;
            beat        <= 24'd0;
            flash_read  <= 1'b0;
            flash_addr  <= 13'd0;
            ram_wr_en   <= 1'b0;
            ram_wr_addr <= '0;
            ram_wr_data <= '0;
            boot_done   <= 1'b0;
            boot_fail   <= 1'b0;
            all_ones_seen <= 1'b1;
            pix0        <= 32'd0;
            pix0_taken  <= 1'b0;
        end else begin
            flash_read <= 1'b0;
            ram_wr_en  <= 1'b0;
            // Free-running ~3 Hz heartbeat.  On the board this is the only
            // way to tell "the bootloader FSM is actually clocked and running"
            // apart from "the UFM is holding it up" - see the LED map in
            // samegame_top.
            beat <= beat + 24'd1;

            case (state)
            // ----------------------------------------------------------
            // Start (or restart) the current word.
            //
            // NOTE: retry_cnt is deliberately NOT cleared here.  This state is
            // re-entered by S_ABORT for every retry, so clearing it would make
            // `retry_cnt >= MAX_RETRIES` unreachable and a dead UFM would be
            // retried for ever (the TB's dead-slave case caught exactly that).
            // It is cleared on a successful word (S_NEXT) and at reset.
            // ----------------------------------------------------------
            S_IDLE: begin
                watch <= 13'd0;
                state <= S_REQ;
            end

            // Wait until the IP can take a command.
            //
            // `~reset_n` forces waitrequest high, so this also guarantees the
            // flash block is out of its internal reset before read is pulsed.
            S_REQ: begin
                if (!flash_waitrequest) begin
                    flash_read <= 1'b1;
                    flash_addr <= 13'(addr);
                    watch      <= 13'd0;
                    state      <= S_REQ2;
                end else if (watch >= 13'(WATCH_CYCLES)) begin
                    state      <= S_ABORT;   // bus never became free
                end else begin
                    watch      <= watch + 13'd1;
                end
            end

            // Second cycle of the read pulse (see the header note).
            S_REQ2: begin
                flash_read <= 1'b1;
                watch      <= 13'd0;
                state      <= S_DATA;
            end

            // Wait for readdatavalid.  waitrequest is deliberately IGNORED
            // here: it is still high when readdatavalid pulses.
            //
            // flash_addr keeps its value for the whole state, so the address is
            // stable until the read has really completed.
            S_DATA: begin
                if (flash_readdatavalid) begin
                    ram_wr_data <= flash_readdata[15:0];
                    // remember the very first word so the board can show what
                    // the flash really contains (see boot_pix)
                    if (!pix0_taken) begin
                        pix0       <= flash_readdata;
                        pix0_taken <= 1'b1;
                    end
                    state       <= S_WRITE;
                end else if (watch >= 13'(WATCH_CYCLES)) begin
                    state       <= S_ABORT;
                end else begin
                    watch       <= watch + 13'd1;
                end
            end

            // ----------------------------------------------------------
            // Store the pixel.
            // ----------------------------------------------------------
            S_WRITE: begin
                ram_wr_en   <= 1'b1;
                ram_wr_addr <= RAM_AW'(addr);
                all_ones_seen <= all_ones_seen && (flash_readdata[15:0] == 16'hFFFF);
                state       <= S_NEXT;
            end

            S_NEXT: begin
                if (addr == 11'(PIXELS - 1)) begin
                    state     <= S_DONE;
                    boot_done <= 1'b1;
                end else begin
                    addr      <= addr + 11'd1;
                    retry_cnt <= 3'd0;      // this word is done: reset the retries
                    watch     <= 13'd0;
                    state     <= S_REQ;      // consecutive words need no IDLE
                end
            end

            // ----------------------------------------------------------
            // This word did not arrive in time: retry it, and if it keeps
            // failing move on so the design can never hang for ever.
            // ----------------------------------------------------------
            S_ABORT: begin
                flash_read <= 1'b0;
                watch      <= 13'd0;
                if (retry_cnt >= 3'(MAX_RETRIES)) begin
                    boot_fail <= 1'b1;
                    // give up on this word but keep going: spinning here would
                    // hold the game FSM in reset for ever
                    if (addr == 11'(PIXELS - 1)) begin
                        state     <= S_DONE;
                        boot_done <= 1'b1;
                    end else begin
                        addr      <= addr + 11'd1;
                        retry_cnt <= 3'd0;
                        state     <= S_REQ;
                    end
                end else begin
                    retry_cnt <= retry_cnt + 3'd1;
                    // full resync through IDLE so every retry starts from a
                    // clean command and a fresh waitrequest handshake
                    state     <= S_IDLE;
                end
            end

            S_DONE: begin
                boot_done <= 1'b1;
            end
            endcase
        end
    end

    // ~3 Hz square wave while the FSM is clocking (50 MHz / 2^24).  Exported
    // purely for bring-up: it proves the bootloader is alive even if every UFM
    // read times out, which "led = ~boot_done" alone cannot show.
    assign boot_beat = beat[23];

    // Latched "the whole UFM image was erased" flag.
    //
    // This is the flag that names the SOLID WHITE panel: an erased UFM reads
    // back all ones, so every logo pixel becomes RGB565 0xFFFF and the renderer
    // paints white everywhere.  Nothing times out, so boot_fail stays 0 and the
    // panel just looks "full" - which is exactly why the failure needs its own
    // signal.
    assign boot_blank = all_ones_seen;

    // Two bits of the first word the flash returned.  For a correctly
    // programmed UFM these are bits [1:0] of the first pixel, i.e. a few of the
    // LSBs of 16'h00EA, so they read 2'b10.  They read 2'b11 when the flash is
    // erased and 2'b00 when it is all zeros, which makes the flash content
    // readable straight off the board.
    assign boot_pix = pix0[1:0];
endmodule
