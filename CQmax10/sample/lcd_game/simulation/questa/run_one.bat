@echo off
REM Helper: compile everything and run ONE testbench given as %1.
REM Usage:  run_one.bat tb_orange
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
set RTL=..\..\rtl
cd /d "%~dp0"

taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe /IM vish.exe >nul 2>&1
timeout /t 5 /nobreak > nul

"%QDIR%\vlog.exe" -sv -quiet %RTL%\spi_byte_master.sv %RTL%\reset_sync.sv %RTL%\debounce.sv %RTL%\framebuffer.v %RTL%\framebuffer_pixel_src.sv %RTL%\line_draw.sv %RTL%\game_ctrl.sv %RTL%\frame_seq.sv %RTL%\lcd_ili9341_ctrl.sv %RTL%\lcd_test_top.sv %1.sv > _v_%1.txt 2>&1
echo VLOG_EXIT=%ERRORLEVEL%
findstr /C:"** Error" _v_%1.txt

"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.%1 > _r_%1.txt 2>&1
echo VSIM_EXIT=%ERRORLEVEL%
findstr /C:"PASS" /C:"FAIL" /C:"Errors:" /C:"OK " _r_%1.txt
echo DONE_%1
