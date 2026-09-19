# microphone - 音声波形 + スペクトラム LCD 表示 (Quartus Prime / MAX 10)

PMOD-Microphone v1.0 で音声を取得し、その波形を PMOD-TFTLCD v1.1
(ILI9341, 320x240) に表示する FPGA デザインです。
さらに **128 点 FFT** で周波数ごとの値を求め、その棒グラフを
波形に重ねて表示します。

## 構成

```
microphone/
├── microphone.qpf          Quartus Prime プロジェクト
├── microphone.qsf          ピン配置・ファイル登録
├── microphone.sdc          タイミング制約
├── tools/
│   └── gen_tables.ps1      FFT 用 ROM テーブルの生成スクリプト
├── rtl/
│   ├── top.sv              トップモジュール
│   ├── i2s_rx.sv           I2S マイク受信 (FPGA がマスタ)
│   ├── moving_avg.sv       移動平均フィルタ (ノイズ低減)
│   ├── audio_buf.sv        波形表示用デュアルポート RAM
│   ├── fft128.sv           128 点 FFT + パワースペクトル
│   ├── fft_tables.svh      FFT 用 ROM テーブル (自動生成)
│   ├── spectrum.sv         スペクトル -> バーの高さ (log2 圧縮)
│   ├── sw_debounce.sv      タクトスイッチのチャタリング除去
│   └── lcd_wave.sv         ILI9341 SPI 制御 + 波形 / 棒グラフ描画
└── sim/
    ├── tb_i2s_rx.sv        I2S 受信のテストベンチ
    ├── tb_lcd_ctrl.sv      LCD 制御のテストベンチ
    ├── tb_moving_avg.sv    移動平均フィルタのテストベンチ
    ├── tb_fft128.sv        FFT のテストベンチ
    ├── tb_spectrum.sv      スペクトラム変換のテストベンチ
    ├── tb_sw_debounce.sv   スイッチ入力のテストベンチ
    ├── tb_top_sw.sv        top のスイッチ -> 時間軸パスのテストベンチ
    └── run_sim.bat         Questa 実行スクリプト
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
| 121 | `led2` | FFT フレーム完了ごとにトグル |
| 120 | `led3` | LCD 初期化完了で点灯 |

### タクトスイッチ

| FPGA | 信号 | 機能 |
|------|------|------|
| 62 | `sw_inc` | 波形の時間軸を 1 段上げる |
| 48 | `sw_dec` | 波形の時間軸を 1 段下げる |
| 17 | `btn_rst` | リセット (押下 = Low) |

> プルアップ前提・押下 = Low として扱っています。基板の配線が逆の場合は
> `top.sv` の `sw_debounce` の `ACTIVE_LOW` を `1'b0` にしてください。
> チャタリング除去と 2 段同期化は `sw_debounce.sv` が行います。
>
> **注意**: 元は `sw_dec` を PIN_54 に割り当てていましたが、この基板の
> PIN_54 のスイッチが動作しなかったため PIN_48 に変更しました。
> FPGA 側は正常であることを確認済みです
> (`PIN_54` -> `sw_dec` の割り当て、Bank 3 / 3.3-V LVCMOS、
> デュアルパーパスピンではない、`tb_top_sw` での動作検証 OK)。
> 基板のスイッチ / プルアップ抵抗の実装状態を確認してください。

## 動作

### I2S マイク受信 (`i2s_rx.sv`)

FPGA が I2S マスタとして動作します。

- ビットクロック `SCK` = 1.28 MHz (`CLK_HZ / SCK_HZ ≒ 39`)
- 1 フレーム = 64 SCK (32bit × 2ch) の Philips I2S フォーマット
- サンプリング周波数 `Fs` = 1.28 MHz / 64 = **20.031 kHz**
- WS 変化の 1 SCK 後に MSB が現れるため、`bit_pos = 1..24` の
  24bit を取り込み、上位 16bit (符号付き) を出力

> **注意**: 使用する Pmod マイクの型番によっては、I2S ではなく
> 左詰め (Left-Justified) 形式の場合があります。その場合は
> `i2s_rx.sv` の `in_data` の範囲を `bit_pos = 0..23` に変更して
> ください。

### 移動平均フィルタ (`moving_avg.sv`)

受信したサンプルに 8 サンプルの単純移動平均をかけてノイズを抑えます。

