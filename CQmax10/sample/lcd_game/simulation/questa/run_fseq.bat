@echo off
REM Build and run the focused frame_seq pacing test (no SPI, fast).
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\LR-189312_License.dat
set QDIR=H:\altera_lite\25.1std\questa_fse\win64
set RTL=..\..\rtl
cd /d "%~dp0"

taskkill /F /IM vsim.exe /IM vsimk.exe /IM vopt.exe /IM vish.exe >nul 2>&1
timeout /t 6 /nobreak > nul

"%QDIR%\vlog.exe" -sv -quiet %RTL%\frame_seq.sv tb_frame_seq.sv > _v_fseq.txt 2>&1
echo VLOG_EXIT=%ERRORLEVEL%
findstr /C:"** Error" _v_fseq.txt

"%QDIR%\vsim.exe" -batch -do "run -all; quit -f" work.tb_frame_seq > _r_fseq.txt 2>&1
echo VSIM_EXIT=%ERRORLEVEL%
echo ==================== OUTPUT ====================
type _r_fseq.txt
echo FSEQ_DONE
