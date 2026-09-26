@echo off
REM ==========================================================================
REM make_pof_ufm.bat
REM
REM Generate output_files\lcd_game_ufm.pof: a MAX 10 programming file that
REM carries BOTH the FPGA configuration AND the UFM (logo) image, so a single
REM Programmer operation writes the game and the On-Chip Flash content.
REM
REM --------------------------------------------------------------------------
REM WHY THIS SCRIPT EXISTS (the root cause of the white / black panel)
REM --------------------------------------------------------------------------
REM The normal Quartus flow produces two files and NEITHER writes the UFM on
REM this device:
REM
REM   lcd_game.sof : DOES carry the UFM image, but a .sof only loads the
REM                  VOLATILE configuration RAM over JTAG.  It never touches
REM                  the NON-VOLATILE UFM, so after programming with a .sof the
REM                  UFM still reads back all ones.
REM   lcd_game.pof : carries NO UFM content at all.  The UFM IP here is
REM                  configured as Internal Configuration / Single Uncompressed
REM                  Image WITHOUT memory initialization, so the assembler has
REM                  nothing to place.
REM
REM Consequence on the board: the UFM returns 16'hFFFFFFFF for every word, so
REM ufm_bootloader copies all ones into logo_ram SUCCESSFULLY.  boot_done = 1
REM and boot_fail = 0, i.e. every LED looks healthy, while the renderer paints
REM RGB565 0xFFFF everywhere = a SOLID WHITE panel.  The boot_blank diagnostic
REM added to samegame_top turns that into a BLACK panel plus led3 lit.
REM
REM --------------------------------------------------------------------------
REM THE FIX: quartus_cpf's MAX 10 specific UFM options
REM     -o ufm_source=Page_0
REM     -o ufm_source_file=<Intel HEX or MIF holding the flash image>
REM
REM CRITICAL DETAIL - the hex must cover the WHOLE UFM page.
REM   The UFM data page on the 10M08SC is 32,768 BYTES = 8,192 x 32-bit words.
REM   A shorter file produces
REM       Critical Warning (18094): Memory depth (8000) in the Memory
REM       Initialization File "logo_rom.hex" is less than the flash memory
REM       depth (32768).
REM   and quartus_cpf then SILENTLY IGNORES it - the resulting .pof comes out
REM   byte-identical to one built without it.  make_ufm_hex.ps1 therefore pads
REM   the image out to the full page before this script runs.
REM
REM --------------------------------------------------------------------------
REM HOW TO PROGRAM THE BOARD
REM   Programmer -> Add File -> output_files\lcd_game_ufm.pof
REM   (NOT lcd_game.sof  - that leaves the UFM erased)
REM   (NOT lcd_game.pof  - that erases the UFM)
REM ==========================================================================
setlocal
cd /d "%~dp0"
set QDIR=H:\altera_lite\25.1std\quartus\bin64
set OUT=pof_ufm_result.txt

echo === 1. regenerate the UFM hex, padded to the whole UFM page === > %OUT%
powershell -NoProfile -ExecutionPolicy Bypass -File make_ufm_hex.ps1 >> %OUT% 2>&1
if errorlevel 1 goto :fail

echo. >> %OUT%
echo === 2. full compile (the assembler embeds the UFM image in the .pof) === >> %OUT%
"%QDIR%\quartus_sh.exe" --flow compile lcd_game >> %OUT% 2>&1
if errorlevel 1 goto :fail

echo. >> %OUT%
echo === 3. verify that lcd_game.pof carries the UFM image === >> %OUT%
powershell -NoProfile -ExecutionPolicy Bypass -File tmp_cpf\check_ufm_pof.ps1 >> %OUT% 2>&1
if errorlevel 1 goto :fail

echo. >> %OUT%
echo === RESULT: program output_files\lcd_game.pof === >> %OUT%
echo DONE >> %OUT%
type %OUT%
exit /b 0

:fail
echo. >> %OUT%
echo === FAILED - see the messages above === >> %OUT%
echo FAILED >> %OUT%
type %OUT%
exit /b 1
