@echo off
REM run_build_now.bat - wrapper so the build can be driven from the task runner
REM (the interactive terminal is PowerShell 5.1 and drops compound commands).
setlocal
set "PATH=%PATH%;H:\altera_lite\25.1std\quartus\bin64"
cd /d "%~dp0"
echo CWD=%CD%
if not exist ".\lcd_game.qpf" (echo ERROR: lcd_game.qpf not found in %CD% & exit /b 2)

REM Kill any leftover tools that hold qbuild.log open (an abandoned compile
REM otherwise makes the redirect silently fail).
taskkill /F /IM quartus_sh.exe /IM quartus_fit.exe /IM quartus_sta.exe /IM quartus_map.exe /IM jtagd.exe > nul 2>&1

REM IMPORTANT: do NOT redirect full_build.bat's stdout into qbuild.log.
REM full_build.bat already writes qbuild.log itself, and cmd cannot open the
REM same file twice - the inner redirect fails with "the process cannot access
REM the file", quartus_sh is never even started, and the fit summary keeps the
REM PREVIOUS build's timestamp while still looking successful.
call full_build.bat > build_stdout.txt 2>&1
echo BUILD-EXIT=%ERRORLEVEL%
echo BUILD-DONE
