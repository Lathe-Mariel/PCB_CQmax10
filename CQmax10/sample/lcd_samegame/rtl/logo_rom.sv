// logo_rom.sv
//
// Read-only ROM holding the five 20x20 RGB565 logo images (2000 words x 16
// bit).  Stored in a 2048-deep (power of two) array so Quartus can infer a
// single M9K block; the upper 48 words are unused and initialised to 0.
//
// Layout (per the specification):
//   address = block_id * 400 + logo_y * 20 + logo_x
//   block_id : 0..4   logo_y : 0..19   logo_x : 0..19
//
// Read latency is one clock cycle (registered address -> registered data);
// the renderer presents `rom_addr` one cycle before it needs `rom_data`.

module logo_rom #(
    parameter int ROM_DEPTH = 2000,     // 5 * 20 * 20  (actual image words)
    parameter int MEM_DEPTH = 2048,      // power-of-two storage depth (M9K)
    parameter int AW        = 11,
    parameter int DW        = 16
)(
    input  logic        clk,
    input  logic [AW-1:0] rd_addr,
    output logic [DW-1:0] rd_data
);
    logic [DW-1:0] rom [0:MEM_DEPTH-1];

    initial begin
        $readmemh("logo_rom.mem", rom, 0, ROM_DEPTH-1);
    end

    always_ff @(posedge clk) begin
        rd_data <= rom[rd_addr];
    end
endmodule
