// PWM controller for direct LED drive
// Shared counter, per-LED duty cycle from brightness values

module pwm_controller #(
    parameter int PWM_WIDTH = 8,
    parameter int NUM_LEDS  = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [PWM_WIDTH-1:0]         brightness [NUM_LEDS],
    output logic [           NUM_LEDS-1:0] led_pwm
);

    logic [PWM_WIDTH-1:0] pwm_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pwm_cnt <= '0;
        else
            pwm_cnt <= pwm_cnt + PWM_WIDTH'(1);
    end

    always_comb begin
        for (int i = 0; i < NUM_LEDS; i++)
            led_pwm[i] = (brightness[i] > pwm_cnt);
    end

endmodule
