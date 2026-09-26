@echo off
REM sta_paths.bat - dump the worst timing paths of the compiled lcd_game design.
setlocal
cd /d "%~dp0"
"H:\altera_lite\25.1std\quartus\bin64\quartus_sta.exe" -t simulation\questa\report_paths.tcl lcd_game > simulation\questa\sta.log 2>&1
echo --- setup paths ---
type worst_setup.rpt 2>nul
exit /b 0
