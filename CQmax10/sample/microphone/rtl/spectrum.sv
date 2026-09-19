// ============================================================
// spectrum.sv
//   パワースペクトル (mag2) を LCD 表示用の棒グラフ高さに変換する
//
//   動作:
//     1. fft128 が 1 フレーム分 (64 bin) の mag2 を書き終えると
//        frame_done が 1 クロックパルスする。
//     2. それを合図に bin 0..63 を順に読み出し、log2 圧縮して
//        バーの高さ (0..MAX_VAL px) に変換する。
//     3. bar_ram に書き込み、LCD 側は bar_addr で読み出す。
//
//   圧縮方法 (log2 圧縮):
//     mag2 (34bit) の最上位 1 の位置 exp と、その直後の 7bit 仮数
//     mant を取り出し、LOG2_LUT を使って
//         q4 = exp*16 + 16*log2(1 + mant/128)
//     を求める。16 = 1 オクターブなので q4 は log2 を 16 倍した値。
//     これを線形に 0..MAX_VAL へ写像する。
//
//       オクターブ = 6.02 dB なので、q4 1 単位 ≒ 0.376 dB
//
//     LOG_MIN はバー高さ 0 になるしきい値 (ノイズフロア)。
//     LOG_MUL / LOG_SH がゲイン (LOG_MUL / 2^LOG_SH)。
//
//     q4 は最大 544 (msb_pos=33, LUT=16) 程度になるので、
//     LOG_MUL との積は 15bit 以上必要。ここでは 18bit で受ける。
//
//         height = clip( (q4 - LOG_MIN) * LOG_MUL / 2^LOG_SH )
//
//     ゲインの単位は px / octave (1 octave = 6.02 dB)。
//     例) LOG_MUL=11, LOG_SH=4 -> 0.69 px/octave
//         LOG_MUL=33, LOG_SH=4 -> 2.06 px/octave (= ちょうど 3 倍)
//
//   ピークホールド (減衰):
//     前フレームより小さい値は DECAY px/フレームずつ減らす。
//     値が急に消えずスペクトラムアナライザらしい見た目になる。
//
//   棒ごとの表示時間 (BAR_LIFE):
//     各 bin は「あと何フレーム表示するか」のカウンタを持つ。
//     信号があるフレームは寿命を BAR_LIFE に戻し、
//     信号が消えたフレームから 1 つずつ減らして 0 になったら
//     そのビンのバーを 0 にする。
//
//     -> **これがバーの表示時間を決める本命のカウンタ**。
//        信号が消えてから BAR_LIFE フレームの間、
//        そのビンはピーク値を保持して表示され続ける。
//
//     この方式なら LCD 側のフレーム位相に依存しない
//     (LCD の寿命カウンタだと、FFT の 1 クロックパルスを
//      フレーム開始で取りこぼして即座に消えてしまう)。
//
//     ◆ 単位は FFT フレーム (128 サンプル = 6.4 ms) ◆
//     LCD は約 148 ms ごとにしか bar_ram を読まないので、
//     BAR_LIFE が 1 LCD フレーム分 (約 23 FFT フレーム) より
//     小さいと、LCD が読む前に寿命切れで 0 になりバーが点滅する。
//     BAR_LIFE は 25 以上にすること。
//
//  無音時の一括消去 (SIL_FRAMES):
//     フレーム全体が無音 (最大 mag2 < SIG_TH) のまま SIL_FRAMES
//     フレーム続いたら、全ビンを 0 にする。
//     ◆ SIL_FRAMES は BAR_LIFE 以上にすること ◆
//     小さいとビンごとの寿命より先に全部消えてしまい、
//     BAR_LIFE をいくら上げても表示が伸びない (以前は 2 で、
//     これが「表示がすぐ消える」原因だった)。
//
//   fft128 側の mag2 読み出しは 1 クロック遅れなので、
//   アドレスを出してから 2 クロック待ってから値を使う。
//
//   対数圧縮は組み合わせ遅延が大きいため、以下の 4 段にパイプライン化
//   している (50 MHz / 20 ns に収めるため)。
//     1. 最上位ビット位置 (優先エンコーダ)
//     2. 正規化シフト (仮数部の抽出)
//     3. log2 LUT + 加算
//     4. ゲイン + クリップ + ピークホールド判定
// ============================================================

