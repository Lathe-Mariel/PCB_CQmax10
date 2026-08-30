# line_game_pins.tcl
# Pin assignments for line_game_top on the MAX10 10M08SCE144C8G
# (CQ-MAX10-A core board). Run inside Quartus with:
#   Tools -> Tcl Scripts... -> select this file -> Run
# or from a shell: quartus_sh -t line_game_pins.tcl
# then re-run Fitter/Assembler.
#
# NOTE: I/O standards below assume 3.3V LVTTL, the common default for this
# board family. Check your board's schematic (CQ-MAX10-A) and the
# PMOD-TFTLCD v1.1 module before programming — adjust IO_STANDARD if it
# actually uses 2.5V/1.8V bank supplies.

package require ::quartus::project

set_location_assignment PIN_85 -to clk
set_location_assignment PIN_17 -to btn_rst
set_location_assignment PIN_62 -to Button
set_location_assignment PIN_81 -to lcd_cs
set_location_assignment PIN_78 -to lcd_mosi
set_location_assignment PIN_75 -to lcd_sck
set_location_assignment PIN_77 -to lcd_dc

set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to clk
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to btn_rst
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to Button
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to lcd_cs
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to lcd_mosi
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to lcd_sck
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to lcd_dc

# Button/reset are external pins with no on-die pull-up on MAX10 unless
# enabled explicitly — if your board doesn't already pull them up with a
# resistor, uncomment these:
# set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to btn_rst
# set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to Button

export_assignments
