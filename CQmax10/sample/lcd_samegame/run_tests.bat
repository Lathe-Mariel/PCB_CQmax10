@echo off
REM run_tests.bat - run every testbench and print only the verdict lines.
setlocal
cd /d "%~dp0\simulation\questa"
call run_all.bat > ascii_out.log 2>&1
findstr /C:"checks=" /C:"ALL PASS" /C:"TESTBENCHES" /C:"FAILURES" /C:"FAIL " ascii_out.log
exit /b 0
