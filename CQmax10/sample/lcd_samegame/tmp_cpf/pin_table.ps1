$ErrorActionPreference = 'Continue'
$f = 'h:\git\PCB_CQmax10\CQmax10\CQmax10.kicad_sch'
$t = Get-Content $f -Raw
$out = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame\tmp_cpf\pin_table.txt'
$L = @()

# --- Pmod_Socket pin offsets from the embedded library symbol --------------
$i = $t.IndexOf('(symbol "kicad8-2:Pmod_Socket"')
$depth = 0; $j = $i
do { $c = $t[$j]; if ($c -eq '(') { $depth++ } elseif ($c -eq ')') { $depth-- }; $j++ } while ($depth -gt 0 -and $j -lt $t.Length)
$lib = $t.Substring($i, $j - $i)
$pinOff = @{}
foreach ($m in [regex]::Matches($lib, '\(pin\s+[a-z]+\s+[a-z]+\s+\(at\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\)[\s\S]{0,400}?\(number\s+"([^"]+)"')) {
    $pinOff[[int]$m.Groups[4].Value] = @{ x = [double]$m.Groups[1].Value; y = [double]$m.Groups[2].Value }
}

# --- all IOPIN labels -----------------------------------------------------
$labels = @()
foreach ($mm in [regex]::Matches($t, '\(label\s+"(IOPIN\d+)"\s*\(at\s+([-\d.]+)\s+([-\d.]+)')) {
    $labels += [pscustomobject]@{ name = $mm.Groups[1].Value; x = [double]$mm.Groups[2].Value; y = [double]$mm.Groups[3].Value }
}

# --- all Pmod_Socket instances with their reference ----------------------
$insts = @()
foreach ($mm in [regex]::Matches($t, '\(symbol\s+\(lib_id\s+"kicad8-2:Pmod_Socket"\)\s*\(at\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\)')) {
    $seg = $t.Substring($mm.Index, 6000)
    $rm = [regex]::Match($seg, '"Reference"\s+"([^"]+)"')
    $ref = if ($rm.Success) { $rm.Groups[1].Value } else { '?' }
    $insts += [pscustomobject]@{ ref = $ref; x = [double]$mm.Groups[1].Value; y = [double]$mm.Groups[2].Value }
}

# Which net has how many label instances (a net with several labels means the
# same signal is routed to several places, e.g. a connector pin AND the FPGA).
$counts = @{}
foreach ($lb in $labels) { if ($counts.ContainsKey($lb.name)) { $counts[$lb.name]++ } else { $counts[$lb.name] = 1 } }

$known = @{ '81' = 'lcd_cs'; '78' = 'lcd_mosi'; '75' = 'lcd_sck'; '77' = 'lcd_dc' }

foreach ($s in ($insts | Sort-Object ref)) {
    $L += "=== $($s.ref) at ($($s.x), $($s.y)) ==="
    foreach ($n in 1..12) {
        if (-not $pinOff.ContainsKey($n)) { continue }
        $px = $s.x + $pinOff[$n].x
        $py = $s.y - $pinOff[$n].y
        $nb = $null; $nd = [double]::MaxValue
        foreach ($lb in $labels) {
            $d = [Math]::Sqrt([Math]::Pow($lb.x - $px, 2) + [Math]::Pow($lb.y - $py, 2))
            if ($d -lt $nd) { $nd = $d; $nb = $lb }
        }
        if ($nd -lt 12) {
            $num = $nb.name -replace 'IOPIN', ''
            $tag = if ($known.ContainsKey($num)) { '   <- ' + $known[$num] } else { '' }
            $L += ("   pin {0,2} : {1,-11} instances={2}{3}" -f $n, $nb.name, $counts[$nb.name], $tag)
        } else {
            $L += ("   pin {0,2} : --" -f $n)
        }
    }
    $L += ''
}

$L += '=== nets routed to more than one physical point ==='
foreach ($k in ($counts.Keys | Sort-Object { [int]($_ -replace 'IOPIN','') })) {
    if ($counts[$k] -gt 1) { $L += ("   {0,-11} x{1}" -f $k, $counts[$k]) }
}

$L | Set-Content $out -Encoding ASCII
Write-Output 'PIN TABLE DONE'
