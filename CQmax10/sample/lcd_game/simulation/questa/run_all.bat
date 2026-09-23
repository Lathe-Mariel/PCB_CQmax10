@echo off
REM Helper: recompile everything and run each testbench, one at a time.
REM The Questa license is nodelocked and allows ONE vsim at a time, so any
REM leftover vsim is killed first and a few seconds are allowed for the
REM license to be released before the next run.
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
set RTL=..\..\rtl
cd /d "%~dp0"

taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe /IM vish.exe >nul 2>&1
timeout /t 5 /nobreak > nul

echo === vlog ===
"%QDIR%\vlog.exe" -sv -quiet %RTL%\spi_byte_master.sv %RTL%\reset_sync.sv %RTL%\debounce.sv %RTL%\framebuffer.v %RTL%\framebuffer_pixel_src.sv %RTL%\line_draw.sv %RTL%\game_ctrl.sv %RTL%\frame_seq.sv %RTL%\lcd_ili9341_ctrl.sv %RTL%\lcd_test_top.sv tb_framebuffer.sv tb_line_draw.sv tb_game.sv tb_orange.sv tb_spi_clk.sv tb_frame_seq.sv > _vlog.txt 2>&1
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

echo === tb_game ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_game > _r_game.txt 2>&1
findstr /C:"OK " /C:"PASS" /C:"FAIL" /C:"Errors:" _r_game.txt

echo === tb_orange ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_orange > _r_orange.txt 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"Errors:" _r_orange.txt

echo === tb_spi_clk ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_spi_clk > _r_spi.txt 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"Errors:" _r_spi.txt

echo === tb_frame_seq ===
taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe >nul 2>&1
timeout /t 5 /nobreak > nul
"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_frame_seq > _r_fseq.txt 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"Errors:" _r_fseq.txt

echo ALL_DONE
