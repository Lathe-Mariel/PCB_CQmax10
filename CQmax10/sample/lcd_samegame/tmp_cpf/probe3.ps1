$ErrorActionPreference = 'Continue'
$Q    = 'H:\altera_lite\25.1std\quartus\bin64'
$root = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame'
$out  = Join-Path $root 'tmp_cpf\probe3_result.txt'
$L = @()

function HexRec([int]$addr, [byte[]]$bytes) {
    $sum = 32 + (($addr -shr 8) -band 0xFF) + ($addr -band 0xFF)
    foreach ($b in $bytes) { $sum += $b }
    $sum = $sum -band 0xFF
    return (':20{0:X4}00{1}{2:X2}' -f $addr, (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ''), $sum)
}

# UFM page 0 on 10M08SC is 32,768 BYTES = 8,192 x 32-bit words.
# The earlier attempt only supplied 2,000 words, which is why cpf reported
#   "Memory depth (8000) ... less than the flash memory depth (32768)"
# and then silently ignored the file.  Fill the whole page instead.
$mem  = @(Get-Content (Join-Path $root 'logo_rom.mem')) | Where-Object { $_ -match '\S' }
$TOTW = 8192
$hex  = Join-Path $root 'tmp_cpf\logo_ufm_8192.hex'
$L += '=== generated full-page UFM hex ==='
$sb = New-Object System.Text.StringBuilder
for ($base = 0; $base -lt $TOTW; $base += 8) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    for ($k = 0; $k -lt 8; $k++) {
        $idx = $base + $k
        if ($idx -lt 2000) { $v = [Convert]::ToUInt16($mem[$idx].Trim(), 16) }
        elseif ($idx -lt 2048) { $v = 0x0000 }      # logo_ram padding words
        else { $v = 0xFFFF }                        # unused flash stays erased
        $bytes.Add([byte]($v -band 0xFF)); $bytes.Add([byte](($v -shr 8) -band 0xFF))
        $bytes.Add(0); $bytes.Add(0)
    }
    $sb.AppendLine((HexRec $base $bytes.ToArray())) | Out-Null
}
$sb.AppendLine(':00000001FF') | Out-Null
$sb.ToString() | Set-Content $hex -Encoding ASCII
$L += "    $hex"
$L += "    words=$TOTW  bytes=$($TOTW*4)  lines=$((Get-Content $hex).Count)"

# --- attempt A: -o ufm_source_file, no -d --------------------------------
$poA = Join-Path $root 'tmp_cpf\ufmA.pof'
$rA = & "$Q\quartus_cpf.exe" -c -o ufm_source=Page_0 -o "ufm_source_file=$hex" `
        (Join-Path $root 'output_files\lcd_game.sof') $poA 2>&1
$L += '=== A: cpf -o ufm_source=Page_0 -o ufm_source_file=<full hex> (no -d) ==='
$L += ($rA | Select-String -Pattern 'Error|Warning|Critical|successful' | ForEach-Object { $_.Line })

# --- attempt B: same but WITH -d -----------------------------------------
$poB = Join-Path $root 'tmp_cpf\ufmB.pof'
$rB = & "$Q\quartus_cpf.exe" -c -d 10M08SCE144C8G -o ufm_source=Page_0 -o "ufm_source_file=$hex" `
        (Join-Path $root 'output_files\lcd_game.sof') $poB 2>&1
$L += '=== B: same WITH -d 10M08SCE144C8G ==='
$L += ($rB | Select-String -Pattern 'Error|Warning|Critical|successful' | ForEach-Object { $_.Line })

# --- attempt C: let cpf write its own option file ------------------------
$optFile = Join-Path $root 'tmp_cpf\auto_option.txt'
$rC = & "$Q\quartus_cpf.exe" -w $optFile 2>&1
$L += '=== C: quartus_cpf -w (auto option file) ==='
$L += ($rC | Out-String)
if (Test-Path $optFile) {
    $L += "    generated: $optFile"
    $L += (Get-Content $optFile | Select-String -Pattern 'ufm|UFM|flash' | ForEach-Object { '    ' + $_.Line })
}

# --- hash comparison ------------------------------------------------------
$L += '=== hashes ==='
foreach ($f in 'output_files\lcd_game.pof', 'tmp_cpf\ufmA.pof', 'tmp_cpf\ufmB.pof') {
    $full = Join-Path $root $f
    if (Test-Path $full) {
        $L += ("    {0,-26} size={1,-9} sha={2}" -f $f, (Get-Item $full).Length,
               (Get-FileHash $full -Algorithm SHA256).Hash.Substring(0, 24))
    } else { $L += ("    {0,-26} MISSING" -f $f) }
}

$L | Set-Content $out -Encoding ASCII
Write-Output 'PROBE3 DONE'
