// spi_byte_master.sv
// Minimal write-only SPI master, mode 0 (CPOL=0, CPHA=0), MSB first.
// No MISO: this project only ever writes to the ILI9341.
//
// ---------------------------------------------------------------------------
// CLOCK DIVIDER (rational)
// ---------------------------------------------------------------------------
// The SCK half period is HALF_NUM / HALF_DEN system clock cycles, so the SCK
// frequency is
//
//     f_sck = f_clk * HALF_DEN / (2 * HALF_NUM)
//
// It is deliberately a RATIONAL ratio rather than an integer divider: from a
// 50 MHz clock an integer divider can only give 25, 12.5, 8.33, 6.25 MHz ...
// and the ILI9341 datasheet write limit is 10 MHz, which is NOT in that list.
// With a fraction we can hit it exactly:
//
//     10 MHz  <-  half period = 2.5 clk  <-  HALF_NUM = 5, HALF_DEN = 2
//
// The half period follows the accumulator, so for 5/2 the LOW half is 3 clk
// and the HIGH half is 2 clk (4 clk and 1 clk per bit respectively), giving an
// average bit period of exactly 5 clk = 100 ns, i.e. 10 MHz. Both halves stay
// at 2 clk (40 ns) or more, satisfying the panel's minimum pulse width.
//
// HALF_DEN = 1 reproduces a plain integer divider, so older parameter sets
// (and the existing testbenches) keep working unchanged.

module spi_byte_master #(
    parameter int HALF_NUM = 2,        // SCK half period = HALF_NUM / HALF_DEN clk
    parameter int HALF_DEN = 1
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       start,          // 1-cycle pulse: send data_in
    input  logic [7:0] data_in,
    output logic       sck,
    output logic       mosi,
    output logic       busy,
    output logic       done            // 1-cycle pulse when the byte is finished
);
    // the accumulator must hold up to HALF_NUM + HALF_DEN - 1
    localparam int AW = ((HALF_NUM + HALF_DEN) <= 2)
                      ? 2 : ($clog2(HALF_NUM + HALF_DEN) + 1);

    localparam int HALF_NUM_I = (HALF_NUM < 1) ? 1 : HALF_NUM;
    localparam int HALF_DEN_I = (HALF_DEN < 1) ? 1 : HALF_DEN;
    localparam logic [AW-1:0] NUM = HALF_NUM_I[AW-1:0];
    localparam logic [AW-1:0] DEN = HALF_DEN_I[AW-1:0];

    typedef enum logic [1:0] {S_IDLE, S_LOW, S_HIGH} state_t;
    state_t state;

    logic [AW-1:0] acc;
    logic          tick;
    logic [7:0]    shreg;
    logic [3:0]    bitcnt;

    // tick on the cycle the accumulator reaches or passes the half period
    assign tick = ((acc + DEN) >= NUM);

    always_ff @(posedge clk) begin
        if (rst) begin
            acc <= '0;
        end else if (state == S_IDLE) begin
            acc <= '0;
        end else if (tick) begin
            acc <= acc + DEN - NUM;      // keep the fractional remainder
        end else begin
            acc <= acc + DEN;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            sck    <= 1'b0;
            mosi   <= 1'b0;
            busy   <= 1'b0;
            done   <= 1'b0;
            shreg  <= 8'h00;
            bitcnt <= 4'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    sck <= 1'b0;
                    if (start) begin
                        shreg  <= data_in;
                        mosi   <= data_in[7];
                        bitcnt <= 4'd8;
                        busy   <= 1'b1;
                        state  <= S_LOW;
                    end
                end

                S_LOW: begin // SCK low half: MOSI is already valid
                    if (tick) begin
                        sck   <= 1'b1;
                        state <= S_HIGH;
                    end
                end

                S_HIGH: begin // SCK high half: the panel samples here
                    if (tick) begin
                        sck <= 1'b0;
                        if (bitcnt == 4'd1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            shreg  <= {shreg[6:0], 1'b0};
                            mosi   <= shreg[6];
                            bitcnt <= bitcnt - 4'd1;
                            state  <= S_LOW;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
