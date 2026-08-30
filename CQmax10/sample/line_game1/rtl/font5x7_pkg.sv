// font5x7_pkg.sv
// Minimal 5x7 bitmap font, digits 0-9 only (enough for the score readout).
// Row 0 is the top row of the glyph. Bit 4 (MSB) is the leftmost pixel.
package font5x7_pkg;

    function automatic logic [4:0] digit_row(input logic [3:0] digit,
                                              input logic [2:0] row);
        logic [4:0] font_table [0:9][0:6];
        begin
            font_table[0][0]=5'b01110; font_table[0][1]=5'b10001; font_table[0][2]=5'b10011;
            font_table[0][3]=5'b10101; font_table[0][4]=5'b11001; font_table[0][5]=5'b10001;
            font_table[0][6]=5'b01110;

            font_table[1][0]=5'b00100; font_table[1][1]=5'b01100; font_table[1][2]=5'b00100;
            font_table[1][3]=5'b00100; font_table[1][4]=5'b00100; font_table[1][5]=5'b00100;
            font_table[1][6]=5'b01110;

            font_table[2][0]=5'b01110; font_table[2][1]=5'b10001; font_table[2][2]=5'b00001;
            font_table[2][3]=5'b00010; font_table[2][4]=5'b00100; font_table[2][5]=5'b01000;
            font_table[2][6]=5'b11111;

            font_table[3][0]=5'b11111; font_table[3][1]=5'b00010; font_table[3][2]=5'b00100;
            font_table[3][3]=5'b00010; font_table[3][4]=5'b00001; font_table[3][5]=5'b10001;
            font_table[3][6]=5'b01110;

            font_table[4][0]=5'b00010; font_table[4][1]=5'b00110; font_table[4][2]=5'b01010;
            font_table[4][3]=5'b10010; font_table[4][4]=5'b11111; font_table[4][5]=5'b00010;
            font_table[4][6]=5'b00010;

            font_table[5][0]=5'b11111; font_table[5][1]=5'b10000; font_table[5][2]=5'b11110;
            font_table[5][3]=5'b00001; font_table[5][4]=5'b00001; font_table[5][5]=5'b10001;
            font_table[5][6]=5'b01110;

            font_table[6][0]=5'b00110; font_table[6][1]=5'b01000; font_table[6][2]=5'b10000;
            font_table[6][3]=5'b11110; font_table[6][4]=5'b10001; font_table[6][5]=5'b10001;
            font_table[6][6]=5'b01110;

            font_table[7][0]=5'b11111; font_table[7][1]=5'b00001; font_table[7][2]=5'b00010;
            font_table[7][3]=5'b00100; font_table[7][4]=5'b01000; font_table[7][5]=5'b01000;
            font_table[7][6]=5'b01000;

            font_table[8][0]=5'b01110; font_table[8][1]=5'b10001; font_table[8][2]=5'b10001;
            font_table[8][3]=5'b01110; font_table[8][4]=5'b10001; font_table[8][5]=5'b10001;
            font_table[8][6]=5'b01110;

            font_table[9][0]=5'b01110; font_table[9][1]=5'b10001; font_table[9][2]=5'b10001;
            font_table[9][3]=5'b01111; font_table[9][4]=5'b00001; font_table[9][5]=5'b00010;
            font_table[9][6]=5'b01100;

            digit_row = (digit <= 4'd9) ? font_table[digit][row] : 5'b00000;
        end
    endfunction

endpackage
