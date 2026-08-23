# =============================================================================
# matrix_led.sdc - basic TimeQuest timing constraints
#
# System clock = 50 MHz (must match CLK_FREQ_HZ in top_matrix_led.sv).
# =============================================================================

create_clock -name clk -period 20.000 [get_ports {clk}]

derive_clock_uncertainty

# rst_n is asynchronous and only feeds a reset synchronizer; no need to
# constrain it as a clock. All other outputs (ROW/COL_GREEN/COL_RED/CLOCK/
# RCLOCK/CLR1/CLR2/CLR3) are slow, fully-registered, single-clock-domain
# signals, so the default clock constraint above is sufficient for timing
# closure of this design.
