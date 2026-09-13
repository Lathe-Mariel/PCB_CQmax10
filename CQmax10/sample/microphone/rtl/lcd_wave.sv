// ============================================================
// lcd_wave.sv
//   ILI9341 SPI LCD コントローラ + 波形描画
//   PMOD-TFTLCD v1.1 (320x240, RGB565)
//
//   画面構成 (横向き: MADCTL = 0x28)
//     背景   : 黒
//     グリッド: 32px ごとの暗い線
//     中央線  : グレー (振幅 0 のライン)
//     波形    : 緑 (1 サンプル = 1 列)
//
//   描画方式:
//     フレーム開始時に書き込みポインタ (wr_ptr) をラッチし、
//     その 320 サンプル前から現在までのデータを
//     左→右に 1 サンプル 1 列で描画する。
//
//   SPI : Mode 0, SCK = CLK_HZ / 4 (= 12.5 MHz @ 50 MHz)
// ============================================================

module lcd_wave #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BUF_AW = 12,           // 波形 RAM アドレス幅
    parameter int LCD_W  = 320,
    parameter int LCD_H  = 240,
    parameter int AMP_GAIN_SHIFT = 2,    // 振幅ゲイン (左シフト量)
    parameter int FRAME_WAIT = 2_500_000, // フレーム間隔 (50MHz -> 50ms)
    parameter int POWERON_WAIT = 7_500_000, // 電源ON後待機 (50MHz -> 150ms)
    parameter int SWRST_WAIT   = 250_000,   // SWRESET 後待機 (5ms)
    parameter int SLPOUT_WAIT  = 6_000_000  // SLPOUT 後待機 (120ms)
) (
    input  logic               clk,
    input  logic               rst_n,       // 非同期リセット (Low 有効)

    // --- PMOD-TFTLCD ---
    output logic               lcd_cs,      // CS   (Low 有効)
    output logic               lcd_dc,      // RS   (1=Data, 0=Command)
    output logic               lcd_mosi,    // MOSI
    output logic               lcd_sck,     // SCK

    // --- 波形 RAM 読み出し ---
    output logic [BUF_AW-1:0]  rd_addr,
    input  logic signed [15:0] rdata,
    input  logic [BUF_AW-1:0]  wr_ptr,      // RAM 書き込みポインタ

    // --- ステータス ---
    output logic               init_done,
    output logic               frame_tick    // 1 フレーム描画完了パルス
);

    // ========================================================
    // 定数
    // ========================================================
    // SPI バイト送信器は 1 ビットあたり 4 クロック使うため
    // SPI クロック = CLK_HZ / 4 = 12.5 MHz となる。
    localparam int TOTAL_PIX = LCD_W * LCD_H;      // 76800
    localparam int CNT_W     = $clog2(TOTAL_PIX);  // 17

    localparam int Y_CENTER = LCD_H / 2;           // 120
    localparam int Y_OFFSET = Y_CENTER - 1;        // 119 (振幅 0 の行)
    localparam int Y_MAXROW = LCD_H - 1;           // 239

    // 定数 (比較用は int のままにしておくとビット幅の切捨て警告が出ない)
    localparam int LAST_PIX = TOTAL_PIX - 1;
    localparam int LAST_COL = LCD_W - 1;
    localparam int LAST_ROW = LCD_H - 1;

    // サイズ付き定数 (演算に使うものだけ幅を明示する)
    localparam logic [BUF_AW-1:0]  OFF_PREV     = LCD_W;
    localparam logic [23:0]        POWERON_CNT  = POWERON_WAIT;
    localparam logic [23:0]        FRAME_WAIT_C = FRAME_WAIT;
    localparam logic [23:0]        SWRST_CNT    = SWRST_WAIT;
    localparam logic [23:0]        SLPOUT_CNT   = SLPOUT_WAIT;
    localparam logic [8:0]         Y_OFFSET_C   = Y_OFFSET;
    localparam logic [7:0]         Y_MAXROW_C   = Y_MAXROW;

    localparam logic [15:0] COL_BG   = 16'h0000;   // 黒
    localparam logic [15:0] COL_GRID = 16'h1082;   // 暗い緑 (グリッド)
    localparam logic [15:0] COL_AXIS = 16'h4208;   // グレー (中央線)
    localparam logic [15:0] COL_WAVE = 16'h07E0;   // 緑 (波形)

    // ========================================================
    // 初期化シーケンス ROM
    //   bit[8] = 0 : CMD (DC = 0)
    //   bit[8] = 1 : DAT (DC = 1)
    // ========================================================
    localparam [6:0] ROM_DEPTH = 7'd64;

    localparam [8:0]
        R00=9'h001, R01=9'h011,                        // SWRESET, SLPOUT
        R02=9'h03A, R03=9'h155,                        // COLMOD  = 0x55
        R04=9'h036, R05=9'h128,                        // MADCTL  = 0x28 (横)
        R06=9'h0B1, R07=9'h100, R08=9'h118,            // FRMCTR1
        R09=9'h0C0, R10=9'h123,                        // PWCTR1
        R11=9'h0C1, R12=9'h110,                        // PWCTR2
        R13=9'h0C5, R14=9'h13E, R15=9'h128,            // VMCTR1
        R16=9'h0C7, R17=9'h186,                        // VMCTR2
        R18=9'h026, R19=9'h101,                        // GAMMASET = 1
        R20=9'h0E0,                                    // GMCTRP1
        R21=9'h10F, R22=9'h131, R23=9'h12B, R24=9'h10C,
        R25=9'h10E, R26=9'h108, R27=9'h14E, R28=9'h1F1,
        R29=9'h137, R30=9'h107, R31=9'h110, R32=9'h103,
        R33=9'h10E, R34=9'h109, R35=9'h100,
        R36=9'h0E1,                                    // GMCTRN1
        R37=9'h100, R38=9'h10E, R39=9'h114, R40=9'h103,
        R41=9'h111, R42=9'h107, R43=9'h131, R44=9'h1C1,
        R45=9'h148, R46=9'h108, R47=9'h10F, R48=9'h10C,
        R49=9'h131, R50=9'h136, R51=9'h10F,
        R52=9'h02A, R53=9'h100, R54=9'h100,            // CASET (0..319)
        R55=9'h101, R56=9'h13F,
        R57=9'h02B, R58=9'h100, R59=9'h100,            // PASET (0..239)
        R60=9'h100, R61=9'h0EF,
        R62=9'h029,                                    // DISPON
        R63=9'h02C;                                    // Memory Write

    function automatic [8:0] rom_read(input [6:0] addr);
        case (addr)
            7'd0:  rom_read = R00;  7'd1:  rom_read = R01;
            7'd2:  rom_read = R02;  7'd3:  rom_read = R03;
            7'd4:  rom_read = R04;  7'd5:  rom_read = R05;
            7'd6:  rom_read = R06;  7'd7:  rom_read = R07;
            7'd8:  rom_read = R08;  7'd9:  rom_read = R09;
            7'd10: rom_read = R10;  7'd11: rom_read = R11;
            7'd12: rom_read = R12;  7'd13: rom_read = R13;
            7'd14: rom_read = R14;  7'd15: rom_read = R15;
            7'd16: rom_read = R16;  7'd17: rom_read = R17;
            7'd18: rom_read = R18;  7'd19: rom_read = R19;
            7'd20: rom_read = R20;  7'd21: rom_read = R21;
            7'd22: rom_read = R22;  7'd23: rom_read = R23;
            7'd24: rom_read = R24;  7'd25: rom_read = R25;
            7'd26: rom_read = R26;  7'd27: rom_read = R27;
            7'd28: rom_read = R28;  7'd29: rom_read = R29;
            7'd30: rom_read = R30;  7'd31: rom_read = R31;
            7'd32: rom_read = R32;  7'd33: rom_read = R33;
            7'd34: rom_read = R34;  7'd35: rom_read = R35;
            7'd36: rom_read = R36;  7'd37: rom_read = R37;
            7'd38: rom_read = R38;  7'd39: rom_read = R39;
            7'd40: rom_read = R40;  7'd41: rom_read = R41;
            7'd42: rom_read = R42;  7'd43: rom_read = R43;
            7'd44: rom_read = R44;  7'd45: rom_read = R45;
            7'd46: rom_read = R46;  7'd47: rom_read = R47;
            7'd48: rom_read = R48;  7'd49: rom_read = R49;
            7'd50: rom_read = R50;  7'd51: rom_read = R51;
            7'd52: rom_read = R52;  7'd53: rom_read = R53;
            7'd54: rom_read = R54;  7'd55: rom_read = R55;
            7'd56: rom_read = R56;  7'd57: rom_read = R57;
            7'd58: rom_read = R58;  7'd59: rom_read = R59;
            7'd60: rom_read = R60;  7'd61: rom_read = R61;
            7'd62: rom_read = R62;  7'd63: rom_read = R63;
            default: rom_read = 9'h000;
        endcase
    endfunction

    // ========================================================
    // 電源 ON 後 150ms 待機
    // ========================================================
    logic [23:0] poweron_cnt;
    logic        init_start;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            poweron_cnt <= '0;
            init_start  <= 1'b0;
        end else if (poweron_cnt == POWERON_CNT) begin
            init_start <= 1'b1;
        end else begin
            poweron_cnt <= poweron_cnt + 24'd1;
        end
    end

    // ========================================================
    // SPI バイト送信器 (Mode 0, MSB ファースト)
    //   tx_cnt[1:0] : 0=MSB 出力, 1=SCK 立上, 2=保持, 3=SCK 立下
    //   tx_cnt[5:2] : ビット番号 0..7
    // ========================================================
    logic [7:0] tx_byte;
    logic       tx_dc_reg;
    logic       tx_start;
    logic       tx_busy;
    logic [5:0] tx_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lcd_cs   <= 1'b1;
            lcd_sck  <= 1'b0;
            lcd_mosi <= 1'b0;
            lcd_dc   <= 1'b0;
            tx_busy  <= 1'b0;
            tx_cnt   <= '0;
        end else if (tx_start && !tx_busy) begin
            tx_busy  <= 1'b1;
            tx_cnt   <= '0;
            lcd_cs   <= 1'b0;
            lcd_dc   <= tx_dc_reg;
            lcd_sck  <= 1'b0;
            lcd_mosi <= tx_byte[7];
        end else if (tx_busy) begin
            tx_cnt <= tx_cnt + 6'd1;
            case (tx_cnt[1:0])
                2'b00: lcd_mosi <= tx_byte[7 - tx_cnt[5:2]];
                2'b01: lcd_sck  <= 1'b1;
                2'b10: ; // 半周期保持
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

    // ========================================================
    // ステートマシン
    // ========================================================
    // ステートマシン (typedef enum は古いシミュレータで扱いにくいため
    // localparam の整数で表現する)
    localparam [3:0]
        S_WAIT       = 4'd0,
        S_INIT_TX    = 4'd1,
        S_INIT_WAIT  = 4'd2,
        S_SWRST_DLY  = 4'd3,
        S_SLPOUT_DLY = 4'd4,
        S_FRAME_START= 4'd5,
        S_PIX_CALC   = 4'd6,
        S_PIX_RD     = 4'd7,
        S_PIX_HI_TX  = 4'd8,
        S_PIX_HI_W   = 4'd9,
        S_PIX_LO_TX  = 4'd10,
        S_PIX_LO_W   = 4'd11,
        S_FRAME_END  = 4'd12,
        S_NEXT_FRAME = 4'd13;

    logic [3:0]  state;
    logic [6:0]  init_idx;
    logic [23:0] dly_cnt;
    logic [23:0] frm_cnt;
    logic [CNT_W-1:0] pix_cnt;
    logic [8:0]  col_cnt;
    logic [7:0]  row_cnt;
    logic [15:0] cur_color;
    logic [BUF_AW-1:0] rd_base;

    // 読み出したサンプルから波形の Y 座標を求める
    //   16bit 符号付き -> ゲイン (左シフト) を掛け、振幅 1 ビット = 1 px
    //   として中央 (Y_OFFSET) からの変位に変換する
    wire signed [31:0] samp_off = $signed(rdata) <<< AMP_GAIN_SHIFT;
    wire signed [31:0] y_raw    = $signed({23'd0, Y_OFFSET_C}) - samp_off;
    wire        [7:0]  y_wave   = (y_raw < 32'sd0)                        ? 8'd0 :
                                  (y_raw > $signed({24'd0, Y_MAXROW_C}))  ? Y_MAXROW_C :
                                                                           y_raw[7:0];

    // 波形は 1 サンプル = 1 列で描画する。
    // 隣接列とのつながりを良くするため WAVE_THICK px の太さで描く。
    localparam int WAVE_THICK = 3;    // 奇数 (1 = 1px 幅)
    localparam int WAVE_HALF  = WAVE_THICK / 2;
    localparam logic [7:0] WAVE_HALF_C = WAVE_HALF;
    wire [7:0] y_lo = (y_wave < WAVE_HALF_C) ? 8'd0
                                             : (y_wave - WAVE_HALF_C);
    wire [7:0] y_hi = ((y_wave + WAVE_HALF_C) > Y_MAXROW_C) ? Y_MAXROW_C
                                                            : (y_wave + WAVE_HALF_C);

    // 現在の列を描画するサンプル位置
    //   rd_base は「最新サンプル + 1」の位置なので、1 サンプル戻してから
    //   LCD_W サンプル前を読み出す (最新の LCD_W サンプルを左→右に描画)
    //   col_cnt は 9bit 固定なので BUF_AW 幅へゼロ拡張する
    wire [BUF_AW-1:0] col_off;
    generate
        if (BUF_AW <= 9) begin : g_col_off
            assign col_off = col_cnt[BUF_AW-1:0];
        end else begin : g_col_off
            assign col_off = {{(BUF_AW-9){1'b0}}, col_cnt};
        end
    endgenerate

    wire [BUF_AW-1:0] rd_idx = rd_base - 1'b1 - OFF_PREV + col_off;

    assign rd_addr = rd_idx;

    // ピクセル色 (S_PIX_RD で rdata が有効)
    function automatic [15:0] pixel_color(
        input [8:0] x,
        input [7:0] y,
        input [7:0] wy_lo,
        input [7:0] wy_hi
    );
        if ((y >= wy_lo) && (y <= wy_hi))         pixel_color = COL_WAVE;
        else if (y == Y_OFFSET_C[7:0])            pixel_color = COL_AXIS;
        else if (x[4:0] == 5'd0)                  pixel_color = COL_GRID;
        else if (y[4:0] == 5'd0)                  pixel_color = COL_GRID;
        else                                      pixel_color = COL_BG;    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_WAIT;
            init_idx   <= '0;
            dly_cnt    <= '0;
            frm_cnt    <= '0;
            pix_cnt    <= '0;
            col_cnt    <= '0;
            row_cnt    <= '0;
            cur_color  <= '0;
            tx_start   <= 1'b0;
            tx_byte    <= '0;
            tx_dc_reg  <= 1'b0;
            rd_base    <= '0;
            init_done  <= 1'b0;
            frame_tick <= 1'b0;
        end else begin
            tx_start   <= 1'b0;
            frame_tick <= 1'b0;

            case (state)

                // ---- 電源 ON 待機 ----
                S_WAIT: begin
                    if (init_start) begin
                        init_idx <= '0;
                        state    <= S_INIT_TX;
                    end
                end

                // ---- 初期化コマンド/データ送信 ----
                S_INIT_TX: begin
                    if (init_idx < ROM_DEPTH) begin
                        if (!tx_busy && !tx_start) begin
                            {tx_dc_reg, tx_byte} <= rom_read(init_idx);
                            tx_start <= 1'b1;
                            state    <= S_INIT_WAIT;
                        end
                    end else begin
                        init_done <= 1'b1;
                        state     <= S_FRAME_START;
                    end
                end

                S_INIT_WAIT: begin
                    if (!tx_busy && !tx_start) begin
                        case (tx_byte)
                            8'h01: begin dly_cnt <= '0; state <= S_SWRST_DLY;  end
                            8'h11: begin dly_cnt <= '0; state <= S_SLPOUT_DLY; end
                            default: begin
                                init_idx <= init_idx + 7'd1;
                                state    <= S_INIT_TX;
                            end
                        endcase
                    end
                end

                // SWRESET 後 5ms
                S_SWRST_DLY: begin
                    if (dly_cnt == SWRST_CNT) begin
                        init_idx <= init_idx + 7'd1;
                        state    <= S_INIT_TX;
                    end else begin
                        dly_cnt <= dly_cnt + 24'd1;
                    end
                end

                // SLPOUT 後 120ms
                S_SLPOUT_DLY: begin
                    if (dly_cnt == SLPOUT_CNT) begin
                        init_idx <= init_idx + 7'd1;
                        state    <= S_INIT_TX;
                    end else begin
                        dly_cnt <= dly_cnt + 24'd1;
                    end
                end

                // ---- フレーム開始 ----
                // 書き込みポインタをラッチして描画範囲を固定する
                S_FRAME_START: begin
                    rd_base <= wr_ptr;
                    pix_cnt <= '0;
                    col_cnt <= '0;
                    row_cnt <= '0;
                    state   <= S_PIX_CALC;
                end

                // ---- 読み出しアドレス設定 ----
                S_PIX_CALC: begin
                    state <= S_PIX_RD;
                end

                // ---- 波形 RAM 読み出し待ち (1 サイクル) ----
                S_PIX_RD: begin
                    cur_color <= pixel_color(col_cnt, row_cnt, y_lo, y_hi);
                    state     <= S_PIX_HI_TX;
                end

                // ---- 上位バイト送信 ----
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

                // ---- 下位バイト送信 ----
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
                        if (col_cnt == LAST_COL) begin
                            col_cnt <= '0;
                            row_cnt <= row_cnt + 8'd1;
                        end else begin
                            col_cnt <= col_cnt + 9'd1;
                        end

                        if (pix_cnt == LAST_PIX) begin
                            frame_tick <= 1'b1;
                            frm_cnt    <= '0;
                            state      <= S_FRAME_END;
                        end else begin
                            pix_cnt <= pix_cnt + 1'b1;
                            state   <= S_PIX_CALC;
                        end
                    end
                end

                // ---- フレーム間待機 ----
                S_FRAME_END: begin
                    if (frm_cnt == FRAME_WAIT_C)
                        state <= S_NEXT_FRAME;
                    else
                        frm_cnt <= frm_cnt + 24'd1;
                end

                // ---- Memory Write 再発行 -> 次フレーム開始 ----
                // ILI9341 は 0x2C を送るとアドレスポインタが先頭に戻る
                S_NEXT_FRAME: begin
                    if (!tx_busy && !tx_start) begin
                        tx_byte   <= 8'h2C;
                        tx_dc_reg <= 1'b0;
                        tx_start  <= 1'b1;
                        state     <= S_FRAME_START;
                    end
                end

                default: state <= S_WAIT;
            endcase
        end
    end

endmodule
