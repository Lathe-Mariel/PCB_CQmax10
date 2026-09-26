// Minimal experiment: can a MAX 10 10M08SCE144C8G infer an M9K whose contents
// come from a $readmemh initialization file?  If yes, the logo store does NOT
// need the UFM at all and the "white panel" problem disappears.
module romtest (
    input  wire        clk,
    input  wire [10:0] a,
    output wire [15:0] q
);
    reg [15:0] rom [0:2047];
    reg [15:0] qr;

    initial begin
        $readmemh("logo_rom.mem", rom, 0, 1999);
    end

    always @(posedge clk)
        qr <= rom[a];

    assign q = qr;
endmodule
