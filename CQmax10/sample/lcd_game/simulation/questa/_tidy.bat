@echo off
REM Remove Questa/vlog scratch output and the compiled library.
REM Keeps: run_all.bat, run_one.bat, run_spi.bat, run_sim.tcl, _killsim.bat, _tidy.bat, tb_*.sv
cd /d "%~dp0"

del /q _vlog.txt        >nul 2>&1
del /q _all.txt         >nul 2>&1
del /q _r_fb.txt _r_ld.txt _r_game.txt _r_rect.txt _r_spi.txt >nul 2>&1
del /q _r_dots.txt _r_tb_dot_field.txt >nul 2>&1
del /q _r_tb_rect_write.txt _r_tb_spi_clk.txt >nul 2>&1
del /q _v_tb_rect_write.txt _v_tb_spi_clk.txt _v_tb_dot_field.txt >nul 2>&1
del /q _rect_out.txt _spi_out.txt _game_out.txt _orange_out.txt >nul 2>&1
del /q _dots_out.txt _fps_run.txt _probe.txt _build_out.txt >nul 2>&1
del /q transcript vsim.wlf >nul 2>&1
del /q lcd_game.vo lcd_game.sft >nul 2>&1

if exist work rmdir /s /q work >nul 2>&1

echo TIDY_DONE
dir /b
