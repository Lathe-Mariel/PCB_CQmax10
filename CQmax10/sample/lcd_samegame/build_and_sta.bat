@echo off
REM build_and_sta.bat - compile lcd_game, then dump the worst timing paths in
REM the SAME invocation (a previous Quartus step can leave a stale timing DB).
setlocal
cd /d "%~dp0"
set QDIR=H:\altera_lite\25.1std\quartus\bin64

echo === compile ===
"%QDIR%\quartus_sh.exe" --flow compile lcd_game > qbuild.log 2>&1
findstr /C:"Full Compilation was" /C:"Can't fit" /C:"170011" /C:"10119" qbuild.log

echo.
echo === worst setup paths ===
"%QDIR%\quartus_sta.exe" -t simulation\questa\report_paths.tcl lcd_game > simulation\questa\sta.log 2>&1
findstr /C:"Slack :" /C:"From :" /C:"To :" worst_setup.rpt

echo.
echo === area ===
type output_files\lcd_game.fit.summary | findstr /C:"logic elements" /C:"combinational" /C:"Fitter Status"
exit /b 0
