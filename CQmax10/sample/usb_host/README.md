# CQ-MAX10-A USB Keyboard to JTAG UART

CQ-MAX10-A の 50 MHz クロックから PLL で 12 MHz を作り、PMOD-USBHOST に接続した low-speed USB HID キーボードの入力を ASCII に変換して Intel JTAG UART へ出力するサンプルです。

## 接続

デフォルトは USB channel 1 を使います。

| Signal | FPGA pin | PMOD-USBHOST |
| --- | --- | --- |
| `clk` | 88 | 50 MHz system clock |
| `rst_n` | 17 | active-low reset |
| `usb_u1_dp` | 44 | U1P |
| `usb_u1_dm` | 45 | U1N |
| `usb_u2_dp` | 46 | U2P |
| `usb_u2_dm` | 38 | U2N |

USB channel 2 を使う場合は `top` の `USB_CHANNEL` parameter を `2` に変えてください。

## ビルド

1. Quartus Prime Lite で `usb_host.qpf` を開きます。
2. `usb_host` revision をコンパイルします。
3. 書き込み後、JTAG UART Terminal または `nios2-terminal` を開きます。
4. USB キーボードで入力すると、押下された文字が JTAG UART に出力されます。

## 状態 LED

| LED | Meaning |
| --- | --- |
| `led` / `leds[7]` | 1 Hz heartbeat |
| `led0` | accepted character toggle |
| `leds[0]` | PLL locked |
| `leds[1]` | USB device detected |
| `leds[2]` | USB keyboard detected |
| `leds[3]` | USB connection/protocol error |
| `leds[4]` | USB-to-system CDC overflow |
| `leds[5]` | JTAG UART write FIFO full/stalled |
| `leds[6]` | pending character waiting for JTAG UART |

## Notes

- HID keycode to ASCII conversion is US keyboard layout oriented.
- Key repeat is suppressed by comparing the current boot keyboard report with the previous report; one new key press emits one character.
- Enter emits LF (`0x0a`), Backspace emits `0x08`, Tab emits `0x09`, Escape emits `0x1b`.
- The USB HID host core is from nand2mario's `usb_hid_host` project and expects a 12 MHz clock.

## Simulation

The included Questa smoke test verifies the HID keycode to ASCII mapper:

```tcl
cd sim
vsim -do run_questa.tcl
```