- ランニングサム方式のため**乗算器は不要** (加算 2 回のみ)
- `Fs = 20.03 kHz` / `N = 8` のとき、-3dB 遮断周波数は約 1.4 kHz
- ノイズエネルギーは理論上 **1/N = 1/8 (12.5%)** に低減
  （実測 13.7% で理論値とよく一致）

> 移動平均は**波形表示にのみ**使います。FFT には生サンプルを入力します
> (N = 8 では 8 kHz 以上の成分が落ちてしまうため)。

### 波形表示 (`audio_buf.sv` / `lcd_wave.sv`)

- 4096 サンプルのリングバッファにフィルタ後のデータを書き込む
- LCD フレーム開始時に書き込みポインタをラッチし、
  直近 320 サンプルを左から右へ 1 サンプル 1 列で描画
- 描画時間 約 98 ms + 待機 50 ms で 1 フレーム約 148 ms
- 波形は緑、中央線はグレー、32px ごとにグリッド線
- 振幅は `AMP_GAIN_SHIFT` で調整可能 (現在 = `-1`、**1/2**)

#### 振幅スケール `AMP_GAIN_SHIFT`

2 の冪で指定します (符号付き)。

| `AMP_GAIN_SHIFT` | 倍率 | 動作 |
|------------------|------|------|
| `+2` | ×4 | 左シフト |
| `+1` | ×2 | 左シフト |
| `0` | ×1 | 等倍 |
| **`-1`** | **×1/2** | **右シフト (現在)** |
| `-2` | ×1/4 | 右シフト |

```
samp_off = (rdata << AMP_LSH) >>> AMP_RSH
   AMP_LSH = (AMP_GAIN_SHIFT > 0) ?  AMP_GAIN_SHIFT : 0
   AMP_RSH = (AMP_GAIN_SHIFT < 0) ? -AMP_GAIN_SHIFT : 0
```

左シフト量と右シフト量を分けることで、負のシフト量という
未定義動作 (Verilog では禁止) を避けています。右シフトは算術
シフト (`>>>`) なので符号が保持されます。

> 振幅 1 ビット = 1 px なので、`-1` にすると同じ音でも
> 波形の振れ幅が画面半分になります。

描画中に書き込みポインタがラッチ位置を追い越しても、
深さ 4096 に対し描画期間中の書き込みは約 1720 サンプルなので
上書きは発生しません。

### スペクトラム表示 (`fft128.sv` / `spectrum.sv`)

周波数ごとの値を棒グラフで波形に重ねて表示します。

```
 moving_avg ──┬─► audio_buf ──► lcd_wave (波形)
              │
              └─► fft128 ──► spectrum ──► lcd_wave (棒グラフ)
```

#### `fft128.sv` : 128 点 FFT

- 基数 2 / DIT (Decimation-In-Time) の in-place バタフライを 7 段
- 入力は 16bit 符号付き (Q0)、Hann 窓 (Q15) を内部で適用
- 回転因子は Q14 の ROM テーブル (`fft_tables.svh`)
- 内部データは 24bit 符号付き (バタフライで 7bit 成長するため)
- 出力は `Re² + Im²` = 34bit のパワースペクトル
- 入力は ping-pong バッファに取り込むため、FFT 実行中も
  サンプルを取りこぼさない

周波数レンジ:

| 項目 | 値 |
|------|-----|
| サンプリング周波数 `Fs` | **20.03 kHz** (`SCK = 1.28 MHz / 64`) |
| ナイキスト周波数 | 10.016 kHz |
| FFT 入力の間引き `DEC_N` | 1 (間引きなし) |
| FFT 入力周波数 `Fse` | 20.03 kHz |
| ポイント数 `N` | 128 |
| 分解能 `df = Fse / N` | **156.5 Hz / bin** |
| **表示範囲** | **bin 0 ～ 63 = 0 ～ 10.0 kHz** |

`Fs` は I2S の `SCK` から `Fs = SCK / 64` で決まります。
0～10 kHz をカバーするため `top.sv` の `SCK_HZ` を 1 MHz → **1.28 MHz**
に上げています (`Fs = 20.031 kHz`、`df = 156.5 Hz`)。

