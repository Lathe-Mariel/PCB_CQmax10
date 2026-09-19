// ============================================================
// tb_spectrum.sv
//   spectrum.sv のテストベンチ
//
//   検証内容:
//     1. 起動直後は bar_ram が全て 0 であること
//     2. frame_done を 1 回入れると全 64 bin が読み出されること
//     3. 単一ビンに大きな値を入れたとき、そのビンのバーだけが
//        高くなること (log2 圧縮の単調性)
//     4. 値が減ったときに減衰 (DECAY) がかかること
//
//   mag2 ポートは fft128 と同じく 1 クロック遅れのレジスタ出力を
//   模擬する。
// ============================================================

`timescale 1ns / 1ps

`include "fft_tables.svh"

module tb_spectrum;

    localparam int N_BINS  = 64;
    localparam int MAX_VAL = 239;

    // --------------------------------------------------------
    // DUT のパラメータ
    //   LOG_MUL / LOG_SH は top.sv と同じ値にする (ゲイン 33/16)。
    //   DECAY は機構の検証のために 2 のままにする。
    // --------------------------------------------------------
    localparam int START_BIN = 1;
    localparam int LOG_MIN   = 128;
    localparam int LOG_MUL   = 33;   // top.sv と同じ (従来 11 の 3 倍)
    localparam int LOG_SH    = 4;
    localparam int DECAY     = 2;
    localparam int SIG_TH    = 1024; // これ未満の mag2 は無音とみなす
    localparam int BAR_LIFE  = 10;   // テスト用に短くする
    //   一括消去がビンごとの保持より先に起きないよう BAR_LIFE より大きくする
    //   (top.sv の SP_SIL_FRAMES と同じ関係)
    localparam int SIL_FRAMES = BAR_LIFE + 4;

    // 1 octave (= 2 倍) あたりのバーの伸び (px)
    localparam int GAIN_PX = (16 * LOG_MUL) >> LOG_SH;   // 33

    logic        clk   = 1'b0;
    logic        rst_n = 1'b0;

    logic [6:0]  mag_addr;
    logic [33:0] mag2;
    logic        frame_done;

    logic [5:0]  bar_addr;
    logic [7:0]  bar_data;
    logic        busy;
    logic        bar_fresh;

    // ---- mag2 RAM (fft128 の mem_mag2 を模擬) ----
    logic [33:0] mem_mag2 [0:N_BINS-1];

    always #5 clk = ~clk;

    // fft128 と同じく 1 クロック遅れの読み出し
    always_ff @(posedge clk) mag2 <= mem_mag2[mag_addr];

    spectrum #(
        .N_BINS    (N_BINS),
        .START_BIN (START_BIN),
        .MAX_VAL   (MAX_VAL),
        .LOG_MIN   (LOG_MIN),
        .LOG_MUL   (LOG_MUL),
        .LOG_SH    (LOG_SH),
        .DECAY     (DECAY),
        .SIG_TH    (SIG_TH),
        .BAR_LIFE  (BAR_LIFE),
        .SIL_FRAMES (SIL_FRAMES)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .mag_addr   (mag_addr),
        .mag2       (mag2),
        .frame_done (frame_done),
        .bar_addr   (bar_addr),
        .bar_data   (bar_data),
        .busy       (busy),
        .bar_fresh  (bar_fresh)
    );

    integer errors = 0;

    // --------------------------------------------------------
    // 期待値 : q4 を求めて高さへ写像する (RTL と同じ計算)
    // --------------------------------------------------------
    function automatic [7:0] expect_height(input [33:0] m2);
        integer ex;
        integer mant;
        integer q4;
        integer rel;
        integer gain;
        begin
            ex   = 0;
            mant = 0;
            for (ex = 33; ex >= 0; ex = ex - 1)
                if (m2[ex]) begin
                    if (ex >= 7) mant = (m2 >> (ex - 6)) & 7'h7F;
                    else         mant = (m2 << (6 - ex)) & 7'h7F;
                    q4 = ex * 16 + LOG2_LUT[mant];
                    rel = (q4 > LOG_MIN) ? (q4 - LOG_MIN) : 0;
                    gain = (rel * LOG_MUL) >> LOG_SH;
                    if (gain > MAX_VAL) gain = MAX_VAL;
                    expect_height = gain[7:0];
                    ex = -1;          // ループを抜ける
                end
            if (m2 == 0) expect_height = 8'd0;
        end
    endfunction

    // --------------------------------------------------------
    // bar_ram を LCD と同じ手順で読む
    // --------------------------------------------------------
    task read_bars;
        integer k;
        begin
            for (k = 0; k < N_BINS; k = k + 1) begin
                @(negedge clk);
                bar_addr = k[5:0];
            end
        end
    endtask

    // --------------------------------------------------------
    // 1 フレーム分の変換を流す
    // --------------------------------------------------------
    task run_frame;
        begin
            @(negedge clk);
            frame_done = 1'b1;
            @(negedge clk);
            frame_done = 1'b0;
            // busy が下がるまで待つ
            wait (busy == 1'b0);
            @(negedge clk);
        end
    endtask

    // --------------------------------------------------------
    // 全 bin のバー高さを検証
    //   START_BIN より下の bin はクリアされた 0 のまま。
    // --------------------------------------------------------
    task check_all(input [8*16-1:0] tag);
        integer k;
        integer bad;
        integer exp_h;
        begin
            bad = 0;
            for (k = 0; k < N_BINS; k = k + 1) begin
                exp_h = (k < START_BIN) ? 0 : expect_height(mem_mag2[k]);
                if (dut.bar_ram[k] !== exp_h[7:0]) begin
                    bad = bad + 1;
                    if (bad < 8)
                        $display("  %0s bin %0d : dut=%0d expect=%0d (m2=%0d)",
                                 tag, k, dut.bar_ram[k], exp_h, mem_mag2[k]);
                end
            end
            $display("  [%0s] bar mismatches = %0d", tag, bad);
            errors = errors + bad;
        end
    endtask

    integer k;

    initial begin
        $display("=== tb_spectrum ===");

        rst_n      = 1'b0;
        frame_done = 1'b0;
        bar_addr   = '0;
        for (k = 0; k < N_BINS; k = k + 1) mem_mag2[k] = '0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;

        // ---- テスト 1 : クリア確認 ----
        $display("--- test 1 : clear ---");
        wait (busy == 1'b0);
        @(negedge clk);
        begin
            integer bad;
            bad = 0;
            for (k = 0; k < N_BINS; k = k + 1)
                if (dut.bar_ram[k] !== 8'd0) bad = bad + 1;
            $display("  non-zero bars after reset = %0d", bad);
            errors = errors + bad;
        end

        // ---- テスト 2 : 全て 0 のまま ----
        $display("--- test 2 : all zeros ---");
        run_frame;
        check_all("zero");

        // ---- テスト 3 : 単一ビン ----
        $display("--- test 3 : single bin (bin 10) ---");
        for (k = 0; k < N_BINS; k = k + 1) mem_mag2[k] = '0;
        mem_mag2[10] = 34'd4_000_000;
        run_frame;
        check_all("one");
        $display("  bar[10] = %0d (should be non-zero)", dut.bar_ram[10]);
        if (dut.bar_ram[10] == 8'd0) begin
            errors = errors + 1;
            $display("  FAIL: bin 10 should be non-zero");
        end

        // ---- テスト 4 : 対数圧縮の線形性 ----
        //   2 の冪 (1 octave ずつ) を入れると q4 はちょうど 16 ずつ増え、
        //   バーは GAIN_PX px ずつ伸びるはず。
        //   mag2[k] = 2^(k+9) -> q4 = (k+9)*16 -> height = (k+1)*GAIN_PX
        //   (bin 0 は START_BIN=1 で除外されるので常に 0)
        $display("--- test 4 : log compression (1 octave = %0d px) ---", GAIN_PX);
        for (k = 0; k < N_BINS; k = k + 1) mem_mag2[k] = '0;
        for (k = 0; k < 7; k = k + 1)
            mem_mag2[k] = 34'd1 << (k + 9);      // 512 .. 32768
        run_frame;
        for (k = 0; k < 7; k = k + 1) begin
            integer exp_h;
            exp_h = (k < START_BIN) ? 0 : ((k + 1) * GAIN_PX);
            $display("    mag2=%6d -> bar=%3d (expect %0d)",
                     mem_mag2[k], dut.bar_ram[k], exp_h);
            if (dut.bar_ram[k] !== exp_h[7:0]) begin
                errors = errors + 1;
                $display("    FAIL: bin %0d expected %0d", k, exp_h);
            end
        end

        // ---- テスト 5 : ビンごとの保持時間 (BAR_LIFE) ----
        //   信号がある間は表示が続き、信号が無くなると BAR_LIFE フレーム後に
        //   そのビンのバーだけが 0 になる。
        //   LCD 側のフレーム位相に依存しないことがポイント。
        //
        //   また BAR_LIFE が表示時間を決めていること
        //   (一括消去 SIL_FRAMES が先に効いていないこと) を確認する。
        $display("--- test 5 : per-bin hold time (BAR_LIFE=%0d, SIL_FRAMES=%0d) ---",
                 BAR_LIFE, SIL_FRAMES);
        for (k = 0; k < N_BINS; k = k + 1) mem_mag2[k] = 34'd10_000_000;
        run_frame;
        begin
            integer peak0;
            integer i;

            // ---- (a) 信号があり続ける限り消えないこと ----
            peak0 = dut.bar_ram[10];
            $display("  bar[10] with signal = %0d", peak0);
            if (peak0 == 8'd0) begin
                errors = errors + 1;
                $display("  FAIL: bar should be non-zero with signal");
            end

            for (i = 0; i < BAR_LIFE * 4; i = i + 1) run_frame;
            $display("  bar[10] after %0d frames WITH signal = %0d (expect %0d)",
                     BAR_LIFE * 4, dut.bar_ram[10], peak0);
            if (dut.bar_ram[10] !== peak0[7:0]) begin
                errors = errors + 1;
                $display("  FAIL: bar must stay while the signal is present");
            end

            // ---- (b) 信号が消えて BAR_LIFE-1 フレームではまだ見えること ----
            //        (BAR_LIFE が表示時間を決めている = SIL_FRAMES が
            //         先に全部消していないことの確認)
            for (k = 0; k < N_BINS; k = k + 1) mem_mag2[k] = '0;

            for (i = 0; i < (BAR_LIFE - 1); i = i + 1) run_frame;
            $display("  bar[10] after %0d silent frames = %0d (expect non-zero, BAR_LIFE=%0d)",
                     BAR_LIFE - 1, dut.bar_ram[10], BAR_LIFE);
            if (dut.bar_ram[10] === 8'd0) begin
                errors = errors + 1;
                $display("  FAIL: bar cleared before BAR_LIFE (SIL_FRAMES too small?)");
            end

            // ---- (c) BAR_LIFE を過ぎると 0 になること ----
            for (i = 0; i < 3; i = i + 1) run_frame;
            $display("  bar[10] after %0d silent frames = %0d (expect 0)",
                     BAR_LIFE + 2, dut.bar_ram[10]);
            if (dut.bar_ram[10] !== 8'd0) begin
                errors = errors + 1;
                $display("  FAIL: bar should be cleared after BAR_LIFE");
            end

            // 無音が続いている間は全 bin が 0 であること
            for (k = 0; k < N_BINS; k = k + 1)
                if (dut.bar_ram[k] !== 8'd0) begin
                    errors = errors + 1;
                    $display("  FAIL: bin %0d not cleared", k);
                    k = N_BINS;
                end
        end

        // ---- テスト 6 : bar_fresh パルス ----
        //   変換を 1 フレーム流すと bar_fresh が 1 回出ること。
        $display("--- test 6 : bar_fresh pulse ---");
        for (k = 0; k < N_BINS; k = k + 1) mem_mag2[k] = 34'd1_000_000;
        begin
            integer pulses;
            pulses = 0;
            @(negedge clk);
            frame_done = 1'b1;
            @(negedge clk);
            frame_done = 1'b0;
            // 変換が終わるまで見張る
            while (busy == 1'b1) begin
                @(negedge clk);
                if (bar_fresh) pulses = pulses + 1;
            end
            @(negedge clk);
            if (bar_fresh) pulses = pulses + 1;
            $display("  bar_fresh pulses = %0d (expect 1)", pulses);
            if (pulses != 1) begin
                errors = errors + 1;
                $display("  FAIL: bar_fresh should pulse once per frame");
            end
        end

        // ---- テスト 7 : bar_data のレイテンシ ----
        $display("--- test 7 : read port ---");
        bar_addr = 6'd10;
        @(negedge clk);
        @(negedge clk);
        @(negedge clk);
        $display("  bar_data[10] = %0d", bar_data);
        if (bar_data !== dut.bar_ram[10]) begin
            errors = errors + 1;
            $display("  FAIL: read port mismatch");
        end

        $display("---------------------------------------------");
        $display("errors = %0d", errors);
        $display("---------------------------------------------");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $stop;
    end

endmodule
