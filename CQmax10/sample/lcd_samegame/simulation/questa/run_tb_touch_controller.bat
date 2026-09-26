@echo off
REM run_tb_touch_controller.bat - run the touch controller testbench.
setlocal
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
set RTL=..\..\rtl
cd /d "%~dp0"

REM Always start from a clean library: vsim caches the optimised design under
REM work/@_opt*, and vlog does NOT refresh that cache, so after an interrupted
REM run an RTL edit can produce byte-identical output ("I fixed it but nothing
REM changed").
if exist work rmdir /s /q work
"%QDIR%\vlib.exe" work
"%QDIR%\vlog.exe" -sv "%RTL%\touch_controller.sv" tb_touch_controller.sv
if errorlevel 1 goto :fail
"%QDIR%\vsim.exe" -c -work work -do "run -all; quit -f" tb_touch_controller
if errorlevel 1 goto :fail
exit /b 0

:fail
echo *** SIMULATION FAILED ***
exit /b 1
