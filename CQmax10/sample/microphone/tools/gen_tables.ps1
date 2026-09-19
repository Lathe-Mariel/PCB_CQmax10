# ============================================================
# gen_tables.ps1
#   FFT 用 ROM テーブル (rtl/fft_tables.svh) を生成する
#
#   使い方:
#     powershell -NoProfile -ExecutionPolicy Bypass -File <このファイル>
#
#   生成するテーブル
#     TW_RE / TW_IM : 回転因子 exp(-j*2*pi*k/128)     (Q14, k = 0..63)
#     HANN          : Hann 窓 0.5-0.5*cos(2*pi*n/128) (Q15, n = 0..127)
#     LOG2_LUT      : 16*log2(1 + m/128)              (m = 0..127, 0..16)
#
#   ※ パック配列 + 連結で出力する (古いシミュレータでも読める形式)。
#      連結は「左端が最大インデックス」なので、配列は降順に出力する。
#
#   ※ このファイルは日本語コメントを含むため UTF-8 (BOM 付き) で保存する
#      こと。PowerShell 5.1 は BOM が無いと ANSI として読んでしまう。
# ============================================================
$ErrorActionPreference = 'Stop'

# 大文字小文字を区別しない言語なので、$N と $n のような
# 紛らわしい変数名は使わないこと。
$FFT_N   = 128
$FFT_HF  = $FFT_N / 2

# 最近傍丸め ('R' は Invoke-History のエイリアスなので避ける)
function RN([double]$x) {
    return [int][Math]::Round($x, 0, [MidpointRounding]::AwayFromZero)
}

# ------------------------------------------------------------
# 値の計算
# ------------------------------------------------------------
$twRe = New-Object int[] $FFT_HF
$twIm = New-Object int[] $FFT_HF
for ($k = 0; $k -lt $FFT_HF; $k++) {
    $ang = 2.0 * [Math]::PI * $k / $FFT_N
    $twRe[$k] = RN(16384.0 * [Math]::Cos($ang))
    $twIm[$k] = RN(-16384.0 * [Math]::Sin($ang))
}

$hann = New-Object int[] $FFT_N
for ($i = 0; $i -lt $FFT_N; $i++) {
    $ang = 2.0 * [Math]::PI * $i / $FFT_N
    $hann[$i] = RN(32767.0 * (0.5 - 0.5 * [Math]::Cos($ang)))
}

$lut = New-Object int[] 128
for ($m = 0; $m -lt 128; $m++) {
    $lut[$m] = RN(16.0 * [Math]::Log(1.0 + $m / 128.0, 2))
}

# ------------------------------------------------------------
# 出力
# ------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder

function Out-Line([string]$s) { [void]$sb.AppendLine($s) }

# パック配列を出力する (values は添字 0..len-1、連結は降順に並べる)
# signed は "logic signed" として宣言する。signed にしないと
# 符号付きデータとの乗算が符号なしになり、負のサンプルで結果が壊れる。
function Emit-Array([string]$name, [int]$width, [bool]$signed, [int[]]$values, [int]$perLine) {
    $len  = $values.Length
    $kind = if ($signed) { "logic signed" } else { "logic" }
    $decl = "localparam $kind [" + ($len - 1) + ":0][" + ($width - 1) + ":0] $name = {"
    Out-Line $decl
    $line  = "    "
    $count = 0
    for ($i = $len - 1; $i -ge 0; $i--) {
        $val = $values[$i]
        # Verilog では "16'sd-123" は不正。負数は "-16'sd123" の形にする。
        if ($val -lt 0) {
            $tok = "-${width}'sd" + (-$val)
        } elseif ($signed) {
            $tok = "${width}'sd$val"
        } else {
            $tok = "${width}'d$val"
        }
        if ($i -eq 0) { $tok = $tok + " };" } else { $tok = $tok + ", " }

        if (($line.Length + $tok.Length) -gt 100) {
            Out-Line $line
            $line  = "    "
            $count = 0
        }
        $line = $line + $tok
        $count = $count + 1
        if ($count -ge $perLine) {
            Out-Line $line
            $line  = "    "
            $count = 0
        }
    }
    if ($line.Trim().Length -gt 0) { Out-Line $line }
}

Out-Line "// ============================================================"
Out-Line "// fft_tables.svh"
Out-Line "//   FFT 用 ROM テーブル"
Out-Line "//"
Out-Line "//   このファイルは tools/gen_tables.ps1 が自動生成する。"
Out-Line "//   手で編集しないこと (再生成で上書きされる)。"
Out-Line "//"
Out-Line "//   TW_RE / TW_IM : 回転因子 exp(-j*2*pi*k/128)     (Q14, k = 0..63)"
Out-Line "//   HANN          : Hann 窓 0.5-0.5*cos(2*pi*n/128) (Q15, n = 0..127)"
Out-Line "//   LOG2_LUT      : 16*log2(1 + m/128)              (m = 0..127)"
Out-Line "//"
Out-Line "//   パック配列 + 連結で書いているので古いツールでも読める。"
Out-Line "//   連結は左端が最大インデックスになる点に注意。"
Out-Line "//"
Out-Line "//   複数のファイルから include されるためガードを入れてある。"
Out-Line "// ============================================================"
Out-Line ''
Out-Line '`ifndef FFT_TABLES_SVH'
Out-Line '`define FFT_TABLES_SVH'
Out-Line ''
Out-Line "// exp(-j*2*pi*k/128) の実部 (Q14)"
Emit-Array "TW_RE" 16 $true $twRe 8
Out-Line ""
Out-Line "// exp(-j*2*pi*k/128) の虚部 (Q14, -sin)"
Emit-Array "TW_IM" 16 $true $twIm 8
Out-Line ""
Out-Line "// Hann 窓 (Q15, 符号付き: 音声サンプルとの乗算を符号付きにするため)"
Emit-Array "HANN" 16 $true $hann 12
Out-Line ""
Out-Line "// 16*log2(1 + m/128) : 仮数部 7bit から log2 の小数部 (Q4) を得る"
Emit-Array "LOG2_LUT" 5 $false $lut 16
Out-Line ''
Out-Line '`endif // FFT_TABLES_SVH'
Out-Line ''

$dst = Join-Path (Split-Path $PSScriptRoot -Parent) 'rtl\fft_tables.svh'
[System.IO.File]::WriteAllText($dst, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "generated: $dst"
Write-Host ("  TW  : {0} entries" -f $FFT_HF)
Write-Host ("  HANN: {0} entries (min={1}, max={2})" -f $FFT_N, ($hann | Measure-Object -Minimum).Minimum, ($hann | Measure-Object -Maximum).Maximum)
Write-Host ("  LUT : {0} entries (min={1}, max={2})" -f 128, ($lut | Measure-Object -Minimum).Minimum, ($lut | Measure-Object -Maximum).Maximum)
