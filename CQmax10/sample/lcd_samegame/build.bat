@echo off
REM build.bat - compile the lcd_game Quartus project and print the interesting
REM lines of the log.  The `cd` is inside the batch file on purpose: a leading
REM Set-Location in a compound shell command gets dropped, which silently builds
REM the WRONG directory.
setlocal
set PROJ=%~dp0
cd /d "%PROJ%"
set LOG=%~dp0qbuild.log
"H:\altera_lite\25.1std\quartus\bin64\quartus_sh.exe" --flow compile lcd_game > "%LOG%" 2>&1
findstr /C:"combinational node" /C:"Can't fit" /C:"Full Compilation was" ^
        /C:"Error (10119" /C:"Error (170" /C:"Total logic elements" /C:"LABs" "%LOG%"
exit /b 0
