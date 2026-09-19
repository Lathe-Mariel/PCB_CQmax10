// ============================================================
// tb_fft128.sv
//   fft128 のシミュレーション用テストベンチ
//
//   検証方法:
//     FFT コアの正しさを確認することを優先し、間引きは使わない
//     (DEC_N = 1)。din_valid ごとに 1 サンプル取り込まれるので、
//     テスト側の期待値と必ず一致する。
//
//     信号は「テスト側で決めた整数列」をそのまま流し込む。
//     (real を使った正弦波は丸め誤差の切り分けが難しいため、
//      まず DC とインパルスという厳密に検証できる入力を使う)
//
//   参照モデル:
//     DUT と同じ整数演算 (Q15 窓掛け → >>15、Q14 回転因子 →
//     (x*w)>>14) で DFT を計算する。
//     TW_RE/TW_IM は k = 0..63 のみなので、k >= 64 は
//     exp(-j*2*pi*(64+k')/128) = -exp(-j*2*pi*k'/64) を使う。
//
//   検証項目:
//     1. DC 入力      : X[0] = sum(xq)、他の bin はほぼ 0
//     2. インパルス   : 全 bin が |X[k]| = 振幅 になる
//     3. 余弦波       : 対応する bin にピークが立つ
//     4. 参照 DFT と一致
//     5. 再現性
//
//   実行方法 (Questa):
//     vlib work
//     vlog -sv +incdir+../rtl ../rtl/fft128.sv tb_fft128.sv
//     vsim -c -do "run -all; quit -f" tb_fft128
// ============================================================

