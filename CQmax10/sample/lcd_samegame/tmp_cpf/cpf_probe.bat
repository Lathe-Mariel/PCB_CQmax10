@echo off
REM cpf_probe.bat - determine how the UFM content gets (or fails to get) into a
REM programming file.  Writes everything to cpf_probe.txt so the result can be
REM read back reliably.
setlocal
cd /d "%~dp0.."
set OUT=tmp_cpf\cpf_probe.txt
set QDIR=H:\altera_lite\25.1std\quartus\bin64

echo === sof -> pof conversion === > %OUT%
"%QDIR%\quartus_cpf.exe" -c -d 10M08SCE144C8G output_files\lcd_game.sof tmp_cpf\from_sof.pof >> %OUT% 2>&1
echo cpf exit=%ERRORLEVEL% >> %OUT%

echo. >> %OUT%
echo === list of generated files === >> %OUT%
dir /b tmp_cpf >> %OUT%

echo. >> %OUT%
echo === hexout: sof -> hex (a UFM-style image?) === >> %OUT%
"%QDIR%\quartus_cpf.exe" -c --help=hexout > tmp_cpf\help_hexout.txt 2>&1
type tmp_cpf\help_hexout.txt >> %OUT%

echo DONE >> %OUT%
exit /b 0
