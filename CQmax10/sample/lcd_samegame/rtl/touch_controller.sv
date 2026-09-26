// touch_controller.sv
//
// XPT2046 touch-panel controller for the PMOD-TFTLCD v1.1 (ILI9341 + touch).
//
// Interface:
//   touch_cs        -> PIN_60   (T_CS,  active low)
//   touch_mosi      -> PIN_58   (T_DIN, control byte out)
//   touch_miso      -> PIN_56   (T_DO,  12-bit ADC result in)
//   touch_sck       -> PIN_50   (T_CLK, SPI clock)
//   touch_miso_alt  -> PIN_55   (second candidate MISO pad, bring-up probe)
//
// These are the pins the .qsf actually assigns.  (An older version of this
// comment listed PIN_134/135/132/130, which belong to a different socket on
// this board and were never used - the .qsf is the authority.)
//
// HOW THESE PINS WERE DETERMINED (do not "simplify" them)
//   Read directly out of the board's own KiCad netlist (CQmax10.kicad_pcb,
//   every `(pad "N" ... (net <id> "/NAME"))` entry), socket by socket:
//
//     LCD   lives on socket J5 : p3 = DC, p7 = CS, p8 = MOSI, p10 = SCK
//                                -> pins 77, 81, 78, 75
//     TOUCH lives on socket J2 : p3 = MISO, p7 = CS, p8 = MOSI, p10 = SCK
//                                -> pins 56,   60,   58,   50
//     J2 p1..p4 = 60, 58, 56, 50  (CS, MOSI, MISO, CLK - the standard PMOD
//                                  "SPI" layout, which is exactly how the
//                                  PMOD-TFTLCD module wires its touch port)
//
//   Both sockets therefore carry a complete, self-consistent 4-signal SPI port.
//   Pin assignments were verified against the physical board and the user has
//   confirmed the wiring itself is correct - if the touch panel is still quiet,
//   the fault is in the LOGIC, not in the pin list.  (That is exactly what the
//   divider bug fixed below turned out to be: the pins, the wiring and the data
//   all worked, but the SPI frame was one clock short of a full 24-bit
//   transfer.)
//
//   HISTORY / CORRECTION: an earlier version of this comment called the touch
//   pins PIN_134/135/132/130 and claimed 60/58/56/50 "span two connectors,
//   which can never work".  Both statements were WRONG - 134/135/132/130 are a
//   different socket (J6), and 60/58/56/50 are all on J2.  Do not reintroduce
//   that claim; measure the .kicad_pcb instead of guessing.
//
// Protocol (24 clocks per conversion):
//   Phase 1 (bit index 0..7)   : 8-bit control byte on DIN (MOSI)
//   Phase 2 (bit index 8..10)  : acquisition, DOUT undefined
//   Phase 3 (bit index 11..22) : 12-bit ADC result on DOUT, MSB first
//   Phase 4 (bit index 23)     : trailing zero (ignored)
//
// The bit index counts SCK rising edges from the start of the transfer, so the
// ADC result is shifted in on indices 11..22.  (An earlier comment said
// "clk 12..23", which is one off; the 0-based indexing above matches the code
// and the XPT2046 datasheet figure.)
//
// Control bytes:
//   0xD0 : X position (START=1, A2:A0=101, 12-bit, DFR, PD=00)
//   0x90 : Y position (START=1, A2:A0=001, ...)
//   0xB0 : Z1 pressure (used to detect touch)
//
// Cycle: every SAMPLE_MS the controller measures Z1.  If pressure exceeds
// TOUCH_THRESH it then reads X and Y, takes the median of three samples to
// de-noise, converts to LCD coordinates and asserts `touch_valid`.  When the
// pressure drops below threshold, `touch_valid` deasserts.
//
// Outputs for the game FSM:
//   touch_valid : 1 while the panel is being touched
//   touch_x     : LCD X (0..319)
//   touch_y     : LCD Y (0..239)
//   touch_down  : 1-cycle pulse on touch start
//   touch_up    : 1-cycle pulse on touch release
//
// The SPI clock is clk/32 = 1.5625 MHz (XPT2046 max is ~2 MHz).

