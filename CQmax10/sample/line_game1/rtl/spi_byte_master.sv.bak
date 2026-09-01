// spi_byte_master.sv
// Minimal write-only SPI master, mode 0 (CPOL=0, CPHA=0), MSB first.
// No MISO: this project only ever writes to the ILI9341.
module spi_byte_master #(
    parameter int HALF_PERIOD = 2   // system clk cycles per SCK half period
)(
    input  logic       clk,
    input  logic       rst,
    input  logic        start,      // pulse (1 cycle) to send data_in
    input  logic [7:0]  data_in,
    output logic         sck,
    output logic         mosi,
    output logic         busy,
    output logic         done        // 1 cycle pulse when byte is finished
);
    localparam int DW = (HALF_PERIOD <= 1) ? 1 : $clog2(HALF_PERIOD);

    typedef enum logic [1:0] {S_IDLE, S_LOW, S_HIGH} state_t;
    state_t state;

    logic [DW-1:0] div_cnt;
    logic          tick;
    logic [7:0]    shreg;
    logic [3:0]    bitcnt;

    assign tick = (div_cnt == DW'(HALF_PERIOD - 1));

    always_ff @(posedge clk) begin
        if (rst) begin
            div_cnt <= '0;
        end else if (state == S_IDLE) begin
            div_cnt <= '0;
        end else if (tick) begin
            div_cnt <= '0;
        end else begin
            div_cnt <= div_cnt + 1'b1;
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

                S_LOW: begin // SCK low half: mosi already valid, wait, then raise SCK
                    if (tick) begin
                        sck   <= 1'b1;
                        state <= S_HIGH;
                    end
                end

                S_HIGH: begin // SCK high half: slave samples here
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
