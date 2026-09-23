# LCD "全画面オレンジ" 表示 (Step 1)

MAX 10 (10M08SCE144C8G, CQ-MAX10-A + Pmod ボード) と
PMOD-TFTLCD v1.1 (ILI9341, 320x240) を使って、**画面全体をオレンジ色で塗りつぶす**
FPGA デザインです。

このプロジェクトは最終目標である「LCD を使った 1 キーゲーム」の
**Step 1 (表示系の土台)** にあたります。仕様書
(`prompt.txt` の Architecture) にある「320x200 の 1bit フレームバッファ」も
すでに実装済みで、Step 2 のゲームロジックはこのフレームバッファに
1 を書き込むだけで済むようになっています。

**動作確認済み:** Questa によるシミュレーション (2 本, 計 230557 チェック) が
すべて PASS、Quartus のコンパイルも成功し、タイミング Slack +8.8 ns で
すべての制約を満たしています。

---

## 1. 構成

```
lcd_game.qpf / lcd_game.qsf        Quartus プロジェクト (top = lcd_test_top)
lcd_game.sdc                      タイミング制約 (50MHz, clk のみ)
rtl/
  lcd_test_top.sv                  トップレベル (ピン / 各ブロックの接続)
  lcd_ili9341_ctrl.sv              ILI9341 初期化 + 1 フレーム転送
  spi_byte_master.sv               4 線式 SPI バイト送信器 (Mode 0)
  framebuffer.v                    320x200x1bit フレームバッファ (2000 x 32bit)
  framebuffer_pixel_src.sv         フレームバッファ読み出し + RGB565 変換
  frame_seq.sv                     フレーム周期生成 (FRAME_PERIOD_MS ごと)
  reset_sync.sv                    リセット同期
  debounce.sv                      ボタン(sw1)チャタリング除去
simulation/questa/
  tb_framebuffer.sv                フレームバッファ / ピクセル変換の検証
  tb_orange.sv                     初期化シーケンスと全画面転送の検証
  run_sim.tcl                      Questa 実行スクリプト
```

## 2. データの流れ

```
clk(50MHz) ─► reset_sync ─► rst
                              │
     ┌────────────────────────┴─────────────────────────┐
     │                                                  │
     ▼                                                  ▼
 frame_seq            lcd_ili9341_ctrl            framebuffer (320x200x1)
  FRAME_PERIOD_MS 毎に  ─► CASET/PASET/RAMWR ─┐         ▲
  CMD_FRAME を発行      SPI でピクセル転送    │         │ rd_addr
                              │              │    framebuffer_pixel_src
                              │ pix_req      └──► (1bit → RGB565)
                              └────────────────────────┘
```

* `frame_seq` が「フレームを送れ」と要求 (`req_valid`) を出し、
  `lcd_ili9341_ctrl` が受け付けると 1 画面分を SPI で送り出します。
* ピクセルは `framebuffer_pixel_src` から 1 ピクセルずつ取得します
  (読み出しレイテンシ 2 クロック、`pix_valid` で完了通知)。
* オレンジ色になるのは、リセット直後にフレームバッファを 0 でクリアし、
  **bit=0 → オレンジ (0xFD20)** に対応させているためです。

## 3. フレームバッファ (Step 2 への布石)

| 項目 | 値 |
|---|---|
| サイズ | 320 x 200 = 64000 bit |
| 構成 | 2000 ワード x 32 bit (32 ピクセルを 1 ワードにパック) |
| 実装 | M9K 1 ブロック (`ramstyle = "M9K"`) |
| ワードアドレス | `y*10 + x/32` |
| ビット位置 | `x % 32` |

`framebuffer.v` は

* 読み出しポート (LCD がスキャンアウト用に使用)
* 書き込みポート (ゲームロジックが描画用に使用)
* 全クリア機能 (`clr_start` / `clr_busy`)

を持ちます。Step 1 では書き込みポートは未使用 (`fb_wr_en = 0`) で、
リセット後に一度だけ全クリアしています。
Step 2 では `lcd_test_top.sv` の

```verilog
assign fb_wr_en   = 1'b0;
assign fb_wr_addr = '0;
assign fb_wr_data = 32'h0000_0000;
```

をゲームロジックの出力に差し替え、`COLOR_BIT1` (現在は白) を線の色に
使えばそのままゲームが描けます。

