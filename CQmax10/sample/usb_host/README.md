# CQ-MAX10-A USB Keyboard to JTAG UART

CQ-MAX10-A の 50 MHz クロックから PLL で 12 MHz を作り、PMOD-USBHOST に接続した low-speed USB HID キーボードの入力を ASCII に変換して Intel JTAG UART へ出力するサンプルです。

## 接続

デフォルトは USB channel 1 を使います。

PMOD-USBHOST v1.0 は Pmod port 6 に接続します。

| Signal | FPGA pin | Pmod pin | PMOD-USBHOST |
| --- | --- | --- | --- |
| `clk` | 88 | - | 50 MHz system clock |
| `rst_n` | 17 | - | active-low reset |
| `usb_u1_dp` | 98 | 2 | U1P |
| `usb_u1_dm` | 101 | 6 | U1N |
| `usb_u2_dp` | 99 | 1 | U2P |
| `usb_u2_dm` | 100 | 5 | U2N |

USB channel 2 を使う場合は `top` の `USB_CHANNEL` parameter を `2` に変えてください。

## ビルド

1. Quartus Prime Lite で `usb_host.qpf` を開きます。
2. `usb_host` revision をコンパイルします。
3. 書き込み後、JTAG UART Terminal または `nios2-terminal` を開きます。
4. USB キーボードで入力すると、押下された文字が JTAG UART に出力されます。

## 状態 LED

基板の LED D1-D4 は `+3V3 -> 抵抗 -> アノード -> カソード -> FPGA ピン` で接続されているため、
FPGA ピンは **LOW で点灯 (シンク)**、HIGH で消灯します (`top.sv` 側で反転済み)。

| LED | Pin | Meaning |
| --- | --- | --- |
| `led0` | 123 | **1 Hz ハートビート (FPGA が動作中)** |
| `led1` | 122 | **キーボードのキーを押している間ずっと点灯** |
| `led2` | 121 | **キーコードを受信するたびに 120 ms 点灯** |
| `led3` | 120 | USB キーボードを認識したら点灯 |

`led0` は FPGA 自体が生きていることを示す最も基本的な指標です。ここが点滅していなければ
電源 (ブラウンアウト) を疑ってください (この設計には CPU も自己リセット機構も無いため、
論理回路の不具合で FPGA が停止することはありません)。

`led1` と `led2` はキーボード入力の確認用です。`led2` はキーを押して離すのが速くても
目視できるよう、キーコード受信ごとに 120 ms 点灯します (`top.sv` の `HOLD_MS`) 。

ブリンクしない場合の切り分け: `led3` が点灯すれば FPGA はキーボードを認識しています。
`led3` が点灯しない場合は USB の接続 (Pmod port 6、5V 電源、プルアップ抵抗) を確認してください。

### その他のステータス出力

`led` (PIN_85) と `leds[7:0]` (PIN_52/57/55/59/50/56/58/60) は CQ-MAX10-A の
Pmod ボード上では LED に接続されていません (`leds[]` は Pmod port 2/4 のソケットに出ています)。

## トラブルシューティング: USB ケーブルを挿すと FPGA が止まる

PMOD-USBHOST v1.0 の回路図から確認した事実:

- 搭載部品は **C1/C2/C9/C10 (コンデンサ), L1 (22 µH), U1 (ME2188A50XG 昇圧コンバータ),
  J1/J2 (12ピン)** のみ。**抵抗は 1 本も実装されていません。**
- U1 は昇圧コンバータで、`LX` (J2 pin 6) と `OUT` (J2 pin 1) を持ち、出力は **5V**。
- J1/J2 のピン 2/3/4/5/7/8/9/10/11/12 の大半は **GND**、電源ピンは **3V3** と **5V** です。

### 重要: FPGA が止まるのは電源が原因の可能性が高い

`top.sv` には FPGA 自身をリセットする回路はありません。CPU もソフトウェアも無いため、
**RTL 側の不具合で FPGA が動作停止することは原理的にありません**。FPGA が止まる場合は
電源系 (3.3V レールの電圧降下 / ブラウンアウト) を疑ってください。

PMOD-USBHOST は Pmod から供給される **3.3V から昇圧して 5V を作り**、それを USB の VBUS に
与えます。USB 機器 (キーボード) は最大 100 mA 程度を 5V 側で消費しうるため、
3.3V 側では昇圧の損失を含めて **0.5 W 前後の追加負荷**になります。
CQ-MAX10-A の 3.3V レギュレータ (IC1 = NJM2845DL1-33) の供給能力を超えると
レール電圧が落ち、FPGA がリセット/停止します。

### 確認手順

1. **Pmod の 3V3 ピンをテスタで測る。** USB ケーブルを挿した瞬間に電圧が
   3.3V から下がる (例: 3.0V 以下) なら、電源容量不足です。
2. **FPGA のハートビート LED (`leds[7]` / PIN_52) を見る。**
   ケーブルを挿す前は点滅し、挿すと止まるなら電源が落ちています。
3. **FPGA ボードの別電源を試す。** セルフパワーの USB ハブや、電流容量に余裕のある
   5V 電源を使ってください (PC の USB ポート直結は容量が足りないことがあります)。
4. **USB のプル抵抗を追加する。** low-speed USB ホストは D+ に 15 kΩ (プルダウン)、
   D- に 1.5 kΩ (プルアップ) が必要です。PMOD-USBHOST には抵抗が実装されていないため、
   これらは外付けが必要です。無いと機器が認識されません。

> 注: 上記の電流値はデータシートが取得できなかったため概算です。
> 実際の値はテスタで測定してください。

## Notes

- HID keycode to ASCII conversion is US keyboard layout oriented.
- Key repeat is suppressed by comparing the current boot keyboard report with the previous report; one new key press emits one character.
- Enter emits LF (`0x0a`), Backspace emits `0x08`, Tab emits `0x09`, Escape emits `0x1b`.
- The USB HID host core is from nand2mario's `usb_hid_host` project and expects a 12 MHz clock.
- The four board LEDs are **active low** (the FPGA pin sinks the LED current). `top.sv` keeps the
  internal signals active-high and inverts them once at the output pins.
- `key_led_stretch` converts the asynchronous (12 MHz domain) key state into LED indications in the 50 MHz domain. Adjust `HOLD_MS` to change how long `led2` stays lit per key code.

## Simulation

The included Questa smoke tests verify the HID keycode to ASCII mapper, the
key activity LED stretcher and the board LED polarity:

```tcl
cd sim
vsim -do run_questa.tcl
vsim -do run_questa_key_led.tcl
```
