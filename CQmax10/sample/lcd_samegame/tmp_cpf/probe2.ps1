$ErrorActionPreference = 'Continue'
$Q    = 'H:\altera_lite\25.1std\quartus\bin64'
$root = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame'
$out  = Join-Path $root 'tmp_cpf\probe2_result.txt'
$L = @()

function Hash($p) {
    if (-not (Test-Path $p)) { return 'MISSING' }
    return (Get-FileHash $p -Algorithm SHA256).Hash.Substring(0, 24)
}

# --- 1. does cpf even parse ufm_source_file?  point it at a bogus file ------
$r = & "$Q\quartus_cpf.exe" -c -o ufm_source=Page_0 -o ufm_source_file=NO_SUCH_FILE.hex `
        (Join-Path $root 'output_files\lcd_game.sof') `
        (Join-Path $root 'tmp_cpf\bogus.pof') 2>&1
$L += '=== 1. bogus ufm_source_file (does cpf notice?) ==='
$L += ($r | Select-String -Pattern 'Error|Warning|Info: Quartus Prime Convert' | ForEach-Object { $_.Line })

# --- 2. build a FULL-DEPTH hex: 32768 words, logos in 0..1999 --------------
$mem = @(Get-Content (Join-Path $root 'logo_rom.mem')) | Where-Object { $_ -match '\S' }
$fullHex = Join-Path $root 'tmp_cpf\logo_ufm_full.hex'
$sb = New-Object System.Text.StringBuilder
$wordsPerRec = 8                       # 32 data bytes per record
$total       = 32768
for ($base = 0; $base -lt $total; $base += $wordsPerRec) {
    $bytes = @()
    for ($k = 0; $k -lt $wordsPerRec; $k++) {
        $idx = $base + $k
        if ($idx -lt 2000) { $v = [Convert]::ToUInt16($mem[$idx].Trim(), 16) } else { $v = 0xFFFF }
        $bytes += [byte]($v -band 0xFF)
        $bytes += [byte](($v -shr 8) -band 0xFF)
        $bytes += [byte]0
        $bytes += [byte]0
    }
    $sum = ($bytes | Measure-Object -Sum).Sum
    $sum = ($sum + 32 + (($base -shr 8) -band 0xFF) + ($base -band 0xFF)) -band 0xFF
    $rec = ':20{0:X4}00{1}{2:X2}' -f $base, (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ''), $sum
    $sb.AppendLine($rec) | Out-Null
}
$sb.AppendLine(':00000001FF') | Out-Null
$sb.ToString() | Set-Content $fullHex -Encoding ASCII
$L += '=== 2. generated full-depth hex ==='
$L += "    file=$fullHex  words=$total  lines=$((Get-Content $fullHex).Count)"

# --- 3. cpf with the full-depth hex ---------------------------------------
$r2 = & "$Q\quartus_cpf.exe" -c -o ufm_source=Page_0 -o ufm_source_file=$fullHex `
        (Join-Path $root 'output_files\lcd_game.sof') `
        (Join-Path $root 'tmp_cpf\full_ufm.pof') 2>&1
$L += '=== 3. cpf with full-depth UFM hex ==='
$L += ($r2 | Select-String -Pattern 'Error|Warning|Critical|successful' | ForEach-Object { $_.Line })

# --- 4. compare every .pof ------------------------------------------------
$L += '=== 4. hash comparison ==='
foreach ($f in 'output_files\lcd_game.pof', 'tmp_cpf\from_sof.pof', 'tmp_cpf\bogus.pof',
               'tmp_cpf\full_ufm.pof', 'output_files\lcd_game.sof') {
    $full = Join-Path $root $f
    $sz = if (Test-Path $full) { (Get-Item $full).Length } else { '-' }
    $L += ("    {0,-30} size={1,-9} sha={2}" -f $f, $sz, (Hash $full))
}

$L | Set-Content $out -Encoding ASCII
Write-Output 'PROBE2 DONE'
