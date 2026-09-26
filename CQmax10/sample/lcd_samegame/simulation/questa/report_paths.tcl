# report_paths.tcl - dump the worst setup paths of the compiled design.
#
# Usage:
#   quartus_sta -t report_paths.tcl lcd_game
#
# NOTE: report_timing has NO -panel option in this Quartus version; write the
# report to a file instead.
project_open [lindex $argv 0]
create_timing_netlist
read_sdc
update_timing_netlist

report_timing -setup -npaths 20 -detail path_only -file worst_setup.rpt
report_timing -hold  -npaths 10 -detail path_only -file worst_hold.rpt

delete_timing_netlist
project_close