書き込みは 32bit ワード単位なので、ゲームロジック側で
「1 ピクセルをセットする」には

1. 現在のワードを読み出す (`rd_addr`) — ただし読み出しは 1 クロック後
2. `wr_data = rd_data | (32'h1 << x[4:0])` を作る
3. `wr_addr = y*10 + x/32` に書き込む

の read-modify-write になります。ゲームは 1 ステップごとに 1 ドット
しか描かないので、この 3 サイクルは十分間に合います。
衝突判定用の履歴も同じフレームバッファから読めるので、
別途 64000bit のビットマップを持つ必要はありません。

## 4. 色

`lcd_test_top` のパラメータで変更できます。

| パラメータ | 既定値 | 意味 |
|---|---|---|
| `COLOR_BIT0` | `16'hFD20` | フレームバッファ bit=0 の色 (オレンジ) |
| `COLOR_BIT1` | `16'hFFFF` | フレームバッファ bit=1 の色 (白, Step 2 の線) |
| `COLOR_INFO` | `16'hFD20` | 320x40 情報表示領域の色 (オレンジ) |

RGB565 なので、赤=R[15:11], 緑=[10:5], 青=[4:0] です。
例えば 8bit の (R,G,B) から作るには
`{R[7:3], G[7:2], B[7:3]}` を使います。

## 5. タイミング

| 項目 | 値 | 備考 |
|---|---|---|
| システムクロック | 50 MHz | PIN_88 |
| SPI クロック | 12.5 MHz | `SCLK_HALF_CYCLES = 2` → clk/4 |
| 1 ピクセル | 16 bit = 64 clk + ハンドシェイク数 clk | |
| 1 フレーム (320x240) | 約 105 ms | 76800 ピクセル |
| フレーム周期 | `FRAME_PERIOD_MS` = 250 ms | |
| 初期化前待ち | `POWERON_WAIT_MS` = 150 ms | 電源投入後の安定待ち |

SPI は 12.5 MHz なので 1 フレーム約 105 ms かかります。
フレーム周期をこれより短くすると `req_ready` が下がったままに
なるだけなので、通常は 150 ms 以上を指定してください。

## 6. ピンアサイン

| FPGA pin | 信号 | 機能 |
|---|---|---|
| PIN_88 | `clk` | 50 MHz システムクロック |
| PIN_17 | `btn_rst` | リセット (アクティブ Low) |
| PIN_62 | `sw1` | ゲームボタン (Step 2 で使用) |
| PIN_48 | `sw2` | 未使用 (LED に反映) |
| PIN_81 | `lcd_cs` | LCD チップセレクト (アクティブ Low) |
| PIN_78 | `lcd_mosi` | SPI MOSI |
| PIN_75 | `lcd_sck` | SPI クロック |
| PIN_77 | `lcd_dc` | データ/コマンド |
| PIN_85 | `led` | 初期化完了で点灯 (アクティブ Low) |
| PIN_122 | `led0` | フレーム転送中に点灯 (アクティブ Low) |
| PIN_123 | `led1` | フレーム完了ごとにトグル (ハートビート) |
| PIN_120 | `led2` | `sw2` の状態 |
| PIN_121 | `led3` | ボタン押下で点灯 |

LED はすべてアクティブ Low です。

## 7. ビルド手順

1. Quartus Prime で `lcd_game.qpf` を開く (デバイスは
   `10M08SCE144C8G`、トップは `lcd_test_top`)。
2. Processing → Start Compilation。
3. Programmer で `output_files/lcd_test_top.sof` を書き込む。

コマンドラインの場合:

```
quartus_sh --flow compile lcd_game
```

### ビルド結果 (実測)

| 項目 | 値 |
|---|---|
| Fitter | Successful, 0 errors |
| 論理要素 | 465 / 8064 (6 %) |
| レジスタ | 196 |
| ピン | 13 / 101 |
| メモリビット | 0 (Step 1 では定数化, 下記参照) |
| セットアップ Slack | +9.186 ns (Slow 1200mV 85C) |
| ホールド Slack | +0.360 ns |

フレームバッファの M9K 推論自体は確認済みです。Step 1 のまま
(書き込みポートを `0` 固定) でコンパイルすると、Quartus が
「常に 0 しか書かれない RAM」を定数化して消すため、メモリビットが
0 と表示されます。一時的に書き込みポートを `sw2` に繋いで
コンパイルしたところ **64,000 memory bits (= 320 x 200 ちょうど)**、
論理要素 613、タイミング Slack +8.813 ns で正常に M9K 1 ブロックに
推論されることを確認しました。Step 2 でゲームロジックが書き込む
ようになれば常に推論されます。

