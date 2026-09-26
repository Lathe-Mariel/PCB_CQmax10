$ErrorActionPreference = 'Continue'
$pdf = 'h:\git\PCB_CQmax10\_ref\pmod-tftlcd-v1.1.pdf'
$out = 'h:\git\PCB_CQmax10\sample\lcd_samegame\tmp_cpf\pdf_pins.txt'
$L = @()

$bytes = [IO.File]::ReadAllBytes($pdf)
$L += "pdf size = $($bytes.Length)"

# Pull every FlateDecode stream and inflate it, then keep printable text.
$latin = [Text.Encoding]::GetEncoding(28591)
$s = $latin.GetString($bytes)

$streams = [regex]::Matches($s, '(?s)stream\r?\n(.*?)\r?\nendstream')
$L += "streams found = $($streams.Count)"

function Inflate([byte[]]$data) {
    try {
        $ms = New-Object IO.MemoryStream(,$data)
        $ms.Position = 2                     # skip the 2-byte zlib header
        $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
        $os = New-Object IO.MemoryStream
        $ds.CopyTo($os)
        return $os.ToArray()
    } catch { return $null }
}

$allText = New-Object System.Text.StringBuilder
$n = 0
foreach ($m in $streams) {
    $raw = $latin.GetBytes($m.Groups[1].Value)
    $inf = Inflate $raw
    if ($inf -eq $null) { continue }
    $n++
    $txt = $latin.GetString($inf)
    # keep runs of printable characters
    foreach ($t in [regex]::Matches($txt, '[\x20-\x7E]{3,}')) {
        [void]$allText.AppendLine($t.Value)
    }
}
$L += "inflated streams = $n"
$L += ''
$L += '=== printable strings ==='

# collect all text operators:  (....) Tj   and  [ ... ] TJ
$text = $allText.ToString()
$toks = @()
foreach ($m in [regex]::Matches($text, '\((?:\\.|[^()\\])*\)')) {
    $v = $m.Value.Substring(1, $m.Value.Length - 2)
    $v = $v -replace '\\\(', '(' -replace '\\\)', ')' -replace '\\\\', '\'
    if ($v.Trim().Length -gt 0) { $toks += $v }
}
$L += "text tokens = $($toks.Count)"
$L += ($toks -join ' | ')

$L | Set-Content $out -Encoding ASCII
Write-Output 'PDF PARSE DONE'
