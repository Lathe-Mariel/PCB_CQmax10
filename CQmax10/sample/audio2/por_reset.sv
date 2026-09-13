// =============================================================================
// por_reset.sv
// Synchronous power-on reset generator.
//
// On Gowin (and other SRAM-based FPGAs) a register's declared default value
// is realized as the device's power-up SRAM state, not a simulation-only
// "initial" construct, so it is safe to rely on here purely for the counter
// used to build a clean synchronous reset pulse after configuration.
// No behavioral `initial begin ... end` blocks are used anywhere.
// =============================================================================
module por_reset #(
    parameter int WIDTH = 6            // 64 clk cycles of reset after config
) (
    input  logic clk,
    output logic rst
);

    logic [WIDTH-1:0] cnt = '0;

    always_ff @(posedge clk) begin
        if (!(&cnt))
            cnt <= cnt + 1'b1;
    end

    assign rst = ~(&cnt);

endmodule
