@echo off
REM report_paths.bat - dump the worst timing paths of lcd_game.
setlocal
cd /d "%~dp0..\.."
"H:\altera_lite\25.1std\quartus\bin64\quartus_sta.exe" -t simulation\questa\report_paths.tcl lcd_game > simulation\questa\sta.log 2>&1
findstr /C:"Slack" /C:"Slow 1200mV 85C Model Setup" simulation\questa\sta.log
exit /b 0
