# run_sim.tcl - Questa simulation script for the lcd_game design
#
# Usage (from this directory):
#   set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
#   vlib work
#   vlog -sv ..\..\rtl\*.sv ..\..\rtl\*.v tb_framebuffer.sv tb_line_draw.sv tb_game.sv tb_orange.sv
#   vsim -batch -do "run -all; quit -f" tb_framebuffer
#
# NOTE: the nodelocked Questa license allows only ONE vsim session at a time,
# so run the testbenches one at a time. If you see "License checkout has been
# disallowed ... an instance of ModelSim is already running", a leftover
# vsim.exe still holds the license; kill it and retry. run_all.bat does this
# automatically.
#
#   vsim -batch -do "run -all; quit -f" tb_framebuffer
#   vsim -batch -do "run -all; quit -f" tb_line_draw
#   vsim -batch -do "run -all; quit -f" tb_game
#   vsim -batch -do "run -all; quit -f" tb_orange     (~2.5 min: real SPI transfer)
#   vsim -batch -do "run -all; quit -f" tb_fps        (~4 min: measures the frame rate)
onerror {resume}
quietly WaveActivateNextPane {} 0

set TESTS {tb_framebuffer tb_line_draw tb_game tb_orange tb_spi_clk tb_frame_seq tb_fps}

foreach t $TESTS {
    puts "==================================================="
    puts " running $t"
    puts "==================================================="
    if {[catch {
        vsim -batch work.$t
        run -all
        quit -f
    } err]} {
        puts "ERROR running $t: $err"
    }
}
