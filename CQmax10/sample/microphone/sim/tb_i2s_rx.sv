// ============================================================
// tb_i2s_rx.sv
//   i2s_rx のシミュレーション用テストベンチ
//
//   PMOD-Microphone の代わりに I2S スレーブモデルを接続し、
//   既知の 24bit データを送出して受信値を検証する。
//
//   実行方法 (Questa / ModelSim):
//     vlog ../rtl/i2s_rx.sv tb_i2s_rx.sv
//     vsim -c tb_i2s_rx -do "run -all; quit"
// ============================================================

`timescale 1ns / 1ps

module tb_i2s_rx;

    localparam int CLK_HZ = 50_000_000;
    localparam int SCK_HZ = 1_000_000;

    logic clk = 1'b0;
    logic rst_n;

    // 50 MHz クロック (20 ns)
    always #10 clk = ~clk;

    logic mic_sck;
    logic mic_ws;
    logic mic_sd;

    logic signed [15:0] sample;
    logic               sample_valid;

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------
    i2s_rx #(
        .CLK_HZ (CLK_HZ),
        .SCK_HZ (SCK_HZ)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .mic_sck      (mic_sck),
        .mic_ws       (mic_ws),
        .mic_sd       (mic_sd),
        .sample       (sample),
        .sample_valid (sample_valid)
    );

    // --------------------------------------------------------
    // I2S マイクモデル
    //
    //   mic_sck / mic_ws のエッジを clk で検出して
    //   ビット位置 (bcnt) を DUT と同じ規則で数える。
    //   bcnt = 1..24 の期間に 24bit データを MSB から出力する。
    //   (I2S は WS 変化の 1 SCK 後に MSB を出力する)
    // --------------------------------------------------------
    logic        sck_d, ws_d;
    logic        sck_fall, ws_fall;
    logic [5:0]  bcnt;
    logic [23:0] payload;
    int          frame_cnt;

    always_ff @(posedge clk) begin
        sck_d <= mic_sck;
        ws_d  <= mic_ws;
    end

    assign sck_fall = sck_d & ~mic_sck;
    assign ws_fall  = ws_d  & ~mic_ws;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bcnt <= '0;
        end else if (ws_fall) begin
            bcnt <= '0;          // 左チャネル開始
        end else if (sck_fall) begin
            bcnt <= (bcnt == 6'd63) ? 6'd0 : (bcnt + 6'd1);
        end
    end

    // テストパターン: フレームごとに変化する 24bit 値
    always_ff @(posedge clk) begin
        if (!rst_n)       payload <= 24'h800000;
        else if (ws_fall) payload <= 24'((frame_cnt * 4096) & 24'hFFFFFF);
    end

    always_ff @(posedge clk) begin
        if (!rst_n)       frame_cnt <= 0;
        else if (ws_fall) frame_cnt <= frame_cnt + 1;
    end

    // 左チャネルの bcnt = 1..24 で MSB から出力
    assign mic_sd = ((bcnt >= 6'd1) && (bcnt <= 6'd24))
                  ? payload[24 - bcnt] : 1'b0;

    // --------------------------------------------------------
    // 検証
    // --------------------------------------------------------
    int errors = 0;
    int checks = 0;

    always_ff @(posedge clk) begin
        if (sample_valid) begin
            checks <= checks + 1;
            // 受信値は送信データの上位 16bit と一致するはず
            if (sample !== payload[23:8]) begin
                errors <= errors + 1;
                if (errors < 10)
                    $display("MISMATCH: got %04h, expected %04h (frame %0d)",
                             sample, payload[23:8], frame_cnt);
            end
        end
    end

    initial begin
        rst_n = 1'b0;
        repeat (100) @(posedge clk);
        rst_n = 1'b1;

        // 200 フレーム分待つ (Fs = 15.625 kHz で約 12.8 ms)
        repeat (200) begin
            @(negedge mic_ws);
            @(posedge mic_ws);
            @(negedge mic_ws);
        end

        $display("checks = %0d, errors = %0d", checks, errors);
        if (errors == 0 && checks > 100) $display("TEST PASSED");
        else                             $display("TEST FAILED");
        $stop;
    end

endmodule
