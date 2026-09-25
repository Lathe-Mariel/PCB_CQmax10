// logo_ram.sv
//
// The logo image store, implemented as a writable M9K RAM (2048 x 16 bit,
// power-of-two depth so Quartus infers a single memory block without needing
// on-chip memory initialization, which the compact 10M08SC variant rejects).
//
// The actual logo pixels (2000 words) live in UFM (On-Chip Flash); a bootloader
// copies them here at power-up through the synchronous write port.  The
// renderer then reads them through the registered read port with one cycle of
// latency, exactly as the old logo_rom did.
//
// Layout (per the specification):
//   address = block_id * 400 + logo_y * 20 + logo_x
//   block_id : 0..4   logo_y : 0..19   logo_x : 0..19
//
// Ports:
//   renderer read : rd_addr -> rd_data  (registered, 1 cycle)
//   bootloader write : wr_en / wr_addr / wr_data  (synchronous)

module logo_ram #(
    parameter int ROM_DEPTH = 2000,     // 5 * 20 * 20  (actual image words)
    parameter int MEM_DEPTH = 2048,      // power-of-two storage depth (M9K)
    parameter int AW        = 11,
    parameter int DW        = 16
)(
    input  logic        clk,

    // renderer read port (registered)
    input  logic [AW-1:0] rd_addr,
    output logic [DW-1:0] rd_data,

    // bootloader write port (synchronous)
    input  logic        wr_en,
    input  logic [AW-1:0] wr_addr,
    input  logic [DW-1:0] wr_data
);
    logic [DW-1:0] mem [0:MEM_DEPTH-1];

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end
endmodule
