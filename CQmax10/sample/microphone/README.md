# microphone - 音声波形 LCD 表示 (Quartus Prime / MAX 10)

PMOD-Microphone v1.0 で音声を取得し、その波形を PMOD-TFTLCD v1.1
(ILI9341, 320x240) に表示する FPGA デザインです。

## 構成

```
microphone/
├── microphone.qpf          Quartus Prime プロジェクト
├── microphone.qsf          ピン配置・ファイル登録
├── microphone.sdc          タイミング制約
├── rtl/
│   ├── top.sv              トップモジュール
│   ├── i2s_rx.sv           I2S マイク受信 (FPGA がマスタ)
│   ├── moving_avg.sv       移動平均フィルタ (ノイズ低減)
│   ├── audio_buf.sv        波形表示用デュアルポート RAM
│   └── lcd_wave.sv         ILI9341 SPI 制御 + 波形描画
└── sim/
    ├── tb_i2s_rx.sv        I2S 受信のテストベンチ
    ├── tb_lcd_ctrl.sv      LCD 制御のテストベンチ
    ├── tb_moving_avg.sv    移動平均フィルタのテストベンチ
    └── run_sim.bat         ModelSim 実行スクリプト
```

## ハードウェア

| 項目 | 内容 |
|------|------|
| FPGA | 10M08SCE144C8G (MAX 10) |
| マイク | PMOD-Microphone v1.0 (I2S MEMS マイク) |
| LCD | PMOD-TFTLCD v1.1 (ILI9341, 320x240, 4-wire SPI) |
| クロック | 50 MHz (PIN_88) |
| リセット | ボタン PIN_17 (押下 = Low) |

## ピン配置

### PMOD 1 : Microphone

| FPGA | 信号 | 説明 |
|------|------|------|
| 47 | `mic_sck` | ビットクロック (FPGA → MIC) |
| 45 | `mic_ws` | ワードセレクト / LRCLK (FPGA → MIC) |
| 39 | `mic_sd` | シリアルデータ (MIC → FPGA) |

### PMOD 2 : LCD

| FPGA | 信号 | 説明 |
|------|------|------|
| 81 | `lcd_cs` | チップセレクト (Low 有効) |
| 77 | `lcd_dc` | Data/Command (RS) |
| 78 | `lcd_mosi` | SPI MOSI |
| 75 | `lcd_sck` | SPI クロック |

### LED

| FPGA | 信号 | 表示内容 |
|------|------|----------|
| 85 | `led` | フレーム描画ごとにトグル |
| 123 | `led0` | マイク入力検出中に点灯 |
| 122 | `led1` | サンプル受信ごとにトグル |
| 121 | `led2` | 未使用 (Low 固定) |
| 120 | `led3` | LCD 初期化完了で点灯 |

## 動作

### I2S マイク受信 (`i2s_rx.sv`)

FPGA が I2S マスタとして動作します。

- ビットクロック `SCK` = 1 MHz (`CLK_HZ / SCK_HZ = 50`)
- 1 フレーム = 64 SCK (32bit × 2ch) の Philips I2S フォーマット
- サンプリング周波数 `Fs` = 1 MHz / 64 = **15.625 kHz**
- WS 変化の 1 SCK 後に MSB が現れるため、`bit_pos = 1..24` の
  24bit を取り込み、上位 16bit (符号付き) を出力

> **注意**: 使用する Pmod マイクの型番によっては、I2S ではなく
> 左詰め (Left-Justified) 形式の場合があります。その場合は
> `i2s_rx.sv` の `in_data` の範囲を `bit_pos = 0..23` に変更して
> ください。

### 移動平均フィルタ (`moving_avg.sv`)

受信したサンプルに 8 サンプルの単純移動平均をかけてノイズを抑えます。

- ランニングサム方式のため**乗算器は不要** (加算 2 回のみ)
- N = 8 のとき、-3dB 遮断周波数は約 1.1 kHz
- ノイズエネルギーは理論上 **1/N = 1/8 (12.5%)** に低減
  （実測 13.7% で理論値とよく一致）

### 波形表示 (`audio_buf.sv` / `lcd_wave.sv`)

- 4096 サンプルのリングバッファにフィルタ後のデータを書き込む
- LCD フレーム開始時に書き込みポインタをラッチし、
  直近 320 サンプルを左から右へ 1 サンプル 1 列で描画
