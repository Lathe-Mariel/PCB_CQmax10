// lcd_ili9341_ctrl.sv
//
// Drives a PMOD-TFTLCD v1.1 (ILI9341, 320x240) over a 4-wire write-only SPI
// bus (CS, SCK, MOSI, D/C). There is no MISO and no dedicated hardware RESET
// line in this project's pin list, so the panel is reset with the ILI9341
// SWRESET (0x01) command; RESX is assumed to be pulled high on the PMOD
// board (same assumption as sample/lcd/lcd_ctrl.v, which works).
//
// The controller initialises the panel on its own POWERON_WAIT_MS after reset
// is released (the panel needs ~150 ms of VDD settling before the first
// command).
//
// ---------------------------------------------------------------------------
// ARCHITECTURE: WINDOWED RECTANGLE WRITES, NOT FRAME STREAMING
// ---------------------------------------------------------------------------
// The ILI9341 keeps the picture in its OWN GRAM, so the FPGA does not have to
// resend all 76800 pixels every frame. Instead this controller accepts
// windowed rectangle writes:
//
//   wr_valid / wr_ready + wr_x0,wr_y0,wr_x1,wr_y1 (inclusive) + wr_color
//
// and for each one sends
//
//   CASET (x0..x1)   PASET (y0..y1)   RAMWR   followed by the window pixels
//
// The window can be anything from the whole screen down to a single pixel:
//
//   * whole screen  -> the initial background fill
//   * one row span  -> one playfield line          ("行単位で描画")
//   * one pixel     -> one dot of the moving line  ("ドット単位で描画")
//
// That is what removes the need for a frame-buffer scan-out: the panel holds
// the image and the FPGA only writes what actually changed. The previous
// design streamed 320x240x16 bits every frame, which kept the SPI link 100 %
// busy and capped the design at ~6.7 fps; now the link is idle between
// updates.
//
// A request must be held (wr_valid high, address/colour stable) until the
// cycle where wr_ready is high. The window is then latched, so the caller may
// change it as soon as it sees the accept.
//
// The pixels of a window are streamed in row-major order (column fastest),
// which is the order the ILI9341 expects after CASET/PASET.
//
// Timing: SCK = clk * HALF_DEN / (2 * HALF_NUM). The defaults give
// 50 MHz * 2 / (2*5) = 10 MHz, the ILI9341 datasheet write limit.

