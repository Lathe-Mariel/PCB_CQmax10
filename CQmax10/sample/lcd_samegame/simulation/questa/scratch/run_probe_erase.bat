@echo off
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
cd /d "%~dp0"
if exist work rmdir /s /q work
"%QDIR%\vlib.exe" work
"%QDIR%\vlog.exe" -sv ..\..\..\rtl\erase_engine.sv probe_erase.sv
"%QDIR%\vsim.exe" -c -do "run -all; quit -f" probe_erase
