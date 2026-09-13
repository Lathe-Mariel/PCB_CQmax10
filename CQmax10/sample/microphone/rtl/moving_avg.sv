// ============================================================
// moving_avg.sv
//   移動平均フィルタ (ノイズ低減用)
//
//   N サンプルの単純移動平均を出力する。
//   ランニングサム方式なので乗算器は不要 (加算 2 回のみ)。
//
//   Fs = 15.625 kHz, N = 8 の場合の -3dB 遮断周波数は約 1.1 kHz。
//   耳障りな高周波ノイズを落としつつ、音声波形の形は保たれる。
//
//   平均は「サンプル列を N 個ずつ矩形窓で平均」する FIR フィルタと
//   等価。乗算が不要で FPGA では最も安価な平滑化手段。
// ============================================================

module moving_avg #(
    parameter int N  = 8,    // 平均するサンプル数 (2 の冪)
    parameter int DW = 16    // データ幅
) (
    input  logic                 clk,
    input  logic                 rst_n,      // 非同期リセット (Low 有効)

    input  logic                 valid_in,   // 入力有効 (1 クロックパルス)
    input  logic signed [DW-1:0] data_in,

    output logic signed [DW-1:0] data_out,   // 移動平均値
    output logic                 valid_out   // 1 クロック遅れて出力
);

    localparam int AW = $clog2(N);        // 履歴バッファのアドレス幅
    // 和のビット幅を 1bit 余分に取る。
    // これにより acc - hist[wp] の中間結果が 19bit からはみ出しても
    // 切り捨てが起きない (Verilog は全オペランドの最大幅で演算するため)。
    localparam int SW = DW + AW + 1;

    logic signed [DW-1:0] hist [0:N-1];   // 過去 N サンプルの履歴
    logic [AW-1:0]        wp;             // 履歴の書き込み位置
    logic signed [SW-1:0] acc;            // 現在の窓の合計値
    logic [AW:0]          fill;           // 有効なサンプル数 (0 .. N)

    // 窓が埋まったかどうかの判定用 (幅を明示して切捨て警告を避ける)
    localparam logic [AW:0] N_CNT = N[AW:0];

    // 次の合計
    //   窓がまだ埋まっていない間は hist[wp] を引かない
    //   (hist は 1 度も書かれていない位置を参照するため)
    //   窓が埋まった後はランニングサムで最古の値を引く
    wire signed [SW-1:0] acc_next = (fill == N_CNT)
                                 ? (acc - hist[wp] + data_in)
                                 : (acc + data_in);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // hist をリセットするループを置くと合成時にラッチを
            // 推論するツールがあるため、acc を 0 に戻し
            // fill カウンタで窓が埋まるまで hist を参照しない方式にする
            wp        <= '0;
            acc       <= '0;
            fill      <= '0;
            data_out  <= '0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_in;

            if (valid_in) begin
                hist[wp] <= data_in;
                wp       <= wp + 1'b1;
                acc      <= acc_next;
                if (fill != N_CNT)
                    fill <= fill + 1'b1;
                // 合計 / N : 符号付きなので算術シフト相当のビット選択
                // acc_next[SW-2:AW] は符号ビットを含む DW bit になる
                data_out <= acc_next[SW-2:AW];
            end
        end
    end

endmodule
