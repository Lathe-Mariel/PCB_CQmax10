# -------------------------------------------------------------------------- #
# CQ-MAX10-A + PMOD-USBHOST keyboard to JTAG UART sample
#
# Clocks:
#   clk     - 50 MHz board oscillator on PIN_88
#   clk_usb - 12 MHz from usb_pll_12mhz (altpll x6/25), the USB HID host clock
#
# The two clocks come from the same PLL, but the design deliberately treats
# them as asynchronous: every crossing signal goes through an explicit 2-FF
# synchronizer (typ_meta/typ_sync, conerr_meta/conerr_sync, overflow_sync in
# top.sv) or through the toggle handshake in cdc_byte_strobe. Handshake signals
# travel in BOTH directions (req_toggle usb->sys, ack_toggle sys->usb), so the
# domains must be cut symmetrically with set_clock_groups.
# -------------------------------------------------------------------------- #

create_clock -name clk -period 20.000 [get_ports clk]
derive_pll_clocks
derive_clock_uncertainty

# Asynchronous USB <-> system clock domains (every crossing is synchronized).
set_clock_groups -asynchronous \
    -group {clk} \
    -group {u_usb_pll|u_altpll|auto_generated|pll1|clk[0]}

# Board push button: asynchronous to clk, feeds the reset synchronizer chain.
set_false_path -from [get_ports rst_n]

# USB D+/D- are a low-speed USB PHY interface (1.5 Mbps NRZI, driven by the host
# core in the 12 MHz domain and sampled by its own oversampling logic). They are
# not synchronous to any clock in this design, so exclude them from I/O timing.
set_false_path -from [get_ports {usb_u1_dp usb_u1_dm usb_u2_dp usb_u2_dm}]
set_false_path -to   [get_ports {usb_u1_dp usb_u1_dm usb_u2_dp usb_u2_dm}]

# Status LEDs are slow human-visible indicators.
set_false_path -to [get_ports {led led0 leds[*]}]
