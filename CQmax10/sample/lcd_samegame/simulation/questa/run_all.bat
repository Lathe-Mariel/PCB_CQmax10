@echo off
REM run_all.bat - run every testbench of the lcd_samegame project.
REM
REM The `work` library is deleted first on purpose: vsim caches the optimised
REM design under work/@_opt*, and `vlog` does NOT refresh that cache.  After a
REM killed run an RTL edit can therefore produce byte-identical output ("I
REM fixed it but nothing changed").  Always start from a clean `work`.
setlocal
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
set RTL=..\..\rtl
cd /d "%~dp0"

set FAILED=0

call :run tb_samegame      "%RTL%\board_memory.sv %RTL%\floodfill_engine.sv %RTL%\gravity_engine.sv %RTL%\column_shift_engine.sv"
if errorlevel 1 set FAILED=1

call :run tb_renderer      "%RTL%\board_memory.sv %RTL%\logo_ram.sv %RTL%\lcd_renderer.sv"
if errorlevel 1 set FAILED=1

call :run tb_game_fsm      "%RTL%\board_memory.sv %RTL%\rng_generator.sv %RTL%\floodfill_engine.sv %RTL%\erase_engine.sv %RTL%\gravity_engine.sv %RTL%\column_shift_engine.sv %RTL%\score_manager.sv %RTL%\game_fsm.sv"
if errorlevel 1 set FAILED=1

REM The UFM -> logo_ram power-up copy.  This is the only path that is exclusive
REM to real hardware; if it hangs, boot_done never asserts, game_fsm is held in
REM reset, the board stays EMPTY and the panel shows nothing but BG_COLOR.
call :run tb_ufm_boot       "%RTL%\ufm_bootloader.sv %RTL%\logo_ram.sv"
if errorlevel 1 set FAILED=1

REM The touch controller.  It was untested until the board showed that touches
REM did nothing, and two faults had hidden behind that: the pins put the touch
REM CS and MOSI on different PMOD connectors, and adc_to_x/adc_to_y divided by
REM 8192 instead of the real ADC span, so the right half of the panel could
REM never respond.  The coordinate sweep in this testbench is the regression
REM guard for the second one.
call :run tb_touch_controller "%RTL%\touch_controller.sv"
if errorlevel 1 set FAILED=1

REM Top-level integration test: the WHOLE power-up chain with the UFM modelled,
REM decoding the real LCD SPI stream.  It uses its own `work_top` library and a
REM stand-in for the generated On-Chip Flash IP (logo_flash_tb.sv), so it is
REM built separately from the other testbenches.
call :run_top
if errorlevel 1 set FAILED=1

echo.
echo ===================================================
if "%FAILED%"=="0" (echo  ALL TESTBENCHES PASSED) else (echo  *** SOME TESTBENCHES FAILED ***)
echo ===================================================
exit /b %FAILED%

:run_top
echo.
echo ===================================================
echo  running tb_samegame_top (integration)
echo ===================================================
if exist work_top rmdir /s /q work_top
"%QDIR%\vlib.exe" work_top > nul
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
if errorlevel 1 exit /b 1
exit /b 0

:run
echo.
echo ===================================================
echo  running %~1
echo ===================================================
if exist work rmdir /s /q work
"%QDIR%\vlib.exe" work > nul
"%QDIR%\vlog.exe" -sv %~2 %~1.sv
if errorlevel 1 exit /b 1
"%QDIR%\vsim.exe" -c -do "run -all; quit -f" %~1
if errorlevel 1 exit /b 1
exit /b 0
