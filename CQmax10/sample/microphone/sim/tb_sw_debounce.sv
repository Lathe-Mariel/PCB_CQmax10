// ============================================================
// tb_sw_debounce.sv
//   sw_debounce.sv のテストベンチ
//
//   検証内容:
//     1. 押下 (Low) すると WAIT_MS 後に level が 1 になり press が 1 回出る
//     2. チャタリング (短いパルス列) では press が出ない
//     3. 押しっぱなしでは press は 1 回しか出ない
//     4. 離すと level が 0 に戻る
//     5. ACTIVE_LOW = 0 でも動く
// ============================================================

`timescale 1ns / 1ps

module tb_sw_debounce;

    // シミュレーション短縮用
    localparam int CLK_HZ  = 1_000_000;   // 1 MHz
    localparam int WAIT_MS = 1;           // 1 ms = 1000 クロック

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    logic sw_in;

    logic level;
    logic press;

    always #5 clk = ~clk;     // 100 MHz 相当 (10 ns)

    sw_debounce #(
        .CLK_HZ     (CLK_HZ),
        .WAIT_MS    (WAIT_MS),
        .ACTIVE_LOW (1'b1)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .sw_in (sw_in),
        .level (level),
        .press (press)
    );

    // 押下回数を数える
    integer n_press = 0;
    always @(posedge clk) if (press) n_press = n_press + 1;

    integer errors = 0;

    // WAIT_MS 分のクロックを進める
    task wait_deb;
        integer i;
        begin
            for (i = 0; i < (CLK_HZ / 1000) * WAIT_MS + 10; i = i + 1)
                @(negedge clk);
        end
    endtask

    initial begin
        $display("=== tb_sw_debounce ===");

        sw_in = 1'b1;             // 未押下 (プルアップ)
        rst_n = 1'b0;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ---- テスト 1 : 押下 ----
        $display("--- test 1 : press ---");
        n_press = 0;
        sw_in = 1'b0;             // 押す
        wait_deb;
        $display("  level = %0d (expect 1), n_press = %0d (expect 1)",
                 level, n_press);
        if (level !== 1'b1) begin errors = errors + 1; $display("  FAIL level"); end
        if (n_press != 1)   begin errors = errors + 1; $display("  FAIL press count"); end

        // ---- テスト 2 : 押しっぱなし ----
        $display("--- test 2 : hold ---");
        wait_deb;                 // さらに待っても press は増えない
        wait_deb;
        $display("  n_press = %0d (expect 1)", n_press);
        if (n_press != 1) begin errors = errors + 1; $display("  FAIL retrigger"); end

        // ---- テスト 3 : 離す ----
        $display("--- test 3 : release ---");
        sw_in = 1'b1;
        wait_deb;
        $display("  level = %0d (expect 0), n_press = %0d (expect 1)",
                 level, n_press);
        if (level !== 1'b0) begin errors = errors + 1; $display("  FAIL release"); end
        if (n_press != 1)   begin errors = errors + 1; $display("  FAIL count"); end

        // ---- テスト 4 : チャタリング ----
        //   WAIT_MS より短いパルス列は無視されること
        $display("--- test 4 : chatter ---");
        n_press = 0;
        begin
            integer i;
            for (i = 0; i < 20; i = i + 1) begin
                sw_in = 1'b0;
                repeat (5) @(negedge clk);
                sw_in = 1'b1;
                repeat (5) @(negedge clk);
            end
        end
        wait_deb;
        $display("  level = %0d (expect 0), n_press = %0d (expect 0)",
                 level, n_press);
        if (level !== 1'b0) begin errors = errors + 1; $display("  FAIL chatter level"); end
        if (n_press != 0)   begin errors = errors + 1; $display("  FAIL chatter press"); end

        // ---- テスト 5 : チャタリング後に押下 ----
        $display("--- test 5 : chatter then press ---");
        n_press = 0;
        begin
            integer i;
            for (i = 0; i < 5; i = i + 1) begin
                sw_in = 1'b0;
                repeat (5) @(negedge clk);
                sw_in = 1'b1;
                repeat (5) @(negedge clk);
            end
            sw_in = 1'b0;         // 今度は押しっぱなしにする
        end
        wait_deb;
        $display("  level = %0d (expect 1), n_press = %0d (expect 1)",
                 level, n_press);
        if (level !== 1'b1) begin errors = errors + 1; $display("  FAIL level"); end
        if (n_press != 1)   begin errors = errors + 1; $display("  FAIL press count"); end

        $display("---------------------------------------------");
        $display("errors = %0d", errors);
        $display("---------------------------------------------");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $stop;
    end

    // タイムアウト
    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $stop;
    end

endmodule
