FPGAデザインを作る

# Application
マイクを使って音声情報を取得し，その音声波形をLCDに表示する
Quartus Primerのプロジェクトとして実装する

# Hardware
## FPGA
10M08SCE144C8G

## LCD
PMOD-TFTLCD v1.1(muse lab)
Resolusion:320x240
https://github.com/wuxx/icesugar/blob/master/schematic/pmod-tftlcd-v1.1.pdf

## Microphone
PMOD-Microphone v1.0(muse lab)
https://github.com/wuxx/icesugar/blob/master/schematic/pmod-microphone-v1.0.pdf

# Software
## Development Evironment
Quartus Prime
## HDL
SystemVerilog

# Physical constraint
Pmod 1 | Microphone
46 | NC
44 | NC
41 | NC
38 | NC
45 | WS
43 | NC
39 | SD
47 | SCK


Pmod 2 |  LCD
80 | NC
79 | NC
77 | RS
76 | NC
81 | CS
78 | MOSI
74 | NC
75 | CLK