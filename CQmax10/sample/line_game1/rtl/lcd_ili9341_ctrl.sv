// lcd_ili9341_ctrl.sv
// Drives a PMOD-TFTLCD v1.1 (ILI9341, 320x240) over a 4-wire write-only SPI
// bus (CS, SCK, MOSI, D/C). There is no MISO and no dedicated hardware
// RESET pin in this project's pin list, so the panel is reset with the
// ILI9341 SWRESET command (0x01). If your PMOD board ties RESX to a GPIO
// instead of a pull-up, wire that pin externally and hold it high for a
// few ms before releasing `rst` here.
//
// Command interface (single outstanding request, req_ready/req_valid):
//   CMD_INIT      : run the panel init sequence once.
//   CMD_FILL_RECT : fill the rectangle (req_x,req_y,req_w,req_h) with
//                   req_color (RGB565), using a single CASET/PASET/RAMWR
//                   window + streamed pixel burst (fast for both large
//                   clears and 1x1 pixel writes).
//
// MADCTL (landscape orientation) is set to a common default; if the image
// comes out rotated or mirrored on your physical mounting, adjust
// MADCTL_VALUE below (this is exactly the kind of thing that needed
// correcting on the previous PMOD-TFTLCD/ILI9341 bring-up too).
module lcd_ili9341_ctrl #(
    parameter int SCLK_HALF_CYCLES = 2,   // 50MHz/ (2*2) = 12.5 MHz SPI clock
    parameter int SCREEN_W = 320,
    parameter int SCREEN_H = 240,
    parameter logic [7:0] MADCTL_VALUE = 8'h28
)(
    input  logic        clk,
    input  logic        rst,

    input  logic        req_valid,
    output logic        req_ready,
    input  logic [1:0]  req_cmd,      // 2'b01=INIT, 2'b10=FILL_RECT
    input  logic [8:0]  req_x,
    input  logic [7:0]  req_y,
    input  logic [8:0]  req_w,
    input  logic [8:0]  req_h,
    input  logic [15:0] req_color,

    output logic        lcd_cs,
    output logic        lcd_sck,
    output logic        lcd_mosi,
    output logic        lcd_dc
);
    localparam logic [1:0] CMD_NOP  = 2'b00;
    localparam logic [1:0] CMD_INIT = 2'b01;
    localparam logic [1:0] CMD_FILL = 2'b10;

    // ---------------------------------------------------------------
    // SPI byte engine
    // ---------------------------------------------------------------
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

    // ---------------------------------------------------------------
    // Init sequence ROM: {ctrl[1:0], byte[7:0]}
    //   ctrl = 00 -> command byte
    //   ctrl = 01 -> data byte (follows the preceding command)
    //   ctrl = 10 -> delay, byte field = delay in ~1ms units
    //   ctrl = 11 -> end of sequence
    // ---------------------------------------------------------------
    localparam int INIT_LEN = 33;
    logic [9:0] init_rom [0:INIT_LEN-1];
    initial begin
        // NOTE: Quartus supports this initial-block-on-a-ROM pattern for
        // synthesis (it just preloads constant memory contents); it is not
        // the kind of behavioural `initial` block that is unsynthesizable.
        init_rom[0]  = {2'b00, 8'h01};            // SWRESET
        init_rom[1]  = {2'b10, 8'd10};             // delay 10ms
        init_rom[2]  = {2'b00, 8'h11};            // SLPOUT
        init_rom[3]  = {2'b10, 8'd120};            // delay 120ms
        init_rom[4]  = {2'b00, 8'hC0};            // PWCTR1
        init_rom[5]  = {2'b01, 8'h23};
        init_rom[6]  = {2'b00, 8'hC1};            // PWCTR2
        init_rom[7]  = {2'b01, 8'h10};
        init_rom[8]  = {2'b00, 8'hC5};            // VMCTR1
        init_rom[9]  = {2'b01, 8'h3E};
        init_rom[10] = {2'b01, 8'h28};
        init_rom[11] = {2'b00, 8'hC7};            // VMCTR2
        init_rom[12] = {2'b01, 8'h86};
        init_rom[13] = {2'b00, 8'h36};            // MADCTL (orientation/BGR)
        init_rom[14] = {2'b01, MADCTL_VALUE};
        init_rom[15] = {2'b00, 8'h3A};            // COLMOD
        init_rom[16] = {2'b01, 8'h55};             // 16 bpp (RGB565)
        init_rom[17] = {2'b00, 8'hB1};            // FRMCTR1
        init_rom[18] = {2'b01, 8'h00};
        init_rom[19] = {2'b01, 8'h18};
        init_rom[20] = {2'b00, 8'hB6};            // DISCTRL
        init_rom[21] = {2'b01, 8'h08};
        init_rom[22] = {2'b01, 8'h82};
        init_rom[23] = {2'b01, 8'h27};
        init_rom[24] = {2'b00, 8'h2A};            // CASET, full width (init)
        init_rom[25] = {2'b01, 8'h00};
        init_rom[26] = {2'b01, 8'h00};
        init_rom[27] = {2'b01, 8'h01};
        init_rom[28] = {2'b01, 8'h3F};
        init_rom[29] = {2'b00, 8'h29};            // DISPON
        init_rom[30] = {2'b10, 8'd20};             // delay 20ms
        init_rom[31] = {2'b11, 8'h00};            // END
        init_rom[32] = {2'b11, 8'h00};            // (unused, END padding)
    end

    localparam logic [7:0] CMD_CASET = 8'h2A;
    localparam logic [7:0] CMD_PASET = 8'h2B;
    localparam logic [7:0] CMD_RAMWR = 8'h2C;

    // ---------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,
        S_INIT_STEP, S_INIT_DELAY,
        S_SEND, S_SEND_WAIT,
        S_FILL_START,
        S_FILL_STREAM
    } state_t;

    typedef enum logic [3:0] {
        R_INIT_NEXT,
        R_FILL_CASET1, R_FILL_CASET2, R_FILL_CASET3, R_FILL_CASET4,
        R_FILL_PASET1, R_FILL_PASET2, R_FILL_PASET3, R_FILL_PASET4,
        R_FILL_RAMWR, R_FILL_STREAM_ENTRY
    } retid_t;

    state_t state;
    retid_t ret_id;

    logic [5:0]  init_idx;
    logic [31:0] delay_cnt;

    logic [8:0]  fx0, fx1, fy0, fy1;
    logic [16:0] pix_left;     // up to 320*240 = 76800
    logic        pix_byte_sel; // 0 = high byte of RGB565, 1 = low byte
    logic [15:0] fill_color_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            lcd_cs      <= 1'b1;
            lcd_dc      <= 1'b1;
            spi_start   <= 1'b0;
            init_idx    <= '0;
            delay_cnt   <= '0;
            pix_left    <= '0;
            pix_byte_sel<= 1'b0;
        end else begin
            spi_start <= 1'b0;

            case (state)
            // -------------------------------------------------------
            S_IDLE: begin
                lcd_cs <= 1'b1;
                if (req_valid) begin
                    case (req_cmd)
                        CMD_INIT: begin
                            init_idx <= '0;
                            lcd_cs   <= 1'b0;
                            state    <= S_INIT_STEP;
                        end
                        CMD_FILL: begin
                            fx0 <= req_x;
                            fx1 <= req_x + req_w - 9'd1;
                            fy0 <= {1'b0, req_y};
                            fy1 <= {1'b0, req_y} + req_h - 9'd1;
                            fill_color_r <= req_color;
                            pix_left <= req_w * req_h;
                            lcd_cs   <= 1'b0;
                            state    <= S_FILL_START;
                        end
                        default: state <= S_IDLE;
                    endcase
                end
            end

            // ---------------- INIT sequence -------------------------
            S_INIT_STEP: begin
                case (init_rom[init_idx][9:8])
                    2'b00: begin // command byte
                        lcd_dc   <= 1'b0;
                        spi_data <= init_rom[init_idx][7:0];
                        spi_start<= 1'b1;
                        ret_id   <= R_INIT_NEXT;
                        state    <= S_SEND;
                    end
                    2'b01: begin // data byte
                        lcd_dc   <= 1'b1;
                        spi_data <= init_rom[init_idx][7:0];
                        spi_start<= 1'b1;
                        ret_id   <= R_INIT_NEXT;
                        state    <= S_SEND;
                    end
                    2'b10: begin // delay
                        delay_cnt <= init_rom[init_idx][7:0] * (50_000_000/1000);
                        state     <= S_INIT_DELAY;
                    end
                    default: begin // end
                        lcd_cs <= 1'b1;
                        state  <= S_IDLE;
                    end
                endcase
            end

            S_INIT_DELAY: begin
                if (delay_cnt == 0) begin
                    init_idx <= init_idx + 6'd1;
                    state    <= S_INIT_STEP;
                end else begin
                    delay_cnt <= delay_cnt - 1'b1;
                end
            end

            // ---------------- generic byte-send + return ------------
            S_SEND: begin
                state <= S_SEND_WAIT;
            end
            S_SEND_WAIT: begin
                if (spi_done) begin
                    case (ret_id)
                        R_INIT_NEXT: begin
                            init_idx <= init_idx + 6'd1;
                            state    <= S_INIT_STEP;
                        end
                        R_FILL_CASET1: begin lcd_dc<=1'b1; spi_data<=fx0[8:8]?8'h01:8'h00; spi_start<=1'b1; ret_id<=R_FILL_CASET2; state<=S_SEND; end
                        R_FILL_CASET2: begin lcd_dc<=1'b1; spi_data<=fx0[7:0];              spi_start<=1'b1; ret_id<=R_FILL_CASET3; state<=S_SEND; end
                        R_FILL_CASET3: begin lcd_dc<=1'b1; spi_data<=fx1[8:8]?8'h01:8'h00; spi_start<=1'b1; ret_id<=R_FILL_CASET4; state<=S_SEND; end
                        R_FILL_CASET4: begin lcd_dc<=1'b1; spi_data<=fx1[7:0];              spi_start<=1'b1; ret_id<=R_FILL_PASET1; state<=S_SEND; end
                        R_FILL_PASET1: begin
                            lcd_dc<=1'b0; spi_data<=CMD_PASET; spi_start<=1'b1; ret_id<=R_FILL_PASET2; state<=S_SEND;
                        end
                        R_FILL_PASET2: begin lcd_dc<=1'b1; spi_data<=fy0[8:8]?8'h01:8'h00; spi_start<=1'b1; ret_id<=R_FILL_PASET3; state<=S_SEND; end
                        R_FILL_PASET3: begin lcd_dc<=1'b1; spi_data<=fy0[7:0];              spi_start<=1'b1; ret_id<=R_FILL_PASET4; state<=S_SEND; end
                        R_FILL_PASET4: begin lcd_dc<=1'b1; spi_data<=fy1[8:8]?8'h01:8'h00; spi_start<=1'b1; ret_id<=R_FILL_RAMWR; state<=S_SEND; end
                        R_FILL_RAMWR: begin
                            // one more PASET byte was pending (fy1 low), then RAMWR cmd
                            lcd_dc<=1'b1; spi_data<=fy1[7:0]; spi_start<=1'b1; ret_id<=R_FILL_STREAM_ENTRY; state<=S_SEND;
                        end
                        R_FILL_STREAM_ENTRY: begin
                            lcd_dc <= 1'b0;
                            spi_data <= CMD_RAMWR;
                            spi_start<= 1'b1;
                            pix_byte_sel <= 1'b0;
                            ret_id  <= R_FILL_STREAM_ENTRY; // unused after this
                            state   <= S_FILL_STREAM;
                        end
                        default: state <= S_IDLE;
                    endcase
                end
            end

            // ---------------- FILL_RECT: send CASET cmd first -------
            S_FILL_START: begin
                lcd_dc    <= 1'b0;
                spi_data  <= CMD_CASET;
                spi_start <= 1'b1;
                ret_id    <= R_FILL_CASET1;
                state     <= S_SEND;
            end

            // ---------------- FILL_RECT: stream pixel data ----------
            S_FILL_STREAM: begin
                if (spi_busy || spi_start) begin
                    // wait for the RAMWR cmd byte / previous pixel byte to finish
                end else if (pix_left == 0) begin
                    lcd_cs <= 1'b1;
                    state  <= S_IDLE;
                end else begin
                    lcd_dc   <= 1'b1;
                    spi_data <= pix_byte_sel ? fill_color_r[7:0] : fill_color_r[15:8];
                    spi_start<= 1'b1;
                    if (pix_byte_sel) begin
                        pix_byte_sel <= 1'b0;
                        pix_left     <= pix_left - 17'd1;
                    end else begin
                        pix_byte_sel <= 1'b1;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    assign req_ready = (state == S_IDLE) && !rst;

endmodule