// ============================================================
// lcd_ctrl.v - ILI9341 SPI LCD Controller
// Tang Primer 25K + PMOD-TFTLCD v1.1
//
// Display : 320 x 240, RGB565 (16-bit color)
// Interface: 4-wire SPI (CS, DC, MOSI, SCK)
// SPI clock: 50MHz / 4 = 12.5MHz
//
// 表示内容:
//   背景: 8色縦縞テストパターン (各40px × 8 = 320px)
//   アニメーション: ウサギ画像 (40x40px) が斜め移動・壁で跳ね返る
//                   0.1秒ごとに1px移動 (X+Y同時)
//
// リセット: ユーザボタン H11 (押下=Low) で非同期リセット
// ============================================================

module lcd_ctrl (
    input  wire clk,       // 50 MHz
    input  wire btn_rst,   // ユーザボタン H11 (押下=Low)
    output reg  lcd_cs,    // G5  Chip Select (Low有効)
    output reg  lcd_dc,    // K11 Data/Command (RS)
    output reg  lcd_mosi,  // G8  SPI MOSI
    output reg  lcd_sck    // J5  SPI Clock
);

// ============================================================
// ユーザボタン 2段同期化 + 非同期リセット生成
// ============================================================
reg btn_r1, btn_r2;
always @(posedge clk) begin
    btn_r1 <= btn_rst;
    btn_r2 <= btn_r1;
end
wire rst_n = btn_r2;

// ============================================================
// 画像パラメータ
//   LCD  : 320(col) x 240(row)
//   画像 : 40x40px
//   移動範囲: X=0..(320-40-1)=279, Y=0..(240-40-1)=199
// ============================================================
localparam [8:0] IMG_W    = 9'd40;
localparam [7:0] IMG_H    = 8'd40;
localparam [8:0] LCD_COLS = 9'd320;
localparam [7:0] LCD_ROWS = 8'd240;
localparam [8:0] X_MAX    = 9'd279;  // 320-40-1
localparam [7:0] Y_MAX    = 8'd199;  // 240-40-1

// ============================================================
// 画像ROM インスタンス
// ============================================================
reg  [10:0] img_addr;
wire [15:0] img_data;

img_rom u_img_rom (
    .addr (img_addr),
    .data (img_data)
);

// ============================================================
// 初期化シーケンス ROM
// bit[8]=0 → CMD (DC=Low), bit[8]=1 → DAT (DC=High)
// ============================================================
localparam [6:0] ROM_DEPTH = 7'd68;

localparam [8:0]
    ROM_00 = 9'h001,  ROM_01 = 9'h011,
    ROM_02 = 9'h0C0,  ROM_03 = 9'h123,
    ROM_04 = 9'h0C1,  ROM_05 = 9'h110,
    ROM_06 = 9'h0C5,  ROM_07 = 9'h13E,  ROM_08 = 9'h128,
    ROM_09 = 9'h0C7,  ROM_10 = 9'h186,
    ROM_11 = 9'h036,  ROM_12 = 9'h128,
    ROM_13 = 9'h03A,  ROM_14 = 9'h155,
    ROM_15 = 9'h0B1,  ROM_16 = 9'h100,  ROM_17 = 9'h11B,
    ROM_18 = 9'h0B6,  ROM_19 = 9'h108,  ROM_20 = 9'h182,  ROM_21 = 9'h127,
    ROM_22 = 9'h026,  ROM_23 = 9'h101,
    ROM_24 = 9'h0E0,
    ROM_25 = 9'h10F,  ROM_26 = 9'h131,  ROM_27 = 9'h12B,
    ROM_28 = 9'h10C,  ROM_29 = 9'h10E,  ROM_30 = 9'h108,
    ROM_31 = 9'h14E,  ROM_32 = 9'h1F1,  ROM_33 = 9'h137,
    ROM_34 = 9'h107,  ROM_35 = 9'h110,  ROM_36 = 9'h103,
    ROM_37 = 9'h10E,  ROM_38 = 9'h109,  ROM_39 = 9'h100,
    ROM_40 = 9'h0E1,
    ROM_41 = 9'h100,  ROM_42 = 9'h10E,  ROM_43 = 9'h114,
    ROM_44 = 9'h103,  ROM_45 = 9'h111,  ROM_46 = 9'h107,
    ROM_47 = 9'h131,  ROM_48 = 9'h1C1,  ROM_49 = 9'h148,
    ROM_50 = 9'h108,  ROM_51 = 9'h10F,  ROM_52 = 9'h10C,
    ROM_53 = 9'h131,  ROM_54 = 9'h136,  ROM_55 = 9'h10F,
    ROM_56 = 9'h02A,                              // Column Addr Set (0~239)
    ROM_57 = 9'h100,  ROM_58 = 9'h100,
    ROM_59 = 9'h101,  ROM_60 = 9'h13F,
    ROM_61 = 9'h02B,                              // Row Addr Set (0~319)
    ROM_62 = 9'h100,  ROM_63 = 9'h100,
    ROM_64 = 9'h100,  ROM_65 = 9'h1EF,
    ROM_66 = 9'h029,  ROM_67 = 9'h02C;

