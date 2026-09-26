// rom_megafunc.v
//
// Experiment: can a MAX 10 10M08SCE144C8G build an M9K ROM whose contents are
// initialized from a file, when the memory is instantiated as an altsyncram
// MEGAFUNCTION instead of inferred from raw logic?
//
// Background: "Info (276013): RAM logic "rom" is uninferred because MIF is not
// supported for the selected family" is what Quartus says about an INFERRED
// ROM on this device, and it then builds the ROM from LEs (2,601 of them for
// 2048x16), which is far too expensive.  The On-Chip Flash IP is the officially
// supported alternative, but a .pof for MAX 10 does not seem to carry the UFM
// image, which is why the board ends up with an erased UFM.
//
// If the megafunction route works, the logo image can live in the configuration
// bitstream itself and the UFM becomes unnecessary.
module rom_megafunc (
    input  wire        clk,
    input  wire [10:0] a,
    output wire [15:0] q
);
    altsyncram #(
        .operation_mode          ("ROM"),
        .width_a                 (16),
        .widthad_a               (11),
        .numwords_a              (2048),
        .outdata_reg_a           ("CLOCK0"),
        .address_aclr_a          ("NONE"),
        .outdata_aclr_a          ("NONE"),
        .init_file               ("logo_rom.mif"),
        .lpm_type                ("altsyncram"),
        .intended_device_family  ("MAX 10")
    ) u_rom (
        .clock0    (clk),
        .address_a (a),
        .q_a       (q)
    );
endmodule