> **注意**: I2S マスタの SCK が 1.28 MHz になるため、使用する Pmod マイクが
> このビットクロックに対応している必要があります (ICS-43432 系は 3.2 MHz 程度まで可)。
> 波形表示の時間軸も変わります (320 サンプル = 現在約 16 ms)。
>
> **FFT には移動平均を通さない生サンプルを入力** しています。
> `moving_avg` (N = 8) は `Fs/N` 付近から減衰し始めるため、
> `Fs = 20 kHz` では 8 kHz 以上の成分が落ちてしまうからです。
> 移動平均は波形表示にのみ使います。

#### `spectrum.sv` : 対数圧縮とバーの高さ

パワーは数十 dB のダイナミックレンジがあるため、
そのまま高さにすると弱い成分が潰れます。
最上位ビット位置と 7bit の仮数から `log2` を求め、
`LOG2_LUT` を使って対数圧縮します。

- `q4 = exp*16 + 16*log2(1 + mant/128)`  (log2 の 16 倍 = 0.376 dB/単位)
- しきい値 `LOG_MIN` (既定 = 128 → `mag2 = 256`) 以下はバー高さ 0
- ゲインは `LOG_MUL / 2^LOG_SH` [px / octave]
- **ピークホールド**: 前フレームより小さい値は `DECAY` px/フレーム
  ずつしか減らさない (`DECAY = 0` で最大値保持)

表示ゲインを **従来の 3 倍** にしています (`LOG_MUL` を 11 → 33)。

| 項目 | 従来 | 現在 |
|------|------|------|
| `LOG_MUL` | 11 | **33** |
| `LOG_SH` | 4 | 4 |
| ゲイン | 0.69 px / octave | **2.06 px / octave** |
| 1 octave (6.02 dB) あたり | 11 px | **33 px** |

> 1 octave = 2 倍 = 6.02 dB なので、2.06 px/octave は **約 0.34 px/dB** です。
> 画面は 240 px なので表示レンジは約 **70 dB** になります。
>
> `q4` は最大 544 程度、`LOG_MUL` は最大 255 なので、積は 18bit で受けています。

実測の圧縮特性 (1 octave ずつ、`LOG_MUL = 33`, `LOG_MIN = 128`):

| `mag2` | `q4` | バーの高さ |
|---------|------|------------|
| 512 | 144 | 0 px |
| 1,024 | 160 | 66 px |
| 2,048 | 176 | 99 px |
| 4,096 | 192 | 132 px |
| 8,192 | 208 | 165 px |
| 16,384 | 224 | 198 px |
| 32,768 | 240 | 231 px |

ちょうど 33 px ずつ伸びており、対数圧縮が正しく効いています。

#### 棒グラフのジオメトリ (`lcd_wave.sv`)

| 項目 | 既定値 | 説明 |
|------|--------|------|
| `BAR_EN` | 1 | 棒グラフを描く |
| `BAR_N` | 64 | 本数 (= FFT の全 bin) |
| `BAR_W` | 4 | 1 本の横幅 (px) |
| **`BAR_GAIN_SH`** | 1 | **表示高さの左シフト量 (1 で 2 倍、0 で等倍)** |
| `BAR_OVER_WAVE` | 1 | バーを波形より手前に描く |
| 色 | `COL_BAR` = `16'hFD20` | オレンジ |

ピッチ = `320 / 64 = 5 px`、横幅 4 px なので 1 px の隙間が空き、
64 本で **0 ～ 10 kHz** をカバーします。
画面下部 (下辺 = `LCD_H-1`) から表示高さ分上まで描画します。
bin 0 (DC) は Hann 窓の漏れで常に最大になるため `START_BIN = 1` で除外し、
左端の 1 本 (bin 0) だけ空きになります。

**表示高さの増幅:** `bar_data` (内部の高さ) を `BAR_GAIN_SH` ビット
左シフトして表示します。既定は `BAR_GAIN_SH = 1` なので**内部値の 2 倍の
高さ**で描画します。画面高を超えた分は下辺でクリップされ、その列は
下辺から上端まで塗り潰されます。
内部の高さは 9 bit (`logic [8:0] h`) で計算しているため、
`y + h >= BAR_BOT` の引き算がアンダーフローしません。

#### 描画の重ね順 (重要)

`BAR_OVER_WAVE = 1` (既定) のときの重ね順は:

```
バー > 波形 > 中央線 > グリッド > 背景
```

