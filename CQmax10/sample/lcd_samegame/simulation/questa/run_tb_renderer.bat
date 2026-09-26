@echo off
REM run_tb_renderer.bat - compile and run tb_renderer (self-contained in this dir)
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
cd /d "%~dp0"
if exist work rmdir /s /q work
"%QDIR%\vlib.exe" work
"%QDIR%\vlog.exe" -sv ..\..\rtl\board_memory.sv ..\..\rtl\logo_ram.sv ..\..\rtl\lcd_renderer.sv tb_renderer.sv
"%QDIR%\vsim.exe" -c -do "run -all; quit -f" tb_renderer