module lcd_ili9341_ctrl #(
    parameter int          SCLK_HALF_NUM   = 5,   // SCK half period = 5/2 clk
    parameter int          SCLK_HALF_DEN   = 2,   // 50*2/(2*5) = 10 MHz
    parameter int          CLK_FREQ_HZ      = 50_000_000,
    parameter int          SCREEN_W         = 320,
    parameter int          SCREEN_H         = 240,
    parameter int          POWERON_WAIT_MS  = 150,
    parameter int          MS_SCALE         = 1,   // 1 in hardware; divide delays for simulation
    parameter logic [7:0]  MADCTL_VALUE     = 8'h28 // landscape (see README)
)(
    input  logic        clk,
    input  logic        rst,

    // ---- rectangle write request (valid/ready) --------------------------
    input  logic        wr_valid,
    output logic        wr_ready,
    input  logic [8:0]  wr_x0,
    input  logic [7:0]  wr_y0,
    input  logic [8:0]  wr_x1,
    input  logic [7:0]  wr_y1,
    input  logic [15:0] wr_color,

    output logic        active,         // 1 while a write is running
    output logic        wr_done,        // 1-cycle pulse when a write finished

    output logic        lcd_cs,
    output logic        lcd_sck,
    output logic        lcd_mosi,
    output logic        lcd_dc
);
    localparam int COLS_LAST_I = SCREEN_W - 1;                 // 319
    localparam int ROWS_LAST_I = SCREEN_H - 1;                 // 239
    localparam logic [8:0]  COLS_LAST = COLS_LAST_I[8:0];
    localparam logic [7:0]  ROWS_LAST = ROWS_LAST_I[7:0];

    localparam int MS_CYCLES = (CLK_FREQ_HZ / 1000) / MS_SCALE;

    // ------------------------------------------------------------------
    // SPI byte engine
    // ------------------------------------------------------------------
    logic       spi_start, spi_busy, spi_done;
    logic [7:0] spi_data;

    spi_byte_master #(.HALF_NUM(SCLK_HALF_NUM), .HALF_DEN(SCLK_HALF_DEN)) u_spi (
        .clk    (clk),
        .rst    (rst),
        .start  (spi_start),
        .data_in(spi_data),
        .sck    (lcd_sck),
        .mosi   (lcd_mosi),
        .busy   (spi_busy),
        .done   (spi_done)
    );

    // ------------------------------------------------------------------
    // Init sequence ROM, {end, delay, is_cmd, byte[7:0]}
    //   {3'b001, b} = command byte (DC = 0)
    //   {3'b000, b} = data byte    (DC = 1)
    //   {3'b010, b} = delay of b milliseconds
    //   {3'b100, b} = end of sequence
    // The sequence itself is the one proven on this board in
    // sample/lcd/lcd_ctrl.v; only MADCTL is exposed as a parameter.
    // Trailing end markers just make the table length non-critical.
    // ------------------------------------------------------------------
    localparam int INIT_LEN = 73;
    localparam logic [10:0] init_rom [0:INIT_LEN-1] = '{
        {3'b001, 8'h01},                         // SWRESET
        {3'b010, 8'd10},                         // delay 10 ms
        {3'b001, 8'h11},                         // SLPOUT
        {3'b010, 8'd120},                        // delay 120 ms
        {3'b001, 8'hC0}, {3'b000, 8'h23},        // PWCTR1
        {3'b001, 8'hC1}, {3'b000, 8'h10},        // PWCTR2
        {3'b001, 8'hC5}, {3'b000, 8'h3E}, {3'b000, 8'h28},  // VMCTR1
        {3'b001, 8'hC7}, {3'b000, 8'h86},        // VMCTR2
        {3'b001, 8'h36}, {3'b000, MADCTL_VALUE}, // MADCTL
        {3'b001, 8'h3A}, {3'b000, 8'h55},        // COLMOD = 16 bpp RGB565
        {3'b001, 8'hB1}, {3'b000, 8'h00}, {3'b000, 8'h1B},  // FRMCTR1
        {3'b001, 8'hB6}, {3'b000, 8'h08}, {3'b000, 8'h82}, {3'b000, 8'h27}, // DISCTRL
        {3'b001, 8'h26}, {3'b000, 8'h01},        // GAMMASET
        {3'b001, 8'hE0},                         // GMCTRP1
        {3'b000, 8'h0F}, {3'b000, 8'h31}, {3'b000, 8'h2B}, {3'b000, 8'h0C},
        {3'b000, 8'h0E}, {3'b000, 8'h08}, {3'b000, 8'h4E}, {3'b000, 8'hF1},
        {3'b000, 8'h37}, {3'b000, 8'h07}, {3'b000, 8'h10}, {3'b000, 8'h03},
        {3'b000, 8'h0E}, {3'b000, 8'h09}, {3'b000, 8'h00},
        {3'b001, 8'hE1},                         // GMCTRN1
        {3'b000, 8'h00}, {3'b000, 8'h0E}, {3'b000, 8'h14}, {3'b000, 8'h03},
        {3'b000, 8'h11}, {3'b000, 8'h07}, {3'b000, 8'h31}, {3'b000, 8'hC1},
        {3'b000, 8'h48}, {3'b000, 8'h08}, {3'b000, 8'h0F}, {3'b000, 8'h0C},
        {3'b000, 8'h31}, {3'b000, 8'h36}, {3'b000, 8'h0F},
        {3'b001, 8'h2A}, {3'b000, 8'h00}, {3'b000, 8'h00},
                         {3'b000, 8'h01}, {3'b000, 8'h3F},  // CASET 0..319
        {3'b001, 8'h2B}, {3'b000, 8'h00}, {3'b000, 8'h00},
                         {3'b000, 8'h01}, {3'b000, 8'hEF},  // PASET 0..239
        {3'b001, 8'h29},                         // DISPON
        {3'b010, 8'd20},                         // delay 20 ms
        {3'b100, 8'h00},                         // END
        {3'b100, 8'h00},
        {3'b100, 8'h00}
    };

    localparam logic [7:0] CMD_CASET = 8'h2A;
    localparam logic [7:0] CMD_PASET = 8'h2B;
    localparam logic [7:0] CMD_RAMWR = 8'h2C;

    // header = CASET(5) + PASET(5) + RAMWR(1) = 11 bytes, indices 0..10
    localparam logic [3:0] HDR_LAST = 4'd10;

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    // 11 states, so 4 bits (a 3-bit enum cannot represent S_DATA onwards)
    typedef enum logic [3:0] {
        S_POWERON,
        S_INIT_STEP, S_INIT_SEND, S_INIT_WAIT, S_INIT_DELAY,
        S_READY,
        S_HDR, S_HDR_W,
        S_DATA, S_DATA_W,
        S_END
    } state_t;

    state_t state;

    logic [6:0]  init_idx;
    logic [31:0] delay_cnt;
    logic        init_done;

    logic [3:0]  hdr_step;
    logic [7:0]  gap_cnt;

    // CS must stay high for at least one SCK period between command trains
    // so the panel can see the end of one write and the start of the next.
    localparam logic [7:0] CS_GAP_CYCLES = 8'd32;

    // ---- latched request -------------------------------------------------
    logic [8:0]  w_x0, w_x1;
    logic [7:0]  w_y0, w_y1;
    logic [15:0] w_color;
    logic [16:0] pix_left;      // pixels still to send in this window
    logic        byte_sel;      // 0 = high byte, 1 = low byte

    wire byte_done = spi_done;

    // window dimensions (a valid window is at least 1x1)
    wire [9:0] w_cnt = {1'b0, w_x1} - {1'b0, w_x0} + 10'd1;   // 1..320
    wire [8:0] h_cnt = {1'b0, w_y1} - {1'b0, w_y0} + 9'd1;    // 1..240

    // The product is held in a wide wire and then sliced: assigning a 19-bit
    // expression straight to a 17-bit wire makes Quartus report a truncation
    // (Warning 10230). Max is 320*240 = 76800, which fits in 17 bits.
    wire [18:0] win_pix_w = w_cnt * h_cnt;
    wire [16:0] win_pix   = win_pix_w[16:0];

    // CASET/PASET high bytes: x can reach 319 (hi = 1), y only reaches 239
    wire [7:0] x0_hi = {7'b000_0000, w_x0[8]};
    wire [7:0] x1_hi = {7'b000_0000, w_x1[8]};

    // a write is accepted only when the controller is idle after init
    assign wr_ready = init_done && (state == S_READY) && !rst;

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= S_POWERON;
            lcd_cs     <= 1'b1;
            lcd_dc     <= 1'b1;
            spi_start  <= 1'b0;
            spi_data   <= 8'h00;
            init_idx   <= '0;
            delay_cnt  <= 32'(POWERON_WAIT_MS) * MS_CYCLES;
            init_done  <= 1'b0;
            hdr_step   <= 4'd0;
            gap_cnt    <= 8'd0;
            w_x0       <= 9'd0;
            w_x1       <= COLS_LAST;
            w_y0       <= 8'd0;
            w_y1       <= ROWS_LAST;
            w_color    <= 16'h0000;
            pix_left   <= 17'd0;
            byte_sel   <= 1'b0;
            wr_done    <= 1'b0;
        end else begin
            spi_start <= 1'b0;
            wr_done   <= 1'b0;

            case (state)
            // ------------------------------------------------- power-on
            // The panel needs VDD to settle before the first command, and
            // the SPI engine needs a clean CS/SCK state too.
            S_POWERON: begin
                lcd_cs <= 1'b1;
                if (delay_cnt == 0) begin
                    init_idx <= '0;
                    lcd_cs   <= 1'b0;
                    state    <= S_INIT_STEP;
                end else begin
                    delay_cnt <= delay_cnt - 1'b1;
                end
            end

            // ------------------------------------------------- init ROM
            S_INIT_STEP: begin
                if (init_idx >= INIT_LEN[6:0]) begin
                    lcd_cs    <= 1'b1;
                    init_done <= 1'b1;
                    state     <= S_READY;
                end else if (init_rom[init_idx][10]) begin
                    // end of sequence
                    lcd_cs    <= 1'b1;
                    init_done <= 1'b1;
                    state     <= S_READY;
                end else if (init_rom[init_idx][9]) begin
                    // delay entry
                    delay_cnt <= 32'(init_rom[init_idx][7:0]) * MS_CYCLES;
                    state     <= S_INIT_DELAY;
                end else begin
                    lcd_dc    <= ~init_rom[init_idx][8];  // is_cmd -> DC low
                    spi_data  <= init_rom[init_idx][7:0];
                    spi_start <= 1'b1;
                    state     <= S_INIT_SEND;
                end
            end

            S_INIT_SEND: begin
                state <= S_INIT_WAIT;
            end

            S_INIT_WAIT: begin
                if (byte_done) begin
                    init_idx <= init_idx + 1'b1;
                    state    <= S_INIT_STEP;
                end
            end

            S_INIT_DELAY: begin
                if (delay_cnt == 0) begin
                    init_idx <= init_idx + 1'b1;   // step past the delay entry
                    state    <= S_INIT_STEP;
                end else begin
                    delay_cnt <= delay_cnt - 1'b1;
                end
            end

            // ------------------------------------------------- idle
            // Accept one rectangle write: latch the window and start the
            // CASET/PASET/RAMWR header. The window is latched here, so the
            // caller is free to change its request immediately.
            S_READY: begin
                lcd_cs <= 1'b1;
                if (wr_valid && wr_ready) begin
                    w_x0     <= wr_x0;
                    w_x1     <= wr_x1;
                    w_y0     <= wr_y0;
                    w_y1     <= wr_y1;
                    w_color  <= wr_color;
                    hdr_step <= 4'd0;
                    byte_sel <= 1'b0;
                    lcd_cs   <= 1'b0;
                    state    <= S_HDR;
                end
            end

            // ------------------------------------- end of write / CS gap
            // Keep CS high for a while so the panel sees a clean break
            // between one command train and the next.
            S_END: begin
                lcd_cs <= 1'b1;
                if (gap_cnt == CS_GAP_CYCLES - 8'd1) begin
                    gap_cnt <= 8'd0;
                    state   <= S_READY;
                end else begin
                    gap_cnt <= gap_cnt + 8'd1;
                end
            end

            // ------------------------------------------------- header
            // 2A x0h x0l x1h x1l  2B y0h y0l y1h y1l  2C
            // The window bytes come from the LATCHED request, not the pins.
            //
            // hdr_step is advanced ONLY in S_HDR_W (after the byte is actually
            // sent). Advancing it here as well would make it step by two,
            // so it would never equal HDR_LAST at the check below and the
            // header would repeat forever.
            S_HDR: begin
                if (!spi_busy && !spi_start) begin
                    case (hdr_step)
                        4'd0: begin lcd_dc <= 1'b0; spi_data <= CMD_CASET; end
                        4'd1: begin lcd_dc <= 1'b1; spi_data <= x0_hi;     end
                        4'd2: begin lcd_dc <= 1'b1; spi_data <= w_x0[7:0]; end
                        4'd3: begin lcd_dc <= 1'b1; spi_data <= x1_hi;     end
                        4'd4: begin lcd_dc <= 1'b1; spi_data <= w_x1[7:0]; end
                        4'd5: begin lcd_dc <= 1'b0; spi_data <= CMD_PASET; end
                        4'd6: begin lcd_dc <= 1'b1; spi_data <= 8'h00;     end
                        4'd7: begin lcd_dc <= 1'b1; spi_data <= w_y0;      end
                        4'd8: begin lcd_dc <= 1'b1; spi_data <= 8'h00;     end
                        4'd9: begin lcd_dc <= 1'b1; spi_data <= w_y1;      end
                        default: begin
                            lcd_dc   <= 1'b0;
                            spi_data <= CMD_RAMWR;
                        end
                    endcase
                    spi_start <= 1'b1;
                    state     <= S_HDR_W;
                end
            end

            // wait for the header byte, then the next one (or the pixels)
            S_HDR_W: begin
                if (byte_done) begin
                    if (hdr_step == HDR_LAST) begin
                        // RAMWR has been sent: set up the pixel stream
                        pix_left <= win_pix;
                        byte_sel <= 1'b0;
                        state    <= S_DATA;
                    end else begin
                        hdr_step <= hdr_step + 4'd1;
                        state    <= S_HDR;
                    end
                end
            end

            // ------------------------------------------------- pixel stream
            // Every pixel of the window is the same colour, so only the
            // window size matters - no memory read is needed per pixel.
            S_DATA: begin
                if (!spi_busy && !spi_start) begin
                    lcd_dc    <= 1'b1;
                    spi_data  <= byte_sel ? w_color[7:0] : w_color[15:8];
                    spi_start <= 1'b1;
                    state     <= S_DATA_W;
                end
            end

            S_DATA_W: begin
                if (byte_done) begin
                    if (!byte_sel) begin
                        byte_sel <= 1'b1;          // send the low byte next
                        state    <= S_DATA;
                    end else begin
                        byte_sel <= 1'b0;
                        pix_left <= pix_left - 17'd1;
                        if (pix_left == 17'd1) begin
                            lcd_cs  <= 1'b1;       // last pixel of the window
                            wr_done <= 1'b1;
                            gap_cnt <= 8'd0;
                            state   <= S_END;
                        end else begin
                            state <= S_DATA;
                        end
                    end
                end
            end

            default: state <= S_POWERON;
            endcase
        end
    end

    assign active = (state == S_HDR)  || (state == S_HDR_W) ||
                    (state == S_DATA) || (state == S_DATA_W);

endmodule
