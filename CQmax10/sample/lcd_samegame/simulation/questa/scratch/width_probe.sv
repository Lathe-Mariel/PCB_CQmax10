// width_probe.sv
//
// Minimal experiment: reproduce the arithmetic style used in lcd_renderer.sv
// and report the values Questa/Quartus actually compute.  Used to confirm /
// refute the "expression width truncated to the assignment target" reading.

`timescale 1ns/1ps

module width_probe;
    // --- A: the expression exactly as written in lcd_renderer.sv ---
    function automatic logic [3:0] div20_as_written(input logic [8:0] x);
        logic [3:0] cx;
        cx = (({3'd0, x} * 13'd410) >> 13);
        return cx;
    endfunction

    // --- B: same, but with a 17-bit multiplier (the product really needs 17) ---
    function automatic logic [3:0] div20_wide(input logic [8:0] x);
        logic [16:0] mul;
        mul = {8'd0, x} * 17'd410;
        return mul[16:13];
    endfunction

    // --- C: remainder exactly as written (5-bit context) ---
    function automatic logic [4:0] mod20_as_written(input logic [8:0] x, input logic [3:0] cx);
        logic [4:0] lx;
        lx = x - (cx * 5'd20);
        return lx;
    endfunction

    // --- D: remainder with a 9-bit multiplier ---
    function automatic logic [4:0] mod20_wide(input logic [8:0] x, input logic [3:0] cx);
        logic [8:0] lx;
        lx = x - (cx * 9'd20);
        return lx;
    endfunction

    // --- E: logo ROM address exactly as written ---
    function automatic logic [10:0] rom_as_written(input logic [2:0] id,
                                                   input logic [4:0] ly,
                                                   input logic [4:0] lx);
        logic [10:0] a;
        a = (id * 9'd400) + (ly * 5'd20) + lx;
        return a;
    endfunction

    int errors = 0;

    task automatic chk(input string what, input int got, input int exp);
        if (got !== exp) begin
            errors++;
            $display("  FAIL %-28s got %0d expected %0d", what, got, exp);
        end
    endtask

    initial begin
        $display("== divide/multiply by 20 ==");
        for (int x = 0; x <= 319; x++) begin
            chk($sformatf("A div20_as_written(%0d)", x), div20_as_written(9'(x)), x / 20);
        end
        for (int x = 0; x <= 319; x++) begin
            chk($sformatf("B div20_wide(%0d)", x), div20_wide(9'(x)), x / 20);
        end

        $display("== modulo 20 ==");
        for (int x = 0; x <= 319; x++) begin
            chk($sformatf("C mod20_as_written(%0d)", x),
                mod20_as_written(9'(x), 4'(x/20)), x % 20);
        end
        for (int x = 0; x <= 319; x++) begin
            chk($sformatf("D mod20_wide(%0d)", x),
                mod20_wide(9'(x), 4'(x/20)), x % 20);
        end

        $display("== logo rom address ==");
        for (int id = 0; id < 5; id++)
            for (int ly = 0; ly < 20; ly++)
                for (int lx = 0; lx < 20; lx++)
                    chk($sformatf("E rom(%0d,%0d,%0d)", id, ly, lx),
                        rom_as_written(3'(id), 5'(ly), 5'(lx)),
                        id*400 + ly*20 + lx);

        $display("==========================================");
        $display("  width_probe: %s", (errors == 0) ? "ALL PASS" : $sformatf("%0d FAILURES", errors));
        $display("==========================================");
        $finish;
    end
endmodule
