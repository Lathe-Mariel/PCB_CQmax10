// reset_sync.sv
// Synchronizes the external active-low reset button (btn_rst, pin 17) into
// an internal synchronous, active-high reset.
// ASSUMPTION: btn_rst is pulled high externally, pressed = 0 (active low).
module reset_sync #(
    parameter int SYNC_STAGES = 3
)(
    input  logic clk,
    input  logic btn_rst_n,   // raw pin, active low
    output logic rst          // internal, synchronous, active high
);
    logic [SYNC_STAGES-1:0] sync_ff;

    always_ff @(posedge clk or negedge btn_rst_n) begin
        if (!btn_rst_n)
            sync_ff <= '0;
        else
            sync_ff <= {sync_ff[SYNC_STAGES-2:0], 1'b1};
    end

    assign rst = ~sync_ff[SYNC_STAGES-1];
endmodule