## 8. シミュレーション (Questa)

```
cd simulation/questa
set SALT_LICENSE_SERVER=H:\altera_lite\25.1std\licenses\<your license>.dat
vlib work
vlog -sv ..\..\rtl\*.sv ..\..\rtl\*.v tb_framebuffer.sv tb_orange.sv
vsim -c -do "run -all; quit -f" tb_framebuffer
vsim -c -do "run -all; quit -f" tb_orange
```

### テスト内容

**`tb_framebuffer`** — 320x240 の全 76800 ピクセルについて

* フレームバッファのワードアドレスが `y*10 + x/32` になること
* 返ってくる色がソフトウェア参照モデルと一致すること
* 読み出しレイテンシがちょうど 2 クロックであること
* ゲームフィールド外 (y >= 200) では情報表示色になること

を検証します (230400 チェック)。

**`tb_orange`** — ボードに近い形での End-to-End 検証

* 初期化シーケンス 67 バイトが、正しい D/C レベルと正しい順序で
  SPI に出力されること (SWRESET → 10ms → SLPOUT → 120ms → ... → DISPON → 20ms)
* フレーム要求ごとに `2A 00 00 01 3F` `2B 00 00 00 EF` `2C` が送られること
* 続く 153600 バイト (76800 ピクセル x 2) がすべてオレンジであること
* CS がフレームごとにいったん High に戻ること (フレーム同士が分離されている)
* 2 フレーム目も同じ内容が繰り返されること

を検証します (157 チェック)。

## 9. 動作確認時の注意

* **画面が真っ暗 / 何も出ない** — LED で切り分けてください。
  `led` が点灯していれば初期化完了、`led0` が点灯していればフレーム転送中です。
  `led1` はフレームが完了するたびにトグルするので、これが止まっていれば
  SPI が進んでいません。
  `led` が点灯しない場合は SPI が止まっているので、`lcd_cs` / `lcd_sck` /
  `lcd_mosi` / `lcd_dc` の配線を確認してください。
* **RESX (LCD リセット)** — ピン表に RESX がないため、初期化は
  SWRESET コマンドのみで行っています。PMOD ボード側で RESX が
  プルアップされている前提です。もし別の GPIO に繋がっている場合は、
  そのピンを追加して数 ms High に保つ必要があります。
* **色が違う** — `COLOR_BIT0` を変更してください。RGB565 のビット順が
  逆 (BGR) に見える場合は `MADCTL_VALUE` の bit3 (BGR) を反転してください。
* **表示が回転 / 鏡像** — `MADCTL_VALUE` (既定 `8'h28`) を
  `8'h48` / `8'h88` / `8'hE8` などに変えて試してください。
* **ボタン / スイッチの極性** — `debounce.sv` / `reset_sync.sv` は
  外部プルアップ (アイドル時 High) を前提にしています。基板上に
  プルアップがない場合は `lcd_game.qsf` の
  `WEAK_PULL_UP_RESISTOR` の行をアンコメントしてください。

## 10. シミュレーションで見つけて直した不具合 (記録)

実装中に Questa で見つかったものを残しておきます。

1. **`pix_valid` がゲームフィールド外で出ていなかった**
   — y >= 200 の 40 行で `pix_valid` が出ず、LCD コントローラが
   フレーム途中で止まっていました (無限待ち)。フィールド外でも
   `pix_valid` を出し、色だけ情報表示色にするよう修正。
2. **初期化 ROM の delay エントリで `init_idx` が進んでいなかった**
   — SWRESET 後の delay で永久ループしていました。
3. **フレーム間に CS の High 区間がなかった**
   — `S_READY` で `lcd_cs <= 1'b1` の直後に `lcd_cs <= 1'b0` を
   書いていたため、非ブロッキング代入の後勝ちで CS が下がったままに
   なり、フレームが連続した 1 本のコマンド列として出力されていました。
   `S_FRAME_END` を追加して CS を 32 clk 以上 High に保つよう修正。
4. **フレームバッファのクリア完了前にフレームが始まる可能性**
   — `frame_seq` の `ready` に `!clr_busy` を追加。
