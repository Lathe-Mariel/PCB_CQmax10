`default_nettype none

module top #(
    parameter int USB_CHANNEL = 1
) (
    input  wire logic clk,
    input  wire logic rst_n,

    inout  wire  usb_u1_dp,
    inout  wire  usb_u1_dm,
    inout  wire  usb_u2_dp,
    inout  wire  usb_u2_dm,

    output logic led,
    output logic led0,
    output logic [7:0] leds
);

    wire clk_usb;
    wire pll_locked;

    usb_pll_12mhz u_usb_pll (
        .clk_50m (clk),
        .rst_n   (rst_n),
        .clk_12m (clk_usb),
        .locked  (pll_locked)
    );

    wire async_rst_n = rst_n & pll_locked;
    logic rst_sys_n;
    logic rst_usb_n;

    reset_sync u_rst_sys (
        .clk         (clk),
        .async_rst_n (async_rst_n),
        .rst_n       (rst_sys_n)
    );

    reset_sync u_rst_usb (
        .clk         (clk_usb),
        .async_rst_n (async_rst_n),
        .rst_n       (rst_usb_n)
    );

    wire [1:0] usb_typ;
    wire       usb_report;
    wire       usb_conerr;
    wire [7:0] key_modifiers;
    wire [7:0] key1;
    wire [7:0] key2;
    wire [7:0] key3;
    wire [7:0] key4;
    wire [7:0] mouse_btn;
    wire signed [7:0] mouse_dx;
    wire signed [7:0] mouse_dy;
    wire game_l;
    wire game_r;
    wire game_u;
    wire game_d;
    wire game_a;
    wire game_b;
    wire game_x;
    wire game_y;
    wire game_sel;
    wire game_sta;
    wire [63:0] dbg_hid_report;

    generate
        if (USB_CHANNEL == 2) begin : g_usb_ch2
            assign usb_u1_dp = 1'bz;
            assign usb_u1_dm = 1'bz;

            usb_hid_host u_usb_hid_host (
                .usbclk        (clk_usb),
                .usbrst_n      (rst_usb_n),
                .usb_dm        (usb_u2_dm),
                .usb_dp        (usb_u2_dp),
                .typ           (usb_typ),
                .report        (usb_report),
                .conerr        (usb_conerr),
                .key_modifiers (key_modifiers),
                .key1          (key1),
                .key2          (key2),
                .key3          (key3),
                .key4          (key4),
                .mouse_btn     (mouse_btn),
                .mouse_dx      (mouse_dx),
                .mouse_dy      (mouse_dy),
                .game_l        (game_l),
                .game_r        (game_r),
                .game_u        (game_u),
                .game_d        (game_d),
                .game_a        (game_a),
                .game_b        (game_b),
                .game_x        (game_x),
                .game_y        (game_y),
                .game_sel      (game_sel),
                .game_sta      (game_sta),
                .dbg_hid_report(dbg_hid_report)
            );
        end else begin : g_usb_ch1
            assign usb_u2_dp = 1'bz;
            assign usb_u2_dm = 1'bz;

            usb_hid_host u_usb_hid_host (
                .usbclk        (clk_usb),
                .usbrst_n      (rst_usb_n),
                .usb_dm        (usb_u1_dm),
                .usb_dp        (usb_u1_dp),
                .typ           (usb_typ),
                .report        (usb_report),
                .conerr        (usb_conerr),
                .key_modifiers (key_modifiers),
                .key1          (key1),
                .key2          (key2),
                .key3          (key3),
                .key4          (key4),
                .mouse_btn     (mouse_btn),
                .mouse_dx      (mouse_dx),
                .mouse_dy      (mouse_dy),
                .game_l        (game_l),
                .game_r        (game_r),
                .game_u        (game_u),
                .game_d        (game_d),
                .game_a        (game_a),
                .game_b        (game_b),
                .game_x        (game_x),
                .game_y        (game_y),
                .game_sel      (game_sel),
                .game_sta      (game_sta),
                .dbg_hid_report(dbg_hid_report)
            );
        end
    endgenerate

    logic [7:0] usb_ascii;
    logic       usb_ascii_valid;

    hid_keyboard_ascii u_hid_keyboard_ascii (
        .clk           (clk_usb),
        .rst_n         (rst_usb_n),
        .typ           (usb_typ),
        .report        (usb_report),
        .key_modifiers (key_modifiers),
        .key1          (key1),
        .key2          (key2),
        .key3          (key3),
        .key4          (key4),
        .ascii         (usb_ascii),
        .ascii_valid   (usb_ascii_valid)
    );

    logic [7:0] sys_ascii;
    logic       sys_ascii_valid;
    logic       sys_ascii_ready;
    logic       cdc_overflow_usb;
    logic       cdc_src_ready;

    cdc_byte_strobe #(
        .WIDTH (8)
    ) u_usb_to_sys_char (
        .src_clk   (clk_usb),
        .src_rst_n (rst_usb_n),
        .src_data  (usb_ascii),
        .src_valid (usb_ascii_valid),
        .src_ready (cdc_src_ready),
        .overflow  (cdc_overflow_usb),
        .dst_clk   (clk),
        .dst_rst_n (rst_sys_n),
        .dst_data  (sys_ascii),
        .dst_valid (sys_ascii_valid),
        .dst_ready (sys_ascii_ready)
    );

    logic        jtag_stalled;
    logic [15:0] jtag_wspace;

    jtag_uart_tx u_jtag_uart_tx (
        .clk         (clk),
        .rst_n       (rst_sys_n),
        .tx_data     (sys_ascii),
        .tx_valid    (sys_ascii_valid),
        .tx_ready    (sys_ascii_ready),
        .stalled     (jtag_stalled),
        .last_wspace (jtag_wspace)
    );

    logic [25:0] heartbeat_cnt;
    logic        heartbeat;
    logic        char_toggle;
    logic [1:0]  typ_meta;
    logic [1:0]  typ_sync;
    logic        conerr_meta;
    logic        conerr_sync;
    logic [1:0]  overflow_sync;

    always_ff @(posedge clk or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            heartbeat_cnt <= 26'd0;
            heartbeat     <= 1'b0;
            char_toggle   <= 1'b0;
            typ_meta      <= 2'd0;
            typ_sync      <= 2'd0;
            conerr_meta   <= 1'b0;
            conerr_sync   <= 1'b0;
            overflow_sync <= 2'b00;
        end else begin
            typ_meta      <= usb_typ;
            typ_sync      <= typ_meta;
            conerr_meta   <= usb_conerr;
            conerr_sync   <= conerr_meta;
            overflow_sync <= {overflow_sync[0], cdc_overflow_usb};

            if (heartbeat_cnt == 26'd24_999_999) begin
                heartbeat_cnt <= 26'd0;
                heartbeat     <= ~heartbeat;
            end else begin
                heartbeat_cnt <= heartbeat_cnt + 26'd1;
            end

            if (sys_ascii_valid && sys_ascii_ready) begin
                char_toggle <= ~char_toggle;
            end
        end
    end

    assign led     = heartbeat;
    assign led0    = char_toggle;
    assign leds[0] = pll_locked;
    assign leds[1] = (typ_sync != 2'd0);
    assign leds[2] = (typ_sync == 2'd1);
    assign leds[3] = conerr_sync;
    assign leds[4] = overflow_sync[1];
    assign leds[5] = jtag_stalled;
    assign leds[6] = sys_ascii_valid;
    assign leds[7] = heartbeat;

endmodule

`default_nettype wire