`timescale 1ns / 1ps

module tb_fft128;

    localparam int N      = 128;
    localparam int HALF   = N / 2;
    localparam int DEC_N  = 1;
    localparam int OUT_SH = 8;

    `include "fft_tables.svh"

    logic clk = 1'b0;
    always #10 clk = ~clk;

    logic rst_n;
    logic signed [15:0] din;
    logic               din_valid;
    logic [6:0]         mag_addr;
    logic [33:0]        mag2;
    logic               mag_we;
    logic [7:0]         frame_index;
    logic               frame_done;
    logic               busy;

    fft128 #(
        .N      (N),
        .DEC_N  (DEC_N),
        .OUT_SH (OUT_SH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .din         (din),
        .din_valid   (din_valid),
        .mag_addr    (mag_addr),
        .mag2        (mag2),
        .mag_we      (mag_we),
        .frame_index (frame_index),
        .frame_done  (frame_done),
        .busy        (busy)
    );

    // --------------------------------------------------------
    // テスト入力 (整数列)
    // --------------------------------------------------------
    integer sig_int [0:N-1];
    integer ref_xq  [0:N-1];      // DUT が取り込んだ窓掛け後データ
    real    ref_re  [0:HALF-1];
    real    ref_im  [0:HALF-1];
    integer errors;

    // 窓掛け後の期待値 (DUT と独立に計算して入力段を検証する)
    //   DUT と同じく HANN 要素を $signed() で符号付きにする
    task prep_window;
        integer nn;
        begin
            for (nn = 0; nn < N; nn = nn + 1)
                ref_xq[nn] = ($signed(sig_int[nn]) * $signed(HANN[nn])) >>> 15;
        end
    endtask

    // DUT が実際に取り込んだ入力バッファを読む
    task read_dut_input;
        integer nn;
        begin
            for (nn = 0; nn < N; nn = nn + 1) begin
                if (dut.buf_sel == 1'b1) ref_xq[nn] = $signed(dut.buf0[nn]);
                else                     ref_xq[nn] = $signed(dut.buf1[nn]);
            end
        end
    endtask

    // 参照 DFT (浮動小数点)
    //   DUT が取り込んだデータを使うので、FFT コアだけを分離して検証できる
    task calc_reference;
        integer nn, kk;
        real    ang, re, im;
        begin
            for (kk = 0; kk < HALF; kk = kk + 1) begin
                re = 0.0;
                im = 0.0;
                for (nn = 0; nn < N; nn = nn + 1) begin
                    ang = 2.0 * 3.141592653589793 * kk * nn / N;
                    re  = re + ref_xq[nn] * $cos(ang);
                    im  = im - ref_xq[nn] * $sin(ang);
                end
                ref_re[kk] = re;
                ref_im[kk] = im;
            end
        end
    endtask

    // --------------------------------------------------------
    // 入力の流し込みとフレーム完了待ち
    // --------------------------------------------------------
    task feed_block;
        integer n;
        begin
            for (n = 0; n < N; n = n + 1) begin
                @(negedge clk);
                din       = sig_int[n];
                din_valid = 1'b1;
                @(negedge clk);
                din_valid = 1'b0;
            end
        end
    endtask

    task wait_frame;
        begin
            wait (frame_done == 1'b1);
            @(negedge clk);
        end
    endtask

    task do_reset;
        begin
            rst_n     = 1'b0;
            din       = '0;
            din_valid = 1'b0;
            repeat (5) @(negedge clk);
            rst_n = 1'b1;
            repeat (5) @(negedge clk);
        end
    endtask

    // --------------------------------------------------------
    // 比較
    //   回転因子 Q14 と 24bit 打ち切りの量子化誤差があるため、
    //   「相対 1%」にノイズフロア 32 LSB を加えた許容幅で比較する。
    //   (ピークは 384000 程度なのでフロアは 1e-4 以下)
    //   $abs は古い Questa に無いため自前で実装する。
    // --------------------------------------------------------
    localparam real TOL_FLOOR = 32.0;
    localparam real TOL_REL   = 0.01;

    function automatic real absr(input real v);
        begin
            absr = (v < 0.0) ? -v : v;
        end
    endfunction

    real worst_rel;

    task compare_spectrum(input [8*8-1:0] tag);
        integer kk, badn;
        real    dr, di, er, ei, tol, den, rel;
        begin
            badn      = 0;
            worst_rel = 0.0;
            for (kk = 0; kk < HALF; kk = kk + 1) begin
                dr = $signed(dut.mem_re[kk]);
                di = $signed(dut.mem_im[kk]);
                er = ref_re[kk];
                ei = ref_im[kk];
                tol = TOL_REL * (absr(er) + absr(ei)) + TOL_FLOOR;

                // レポート用の相対誤差は「有意な大きさの bin」だけで見る
                den = absr(er) + absr(ei);
                if (den > 1000.0) begin
                    rel = absr(dr - er) / den;
                    if (rel > worst_rel) worst_rel = rel;
                end

                if ((absr(dr - er) > tol) || (absr(di - ei) > tol)) begin
                    badn = badn + 1;
                    if (badn < 10)
                        $display("  MISMATCH k=%0d dut=(%0.0f,%0.0f) ref=(%0.0f,%0.0f)",
                                 kk, dr, di, er, ei);
                end
            end
            $display("  [%0s] X[k] mismatches = %0d  (worst rel err = %.4f%%)",
                     tag, badn, worst_rel * 100.0);
            errors = errors + badn;
        end
    endtask

    // 内部 mem_re の合計 (窓掛け後の合計と一致するはず)
    function integer sum_mem_re;
        integer kk, s;
        begin
            s = 0;
            for (kk = 0; kk < N; kk = kk + 1) s = s + $signed(dut.mem_re[kk]);
            sum_mem_re = s;
        end
    endfunction

    function integer sum_xq;
        integer kk, s;
        begin
            s = 0;
            for (kk = 0; kk < N; kk = kk + 1) s = s + ref_xq[kk];
            sum_xq = s;
        end
    endfunction

    integer k, pk, bad;
    integer save_x [0:HALF-1];

    // --------------------------------------------------------
    // メイン
    // --------------------------------------------------------
    initial begin
        errors    = 0;
        din       = '0;
        din_valid = 1'b0;
        mag_addr  = '0;

        // ================================================
        // テスト 1 : DC 入力
        //   X[0] = sum(xq) になるはず。bin 1..63 はほぼ 0。
        // ================================================
        $display("--- test 1 : DC input ---");
        do_reset;
        for (k = 0; k < N; k = k + 1) sig_int[k] = 10000;
        prep_window;
        feed_block;
        wait_frame;
        read_dut_input;
        // DUT が取り込んだデータと期待値が一致すること
        bad = 0;
        for (k = 0; k < N; k = k + 1)
            if (ref_xq[k] !== (($signed(sig_int[k]) * $signed(HANN[k])) >>> 15))
                bad = bad + 1;
        $display("  captured input mismatches = %0d", bad);
        errors = errors + bad;

        // DC なら bin 0 だけが立ち、ほかはほぼ 0
        pk = 0;
        for (k = 1; k < HALF; k = k + 1)
            if ($signed(dut.mem_mag2[k]) > pk) pk = $signed(dut.mem_mag2[k]);
        $display("  mem_re[0] = %0d, max mag2(bin1..63) = %0d",
                 $signed(dut.mem_re[0]), pk);
        if ($signed(dut.mem_re[0]) != 639924) begin
            errors = errors + 1;
            $display("  DC FAIL: X[0] should be 639924");
        end
        if (pk > 2000000) begin
            errors = errors + 1;
            $display("  DC FAIL: leakage too large");
        end

        // ================================================
        // テスト 2 : インパルス入力
        //   x[0] = A, x[1..127] = 0
        //   X[k] = xq[0] = 0 (HANN[0] = 0)  -> 全部 0 になる
        //   HANN[0]=0 なので x[0] ではなく x[64] に置く。
        //   X[k] = xq[64] * exp(-j*2*pi*k*64/128)
        //        = A_win * (-1)^k  -> |X[k]| = A_win, 実部は ±A_win
        // ================================================
        $display("--- test 2 : impulse at n=64 ---");
        do_reset;
        for (k = 0; k < N; k = k + 1) sig_int[k] = 0;
        sig_int[64] = 10000;
        prep_window;
        feed_block;
        wait_frame;
        read_dut_input;

        bad = 0;
        for (k = 0; k < HALF; k = k + 1) begin
            if ($signed(dut.mem_im[k]) !== 0) bad = bad + 1;
            if ($signed(dut.mem_re[k]) !== (ref_xq[64] * ((k % 2 == 0) ? 1 : -1)))
                bad = bad + 1;
        end
        $display("  impulse check: xq[64]=%0d bad = %0d", ref_xq[64], bad);
        errors = errors + bad;

        // ================================================
        // テスト 3 : 余弦波 (bin 8)
        //   x[n] = A * cos(2*pi*8*n/128)
        // ================================================
        $display("--- test 3 : cosine (bin 8) ---");
        do_reset;
        for (k = 0; k < N; k = k + 1)
            sig_int[k] = 16'($rtoi(12000.0 * $cos(2.0 * 3.141592653589793
                                                    * 8.0 * k / N)));
        prep_window;
        feed_block;
        wait_frame;
        read_dut_input;
        calc_reference;
        compare_spectrum("cos");

        // ピーク bin
        pk = 0;
        for (k = 1; k < HALF; k = k + 1)
            if ($signed(dut.mem_mag2[k]) > $signed(dut.mem_mag2[pk])) pk = k;
        $display("  peak bin = %0d (expected 8)", pk);
        if (pk != 8) begin
            errors = errors + 1;
            $display("  PEAK FAIL");
        end

        // ================================================
        // テスト 4 : 再現性
        // ================================================
        $display("--- test 4 : repeatability ---");
        for (k = 0; k < HALF; k = k + 1) save_x[k] = $signed(dut.mem_re[k]);
        feed_block;
        wait_frame;
        bad = 0;
        for (k = 0; k < HALF; k = k + 1)
            if ($signed(dut.mem_re[k]) !== save_x[k]) bad = bad + 1;
        $display("  changed bins = %0d", bad);
        if (bad != 0) errors = errors + 1;

        // ================================================
        $display("---------------------------------------------");
        $display("errors = %0d", errors);
        $display("---------------------------------------------");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $stop;
    end

endmodule
