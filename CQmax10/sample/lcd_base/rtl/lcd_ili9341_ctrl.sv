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
// command), then accepts whole-frame requests:
//
//   req_valid / req_ready / req_cmd = CMD_FRAME
//       Sets a full-screen 320x240 CASET/PASET window, issues RAMWR and
//       streams one entire frame, pixel by pixel, in row-major order
//       (column fastest) - the order the ILI9341 expects.
//
// Each pixel is fetched over the `pix_*` port so the frame source can be
// anything; here it is the 1-bit frame buffer plus a colour LUT.
//
//   assert pix_req for one clk with pix_x/pix_y valid
//   2 clk later pix_valid is asserted for one clk with pix_color valid
//
// Timing: SCK = clk / (2*SCLK_HALF_CYCLES) = 12.5 MHz for HALF_CYCLES = 2.
// 16 bits/pixel * 4 clk/bit = 64 clk/pixel, plus a few clk of handshake, so
// a full 76800-pixel frame takes about 105 ms (~9 fps). Lengthen the frame
// period at the top level rather than trying to go faster.

module lcd_ili9341_ctrl #(
    parameter int          SCLK_HALF_CYCLES = 2,   // 50 MHz / (2*2) = 12.5 MHz
    parameter int          CLK_FREQ_HZ      = 50_000_000,
    parameter int          SCREEN_W         = 320,
    parameter int          SCREEN_H         = 240,
    parameter int          POWERON_WAIT_MS  = 150,
    parameter int          MS_SCALE         = 1,   // 1 in hardware; divide delays for simulation
    parameter logic [7:0]  MADCTL_VALUE     = 8'h28 // landscape (see README)
)(
    input  logic        clk,
    input  logic        rst,

    input  logic        req_valid,
    output logic        req_ready,
    input  logic [1:0]  req_cmd,        // 2'b10 = FRAME

    // pixel source (frame buffer scan-out)
    output logic        pix_req,
    output logic [8:0]  pix_x,
    output logic [7:0]  pix_y,
    input  logic [15:0] pix_color,
    input  logic        pix_valid,

    output logic        active,         // 1 while a frame transfer is running
    output logic        frame_done,     // 1-cycle pulse when a frame is finished

    output logic        lcd_cs,
    output logic        lcd_sck,
    output logic        lcd_mosi,
    output logic        lcd_dc
);
    localparam logic [1:0] CMD_FRAME = 2'b10;

    localparam int COLS_LAST_I = SCREEN_W - 1;                 // 319
    localparam int ROWS_LAST_I = SCREEN_H - 1;                 // 239
    localparam int NPIX_I      = SCREEN_W * SCREEN_H;          // 76800
    localparam logic [8:0]  COLS_LAST = COLS_LAST_I[8:0];
    localparam logic [7:0]  ROWS_LAST = ROWS_LAST_I[7:0];
    localparam logic [16:0] NPIX      = NPIX_I[16:0];

    // the CASET/PASET high bytes are only ever 0 or 1 for this panel
    localparam logic [7:0] COLS_LAST_HI = (COLS_LAST[8]) ? 8'h01 : 8'h00;
    localparam logic [7:0] ROWS_LAST_HI = (ROWS_LAST > 8'hFF) ? 8'h01 : 8'h00;

    localparam int MS_CYCLES = (CLK_FREQ_HZ / 1000) / MS_SCALE;

    // ------------------------------------------------------------------
    // SPI byte engine
    // ------------------------------------------------------------------
    logic       spi_start, spi_busy, spi_done;
    logic [7:0] spi_data;

    spi_byte_master #(.HALF_PERIOD(SCLK_HALF_CYCLES)) u_spi (
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

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_POWERON,
        S_INIT_STEP, S_INIT_SEND, S_INIT_WAIT, S_INIT_DELAY,
        S_READY,
        S_FRAME_HDR,
        S_SCAN_REQ, S_SCAN_WAIT, S_SCAN_TX, S_SCAN_TXW,
        S_FRAME_END
    } state_t;

    state_t state;

    logic [6:0]  init_idx;
    logic [31:0] delay_cnt;
    logic        init_done;

    logic [3:0]  hdr_step;
    logic [7:0]  gap_cnt;

    // CS must stay high for at least one SCK period between command trains
    // so the panel can see the end of the frame and the start of the next one.
    localparam logic [7:0] CS_GAP_CYCLES = 8'd32;

    logic [8:0]  col_cnt;
    logic [7:0]  row_cnt;
    logic [16:0] pix_left;
    logic        byte_sel;
    logic [15:0] cur_color;

    // one-cycle strobe when the byte in spi_data has just been shifted out
    wire byte_done = spi_done;

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
            col_cnt    <= 9'd0;
            row_cnt    <= 8'd0;
            pix_left   <= 17'd0;
            byte_sel   <= 1'b0;
            cur_color  <= 16'h0000;
            pix_req    <= 1'b0;
            pix_x      <= 9'd0;
            pix_y      <= 8'd0;
            frame_done <= 1'b0;
        end else begin
            spi_start  <= 1'b0;
            pix_req    <= 1'b0;
            frame_done <= 1'b0;

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
            S_READY: begin
                lcd_cs <= 1'b1;
                if (req_valid && req_cmd == CMD_FRAME) begin
                    hdr_step <= 4'd0;
                    col_cnt  <= 9'd0;
                    row_cnt  <= 8'd0;
                    pix_left <= NPIX;
                    byte_sel <= 1'b0;
                    lcd_cs   <= 1'b0;
                    state    <= S_FRAME_HDR;
                end
            end

            // ------------------------------------- end of frame / CS gap
            // Keep CS high for a while so the panel sees a clean break
            // between one frame's command train and the next one's.
            S_FRAME_END: begin
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
            S_FRAME_HDR: begin
                if (!spi_busy && !spi_start) begin
                    case (hdr_step)
                        4'd0: begin lcd_dc <= 1'b0; spi_data <= CMD_CASET;          end
                        4'd1: begin lcd_dc <= 1'b1; spi_data <= 8'h00;              end
                        4'd2: begin lcd_dc <= 1'b1; spi_data <= 8'h00;              end
                        4'd3: begin lcd_dc <= 1'b1; spi_data <= COLS_LAST_HI;        end
                        4'd4: begin lcd_dc <= 1'b1; spi_data <= COLS_LAST[7:0];     end
                        4'd5: begin lcd_dc <= 1'b0; spi_data <= CMD_PASET;          end
                        4'd6: begin lcd_dc <= 1'b1; spi_data <= 8'h00;              end
                        4'd7: begin lcd_dc <= 1'b1; spi_data <= 8'h00;              end
                        4'd8: begin lcd_dc <= 1'b1; spi_data <= ROWS_LAST_HI;        end
                        4'd9: begin lcd_dc <= 1'b1; spi_data <= ROWS_LAST[7:0];     end
                        default: begin
                            lcd_dc   <= 1'b0;
                            spi_data <= CMD_RAMWR;
                            state    <= S_SCAN_REQ;
                        end
                    endcase
                    spi_start <= 1'b1;
                    hdr_step  <= hdr_step + 4'd1;
                end
            end

            // ------------------------------------------------- scan-out
            S_SCAN_REQ: begin
                if (pix_left == 17'd0) begin
                    lcd_cs  <= 1'b1;
                    gap_cnt <= 8'd0;
                    state   <= S_FRAME_END;
                end else begin
                    pix_req <= 1'b1;               // 1-cycle request pulse
                    pix_x   <= col_cnt;
                    pix_y   <= row_cnt;
                    state   <= S_SCAN_WAIT;
                end
            end

            S_SCAN_WAIT: begin
                if (pix_valid) begin
                    cur_color <= pix_color;
                    state     <= S_SCAN_TX;
                end
            end

            S_SCAN_TX: begin
                if (!spi_busy && !spi_start) begin
                    lcd_dc    <= 1'b1;
                    spi_data  <= byte_sel ? cur_color[7:0] : cur_color[15:8];
                    spi_start <= 1'b1;
                    state     <= S_SCAN_TXW;
                end
            end

            S_SCAN_TXW: begin
                if (byte_done) begin
                    if (!byte_sel) begin
                        byte_sel <= 1'b1;          // send the low byte next
                        state    <= S_SCAN_TX;
                    end else begin
                        byte_sel <= 1'b0;
                        pix_left <= pix_left - 17'd1;
                        if (col_cnt == COLS_LAST) begin
                            col_cnt <= 9'd0;
                            row_cnt <= row_cnt + 8'd1;
                        end else begin
                            col_cnt <= col_cnt + 9'd1;
                        end
                        if (pix_left == 17'd1) begin
                            lcd_cs     <= 1'b1;    // last pixel of the frame
                            frame_done <= 1'b1;
                            gap_cnt    <= 8'd0;
                            state      <= S_FRAME_END;
                        end else begin
                            state <= S_SCAN_REQ;
                        end
                    end
                end
            end

            default: state <= S_POWERON;
            endcase
        end
    end

    assign req_ready = init_done && (state == S_READY) && !rst;
    assign active    = (state == S_FRAME_HDR) ||
                       (state == S_SCAN_REQ)  ||
                       (state == S_SCAN_WAIT) ||
                       (state == S_SCAN_TX)   ||
                       (state == S_SCAN_TXW);

endmodule
