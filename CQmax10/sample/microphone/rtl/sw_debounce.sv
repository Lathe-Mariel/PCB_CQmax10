// ============================================================
// sw_debounce.sv
//   タクトスイッチ用の同期化 + チャタリング除去 + 押下検出
//
//   動作:
//     1. 非同期のスイッチ入力を 2 段 FF で同期化
//     2. WAIT_MS の間レベルが変わらなかったら確定 (チャタリング除去)
//     3. 確定レベルが「押下」になった瞬間に press を 1 クロック出力
//
//   ACTIVE_LOW = 1 の場合、押下 = Low (プルアップ + GND へ落とす配線)。
//   基板の配線が逆の場合は ACTIVE_LOW を 0 にすること。
//
//   押下判定は「確定レベルの立ち上がりエッジ」で行うので、
//   押しっぱなしでも press は 1 回しか出ない。
// ============================================================

module sw_debounce #(
    parameter int  CLK_HZ     = 50_000_000,
    parameter int  WAIT_MS    = 10,      // チャタリング除去時間 (ms)
    parameter bit  ACTIVE_LOW = 1'b1     // 押下 = Low
) (
    input  logic clk,
    input  logic rst_n,

    input  logic sw_in,        // 生のスイッチ入力 (非同期)

    output logic level,        // 確定レベル (押下 = 1)
    output logic press         // 押下した瞬間に 1 クロックパルス
);

    // チャタリング除去に必要なクロック数 (500,000 @ 50 MHz / 10 ms)
    localparam int CNT_MAX = (CLK_HZ / 1000) * WAIT_MS;

    localparam logic [23:0] CNT_TOP = CNT_MAX[23:0];

    logic [1:0]  sync_r;
    logic [23:0] cnt;
    logic        stable;
    logic        stable_d;

    // 生の入力 (押下 = 1 に正規化)
    wire raw = ACTIVE_LOW ? ~sync_r[1] : sync_r[1];

    // --- 2 段同期化 ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync_r <= 2'b00;
        else        sync_r <= {sync_r[0], sw_in};
    end

    // --- チャタリング除去 + エッジ検出 ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt      <= '0;
            stable   <= 1'b0;
            stable_d <= 1'b0;
        end else begin
            stable_d <= stable;

            if (raw == stable) begin
                // 変化なし -> カウンタをリセット
                cnt <= '0;
            end else if (cnt == CNT_TOP) begin
                // WAIT_MS の間同じレベルだった -> 確定
                cnt    <= '0;
                stable <= raw;
            end else begin
                cnt <= cnt + 24'd1;
            end
        end
    end

    assign level = stable;
    assign press = stable & ~stable_d;

endmodule
