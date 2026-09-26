$ErrorActionPreference = 'Continue'
$f   = 'h:\git\PCB_CQmax10\CQmax10\CQmax10.kicad_pcb'
$out = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame\tmp_cpf\pcb_pins.txt'
$L = @()

$t = Get-Content $f -Raw
$L += "pcb size = $($t.Length) chars"

# Footprints: (footprint "LIB:NAME" (at X Y R) ... (property "Reference" "J5" ...) ... pads ... )
# Walk each footprint block, capture its reference and every pad's number + net.
$fpRx = [regex]'\(footprint\s+"([^"]+)"'
$idx = 0
$found = 0
while ($true) {
    $m = $fpRx.Match($t, $idx)
    if (-not $m.Success) { break }
    # find the matching closing paren for this footprint
    $start = $m.Index
    $depth = 0; $i = $start
    do { $c = $t[$i]; if ($c -eq '(') { $depth++ } elseif ($c -eq ')') { $depth-- }; $i++ } while ($depth -gt 0 -and $i -lt $t.Length)
    $block = $t.Substring($start, $i - $start)
    $idx = $i

    $lib = $m.Groups[1].Value
    if ($lib -notmatch 'Pmod') { continue }
    $rm = [regex]::Match($block, '\(property\s+"Reference"\s+"([^"]+)"')
    $ref = if ($rm.Success) { $rm.Groups[1].Value } else { '?' }
    $found++
    $L += ''
    $L += "=== $ref   ($lib) ==="

    foreach ($pm in [regex]::Matches($block, '\(pad\s+"?([^"\s]+)"?[\s\S]{0,400}?\(net\s+(\d+)\s+"([^"]+)"')) {
        $padno = $pm.Groups[1].Value
        $net   = $pm.Groups[3].Value
        $L += ("   pad {0,-3} : {1}" -f $padno, $net)
    }
}
$L += ''
$L += "Pmod footprints found = $found"

$L | Set-Content $out -Encoding ASCII
Write-Output "PCB PINS DONE ($found)"
