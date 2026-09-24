// score_manager.sv
//
// Accumulates the game score.  On `add` (1-cycle strobe) with `n` the number of
// erased blocks, the score increases by n*n (per the specification).  The score
// is a 16-bit value, saturated at 16'hFFFF.  `reset_score` clears it to zero.

module score_manager (
    input  logic        clk,
    input  logic        rst,

    input  logic        add,        // strobe: add (n * n) to the score
    input  logic [7:0]  n,          // erased block count

    input  logic        reset_score,// strobe: clear the score

    output logic [15:0] score
);
    logic [15:0] addend;
    logic [16:0] sum;

    // n is at most 192 -> n*n at most 36864 (fits in 16 bits: max 65535)
    assign addend = {8'd0, n} * {8'd0, n};
    assign sum    = {1'b0, score} + {1'b0, addend};

    always_ff @(posedge clk) begin
        if (rst) begin
            score <= 16'd0;
        end else if (reset_score) begin
            score <= 16'd0;
        end else if (add) begin
            score <= (sum[16]) ? 16'hFFFF : sum[15:0];
        end
    end
endmodule
