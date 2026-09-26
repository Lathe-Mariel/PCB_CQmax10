@echo off
REM run_all_to_log.bat - run the testbenches and write an ASCII report.
REM
REM Questa writes UTF-16 when its output is redirected from PowerShell, which
REM makes the log unreadable and un-greppable.  Routing through `cmd /c` gives
REM plain ASCII instead.
setlocal
cd /d "%~dp0"
call run_all.bat > raw_out.log 2>&1
findstr /C:"checks=" /C:"ALL PASS" /C:"FAILURES" /C:"TESTBENCHES" /C:"FAIL " raw_out.log
exit /b 0
