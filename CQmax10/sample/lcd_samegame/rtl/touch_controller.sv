// touch_controller.sv
//
// XPT2046 touch-panel controller for the PMOD-TFTLCD v1.1 (ILI9341 + touch).
//
// Interface (tentative pin assignment, see samegame-top comment):
//   touch_cs   -> PIN_134   (T_CS,  active low)
//   touch_mosi -> PIN_135   (T_DIN, control byte out)
//   touch_miso -> PIN_132   (T_DO,  12-bit ADC result in)
//   touch_sck  -> PIN_130   (T_CLK, SPI clock)
//
// Protocol (24 clocks per conversion):
//   Phase 1 (clk 1..8)  : 8-bit control byte on DIN
//   Phase 2 (clk 9..11) : acquisition (DOUT undefined)
//   Phase 3 (clk 12..23): 12-bit ADC result on DOUT, MSB first
//   Phase 4 (clk 24)    : trailing zeros (ignored)
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
    parameter logic [11:0] TOUCH_THRESH = 12'd100,
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

    // touch status to the game FSM
    output logic        touch_valid,
    output logic [8:0]  touch_x,      // 0..319
    output logic [7:0]  touch_y,      // 0..239
    output logic        touch_down,   // 1-cycle pulse
    output logic        touch_up      // 1-cycle pulse
);
    localparam int MS_CYCLES = (CLK_FREQ_HZ / 1000) / MS_SCALE;
    localparam int SAMPLE_PERIOD = MS_CYCLES * SAMPLE_MS;

    localparam logic [7:0] CMD_X  = 8'hD0;
    localparam logic [7:0] CMD_Y  = 8'h90;
    localparam logic [7:0] CMD_Z1 = 8'hB0;

    // ---- SPI bit clock divider (clk/32 -> 1.5625 MHz) ----
    logic [4:0] clk_div;
    wire spi_clk_rise = (clk_div == 5'd15);
    wire spi_clk_fall = (clk_div == 5'd31);
    always_ff @(posedge clk) begin
        if (rst) clk_div <= 5'd0;
        else     clk_div <= clk_div + 5'd1;
    end

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
    logic [7:0]  spi_cmd;
    logic        spi_start;
    logic        spi_busy;
    logic [5:0]  spi_bit;       // clock count 0..23
    logic [11:0] spi_result;
    logic [7:0]  shift_out;
    logic [11:0] shift_in;

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
        end else if (spi_start && !spi_busy) begin
            touch_cs   <= 1'b0;
            touch_sck  <= 1'b0;
            spi_busy   <= 1'b1;
            spi_bit    <= 6'd0;
            shift_out  <= spi_cmd;
            shift_in   <= 12'd0;
            touch_mosi <= spi_cmd[7];
        end else if (spi_busy) begin
            if (spi_clk_rise) begin
                touch_sck <= 1'b1;
                if (spi_bit >= 6'd9 && spi_bit <= 6'd20)
                    shift_in <= {shift_in[10:0], touch_miso};
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
                end
            end
        end
    end

    // ---- coordinate conversion (ADC -> LCD) ----
    function automatic [8:0] adc_to_x(input logic [11:0] raw);
        logic [23:0] tmp;
        if (raw <= X_ADC_MIN)      return 9'd319;
        else if (raw >= X_ADC_MAX) return 9'd0;
        else begin
            tmp = (X_ADC_MAX - raw) * 24'd319;
            return tmp[21:13];
        end
    endfunction

    function automatic [7:0] adc_to_y(input logic [11:0] raw);
        logic [23:0] tmp;
        if (raw <= Y_ADC_MIN)      return 8'd239;
        else if (raw >= Y_ADC_MAX) return 8'd0;
        else begin
            tmp = (Y_ADC_MAX - raw) * 24'd239;
            return tmp[20:13];
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
endmodule
