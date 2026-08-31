// font5x7_pkg.sv
// Minimal 5x7 bitmap font, digits 0-9 only (enough for the score readout).
// Row 0 is the top row of the glyph. Bit 4 (MSB) is the leftmost pixel.
//
// Implemented as a plain case/case lookup (no local arrays inside the
// function) so it synthesizes as a simple LUT-based ROM on any toolchain.
package font5x7_pkg;

    function automatic logic [4:0] digit_row(input logic [3:0] digit,
                                              input logic [2:0] row);
        logic [4:0] result;
        begin
            case (digit)
                4'd0: case (row)
                    3'd0: result = 5'b01110;
                    3'd1: result = 5'b10001;
                    3'd2: result = 5'b10011;
                    3'd3: result = 5'b10101;
                    3'd4: result = 5'b11001;
                    3'd5: result = 5'b10001;
                    3'd6: result = 5'b01110;
                    default: result = 5'b00000;
                endcase
                4'd1: case (row)
                    3'd0: result = 5'b00100;
                    3'd1: result = 5'b01100;
                    3'd2: result = 5'b00100;
                    3'd3: result = 5'b00100;
                    3'd4: result = 5'b00100;
                    3'd5: result = 5'b00100;
                    3'd6: result = 5'b01110;
                    default: result = 5'b00000;
                endcase
                4'd2: case (row)
                    3'd0: result = 5'b01110;
                    3'd1: result = 5'b10001;
                    3'd2: result = 5'b00001;
                    3'd3: result = 5'b00010;
                    3'd4: result = 5'b00100;
                    3'd5: result = 5'b01000;
                    3'd6: result = 5'b11111;
                    default: result = 5'b00000;
                endcase
                4'd3: case (row)
                    3'd0: result = 5'b11111;
                    3'd1: result = 5'b00010;
                    3'd2: result = 5'b00100;
                    3'd3: result = 5'b00010;
                    3'd4: result = 5'b00001;
                    3'd5: result = 5'b10001;
                    3'd6: result = 5'b01110;
                    default: result = 5'b00000;
                endcase
                4'd4: case (row)
                    3'd0: result = 5'b00010;
                    3'd1: result = 5'b00110;
                    3'd2: result = 5'b01010;
                    3'd3: result = 5'b10010;
                    3'd4: result = 5'b11111;
                    3'd5: result = 5'b00010;
                    3'd6: result = 5'b00010;
                    default: result = 5'b00000;
                endcase
                4'd5: case (row)
                    3'd0: result = 5'b11111;
                    3'd1: result = 5'b10000;
                    3'd2: result = 5'b11110;
                    3'd3: result = 5'b00001;
                    3'd4: result = 5'b00001;
                    3'd5: result = 5'b10001;
                    3'd6: result = 5'b01110;
                    default: result = 5'b00000;
                endcase
                4'd6: case (row)
                    3'd0: result = 5'b00110;
                    3'd1: result = 5'b01000;
                    3'd2: result = 5'b10000;
                    3'd3: result = 5'b11110;
                    3'd4: result = 5'b10001;
                    3'd5: result = 5'b10001;
                    3'd6: result = 5'b01110;
                    default: result = 5'b00000;
                endcase
                4'd7: case (row)
                    3'd0: result = 5'b11111;
                    3'd1: result = 5'b00001;
                    3'd2: result = 5'b00010;
                    3'd3: result = 5'b00100;
                    3'd4: result = 5'b01000;
                    3'd5: result = 5'b01000;
                    3'd6: result = 5'b01000;
                    default: result = 5'b00000;
                endcase
                4'd8: case (row)
                    3'd0: result = 5'b01110;
                    3'd1: result = 5'b10001;
                    3'd2: result = 5'b10001;
                    3'd3: result = 5'b01110;
                    3'd4: result = 5'b10001;
                    3'd5: result = 5'b10001;
                    3'd6: result = 5'b01110;
                    default: result = 5'b00000;
                endcase
                4'd9: case (row)
                    3'd0: result = 5'b01110;
                    3'd1: result = 5'b10001;
                    3'd2: result = 5'b10001;
                    3'd3: result = 5'b01111;
                    3'd4: result = 5'b00001;
                    3'd5: result = 5'b00010;
                    3'd6: result = 5'b01100;
                    default: result = 5'b00000;
                endcase
                default: result = 5'b00000;
            endcase
            digit_row = result;
        end
    endfunction

endpackage