# Convert logo_rom.mem (2000 lines of 16-bit hex values) into Intel HEX
# for the On-Chip Flash (UFM) IP.  Each 32-bit UFM word holds one 16-bit
# pixel in bits [15:0]; bits [31:16] are zero.
#
# Intel HEX record:
#   ':'  LL  AAAA  TT  [DD...]  CC
#   LL = byte count, AAAA = 16-bit address, TT = 00 (data) / 01 (EOF),
#   DD = data bytes, CC = two's-complement checksum of all preceding bytes.

$src = Get-Content logo_rom.mem
$wordCount = $src.Count
$bytesPerWord = 4
$wordsPerRecord = 8
$bytesPerRecord = $bytesPerWord * $wordsPerRecord   # 32

$out = New-Object System.Text.StringBuilder

for ($recStart = 0; $recStart -lt $wordCount; $recStart += $wordsPerRecord) {
    $recWords = [Math]::Min($wordsPerRecord, $wordCount - $recStart)
    $addr = $recStart * $bytesPerWord          # byte address of this record
    $recBytes = $recWords * $bytesPerWord

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(':{0:X2}' -f $recBytes)
    [void]$sb.Append('{0:X4}' -f $addr)
    [void]$sb.Append('00')                      # record type = data
    $sum = $recBytes + (($addr -shr 8) -band 0xFF) + ($addr -band 0xFF)

    for ($j = 0; $j -lt $recWords; $j++) {
        $pix = [Convert]::ToInt32($src[$recStart + $j].Trim(), 16)
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
Write-Output "generated logo_rom.hex: $wordCount words, $([Math]::Ceiling($wordCount / $wordsPerRecord)) data records + 1 EOF"
