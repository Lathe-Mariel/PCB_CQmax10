$ErrorActionPreference = 'Continue'
$Q    = 'H:\altera_lite\25.1std\quartus\bin64'
$root = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame'
$tmp  = Join-Path $root 'tmp_cpf'
$out  = Join-Path $tmp 'probe_result.txt'
$lines = @()
$lines += '=== UFM signature probe ==='

$w = @(Get-Content (Join-Path $root 'logo_rom.mem')) | Where-Object { $_ -match '\S' }
$lines += "mem words = $($w.Count)"

# signature A = mem[0..11], signature B = mem[1000..1007], both as
# little-endian 32-bit UFM words (pixel in bits [15:0], upper 16 bits zero)
$sigA = New-Object System.Collections.Generic.List[byte]
for ($i = 0; $i -lt 12; $i++) {
    $v = [Convert]::ToUInt16($w[$i].Trim(), 16)
    $sigA.Add([byte]($v -band 0xFF)); $sigA.Add([byte](($v -shr 8) -band 0xFF))
    $sigA.Add(0); $sigA.Add(0)
}
$sigB = New-Object System.Collections.Generic.List[byte]
for ($i = 1000; $i -lt 1008; $i++) {
    $v = [Convert]::ToUInt16($w[$i].Trim(), 16)
    $sigB.Add([byte]($v -band 0xFF)); $sigB.Add([byte](($v -shr 8) -band 0xFF))
    $sigB.Add(0); $sigB.Add(0)
}

function FindPat($b, $pat) {
    for ($i = 0; $i -le $b.Length - $pat.Count; $i++) {
        if ($b[$i] -eq $pat[0]) {
            $ok = $true
            for ($j = 1; $j -lt $pat.Count; $j++) {
                if ($b[$i + $j] -ne $pat[$j]) { $ok = $false; break }
            }
            if ($ok) { return $i }
        }
    }
    return -1
}

function Report($path, $label) {
    $script:lines += "--- $label ---"
    if (-not (Test-Path $path)) { $script:lines += '    MISSING'; return }
    $b = [IO.File]::ReadAllBytes($path)
    $a = FindPat $b $sigA
    $c = FindPat $b $sigB
    $script:lines += "    size=$($b.Length)  sigA@=$a  sigB@=$c"
}

Report (Join-Path $root 'output_files\lcd_game.sof') 'built .sof'
Report (Join-Path $root 'output_files\lcd_game.pof') 'built .pof'

# --- try converting the .sof into a .pof with quartus_cpf ----------------
$r1 = & "$Q\quartus_cpf.exe" -c (Join-Path $root 'output_files\lcd_game.sof') (Join-Path $tmp 'from_sof.pof') 2>&1
$lines += '=== cpf -c lcd_game.sof from_sof.pof ==='
$lines += ($r1 | Out-String)
Report (Join-Path $tmp 'from_sof.pof') 'from_sof.pof'

# --- what does cpf know about pof / isc (in-system configuration)? -------
$lines += '=== cpf --help=pof ==='
$lines += ((& "$Q\quartus_cpf.exe" --help=pof 2>&1) | Out-String)
$lines += '=== cpf --help=isc ==='
$lines += ((& "$Q\quartus_cpf.exe" --help=isc 2>&1) | Out-String)

$lines | Set-Content $out -Encoding ASCII
Write-Output 'PROBE DONE'
