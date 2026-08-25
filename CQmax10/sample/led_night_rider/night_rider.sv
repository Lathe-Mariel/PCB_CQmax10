// Night rider (KITT scanner) brightness generator
// Head LED is brightest; trailing LEDs fade with distance

module night_rider #(
    parameter int NUM_LEDS  = 8,
    parameter int PWM_WIDTH = 8,
    parameter int CLK_HZ    = 50_000_000,
    parameter int STEP_HZ   = 9
) (
    input  logic                         clk,
    input  logic                         rst_n,
    output logic [PWM_WIDTH-1:0]         brightness [NUM_LEDS]
);

    localparam int STEP_CYCLES = CLK_HZ / STEP_HZ;
    localparam int POS_WIDTH   = $clog2(NUM_LEDS);

    logic [31:0]          step_cnt;
    logic [POS_WIDTH-1:0] position;
    logic                 direction; // 0: toward LED7, 1: toward LED0

    function automatic logic [PWM_WIDTH-1:0] dist_brightness(int unsigned distance);
        case (distance)
            0: dist_brightness = 8'hFF;
            1: dist_brightness = 8'h90;
            2: dist_brightness = 8'h30;
            3: dist_brightness = 8'h0A;
            default: dist_brightness = '0;
        endcase
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_cnt  <= '0;
            position  <= '0;
            direction <= 1'b0;
        end else if (step_cnt >= STEP_CYCLES - 1) begin
            step_cnt <= '0;

            if (!direction) begin
                if (position >= NUM_LEDS'(NUM_LEDS - 1))
                    direction <= 1'b1;
                else
                    position <= position + POS_WIDTH'(1);
            end else begin
                if (position == '0)
                    direction <= 1'b0;
                else
                    position <= position - POS_WIDTH'(1);
            end
        end else begin
            step_cnt <= step_cnt + 32'd1;
        end
    end

    always_comb begin
        for (int i = 0; i < NUM_LEDS; i++) begin
            int unsigned diste;

            diste = (i >= int'(position))
                 ? int'(i) - int'(position)
                 : int'(position) - int'(i);
            brightness[i] = ~dist_brightness(diste);
        end
    end

endmodule
