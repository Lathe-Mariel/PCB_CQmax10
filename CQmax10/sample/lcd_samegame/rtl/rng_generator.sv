// rng_generator.sv
//
// Simple 16-bit LFSR pseudo-random generator, used to produce the initial
// board.  Each call to `next` (1-cycle strobe) advances the LFSR and presents
// a fresh value on `rng`.  The game only uses `rng % 5` as a logo id, so the
// exact distribution is not critical, but a maximal-length LFSR is used anyway
// to avoid short cycles.
//
// Fibonacci (many-to-one) LFSR with the primitive polynomial
//   x^16 + x^14 + x^13 + x^11 + 1
// i.e. tap bits at positions 16, 14, 13, 11 -> indices 15, 13, 12, 10.

module rng_generator (
    input  logic        clk,
    input  logic        rst,
    input  logic        seed,     // strobe: load SEED_VALUE
    input  logic        next,     // strobe: advance one step
    output logic [15:0] rng
);
    localparam logic [15:0] SEED_VALUE = 16'hACE1;

    logic feedback;

    assign feedback = rng[15] ^ rng[13] ^ rng[12] ^ rng[10];

    always_ff @(posedge clk) begin
        if (rst) begin
            rng <= SEED_VALUE;
        end else if (seed) begin
            rng <= SEED_VALUE;
        end else if (next) begin
            rng <= { rng[14:0], feedback };
        end
    end
endmodule
