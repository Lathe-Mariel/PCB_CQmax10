// Top-level: 8-LED night rider with PWM brightness control
// Target: CQmax10 (10M08SCE144C8G), 50 MHz system clock

module night_rider_top (
    input  logic       clk,
    input  logic       rst_n,
    output logic [7:0] led
);

    logic [7:0] brightness [8];

    night_rider u_night_rider (
        .clk       (clk),
        .rst_n     (rst_n),
        .brightness(brightness)
    );

    pwm_controller u_pwm (
        .clk       (clk),
        .rst_n     (rst_n),
        .brightness(brightness),
        .led_pwm   (led)
    );

endmodule
