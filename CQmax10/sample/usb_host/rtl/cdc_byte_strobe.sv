`default_nettype none

module cdc_byte_strobe #(
    parameter int WIDTH = 8
) (
    input  wire logic             src_clk,
    input  wire logic             src_rst_n,
    input  wire logic [WIDTH-1:0] src_data,
    input  wire logic             src_valid,
    output logic             src_ready,
    output logic             overflow,

    input  wire logic             dst_clk,
    input  wire logic             dst_rst_n,
    output logic [WIDTH-1:0] dst_data,
    output logic             dst_valid,
    input  wire logic             dst_ready
);

    logic [WIDTH-1:0] data_hold;
    logic             req_toggle;
    logic             ack_toggle;
    logic [1:0]       ack_sync;
    logic [1:0]       req_sync;
    logic             req_seen;

    wire ack_seen = (ack_sync[1] == req_toggle);

    assign src_ready = ack_seen;

    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            data_hold  <= '0;
            req_toggle <= 1'b0;
            ack_sync   <= 2'b00;
            overflow   <= 1'b0;
        end else begin
            ack_sync <= {ack_sync[0], ack_toggle};

            if (src_valid) begin
                if (ack_seen) begin
                    data_hold  <= src_data;
                    req_toggle <= ~req_toggle;
                end else begin
                    overflow <= 1'b1;
                end
            end
        end
    end

    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            req_sync   <= 2'b00;
            req_seen   <= 1'b0;
            ack_toggle <= 1'b0;
            dst_data   <= '0;
            dst_valid  <= 1'b0;
        end else begin
            req_sync <= {req_sync[0], req_toggle};

            if (dst_valid && dst_ready) begin
                dst_valid  <= 1'b0;
                ack_toggle <= req_seen;
            end

            if (!dst_valid && (req_sync[1] != req_seen)) begin
                dst_data  <= data_hold;
                dst_valid <= 1'b1;
                req_seen  <= req_sync[1];
            end
        end
    end

endmodule

`default_nettype wire