以前は `波形 > 中央線 > バー` だったため、**背の高いバーを 3 px 幅の
波形ラインと中央線が横切って「棒が途切れて」見えていました**
(高さを上げると必ず重なるため顕著になります)。
バーを最優先にすることで途切れがなくなります
(`tb_lcd_ctrl` の「バーの連続性チェック」で検証)。

#### バーの高さのスナップショット (重要)

`bar_ram` は `spectrum` 側が **FFT フレームごと (約 6.4 ms)** に
書き換えますが、LCD の 1 フレームは

```
描画 76800 px × 1.28 us ≒ 98 ms  +  FRAME_WAIT 50 ms  ≒  148 ms
```

かかります。したがって **1 フレームの間に `bar_ram` は約 23 回も
書き換わります**。

さらに LCD の走査は**行優先** (`pixel_index = row_cnt*320 + col_cnt`,
`col_cnt` が速い) なので、**1 本のバーのピクセルはフレーム全体に
散らばって描かれます**。列 `c` の row 0 はフレームの最初、row 239 は
フレームの最後に送られます。

そのため `bar_data` を描画中に生で読むと、**1 本のバーがフレームの
途中で何度も高さを変えてしまい、「途中で途切れた」ように見えます**
(特に無音時の一括消去や寿命切れで値が 0 に落ちたとき)。

対策として、`lcd_wave` は**フレーム開始時に全 bin の高さを
スナップショット**し (`bar_snap` 配列)、描画にはその値だけを使います。
これで 1 フレーム内では必ず 1 つの値だけが使われ、バーが途切れません。

```
S_FRAME_START -> S_BAR_LD (bin 0..63 を順に取り込み) -> S_PIX_CALC -> 描画
```

`bar_addr` → `bar_data` は 2 クロックのレジスタ遅延があるため、
1 bin あたり 3 サイクルかけます (64 bin でも 192 サイクル ≒ 3.8 us
なのでフレーム時間には影響しません)。

また `col_cnt / BAR_PITCH` の除算と 64 エントリのバー高さ選択は
遅延が大きいため、`S_PIX_CALC` で `bar_cur` にラッチしてから
`pixel_color` に渡します (経路を 2 サイクルに分割)。

`tb_lcd_ctrl` のフェーズ 5 がこの挙動を検証します
(フレーム途中で `bar_ram` を別の値に変えても、そのフレームのバーが
開始時の値で一貫していること)。

#### 棒グラフの表示時間と消去

**表示時間を変えたいときは `top.sv` の `BAR_LIFE` を変えます。**

##### 表示時間を決めるのは `BAR_LIFE` (`spectrum.sv`)

各 bin が「あと何フレーム表示するか」のカウンタ `bar_life` を持ちます。

- そのフレームにノイズフロア (`LOG_MIN`) を超える値があれば、
  寿命を `BAR_LIFE` に戻す
- 信号が消えたフレームから 1 つずつ減らし、0 になったらそのビンの
  バーを 0 にする
- **信号が消えてから `BAR_LIFE` フレームの間、そのビンはピーク値を
  保持して表示され続ける**

```
BAR_LIFE : ビンごとの保持時間。単位は FFT フレーム
           1 FFT フレーム = 128 / 20.03 kHz = 6.39 ms
           表示時間 [s] = BAR_LIFE * 6.39 ms

  例)  32 -> 0.20 s  /  156 -> 1.0 s  /  313 -> 2.0 s
```

寿命の判定は LCD ではなく `spectrum` 側で行います。以前は LCD 側の
フレームカウンタを使っていましたが、LCD のフレーム周期 (約 148 ms) と
FFT の更新周期 (約 6.4 ms) が大きく違うため**フレーム位相によっては
更新を取りこぼして即座に消えていました**。

> **`BAR_LIFE` の制約:** `BAR_LIFE` は FFT フレーム数
> (1 フレーム = 128 サンプル ≒ 6.4 ms) です。LCD は約 148 ms ごとに
> しか `bar_ram` を読まないため、`BAR_LIFE` が 1 LCD フレーム分
> (≒ 23 FFT フレーム) より小さいと、**LCD が読む前に寿命切れで 0 に
> なりバーが点滅・欠けします**。`BAR_LIFE` は 25 以上にしてください。

##### 無音時の一括消去は `SIL_FRAMES` — `BAR_LIFE` より大きくすること

