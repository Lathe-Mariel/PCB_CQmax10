# run_sim.tcl - Questa simulation script for the lcd_game design
#
# Usage (from this directory):
#   set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
#   vlib work
#   vlog -sv ..\..\rtl\*.sv ..\..\rtl\*.v tb_framebuffer.sv tb_line_draw.sv tb_dot_field.sv tb_game.sv tb_rect_write.sv tb_spi_clk.sv
#   vsim -batch -do "run -all; quit -f" tb_framebuffer
#
# NOTE: the nodelocked Questa license allows only ONE vsim session at a time,
# so run the testbenches one at a time. If you see "License checkout has been
# disallowed ... an instance of ModelSim is already running", a leftover
# vsim.exe still holds the license; kill it and retry. run_all.bat does this
# automatically.
#
#   vsim -batch -do "run -all; quit -f" tb_framebuffer   (fast: pure RAM/FSM checks)
#   vsim -batch -do "run -all; quit -f" tb_line_draw     (fast: words + LCD requests)
#   vsim -batch -do "run -all; quit -f" tb_dot_field     (fast: PRNG + dots + requests)
#   vsim -batch -do "run -all; quit -f" tb_game          (fast: rules + LCD requests)
#   vsim -batch -do "run -all; quit -f" tb_rect_write    (~5s: real SPI byte stream)
#   vsim -batch -do "run -all; quit -f" tb_spi_clk       (fast: measures SCK period)
onerror {resume}
quietly WaveActivateNextPane {} 0

set TESTS {tb_framebuffer tb_line_draw tb_dot_field tb_game tb_rect_write tb_spi_clk}

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
