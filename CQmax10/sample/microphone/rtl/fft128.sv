// ============================================================
// fft128.sv
//   128 点 基数 2 バタフライ FFT (in-place, DIT) + パワースペクトル
//
//   処理の流れ:
//     1. din_valid (Fs = 15.625 kHz) を DEC_N 分周して 128 サンプルを
//        入力バッファ (ping-pong) に取り込む。窓掛けも同時に行う。
//     2. 128 サンプルそろったら入力バッファを FFT 用 RAM へコピーし、
//        次の 128 サンプルの取り込みを並行して続ける。
//        このときビットリバースして格納する (DIT の要件)。
//     3. 7 ステージのバタフライを in-place で実行
//     4. Re^2 + Im^2 を自然順の bin として mag2 RAM に書き込む
//
//   ping-pong にしている理由:
//     FFT の実行中も入力サンプルを取り続けるため。入力バッファを
//     2 面持つことで、取り込みと FFT が衝突しない。
//
//   固定小数点:
//     x             : Q0   16bit 符号付き (入力サンプル)
//     窓 / 回転因子 : Q15 / Q14 (fft_tables.svh)
//     内部 X        : Q0   24bit (|X| <= N*max|x| = 2^22 なので足りる)
//     出力 2 乗前   : X を右に OUT_SH bit シフト -> |X| <= 2^14
//                     mag2 <= 2^29 (30bit) で 2 乗が 16x16 に収まる
//     回転因子乗算  : (ra*w) >> 14 で元のスケールに戻す
//
//   周波数分解能:
//     Fse = Fs / DEC_N = 15.625 kHz / 16 = 976.6 Hz
//     df  = Fse / 128 = 7.63 Hz / bin
//     bin 1 = 7.63 Hz、bin 63 = 約 480 Hz (PMOD マイクの帯域内)
//
//   スケーリング:
//     バタフライごとに 1bit 成長する (7 ステージで 2^7 倍) が、
//     内部 24bit に対し最終値は 23bit に収まるので飽和しない。
// ============================================================