フレーム全体が無音 (最大 `mag2` < `SIG_TH`) のまま `SIL_FRAMES`
フレーム続くと、全ビンを一度に 0 にします。

> **重要:** `SIL_FRAMES` が `BAR_LIFE` より小さいと、ビンごとの保持が
> 切れる前に**全部消してしまう**ため、`BAR_LIFE` をいくら上げても
> 表示が伸びません。以前は `SIL_FRAMES = 2` (固定, 約 13 ms) だった
> ため、`BAR_LIFE` を変えても体感の表示時間が変わらない状態でした。
> `top.sv` では `SP_SIL_FRAMES = BAR_LIFE + 8` としています。

##### `BAR_HOLD` (`lcd_wave.sv`) は表示時間に影響しない

`lcd_wave` 側にも `BAR_HOLD` がありますが、これは
**スペクトラム更新 (`bar_fresh`) が完全に止まったときの安全網**です。

実機では `bar_fresh` が約 6.4 ms ごとに来るので、LCD のフレーム開始
(約 148 ms ごと) では必ず `bar_seen = 1` となり `bar_hold` は
`BAR_HOLD` に戻り続けます。したがって**通常動作では `BAR_HOLD` を
変えても表示時間は変わりません**。表示時間は `BAR_LIFE` で変えます。

| パラメータ | ファイル | 単位 | 役割 |
|-----------|---------|------|------|
| `BAR_LIFE` | `top.sv` | FFT フレーム (6.4 ms) | **表示時間 (これで変える)** |
| `SP_SIL_FRAMES` | `top.sv` | FFT フレーム | 無音時の一括消去 (`BAR_LIFE` より大) |
| `BAR_HOLD` | `top.sv` | LCD フレーム (148 ms) | 更新停止時の安全網 (通常は無関係) |

> `bar_fresh` は `spectrum` が 1 クロック幅のパルスで出すため、
> フレーム開始でそのままサンプルすると取りこぼします。
> `lcd_wave` では `bar_seen` にラッチし、フレーム開始時に消費する
> 形にしています (`tb_lcd_ctrl` のフェーズ 4 で検証)。

#### 波形の時間軸 (`lcd_wave.sv`)

タクトスイッチで 1 列あたりのサンプル数 `spp` を切り替えます。

| 状態 | `spp` | 表示時間 (320 列) |
|------|-------|-------------------|
| `tb_sel = 0` | 1 | 約 16 ms |
| `tb_sel = 1` | 2 | 約 32 ms |
| `tb_sel = 2` | 4 | 約 64 ms |
| `tb_sel = 3` | 8 | 約 128 ms |

読み出しアドレスは次の式で求めます。

```
rd_idx = rd_base - 1 - (spp * LCD_W) + (col * spp)
```

`tb_sel` はフレーム開始時にラッチするため、切り替えは次フレームから
反映されます。切り替え時は古い絵が残るので、その 1 フレームは
画面全体を背景色でクリアします。

`spp` は RAM 深さから自動的にクランプされます
(`BUF_AW = 12`, `LCD_W = 320` なら最大 12)。

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
run_sim.bat fft      # fft128 のみ
run_sim.bat spec     # spectrum のみ
run_sim.bat swd      # スイッチのチャタリング除去のみ
run_sim.bat swtop    # top のスイッチ -> 時間軸パスのみ
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

> FFT 系は `fft_tables.svh` を include するため **`+incdir+../rtl` が必須**です。
>
> ```sh
> vlog -sv +incdir+../rtl ../rtl/fft128.sv  tb_fft128.sv
> vlog -sv +incdir+../rtl ../rtl/spectrum.sv tb_spectrum.sv
> ```

### FFT 用 ROM テーブルの再生成

`rtl/fft_tables.svh` は `tools/gen_tables.ps1` が生成します
(`TW_RE` / `TW_IM` 回転因子 Q14、`HANN` 窓 Q15、`LOG2_LUT`)。
手で編集せず、パラメータを変えたら再生成してください。

```sh
powershell -NoProfile -ExecutionPolicy Bypass -File tools/gen_tables.ps1
```

> このスクリプトは日本語コメントを含むため、**UTF-8 (BOM 付き)**で
> 保存する必要があります (PowerShell 5.1 は BOM が無いと ANSI として読みます)。
> また `R` は `Invoke-History` のエイリアス、`$n` は `$N` と
> 大文字小文字を区別しないため衝突する点に注意してください。

