// ============================================================
// i2s_rx.sv
//   PMOD-Microphone v1.0 (I2S MEMS マイク) 受信回路
//
//   FPGA がマスタとなり SCK (ビットクロック) と
//   WS (LRCLK / ワードセレクト) を生成し、
//   SD から I2S フォーマットの音声データを取り込む。
//
//   フォーマット : Philips I2S
//     - WS は SCK の立ち下がりエッジで変化
//     - データは MSB ファースト
//     - WS 変化の 1 SCK 後に MSB が出力される
//     - 受信側は SCK の立ち上がりエッジでサンプリング
//     - 1 フレーム = 64 SCK (32bit x 2ch)
//
//   サンプリング周波数 Fs = SCK_HZ / 64
//     SCK_HZ = 1 MHz  ->  Fs = 15.625 kHz
//
//   出力 sample : 24bit データの上位 16bit (符号付き, 2 の補数)
// ============================================================

module i2s_rx #(
    parameter int CLK_HZ = 50_000_000,   // 入力クロック周波数
    parameter int SCK_HZ = 1_000_000     // ビットクロック周波数
) (
    input  logic               clk,
    input  logic               rst_n,        // 非同期リセット (Low 有効)

    // --- PMOD-Microphone ---
    output logic               mic_sck,      // ビットクロック (FPGA -> MIC)
    output logic               mic_ws,       // ワードセレクト (FPGA -> MIC)
    input  logic               mic_sd,       // シリアルデータ (MIC -> FPGA)

    // --- 取り込んだ音声データ ---
    output logic signed [15:0] sample,       // 24bit の上位 16bit
    output logic               sample_valid  // 1 サンプル確定時の 1 クロックパルス
);

    // --------------------------------------------------------
    // ビットクロック生成
    //   div_cnt : 0 .. DIV-1
    //   SCK : div_cnt < HALF -> Low, それ以外 -> High
    // --------------------------------------------------------
    localparam int DIV  = (CLK_HZ + SCK_HZ / 2) / SCK_HZ;  // 50
    localparam int HALF = DIV / 2;                         // 25

    logic [15:0] div_cnt;
    logic [5:0]  bit_idx;      // 0 .. 63 (フレーム内ビット位置)
    logic        ws_r;
    logic [23:0] shift;        // 受信シフトレジスタ
    logic signed [15:0] sample_r;
    logic        valid_r;

    wire       div_wrap  = (div_cnt == 16'(DIV - 1));
    wire       rise_tick = (div_cnt == 16'(HALF - 1));   // SCK 立ち上がり
    wire       fall_tick = div_wrap;                     // SCK 立ち下がり

    wire [4:0]  bit_pos    = bit_idx[4:0];               // チャネル内 0..31
    wire        in_data    = (bit_pos >= 5'd1) && (bit_pos <= 5'd24);
    wire        is_left    = (ws_r == 1'b0);
    wire [23:0] shift_next = {shift[22:0], mic_sd};
    wire [5:0]  bit_next   = (bit_idx == 6'd63) ? 6'd0 : (bit_idx + 6'd1);

    assign mic_sck = (div_cnt >= 16'(HALF));
    assign mic_ws  = ws_r;

    assign sample       = sample_r;
    assign sample_valid = valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt  <= '0;
            bit_idx  <= '0;
            ws_r     <= 1'b0;
            shift    <= '0;
            sample_r <= '0;
            valid_r  <= 1'b0;
        end else begin
            div_cnt <= div_wrap ? '0 : (div_cnt + 16'd1);
            valid_r <= 1'b0;

            // --- SCK 立ち下がり: ビット位置と WS を更新 ---
            //     左ch = bit_idx 0..31, 右ch = bit_idx 32..63
            if (fall_tick) begin
                bit_idx <= bit_next;
                ws_r    <= (bit_next >= 6'd32);
            end

            // --- SCK 立ち上がり: データを取り込む ---
            //     bit_pos = 0 は I2S の 1 ビット遅延なので取り込まない
            if (rise_tick && in_data) begin
                shift <= shift_next;

                // 左チャネル (= モノラルマイクのデータ) を採用
                if ((bit_pos == 5'd24) && is_left) begin
                    sample_r <= shift_next[23:8];   // 24bit の上位 16bit
                    valid_r  <= 1'b1;
                end
            end
        end
    end

endmodule
