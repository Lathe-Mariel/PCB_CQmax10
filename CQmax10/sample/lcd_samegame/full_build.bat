@echo off
REM full_build.bat - full compile, then report the fit result, the worst slack
REM and whether the .pof really carries the UFM (logo) image.
REM
REM ORDER MATTERS: logo_rom.hex is regenerated FIRST, before the compile.
REM The UFM hex MUST cover the whole flash page (8192 words / 32768 bytes) or the
REM assembler only warns (18094) and silently drops the flash content, which
REM leaves the board with an erased UFM and a blank panel.  Generating it after
REM the compile would make every report one build out of date.
setlocal
cd /d "%~dp0"
set QDIR=H:\altera_lite\25.1std\quartus\bin64
set OUT=full_build_result.txt

echo === UFM hex (must cover the whole 32768-byte flash page) === > %OUT%
powershell -NoProfile -ExecutionPolicy Bypass -File make_ufm_hex.ps1 >> %OUT% 2>&1

echo. >> %OUT%
echo === compile === >> %OUT%
"%QDIR%\quartus_sh.exe" --flow compile lcd_game > qbuild.log 2>&1
findstr /C:"Full Compilation was" /C:"Can't fit" /C:"Error (170011)" /C:"Error (10119)" /C:"Error (" qbuild.log >> %OUT%

echo. >> %OUT%
echo === fit === >> %OUT%
findstr /C:"Fitter Status" /C:"Total logic elements" /C:"Total combinational functions" /C:"Total registers" /C:"Total LABs" output_files\lcd_game.fit.summary >> %OUT%

echo. >> %OUT%
echo === timing === >> %OUT%
findstr /C:"Model Setup" /C:"Model Hold" /C:"Slack" output_files\lcd_game.sta.summary >> %OUT%

echo. >> %OUT%
echo === does lcd_game.pof carry the UFM image? === >> %OUT%
powershell -NoProfile -ExecutionPolicy Bypass -File tmp_cpf\check_ufm_pof.ps1 >> %OUT% 2>&1

echo. >> %OUT%
echo === raw logo signature search (informational) === >> %OUT%
powershell -NoProfile -ExecutionPolicy Bypass -File check_pof_ufm2.ps1 >> %OUT% 2>&1
type pof_check2.txt >> %OUT%

echo DONE >> %OUT%
exit /b 0
