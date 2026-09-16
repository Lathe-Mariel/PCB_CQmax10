`default_nettype none

module jtag_uart_tx #(
    parameter int WRITE_FIFO_DEPTH = 64,
    parameter int READ_FIFO_DEPTH  = 64
) (
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic [7:0]  tx_data,
    input  wire logic        tx_valid,
    output logic        tx_ready,
    output logic        stalled,
    output logic [15:0] last_wspace
);

    localparam int WR_WIDTHU = $clog2(WRITE_FIFO_DEPTH);
    localparam int RD_WIDTHU = $clog2(READ_FIFO_DEPTH);

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_READ_CONTROL,
        ST_WRITE_DATA
    } state_t;

    state_t      state;
    logic [7:0]  tx_buf;
    logic        av_address;
    logic        av_chipselect;
    logic        av_read_n;
    logic        av_write_n;
    logic [31:0] av_writedata;
    wire  [31:0] av_readdata;
    wire         av_waitrequest;
    wire         av_irq;

    assign tx_ready = (state == ST_IDLE);

    always_comb begin
        av_address    = 1'b0;
        av_chipselect = 1'b0;
        av_read_n     = 1'b1;
        av_write_n    = 1'b1;
        av_writedata  = {24'h000000, tx_buf};

        unique case (state)
            ST_READ_CONTROL: begin
                av_address    = 1'b1;
                av_chipselect = 1'b1;
                av_read_n     = 1'b0;
            end
            ST_WRITE_DATA: begin
                av_address    = 1'b0;
                av_chipselect = 1'b1;
                av_write_n    = 1'b0;
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            tx_buf      <= 8'h00;
            stalled     <= 1'b0;
            last_wspace <= 16'd0;
        end else begin
            unique case (state)
                ST_IDLE: begin
                    stalled <= 1'b0;
                    if (tx_valid) begin
                        tx_buf <= tx_data;
                        state  <= ST_READ_CONTROL;
                    end
                end

                ST_READ_CONTROL: begin
                    if (!av_waitrequest) begin
                        last_wspace <= av_readdata[31:16];
                        if (av_readdata[31:16] != 16'd0) begin
                            stalled <= 1'b0;
                            state   <= ST_WRITE_DATA;
                        end else begin
                            stalled <= 1'b1;
                        end
                    end
                end

                ST_WRITE_DATA: begin
                    if (!av_waitrequest) begin
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    altera_avalon_jtag_uart #(
        .writeBufferDepth           (WRITE_FIFO_DEPTH),
        .readBufferDepth            (READ_FIFO_DEPTH),
        .writeIRQThreshold          (8),
        .readIRQThreshold           (8),
        .useRegistersForReadBuffer  (0),
        .useRegistersForWriteBuffer (0),
        .FIFO_WIDTH                 (8),
        .WR_WIDTHU                  (WR_WIDTHU),
        .RD_WIDTHU                  (RD_WIDTHU),
        .write_le                   ("ON"),
        .read_le                    ("ON"),
        .HEX_WRITE_DEPTH_STR        (WRITE_FIFO_DEPTH),
        .HEX_READ_DEPTH_STR         (READ_FIFO_DEPTH)
    ) u_jtag_uart (
        .clk            (clk),
        .rst_n          (rst_n),
        .av_address     (av_address),
        .av_chipselect  (av_chipselect),
        .av_read_n      (av_read_n),
        .av_write_n     (av_write_n),
        .av_writedata   (av_writedata),
        .av_irq         (av_irq),
        .av_readdata    (av_readdata),
        .av_waitrequest (av_waitrequest)
    );

endmodule

`default_nettype wire
