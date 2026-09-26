$root = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame'
$out  = Join-Path $root 'tmp_cpf\verify_ufm_pof.txt'
$L = @()

$mem = @(Get-Content (Join-Path $root 'logo_rom.mem')) | Where-Object { $_ -match '\S' }
$pof = Join-Path $root 'output_files\lcd_game_ufm.pof'
$b   = [IO.File]::ReadAllBytes($pof)

function FindPat([byte[]]$hay, [byte[]]$pat) {
    for ($i = 0; $i -le $hay.Length - $pat.Length; $i++) {
        if ($hay[$i] -eq $pat[0]) {
            $ok = $true
            for ($j = 1; $j -lt $pat.Length; $j++) { if ($hay[$i+$j] -ne $pat[$j]) { $ok = $false; break } }
            if ($ok) { return $i }
        }
    }
    return -1
}

$L += "pof = $pof  size=$($b.Length)"

# Try several plausible on-disk encodings of the first 8 pixels (0x00EA x3,
# 0x0088, 0x090A, 0x63B2, 0xBE19, 0xEF7E).
$pix = 0..7 | ForEach-Object { [Convert]::ToUInt16($mem[$_].Trim(), 16) }

$variants = @{}
# A: 32-bit LE word, pixel in low half
$l = New-Object System.Collections.Generic.List[byte]
foreach ($p in $pix) { $l.Add([byte]($p -band 0xFF)); $l.Add([byte](($p -shr 8) -band 0xFF)); $l.Add(0); $l.Add(0) }
$variants['LE32 low-half'] = $l.ToArray()
# B: plain 16-bit LE
$l = New-Object System.Collections.Generic.List[byte]
foreach ($p in $pix) { $l.Add([byte]($p -band 0xFF)); $l.Add([byte](($p -shr 8) -band 0xFF)) }
$variants['16-bit LE'] = $l.ToArray()
# C: plain 16-bit BE
$l = New-Object System.Collections.Generic.List[byte]
foreach ($p in $pix) { $l.Add([byte](($p -shr 8) -band 0xFF)); $l.Add([byte]($p -band 0xFF)) }
$variants['16-bit BE'] = $l.ToArray()
# D: 32-bit BE word
$l = New-Object System.Collections.Generic.List[byte]
foreach ($p in $pix) { $l.Add(0); $l.Add(0); $l.Add([byte](($p -shr 8) -band 0xFF)); $l.Add([byte]($p -band 0xFF)) }
$variants['BE32 low-half'] = $l.ToArray()
# E: 32-bit word, pixel in HIGH half
$l = New-Object System.Collections.Generic.List[byte]
foreach ($p in $pix) { $l.Add(0); $l.Add(0); $l.Add([byte]($p -band 0xFF)); $l.Add([byte](($p -shr 8) -band 0xFF)) }
$variants['LE32 high-half'] = $l.ToArray()

$L += '--- signature search in lcd_game_ufm.pof ---'
foreach ($k in $variants.Keys) {
    $L += ("    {0,-16} @ {1}" -f $k, (FindPat $b $variants[$k]))
}

# How much does the UFM .pof differ from the plain one, and where?
$a = [IO.File]::ReadAllBytes((Join-Path $root 'output_files\lcd_game.pof'))
$diff = 0; $first = -1; $last = -1
for ($i = 0; $i -lt [Math]::Min($a.Length, $b.Length); $i++) {
    if ($a[$i] -ne $b[$i]) { $diff++; if ($first -lt 0) { $first = $i }; $last = $i }
}
$L += '--- difference from the plain .pof ---'
$L += "    differing bytes=$diff  first=$first  last=$last"

# show the header area where the UFM block likely starts
$L += '--- bytes around the first difference ---'
$s = [Math]::Max(0, $first - 16)
$L += ('    ' + (($b[$s..($s+95)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))

$L | Set-Content $out -Encoding ASCII
Write-Output 'VERIFY DONE'
