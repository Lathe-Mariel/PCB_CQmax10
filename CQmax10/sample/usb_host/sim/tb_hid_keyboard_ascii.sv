`timescale 1ns/1ps
`default_nettype none

module tb_hid_keyboard_ascii;

    logic       clk;
    logic       rst_n;
    logic [1:0] typ;
    logic       report;
    logic [7:0] key_modifiers;
    logic [7:0] key1;
    logic [7:0] key2;
    logic [7:0] key3;
    logic [7:0] key4;
    logic [7:0] ascii;
    logic       ascii_valid;

    hid_keyboard_ascii dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .typ           (typ),
        .report        (report),
        .key_modifiers (key_modifiers),
        .key1          (key1),
        .key2          (key2),
        .key3          (key3),
        .key4          (key4),
        .ascii         (ascii),
        .ascii_valid   (ascii_valid)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic send_report(
        input logic [7:0] mod,
        input logic [7:0] k1,
        input logic [7:0] k2,
        input logic [7:0] k3,
        input logic [7:0] k4,
        input logic       expect_valid,
        input logic [7:0] expect_ascii
    );
        begin
            @(negedge clk);
            key_modifiers = mod;
            key1          = k1;
            key2          = k2;
            key3          = k3;
            key4          = k4;
            report        = 1'b1;
            @(posedge clk);
            #1;
            if (expect_valid) begin
                if (!ascii_valid || (ascii != expect_ascii)) begin
                    $fatal(1, "expected ascii 0x%02h, got valid=%0d ascii=0x%02h", expect_ascii, ascii_valid, ascii);
                end
            end else if (ascii_valid) begin
                $fatal(1, "unexpected ascii 0x%02h", ascii);
            end
            @(negedge clk);
            report = 1'b0;
        end
    endtask

    initial begin
        rst_n         = 1'b0;
        typ           = 2'd1;
        report        = 1'b0;
        key_modifiers = 8'h00;
        key1          = 8'h00;
        key2          = 8'h00;
        key3          = 8'h00;
        key4          = 8'h00;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        send_report(8'h00, 8'h04, 8'h00, 8'h00, 8'h00, 1'b1, 8'h61);
        send_report(8'h00, 8'h04, 8'h00, 8'h00, 8'h00, 1'b0, 8'h00);
        send_report(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 1'b0, 8'h00);

        send_report(8'h02, 8'h04, 8'h00, 8'h00, 8'h00, 1'b1, 8'h41);
        send_report(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 1'b0, 8'h00);

        send_report(8'h00, 8'h1e, 8'h00, 8'h00, 8'h00, 1'b1, 8'h31);
        send_report(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 1'b0, 8'h00);

        send_report(8'h02, 8'h1e, 8'h00, 8'h00, 8'h00, 1'b1, 8'h21);
        send_report(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 1'b0, 8'h00);

        send_report(8'h00, 8'h39, 8'h00, 8'h00, 8'h00, 1'b0, 8'h00);
        send_report(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 1'b0, 8'h00);
        send_report(8'h00, 8'h05, 8'h00, 8'h00, 8'h00, 1'b1, 8'h42);
        send_report(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 1'b0, 8'h00);
        send_report(8'h02, 8'h05, 8'h00, 8'h00, 8'h00, 1'b1, 8'h62);

        $display("tb_hid_keyboard_ascii: PASS");
        $finish;
    end

endmodule

`default_nettype wire
