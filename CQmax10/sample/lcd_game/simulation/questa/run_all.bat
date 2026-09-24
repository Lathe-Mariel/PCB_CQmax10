@echo off
REM Helper: recompile everything and run each testbench, one at a time.
REM The Questa license is nodelocked and allows ONE vsim at a time, so any
REM leftover vsim is killed first and a few seconds are allowed for the
REM license to be released before the next run.
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
set RTL=..\..\rtl
cd /d "%~dp0"

if exist work rmdir /s /q work
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe /IM vish.exe >nul 2>&1
timeout /t 5 /nobreak > nul

echo === vlog ===
"%QDIR%\vlog.exe" -sv -quiet %RTL%\spi_byte_master.sv %RTL%\reset_sync.sv %RTL%\debounce.sv %RTL%\framebuffer.v %RTL%\line_draw.sv %RTL%\dot_field.sv %RTL%\game_ctrl.sv %RTL%\lcd_ili9341_ctrl.sv %RTL%\lcd_test_top.sv tb_framebuffer.sv tb_line_draw.sv tb_dot_field.sv tb_game.sv tb_rect_write.sv tb_spi_clk.sv > _vlog.txt 2>&1
echo vlog done, errors:
findstr /C:"** Error" _vlog.txt

echo === tb_framebuffer ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_framebuffer > _r_fb.txt 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"Errors:" _r_fb.txt

echo === tb_line_draw ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_line_draw > _r_ld.txt 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"Errors:" _r_ld.txt

echo === tb_dot_field ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_dot_field > _r_dots.txt 2>&1
findstr /C:"OK " /C:"PASS" /C:"FAIL" /C:"Errors:" _r_dots.txt

echo === tb_game ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_game > _r_game.txt 2>&1
findstr /C:"OK " /C:"PASS" /C:"FAIL" /C:"Errors:" _r_game.txt

echo === tb_rect_write ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_rect_write > _r_rect.txt 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"Errors:" _r_rect.txt

echo === tb_spi_clk ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_spi_clk > _r_spi.txt 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"Errors:" _r_spi.txt

echo ALL_DONE
