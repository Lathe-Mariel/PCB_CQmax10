// ============================================================
// tb_top_sw.sv
//   top.sv のタクトスイッチ -> tb_sel のパスを実機と同じ形で検証する
//
//   top を丸ごとインスタンス化し、sw_inc / sw_dec を実際に
//   押下パターンで駆動して tb_sel が変化することを確認する。
//   LCD の初期化待ちは並行して進むので無視してよい
//   (tb_sel のロジックは LCD に依存しない)。
//
//   検証内容:
//     1. リセット直後に不正な press が出ないこと
//     2. sw_inc (PIN_62) の押下で tb_sel が上がること
//     3. sw_dec (PIN_54) の押下で tb_sel が下がること
//     4. 上限 / 下限でクランプされること
//     5. 押しっぱなしで 1 回しか変化しないこと
// ============================================================

`timescale 1ns / 1ps

module tb_top_sw;

    // シミュレーションを短時間で終わらせるためクロックを落とす。
    //   デバウンスのクロック数は CLK_HZ * WAIT_MS / 1000 なので、
    //   CLK_HZ を下げると同じ ms 数でも必要なサイクル数が減る。
    //   tb_sel のロジックは LCD に依存しないので問題ない。
    localparam int TB_CLK_HZ  = 20_000_000;   // シミュレーション用の周波数表記
    localparam int TB_CLK_PD  = 25;           // 半周期 (ns) = 20 MHz
    localparam int TB_WAIT_MS = 1;            // チャタリング除去 1 ms

    logic clk = 1'b0;
    always #TB_CLK_PD clk = ~clk;

    localparam int MS = TB_CLK_HZ / 1000;     // 1 ms = 20000 クロック

    logic btn_rst;
    logic sw_inc;
    logic sw_dec;

    logic mic_sck, mic_ws, mic_sd;
    logic lcd_cs, lcd_dc, lcd_mosi, lcd_sck;
    logic led, led0, led1, led2, led3;

    top #(
        .CLK_HZ     (TB_CLK_HZ),
        .SW_WAIT_MS (TB_WAIT_MS)
    ) dut (
        .clk      (clk),
        .btn_rst  (btn_rst),
        .sw_inc   (sw_inc),
        .sw_dec   (sw_dec),
        .mic_sck  (mic_sck),
        .mic_ws   (mic_ws),
        .mic_sd   (mic_sd),
        .lcd_cs   (lcd_cs),
        .lcd_dc   (lcd_dc),
        .lcd_mosi (lcd_mosi),
        .lcd_sck  (lcd_sck),
        .led      (led),
        .led0     (led0),
        .led1     (led1),
        .led2     (led2),
        .led3     (led3)
    );

    integer errors = 0;

    // press パルスを数える
    integer n_inc = 0;
    integer n_dec = 0;
    always @(posedge clk) begin
        if (dut.swi_press) n_inc = n_inc + 1;
        if (dut.swd_press) n_dec = n_dec + 1;
    end

    task wait_ms(input integer n);
        integer i;
        begin
            for (i = 0; i < MS * n; i = i + 1) @(negedge clk);
        end
    endtask

    // スイッチを押して離す (押下 = Low)
    //   デバウンスが TB_WAIT_MS なので、それより少し長く押す
    task press_inc;
        begin
            @(negedge clk);
            sw_inc = 1'b0;
            wait_ms(TB_WAIT_MS + 3);
            @(negedge clk);
            sw_inc = 1'b1;
            wait_ms(1);
        end
    endtask

    task press_dec;
        begin
            @(negedge clk);
            sw_dec = 1'b0;
            wait_ms(TB_WAIT_MS + 3);
            @(negedge clk);
            sw_dec = 1'b1;
            wait_ms(1);
        end
    endtask

    integer saved;

    initial begin
        $display("=== tb_top_sw ===");

        btn_rst = 1'b0;      // 押下 (Low) = リセット
        sw_inc  = 1'b1;      // 未押下 (プルアップ)
        sw_dec  = 1'b1;
        mic_sd  = 1'b0;

        wait_ms(5);
        btn_rst = 1'b1;      // 離す
        wait_ms(5);          // por_cnt が満了するまで待つ

        // ---- テスト 1 : リセット直後 ----
        $display("--- test 1 : after reset ---");
        $display("  tb_sel = %0d, n_inc = %0d, n_dec = %0d",
                 dut.tb_sel, n_inc, n_dec);
        if (n_inc != 0 || n_dec != 0) begin
            errors = errors + 1;
            $display("  FAIL: spurious press at power-on");
        end

        // ---- テスト 2 : sw_inc で上がる ----
        $display("--- test 2 : sw_inc (PIN_62) up ---");
        press_inc;
        $display("  tb_sel = %0d (expect 1), n_inc = %0d", dut.tb_sel, n_inc);
        if (dut.tb_sel !== 3'd1) begin
            errors = errors + 1;
            $display("  FAIL: tb_sel should be 1");
        end

        // ---- テスト 3 : sw_dec で下がる ----
        $display("--- test 3 : sw_dec (PIN_54) down ---");
        press_dec;
        $display("  tb_sel = %0d (expect 0), n_dec = %0d", dut.tb_sel, n_dec);
        if (dut.tb_sel !== 3'd0) begin
            errors = errors + 1;
            $display("  FAIL: tb_sel should be 0 (sw_dec did not work)");
        end

        // ---- テスト 4 : 下限クランプ ----
        $display("--- test 4 : lower clamp ---");
        press_dec;
        press_dec;
        $display("  tb_sel = %0d (expect 0)", dut.tb_sel);
        if (dut.tb_sel !== 3'd0) begin
            errors = errors + 1;
            $display("  FAIL: tb_sel should stay 0");
        end

        // ---- テスト 5 : 上限クランプ ----
        $display("--- test 5 : upper clamp ---");
        begin
            integer i;
            for (i = 0; i < 4; i = i + 1) press_inc;   // 0 -> 3 -> clamp
        end
        $display("  tb_sel = %0d (expect 3)", dut.tb_sel);
        if (dut.tb_sel !== 3'd3) begin
            errors = errors + 1;
            $display("  FAIL: tb_sel should clamp at 3");
        end

        // ---- テスト 6 : 押しっぱなしで 1 回だけ ----
        $display("--- test 6 : hold ---");
        saved = n_inc;
        @(negedge clk);
        sw_inc = 1'b0;
        wait_ms(TB_WAIT_MS + 4);   // ずっと押しっぱなし
        @(negedge clk);
        sw_inc = 1'b1;
        wait_ms(1);
        $display("  extra presses = %0d (expect 1)", n_inc - saved);
        if ((n_inc - saved) != 1) begin
            errors = errors + 1;
            $display("  FAIL: hold should give exactly 1 press");
        end

        $display("---------------------------------------------");
        $display("errors = %0d", errors);
        $display("---------------------------------------------");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $stop;
    end

    initial begin
        // テストは約 55 ms で完了して $stop する。
        // ここは完了しなかった場合のガード (十分に長くとる)。
        #500_000_000;
        $display("TIMEOUT");
        $stop;
    end

endmodule
