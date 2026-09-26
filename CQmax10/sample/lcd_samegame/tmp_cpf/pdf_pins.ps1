$ErrorActionPreference = 'Continue'
$pdf = 'h:\git\PCB_CQmax10\_ref\pmod-tftlcd-v1.1.pdf'
$out = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame\tmp_cpf\pdf_pins.txt'
$L = @()

$bytes = [IO.File]::ReadAllBytes($pdf)
$L += "pdf size = $($bytes.Length)"

$latin = [Text.Encoding]::GetEncoding(28591)
$s = $latin.GetString($bytes)

$streams = [regex]::Matches($s, '(?s)stream\r?\n(.*?)\r?\nendstream')
$L += "streams = $($streams.Count)"

function Inflate([byte[]]$data) {
    try {
        $ms = New-Object IO.MemoryStream(,$data)
        $ms.Position = 2
        $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
        $os = New-Object IO.MemoryStream
        $ds.CopyTo($os)
        $os.ToArray()
    } catch { $null }
}

$sb = New-Object System.Text.StringBuilder
$n = 0
foreach ($m in $streams) {
    $raw = $latin.GetBytes($m.Groups[1].Value)
    $inf = Inflate $raw
    if ($null -eq $inf) { continue }
    $n++
    $txt = $latin.GetString($inf)
    foreach ($t in [regex]::Matches($txt, '[\x20-\x7E]{2,}')) { [void]$sb.AppendLine($t.Value) }
}
$L += "inflated = $n"

# text-showing operators
$toks = @()
foreach ($m in [regex]::Matches($sb.ToString(), '\((?:\\.|[^()\\])*\)')) {
    $v = $m.Value.Substring(1, $m.Value.Length - 2)
    $v = $v -replace '\\\(', '(' -replace '\\\)', ')' -replace '\\\\', '\'
    if ($v.Trim().Length -gt 0) { $toks += $v.Trim() }
}
$L += "tokens = $($toks.Count)"
$L += ''
$L += '=== TOKENS ==='
$L += ($toks -join ' | ')

$L | Set-Content $out -Encoding ASCII
Write-Output "PDF PARSE DONE  ($($toks.Count) tokens)"
