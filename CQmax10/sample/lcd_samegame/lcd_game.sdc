# lcd_game.sdc
# Timing constraints for the orange-fill LCD test on the CQ-MAX10-A board.
#
# System clock: 50 MHz on PIN_88. Everything in the design runs from this
# single clock, so one create_clock covers the whole design.

create_clock -name clk -period 20.000 [get_ports {clk}]

# Inputs are asynchronous (reset button, switches) and are synchronized with
# 2-3 flops in reset_sync.sv / debounce.sv, so they are cut from the timing
# analysis.
set_false_path -from [get_ports {btn_rst sw1 sw2 touch_miso}]

# The SPI outputs (lcd_cs/lcd_sck/lcd_mosi/lcd_dc) go straight to the panel's
# registers; they are launched by clk and have no return path. Board-level
# setup/hold at the PMOD connector is what matters, and at 12.5 MHz SCK there
# is ample margin, so no output delays are needed here.

derive_clock_uncertainty
