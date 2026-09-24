@echo off
REM Build the Quartus project from the project root and summarise the result.
set QSH=H:\altera_lite\25.1std\quartus\bin64\quartus_sh.exe
cd /d "%~dp0"
echo PWD=%CD%
if not exist lcd_game.qpf (echo NO_QPF & exit /b 1)
"%QSH%" --flow compile lcd_game > qbuild.log 2>&1
echo QUARTUS_EXIT=%ERRORLEVEL%
findstr /C:"Error (" /C:"Quartus Prime Full Compilation was successful" qbuild.log
echo ---- fit ----
findstr /C:"Total logic elements" /C:"Total registers" /C:"Total memory bits" /C:"Total pins" output_files\lcd_game.fit.summary
echo ---- timing ----
findstr /C:"Slack" output_files\lcd_game.sta.summary
echo BUILD_DONE
