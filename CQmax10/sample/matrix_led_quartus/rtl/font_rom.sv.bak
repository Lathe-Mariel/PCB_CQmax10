`default_nettype none
// =============================================================================
// font_rom.sv
// -----------------------------------------------------------------------------
// 8x8 numeral font ROM (digits 0-9), purely combinational (case-statement
// based, no `initial` block -> synthesis-safe on MAX 10 / Quartus Prime).
//
// pattern[7] = leftmost column, pattern[0] = rightmost column, '1' = pixel lit.
// row = 0 is the top row of the glyph, row = 7 is the bottom row.
// =============================================================================
module font_rom (
    input  logic [3:0] digit,    // 0-9 (values 10-15 are unused -> blank)
    input  logic [2:0] row,      // 0-7, top to bottom
    output logic [7:0] pattern
);

    always_comb begin
        unique case (digit)
            4'd0: begin
                unique case (row)
                    3'd0: pattern = 8'h3C;
                    3'd1: pattern = 8'h66;
                    3'd2: pattern = 8'h66;
                    3'd3: pattern = 8'h66;
                    3'd4: pattern = 8'h66;
                    3'd5: pattern = 8'h66;
                    3'd6: pattern = 8'h66;
                    3'd7: pattern = 8'h3C;
                    default: pattern = 8'h00;
                endcase
            end
            4'd1: begin
                unique case (row)
                    3'd0: pattern = 8'h18;
                    3'd1: pattern = 8'h38;
                    3'd2: pattern = 8'h18;
                    3'd3: pattern = 8'h18;
                    3'd4: pattern = 8'h18;
                    3'd5: pattern = 8'h18;
                    3'd6: pattern = 8'h18;
                    3'd7: pattern = 8'h3C;
                    default: pattern = 8'h00;
                endcase
            end
            4'd2: begin
                unique case (row)
                    3'd0: pattern = 8'h3C;
                    3'd1: pattern = 8'h66;
                    3'd2: pattern = 8'h06;
                    3'd3: pattern = 8'h0C;
                    3'd4: pattern = 8'h18;
                    3'd5: pattern = 8'h30;
                    3'd6: pattern = 8'h60;
                    3'd7: pattern = 8'h7E;
                    default: pattern = 8'h00;
                endcase
            end
            4'd3: begin
                unique case (row)
                    3'd0: pattern = 8'h3C;
                    3'd1: pattern = 8'h66;
                    3'd2: pattern = 8'h06;
                    3'd3: pattern = 8'h1C;
                    3'd4: pattern = 8'h06;
                    3'd5: pattern = 8'h06;
                    3'd6: pattern = 8'h66;
                    3'd7: pattern = 8'h3C;
                    default: pattern = 8'h00;
                endcase
            end
            4'd4: begin
                unique case (row)
                    3'd0: pattern = 8'h0C;
                    3'd1: pattern = 8'h1C;
                    3'd2: pattern = 8'h3C;
                    3'd3: pattern = 8'h6C;
                    3'd4: pattern = 8'h7E;
                    3'd5: pattern = 8'h0C;
                    3'd6: pattern = 8'h0C;
                    3'd7: pattern = 8'h0C;
                    default: pattern = 8'h00;
                endcase
            end
            4'd5: begin
                unique case (row)
                    3'd0: pattern = 8'h7E;
                    3'd1: pattern = 8'h60;
                    3'd2: pattern = 8'h60;
                    3'd3: pattern = 8'h7C;
                    3'd4: pattern = 8'h06;
                    3'd5: pattern = 8'h06;
                    3'd6: pattern = 8'h66;
                    3'd7: pattern = 8'h3C;
                    default: pattern = 8'h00;
                endcase
            end
            4'd6: begin
                unique case (row)
                    3'd0: pattern = 8'h1C;
                    3'd1: pattern = 8'h30;
                    3'd2: pattern = 8'h60;
                    3'd3: pattern = 8'h7C;
                    3'd4: pattern = 8'h66;
                    3'd5: pattern = 8'h66;
                    3'd6: pattern = 8'h66;
                    3'd7: pattern = 8'h3C;
                    default: pattern = 8'h00;
                endcase
            end
            4'd7: begin
                unique case (row)
                    3'd0: pattern = 8'h7E;
                    3'd1: pattern = 8'h06;
                    3'd2: pattern = 8'h0C;
                    3'd3: pattern = 8'h18;
                    3'd4: pattern = 8'h30;
                    3'd5: pattern = 8'h30;
                    3'd6: pattern = 8'h30;
                    3'd7: pattern = 8'h30;
                    default: pattern = 8'h00;
                endcase
            end
            4'd8: begin
                unique case (row)
                    3'd0: pattern = 8'h3C;
                    3'd1: pattern = 8'h66;
                    3'd2: pattern = 8'h66;
                    3'd3: pattern = 8'h3C;
                    3'd4: pattern = 8'h66;
                    3'd5: pattern = 8'h66;
                    3'd6: pattern = 8'h66;
                    3'd7: pattern = 8'h3C;
                    default: pattern = 8'h00;
                endcase
            end
            4'd9: begin
                unique case (row)
                    3'd0: pattern = 8'h3C;
                    3'd1: pattern = 8'h66;
                    3'd2: pattern = 8'h66;
                    3'd3: pattern = 8'h66;
                    3'd4: pattern = 8'h3E;
                    3'd5: pattern = 8'h06;
                    3'd6: pattern = 8'h0C;
                    3'd7: pattern = 8'h38;
                    default: pattern = 8'h00;
                endcase
            end
            default: pattern = 8'h00; // digits 10-15: blank (unused)
        endcase
    end

endmodule
`default_nettype wire
