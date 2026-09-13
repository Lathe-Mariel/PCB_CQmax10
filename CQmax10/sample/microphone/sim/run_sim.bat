@echo off
REM ============================================================
REM run_sim.bat - テストベンチを Questa (Altera Starter FPGA Edition) で実行する
REM
REM   run_sim.bat          すべてのテストベンチを実行
REM   run_sim.bat i2s      i2s_rx のみ
REM   run_sim.bat lcd      lcd_wave のみ
REM   run_sim.bat avg      moving_avg のみ
REM
REM Questa はライセンスのチェックアウトに SALT_LICENSE_SERVER を使う。
REM LM_LICENSE_FILE を設定しても vsim は起動できないので注意。
REM ============================================================
set QUESTA_ROOT=H:\altera_lite\25.1std
set QUESTA=%QUESTA_ROOT%\questa_fse\win64
set LICENSE=%QUESTA_ROOT%\licenses\LR-189312_License.dat

if not exist "%QUESTA%\vsim.exe" (
    echo ERROR: Questa not found at %QUESTA%
    exit /b 1
)
if not exist "%LICENSE%" (
    echo ERROR: license file not found at %LICENSE%
    exit /b 1
)

set PATH=%QUESTA%;%PATH%
set SALT_LICENSE_SERVER=%LICENSE%
cd /d %~dp0

set TARGET=%1
if "%TARGET%"=="" set TARGET=all

if exist work rmdir /s /q work
vlib work
if errorlevel 1 goto fail

if "%TARGET%"=="i2s" goto i2s
if "%TARGET%"=="lcd" goto lcd
if "%TARGET%"=="avg" goto avg

:all
call :run_i2s
call :run_lcd
call :run_avg
goto done

:i2s
call :run_i2s
goto done

:lcd
call :run_lcd
goto done

:avg
call :run_avg
goto done

:run_i2s
echo.
echo ============================================
echo  i2s_rx testbench
echo ============================================
vlog -sv ..\rtl\i2s_rx.sv tb_i2s_rx.sv
vsim -c -do "run -all; quit -f" tb_i2s_rx
goto :eof

:run_lcd
echo.
echo ============================================
echo  lcd_wave testbench
echo ============================================
vlog -sv ..\rtl\lcd_wave.sv tb_lcd_ctrl.sv
vsim -c -do "run -all; quit -f" tb_lcd_ctrl
goto :eof

:run_avg
echo.
echo ============================================
echo  moving_avg testbench
echo ============================================
vlog -sv ..\rtl\moving_avg.sv tb_moving_avg.sv
vsim -c -do "run -all; quit -f" tb_moving_avg
goto :eof

:fail
echo ERROR: vlib failed
exit /b 1

:done
echo.
echo === DONE ===
