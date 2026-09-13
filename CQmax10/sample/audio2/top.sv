// =============================================================================
// top.sv
// Tang Primer 25K + PMOD-AUDIO v1.2 : plays the "Intel Inside" style chime
// =============================================================================
module top (
    input  logic clk,          // 50 MHz system clock (core-board oscillator, pin E2)
    output logic pmod_audio    // PMOD-AUDIO "IL" input (Port1 / G11)
);

    logic rst;

    // Power-on reset generator (synchronous, self-clearing)
    por_reset u_por (
        .clk (clk),
        .rst (rst)
    );

    // Note sequencer + square-wave tone generator
    jingle_player u_jingle (
        .clk   (clk),
        .rst   (rst),
        .audio (pmod_audio)
    );

endmodule
