// =============================================================================
// comb_filter.sv
// Lowpass-feedback comb filter (Freeverb-style) used as one branch of the
// parallel comb bank inside reverb.sv.
//
// Per-sample recurrence (classic "LBCF" used by Schroeder/Freeverb):
//   bufout      = mem[ptr]
//   filterstore = bufout*(1-damp) + filterstore*damp     (one-pole lowpass)
//   mem[ptr]    = in_sample + filterstore*feedback
//   out_sample  = bufout
//
// IMPORTANT for BRAM inference (this took two attempts to get right):
//   1) The read and write of `mem` must be coded in the SAME always_ff
//      block. Splitting them into two separate always blocks breaks the
//      inferable-RAM template that Quartus/Vivado/Gowin look for.
//   2) The write must NOT depend, in the same clock edge, on a value
//      just read from the same block-RAM address in that same edge --
//      real BRAM primitives have (at least) one cycle of read latency,
//      so a same-cycle "read old value, immediately compute and write
//      the new value" is not something any BRAM primitive can do, and
//      synthesis falls back to individual flip-flops (this is exactly
//      what Quartus error 276003 -- "cannot convert registers into RAM
//      megafunctions" -- means).
// The structure below satisfies both: read and write live in one
// process, but the write happens on the clock edge *after* the read
// (using the registered `rd_data`, not a same-cycle blocking pre-read).
//
// Timing: `smp_en` is a single-cycle pulse marking a new input sample.
// `out_en`/`out_sample` become valid 2 clk cycles later -- far shorter
// than the ~1000+ clock audio sample period, so no special handling is
// needed downstream beyond using `out_en` to know when data is fresh.
// =============================================================================
module comb_filter #(
    parameter int DATA_W     = 14,
    parameter int DELAY_LEN  = 1116,
    parameter int ADDR_W     = $clog2(DELAY_LEN),
    parameter int FB_GAIN_Q8 = 215,   // feedback gain,  Q8 fixed point (~0.84)
    parameter int DAMP_Q8    = 51     // damping coeff., Q8 fixed point (~0.20)
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     smp_en,
    input  logic signed [DATA_W-1:0] in_sample,
    output logic                     out_en,
    output logic signed [DATA_W-1:0] out_sample
);

    // Delay line (inferred as Block RAM for these sizes)
    logic signed [DATA_W-1:0] mem [0:DELAY_LEN-1];
    logic [ADDR_W-1:0]        ptr;
    logic signed [DATA_W-1:0] filterstore;

    logic signed [DATA_W-1:0] in_reg;
    logic signed [DATA_W-1:0] rd_data;
    logic                     rd_valid;   // pulses 1 clk after smp_en: rd_data is fresh

    // Combinational helpers (do NOT touch `mem` -- only registers below do)
    logic signed [DATA_W+9:0] fstore_wide;
    logic signed [DATA_W-1:0] fstore_next;
    logic signed [DATA_W+9:0] wr_wide;
    logic signed [DATA_W-1:0] mem_write_val;

    assign fstore_wide   = rd_data * (256 - DAMP_Q8) + filterstore * DAMP_Q8;
    assign fstore_next   = fstore_wide >>> 8;
    assign wr_wide        = in_reg + ((fstore_next * FB_GAIN_Q8) >>> 8);
    assign mem_write_val  = wr_wide[DATA_W-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            ptr         <= '0;
            filterstore <= '0;
            out_sample  <= '0;
            out_en      <= 1'b0;
            in_reg      <= '0;
            rd_data     <= '0;
            rd_valid    <= 1'b0;
        end else begin
            // Stage 1 (on smp_en): capture the input sample, read mem[ptr]
            if (smp_en) begin
                in_reg  <= in_sample;
                rd_data <= mem[ptr];        // read -- same process as the write below
            end
            rd_valid <= smp_en;

            // Stage 2 (1 clk later, on rd_valid): filter, write, output
            out_en <= rd_valid;
            if (rd_valid) begin
                filterstore <= fstore_next;
                mem[ptr]    <= mem_write_val;   // write -- same process as the read above
                out_sample  <= rd_data;
                ptr         <= (ptr == ADDR_W'(DELAY_LEN - 1)) ? '0 : ptr + 1'b1;
            end
        end
    end

endmodule