### 検証内容

| テストベンチ | 検証内容 |
|--------------|----------|
| `tb_i2s_rx` | I2S スレーブモデルが送出した 24bit データと、`i2s_rx` が取り込んだ上位 16bit が一致すること (400 サンプル) |
| `tb_lcd_ctrl` | 初期化コマンド列、SPI 転送されたピクセル色、波形・グリッド・中央線・**棒グラフ**の位置、**バーの連続性 (途切れないこと)**、**時間軸切り替え**、**棒グラフの消去**、**1 クロック幅の `bar_fresh`**、**走査中の `bar_ram` 変化に対する 1 フレームの一貫性** |
| `tb_moving_avg` | 参照モデルとの一致、直流収束、インパルス応答 (N サンプルで消える)、ノイズ減衰量 (1/N) |
| `tb_fft128` | DC 入力で `X[0]` が厳密に一致、インパルス応答が解析解と一致、余弦波 (bin 8) のピーク位置、浮動小数点 DFT との相対誤差、再現性 |
| `tb_spectrum` | 起動時のクリア、全 bin の変換、1 octave = 33 px の対角圧縮の線形性、**ビンごとの保持時間 (`BAR_LIFE` が表示時間を決めていること)**、`bar_fresh` パルス、読み出しポート |
| `tb_sw_debounce` | 押下検出、押しっぱなしで再トリガしないこと、離す、チャタリング除去、チャタリング後の押下 |
| `tb_top_sw` | `top` を丸ごと動かして、実際のスイッチ入力から `tb_sel` が変化すること (上下限クランプ、押しっぱなしを含む) |

実測結果 (Questa Altera Starter FPGA Edition 2025.2):

```
tb_i2s_rx    : checks = 400, errors = 0                                    TEST PASSED
tb_lcd_ctrl  : spi_bad = 0, bad_bar = 0, 時間軸切替/寿命消去 OK            TEST PASSED
tb_moving_avg: 参照一致, DC収束, インパルス, ノイズ 13.7% (理論値 12.5%)   TEST PASSED
tb_fft128    : DC X[0] 厳密一致, インパルス解析解一致, cos peak bin=8,
               浮動小数点 DFT との最大相対誤差 0.0033%                     TEST PASSED
tb_spectrum  : 全bin一致, 1octave=33px の線形性, ビン寿命消去 OK      TEST PASSED
tb_sw_debounce: 押下/離す/チャタリング除去/再トリガ無し OK                TEST PASSED
tb_top_sw    : スイッチ -> tb_sel の上下限クランプ/ホールド OK            TEST PASSED
```

> `tb_top_sw` は `top` を丸ごとインスタンス化して検証するため、`top` の
> `CLK_HZ` / `SW_WAIT_MS` パラメータを小さくして高速に回します
> (既定値は実機と同じなので合成結果は変わりません)。

> `tb_fft128` の参照は「DUT が取り込んだ入力バッファを読んで、それに対する
> 浮動小数点 DFT を計算する」方式です。このため窓掛けの丸め差と FFT コアの
> 誤差を分離して検証できます。
>
> なお Questa (Altera Starter FPGA Edition 2025.2) は `$abs` を実装して
> いません。`$abs` を使うと警告が出て 0 が返り、許容幅チェックが
> **無効化されてしまいます**。テストベンチでは自前の絶対値関数を使って
> います。

> `tb_lcd_ctrl` は波形の位置検証に DUT 内部信号 (`col_cnt` / `row_cnt` /
> `rd_base` / `cur_color`) を階層参照しているため、`lcd_wave` の
> 内部構造を変更した場合はテストベンチも合わせて更新してください。

## カスタマイズ

