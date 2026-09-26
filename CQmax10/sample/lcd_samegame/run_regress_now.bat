@echo off
REM run_regress_now.bat - run the whole testbench regression into regress.log.
REM Written as a .bat because the task/terminal here is PowerShell 5.1, which
REM does not accept `&&` as a statement separator.
setlocal
set "PATH=%PATH%;H:\altera_lite\25.1std\questa_fse\win64"
cd /d "%~dp0"
taskkill /F /IM vsim.exe /IM vish.exe /IM vopt.exe /IM vlog.exe > nul 2>&1
call run_tests.bat > regress2.log 2>&1
echo REGRESSION-DONE
