// =============================================================================
// reverb.sv
// Small Freeverb-style reverb: 3 parallel lowpass-feedback comb filters
// summed together, followed by 1 series allpass filter for diffusion,
// then mixed with the dry signal. All three comb filters and the allpass
// filter use BRAM-inferred delay lines (see comb_filter.sv / allpass_filter.sv).
//
// Comb delay lengths (1116, 1277, 1422 samples) are taken from the
// classic Freeverb tuning (mutually prime-ish, avoids strong resonant
// coloration); the allpass length (556 samples) likewise. All scaled for
// this design's ~48kHz internal sample rate.
//
// Pipeline latency: each comb stage adds 2 clk cycles, the allpass stage
// adds 2 more, so the wet path is valid 4 clk cycles after `smp_en`. This
// is negligible compared to the ~1000+ clock audio sample period. Because
// `dry_sample` is itself held constant between `smp_en` pulses (it comes
// from registers that only update on `smp_en`), it can be used directly
// in the final mix without any extra delay-matching logic.
//
// NOTE: the comb/allpass delay-line RAMs have no defined power-up content
// (ordinary BRAM, not a ROM), so there may be a few seconds of very faint
// residual noise in the reverb tail right after configuration/reset before
// it settles -- a minor cosmetic effect of skipping `initial` blocks, not
// a functional defect (the feedback gain is <1, so it decays away).
// =============================================================================
module reverb #(
    parameter int DATA_W = 14
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     smp_en,
    input  logic signed [DATA_W-1:0] dry_sample,
    output logic                     out_en,
    output logic signed [DATA_W-1:0] out_sample
);

    localparam int FB_GAIN_Q8 = 215;   // ~0.84, comb feedback ("room size")
    localparam int DAMP_Q8    = 51;    // ~0.20, comb damping (HF absorption)
    localparam int DRY_GAIN_Q8 = 90;   // ~0.35
    localparam int WET_GAIN_Q8 = 166;  // ~0.65

    // ---------------------------------------------------------------
    // Comb bank (parallel, all fed the same dry input/smp_en)
    // ---------------------------------------------------------------
    logic c0_en, c1_en, c2_en;
    logic signed [DATA_W-1:0] c0_out, c1_out, c2_out;

    comb_filter #(
        .DATA_W(DATA_W), .DELAY_LEN(1116), .FB_GAIN_Q8(FB_GAIN_Q8), .DAMP_Q8(DAMP_Q8)
    ) u_comb0 (
        .clk(clk), .rst(rst), .smp_en(smp_en),
        .in_sample(dry_sample), .out_en(c0_en), .out_sample(c0_out)
    );

    comb_filter #(
        .DATA_W(DATA_W), .DELAY_LEN(1277), .FB_GAIN_Q8(FB_GAIN_Q8), .DAMP_Q8(DAMP_Q8)
    ) u_comb1 (
        .clk(clk), .rst(rst), .smp_en(smp_en),
        .in_sample(dry_sample), .out_en(c1_en), .out_sample(c1_out)
    );

    comb_filter #(
        .DATA_W(DATA_W), .DELAY_LEN(1422), .FB_GAIN_Q8(FB_GAIN_Q8), .DAMP_Q8(DAMP_Q8)
    ) u_comb2 (
        .clk(clk), .rst(rst), .smp_en(smp_en),
        .in_sample(dry_sample), .out_en(c2_en), .out_sample(c2_out)
    );

    // All three combs share identical internal pipeline depth and are
    // triggered by the same smp_en, so their out_en pulses land together.
    logic comb_sum_en;
    logic signed [DATA_W+1:0] comb_sum_wide;
    logic signed [DATA_W-1:0] comb_sum;

    assign comb_sum_en  = c0_en;
    assign comb_sum_wide = c0_out + c1_out + c2_out;
    assign comb_sum      = comb_sum_wide >>> 2;   // /4 headroom (sum of 3 could exceed single range)

    // ---------------------------------------------------------------
    // Series allpass (diffusion)
    // ---------------------------------------------------------------
    logic ap_en;
    logic signed [DATA_W-1:0] ap_out;

    allpass_filter #(
        .DATA_W(DATA_W), .DELAY_LEN(556), .GAIN_Q8(128)
    ) u_allpass (
        .clk(clk), .rst(rst), .smp_en(comb_sum_en),
        .in_sample(comb_sum), .out_en(ap_en), .out_sample(ap_out)
    );

    // ---------------------------------------------------------------
    // Dry / wet mix
    // ---------------------------------------------------------------
    logic signed [DATA_W+9:0] mix_wide;

    assign mix_wide = (dry_sample * DRY_GAIN_Q8) + (ap_out * WET_GAIN_Q8);

    always_ff @(posedge clk) begin
        if (rst) begin
            out_en     <= 1'b0;
            out_sample <= '0;
        end else begin
            out_en <= ap_en;
            if (ap_en)
                out_sample <= (mix_wide >>> 8);
        end
    end

endmodule
