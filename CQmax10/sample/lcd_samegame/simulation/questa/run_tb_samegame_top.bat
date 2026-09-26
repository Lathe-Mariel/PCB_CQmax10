@echo off
REM run_tb_samegame_top.bat - top-level integration test with a UFM model.
setlocal
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
set RTL=..\..\rtl
cd /d "%~dp0"

taskkill /F /IM vsim.exe /IM vish.exe /IM vopt.exe /IM vlog.exe > nul 2>&1
if exist work_top rmdir /s /q work_top

REM separate library so this can be run without disturbing the other TBs
"%QDIR%\vlib.exe" work_top > nul
REM NOTE: samegame_top instantiates logo_flash, the generated On-Chip Flash IP.
REM The Quartus IP tree cannot be compiled here, so logo_flash_tb.sv provides a
REM module with the same name and port list that delegates to the UFM model in
REM tb_samegame_top.sv.  tb_samegame_top.sv is compiled FIRST so ufm_model_top
REM is already defined.
"%QDIR%\vlog.exe" -sv -work work_top ^
    tb_samegame_top.sv logo_flash_tb.sv ^
    "%RTL%\samegame_pkg.sv" "%RTL%\reset_sync.sv" "%RTL%\debounce.sv" ^
    "%RTL%\spi_byte_master.sv" "%RTL%\lcd_ili9341_ctrl.sv" "%RTL%\frame_seq.sv" ^
    "%RTL%\board_memory.sv" "%RTL%\floodfill_engine.sv" "%RTL%\erase_engine.sv" ^
    "%RTL%\gravity_engine.sv" "%RTL%\column_shift_engine.sv" ^
    "%RTL%\score_manager.sv" "%RTL%\rng_generator.sv" "%RTL%\game_fsm.sv" ^
    "%RTL%\logo_ram.sv" "%RTL%\lcd_renderer.sv" "%RTL%\ufm_bootloader.sv" ^
    "%RTL%\touch_controller.sv" "%RTL%\samegame_top.sv"
if errorlevel 1 exit /b 1

"%QDIR%\vsim.exe" -c -work work_top -do "run -all; quit -f" tb_samegame_top
exit /b 0
