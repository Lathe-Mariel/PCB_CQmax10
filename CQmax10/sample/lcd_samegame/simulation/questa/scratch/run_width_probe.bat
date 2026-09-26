@echo off
REM run_width_probe.bat - compile and run the width_probe experiment
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
cd /d "%~dp0"
if exist work rmdir /s /q work
"%QDIR%\vlib.exe" work
"%QDIR%\vlog.exe" -sv width_probe.sv
"%QDIR%\vsim.exe" -c -do "run -all; quit -f" width_probe
