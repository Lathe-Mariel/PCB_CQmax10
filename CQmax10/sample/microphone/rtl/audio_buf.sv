// ============================================================
// audio_buf.sv
//   音声波形表示用 シングルクロック デュアルポート RAM
//
//   書き込み : i2s_rx が取り込んだサンプル (Fs = 15.625 kHz)
//   読み出し : lcd_wave の画面描画 (ランダムアクセス)
//
//   深さ 4096 サンプル (≈ 262 ms)
//     LCD 1 フレームの描画には約 110 ms かかる。
//     フレーム開始時に書き込みポインタをスナップショットして
//     描画中の領域が上書きされないようにするため、
//     深さは「1 フレーム中に進むサンプル数 (約 1720) +
//     表示サンプル数 (240)」より十分大きくとる。
//     4096 - 240 = 3856 サンプル (≈ 246 ms) > 110 ms
// ============================================================

module audio_buf #(
    parameter int AW = 12,   // アドレス幅 (2^12 = 4096)
    parameter int DW = 16    // データ幅
) (
    input  logic                 clk,

    // --- 書き込みポート ---
    input  logic                 we,
    input  logic signed [DW-1:0] wdata,
    output logic [AW-1:0]        wr_ptr,

    // --- 読み出しポート ---
    input  logic [AW-1:0]        rd_addr,
    output logic signed [DW-1:0] rdata
);

    localparam int DEPTH = 1 << AW;

    logic signed [DW-1:0] mem [DEPTH];
    logic [AW-1:0]        wp;

    always_ff @(posedge clk) begin
        if (we) begin
            mem[wp] <= wdata;
            wp      <= wp + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        rdata <= mem[rd_addr];
    end

    assign wr_ptr = wp;

endmodule