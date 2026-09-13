// ============================================================
// tb_moving_avg.sv
//   moving_avg のシミュレーション用テストベンチ
//
//   検証内容:
//     1. N サンプル分そろった後、出力が窓内の平均値になること
//     2. 一定値を入力し続けると、出力がその値に収束すること
//     3. 直流成分が正しく通ること (符号付き演算の確認)
//     4. インパルス応答が N サンプルで消えること (FIR として正しい)
//     5. ランダムノイズを加えた正弦波でノイズが減衰すること
//
//   実行方法 (ModelSim):
//     vlib work
//     vlog -sv ../rtl/moving_avg.sv tb_moving_avg.sv
//     vsim -c -do "run -all; quit -f" tb_moving_avg
// ============================================================

`timescale 1ns / 1ps

module tb_moving_avg;

    localparam integer N  = 8;
    localparam integer DW = 16;

    logic clk = 1'b0;
    always #10 clk = ~clk;      // 50 MHz

    logic rst_n;
    logic               valid_in;
    logic signed [DW-1:0] data_in;
    logic signed [DW-1:0] data_out;
    logic               valid_out;

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------
    moving_avg #(
        .N  (N),
        .DW (DW)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .data_in   (data_in),
        .data_out  (data_out),
        .valid_out (valid_out)
    );

    // --------------------------------------------------------
    // 参照モデル (ソフトウェアで同じ計算をする)
    // --------------------------------------------------------
    logic signed [DW-1:0] ref_hist [0:N-1];
    integer ref_wp;
    integer ref_sum;
    integer ref_out;

    integer errors;

    task ref_push(input integer v);
        begin
            ref_sum  = ref_sum - ref_hist[ref_wp] + v;
            ref_hist[ref_wp] = v[DW-1:0];
            ref_wp   = (ref_wp + 1) % N;
            // 算術シフト相当: 整数除算では負数が 0 方向へ丸まるため
            // 床方向へ丸める
            if (ref_sum >= 0) ref_out = ref_sum / N;
            else              ref_out = -(((-ref_sum) + N - 1) / N);
        end
    endtask

    // DUT と同じ値を返すか確認
    //   注意1: @(posedge clk) の直後はノンブロッキング代入がまだ反映されて
    //          いないため、わずかに待ってから比較する
    //   注意2: data_in の設定もこのタスク内で行う (呼び忘れ防止)
    task check(input integer v, input integer tag);
        begin
            data_in  = v[DW-1:0];
            valid_in = 1'b1;
            ref_push(v);
            @(posedge clk);
            #1;                        // NBA 反映待ち (1ns)
            if (valid_out !== 1'b1) begin
                errors = errors + 1;
                $display("no valid_out (tag=%0d)", tag);
            end
            if ($signed(data_out) !== ref_out) begin
                errors = errors + 1;
                if (errors < 15)
                    $display("MISMATCH tag=%0d in=%0d dut=%0d ref=%0d",
                             tag, v, $signed(data_out), ref_out);
            end
        end
    endtask

    // --------------------------------------------------------
    // テスト本体
    // --------------------------------------------------------
    integer i;
    integer v;
    integer noise;
    integer seed;
    integer diff;
    reg signed [DW-1:0] clean_sig;

    // テスト4 用: クリーン信号のみをフィルタした結果と比較する
    integer in_arr    [0:511];
    integer cln_arr   [0:511];
    integer dut_out   [0:511];
    integer clean_out [0:511];
    integer a_hist    [0:N-1];
    integer a_wp, a_sum, a_out;
    real    energy_in, energy_out;

    initial begin
        errors   = 0;
        valid_in = 1'b0;
        data_in  = '0;
        rst_n    = 1'b0;

        for (i = 0; i < N; i = i + 1) ref_hist[i] = '0;
        ref_wp  = 0;
        ref_sum = 0;
        ref_out = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ================================================
        // テスト1: 決め打ちの入力列で参照モデルと一致するか
        // ================================================
        $display("--- test 1: reference model match ---");
        for (i = 0; i < 200; i = i + 1) begin
            v = (i * 137) % 20000 - 10000;    // -10000 .. +9999
            check(v, i);
        end

        // ================================================
        // テスト2: 一定値 -> 出力が収束すること
        // ================================================
        $display("--- test 2: DC convergence ---");
        for (i = 0; i < 3 * N; i = i + 1)
            check(5000, 1000 + i);
        if ($signed(data_out) !== 5000) begin
            errors = errors + 1;
            $display("DC settle failed: %0d (expected 5000)", $signed(data_out));
        end else begin
            $display("  DC value 5000 settled correctly");
        end

        // 負の直流
        for (i = 0; i < 3 * N; i = i + 1)
            check(-3000, 2000 + i);
        if ($signed(data_out) !== -3000) begin
            errors = errors + 1;
            $display("DC settle failed: %0d (expected -3000)", $signed(data_out));
        end else begin
            $display("  DC value -3000 settled correctly");
        end

        // ================================================
        // テスト3: インパルス応答 (N サンプルで消える)
        // ================================================
        $display("--- test 3: impulse response ---");
        for (i = 0; i < 2 * N; i = i + 1) check(0, 3000 + i);
        check(8000, 3100);                       // インパルス
        // 窓から完全に押し出すには N 個の 0 が必要
        for (i = 0; i < N; i = i + 1)
            check(0, 3100 + i);
        if ($signed(data_out) !== 0) begin
            errors = errors + 1;
            $display("impulse did not clear: %0d", $signed(data_out));
        end else begin
            $display("  impulse cleared after N samples");
        end

        // ================================================
        // テスト4: ノイズ減衰の確認
        //   移動平均は線形フィルタなので
        //     filter(信号 + ノイズ) - filter(信号) = filter(ノイズ)
        //   が成り立つ。これを使ってノイズ成分だけを取り出し、
        //   入力と出力のノイズエネルギーを比較する。
        // ================================================
        $display("--- test 4: noise attenuation ---");
        for (i = 0; i < 4 * N; i = i + 1) check(0, 4000 + i);

        seed = 12345;

        // ---- テストパターン生成 ----
        for (i = 0; i < 512; i = i + 1) begin
            // 直流 0 の三角波 (正弦波の整数近似)
            if ((i % 16) < 8) cln_arr[i] = (i % 8) * 500 - 2000;
            else              cln_arr[i] = (7 - (i % 8)) * 500 - 2000;

            // ランダムノイズ (線形合同法)
            seed  = (seed * 1103515245 + 12345) & 32'h7FFFFFFF;
            noise = (seed % 4001) - 2000;   // -2000 .. +2000

            v = cln_arr[i] + noise;
            if (v > 32767)  v = 32767;
            if (v < -32768) v = -32768;
            in_arr[i] = v;
        end

        // ---- パスA: クリーン信号のみをソフトウェアでフィルタ ----
        a_wp  = 0;
        a_sum = 0;
        a_out = 0;
        for (i = 0; i < N; i = i + 1) a_hist[i] = 0;

        for (i = 0; i < 512; i = i + 1) begin
            a_sum = a_sum - a_hist[a_wp] + cln_arr[i];
            a_hist[a_wp] = cln_arr[i];
            a_wp  = (a_wp + 1) % N;
            if (a_sum >= 0) a_out = a_sum / N;
            else            a_out = -(((-a_sum) + N - 1) / N);
            clean_out[i] = a_out;
        end

        // ---- パスB: DUT にクリーン + ノイズを入力 ----
        for (i = 0; i < 512; i = i + 1) begin
            data_in  = in_arr[i][DW-1:0];
            valid_in = 1'b1;
            ref_push(in_arr[i]);
            @(posedge clk);
            #1;
            dut_out[i] = $signed(data_out);
        end
        valid_in = 1'b0;

        // ---- ノイズエネルギーを比較 ----
        energy_in  = 0.0;
        energy_out = 0.0;
        for (i = 0; i < 512; i = i + 1) begin
            diff = in_arr[i] - cln_arr[i];
            energy_in  = energy_in  + (diff * diff);
            diff = dut_out[i] - clean_out[i];
            energy_out = energy_out + (diff * diff);
        end

        $display("  input  noise energy = %.0f", energy_in);
        $display("  output noise energy = %.0f (%.1f%%)",
                 energy_out, 100.0 * energy_out / energy_in);
        $display("  theoretical ratio for N=%0d: %.1f%%",
                 N, 100.0 / N);

        // 移動平均でノイズエネルギーは 1/N になるはず。
        // 余裕を見て 1/3 以下なら合格とする。
        if (energy_out * 3.0 >= energy_in) begin
            errors = errors + 1;
            $display("  noise NOT attenuated enough");
        end else begin
            $display("  noise attenuated correctly");
        end

        // ================================================
        // 結果
        // ================================================
        $display("---------------------------------------------");
        $display("errors = %0d", errors);
        $display("---------------------------------------------");

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end

endmodule