- 描画時間 約 110 ms + 待機 50 ms で 1 フレーム約 160 ms
- 波形は緑、中央線はグレー、32px ごとにグリッド線
- 振幅は `AMP_GAIN_SHIFT` (既定 = 1、**2 倍**) で調整可能

描画中に書き込みポインタがラッチ位置を追い越しても、
深さ 4096 に対し描画期間中の書き込みは約 1720 サンプルなので
上書きは発生しません。

## ビルド手順

1. Quartus Prime (Standard Edition) で `microphone.qpf` を開く
2. **Processing → Start Compilation** を実行
3. **Tools → Programmer** で `output_files/microphone.sof` を書き込む

## シミュレーション

シミュレータは **Questa (Altera Starter FPGA Edition)** を使用します。
インストール先: `H:\altera_lite\25.1std\questa_fse`

```sh
cd sim
run_sim.bat          # すべてのテストベンチを実行
run_sim.bat i2s      # i2s_rx のみ
run_sim.bat lcd      # lcd_wave のみ
run_sim.bat avg      # moving_avg のみ
```

### ライセンスの設定 (重要)

Questa はライセンスのチェックアウトに **`SALT_LICENSE_SERVER`** を使います。
`LM_LICENSE_FILE` では `vlog` は通りますが **`vsim` が起動しません**。

```bat
set QUESTA_ROOT=H:\altera_lite\25.1std
set PATH=%QUESTA_ROOT%\questa_fse\win64;%PATH%
set SALT_LICENSE_SERVER=%QUESTA_ROOT%\licenses\LR-189312_License.dat
```

`run_sim.bat` は上記を自動で設定します。手動で実行する場合:

```sh
vlib work
vlog -sv ../rtl/i2s_rx.sv     tb_i2s_rx.sv
vsim -c -do "run -all; quit -f" tb_i2s_rx
```

### 検証内容

| テストベンチ | 検証内容 |
|--------------|----------|
| `tb_i2s_rx` | I2S スレーブモデルが送出した 24bit データと、`i2s_rx` が取り込んだ上位 16bit が一致すること (400 サンプル) |
| `tb_lcd_ctrl` | 初期化コマンド列、SPI 転送されたピクセル色、波形 Y 座標・グリッド・中央線の位置が正しいこと |
| `tb_moving_avg` | 参照モデルとの一致、直流収束、インパルス応答 (N サンプルで消える)、ノイズ減衰量 (1/N) |

実測結果 (Questa Altera Starter FPGA Edition 2025.2):

```
tb_i2s_rx   : checks = 400, errors = 0                            TEST PASSED
tb_lcd_ctrl : spi_bad = 0, bad_color = 0, bad_wave = 0            TEST PASSED
tb_moving_avg: 参照一致, DC収束, インパルス, ノイズ 13.7% (理論値 12.5%)  TEST PASSED
```

> `tb_lcd_ctrl` は波形の位置検証に DUT 内部信号 (`col_cnt` / `row_cnt` /
> `rd_base` / `cur_color`) を階層参照しているため、`lcd_wave` の
> 内部構造を変更した場合はテストベンチも合わせて更新してください。

## カスタマイズ

| 変更内容 | ファイル | パラメータ |
|----------|----------|------------|
| サンプリング周波数 | `top.sv` | `SCK_HZ` |
| 移動平均のサンプル数 | `top.sv` | `AVG_N` |
| 波形の振幅 | `top.sv` | `AMP_GAIN_SHIFT` |
| 波形バッファ長 | `top.sv` | `BUF_AW` |
| フレーム更新間隔 | `top.sv` | `FRAME_WAIT` |
| 表示色 | `lcd_wave.sv` | `COL_WAVE` など |
| 表示するサンプル数 | `lcd_wave.sv` | `LCD_W` |
| 波形の太さ | `lcd_wave.sv` | `WAVE_THICK` |

> `BUF_AW` を変更する場合は `audio_buf` の深さと
> `lcd_wave` の描画範囲に注意してください。

## コンパイル結果

Quartus Prime 25.1std (Lite) / 10M08SCE144C8G

| 項目 | 結果 |
|------|------|
| Flow Status | Successful (0 errors) |
| Total logic elements | 803 / 8,064 ( 10 % ) |
| Dedicated logic registers | 439 / 8,064 ( 5 % ) |
| Total pins | 14 / 101 ( 14 % ) |
| Total memory bits | 65,536 / 387,072 ( 17 % ) |
| Fmax (Slow 1200mV 85C) | 56.15 MHz (要件 50 MHz) |