function [8:0] rom_read;
    input [6:0] addr;
    case (addr)
        7'd0 : rom_read=ROM_00; 7'd1 : rom_read=ROM_01;
        7'd2 : rom_read=ROM_02; 7'd3 : rom_read=ROM_03;
        7'd4 : rom_read=ROM_04; 7'd5 : rom_read=ROM_05;
        7'd6 : rom_read=ROM_06; 7'd7 : rom_read=ROM_07;
        7'd8 : rom_read=ROM_08; 7'd9 : rom_read=ROM_09;
        7'd10: rom_read=ROM_10; 7'd11: rom_read=ROM_11;
        7'd12: rom_read=ROM_12; 7'd13: rom_read=ROM_13;
        7'd14: rom_read=ROM_14; 7'd15: rom_read=ROM_15;
        7'd16: rom_read=ROM_16; 7'd17: rom_read=ROM_17;
        7'd18: rom_read=ROM_18; 7'd19: rom_read=ROM_19;
        7'd20: rom_read=ROM_20; 7'd21: rom_read=ROM_21;
        7'd22: rom_read=ROM_22; 7'd23: rom_read=ROM_23;
        7'd24: rom_read=ROM_24; 7'd25: rom_read=ROM_25;
        7'd26: rom_read=ROM_26; 7'd27: rom_read=ROM_27;
        7'd28: rom_read=ROM_28; 7'd29: rom_read=ROM_29;
        7'd30: rom_read=ROM_30; 7'd31: rom_read=ROM_31;
        7'd32: rom_read=ROM_32; 7'd33: rom_read=ROM_33;
        7'd34: rom_read=ROM_34; 7'd35: rom_read=ROM_35;
        7'd36: rom_read=ROM_36; 7'd37: rom_read=ROM_37;
        7'd38: rom_read=ROM_38; 7'd39: rom_read=ROM_39;
        7'd40: rom_read=ROM_40; 7'd41: rom_read=ROM_41;
        7'd42: rom_read=ROM_42; 7'd43: rom_read=ROM_43;
        7'd44: rom_read=ROM_44; 7'd45: rom_read=ROM_45;
        7'd46: rom_read=ROM_46; 7'd47: rom_read=ROM_47;
        7'd48: rom_read=ROM_48; 7'd49: rom_read=ROM_49;
        7'd50: rom_read=ROM_50; 7'd51: rom_read=ROM_51;
        7'd52: rom_read=ROM_52; 7'd53: rom_read=ROM_53;
        7'd54: rom_read=ROM_54; 7'd55: rom_read=ROM_55;
        7'd56: rom_read=ROM_56; 7'd57: rom_read=ROM_57;
        7'd58: rom_read=ROM_58; 7'd59: rom_read=ROM_59;
        7'd60: rom_read=ROM_60; 7'd61: rom_read=ROM_61;
        7'd62: rom_read=ROM_62; 7'd63: rom_read=ROM_63;
        7'd64: rom_read=ROM_64; 7'd65: rom_read=ROM_65;
        7'd66: rom_read=ROM_66; 7'd67: rom_read=ROM_67;
        default: rom_read = 9'h000;
    endcase
endfunction

