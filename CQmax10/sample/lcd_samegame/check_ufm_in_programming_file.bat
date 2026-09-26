@echo off
REM check_ufm_in_programming_file.bat
REM
REM Check that the programming files really carry the UFM logo image.
REM
REM BACKGROUND - read this before programming the board
REM --------------------------------------------------
REM check_pof_ufm2.ps1 searches the programming files for the logo0 signature
REM (the first 12 pixels as little-endian 32-bit UFM words).  Measured result
REM for this project:
REM
REM     lcd_game.sof : FOUND (1 hit, offset 415625)   <- UFM content present
REM     lcd_game.pof : NOT FOUND in any packing, and only 2 coincidental
REM                    occurrences of the 0x00EA word in the whole file
REM
REM The `.pof` produced by this project does NOT carry the On-Chip Flash (UFM)
REM initialisation content, so programming the MAX 10's internal configuration
REM flash from it leaves the UFM blank.  Consequence on the board:
REM     UFM blank -> logo_ram filled with zeros -> boot_done DOES assert
REM     (the copy "succeeds", it just copies zeros) -> the game runs and the
REM     renderer paints 16'h0000 for every pixel -> SOLID BLACK PANEL,
REM     while every LED still blinks because the frame scan is perfectly fine.
REM
REM WHAT TO DO
REM -----------
REM   * Program with lcd_game.sof over JTAG - that file DOES contain the UFM
REM     content, and the project's own lcd_game.cdf already does exactly this.
REM   * `.sofp` (sof + flash content) cannot be produced by `quartus_cpf -c` on
REM     this device: the target flash is the MAX 10 INTERNAL one, not an
REM     external configuration device, so cpf rejects the extension.
REM
REM This script therefore VERIFIES rather than converts.
setlocal
cd /d "%~dp0"

echo === programming files present ===
if exist output_files\lcd_game.sof echo   output_files\lcd_game.sof  (JTAG - contains UFM)
if exist output_files\lcd_game.pof echo   output_files\lcd_game.pof  (config flash - NO UFM)
echo.

echo === logo0 signature search ===
powershell -NoProfile -ExecutionPolicy Bypass -File check_pof_ufm2.ps1
type pof_check2.txt

echo.
echo Reminder: a "NOT FOUND" for the .pof is the black-panel cause.
echo           Program the .sof over JTAG.
exit /b 0
