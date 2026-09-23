# run_sim.tcl - Questa simulation script for the lcd_game orange-fill test
#
# Usage (from this directory):
#   set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
#   vlib work
#   vlog -sv ../../rtl/*.sv ../../rtl/*.v tb_framebuffer.sv tb_orange.sv
#   vsim -c -do run_sim.tcl
#
# or non-interactively, one test at a time:
#   vsim -c -do "run -all; quit -f" tb_framebuffer
#   vsim -c -do "run -all; quit -f" tb_orange

onerror {resume}
quietly WaveActivateNextPane {} 0

set TESTS {tb_framebuffer tb_orange}

foreach t $TESTS {
    puts "==================================================="
    puts " running $t"
    puts "==================================================="
    if {[catch {
        vsim -c -novopt work.$t
        run -all
        quit -f
    } err]} {
        puts "ERROR running $t: $err"
    }
}
