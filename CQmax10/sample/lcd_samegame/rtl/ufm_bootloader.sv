// ufm_bootloader.sv
//
// Copies the 2000 logo pixels from UFM (On-Chip Flash IP, 32-bit word per
// pixel, pixel in bits [15:0]) into the writable logo_ram at power-up.
//
// The On-Chip Flash IP exposes a 32-bit Avalon-MM data slave.  This module
// issues a sequence of single-word reads:
//
//   assert avmm_read + address, hold while waitrequest is high
//   wait for readdatavalid, capture readdata[15:0]
//   write the pixel to logo_ram, advance the address
//
// `boot_done` asserts after the last pixel is written and stays high, so the
// game FSM and renderer only start once the logos are resident in RAM.

module ufm_bootloader #(
    parameter int PIXELS   = 2000,      // 5 logos x 20 x 20
    parameter int RAM_AW   = 11,        // logo_ram address width
    parameter int RAM_DW   = 16         // logo_ram data width (pixel)
)(
    input  logic        clk,
    input  logic        rst,

    // On-Chip Flash Avalon-MM data slave (master side)
    output logic        flash_read,
    output logic [12:0] flash_addr,      // word address 0..8191
    input  logic        flash_waitrequest,
    input  logic        flash_readdatavalid,
    input  logic [31:0] flash_readdata,

    // logo_ram write port
    output logic            ram_wr_en,
    output logic [RAM_AW-1:0] ram_wr_addr,
    output logic [RAM_DW-1:0] ram_wr_data,

    output logic        boot_done
);
    typedef enum logic [2:0] {
        S_IDLE, S_READ_REQ, S_READ_WAIT, S_DATA, S_WRITE, S_NEXT, S_DONE
    } state_t;
    state_t state;

    logic [10:0] addr;         // 0..1999 pixel index (also UFM word addr)

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            addr        <= 11'd0;
            flash_read  <= 1'b0;
            flash_addr  <= 13'd0;
            ram_wr_en   <= 1'b0;
            ram_wr_addr <= '0;
            ram_wr_data <= '0;
            boot_done   <= 1'b0;
        end else begin
            flash_read <= 1'b0;
            ram_wr_en  <= 1'b0;

            case (state)
            S_IDLE: begin
                addr  <= 11'd0;
                state <= S_READ_REQ;
            end

            // issue a read for the current word address
            S_READ_REQ: begin
                flash_read <= 1'b1;
                flash_addr <= 13'(addr);
                state      <= S_READ_WAIT;
            end

            // wait until waitrequest deasserts (address accepted)
            S_READ_WAIT: begin
                if (!flash_waitrequest)
                    state <= S_DATA;
            end

            // wait for readdatavalid, capture the pixel
            S_DATA: begin
                if (flash_readdatavalid) begin
                    ram_wr_data <= flash_readdata[15:0];
                    state       <= S_WRITE;
                end
            end

            // write the pixel into logo_ram
            S_WRITE: begin
                ram_wr_en   <= 1'b1;
                ram_wr_addr <= RAM_AW'(addr);
                state       <= S_NEXT;
            end

            S_NEXT: begin
                if (addr == PIXELS - 1) begin
                    state     <= S_DONE;
                    boot_done <= 1'b1;
                end else begin
                    addr  <= addr + 11'd1;
                    state <= S_READ_REQ;
                end
            end

            S_DONE: begin
                boot_done <= 1'b1;
            end
            endcase
        end
    end
endmodule
