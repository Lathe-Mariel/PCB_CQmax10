$ErrorActionPreference = 'Continue'
$f = 'h:\git\PCB_CQmax10\CQmax10\CQmax10.kicad_sch'
$t = Get-Content $f -Raw
$out = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame\tmp_cpf\j5_pins.txt'
$L = @()

# ---- Pmod_Socket pin offsets from the embedded library symbol -------------
$i = $t.IndexOf('(symbol "kicad8-2:Pmod_Socket"')
$depth = 0; $j = $i
do { $c = $t[$j]; if ($c -eq '(') { $depth++ } elseif ($c -eq ')') { $depth-- }; $j++ } while ($depth -gt 0 -and $j -lt $t.Length)
$lib = $t.Substring($i, $j - $i)

$pinOff = @{}
foreach ($m in [regex]::Matches($lib, '\(pin\s+[a-z]+\s+[a-z]+\s+\(at\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\)[\s\S]{0,400}?\(number\s+"([^"]+)"')) {
    $pinOff[[int]$m.Groups[4].Value] = @{ x = [double]$m.Groups[1].Value; y = [double]$m.Groups[2].Value }
}

# ---- locate J5 ------------------------------------------------------------
$m = [regex]::Match($t, '\(symbol\s+\(lib_id\s+"kicad8-2:Pmod_Socket"\)\s*\(at\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\)')
$best = $null
foreach ($mm in [regex]::Matches($t, '\(symbol\s+\(lib_id\s+"kicad8-2:Pmod_Socket"\)\s*\(at\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\)')) {
    $seg = $t.Substring($mm.Index, 6000)
    $rm = [regex]::Match($seg, '"Reference"\s+"([^"]+)"')
    if ($rm.Success -and $rm.Groups[1].Value -eq 'J5') {
        $best = @{ x = [double]$mm.Groups[1].Value; y = [double]$mm.Groups[2].Value }
        break
    }
}
$L += ("J5 placed at ({0}, {1})" -f $best.x, $best.y)

# ---- every IOPIN label, all occurrences ----------------------------------
$labels = @()
foreach ($mm in [regex]::Matches($t, '\(label\s+"(IOPIN\d+)"\s*\(at\s+([-\d.]+)\s+([-\d.]+)')) {
    $labels += [pscustomobject]@{
        name = $mm.Groups[1].Value
        x    = [double]$mm.Groups[2].Value
        y    = [double]$mm.Groups[3].Value
    }
}

# ---- nearest label to each pin connection point --------------------------
# KiCad symbol +y is UP while schematic +y is DOWN, so screen_y = inst_y - local_y
$L += ''
$L += 'pin | screen x,y        | nearest label      | distance'
$L += '----+-------------------+--------------------+---------'
foreach ($n in 1..12) {
    if (-not $pinOff.ContainsKey($n)) { continue }
    $px = $best.x + $pinOff[$n].x
    $py = $best.y - $pinOff[$n].y
    $nb = $null; $nd = [double]::MaxValue
    foreach ($lb in $labels) {
        $d = [Math]::Sqrt([Math]::Pow($lb.x - $px, 2) + [Math]::Pow($lb.y - $py, 2))
        if ($d -lt $nd) { $nd = $d; $nb = $lb }
    }
    $flag = if ($nd -lt 12) { '' } else { '   (no label nearby)' }
    $L += ("{0,3} | ({1,8:N2},{2,7:N2}) | {3,-18} | {4,6:N1}{5}" -f $n, $px, $py, $nb.name, $nd, $flag)
}

$L | Set-Content $out -Encoding ASCII
Write-Output 'J5 PIN MAP DONE'