`include "fft_tables.svh"

module spectrum #(
    parameter int N_BINS    = 64,    // 変換するビン数 (= fft128 の HALF)
    parameter int START_BIN = 1,     // この bin から処理する (0 = DC は除外)
    parameter int MAX_VAL   = 239,   // バーの最大高さ (px)
    parameter int LOG_MIN   = 128,   // バー 0 になる q4 (= 2^8 -> mag2 256)
    parameter int LOG_MUL   = 11,    // ゲイン分子
    parameter int LOG_SH    = 4,     // ゲイン分母 (2^LOG_SH)
    parameter int DECAY     = 2,     // 1 フレームあたりの減衰量 (px)
    parameter int SIG_TH    = 1024,  // 無音とみなす mag2 のしきい値
    parameter int BAR_LIFE  = 6,     // バーの表示時間 (FFT フレーム数)
    parameter int SIL_FRAMES = 2     // 全ビン一括消去までの無音フレーム数
) (
    input  logic        clk,
    input  logic        rst_n,

    // --- fft128 との接続 ---
    output logic [6:0]  mag_addr,      // 読み出す bin
    input  logic [33:0] mag2,          // パワー (1 クロック遅れ)
    input  logic        frame_done,    // 1 フレーム完了パルス

    // --- LCD 側の読み出し ---
    input  logic [5:0]  bar_addr,      // 表示したい bin
    output logic [7:0]  bar_data,      // バーの高さ (1 クロック遅れ)

    // --- ステータス ---
    output logic        busy,          // 変換中
    output logic        bar_fresh      // バーを更新した (1 フレーム 1 パルス)
);

    // ========================================================
    // 定数
    // ========================================================
    localparam int LAST_BIN = N_BINS - 1;

    // 型付き定数 (古いツールはサイズ付きキャストを持たないため
    // localparam で幅を明示する)
    localparam logic [5:0]  LAST_BIN_C  = LAST_BIN[5:0];
    localparam logic [6:0]  START_BIN_C = START_BIN[6:0];
    localparam logic [10:0] MAX_VAL_C   = MAX_VAL;
    localparam logic [9:0]  LOG_MIN_C   = LOG_MIN;
    localparam logic [7:0]  DECAY_C     = DECAY;
    localparam logic [33:0] SIG_TH_C    = SIG_TH;
    //   表示時間は ms 単位で 1 秒以上にもなるため 16bit
    localparam logic [15:0] BAR_LIFE_C  = BAR_LIFE;
    localparam logic [15:0] SIL_FRAMES_C = SIL_FRAMES;

    // ========================================================
    // バーの高さ RAM (LCD 読み出しポート)
    // ========================================================
    logic [7:0] bar_ram [0:N_BINS-1];

    // 各 bin の寿命カウンタ (FFT フレーム数)。0 = もう表示しない
    //   数秒の保持を扱えるよう 16bit
    logic [15:0] bar_life [0:N_BINS-1];

    always_ff @(posedge clk) begin
        bar_data <= bar_ram[bar_addr];
    end

    // ========================================================
    // mag2 -> バーの高さ
    //  パイプライン各段の組み合わせ演算
    // ========================================================

    // --- 段 1 : 最上位ビット位置 (優先エンコーダ) ---
    logic [5:0] msb_pos;
    integer     idx;

    always_comb begin
        msb_pos = 6'd0;
        // 小さい方から見て「あと勝ち」にすることで最上位が残る
        for (idx = 0; idx <= 33; idx = idx + 1)
            if (mag2[idx]) msb_pos = idx[5:0];
    end

    // --- 段 2 : 正規化 (仮数部 = 最上位 1 の直後 7bit) ---
    logic [33:0] m2_r;      // 段 1 で取り込んだ mag2
    logic [5:0]  exp_r;     // 段 1 で取り込んだ msb_pos
    logic [6:0]  mant_r;    // 段 2 の結果

    wire [5:0]  shamt    = 6'd33 - exp_r;
    wire [33:0] norm     = m2_r << shamt;
    wire [6:0]  mant_now = norm[32:26];

    // --- 段 3 : q4 = 16*log2(mag2) ---
    logic [9:0] q4_r;

    wire [9:0] q4_now = {exp_r, 4'b0} + {5'b0, LOG2_LUT[mant_r]};

    // --- 段 4 : 高さへの写像 ---
    logic [7:0] h_r;        // 段 4 の結果 (しきい値クリップ済み)
    logic [7:0]  old_val;   // 前フレームのバー高さ
    logic [15:0] life_r;    // 前フレームの寿命カウンタ

    //   q4 <= LOG_MIN なら 0、それ以外はゲインを掛けてクリップする。
    //   積は (q4 - LOG_MIN) <= 544, LOG_MUL <= 255 なので 18bit。
    wire [10:0] rel = (q4_r > LOG_MIN_C) ? (q4_r - LOG_MIN_C) : 11'd0;
    wire [17:0] gain = rel * LOG_MUL;
    wire [17:0] gsh  = gain >> LOG_SH;
    wire [7:0]  height_now = (gsh > MAX_VAL_C) ? MAX_VAL_C[7:0] : gsh[7:0];

    // ピークホールド : 前フレームより低い値は DECAY ずつしか減らさない
    wire [7:0] decayed = (old_val > DECAY_C) ? (old_val - DECAY_C) : 8'd0;

    // 寿命の判定
    //   has_sig : このフレームにノイズフロアを超える値があった
    //   expired : 寿命カウンタが 0 -> もう表示しない (バーは 0)
    //
    //   信号があれば毎フレーム寿命をリセットするので、表示中は消えない。
    //   信号が無くなると BAR_LIFE フレーム後にそのビンだけ 0 になる。
    //   信号があるフレームは寿命に関係なく即座に表示する
    //   (クリア直後の 1 フレーム目から見えるようにするため)。
    wire        has_sig   = (height_now != 8'd0);
    wire        expired   = (life_r == 16'd0);
    wire [15:0] life_next = has_sig    ? BAR_LIFE_C
                          : expired    ? 16'd0
                                       : (life_r - 16'd1);
    // バーの高さ : ピークホールド (信号が無いときは DECAY で減衰)
    wire [7:0]  held      = (height_now >= old_val) ? height_now : decayed;
    wire [7:0]  bar_next  = (has_sig || !expired)   ? held : 8'd0;

    // ========================================================
    // ステートマシン
    // ========================================================
    localparam [2:0]
        S_CLR  = 3'd0,   // 起動時に bar_ram を 0 で埋める
        S_IDLE = 3'd1,   // frame_done 待ち
        S_W1   = 3'd2,   // mag_addr を出して 1 クロック待つ
        S_ENC  = 3'd3,   // mag2 が有効 : 最上位ビット位置を求める
        S_NORM = 3'd4,   // 仮数部を抽出
        S_LOG  = 3'd5,   // log2 LUT + 加算
        S_GAIN = 3'd6,   // ゲイン + クリップ
        S_HOLD = 3'd7;   // ピークホールド判定

    logic [2:0] state;
    logic [5:0] bin;
    logic [5:0] clr_bin;

    // ---- 無音検出 ----
    //   フレーム中に読み出した mag2 の最大値が SIG_TH 未満なら無音。
    //   無音が SIL_FRAMES フレーム続いたら、その次のフレームで
    //   全バーを 0 に消去する (消去は 1 フレームで完了する)。
    //
    //   判定は「読み出しパスが終わった時点」で行う。フレーム開始時に
    //   見ると、読み出し前の pk (= 0) で判断してしまい、信号が現れた
    //   最初のフレームを消してしまうため。
    //
    //   消去後は sil_cnt を 1 に戻す (ヒステリシス)。これで無音が
    //   ずっと続いても消去は SIL_FRAMES ごとに 1 回で済む。
    logic [33:0] pk;            // このフレームの最大 mag2
    logic [15:0] sil_cnt;       // 無音が連続したフレーム数
    logic        wipe;          // このパスは消去のみ行う

    wire        silent   = (pk < SIG_TH_C);
    wire [15:0] sil_inc  = (sil_cnt == 16'hFFFF) ? 16'hFFFF : (sil_cnt + 16'd1);
    wire        wipe_go  = silent && (sil_inc >= SIL_FRAMES_C);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_CLR;
            bin      <= '0;
            clr_bin  <= '0;
            mag_addr <= '0;
            m2_r     <= '0;
            exp_r    <= '0;
            mant_r   <= '0;
            q4_r     <= '0;
            h_r      <= '0;
            old_val  <= '0;
            life_r   <= '0;
            pk        <= '0;
            sil_cnt   <= '0;
            wipe      <= 1'b0;
            bar_fresh <= 1'b0;
        end else begin
            bar_fresh <= 1'b0;
            case (state)

                // ---- 起動時のクリア (配列を for で消すと
                //      ラッチ推論の警告が出るため 1 個ずつ消す) ----
                S_CLR: begin
                    bar_ram[clr_bin]  <= 8'd0;
                    bar_life[clr_bin] <= 16'd0;
                    if (clr_bin == LAST_BIN_C) begin
                        state <= S_IDLE;
                    end else begin
                        clr_bin <= clr_bin + 6'd1;
                    end
                end

                // ---- FFT 1 フレーム完了待ち ----
                S_IDLE: begin
                    if (frame_done) begin
                        // DC (bin 0) は Hann 窓の漏れで常に最大に
                        // なってしまうため START_BIN から始める。
                        // bar_ram[0] はクリア時の 0 のまま残る。
                        bin      <= START_BIN_C[5:0];
                        mag_addr <= START_BIN_C;
                        pk       <= '0;
                        state    <= S_W1;
                    end
                end

                // ---- mag_addr 出力後 2 クロック待つ ----
                S_W1: state <= S_ENC;

                // ---- 段 1 : mag2 が有効。エンコーダと一緒に取り込む ----
                S_ENC: begin
                    m2_r    <= mag2;
                    exp_r   <= msb_pos;
                    old_val <= bar_ram[bin];
                    life_r  <= bar_life[bin];
                    if (!wipe && (mag2 > pk)) pk <= mag2;   // 最大値を記録
                    state   <= S_NORM;
                end

                // ---- 段 2 : 仮数部 ----
                S_NORM: begin
                    mant_r <= mant_now;
                    state  <= S_LOG;
                end

                // ---- 段 3 : log2 ----
                S_LOG: begin
                    q4_r  <= q4_now;
                    state <= S_GAIN;
                end

                // ---- 段 4 : ゲインとクリップ ----
                S_GAIN: begin
                    h_r   <= height_now;
                    state <= S_HOLD;
                end

                // ---- ピークホールド判定 + 書き込み ----
                S_HOLD: begin
                    // 消去フレームは強制的に 0 を書く
                    if (wipe) begin
                        bar_ram[bin]  <= 8'd0;
                        bar_life[bin] <= 16'd0;
                    end else begin
                        // 寿命が切れていれば 0、まだあれば寿命内の高さを書く
                        bar_ram[bin]  <= bar_next;
                        bar_life[bin] <= life_next;
                    end

                    if (bin == LAST_BIN_C) begin
                        // 読み出しパス終了。ここで無音を判定して次の
                        // フレームの動作を決める。
                        if (wipe) begin
                            // 消去し終わった -> ヒステリシスのため 1 に戻す
                            sil_cnt <= 16'd1;
                            wipe    <= 1'b0;
                        end else begin
                            sil_cnt <= silent ? sil_inc : 16'd0;
                            wipe    <= wipe_go;   // 次のフレームで消去する
                        end
                        bar_fresh <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        bin      <= bin + 6'd1;
                        mag_addr <= {1'b0, bin} + 7'd1;
                        state    <= S_W1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign busy = (state != S_IDLE);

endmodule
