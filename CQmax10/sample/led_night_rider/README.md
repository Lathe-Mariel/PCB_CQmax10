# Night Rider LED — CQmax10 FPGA Project

8 LED ナイトライダー（KITT スキャナー）パターンを PWM 明るさ制御付きで駆動する SystemVerilog プロジェクトです。

## ターゲット

| 項目 | 値 |
|---|---|
| FPGA | Intel MAX 10 `10M08SCE144C8G` |
| ボード | [CQmax10](https://github.com/Lathe-Mariel/PCB_CQmax10) |
| ツール | Quartus Prime Lite |
| システムクロック | 50 MHz |

## 構成

```
night_rider_fpga/
├── night_rider.qpf          # Quartus プロジェクト
├── night_rider.qsf          # デバイス設定・ピン配置
├── rtl/
│   ├── night_rider_top.sv   # トップレベル
│   ├── night_rider.sv       # スキャナー位置・明るさ生成
│   └── pwm_controller.sv    # 8 bit PWM 出力
└── output_files/            # 合成・配置配線結果（生成物）
```

## 動作

- スキャナーヘッドが LED0 → LED7 → LED0 … と往復移動（10 ステップ/秒）
- ヘッド LED が最も明るく、離れるほど暗くなる尾光（4 段階の輝度）
- PWM 周波数: 50 MHz / 256 ≈ 195 kHz（ちらつきなし）

## ピン配置

| 信号 | FPGA ピン | I/O 標準 |
|---|---|---|
| clk | 88 | 3.3-V LVCMOS |
| rst_n | 17 | 3.3-V LVCMOS |
| led[0] | 98 | 3.3-V LVCMOS |
| led[1] | 101 | 3.3-V LVCMOS |
| led[2] | 99 | 3.3-V LVCMOS |
| led[3] | 100 | 3.3-V LVCMOS |
| led[4] | 96 | 3.3-V LVCMOS |
| led[5] | 105 | 3.3-V LVCMOS |
| led[6] | 97 | 3.3-V LVCMOS |
| led[7] | 106 | 3.3-V LVCMOS |

## ビルド手順

1. Quartus Prime Lite を起動
2. **File → Open Project** で `night_rider.qpf` を開く
3. **Processing → Start Compilation**（または Ctrl+L）
4. 完了後、`output_files/night_rider_top.sof` を Program Device で書き込み

### コマンドライン（任意）

Quartus が PATH にある場合:

```powershell
cd C:\Users\nagai\night_rider_fpga
quartus_sh --flow compile night_rider
quartus_pgm -c USB-Blaster -m jtag -o "p;output_files/night_rider_top.sof"
```

## パラメータ調整

`rtl/night_rider.sv` の `STEP_HZ`（デフォルト 10）でスキャン速度を変更できます。
`dist_brightness()` 内の値で尾光の長さ・明るさを調整できます。
