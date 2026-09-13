// ============================================================
// top.sv
//   マイクで取り込んだ音声波形を LCD に表示する
//
//   [PMOD 1] PMOD-Microphone v1.0 (I2S MEMS マイク)
//     FPGA が I2S マスタとして SCK / WS を生成し SD を受信
//
//   [PMOD 2] PMOD-TFTLCD v1.1 (ILI9341, 320x240, SPI)
//     音声波形を 1 サンプル 1 列で描画
//
//   構成:
//     i2s_rx     : I2S 受信      -> sample (16bit 符号付き)
//     moving_avg : 移動平均      -> ノイズ低減
//     audio_buf  : 波形用 RAM    -> 4096 サンプルのリングバッファ
//     lcd_wave   : ILI9341 制御 + 波形描画
//
//   ボタン (btn_rst) を押すとリセット
// ============================================================

module top (
    // --- クロック / リセット ---
    input  logic       clk,        // PIN_88 : 50 MHz
    input  logic       btn_rst,    // PIN_17 : 押下 = Low

    // --- PMOD 1 : Microphone ---
    output logic       mic_sck,    // PIN_47 : SCK
    output logic       mic_ws,     // PIN_45 : WS
    input  logic       mic_sd,     // PIN_39 : SD

    // --- PMOD 2 : LCD ---
    output logic       lcd_cs,     // PIN_81 : CS
    output logic       lcd_dc,     // PIN_77 : RS
    output logic       lcd_mosi,   // PIN_78 : MOSI
    output logic       lcd_sck,    // PIN_75 : CLK

    // --- LED ---
    output logic       led,        // PIN_85 : フレーム描画ごとにトグル
    output logic       led0,       // PIN_123: マイク入力検出
    output logic       led1,       // PIN_122: サンプル受信ごとにトグル
    output logic       led2,       // PIN_121: 未使用 (0)
    output logic       led3        // PIN_120: LCD 初期化完了
);

    // ========================================================
    // パラメータ
    // ========================================================
    localparam int CLK_HZ  = 50_000_000;   // 入力クロック
    localparam int SCK_HZ  = 1_000_000;    // I2S ビットクロック (Fs = 15.625 kHz)
    localparam int BUF_AW  = 12;           // 波形 RAM アドレス幅 (4096 サンプル)

    localparam int AVG_N         = 8;      // 移動平均のサンプル数
    localparam int AMP_GAIN_SHIFT = 0;     // 波形表示ゲイン (1 -> 2倍)

    // ========================================================
    // 電源投入時リセット + ボタン 2 段同期化
    //   rst_n : Low 有効の非同期リセット
    // ========================================================
    logic [15:0] por_cnt;
    logic        btn_r1, btn_r2;
    logic        rst_n;

    always_ff @(posedge clk) begin
        if (por_cnt != 16'hFFFF) por_cnt <= por_cnt + 16'd1;
    end

    always_ff @(posedge clk) begin
        btn_r1 <= btn_rst;
        btn_r2 <= btn_r1;
    end

    assign rst_n = (por_cnt == 16'hFFFF) & btn_r2;

    // ========================================================
    // I2S マイク受信
    // ========================================================
    logic signed [15:0] sample;
    logic               sample_valid;

    i2s_rx #(
        .CLK_HZ (CLK_HZ),
        .SCK_HZ (SCK_HZ)
    ) u_i2s_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .mic_sck      (mic_sck),
        .mic_ws       (mic_ws),
        .mic_sd       (mic_sd),
        .sample       (sample),
        .sample_valid (sample_valid)
    );

    // ========================================================
    // 移動平均フィルタ (ノイズ低減)
    //   AVG_N サンプル分の平均をとることで、波形に乗る
    //   高周波ノイズを抑える。
    // ========================================================
    logic signed [15:0] avg_sample;
    logic               avg_valid;

    moving_avg #(
        .N  (AVG_N),
        .DW (16)
    ) u_moving_avg (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (sample_valid),
        .data_in   (sample),
        .data_out  (avg_sample),
        .valid_out (avg_valid)
    );

    // ========================================================
    // 波形用リングバッファ
    // ========================================================
    logic [BUF_AW-1:0] rd_addr;
    logic [BUF_AW-1:0] wr_ptr;
    logic signed [15:0] rdata;

    audio_buf #(
        .AW (BUF_AW),
        .DW (16)
    ) u_audio_buf (
        .clk      (clk),
        .we       (avg_valid),
        .wdata    (avg_sample),
        .wr_ptr   (wr_ptr),
        .rd_addr  (rd_addr),
        .rdata    (rdata)
    );

    // ========================================================
    // LCD コントローラ + 波形描画
    // ========================================================
    logic init_done;
    logic frame_tick;

    lcd_wave #(
        .CLK_HZ         (CLK_HZ),
        .BUF_AW         (BUF_AW),
        .LCD_W          (320),
        .LCD_H          (240),
        .AMP_GAIN_SHIFT (AMP_GAIN_SHIFT),
        .FRAME_WAIT     (2_500_000)   // 50 ms
    ) u_lcd_wave (
        .clk        (clk),
        .rst_n      (rst_n),
        .lcd_cs     (lcd_cs),
        .lcd_dc     (lcd_dc),
        .lcd_mosi   (lcd_mosi),
        .lcd_sck    (lcd_sck),
        .rd_addr    (rd_addr),
        .rdata      (rdata),
        .wr_ptr     (wr_ptr),
        .init_done  (init_done),
        .frame_tick (frame_tick)
    );

    // ========================================================
    // LED インジケータ
    // ========================================================
    logic led_frame;
    logic led_sample;
    logic [22:0] mic_act_cnt;

    // フレーム描画ごとにトグル
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)       led_frame <= 1'b0;
        else if (frame_tick) led_frame <= ~led_frame;
    end

    // サンプル受信ごとにトグル
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)             led_sample <= 1'b0;
        else if (sample_valid)  led_sample <= ~led_sample;
    end

    // マイク入力がある間点灯 (約 0.17 秒間保持)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)            mic_act_cnt <= '0;
        else if (sample_valid) mic_act_cnt <= '0;
        else if (mic_act_cnt != 23'h7FFFFF) mic_act_cnt <= mic_act_cnt + 23'd1;
    end

    assign led  = led_frame;
    assign led0 = (mic_act_cnt != 23'h7FFFFF);
    assign led1 = led_sample;
    assign led2 = 1'b0;
    assign led3 = init_done;

endmodule