`include "fft_tables.svh"

module fft128 #(
    parameter int N      = 128,   // FFT 点数 (128 固定)
    parameter int DEC_N  = 16,    // din_valid の分周比 (Fse = Fs / DEC_N)
    parameter int OUT_SH = 8      // 出力を 2 乗する前の右シフト量
) (
    input  logic               clk,
    input  logic               rst_n,         // 非同期リセット (Low 有効)

    // --- 音声入力 (moving_avg の出力) ---
    input  logic signed [15:0] din,
    input  logic               din_valid,     // Fs = 15.625 kHz の 1 クロックパルス

    // --- スペクトル読み出し (LCD 側から bin を指定) ---
    input  logic [6:0]         mag_addr,      // bin (0 .. 63)
    output logic [33:0]        mag2,          // Re^2 + Im^2 (1 クロック遅れ)

    // --- ステータス ---
    output logic               mag_we,        // bin 書き込みパルス
    output logic [7:0]         frame_index,   // 完了した FFT フレーム数
    output logic               frame_done,    // 1 フレーム完了パルス
    output logic               busy
);

    // ========================================================
    // 定数
    // ========================================================
    localparam int LOG2N = 7;                 // log2(N)
    localparam int HALF  = N / 2;             // 出力するビン数
    localparam int XW    = 24;                // 内部データ幅
    localparam int TW    = 16;                // 回転因子の幅 (Q14)
    localparam int PWD   = XW + TW;           // 乗算結果 40bit
    localparam int PSH   = 14;                // 回転因子の小数ビット数

    localparam logic [2:0]  STAGE_L = 3'(LOG2N - 1);
    localparam logic [6:0]  NLESS1  = 7'(N - 1);
    localparam logic [6:0]  HALF_L1 = 7'(HALF - 1);
    localparam logic [7:0]  DEC_C   = 8'(DEC_N - 1);
    // 1 ステージのバタフライ数 = N/2
    localparam logic [5:0]  BF_LAST = 6'(HALF - 1);

    // ========================================================
    // 1. サンプルの間引き
    //    din_valid は Fs のストローブ。DEC_N 個ごとに 1 サンプル取り込む。
    // ========================================================
    logic [7:0]  dec_cnt;
    logic        take_sample;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_cnt     <= '0;
            take_sample <= 1'b0;
        end else begin
            take_sample <= 1'b0;
            if (din_valid) begin
                if (dec_cnt == DEC_C) begin
                    dec_cnt     <= '0;
                    take_sample <= 1'b1;
                end else begin
                    dec_cnt <= dec_cnt + 8'd1;
                end
            end
        end
    end

    // ========================================================
    // 2. 入力バッファ (ping-pong, 窓掛け済み)
    //    buf_sel = 0 : 取り込み中 / buf_sel = 1 : FFT 待ち or 実行中
    // ========================================================
    logic signed [15:0] buf0 [0:N-1];
    logic signed [15:0] buf1 [0:N-1];

    logic [6:0]  in_cnt;
    logic        buf_sel;
    // 完成した入力ブロック数。取り込み側だけが更新する。
    logic [7:0]  blk_count;
    // FFT 側が消費したブロック数。FSM だけが更新する。
    logic [7:0]  blk_used;

    logic signed [31:0] wprod;      // din * HANN (Q15)
    logic signed [15:0] win_val;    // 窓掛け後 (Q0)

    // 窓掛け。
    //   HANN は 2 次元パック配列なので、要素参照 HANN[in_cnt] だけでは
    //   符号が伝わらず「符号なし乗算」になってしまう (負のサンプルが壊れる)。
    //   $signed() で明示的に符号付きにする。
    assign wprod   = din * $signed(HANN[in_cnt]);
    assign win_val = wprod[30:15];

    // 取り込み (常時、FFT とは独立に進む)
    always_ff @(posedge clk) begin
        if (take_sample) begin
            if (buf_sel == 1'b0) buf0[in_cnt] <= win_val;
            else                 buf1[in_cnt] <= win_val;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_cnt    <= '0;
            buf_sel   <= 1'b0;
            blk_count <= '0;
        end else begin
            if (take_sample) begin
                if (in_cnt == NLESS1) begin
                    in_cnt    <= '0;
                    buf_sel   <= ~buf_sel;   // 面を切り替える
                    blk_count <= blk_count + 8'd1;
                end else begin
                    in_cnt <= in_cnt + 7'd1;
                end
            end
        end
    end

    // ========================================================
    // 3. FFT 内部 RAM (実部 / 虚部)
    //    読み出し 1 ポート + 書き込み 1 ポート
    // ========================================================
    logic signed [XW-1:0] mem_re [0:N-1];
    logic signed [XW-1:0] mem_im [0:N-1];

    logic                 m_we;
    logic [6:0]           m_waddr;
    logic signed [XW-1:0] m_wdata_re;
    logic signed [XW-1:0] m_wdata_im;

    logic [6:0]           m_raddr;
    logic signed [XW-1:0] m_rdr;
    logic signed [XW-1:0] m_rdi;

    always_ff @(posedge clk) begin
        if (m_we) begin
            mem_re[m_waddr] <= m_wdata_re;
            mem_im[m_waddr] <= m_wdata_im;
        end
    end

    always_ff @(posedge clk) begin
        m_rdr <= mem_re[m_raddr];
        m_rdi <= mem_im[m_raddr];
    end

    // ========================================================
    // 4. バタフライのインデックス
    //    1 ステージのバタフライ数は N/2 = 64。
    //    stage s : len = 2^(s+1), half = 2^s
    //      group = bf_idx >> s            (0 .. 2^(6-s)-1)
    //      j     = bf_idx & (2^s - 1)     (回転因子の番号)
    //      idx_a = (group << (s+1)) | j   (0 .. N-1)
    //      idx_b = idx_a + 2^s
    //    回転因子の番号 = j << (LOG2N-1-s)
    // ========================================================
    logic [5:0]  bf_idx;
    logic [2:0]  stage;
    logic [6:0]  out_bin;
    logic [6:0]  cp_idx;

    wire [6:0] ones   = 7'd1 << stage;                  // 2^s
    wire [6:0] mask   = ones - 7'd1;                    // 2^s - 1
    wire [5:0] bf_j   = bf_idx & mask[5:0];
    wire [5:0] bf_grp = bf_idx >> stage;
    // シフトは左オペランドの幅で打ち切られるため、先に 8bit へ広げる
    wire [7:0] ixa_hi = 8'(bf_grp) << (stage + 3'd1);
    wire [7:0] idx_a  = ixa_hi | 8'(bf_j);
    wire [7:0] idx_b  = idx_a + 8'(ones);
    wire [2:0] twsh   = 3'd6 - stage;
    wire [5:0] tw_idx = bf_j << twsh;

    // ========================================================
    // 5. 回転因子 ROM
    // ========================================================
    logic [5:0]           tw_addr_r;
    logic signed [TW-1:0] tw_re;
    logic signed [TW-1:0] tw_im;

    assign tw_re = TW_RE[tw_addr_r];
    assign tw_im = TW_IM[tw_addr_r];

    // ========================================================
    // 6. ステートマシン
    // ========================================================
    localparam [3:0]
        S_IDLE  = 4'd0,
        S_LOAD  = 4'd1,   // 入力バッファ -> mem のコピー
        S_BF_A  = 4'd2,   // idx_a を読み出しアドレスに出す
        S_BF_B  = 4'd3,   // ra/ri ラッチ、idx_b を出す
        S_BF_C  = 4'd4,   // rb/rib ラッチ、回転因子アドレスを出す
        S_BF_D  = 4'd5,   // p1 = ra*wr, p2 = ri*wi
        S_BF_E  = 4'd6,   // p3 = ra*wi, p4 = ri*wr
        S_BF_F  = 4'd7,   // prod_re / prod_im を確定
        S_BF_G  = 4'd8,   // X1..X4 を計算
        S_BF_H  = 4'd9,   // idx_a へ書き込み
        S_BF_I  = 4'd10,  // idx_b へ書き込み + 次へ
        S_OUT_A = 4'd11,  // bin を読み出しアドレスに出す (自然順)
        S_OUT_B = 4'd12,  // re/im ラッチ
        S_OUT_C = 4'd13,  // 2 乗
        S_OUT_D = 4'd14,  // 和を求めて mag2 RAM を書く
        S_OUT_E = 4'd15;  // 次の bin へ (完了判定もここ)

    logic [3:0] state;

    logic signed [XW-1:0]  ra, ri, rb, rib;
    logic signed [PWD-1:0] p1, p2, p3, p4;
    logic signed [XW-1:0]  prod_re, prod_im;
    logic signed [XW-1:0]  x1, x2, x3, x4;

    // b*W : (rb + j*rib) * (wr + j*wi)
    //   = (rb*wr - rib*wi) + j*(rb*wi + rib*wr)
    wire signed [PWD:0] vre = {p1[PWD-1], p1} - {p2[PWD-1], p2};
    wire signed [PWD:0] vim = {p3[PWD-1], p3} + {p4[PWD-1], p4};

    wire signed [XW-1:0] prod_re_next = vre[PSH+XW-1:PSH];
    wire signed [XW-1:0] prod_im_next = vim[PSH+XW-1:PSH];

    // ---- パワースペクトル出力用 ----
    logic signed [XW-1:0] re_o, im_o;
    logic        [31:0]   q1, q2;

    wire signed [15:0] re_sh = $signed(re_o[XW-1:OUT_SH]);
    wire signed [15:0] im_sh = $signed(im_o[XW-1:OUT_SH]);

    // 入力側でビットリバースするため、出力 bin は自然順で読み出す

    // ---- メモリのポート割り当て ----
    wire bf_we = (state == S_BF_H) || (state == S_BF_I);
    wire cp_wr = (state == S_LOAD);

    // 入力バッファは自然順なので、mem へはビットリバースして格納する
    wire [6:0] cp_src = {cp_idx[0], cp_idx[1], cp_idx[2], cp_idx[3],
                         cp_idx[4], cp_idx[5], cp_idx[6]};

    // コピー元は「FFT 対象の面」= 取り込み中の面の反対側
    wire signed [15:0] cp_val = buf_sel ? buf0[cp_src] : buf1[cp_src];

    // 24bit へ符号拡張する。
    // 24'(cp_val) と書くとゼロ拡張になり、負のサンプルが壊れる。
    wire signed [XW-1:0] cp_val_x = {{(XW-16){cp_val[15]}}, cp_val};

    assign m_we       = cp_wr | bf_we;
    assign m_waddr    = cp_wr ? cp_idx
                     : (state == S_BF_I) ? idx_b[6:0] : idx_a[6:0];
    assign m_wdata_re = cp_wr ? cp_val_x
                     : (state == S_BF_I) ? x1 : x3;
    assign m_wdata_im = cp_wr ? {XW{1'b0}}
                     : (state == S_BF_I) ? x2 : x4;

    assign m_raddr = (state == S_OUT_A) ? out_bin
                   : (state == S_BF_A)  ? idx_a[6:0]
                                        : idx_b[6:0];

    // ---- mag2 RAM (書き込み : FFT 側 / 読み出し : LCD 側) ----
    logic [33:0] mem_mag2 [0:HALF-1];
    logic [6:0]  m2w_addr;
    logic [33:0] m2w_data;
    logic        m2w_we;

    always_ff @(posedge clk) begin
        if (m2w_we) mem_mag2[m2w_addr] <= m2w_data;
    end

    always_ff @(posedge clk) begin
        mag2 <= mem_mag2[mag_addr];
    end

    // ========================================================
    // 7. メイン FSM
    // ========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            cp_idx       <= '0;
            blk_used     <= '0;
            bf_idx       <= '0;
            stage        <= '0;
            out_bin      <= '0;
            tw_addr_r    <= '0;
            ra <= '0; ri <= '0; rb <= '0; rib <= '0;
            p1 <= '0; p2 <= '0; p3 <= '0; p4 <= '0;
            prod_re <= '0; prod_im <= '0;
            x1 <= '0; x2 <= '0; x3 <= '0; x4 <= '0;
            re_o <= '0; im_o <= '0;
            q1 <= '0; q2 <= '0;
            m2w_addr <= '0; m2w_data <= '0; m2w_we <= 1'b0;
            mag_we       <= 1'b0;
            frame_index  <= '0;
            frame_done   <= 1'b0;
        end else begin
            mag_we     <= 1'b0;
            m2w_we     <= 1'b0;
            frame_done <= 1'b0;

            case (state)

                // ---- 待機 ----
                //   未処理の入力ブロックがあればロードを開始する
                S_IDLE: begin
                    if (blk_count != blk_used) begin
                        blk_used <= blk_count;
                        cp_idx   <= '0;
                        state    <= S_LOAD;
                    end
                end

                // ---- 入力バッファ -> mem のコピー ----
                S_LOAD: begin
                    if (cp_idx == NLESS1) begin
                        cp_idx <= '0;
                        bf_idx <= '0;
                        stage  <= '0;
                        state  <= S_BF_A;
                    end else begin
                        cp_idx <= cp_idx + 7'd1;
                    end
                end

                // ---- バタフライ ----
                S_BF_A: state <= S_BF_B;

                S_BF_B: begin
                    ra    <= m_rdr;      // mem[idx_a]
                    ri    <= m_rdi;
                    state <= S_BF_C;
                end

                S_BF_C: begin
                    rb        <= m_rdr;  // mem[idx_b]
                    rib       <= m_rdi;
                    tw_addr_r <= tw_idx;
                    state     <= S_BF_D;
                end

                S_BF_D: begin
                    p1    <= rb * tw_re;   // b*W の実部用 (rb*wr)
                    p2    <= rib * tw_im;  // b*W の実部用 (rib*wi)
                    state <= S_BF_E;
                end

                S_BF_E: begin
                    p3    <= rb * tw_im;   // b*W の虚部用 (rb*wi)
                    p4    <= rib * tw_re;  // b*W の虚部用 (rib*wr)
                    state <= S_BF_F;
                end

                S_BF_F: begin
                    prod_re <= prod_re_next;
                    prod_im <= prod_im_next;
                    state   <= S_BF_G;
                end

                S_BF_G: begin
                    x3 <= ra + prod_re;    // idx_a 側 (a + b*W)
                    x4 <= ri + prod_im;
                    x1 <= ra - prod_re;    // idx_b 側 (a - b*W)
                    x2 <= ri - prod_im;
                    state <= S_BF_H;
                end

                S_BF_H: state <= S_BF_I;   // idx_a へ書き込み

                S_BF_I: begin              // idx_b へ書き込み + 次へ
                    if (bf_idx == BF_LAST) begin
                        bf_idx <= '0;
                        if (stage == STAGE_L) begin
                            stage   <= '0;
                            out_bin <= '0;
                            state   <= S_OUT_A;
                        end else begin
                            stage <= stage + 3'd1;
                            state <= S_BF_A;
                        end
                    end else begin
                        bf_idx <= bf_idx + 6'd1;
                        state  <= S_BF_A;
                    end
                end

                // ---- パワースペクトル ----
                S_OUT_A: state <= S_OUT_B;

                S_OUT_B: begin
                    re_o  <= m_rdr;        // mem[bin] = X[bin]
                    im_o  <= m_rdi;
                    state <= S_OUT_C;
                end

                S_OUT_C: begin
                    q1    <= re_sh * re_sh;
                    q2    <= im_sh * im_sh;
                    state <= S_OUT_D;
                end

                S_OUT_D: begin
                    m2w_addr <= out_bin;
                    m2w_data <= q1 + q2;
                    m2w_we   <= 1'b1;
                    state    <= S_OUT_E;
                end

                S_OUT_E: begin             // mag2 RAM の書き込みが完了
                    mag_we <= 1'b1;
                    if (out_bin == HALF_L1) begin
                        frame_index <= frame_index + 8'd1;
                        frame_done  <= 1'b1;
                        state       <= S_IDLE;
                    end else begin
                        out_bin <= out_bin + 7'd1;
                        state   <= S_OUT_A;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign busy = (state != S_IDLE);

endmodule