// ============================================================
// カラーパレット (RGB565) - 8色縦縞背景
// ============================================================
function [15:0] get_color;
    input [8:0] col;
    begin
        if      (col < 9'd40)  get_color = 16'hFFFF; // 白
        else if (col < 9'd80)  get_color = 16'hFFE0; // 黄
        else if (col < 9'd120) get_color = 16'h07FF; // シアン
        else if (col < 9'd160) get_color = 16'h07E0; // 緑
        else if (col < 9'd200) get_color = 16'hF81F; // マゼンタ
        else if (col < 9'd240) get_color = 16'hF800; // 赤
        else if (col < 9'd280) get_color = 16'h001F; // 青
        else                   get_color = 16'h0000; // 黒
    end
endfunction

// ============================================================
// 電源ON後 150ms 待機
// ============================================================
localparam [23:0] POWERON_WAIT = 24'd7_500_000;
reg [23:0] poweron_cnt;
reg        init_start;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        poweron_cnt <= 24'd0;
        init_start  <= 1'b0;
    end else begin
        if (poweron_cnt == POWERON_WAIT)
            init_start <= 1'b1;
        else begin
            init_start  <= 1'b0;
            poweron_cnt <= poweron_cnt + 1'b1;
        end
    end
end

// ============================================================
// SPI バイト送信器
// Mode 0: tx_cnt[5:2]=ビット番号, tx_cnt[1:0]=フェーズ
// ============================================================
reg [7:0] tx_byte;
reg       tx_dc_reg;
reg       tx_start;
reg       tx_busy;
reg [5:0] tx_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lcd_cs   <= 1'b1;
        lcd_sck  <= 1'b0;
        lcd_mosi <= 1'b0;
        lcd_dc   <= 1'b0;
        tx_busy  <= 1'b0;
        tx_cnt   <= 6'd0;
    end else if (tx_start && !tx_busy) begin
        tx_busy  <= 1'b1;
        tx_cnt   <= 6'd0;
        lcd_cs   <= 1'b0;
        lcd_dc   <= tx_dc_reg;
        lcd_sck  <= 1'b0;
        lcd_mosi <= tx_byte[7];
    end else if (tx_busy) begin
        tx_cnt <= tx_cnt + 1'b1;
        case (tx_cnt[1:0])
            2'b00: lcd_mosi <= tx_byte[7 - tx_cnt[5:2]];
            2'b01: lcd_sck  <= 1'b1;
            2'b10: ;
            2'b11: begin
                lcd_sck <= 1'b0;
                if (tx_cnt[5:2] == 4'd7) begin
                    tx_busy <= 1'b0;
                    lcd_cs  <= 1'b1;
                end
            end
        endcase
    end
end

// ============================================================
// アニメーション: 画像位置管理
//
//   img_x : 画像左端のLCD列位置 (0 .. X_MAX=279)
//   img_y : 画像上端のLCD行位置 (0 .. Y_MAX=199)
//   dir_x : X方向 (1'b0=+1, 1'b1=-1)
//   dir_y : Y方向 (1'b0=+1, 1'b1=-1)
//
//   move_pulse: 0.1秒ごとの1クロックパルス
//               50MHz × 0.1s = 5,000,000サイクル
//
//   描画開始時 (S_FRAME_START) に位置を確定し、
//   描画中は位置を変えない (テアリング防止)
// ============================================================
localparam [22:0] MOVE_PERIOD = 23'd2_000_000;

reg [22:0] move_cnt;
reg        move_pulse;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        move_cnt   <= 23'd0;
        move_pulse <= 1'b0;
    end else begin
        if (move_cnt == MOVE_PERIOD - 1'b1) begin
            move_cnt   <= 23'd0;
            move_pulse <= 1'b1;
        end else begin
            move_cnt   <= move_cnt + 1'b1;
            move_pulse <= 1'b0;
        end
    end
end

// 画像位置レジスタ (描画開始時にスナップショット)
reg [8:0] img_x;      // 現在のX位置 (描画用、動かない)
reg [7:0] img_y;      // 現在のY位置 (描画用、動かない)
reg [8:0] next_x;     // 次フレームのX位置
reg [7:0] next_y;     // 次フレームのY位置
reg       dir_x;      // 0=右方向, 1=左方向
reg       dir_y;      // 0=下方向, 1=上方向

// 位置更新ロジック (move_pulse ごとに next_x/next_y を更新)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        next_x <= 9'd140;   // 初期位置: 中央付近
        next_y <= 8'd100;
        dir_x  <= 1'b0;    // 初期方向: 右下
        dir_y  <= 1'b0;
    end else if (move_pulse) begin
        // X方向移動 & 跳ね返り
        if (!dir_x) begin
            if (next_x >= X_MAX) begin
                next_x <= next_x - 9'd1;
                dir_x  <= 1'b1;
            end else
                next_x <= next_x + 9'd1;
        end else begin
            if (next_x == 9'd0) begin
                next_x <= next_x + 9'd1;
                dir_x  <= 1'b0;
            end else
                next_x <= next_x - 9'd1;
        end

        // Y方向移動 & 跳ね返り
        if (!dir_y) begin
            if (next_y >= Y_MAX) begin
                next_y <= next_y - 8'd1;
                dir_y  <= 1'b1;
            end else
                next_y <= next_y + 8'd1;
        end else begin
            if (next_y == 8'd0) begin
                next_y <= next_y + 8'd1;
                dir_y  <= 1'b0;
            end else
                next_y <= next_y - 8'd1;
        end
    end
end

// ============================================================
// メインステートマシン
// ============================================================
localparam [3:0]
    S_WAIT       = 4'd0,
    S_INIT_TX    = 4'd1,
    S_INIT_WAIT  = 4'd2,
    S_SWRST_DLY  = 4'd3,
    S_SLPOUT_DLY = 4'd4,
    S_FRAME_START= 4'd5,   // フレーム開始: 位置スナップショット
    S_PIX_CALC   = 4'd6,   // ピクセル色決定
    S_PIX_ADDR_W = 4'd7,   // img_rom 読み出し待ち (1サイクル)
    S_PIX_HI_TX  = 4'd8,
    S_PIX_HI_W   = 4'd9,
    S_PIX_LO_TX  = 4'd10,
    S_PIX_LO_W   = 4'd11,
    S_FRAME_END  = 4'd12,  // フレーム完了: 次フレーム待機
    S_NEXT_FRAME = 4'd13;  // Memory Write 再発行

reg [3:0]  state;
reg [6:0]  init_idx;
reg [23:0] dly_cnt;
reg [16:0] pix_cnt;   // 0..76799
reg [8:0]  col_cnt;   // 0..319
reg [7:0]  row_cnt;   // 0..239
reg [15:0] cur_color;

// 画像領域判定 (描画中は img_x/img_y を使用)
wire in_img_col = (col_cnt >= img_x) && (col_cnt < (img_x + {1'b0, IMG_W[7:0]}));
wire in_img_row = (row_cnt >= img_y) && (row_cnt < (img_y + IMG_H));
wire in_image   = in_img_col && in_img_row;

// 画像ROM アドレス (img_x/img_y 基準の相対座標)
wire [7:0] img_rel_col = col_cnt[7:0] - img_x[7:0];
wire [7:0] img_rel_row = row_cnt      - img_y;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_WAIT;
        init_idx  <= 7'd0;
        dly_cnt   <= 24'd0;
        pix_cnt   <= 17'd0;
        col_cnt   <= 9'd0;
        row_cnt   <= 8'd0;
        cur_color <= 16'd0;
        tx_start  <= 1'b0;
        tx_byte   <= 8'd0;
        tx_dc_reg <= 1'b0;
        img_addr  <= 11'd0;
        img_x     <= 9'd140;
        img_y     <= 8'd100;
    end else begin
        tx_start <= 1'b0;

        case (state)

            // ---- 電源ON 150ms 待機 ----
            S_WAIT: begin
                if (init_start) begin
                    init_idx <= 7'd0;
                    state    <= S_INIT_TX;
                end
            end

            // ---- 初期化シーケンス送信 ----
            S_INIT_TX: begin
                if (init_idx < ROM_DEPTH) begin
                    if (!tx_busy && !tx_start) begin
                        {tx_dc_reg, tx_byte} <= rom_read(init_idx);
                        tx_start <= 1'b1;
                        state    <= S_INIT_WAIT;
                    end
                end else begin
                    state <= S_FRAME_START;
                end
            end

            S_INIT_WAIT: begin
                if (!tx_busy && !tx_start) begin
                    case (tx_byte)
                        8'h01: begin dly_cnt <= 24'd0; state <= S_SWRST_DLY;  end
                        8'h11: begin dly_cnt <= 24'd0; state <= S_SLPOUT_DLY; end
                        default: begin
                            init_idx <= init_idx + 1'b1;
                            state    <= S_INIT_TX;
                        end
                    endcase
                end
            end

            S_SWRST_DLY: begin
                if (dly_cnt == 24'd250_000)
                    begin init_idx <= init_idx + 1'b1; state <= S_INIT_TX; end
                else dly_cnt <= dly_cnt + 1'b1;
            end

            S_SLPOUT_DLY: begin
                if (dly_cnt == 24'd6_000_000)
                    begin init_idx <= init_idx + 1'b1; state <= S_INIT_TX; end
                else dly_cnt <= dly_cnt + 1'b1;
            end

            // ---- フレーム開始: 位置スナップショット ----
            // next_x/next_y を img_x/img_y に取り込んで描画開始
            S_FRAME_START: begin
                img_x   <= next_x;
                img_y   <= next_y;
                pix_cnt <= 17'd0;
                col_cnt <= 9'd0;
                row_cnt <= 8'd0;
                state   <= S_PIX_CALC;
            end

            // ---- ピクセル色決定 ----
            S_PIX_CALC: begin
                if (in_image) begin
                    // row*40 + col  (40=32+8 → シフト加算)
                    img_addr <= (({3'b000, img_rel_row} << 5)
                              +  ({3'b000, img_rel_row} << 3))
                              +  {3'b000, img_rel_col[7:0]};
                    state    <= S_PIX_ADDR_W;  // 1サイクル待機
                end else begin
                    cur_color <= get_color(col_cnt);
                    state     <= S_PIX_HI_TX;
                end
            end

            // ---- img_rom 読み出し待ち ----
            S_PIX_ADDR_W: begin
                cur_color <= img_data;
                state     <= S_PIX_HI_TX;
            end

            // ---- SPI 送信 (上位バイト) ----
            S_PIX_HI_TX: begin
                if (!tx_busy && !tx_start) begin
                    tx_byte   <= cur_color[15:8];
                    tx_dc_reg <= 1'b1;
                    tx_start  <= 1'b1;
                    state     <= S_PIX_HI_W;
                end
            end

            S_PIX_HI_W: begin
                if (!tx_busy && !tx_start) state <= S_PIX_LO_TX;
            end

            // ---- SPI 送信 (下位バイト) ----
            S_PIX_LO_TX: begin
                if (!tx_busy && !tx_start) begin
                    tx_byte   <= cur_color[7:0];
                    tx_dc_reg <= 1'b1;
                    tx_start  <= 1'b1;
                    state     <= S_PIX_LO_W;
                end
            end

            // ---- カウンタ更新 ----
            S_PIX_LO_W: begin
                if (!tx_busy && !tx_start) begin
                    // 列・行カウンタ更新
                    if (col_cnt == 9'd319) begin
                        col_cnt <= 9'd0;
                        row_cnt <= row_cnt + 8'd1;
                    end else
                        col_cnt <= col_cnt + 9'd1;

                    if (pix_cnt == 17'd76_799) begin
                        // フレーム完了
                        state <= S_FRAME_END;
                    end else begin
                        pix_cnt <= pix_cnt + 17'd1;
                        state   <= S_PIX_CALC;
                    end
                end
            end

            // ---- フレーム完了: 次フレームのタイミング待ち ----
            // move_pulse が来たら次フレームを開始
            S_FRAME_END: begin
                if (move_pulse)
                    state <= S_NEXT_FRAME;
            end

            // ---- 次フレーム: Memory Write コマンド再発行 ----
            // ILI9341 は 0x2C を送るとアドレスポインタが先頭に戻る
            S_NEXT_FRAME: begin
                if (!tx_busy && !tx_start) begin
                    tx_byte   <= 8'h2C;   // Memory Write
                    tx_dc_reg <= 1'b0;    // Command
                    tx_start  <= 1'b1;
                    state     <= S_FRAME_START;
                end
            end

            default: state <= S_WAIT;
        endcase
    end
end

endmodule