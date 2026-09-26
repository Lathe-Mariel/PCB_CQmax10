// logo_flash_tb.sv
//
// Simulation stand-in for the generated On-Chip Flash IP (`logo_flash`).
//
// `samegame_top` instantiates the real IP, which cannot be compiled here: it
// pulls in the whole Quartus IP tree and the altera_mf library.  For the
// integration testbench the interesting behaviour is the Avalon-MM data slave
// handshake plus the flash CONTENT, so this module keeps the module name and
// the exact port list of the generated wrapper and delegates to `ufm_model_top`
// (defined in tb_samegame_top.sv).
//
// The content model returns readdata = {16'h0000, address}.  The real
// logo_rom.hex is not an identity pattern, but for the purpose of this test
// (does any non-background pixel reach the panel?) an identity pattern is
// sufficient AND stronger: every one of the 2000 logo words is distinct, so a
// renderer that fetches the wrong address cannot coincidentally look right.
//
// This file is ONLY used by run_tb_samegame_top.bat.  It is deliberately kept
// in simulation/questa so it never reaches the Quartus project.

module logo_flash (
    input  logic        ufm_clock_clk,
    input  logic        ufm_reset_reset_n,

    // ufm_data (Avalon-MM data slave)
    input  logic [12:0] ufm_data_address,
    input  logic        ufm_data_read,
    input  logic [31:0] ufm_data_writedata,
    input  logic        ufm_data_write,
    output logic [31:0] ufm_data_readdata,
    output logic        ufm_data_waitrequest,
    output logic        ufm_data_readdatavalid,
    input  logic [3:0]  ufm_data_burstcount,

    // ufm_csr (Avalon-MM csr slave) - unused by the design
    input  logic        ufm_csr_address,
    input  logic        ufm_csr_read,
    input  logic [31:0] ufm_csr_writedata,
    input  logic        ufm_csr_write,
    output logic [31:0] ufm_csr_readdata
);
    ufm_model_top #(.RDV_CYCLE(8), .DONE_CYCLE(10)) u_model (
        .clk             (ufm_clock_clk),
        .reset_n         (ufm_reset_reset_n),
        .read            (ufm_data_read),
        .addr            (ufm_data_address),
        .burstcount      (ufm_data_burstcount),
        .waitrequest     (ufm_data_waitrequest),
        .readdatavalid   (ufm_data_readdatavalid),
        .readdata        (ufm_data_readdata)
    );

    assign ufm_csr_readdata = 32'h0;

    // keep the unused inputs referenced so no tool complains
    wire unused = ufm_data_write | ufm_data_writedata[0] | ufm_csr_read
                | ufm_csr_write | ufm_csr_writedata[0] | ufm_csr_address;
endmodule