module touch_controller #(
    parameter int CLK_FREQ_HZ  = 50_000_000,
    parameter int SAMPLE_MS   = 10,
    parameter int MS_SCALE    = 1,
    // MEASURED ON THE BOARD: the touch link works (a 0 was seen on MISO, and
    // the conversions are not all ones) but touch_valid never asserted, so the
    // pressure reading was below this threshold.  It was 100.  Lowered to 16 so
    // any genuine press registers; the Z1 meter below reports the real
    // magnitude so the value can be set properly afterwards.
    parameter logic [11:0] TOUCH_THRESH = 12'd16,
    // calibration (tune on the real board)
    parameter logic [11:0] X_ADC_MIN = 12'd200,
    parameter logic [11:0] X_ADC_MAX = 12'd3900,
    parameter logic [11:0] Y_ADC_MIN = 12'd200,
    parameter logic [11:0] Y_ADC_MAX = 12'd3900
)(
    input  logic        clk,
    input  logic        rst,

    // XPT2046 SPI
    output logic        touch_cs,
    output logic        touch_mosi,
    input  logic        touch_miso,
    output logic        touch_sck,
    // SECOND / THIRD candidate SPI ports, driven and sampled at exactly the
    // same instants as the primary one.
    //
    // WHY THIS EXISTS - and why the pin guessing had to stop:
    //   The module (pmod-tftlcd v1.1) puts its LCD on one PMOD connector and its
    //   touch controller on a SECOND one.  The touch port carries CS, MOSI, MISO
    //   and CLK on the module connector's pins 1..4, while this board exposes
    //   those same four signals on pins 7,8,9,10 of EVERY one of its PMOD
    //   sockets.  Which socket the touch connector ends up on therefore depends
    //   only on the module's mechanical layout - it CANNOT be derived from a
    //   netlist, and guessing it has already cost several builds.
    //
    // MEASURED, socket by socket, by driving each candidate and watching its
    //   MISO pin for ANY low level in a whole 24-clock transfer:
    //       socket J2 (60/58/56/50)  -> dead (12'hFFF, never low)
    //       socket J1 (45/43/39/47)  -> dead
    //       socket J3 (14/12/10/7)   -> dead
    //   The board has six PMOD sockets (J1..J6) and J5 is the LCD, so the touch
    //   connector can only be on J4 or J6.  This build drives those two.
    //
    //   alt_cs/alt_mosi/alt_sck/alt_miso  = socket J4 (pads 7,8,9,10 = 101,100,105,106)
    //   fr_cs /fr_mosi /fr_sck /fr_miso   = socket J6 (pads 7,8,9,10 = 141,140,131,127)
    //
    // AND, to save a whole extra round trip, the read path AUTO-SELECTS: as soon
    // as one of the three sockets proves live, the controller reads from THAT
    // one (see `miso_sel`).  So if the touch chip is on J4 or J6, touch starts
    // working in this very build, not just reporting.
    output logic        alt_cs,
    output logic        alt_mosi,
    input  logic        alt_miso,
    output logic        alt_sck,
    output logic        fr_cs,
    output logic        fr_mosi,
    input  logic        fr_miso,
    output logic        fr_sck,

    // touch status to the game FSM
    output logic        touch_valid,
    output logic [8:0]  touch_x,      // 0..319
    output logic [7:0]  touch_y,      // 0..239
    output logic        touch_down,   // 1-cycle pulse
    output logic        touch_up,     // 1-cycle pulse

    // bring-up probe (see the note below the port list)
    //
    // dbg_z1 is a 3-bit LOGARITHMIC METER of the last Z1 (pressure) reading:
    //     [0] = raw_z1 >= 16      [1] = raw_z1 >= 256     [2] = raw_z1 >= 2048
    // On the board these drive led1..led3 (ACTIVE LOW, so a met bit LIGHTS its
    // LED).  Untouched the panel should read ~0, so all three are dark; a real
    // press lights them progressively, which both proves Z1 is being measured
    // AND shows its order of magnitude for calibration.
    //
    // THE 2048 RUNG MATTERS: with the old 16/64/256 ladder every fault value
    // saturated the meter, so it could not distinguish "MISO never driven"
    // (4095) from "SPI frame one bit short" (2048).
    output logic [2:0]  dbg_z1,
    output logic        dbg_stuck,    // 16 conversions of 12'hFFF in a row
    // 1 = that pad carried at least one 0 bit, so SOMETHING is driving it.
    //   [2] = touch_miso  (socket J2, pins 60/58/56/50)   - measured DEAD
    //   [1] = alt_miso    (socket J4, pins 101/100/105/106)
    //   [0] = fr_miso     (socket J6, pins 141/140/131/127)
    output logic [2:0]  dbg_live,
    // PER-SOCKET FIRST-LOW-CLOCK PROBE - see the long note below dbg_z1.
    //   The 0-based SCK rising-edge index at which that socket's MISO pin first
    //   went LOW within the most recent transfer.  5'h1F means the pad NEVER
    //   went low anywhere in the whole 24-clock frame, i.e. nothing is driving
    //   it.  A value in 0..23 means the touch chip IS answering on that socket,
    //   and the number says roughly where its result begins.
    output logic [4:0]  dbg_low_idx,      // touch_miso  (J2)
    output logic [4:0]  dbg_low_idx_alt,  // alt_miso    (J4)
    output logic [4:0]  dbg_low_idx_fr,   // fr_miso     (J6)
    // Which socket the AUTO-SELECTOR settled on:
    //   0 = none answered (touch chip not on J2/J4/J6), 1 = J2, 2 = J4, 3 = J6
    output logic [1:0]  dbg_socket
);
    // ------------------------------------------------------------------
    // BRING-UP PROBE
    // ------------------------------------------------------------------
    // HISTORY (this probe has been through three stages as the fault moved):
    //  1. `touch_valid` came up and STAYED asserted, with no possible release.
    //     That is what an all-ones result produces, because the pressure reading
    //     is then permanently >= TOUCH_THRESH and no edge ever appears.  12'hFFF
    //     is also exactly what a MISO line stuck HIGH returns - and MEASURED, it
    //     was stuck HIGH.
    //  2. A dual-pad liveness test then showed a 0 ON MISO, i.e. the touch chip
    //     IS driving the line and the wiring to PIN_56 is correct.
    //  3. So the link works but `touch_valid` still never asserted, which means
    //     the Z1 (pressure) reading was simply BELOW the threshold.  Hence the
    //     meter below.
    //
    // `dbg_z1` is a 3-bit logarithmic meter of the last Z1 reading:
    //     [0] = raw_z1 >= 16      [1] = raw_z1 >= 64      [2] = raw_z1 >= 256
    // Untouched, Z1 should be near 0 and all three bits are clear (LEDs dark).
    // Pressing progressively lights them, which proves Z1 is really being
    // measured and shows its order of magnitude so TOUCH_THRESH can be set
    // sensibly instead of guessed.
    //
    // `dbg_stuck` latches when 16 CONSECUTIVE conversions all returned 12'hFFF,
    // which is the unambiguous "MISO is not being driven" signature.
    localparam int MS_CYCLES = (CLK_FREQ_HZ / 1000) / MS_SCALE;
    localparam int SAMPLE_PERIOD = MS_CYCLES * SAMPLE_MS;

    localparam logic [7:0] CMD_X  = 8'hD0;
    localparam logic [7:0] CMD_Y  = 8'h90;
    localparam logic [7:0] CMD_Z1 = 8'hB0;
    // 0x00 is "differential, power down between conversions".  Reading it costs
    // one extra SPI transfer and returns a constant 0 when the controller is
    // alive, because it measures the touch panel's own differential pair with
    // no drive applied - NOT its absolute voltage.
    localparam logic [7:0] CMD_PROBE = 8'h00;

    // ---- SPI transceiver signal declarations ----
    // These are declared BEFORE the clock divider because the divider has to
    // re-synchronise itself to the start of a transfer (see the fix note below).
    logic [7:0]  spi_cmd;
    logic        spi_start;
    logic        spi_busy;

    // ---- SPI bit clock divider (clk/32 -> 1.5625 MHz) ----
    //
    // BUG FIXED HERE - the divider MUST be re-synchronised to the start of every
    // transfer.
    //
    // It used to free-run (`clk_div <= clk_div + 1` unconditionally), so a
    // transfer began on an arbitrary divider phase.  Whenever that phase landed
    // in [16,30] the FIRST event of the frame was a FALL instead of a rise, so
    // `spi_bit` advanced without a SCK pulse.  The 24-clock frame then contained
    // only 23 RISING edges, which shifted the entire frame by one bit:
    //   * the panel decoded the command byte one bit early - 0xB0 (Z1) came back
    //     as 0x60, because the chip sampled DIN on one clock later than the
    //     controller intended, and
    //   * the controller captured {1, result[11:1]} instead of the result.
    // For a Z1 reading of 0 that is exactly 12'b1000_0000_0000 = 2048, which is
    // >= every threshold of the bring-up meter, so the meter read 111 forever.
    // Measured in simulation (dut.spi_done probe): the bad transfer reported
    // panel_cmd=60 / panel_n=23 / dut_shift=100000000000 / dut_res=2048.
    //
    // Starting the divider from 0 makes the frame deterministic: a rise at
    // phase 15 and a fall at phase 31 of every 32-cycle period, always beginning
    // with a rise.
    logic [4:0] clk_div;
    wire spi_start_ok = spi_start && !spi_busy;   // the cycle that starts a transfer

    always_ff @(posedge clk) begin
        if (rst)                clk_div <= 5'd0;
        else if (spi_start_ok)  clk_div <= 5'd0;  // <-- the fix
        else if (spi_busy)      clk_div <= clk_div + 5'd1;
        else                    clk_div <= 5'd0;
    end

    wire spi_clk_rise = spi_busy && (clk_div == 5'd15);
    wire spi_clk_fall = spi_busy && (clk_div == 5'd31);

    // ---- sample timer ----
    logic [23:0] sample_cnt;
    logic        sample_req;
    always_ff @(posedge clk) begin
        if (rst) begin
            sample_cnt <= '0;
            sample_req <= 1'b0;
        end else if (sample_cnt == 24'(SAMPLE_PERIOD) - 1) begin
            sample_cnt <= '0;
            sample_req <= 1'b1;
        end else begin
            sample_cnt <= sample_cnt + 1'b1;
            sample_req <= 1'b0;
        end
    end

    // ---- SPI transceiver ----
    logic        spi_done;      // 1-clock pulse when a transfer completes
    logic [5:0]  spi_bit;       // clock count 0..23
    logic [11:0] spi_result;
    logic [7:0]  shift_out;
    logic [11:0] shift_in;
    // "has this pad ever been LOW while the controller was sampling?" - see the
    // port-list note for why every candidate pad is watched.
    logic        alt_seen_low;
    logic        fr_seen_low;
    logic        pri_seen_low;

    // ---- live-source auto-selection -------------------------------------
    //
    // Rather than make the user reflash once the answering socket is known,
    // the receive path picks it MYSELF, using exactly the evidence the probe
    // gathered: a socket that ever pulled MISO low is the socket with a touch
    // chip on it.
    //
    //   pri_seen_low -> socket J2 answered, keep reading J2
    //   alt_seen_low -> socket J4 answered, read J4
    //   fr_seen_low  -> socket J6 answered, read J6
    //
    // Priority only matters if more than one pad looks live, which cannot happen
    // with a single touch connector.  Until SOMETHING answers, the read stays on
    // J2, so the "all ones" behaviour is unchanged and the probe still reports
    // honestly.
    //
    // This must be declared BEFORE the transceiver that samples it (vlog-2730).
    wire miso_sel = pri_seen_low ? touch_miso :
                    alt_seen_low ? alt_miso   :
                    fr_seen_low  ? fr_miso    :
                                   touch_miso;

    // Which socket the auto-selector settled on, for the bring-up LEDs.
    //   0 = none answered yet (still reading J2), 1 = J2, 2 = J4, 3 = J6
    logic [1:0] autosel_socket;
    always_comb begin
        if      (pri_seen_low) autosel_socket = 2'd1;
        else if (alt_seen_low) autosel_socket = 2'd2;
        else if (fr_seen_low)  autosel_socket = 2'd3;
        else                   autosel_socket = 2'd0;
    end

    // FIRST-CLOCK-INDEX PROBE state.  See the note at dbg_low_idx near the end
    // of the file.  The per-socket `*_low_seen_t` / `*_low_idx_t` pairs
    // accumulate during ONE transfer and are copied into the persistent
    // `*_low_idx_q` registers when that transfer ends.
    logic        low_seen_t;
    logic [4:0]  low_idx_t;
    logic [4:0]  dbg_low_idx_q;
    logic        alt_low_seen_t;
    logic [4:0]  alt_low_idx_t;
    logic [4:0]  alt_low_idx_q;
    logic        fr_low_seen_t;
    logic [4:0]  fr_low_idx_t;
    logic [4:0]  fr_low_idx_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            touch_cs   <= 1'b1;
            touch_mosi <= 1'b0;
            touch_sck  <= 1'b0;
            spi_busy   <= 1'b0;
            spi_bit    <= 6'd0;
            spi_result <= 12'd0;
            shift_out  <= 8'd0;
            shift_in   <= 12'd0;
            alt_seen_low <= 1'b0;
            fr_seen_low  <= 1'b0;
            pri_seen_low <= 1'b0;
            low_seen_t   <= 1'b0;
            low_idx_t    <= 5'h1F;
            dbg_low_idx_q <= 5'h1F;
            alt_low_seen_t <= 1'b0;
            alt_low_idx_t  <= 5'h1F;
            alt_low_idx_q  <= 5'h1F;
            fr_low_seen_t <= 1'b0;
            fr_low_idx_t  <= 5'h1F;
            fr_low_idx_q  <= 5'h1F;
        end else if (spi_start && !spi_busy) begin
            touch_cs   <= 1'b0;
            touch_sck  <= 1'b0;
            spi_busy   <= 1'b1;
            spi_bit    <= 6'd0;
            shift_out  <= spi_cmd;
            shift_in   <= 12'd0;
            touch_mosi <= spi_cmd[7];
            low_seen_t <= 1'b0;
            low_idx_t  <= 5'h1F;
            alt_low_seen_t <= 1'b0;
            alt_low_idx_t  <= 5'h1F;
            fr_low_seen_t  <= 1'b0;
            fr_low_idx_t   <= 5'h1F;
        end else if (spi_busy) begin
            if (spi_clk_rise) begin
                touch_sck <= 1'b1;

                // WATCH THE MISO PAD ON EVERY CLOCK OF THE FRAME.
                //
                // The result is only shifted in over the sampling window below,
                // but the pad is observed across ALL 24 clocks.  If it is low
                // anywhere we learn WHERE, which is exactly what tells a wrong
                // sampling window apart from a line that is never driven.
                // (Watching only the window made those two faults look
                // identical: both produced 12'hFFF and a saturated meter.)
                if (!touch_miso && !low_seen_t) begin
                    low_seen_t <= 1'b1;
                    low_idx_t  <= spi_bit[4:0];
                end
                // Do exactly the same for the two OTHER candidate sockets, so
                // one flash says which socket the touch chip is actually on.
                if (!alt_miso && !alt_low_seen_t) begin
                    alt_low_seen_t <= 1'b1;
                    alt_low_idx_t  <= spi_bit[4:0];
                end
                if (!fr_miso && !fr_low_seen_t) begin
                    fr_low_seen_t <= 1'b1;
                    fr_low_idx_t  <= spi_bit[4:0];
                end

                if (spi_bit >= 6'd9 && spi_bit <= 6'd20) begin
                    shift_in     <= {shift_in[10:0], miso_sel};
                    // Sample the other candidate pads at exactly the same
                    // instants.  A line that is never driven reads all ones, so
                    // a single 0 anywhere proves that pad is being driven.
                    if (!alt_miso)            alt_seen_low <= 1'b1;
                    if (!fr_miso)             fr_seen_low  <= 1'b1;
                    // Also watch the pad we ARE reading: if it ever goes low the
                    // read path is fine and the fault is elsewhere.
                    if (!touch_miso)          pri_seen_low <= 1'b1;
                end
            end else if (spi_clk_fall) begin
                touch_sck <= 1'b0;
                spi_bit   <= spi_bit + 6'd1;
                if (spi_bit < 6'd7) begin
                    touch_mosi <= shift_out[6 - spi_bit[2:0]];
                end else if (spi_bit == 6'd7) begin
                    touch_mosi <= 1'b0;
                end else if (spi_bit == 6'd23) begin
                    spi_result <= shift_in;
                    spi_busy   <= 1'b0;
                    touch_cs   <= 1'b1;
                    // Publish this transfer's first-low index for every socket.
                    // The `*_seen_t` / `*_idx_t` registers were already updated
                    // on the rise of bit 23 (one clock earlier), so the NBA
                    // values are visible here.
                    dbg_low_idx_q <= low_seen_t     ? low_idx_t     : 5'h1F;
                    alt_low_idx_q <= alt_low_seen_t ? alt_low_idx_t : 5'h1F;
                    fr_low_idx_q  <= fr_low_seen_t  ? fr_low_idx_t  : 5'h1F;
                end
            end
        end
    end

    // The three candidate sockets receive IDENTICAL SPI traffic.  Only the one
    // the touch connector is actually plugged into will answer; the others see
    // the clocks with nothing attached, which is harmless.
    assign alt_cs   = touch_cs;
    assign alt_mosi = touch_mosi;
    assign alt_sck  = touch_sck;
    assign fr_cs    = touch_cs;
    assign fr_mosi  = touch_mosi;
    assign fr_sck   = touch_sck;

    // (The live-source auto-selection that drives the receive path lives ABOVE
    //  the SPI transceiver, because vlog requires a signal to be declared before
    //  it is used - see `miso_sel` there.)

    // A GENUINE one-cycle pulse when a transfer completes.
    //
    // This must NOT be driven from the block above: there, spi_done was only
    // assigned inside the `spi_busy` branch, so it was never cleared once the
    // transfer ended and stayed HIGH until the next one began.  That made the
    // command test in the probe unreliable (it ended up metering the X/Y reads
    // instead of Z1).  A dedicated register is unambiguous.
    always_ff @(posedge clk) begin
        if (rst) spi_done <= 1'b0;
        else     spi_done <= (spi_busy && spi_clk_fall && (spi_bit == 6'd23));
    end

    // ---- coordinate conversion (ADC -> LCD) ----
    //
    // ARITHMETIC BUG - do not "simplify" this back
    // --------------------------------------------
    // The original code computed the divide as a power-of-two shift:
    //     tmp = (ADC_MAX - raw) * 319;
    //     return tmp[21:13];          // == tmp / 8192   <-- WRONG
    // 8192 has nothing to do with the ADC range, which spans only
    // (ADC_MAX - ADC_MIN) = 3700 counts.  The numerator peaks at
    // 3699 * 319 = 1,179,981, and /8192 of that is 144, so the reported X
    // could never exceed 144: the right-hand 55% of the panel, and the same
    // 55% at the bottom of Y, simply never responded.  It also jumped straight
    // to 319 the instant the reading touched ADC_MIN, because of the clamp
    // branch - a hard discontinuity at one edge.
    //
    // The divide is by a CONSTANT, so it is done with a multiply by a Q16
    // reciprocal and a shift - no divider.  Writing it as a real `/` costs a
    // full combinational divider and is unacceptable here: with `prod / X_SPAN`
    // the fitter reported setup slack of **-62.791 ns** and LE usage jumped to
    // 7,467 / 8,064 (93%).
    //
    //   x = (num * KX + 2^15) >> 16      KX = round(319 * 65536 / span)
    //   y = (num * KY + 2^15) >> 16      KY = round(239 * 65536 / span)
    //
    // The rounding term keeps the result to within 1 LSB of exact integer
    // division, which is far below the touch panel's own noise.  The TB compares
    // against exact division with a +/-1 tolerance for that reason.
    //
    // The constants below are for the default span of 3700.  IF YOU CHANGE
    // X_ADC_MIN/MAX, recompute them (see the formula above); a static_assert
    // catches the mismatch at elaboration.
    localparam logic [31:0] X_SPAN = (X_ADC_MAX - X_ADC_MIN);
    localparam logic [31:0] Y_SPAN = (Y_ADC_MAX - Y_ADC_MIN);
    localparam logic [31:0] KX = 32'd5650;      // round(319 * 65536 / 3700)
    localparam logic [31:0] KY = 32'd4233;      // round(239 * 65536 / 3700)

    // Guard: the reciprocals above are only valid for a 3700-count span.
    // (This must live in an `initial` block - a bare `if ($error(...))` at
    // module scope is a syntax error, and `$error` is what makes the mismatch a
    // hard failure instead of a silent wrong answer.)
    initial begin
        if (X_SPAN != 32'd3700 || Y_SPAN != 32'd3700)
            $error("touch_controller: KX/KY are tuned for a 3700-count span; recompute them for the configured ADC range.");
    end

    function automatic [8:0] adc_to_x(input logic [11:0] raw);
        logic [31:0] num, scaled;
        if (raw <= X_ADC_MIN)      return 9'd319;
        else if (raw >= X_ADC_MAX) return 9'd0;
        else begin
            num    = (X_ADC_MAX - raw);             // 1..3699
            scaled = num * KX;                      // <= 3699*5651 = 20,903,649
            return (scaled + 32'd32768) >> 16;      // +0.5 LSB round
        end
    endfunction

    function automatic [7:0] adc_to_y(input logic [11:0] raw);
        logic [31:0] num, scaled;
        if (raw <= Y_ADC_MIN)      return 8'd239;
        else if (raw >= Y_ADC_MAX) return 8'd0;
        else begin
            num    = (Y_ADC_MAX - raw);
            scaled = num * KY;                      // <= 3699*4233 = 15,657,867
            return (scaled + 32'd32768) >> 16;
        end
    endfunction

    // ---- median-of-3 ----
    function automatic [11:0] med3(input logic [11:0] a, b, c);
        if ((a >= b && a <= c) || (a >= c && a <= b))      return a;
        else if ((b >= a && b <= c) || (b >= c && b <= a)) return b;
        else                                               return c;
    endfunction

    // ---- main FSM ----
    localparam logic [3:0]
        S_IDLE      = 4'd0,
        S_Z1_START  = 4'd1,
        S_Z1_WAIT   = 4'd2,
        S_Z1_CHECK  = 4'd3,
        S_X_START   = 4'd4,
        S_X_WAIT    = 4'd5,
        S_Y_START   = 4'd6,
        S_Y_WAIT    = 4'd7,
        S_STORE     = 4'd8,
        S_MEDIAN    = 4'd9,
        S_NO_TOUCH  = 4'd10;

    logic [3:0]  state;
    logic [11:0] raw_x, raw_y, raw_z1;
    logic [11:0] x_samples [0:2];
    logic [11:0] y_samples [0:2];
    logic [1:0]  sample_idx;
    logic        valid_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            spi_start   <= 1'b0;
            spi_cmd     <= 8'd0;
            raw_x       <= 12'd0;
            raw_y       <= 12'd0;
            raw_z1      <= 12'd0;
            sample_idx  <= 2'd0;
            valid_reg   <= 1'b0;
            touch_x     <= 9'd0;
            touch_y     <= 8'd0;
        end else begin
            spi_start <= 1'b0;

            case (state)
            S_IDLE: begin
                if (sample_req) state <= S_Z1_START;
            end

            S_Z1_START: begin
                if (!spi_busy && !spi_start) begin
                    spi_cmd   <= CMD_Z1;
                    spi_start <= 1'b1;
                    state     <= S_Z1_WAIT;
                end
            end

            S_Z1_WAIT: begin
                if (!spi_busy && !spi_start) begin
                    raw_z1 <= spi_result;
                    state  <= S_Z1_CHECK;
                end
            end

            S_Z1_CHECK: begin
                if (raw_z1 >= TOUCH_THRESH) state <= S_X_START;
                else                        state <= S_NO_TOUCH;
            end

            S_X_START: begin
                if (!spi_busy && !spi_start) begin
                    spi_cmd   <= CMD_X;
                    spi_start <= 1'b1;
                    state     <= S_X_WAIT;
                end
            end

            S_X_WAIT: begin
                if (!spi_busy && !spi_start) begin
                    raw_x <= spi_result;
                    state <= S_Y_START;
                end
            end

            S_Y_START: begin
                if (!spi_busy && !spi_start) begin
                    spi_cmd   <= CMD_Y;
                    spi_start <= 1'b1;
                    state     <= S_Y_WAIT;
                end
            end

            S_Y_WAIT: begin
                if (!spi_busy && !spi_start) begin
                    raw_y <= spi_result;
                    state <= S_STORE;
                end
            end

            S_STORE: begin
                x_samples[sample_idx] <= raw_x;
                y_samples[sample_idx] <= raw_y;
                if (sample_idx == 2'd2) begin
                    sample_idx <= 2'd0;
                    state      <= S_MEDIAN;
                end else begin
                    sample_idx <= sample_idx + 2'd1;
                    state      <= S_IDLE;
                end
            end

            S_MEDIAN: begin
                touch_x   <= adc_to_x(med3(x_samples[0], x_samples[1], x_samples[2]));
                touch_y   <= adc_to_y(med3(y_samples[0], y_samples[1], y_samples[2]));
                valid_reg <= 1'b1;
                state     <= S_IDLE;
            end

            S_NO_TOUCH: begin
                valid_reg  <= 1'b0;
                sample_idx <= 2'd0;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // ---- touch_valid + edge detection ----
    logic valid_d;
    always_ff @(posedge clk) begin
        if (rst) valid_d <= 1'b0;
        else     valid_d <= valid_reg;
    end

    assign touch_valid = valid_reg;
    assign touch_down  = valid_reg && !valid_d;
    assign touch_up    = !valid_reg && valid_d;

    // Pad liveness for the bring-up probe.  See the port-list note.
    assign dbg_live = { pri_seen_low, alt_seen_low, fr_seen_low };

    // PER-SOCKET FIRST-CLOCK-INDEX PROBE
    // ----------------------------------
    // WHY THIS EXISTS, and why every previous probe was not enough:
    //
    // The module (pmod-tftlcd v1.1) puts its LCD on ONE PMOD connector and the
    // touch controller on a SECOND.  The touch port carries CS, MOSI, MISO, CLK
    // on the module connector's pins 1..4.  The board exposes those signals on
    // pins 7,8,9,10 of EVERY PMOD socket, so the touch port lands on pins
    // 7,8,9,10 of whichever socket it is plugged into - and which socket that is
    // depends on nothing but how far the ribbon reaches.  It CANNOT be derived
    // from a netlist.
    //
    // MEASURED: with the controller talking to J2, every conversion returned
    // 12'hFFF and that MISO pad never went low anywhere in the whole 24-clock
    // frame.  Nothing was driving it, so the touch port is on a DIFFERENT socket.
    //
    // This build therefore drives TWO sockets at once and watches both MISO
    // pins, so a single flash answers the question:
    //    dbg_live[2] / dbg_low_idx      -> touch_miso  (socket J2, 60/58/56/50)
    //    dbg_live[1] / dbg_low_idx_alt  -> alt_miso    (socket J1, 45/43/39/47)
    //
    // A 5'h1F index means that pad never went low (nothing attached), while a
    // value in 0..23 proves the touch chip is answering THERE.  Compare the
    // value with the sampling window (clocks 9..20) to confirm the capture
    // position as well.
    //
    // The values are latched per transfer (cleared when a transfer starts,
    // published when bit 23 falls) so they always reflect the LATEST conversion.
    assign dbg_low_idx     = dbg_low_idx_q;
    assign dbg_low_idx_alt = alt_low_idx_q;
    assign dbg_low_idx_fr  = fr_low_idx_q;
    assign dbg_socket      = autosel_socket;

    // ---- bring-up probe -------------------------------------------------
    // The Z1 magnitude meter is DERIVED COMBINATIONALLY from raw_z1.
    //
    // raw_z1 is latched only in S_Z1_WAIT, so it always holds the latest
    // PRESSURE reading - unlike spi_result, which cycles through Z1, X and Y
    // and would show a coordinate instead.  Deriving the meter this way removes
    // all dependence on transfer timing.
    //
    // THRESHOLDS ARE 16 / 256 / 2048 (not 16/64/256).  The old three-bit
    // thresholds were USELESS on the board because they SATURATE: both of the
    // two fault values that actually occurred - 4095 (MISO never driven) and
    // 2048 (a one-bit-shifted frame) - are >= 256, so the meter read 111 for
    // both and could not tell them apart.  With a 2048 rung the two are
    // distinguishable, and `led` (dbg_stuck) settles it outright:
    //     [0] = raw_z1 >= 16
    //     [1] = raw_z1 >= 256
    //     [2] = raw_z1 >= 2048      <- 2048 (shifted frame) or 4095 (undriven)
    assign dbg_z1 = { (raw_z1 >= 12'd2048),
                      (raw_z1 >= 12'd256),
                      (raw_z1 >= 12'd16) };

    // `dbg_stuck` latches when 16 CONSECUTIVE conversions all returned 12'hFFF,
    // which is the unambiguous "MISO is not being driven" signature.
    logic [3:0] allones_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            dbg_stuck     <= 1'b0;
            allones_count <= 4'd0;
        end else if (spi_done) begin
            if (spi_result == 12'hFFF) begin
                if (allones_count != 4'hF)
                    allones_count <= allones_count + 4'd1;
                if (allones_count == 4'hE)
                    dbg_stuck <= 1'b1;
            end else begin
                // ANY conversion that is not all ones proves the line is being
                // driven, so the "stuck" verdict is cleared.
                allones_count <= 4'd0;
                dbg_stuck     <= 1'b0;
            end
        end
    end
endmodule
