$ErrorActionPreference = 'Continue'
$f = 'h:\git\PCB_CQmax10\CQmax10\CQmax10.kicad_sch'
$t = Get-Content $f -Raw
$out = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame\tmp_cpf\pmod_map.txt'
$L = @()

# ---- 1. pull the Pmod_Socket pin geometry out of the embedded lib_symbols ----
$i = $t.IndexOf('(symbol "kicad8-2:Pmod_Socket"')
if ($i -lt 0) { $L += 'Pmod_Socket library symbol not found'; $L | Set-Content $out; exit }
# find the matching close paren by depth counting
$depth = 0; $j = $i
do {
    $c = $t[$j]
    if ($c -eq '(') { $depth++ }
    elseif ($c -eq ')') { $depth-- }
    $j++
} while ($depth -gt 0 -and $j -lt $t.Length)
$lib = $t.Substring($i, $j - $i)

$libPins = @{}
foreach ($m in [regex]::Matches($lib, '\(pin\s+\w+\s+\w+\s+\(at\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\)[\s\S]{0,300}?"(?:Number|name)"\s+"([^"]+)"')) {
    # placeholder, format varies
}
# KiCad 8 format: (pin passive line (at X Y R) (length L) (name "1" ...) (number "1" ...))
foreach ($m in [regex]::Matches($lib, '\(pin\s+[a-z]+\s+[a-z]+\s+\(at\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\)[\s\S]{0,400}?\(number\s+"([^"]+)"')) {
    $libPins[$m.Groups[4].Value] = @{ x = [double]$m.Groups[1].Value; y = [double]$m.Groups[2].Value }
}
$L += "Pmod_Socket library pins: $($libPins.Count)"
foreach ($k in ($libPins.Keys | Sort-Object { [int]$_ })) {
    $L += ("   pin {0,-3} offset x={1,8} y={2,8}" -f $k, $libPins[$k].x, $libPins[$k].y)
}

# ---- 2. every Pmod_Socket INSTANCE: position + reference --------------------
$insts = @()
foreach ($m in [regex]::Matches($t, '\(symbol\s+\(lib_id\s+"kicad8-2:Pmod_Socket"\)\s*\(at\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\)')) {
    $px = [double]$m.Groups[1].Value; $py = [double]$m.Groups[2].Value
    $seg = $t.Substring($m.Index, 6000)
    $rm = [regex]::Match($seg, '"Reference"\s+"([^"]+)"')
    $ref = if ($rm.Success) { $rm.Groups[1].Value } else { '?' }
    $insts += [pscustomobject]@{ ref = $ref; x = $px; y = $py }
}
$L += ''
$L += "PMOD connector instances: $($insts.Count)"
foreach ($s in $insts) { $L += ("   {0,-5} at ({1}, {2})" -f $s.ref, $s.x, $s.y) }

# ---- 3. label positions, first occurrence of each --------------------------
$rx = [regex]'\(label\s+"(IOPIN\d+)"\s*\(at\s+([-\d.]+)\s+([-\d.]+)'
$seen = @{}
foreach ($m in $rx.Matches($t)) {
    $n = $m.Groups[1].Value
    if (-not $seen.ContainsKey($n)) {
        $seen[$n] = @{ x = [double]$m.Groups[2].Value; y = [double]$m.Groups[3].Value }
    }
}
$L += ''
$L += "distinct IOPIN labels: $($seen.Count)"

# ---- 4. which connector is closest to the known LCD pins? ------------------
$lcdPins = @('IOPIN81', 'IOPIN78', 'IOPIN75', 'IOPIN77')
$best = $null; $bestScore = [double]::MaxValue
foreach ($s in $insts) {
    $score = 0.0; $n = 0
    foreach ($p in $lcdPins) {
        if ($seen.ContainsKey($p)) {
            $score += [Math]::Abs($seen[$p].x - $s.x) + [Math]::Abs($seen[$p].y - $s.y)
            $n++
        }
    }
    if ($n -eq 0) { continue }
    $avg = $score / $n
    $L += ("   {0,-5} avg distance to the 4 LCD labels = {1:N1}" -f $s.ref, $avg)
    if ($avg -lt $bestScore) { $bestScore = $avg; $best = $s }
}

$L += ''
if ($best) {
    $L += ">>> closest PMOD connector to the LCD pins: $($best.ref) at ($($best.x), $($best.y))"
    # every label within 20 units of any of this connector's pins
    $L += '--- labels close to that connector ---'
    foreach ($n in ($seen.Keys | Sort-Object)) {
        $d = [Math]::Abs($seen[$n].x - $best.x) + [Math]::Abs($seen[$n].y - $best.y)
        if ($d -lt 45) {
            $L += ("   {0,-12} at ({1,8}, {2,8})  d={3:N1}" -f $n, $seen[$n].x, $seen[$n].y, $d)
        }
    }
}

$L | Set-Content $out -Encoding ASCII
Write-Output 'PMOD MAP DONE'
