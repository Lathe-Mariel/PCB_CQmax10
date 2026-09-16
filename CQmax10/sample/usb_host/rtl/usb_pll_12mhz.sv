`default_nettype none

module usb_pll_12mhz (
    input  wire clk_50m,
    input  wire rst_n,
    output wire clk_12m,
    output wire locked
);

`ifdef SIM
    logic div_step;
    logic clk_sim;
    logic [3:0] lock_cnt;

    always_ff @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            div_step <= 1'b0;
            clk_sim  <= 1'b0;
            lock_cnt <= 4'd0;
        end else begin
            div_step <= ~div_step;
            if (div_step) begin
                clk_sim <= ~clk_sim;
            end
            if (lock_cnt != 4'hf) begin
                lock_cnt <= lock_cnt + 4'd1;
            end
        end
    end

    assign clk_12m = clk_sim;
    assign locked  = &lock_cnt;
`else
    wire [4:0] pll_clk;

    altpll #(
        .operation_mode          ("NORMAL"),
        .compensate_clock        ("CLK0"),
        .inclk0_input_frequency  (20000),
        .clk0_multiply_by        (6),
        .clk0_divide_by          (25),
        .clk0_duty_cycle         (50),
        .clk0_phase_shift        ("0"),
        .width_clock             (5)
    ) u_altpll (
        .areset (~rst_n),
        .inclk  ({1'b0, clk_50m}),
        .clk    (pll_clk),
        .locked (locked)
    );

    assign clk_12m = pll_clk[0];
`endif

endmodule

`default_nettype wire
