// framebuffer.v
//
// 320 x 240 x 1 bit frame buffer = 76800 bits, packed 32 pixels per M9K word
// (2400 x 32). Simple dual port (one write port, two read ports):
//   - write port : game logic / the start-up line drawer
//   - read port A: LCD scan-out (runs continuously, every frame)
//   - read port B: game logic, to test a pixel before drawing on it
//
// Both read ports are SYNCHRONOUS: the data is registered, so it becomes
// valid one clock after the address is sampled. An asynchronous read (assign
// rd_data = mem[rd_addr]) stops Quartus inferring an M9K and it then tries to
// build the whole buffer from registers, which does not fit on the 10M08.
//
// A 2-read-port + 1-write-port RAM is still a "simple dual port" for the M9K
// (it has two independent read ports), so this stays one memory block.
//
// The write port has priority over the read ports (read-during-write returns
// the new data), which is what the M9K does natively.
//
// Word address layout inside a row:
//   word in row = x / 32      (WORDS_PER_ROW = 10 for a 320-wide screen)
//   bit  in word = x % 32
// so the word address of pixel (x,y) is  y*WORDS_PER_ROW + x/32.

module framebuffer #(
    parameter int FIELD_W       = 320,
    parameter int FIELD_H       = 240,
    parameter int WORDS_PER_ROW = 10,    // FIELD_W / 32
    parameter int AW            = 14      // word address width
)(
    input  logic             clk,

    // read port A (LCD scan-out)
    input  logic [AW-1:0]    rd_addr,
    output logic [31:0]      rd_data,

    // read port B (game logic pixel test)
    input  logic [AW-1:0]    rd2_addr,
    output logic [31:0]      rd2_data,

    // write port (game logic)
    input  logic             wr_en,
    input  logic [AW-1:0]    wr_addr,
    input  logic [31:0]      wr_data,

    // bulk clear: while `clr_busy`, one word per cycle is zeroed
    input  logic             clr_start,
    output logic             clr_busy
);
    localparam int WORDS = FIELD_H * WORDS_PER_ROW;   // 240 * 10 = 2400

    (* ramstyle = "M9K, no_rw_check" *) logic [31:0] mem [0:WORDS-1];

    logic [AW-1:0] clr_addr;
    logic          clearing;

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        else if (clearing)
            mem[clr_addr] <= 32'h0000_0000;
    end

    // synchronous read ports: data is valid one clock after the address
    always_ff @(posedge clk) begin
        rd_data  <= mem[rd_addr];
        rd2_data <= mem[rd2_addr];
    end

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
