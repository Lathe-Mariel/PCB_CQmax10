vlib work
vlog -sv ../rtl/hid_keyboard_ascii.sv
vlog -sv tb_hid_keyboard_ascii.sv
vsim -c tb_hid_keyboard_ascii -do "run -all; quit -f"
