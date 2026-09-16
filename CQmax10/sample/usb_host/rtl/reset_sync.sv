`default_nettype none

module reset_sync #(
    parameter int STAGES = 2
) (
    input  wire logic clk,
    input  wire logic async_rst_n,
    output logic rst_n
);

    logic [STAGES-1:0] sync;

    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) begin
            sync <= '0;
        end else begin
            sync <= {sync[STAGES-2:0], 1'b1};
        end
    end

    assign rst_n = sync[STAGES-1];

endmodule

`default_nettype wire