| 変化内容 | ファイル | パラメータ |
|----------|----------|------------|
| サンプリング周波数 | `top.sv` | `SCK_HZ` (→ `Fs = SCK_HZ/64`) |
| 移動平均のサンプル数 | `top.sv` | `AVG_N` |
| **スイッチのチャタリング除去時間** | `top.sv` | `SW_WAIT_MS` |
| 波形の振幅 | `top.sv` | `AMP_GAIN_SHIFT` (2 の冪。負で縮小) |
| 波形バッファ長 | `top.sv` | `BUF_AW` |
| フレーム更新間隔 | `top.sv` | `FRAME_WAIT` |
| FFT の間引き比 | `top.sv` | `FFT_DEC_N` |
| 表示する最初の bin | `top.sv` | `SP_START` |
| バーの最大高さ | `top.sv` | `SP_MAX` |
| **表示レンジ (本数)** | `top.sv` | `BAR_N` (= bin 数 → 帯域) |
| バーの幅 | `top.sv` | `BAR_W` |
| **バーの表示高さ (倍率)** | `top.sv` | **`BAR_GAIN_SH`** (左シフト量。1 で 2 倍) |
| バーの重ね順 | `lcd_wave.sv` | `BAR_OVER_WAVE` (1 で波形より手前) |
| **バーの表示時間** | `top.sv` | **`BAR_LIFE`** (FFT フレーム数。1.0 s なら 156) |
| 無音時の一括消去 | `top.sv` | `SP_SIL_FRAMES` (`BAR_LIFE` より大) |
| LCD 側の安全網 | `top.sv` | `BAR_HOLD` (LCD フレーム数、通常は無関係) |
| 無音とみなすレベル | `top.sv` | `SP_SIG_TH` |
| **時間軸の段数** | `top.sv` | `TB_N` (1,2,4,... サンプル/列) |
| **表示ゲイン** | `top.sv` | `SP_LOG_MUL` / `SP_LOG_SH` |
| バー 0 になるしきい値 | `top.sv` | `SP_LOG_MIN` |
| ピークホールド | `top.sv` → `spectrum` | `DECAY` (0 = 最大値保持) |
| 表示色 | `lcd_wave.sv` | `COL_WAVE` / `COL_BAR` など |
| 表示するサンプル数 | `lcd_wave.sv` | `LCD_W` |
| 波形の太さ | `lcd_wave.sv` | `WAVE_THICK` |

> `BUF_AW` を変更する場合は `audio_buf` の深さと
> `lcd_wave` の描画範囲に注意してください。
>
> 窓関数 / 回転因子を変える場合は `tools/gen_tables.ps1` を修正して
> `rtl/fft_tables.svh` を再生成してください。
>
> `SCK_HZ` を変えると `Fs = SCK_HZ / 64`、`df = Fs / FFT_DEC_N / FFT_N`、
> 表示帯域 `= df * BAR_N` がすべて変わります。
> 例) 表示を 0～20 kHz にしたい場合は `SCK_HZ = 2_560_000` (`Fs = 40 kHz`,
> `df = 312.5 Hz`) にするとちょうど `df * 64 = 20 kHz` になります
> (`SP_LOG_MUL` を 22 程度に下げると 240 px に収まります)。

## コンパイル結果

Quartus Prime 25.1std (Lite) / 10M08SCE144C8G

| 項目 | FFT 前 | FFT 後 |
|------|--------|--------|
| Flow Status | Successful (0 errors) | Successful (0 errors) |
| Total logic elements | 803 / 8,064 ( 10 % ) | 2,727 / 8,064 ( 34 % ) |
| Total registers | 439 | 1,354 / 8,542 ( 16 % ) |
| Total pins | 14 / 101 ( 14 % ) | 16 / 101 ( 16 % ) |
| Total memory bits | 65,536 / 387,072 ( 17 % ) | 76,352 / 387,072 ( 20 % ) |
| Worst-case setup slack (Slow 1200mV 85C) | +1.694 ns | **+1.207 ns** |
| Worst-case hold slack | — | +0.341 ns |

> `pixel_color` に 9 bit の加算器 (バーの高さ増幅とクリップ) が入り、
> さらにバーの高さスナップショット (64 エントリの選択) が加わりましたが、
> 選択結果を `bar_cur` にラッチして経路を 2 サイクルに分割しているため
> setup slack は **+1.207 ns** と十分な余裕があります (クロック周期 20 ns)。

> `spectrum.sv` の対数圧縮は組み合わせ遅延が大きいため、
> 「優先エンコーダ → 正規化 → log2 LUT → ゲイン + ピークホールド」の
> 4 段にパイプライン化しています。
> パイプライン化しない場合、`mag2` RAM から `bar_ram` へのパスが
> 25.5 ns となり setup slack が **-5.679 ns** でタイミング違反になります。
