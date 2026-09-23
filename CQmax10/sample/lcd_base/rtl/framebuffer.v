// framebuffer.v
//
// 320 x 200 x 1 bit frame buffer = 64000 bits, packed 32 pixels per M9K word
// (2000 x 32). Simple dual port: one write port for the game logic, one read
// port for the LCD scan-out.
//
// The write port has priority over the read port (read-during-write returns
// the new data), which is what a simple-dual-port M9K does natively.

module framebuffer #(
    parameter int FIELD_W = 320,
    parameter int FIELD_H = 200,
    parameter int AW      = 14
)(
    input  logic             clk,

    // read port (scan-out)
    input  logic [AW-1:0]    rd_addr,
    output logic [31:0]      rd_data,

    // write port (game logic)
    input  logic             wr_en,
    input  logic [AW-1:0]    wr_addr,
    input  logic [31:0]      wr_data,

    // bulk clear: while `clr_busy`, one word per cycle is zeroed
    input  logic             clr_start,
    output logic             clr_busy
);
    localparam int WORDS = (FIELD_W * FIELD_H) / 32;

    (* ramstyle = "M9K, no_rw_check" *) logic [31:0] mem [0:WORDS-1];

    logic [AW-1:0] clr_addr;
    logic          clearing;

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        else if (clearing)
            mem[clr_addr] <= 32'h0000_0000;
    end

    assign rd_data = mem[rd_addr];

    // clear FSM: walks the whole buffer, one word per cycle
    always_ff @(posedge clk) begin
        if (clr_start) begin
            clearing <= 1'b1;
            clr_addr <= '0;
        end else if (clearing) begin
            if (clr_addr == AW'(WORDS-1))
                clearing <= 1'b0;
            else
                clr_addr <= clr_addr + 1'b1;
        end
    end

    assign clr_busy = clearing;
endmodule
