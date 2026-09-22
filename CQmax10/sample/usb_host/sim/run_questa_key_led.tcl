vlib work
vlog -sv ../rtl/key_led_stretch.sv
vlog -sv tb_key_led_stretch.sv
vsim -c tb_key_led_stretch -do "run -all; quit -f"
