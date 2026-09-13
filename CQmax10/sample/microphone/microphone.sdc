# ============================================================
# microphone.sdc - タイミング制約
# ============================================================

# ボード入力クロック (PIN_88) : 50 MHz
create_clock -name clk -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]

# 入力遅延 (マイク SD は FPGA が生成する SCK に同期)
set_input_delay -clock clk -max 8.000 [get_ports {mic_sd}]
set_input_delay -clock clk -min 0.000 [get_ports {mic_sd}]

# 出力遅延
set_output_delay -clock clk -max 8.000 [get_ports {lcd_cs lcd_dc lcd_mosi lcd_sck mic_sck mic_ws}]
set_output_delay -clock clk -min 0.000 [get_ports {lcd_cs lcd_dc lcd_mosi lcd_sck mic_sck mic_ws}]

derive_clock_uncertainty
