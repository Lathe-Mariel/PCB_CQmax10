// =============================================================================
// allpass_filter.sv
// Schroeder allpass filter placed in series after the comb bank in
// reverb.sv, to diffuse/smear the comb outputs and reduce the "metallic
// ringing" that plain comb filters produce on their own.
//
// Per-sample recurrence:
//   bufout     = mem[ptr]
//   out_sample = bufout - in_sample*g
//   mem[ptr]   = in_sample + bufout*g
//
// Same BRAM-inference requirements as comb_filter.sv: `mem` is read and
// written in the SAME always_ff block, and the write happens on the
// clock edge *after* the read (using the registered `rd_data`, never a
// same-cycle read-then-write to the same address -- real BRAM cannot do
// that, and forcing it makes synthesis fall back to flip-flops).
// `out_en`/`out_sample` become valid 2 clk cycles after `smp_en`.
// =============================================================================
module allpass_filter #(
    parameter int DATA_W    = 14,
    parameter int DELAY_LEN = 556,
    parameter int ADDR_W    = $clog2(DELAY_LEN),
    parameter int GAIN_Q8   = 128     // allpass gain, Q8 fixed point (0.5)
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     smp_en,
    input  logic signed [DATA_W-1:0] in_sample,
    output logic                     out_en,
    output logic signed [DATA_W-1:0] out_sample
);

    logic signed [DATA_W-1:0] mem [0:DELAY_LEN-1];
    logic [ADDR_W-1:0]        ptr;

    logic signed [DATA_W-1:0] in_reg;
    logic signed [DATA_W-1:0] rd_data;
    logic                     rd_valid;

    logic signed [DATA_W+9:0] y_wide;
    logic signed [DATA_W-1:0] y_next;
    logic signed [DATA_W+9:0] wr_wide;
    logic signed [DATA_W-1:0] mem_write_val;

    assign y_wide        = rd_data - ((in_reg * GAIN_Q8) >>> 8);
    assign y_next         = y_wide[DATA_W-1:0];
    assign wr_wide        = in_reg + ((rd_data * GAIN_Q8) >>> 8);
    assign mem_write_val  = wr_wide[DATA_W-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            ptr        <= '0;
            out_sample <= '0;
            out_en     <= 1'b0;
            in_reg     <= '0;
            rd_data    <= '0;
            rd_valid   <= 1'b0;
        end else begin
            if (smp_en) begin
                in_reg  <= in_sample;
                rd_data <= mem[ptr];        // read -- same process as the write below
            end
            rd_valid <= smp_en;

            out_en <= rd_valid;
            if (rd_valid) begin
                mem[ptr]   <= mem_write_val;    // write -- same process as the read above
                out_sample <= y_next;
                ptr        <= (ptr == ADDR_W'(DELAY_LEN - 1)) ? '0 : ptr + 1'b1;
            end
        end
    end

endmodule
