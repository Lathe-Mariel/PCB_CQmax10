$root = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame'
$mem  = @(Get-Content (Join-Path $root 'logo_rom.mem')) | Where-Object { $_ -match '\S' }
$out  = Join-Path $root 'tmp_cpf\logo_grid.txt'
$L = @()

# Build a palette so each distinct RGB565 colour gets a letter.  This tells us
# whether the logos are simple geometric shapes (which RTL could generate with
# no memory at all) or photographic (which need storage).
$pal = @{}
$letters = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
$next = 0
for ($i = 0; $i -lt 2000; $i++) {
    $v = $mem[$i].Trim()
    if (-not $pal.ContainsKey($v)) {
        if ($next -lt $letters.Length) { $pal[$v] = $letters[$next] } else { $pal[$v] = '?' }
        $next++
    }
}
$L += "total words = 2000, distinct colours = $($pal.Count)"

# RGB565 -> readable name for the most common colours
function C($hex) {
    $v = [Convert]::ToUInt16($hex, 16)
    $r = (($v -shr 11) -band 0x1F) * 255 / 31
    $g = (($v -shr 5)  -band 0x3F) * 255 / 63
    $b = ($v -band 0x1F) * 255 / 31
    return ('#{0:X2}{1:X2}{2:X2}' -f [int]$r, [int]$g, [int]$b)
}
$L += '--- palette (most frequent first) ---'
$pal.GetEnumerator() | Sort-Object { $c = 0; for ($i=0;$i -lt 2000;$i++){ if($mem[$i].Trim() -eq $_.Key){$c++} }; $c } -Descending |
    Select-Object -First 14 | ForEach-Object {
        $cnt = 0; for ($i=0;$i -lt 2000;$i++){ if($mem[$i].Trim() -eq $_.Key){$cnt++} }
        $L += ("    {0}  0x{1}  rgb {2}   count={3}" -f $_.Value, $_.Key, (C $_.Key), $cnt)
    }

for ($logo = 0; $logo -lt 5; $logo++) {
    $L += ''
    $L += "=== Logo$logo  (address $($logo*400) .. $($logo*400+399)) ==="
    for ($y = 0; $y -lt 20; $y++) {
        $row = ''
        for ($x = 0; $x -lt 20; $x++) {
            $row += $pal[$mem[$logo*400 + $y*20 + $x].Trim()]
        }
        $L += '    ' + $row
    }
}

$L | Set-Content $out -Encoding ASCII
Write-Output "GRID DONE -> $out"
