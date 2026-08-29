`default_nettype none

module top #(
    parameter int CLK_FREQ_HZ       = 50_000_000,             // system clk = 50 MHz
    parameter int DIGIT_HOLD_TICKS  = CLK_FREQ_HZ             // 1 second per digit

	 )(
    input  logic clk,          // pin 88  : system clock
    input  logic rst_n,        // pin 17  : asynchronous reset, active low

	 output logic led,
	 input logic sw0,
	 output logic led0,
	 output logic [7:0] leds,
	 output logic [7:0] port3,
 	 output logic [7:0] port4,
	 output logic [7:0] port5,
	 output logic [7:0] port6
);

assign led0 = sw0;

    // ------------------------------------------------------------------
    // Reset synchronizer (async assert, sync de-assert)
    // ------------------------------------------------------------------
    logic [1:0] rst_sync;
    logic       rst_int_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    end
    assign rst_int_n = rst_sync[1];

    // ------------------------------------------------------------------
    // 1-second digit counter: cycles 0 -> 9 -> 0 ...
    // ------------------------------------------------------------------
    logic [25:0] sec_cnt;
    logic [3:0]  digit_idx;

    always_ff @(posedge clk or negedge rst_int_n) begin
        if (!rst_int_n) begin
            sec_cnt   <= 26'd0;
            digit_idx <= 4'd0;
        end else if (sec_cnt == DIGIT_HOLD_TICKS-1) begin
            sec_cnt   <= 26'd0;
            leds <= ~leds;
		      led <= !led;
				port3 <= ~port3;
				port4 <= ~port4;
				port5 <= ~port5;
				port6 <= ~port6;
        end else begin
            sec_cnt <= sec_cnt + 26'd1;
        end
    end

endmodule
`default_nettype wire