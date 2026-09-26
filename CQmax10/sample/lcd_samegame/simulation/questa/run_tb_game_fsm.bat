@echo off
REM run_tb_game_fsm.bat - compile and run tb_game_fsm
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
cd /d "%~dp0"
if exist work rmdir /s /q work
"%QDIR%\vlib.exe" work
"%QDIR%\vlog.exe" -sv ..\..\rtl\board_memory.sv ..\..\rtl\rng_generator.sv ^
    ..\..\rtl\floodfill_engine.sv ..\..\rtl\erase_engine.sv ^
    ..\..\rtl\gravity_engine.sv ..\..\rtl\column_shift_engine.sv ^
    ..\..\rtl\score_manager.sv ..\..\rtl\game_fsm.sv tb_game_fsm.sv
"%QDIR%\vsim.exe" -c -do "run -all; quit -f" tb_game_fsm
