# 2色マトリクスLED ダイナミック点灯制御 (MAX10 / Quartus Prime Lite)

8x8 二色 (緑/赤) ドット・マトリクスLED (秋月 LTP-12188M-08) を、3個の
TC74HC595AP シフトレジスタ (Row / Column-Green / Column-Red) 経由でダイナ
ミック点灯し、0〜9の数字を1秒ごとに切り替えて表示します。

## ファイル構成

```
matrix_led_quartus/
├── matrix_led.qpf          Quartus Prime プロジェクトファイル
├── matrix_led.qsf          デバイス設定・ピン割当・IO規格
├── matrix_led.sdc          TimeQuest 制約 (クロック定義)
├── rtl/
│   ├── top_matrix_led.sv   トップ・モジュール (走査シーケンサ本体)
│   └── font_rom.sv         0〜9 数字の 8x8 フォントROM (case文、initial不使用)
└── sim/
    └── tb_top_matrix_led.sv  簡易テストベンチ (タイミングを縮小してシミュレーション用)
```

## Quartus Prime Lite での開き方

1. Quartus Prime Lite を起動し、`File > Open Project` で `matrix_led.qpf` を開く。
2. `Assignments > Device` でお使いの MAX10 基板の正確な型番・パッケージを確認
   （`matrix_led.qsf` は `10M08SAE144C8G` (144-EQFP) を仮定しています）。
3. `Processing > Start Compilation` でコンパイル。
4. `Tools > Programmer` で生成された `.sof` を書き込み。

## 必ず確認していただきたい前提（ハードウェア依存の仮定）

`clk` (pin 88) の周波数は **50 MHz** と指定いただいたため、
`CLK_FREQ_HZ`（`top_matrix_led.sv`）および `create_clock -period 20.000`
（`matrix_led.sdc`）はこれに合わせて設定済みです。以下はそれ以外の
未確認事項（回路図での極性・配線を確認してください）です。

| 項目 | 仮定 | 該当パラメータ |
|---|---|---|
| ROW の極性 | active-High（1でその行のアノードON） | `ROW_ACTIVE_HIGH` |
| COL_GREEN / COL_RED の極性 | active-Low（0でそのカソードをシンクし点灯） | `COL_ACTIVE_LOW` |
| シフト順 | MSB first（bit7から送出） | `font_rom.sv` のビット定義 / シフト方向 |

これらが実際の駆動回路（トランジスタの向きやシフトレジスタの配線）と異なる
場合は、該当パラメータを反転するか、`font_rom.sv` のビット順を左右反転
してください。

## 動作概要

- `clk`/`rst_n` 以外はすべて 3.3-V LVCMOS、レジスタ出力（グリッチなし）。
- リセット直後に `CLR1`/`CLR2`/`CLR3` を約16クロック分 Low にして3つの
  595 をクリアし、その後 Highに戻して通常動作へ移行します。
- 1行分の走査サイクル: 行選択パターン・列(緑)パターン・列(赤)パターンの
  各8bitを、共有 `CLOCK` で8回シフト → `RCLOCK` を1パルスして3レジスタ
  同時ラッチ → その行を `ROW_HOLD_TICKS` (既定 約1kHz) だけ表示保持 →
  次の行へ。8行で1フレーム (既定 約125Hz、ちらつきなし)。
- 偶数の数字は緑、奇数の数字は赤で表示し、両方の色チャネル（および両方
  のクリア系統）を実際に使用する構成にしています。単色でよい場合は
  `top_matrix_led.sv` 内の `colg_raw`/`colr_raw` の代入部分を変更して
  ください。
- 数字は `DIGIT_HOLD_TICKS`（既定 = `CLK_FREQ_HZ`、すなわち1秒）ごとに
  0→1→…→9→0… と循環します。

## シミュレーション

`sim/tb_top_matrix_led.sv` はタイミング用パラメータを縮小してインスタン
ス化しており、ModelSim / Questa 等で数千ns程度のシミュレーションで複数
桁分の走査動作を確認できます（合成には使用しません）。
