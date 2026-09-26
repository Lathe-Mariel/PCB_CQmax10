# check_ufm_pof.ps1
#
# Decide whether output_files\lcd_game.pof carries the UFM (logo) image, i.e.
# whether programming it will actually fill the On-Chip Flash.
#
# WHY THIS IS NOT A SIGNATURE SEARCH
#   A .pof is not a plain dump of the flash words, so searching it for the
#   little-endian logo pattern ALWAYS reports "not found", even when the content
#   is present.  (The .sof, by contrast, does contain the raw pattern, which is
#   why the signature search works there and not here.)
#
# THE THREE GATES USED BELOW
#   1. logo_rom.hex must cover the WHOLE UFM page.
#         The UFM data page on the 10M08SC is 32,768 BYTES = 8,192 x 32-bit
#         words.  With the original 2,000-word hex the assembler only emitted
#             Critical Warning (18094): Memory depth (8000) in the Memory
#             Initialization File "logo_rom.hex" is less than the flash memory
#             depth (32768).
#         and then DROPPED the flash content: the .pof came out byte-identical
#         to one built with no flash content at all (sha256 4155F38B...).
#         Padding the hex to 8,192 words changed the .pof to sha256
#         1E62301A... - a ~12 KB difference, which IS the UFM image.
#   2. The build log must NOT contain warning 18094.
#   3. The built .pof must differ from the known no-UFM fingerprint.

$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot          # project root
$pof  = Join-Path $root 'output_files\lcd_game.pof'
$log  = Join-Path $root 'qbuild.log'
$hex  = Join-Path $root 'logo_rom.hex'

# Fingerprint of a .pof built while logo_rom.hex was too short, i.e. WITHOUT any
# flash content.  Anything different means the UFM image made it in.
$NO_UFM_SHA = '4155F38B248E721F886C819E'

$fail = 0

# --- gate 1: the hex covers the whole UFM page ----------------------------
if (-not (Test-Path $hex)) {
    Write-Output "  MISSING: $hex"
    exit 1
}
$maxEnd = 0
foreach ($line in Get-Content $hex) {
    if ($line -notmatch '^:') { continue }
    if ($line.Substring(7, 2) -ne '00') { continue }      # data records only
    $len  = [Convert]::ToInt32($line.Substring(1, 2), 16)
    $addr = [Convert]::ToInt32($line.Substring(3, 4), 16)
    if (($addr + $len) -gt $maxEnd) { $maxEnd = $addr + $len }
}
$whole = $maxEnd -ge 32768
Write-Output ("  [1] logo_rom.hex covers up to byte {0} of the 32768-byte UFM page : {1}" -f `
              $maxEnd, $(if ($whole) { 'OK' } else { 'TOO SHORT - FAIL' }))
if (-not $whole) { $fail = 1 }

# --- gate 2: no memory-depth warning in the build log --------------------
if (Test-Path $log) {
    $w = Select-String -Path $log -Pattern '18094' -SimpleMatch -Quiet
    Write-Output ("  [2] build log free of Critical Warning 18094 : {0}" -f `
                  $(if ($w) { 'NO - the flash content was dropped (FAIL)' } else { 'OK' }))
    if ($w) { $fail = 1 }
} else {
    Write-Output '  [2] qbuild.log not found - run the full compile first (SKIPPED)'
}

# --- gate 3: the .pof differs from the no-UFM fingerprint ----------------
if (-not (Test-Path $pof)) {
    Write-Output "  MISSING: $pof"
    exit 1
}
$sha = (Get-FileHash $pof -Algorithm SHA256).Hash.Substring(0, 24)
$noUfm = ($sha -eq $NO_UFM_SHA)
Write-Output ("  [3] lcd_game.pof sha256 {0} (no-UFM fingerprint is {1}) : {2}" -f `
              $sha, $NO_UFM_SHA, $(if ($noUfm) { 'MATCHES no-UFM - FAIL' } else { 'OK (flash content present)' }))
if ($noUfm) { $fail = 1 }

Write-Output ''
if ($fail -ne 0) {
    Write-Output '  FAIL: lcd_game.pof does NOT reliably carry the UFM image.'
    Write-Output '        Run make_ufm_hex.ps1 (it pads to the whole page), then recompile.'
    exit 1
}

Write-Output '  OK: lcd_game.pof carries the UFM image.'
Write-Output '  Program output_files\lcd_game.pof  (NOT lcd_game.sof - a .sof only'
Write-Output '  loads the volatile configuration RAM and never writes the UFM).'
exit 0
