# check_pof_ufm2.ps1 - robust search for the logo image inside the programming
# files, trying the plausible packings.
#
# logo0's first words in logo_rom.mem are
#     00EA 00EA 00EA 0088 090A 63B2 BE19 EF7E FFDF E75D 3A6F 0068 ...
# make_ufm_hex.ps1 writes each pixel as a little-endian 32-bit UFM word
#     EA 00 00 00  |  EA 00 00 00  |  EA 00 00 00  |  88 00 00 00  | ...
# so the canonical signature is the first 12 words (48 bytes) below.
#
# The same image is ALSO searched as
#   * 16-bit little-endian words  (if the flash stored pixels, not words)
#   * 16-bit big-endian words
# so a "not found" cannot simply be a packing mismatch.

$root = 'h:\git\PCB_CQmax10\CQmax10\sample\lcd_samegame'
$out  = "$root\pof_check2.txt"

# 12 consecutive pixels from the start of logo0
$pix = @(0x00EA,0x00EA,0x00EA,0x0088,0x090A,0x63B2,0xBE19,0xEF7E,0xFFDF,0xE75D,0x3A6F,0x0068)

function New-Pat32([int[]]$p) {
    $l = New-Object System.Collections.Generic.List[byte]
    foreach ($v in $p) { $l.AddRange([byte[]]@(($v -band 0xFF), (($v -shr 8) -band 0xFF), 0, 0)) }
    return $l.ToArray()
}
function New-Pat16LE([int[]]$p) {
    $l = New-Object System.Collections.Generic.List[byte]
    foreach ($v in $p) { $l.AddRange([byte[]]@(($v -band 0xFF), (($v -shr 8) -band 0xFF))) }
    return $l.ToArray()
}
function New-Pat16BE([int[]]$p) {
    $l = New-Object System.Collections.Generic.List[byte]
    foreach ($v in $p) { $l.AddRange([byte[]]@((($v -shr 8) -band 0xFF), ($v -band 0xFF))) }
    return $l.ToArray()
}

function Count-Pattern([string] $file, [byte[]] $needle) {
    if (-not (Test-Path $file)) { return "missing" }
    $b = [System.IO.File]::ReadAllBytes($file)
    $n = $needle.Length
    $hits = 0
    $first = -1
    for ($i = 0; $i -le $b.Length - $n; $i++) {
        $hit = $true
        for ($j = 0; $j -lt $n; $j++) { if ($b[$i + $j] -ne $needle[$j]) { $hit = $false; break } }
        if ($hit) { $hits++; if ($first -lt 0) { $first = $i } }
    }
    if ($hits -eq 0) { return "NOT FOUND (searched $($b.Length) bytes)" }
    return "$hits hit(s), first at offset $first (file $($b.Length) bytes)"
}

$files = @("$root\output_files\lcd_game.pof", "$root\output_files\lcd_game.sof")

"=== logo0 signature inside the programming files ===" | Out-File $out -Encoding ascii
foreach ($f in $files) {
    "" | Out-File $out -Append -Encoding ascii
    "--- $(Split-Path $f -Leaf) ---" | Out-File $out -Append -Encoding ascii
    "  32-bit LE UFM words : " + (Count-Pattern $f (New-Pat32 $pix)) | Out-File $out -Append -Encoding ascii
    "  16-bit LE pixels    : " + (Count-Pattern $f (New-Pat16LE $pix)) | Out-File $out -Append -Encoding ascii
    "  16-bit BE pixels    : " + (Count-Pattern $f (New-Pat16BE $pix)) | Out-File $out -Append -Encoding ascii
}

# how many 0x00EA 16-bit LE words exist at all?  logo0 alone has thousands.
"" | Out-File $out -Append -Encoding ascii
"=== occurrences of the 16-bit value 0x00EA (little-endian EA 00) ===" | Out-File $out -Append -Encoding ascii
foreach ($f in $files) {
    $b = [System.IO.File]::ReadAllBytes($f)
    $c = 0
    for ($i = 0; $i -lt $b.Length - 1; $i += 2) { if ($b[$i] -eq 0xEA -and $b[$i+1] -eq 0x00) { $c++ } }
    "$(Split-Path $f -Leaf) : $c aligned 16-bit words equal 0x00EA" | Out-File $out -Append -Encoding ascii
}
"DONE" | Out-File $out -Append -Encoding ascii
