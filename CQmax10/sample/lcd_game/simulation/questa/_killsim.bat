@echo off
REM Kill every simulator process and report how many remain.
taskkill /F /IM vsim.exe  >nul 2>&1
taskkill /F /IM vsimk.exe >nul 2>&1
taskkill /F /IM vopt.exe  >nul 2>&1
taskkill /F /IM vish.exe  >nul 2>&1
taskkill /F /IM vlog.exe  >nul 2>&1
timeout /t 8 /nobreak >nul
tasklist /FI "IMAGENAME eq vsim.exe" | findstr /C:"vsim.exe" >nul
if errorlevel 1 (echo SIM_CLEAR) else (echo SIM_STILL_RUNNING)
