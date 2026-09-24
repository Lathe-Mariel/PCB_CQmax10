// logo_rom.sv
//
// Read-only ROM holding the five 20x20 RGB565 logo images (2000 words x 16
// bit, one M9K block).  Initialised from logo_rom.hex by $readmemh.
//
// Layout (per the specification):
//   address = block_id * 400 + logo_y * 20 + logo_x
//   block_id : 0..4   logo_y : 0..19   logo_x : 0..19
//
// Read latency is one clock cycle (registered address -> registered data);
// the renderer presents `rom_addr` one cycle before it needs `rom_data`.

module logo_rom #(
    parameter int ROM_DEPTH = 2000,     // 5 * 20 * 20
    parameter int AW        = 11
)(
    input  logic        clk,
    input  logic [AW-1:0] rd_addr,
    output logic [15:0] rd_data
);
    (* ramstyle = "M9K, no_rw_check" *) logic [15:0] rom [0:ROM_DEPTH-1];

    initial begin
        $readmemh("logo_rom.hex", rom);
    end

    always_ff @(posedge clk) begin
        rd_data <= rom[rd_addr];
    end
endmodule
