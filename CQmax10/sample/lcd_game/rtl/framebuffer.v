// framebuffer.v
//
// 320 x 240 x 1 bit frame buffer = 76800 bits, packed 32 pixels per M9K word
// (2400 x 32).
//
// ---------------------------------------------------------------------------
// WHAT THIS MEMORY IS FOR NOW
// ---------------------------------------------------------------------------
// The panel is no longer fed by scanning this buffer out. The ILI9341 keeps the
// picture in its own GRAM and is driven by explicit rectangle writes (see
// lcd_ili9341_ctrl.sv), so this buffer is used ONLY as the collision model:
//
//   * the playfield lines are written into it at start-up
//   * the game writes each dot it draws into it
//   * before drawing, the game reads the target pixel; if it is already set
//     the game is over
//
// One read port + one write port is therefore enough, which is a plain simple
// dual port M9K and needs only ONE memory block. (The previous design scanned
// the buffer out to the panel as well, which needed a second read port and
// made Quartus duplicate the whole RAM into a second M9K block.)
//
// The read port is SYNCHRONOUS: the data is registered, so it becomes valid
// one clock after the address is sampled. An asynchronous read (assign
// rd_data = mem[rd_addr]) stops Quartus inferring an M9K and it then tries to
// build the whole buffer from registers, which does not fit on the 10M08.
//
// The read port is registered, so a read of an address that is written on the
// same clock returns the OLD contents of that word (both are nonblocking
// assignments: the read samples the memory before the write updates it). The
// game never does this - it reads a pixel, and writes it in a later cycle - so
// the behaviour only matters as documentation.
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

    // read port (collision test)
    input  logic [AW-1:0]    rd_addr,
    output logic [31:0]      rd_data,

    // write port (playfield / game)
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

    // synchronous read port: data is valid one clock after the address
    always_ff @(posedge clk) begin
        rd_data <= mem[rd_addr];
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
