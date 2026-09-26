# Convert logo_rom.mem (2000 lines of 16-bit hex values) into Intel HEX
# for the On-Chip Flash (UFM) IP.  Each 32-bit UFM word holds one 16-bit
# pixel in bits [15:0]; bits [31:16] are zero.
#
# Intel HEX record:
#   ':'  LL  AAAA  TT  [DD...]  CC
#   LL = byte count, AAAA = 16-bit address, TT = 00 (data) / 01 (EOF),
#   DD = data bytes, CC = two's-complement checksum of all preceding bytes.
#
# ---------------------------------------------------------------------------
# WHY THE FILE IS PADDED TO THE WHOLE UFM PAGE - do not shrink it back
# ---------------------------------------------------------------------------
# The UFM data page on the 10M08SC is 32,768 BYTES = 8,192 32-bit words.  A
# .hex that only covers the 2,000 pixels used to produce
#     Critical Warning (18094): Memory depth (8000) in the Memory
#     Initialization File "logo_rom.hex" is less than the flash memory depth
#     (32768).
# from quartus_cpf when the flash content is loaded with
#     ufm_source=Page_0 / ufm_source_file=logo_rom.hex
# and the content was then NOT included.  Writing the whole page removes the
# ambiguity and makes the file layout match what the IP expects.
# ---------------------------------------------------------------------------

$src = Get-Content logo_rom.mem
$pixelCount = ($src | Where-Object { $_ -match '\S' }).Count

# 32-bit words in one whole UFM page (8,192 words = 32,768 bytes)
$pageWords = 8192

$bytesPerWord = 4
$wordsPerRecord = 8
$bytesPerRecord = $bytesPerWord * $wordsPerRecord   # 32

$out = New-Object System.Text.StringBuilder

for ($recStart = 0; $recStart -lt $pageWords; $recStart += $wordsPerRecord) {
    $addr = $recStart * $bytesPerWord          # byte address of this record
    $recBytes = $bytesPerRecord

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(':{0:X2}' -f $recBytes)
    [void]$sb.Append('{0:X4}' -f $addr)
    [void]$sb.Append('00')                      # record type = data
    $sum = $recBytes + (($addr -shr 8) -band 0xFF) + ($addr -band 0xFF)

    for ($j = 0; $j -lt $wordsPerRecord; $j++) {
        $idx = $recStart + $j
        if ($idx -lt $pixelCount) {
            $pix = [Convert]::ToInt32($src[$idx].Trim(), 16)
        } elseif ($idx -lt 2048) {
            $pix = 0            # the 48 padding words of the 2048-deep logo_ram
        } else {
            $pix = 0xFFFF       # unused flash stays in the erased state
        }
        # little-endian 32-bit word: low byte, high byte, 0, 0
        $b0 = $pix -band 0xFF
        $b1 = ($pix -shr 8) -band 0xFF
        [void]$sb.Append('{0:X2}' -f $b0)
        [void]$sb.Append('{0:X2}' -f $b1)
        [void]$sb.Append('00')
        [void]$sb.Append('00')
        $sum += $b0 + $b1
    }
    $sum = $sum -band 0xFF
    $cksum = (0x100 - $sum) -band 0xFF
    [void]$sb.Append('{0:X2}' -f $cksum)
    [void]$out.AppendLine($sb.ToString())
}

# EOF record
[void]$out.AppendLine(':00000001FF')

Set-Content -Path logo_rom.hex -Value $out.ToString() -NoNewline
Write-Output "generated logo_rom.hex: $pixelCount pixels padded to $pageWords words ($($pageWords*4) bytes), $([Math]::Ceiling($pageWords / $wordsPerRecord)) data records + 1 EOF"

