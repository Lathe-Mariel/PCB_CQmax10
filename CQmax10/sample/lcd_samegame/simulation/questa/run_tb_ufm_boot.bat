@echo off
REM run_tb_ufm_boot.bat - focused UFM bootloader test.
setlocal
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
set RTL=..\..\rtl
cd /d "%~dp0"

taskkill /F /IM vsim.exe /IM vish.exe /IM vopt.exe /IM vlog.exe > nul 2>&1
if exist work rmdir /s /q work
"%QDIR%\vlib.exe" work > nul
"%QDIR%\vlog.exe" -sv "%RTL%\ufm_bootloader.sv" "%RTL%\logo_ram.sv" tb_ufm_boot.sv
if errorlevel 1 exit /b 1
"%QDIR%\vsim.exe" -c -do "run -all; quit -f" tb_ufm_boot
exit /b 0
