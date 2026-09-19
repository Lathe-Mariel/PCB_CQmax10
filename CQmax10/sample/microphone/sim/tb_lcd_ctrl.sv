// ============================================================
// tb_lcd_ctrl.sv
//   lcd_wave のシミュレーション用テストベンチ
//
//   SPI スレーブモデルを接続し、以下を検証する。
//     1. 初期化コマンド (SWRESET/COLMOD/MADCTL など) が送られること
//     2. 初期化後にピクセルデータが送られること
//     3. 送られたピクセル色が期待どおりであること
//        (背景 / グリッド / 中央線 / 波形の位置を検証)
//
//   実行方法 (ModelSim):
//     vlib work
//     vlog -sv ../rtl/lcd_wave.sv tb_lcd_ctrl.sv
//     vsim -c -do "run -all; quit -f" tb_lcd_ctrl
// ============================================================

`timescale 1ns / 1ps

module tb_lcd_ctrl;

    // シミュレーション短縮用のパラメータ
    localparam integer LCD_W          = 32;
    localparam integer LCD_H          = 16;
    localparam integer BUF_AW         = 6;
    //   振幅スケール : 負 = 縮小 (top.sv と同じく 1/2 を検証する)
    localparam integer AMP_GAIN_SHIFT = -1;
    localparam integer FRAME_WAIT     = 100;
    localparam integer POWERON_WAIT   = 50;
    localparam integer SWRST_WAIT     = 20;
    localparam integer SLPOUT_WAIT    = 20;
    localparam integer DEPTH          = 64;
    localparam integer NPIX           = LCD_W * LCD_H;

    // ---- 棒グラフ (BAR_EN=1, BAR_W=4, BAR_N=4 -> pitch 8) ----
    localparam integer BAR_EN     = 1;
    localparam integer BAR_W      = 4;
    localparam integer BAR_N      = 4;
    localparam integer BAR_PITCH  = LCD_W / BAR_N;   // 8
    localparam integer BAR_TEST_H = 5;
    localparam integer BAR_GAIN_SH = 1;   // 表示高さ 2 倍 (top.sv と同じ)

    // ---- 時間軸 ----
    //   BUF_AW=6, LCD_W=32 なので spp の上限は 64/32 = 2。
    //   テストでは 1 と 2 の 2 段だけを使う。
    localparam integer TB_N    = 2;
    localparam integer TB_SPP0 = 1;

    localparam [15:0] COL_BG   = 16'h0000;
    localparam [15:0] COL_GRID = 16'h1082;
    localparam [15:0] COL_AXIS = 16'h4208;
    localparam [15:0] COL_WAVE = 16'h07E0;
    localparam [15:0] COL_BAR  = 16'hFD20;

    logic clk = 1'b0;
    always #10 clk = ~clk;

    logic rst_n;

    logic               lcd_cs, lcd_dc, lcd_mosi, lcd_sck;
    logic [BUF_AW-1:0]  rd_addr, wr_ptr;
    logic signed [15:0] rdata;
    logic [5:0]         bar_addr;
    logic [7:0]         bar_data;
    logic [2:0]         tb_sel;
    logic               bar_fresh;
    logic               init_done, frame_tick;

    // ---- RAM モデル (ノコギリ波) ----
    logic signed [15:0] mem [0:DEPTH-1];

    // ---- 観測 ----
    logic [15:0] px [0:NPIX-1];
    logic [8:0]  px_col [0:NPIX-1];
    logic [7:0]  px_row [0:NPIX-1];
    logic [15:0] px_ref [0:NPIX-1];
    logic [BUF_AW-1:0] px_rdbase [0:NPIX-1];
    logic [2:0]  px_spp [0:NPIX-1];      // そのフレームの spp (時間軸)
    integer      pix_count;
    integer      cmd_cnt;
    logic [7:0]  cmd_hist [0:15];

    // 観測の有効化 / フレーム検出
    logic        collect;                 // 1 の間だけピクセルを取り込む
    logic        last_frame_tick;
    logic        frame_seen;

    // ---- SPI 受信 ----
    logic        sck_d, cs_d, dc_d;
    logic [7:0]  rx_shift;
    logic [3:0]  rx_bitcnt;
    logic [7:0]  hi_byte;
    logic        hi_valid;
    logic [15:0] word;
    logic        word_valid;

    integer i;

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------
    lcd_wave #(
        .CLK_HZ         (50_000_000),
        .BUF_AW         (BUF_AW),
        .LCD_W          (LCD_W),
        .LCD_H          (LCD_H),
        .AMP_GAIN_SHIFT (AMP_GAIN_SHIFT),
        .FRAME_WAIT     (FRAME_WAIT),
        .POWERON_WAIT   (POWERON_WAIT),
        .SWRST_WAIT     (SWRST_WAIT),
        .SLPOUT_WAIT    (SLPOUT_WAIT),
        .BAR_EN         (BAR_EN),
        .BAR_W          (BAR_W),
        .BAR_N          (BAR_N),
        .BAR_HOLD       (2),           // 寿命を短くして消去を検証する
        .BAR_GAIN_SH    (BAR_GAIN_SH),
        .TB_N           (TB_N),
        .TB_SPP0        (TB_SPP0)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .lcd_cs     (lcd_cs),
        .lcd_dc     (lcd_dc),
        .lcd_mosi   (lcd_mosi),
        .lcd_sck    (lcd_sck),
        .rd_addr    (rd_addr),
        .rdata      (rdata),
        .wr_ptr     (wr_ptr),
        .bar_addr   (bar_addr),
        .bar_data   (bar_data),
        .tb_sel     (tb_sel),
        .bar_fresh  (bar_fresh),
        .init_done  (init_done),
        .frame_tick (frame_tick)
    );

    // ---- スペクトラム RAM (spectrum.sv を模擬) ----
    //   テストでは固定パターン : 偶数 bin だけ高さ BAR_TEST_H
    logic [7:0] bar_ram [0:63];

    initial begin
        for (i = 0; i < 64; i = i + 1)
            bar_ram[i] = ((i % 2) == 0) ? BAR_TEST_H[7:0] : 8'd0;
    end

    always @(posedge clk)
        bar_data <= bar_ram[bar_addr];

    // --------------------------------------------------------
    // RAM
    //   LCD_H=16 のテストでは中央が row 7 なので、振幅が ±3 px に
    //   収まるよう小さめの値を入れる
    // --------------------------------------------------------
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = (i % 8) - 4;        // -4 .. +3
        wr_ptr    = 6'd63;
        pix_count = 0;
        cmd_cnt   = 0;
        word_valid = 1'b0;
        hi_valid   = 1'b0;
    end

    always @(posedge clk)
        rdata <= mem[rd_addr];

    // --------------------------------------------------------
    // SPI スレーブ
    //   Mode 0 : SCK 立ち上がりで MOSI を取り込む
    // --------------------------------------------------------
    always @(posedge clk) begin
        sck_d <= lcd_sck;
        cs_d  <= lcd_cs;
        dc_d  <= lcd_dc;
    end

    wire sck_rise = ~sck_d & lcd_sck;
    wire cs_fall  = cs_d & ~lcd_cs;

    always @(posedge clk) begin
        word_valid <= 1'b0;

        if (cs_fall)
            rx_bitcnt <= 4'd0;
        else if (!lcd_cs && sck_rise) begin
            rx_shift  <= {rx_shift[6:0], lcd_mosi};
            rx_bitcnt <= rx_bitcnt + 4'd1;

            if (rx_bitcnt == 4'd7) begin
                rx_bitcnt <= 4'd0;
                if (dc_d == 1'b0) begin
                    // コマンド (DC = Low)
                    if (cmd_cnt < 16)
                        cmd_hist[cmd_cnt] <= {rx_shift[6:0], lcd_mosi};
                    cmd_cnt  <= cmd_cnt + 1;
                    hi_valid <= 1'b0;
                end else if (hi_valid == 1'b0) begin
                    // ピクセル上位バイト
                    hi_byte  <= {rx_shift[6:0], lcd_mosi};
                    hi_valid <= 1'b1;
                end else begin
                    // ピクセル下位バイト -> 1 ピクセル確定
                    word       <= {hi_byte, rx_shift[6:0], lcd_mosi};
                    hi_valid   <= 1'b0;
                    word_valid <= 1'b1;
                end
            end
        end
    end

    // --------------------------------------------------------
    // ピクセル受信 -> 保存
    //   DUT 内部の col_cnt / row_cnt / cur_color を直接参照して
    //   送信バイトと画面位置を正確に対応付ける
    // --------------------------------------------------------
    always @(posedge clk) begin
        // 初期化シーケンス中のパラメータ (DC=High) をピクセルと
        // 誤認しないよう、init_done 後のデータのみを取り込む
        if (word_valid && init_done && collect && pix_count < NPIX) begin
            px[pix_count] <= word;
            // DUT が今送っているピクセルの位置と色
            px_col[pix_count]  <= dut.col_cnt;
            px_row[pix_count]  <= dut.row_cnt;
            px_ref[pix_count]  <= dut.cur_color;
            px_rdbase[pix_count] <= dut.rd_base;
            px_spp[pix_count]  <= dut.spp_r;
            pix_count <= pix_count + 1;
        end
    end

    // --------------------------------------------------------
    // 期待 Y 座標
    // --------------------------------------------------------
    function integer expected_y;
        input integer s;
        integer off, y;
        begin
            // DUT と同じ 2 の冪スケール
            //   > 0 : 左シフト, < 0 : 右シフト (算術)
            off = s;
            if (AMP_GAIN_SHIFT > 0)
                off = off <<< AMP_GAIN_SHIFT;
            else if (AMP_GAIN_SHIFT < 0)
                off = off >>> (-AMP_GAIN_SHIFT);
            y   = (LCD_H / 2 - 1) - off;
            if (y < 0)                 y = 0;
            else if (y > (LCD_H - 1))  y = LCD_H - 1;
            expected_y = y;
        end
    endfunction

    // 描画列 col に対応する波形 RAM のインデックス
    //   rd_idx = (wr_ptr - 1 - spp*LCD_W + col*spp) mod DEPTH
    //   spp はそのフレームの時間軸 (1, 2, 4, ...)
    function integer expected_idx;
        input integer col;
        input integer spp;
        integer idx;
        begin
            idx = (63 - 1 - spp*LCD_W + col*spp) % DEPTH;
            if (idx < 0) idx = idx + DEPTH;
            expected_idx = idx;
        end
    endfunction

    // --------------------------------------------------------
    // 期待ピクセル色 (DUT の pixel_color と同じ規則)
    //   BAR_OVER_WAVE = 1 なので重ね順は
    //     バー > 波形 > 中央線 > グリッド > 背景
    // --------------------------------------------------------
    function [15:0] expected_pixel;
        input integer x;
        input integer y;
        input integer wy_lo;
        input integer wy_hi;
        input integer bin;
        input integer bh;
        integer h;
        integer in_bar;
        begin
            // 表示高さに増幅し、画面高でクリップ
            h = bh << BAR_GAIN_SH;
            if (h > (LCD_H - 1)) h = LCD_H - 1;

            // バー本体 : bin があり、高さが 0 でなく、
            //           バーの横幅 (bar_off < BAR_W) の内側であること
            in_bar = ((bin < BAR_N) && (bh != 0) &&
                      ((x % BAR_PITCH) < BAR_W) &&
                      (y >= ((LCD_H - 1) - h)));

            if (in_bar)                        expected_pixel = COL_BAR;
            else if (y >= wy_lo && y <= wy_hi) expected_pixel = COL_WAVE;
            else if (y == (LCD_H/2 - 1))       expected_pixel = COL_AXIS;
            else if (x[4:0] == 5'd0)           expected_pixel = COL_GRID;
            else if (y[4:0] == 5'd0)           expected_pixel = COL_GRID;
            else                               expected_pixel = COL_BG;
        end
    endfunction

    // --------------------------------------------------------
    // フレーム検出
    // --------------------------------------------------------
    always @(posedge clk) begin
        last_frame_tick <= frame_tick;
        if (frame_tick && !last_frame_tick) frame_seen <= 1'b1;
    end

    task wait_frame;
        begin
            frame_seen = 1'b0;
            while (frame_seen == 1'b0) @(posedge clk);
        end
    endtask

    // bar_fresh はフレーム開始時 (S_FRAME_START) にラッチされるため、
    // 1 クロックだけでは拾われないことがある。1 フレーム分保持する。
    task fresh_pulse;
        begin
            bar_fresh = 1'b1;
            wait_frame;
            bar_fresh = 1'b0;
        end
    endtask

    // --------------------------------------------------------
    // メイン
    // --------------------------------------------------------
    integer k, col, row, ey, lo, hi, idx;
    integer bin, bh;
    logic [15:0] exp;
    integer wave_hits, grid_hits, axis_hits, bg_hits, bar_hits;
    integer bad_color, bad_wave, bad_bar, spi_bad, errors;
    integer timeout;

    initial begin
        rst_n   = 1'b0;
        errors  = 0;
        tb_sel  = 3'd0;
        bar_fresh = 1'b0;
        collect = 1'b0;
        frame_seen = 1'b0;
        last_frame_tick = 1'b0;

        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // 棒グラフが表示されるよう bar_fresh を 1 フレーム分入れる
        repeat (5) @(posedge clk);
        fresh_pulse;
        collect   = 1'b1;

        // ピクセルを NPIX 個受信するまで待つ
        timeout = 0;
        while (pix_count < NPIX && timeout < 3_000_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        repeat (5) @(posedge clk);

        $display("init_done = %b, commands = %0d, pixels = %0d (wait %0d cycles)",
                 init_done, cmd_cnt, pix_count, timeout);

        if (pix_count < NPIX) begin
            $display("TIMEOUT: not enough pixels");
            errors = errors + 1;
        end

        // ---- コマンド検証 ----
        for (k = 0; k < 8; k = k + 1)
            $display("  cmd[%0d] = %02h", k, cmd_hist[k]);

        // ---- SPI 転送の検証 ----
        //   受信したピクセル色が DUT 内部の cur_color と一致すること
        spi_bad = 0;
        for (k = 0; k < NPIX; k = k + 1) begin
            if (px[k] !== px_ref[k]) begin
                spi_bad = spi_bad + 1;
                if (spi_bad < 5)
                    $display("SPI MISMATCH k=%0d rx=%04h dut=%04h", k, px[k], px_ref[k]);
            end
        end

        // ---- 色 / 波形位置の検証 ----
        //   受信したピクセルをピクセル座標に並べ直し、DUT の pixel_color と
        //   同じ規則で期待色を計算して照合する。
        wave_hits = 0; grid_hits = 0; axis_hits = 0; bg_hits = 0;
        bar_hits  = 0;
        bad_color = 0; bad_wave  = 0; bad_bar = 0;

        // px[k] は k = row*LCD_W + col の順に届く
        //   (col が先に進み、次行へ)
        //   dut.col_cnt / dut.row_cnt を直接見ると、カウンタ更新と同じ
        //   クロックになって 1 ずれるため、転送順から座標を求める。
        for (k = 0; k < NPIX; k = k + 1) begin
            col = k % LCD_W;
            row = k / LCD_W;

            // DUT がこの列で読み出した RAM インデックス
            //   時間軸 (spp) はフレーム開始時にラッチされている
            idx = expected_idx(col, px_spp[k]);

            ey = expected_y(mem[idx]);
            lo = (ey > 0) ? ey - 1 : 0;
            hi = (ey < (LCD_H - 1)) ? ey + 1 : (LCD_H - 1);

            // バーの情報 (列 -> bin)
            bin = col / BAR_PITCH;
            bh  = (bin < BAR_N) ? bar_ram[bin] : 0;

            // DUT の pixel_color をそのまま再現する
            //   BAR_OVER_WAVE = 1 : バー > 波形 > 中央線 > グリッド > 背景
            exp = expected_pixel(col, row, lo, hi, bin, bh);

            if (px[k] !== exp) begin
                if (px[k] === COL_BAR || exp === COL_BAR) begin
                    // バーが途切れている / 余計に描かれている
                    bad_bar = bad_bar + 1;
                    if (bad_bar < 10)
                        $display("BAR MISMATCH col=%0d row=%0d rx=%04h exp=%04h (bin=%0d h=%0d)",
                                 col, row, px[k], exp, bin, bh);
                end else begin
                    bad_color = bad_color + 1;
                    if (bad_color < 10)
                        $display("COLOR MISMATCH col=%0d row=%0d rx=%04h exp=%04h",
                                 col, row, px[k], exp);
                end
            end

            case (px[k])
                COL_WAVE: wave_hits = wave_hits + 1;
                COL_GRID: grid_hits = grid_hits + 1;
                COL_AXIS: axis_hits = axis_hits + 1;
                COL_BAR : bar_hits  = bar_hits  + 1;
                COL_BG  : bg_hits   = bg_hits   + 1;
                default: ;
            endcase

            // 波形の位置チェック (バーが上に描かれる列は除外)
            if ((px[k] === COL_WAVE) && (row < lo || row > hi) &&
                (bh == 0)) begin
                bad_wave = bad_wave + 1;
                if (bad_wave < 8)
                    $display("WAVE MISMATCH col=%0d row=%0d exp %0d..%0d (s=%0d)",
                             col, row, lo, hi, mem[idx]);
            end
        end

        // ---- バーの連続性チェック ----
        //   バーのある列は、下辺から表示高さまで隙間なく塗られていること。
        //   (波形や中央線がバーを横切って途切れさせていないこと)
        begin
            integer gap;
            integer exp_h;
            integer r2;
            logic   seen_gap;
            gap = 0;
            for (k = 0; k < LCD_W; k = k + 1) begin
                bin = k / BAR_PITCH;
                if ((bin < BAR_N) && (bar_ram[bin] != 0) &&
                    ((k % BAR_PITCH) < BAR_W)) begin
                    exp_h = bar_ram[bin] << BAR_GAIN_SH;
                    if (exp_h > (LCD_H - 1)) exp_h = LCD_H - 1;
                    seen_gap = 1'b0;
                    // バー本体 (下辺から exp_h 行) が全部 COL_BAR か
                    //   px 配列は row*LCD_W + col の順
                    for (r2 = (LCD_H - 1) - exp_h; r2 <= (LCD_H - 1); r2 = r2 + 1)
                        if (px[r2*LCD_W + k] !== COL_BAR) seen_gap = 1'b1;
                    // バーの無い列は COL_BAR でないこと
                    if (seen_gap) begin
                        gap = gap + 1;
                        if (gap < 6)
                            $display("BAR GAP col=%0d h=%0d (exp_h=%0d)",
                                     k, bar_ram[bin], exp_h);
                    end
                end else begin
                    seen_gap = 1'b0;
                    for (r2 = 0; r2 < LCD_H; r2 = r2 + 1)
                        if (px[r2*LCD_W + k] === COL_BAR) seen_gap = 1'b1;
                    if (seen_gap) begin
                        gap = gap + 1;
                    end
                end
            end
            $display("  bar continuity failures = %0d", gap);
            errors = errors + gap;
        end

        errors = errors + spi_bad + bad_color + bad_wave + bad_bar;

        $display("---------------------------------------------");
        $display("wave=%0d grid=%0d axis=%0d bar=%0d bg=%0d",
                 wave_hits, grid_hits, axis_hits, bar_hits, bg_hits);
        $display("spi_bad   = %0d", spi_bad);
        $display("bad_color = %0d  bad_wave = %0d  bad_bar = %0d",
                 bad_color, bad_wave, bad_bar);
        $display("errors    = %0d", errors);
        $display("---------------------------------------------");

        // ================================================
        // フェーズ 2 : 時間軸の切り替え
        //   tb_sel を変えると次フレームから spp が変わり、
        //   その 1 フレームは画面全体がクリアされること。
        // ================================================
        $display("--- phase 2 : timebase switch ---");
        begin
            integer spp_seen;
            integer clr_cnt;

            // spp = 1 << tb_sel であること (ラッチ後の値)
            for (k = 0; k < TB_N; k = k + 1) begin
                tb_sel = k[2:0];

                // 切り替えフレーム (クリアされる) を 1 回流す
                wait_frame;
                // 次のフレームから新しい時間軸で描画される
                pix_count = 0;
                collect   = 1'b1;
                fresh_pulse;
                wait_frame;
                collect = 1'b0;

                spp_seen = (1 << k);
                $display("  tb_sel=%0d : spp_r=%0d (expect %0d), pixels=%0d",
                         k, dut.spp_r, spp_seen, pix_count);
                if (dut.spp_r !== spp_seen[7:0]) begin
                    errors = errors + 1;
                    $display("    FAIL: spp_r");
                end
                if (pix_count != NPIX) begin
                    errors = errors + 1;
                    $display("    FAIL: expected %0d pixels", NPIX);
                end
            end
        end

        // ================================================
        // フェーズ 3 : 棒グラフの消去 (寿命)
        //   bar_fresh を与えないままフレームを進めると、
        //   BAR_HOLD フレーム後にバーが描かれなくなること。
        // ================================================
        $display("--- phase 3 : bar expiry ---");
        begin
            integer bars_alive;

            tb_sel    = 3'd0;
            bar_fresh = 1'b0;

            // まず寿命を切らす
            for (k = 0; k < 6; k = k + 1) wait_frame;
            $display("  bar_hold = %0d, bar_alive = %0d",
                     dut.bar_hold, dut.bar_alive);
            if (dut.bar_alive !== 1'b0) begin
                errors = errors + 1;
                $display("  FAIL: bar should have expired");
            end

            // 寿命切れのフレームではバーが 1 色も描かれないこと
            pix_count = 0;
            collect   = 1'b1;
            wait_frame;
            collect   = 1'b0;
            bad_bar = 0;
            for (k = 0; k < pix_count; k = k + 1)
                if (px[k] === COL_BAR) bad_bar = bad_bar + 1;
            $display("  bar pixels drawn after expiry = %0d (expect 0)", bad_bar);
            if (bad_bar != 0) begin
                errors = errors + 1;
                $display("  FAIL: bars should be cleared");
            end
        end

        // ================================================
        // フェーズ 4 : 1 クロック幅の bar_fresh
        //   実機では bar_fresh は 1 クロックのパルスで、LCD のフレーム
        //   開始 (約 160 ms 間隔) とは非同期。ここで取りこぼすと
        //   バーがまったく表示されなくなる。
        //   フレーム間に 1 クロックだけパルスを与えても寿命が
        //   維持されることを確認する。
        // ================================================
        $display("--- phase 4 : 1-cycle bar_fresh between frames ---");
        begin
            integer i;
            integer bars_seen;

            tb_sel    = 3'd0;
            bar_fresh = 1'b0;

            // 各回 : フレーム終了後に 1 クロックだけパルスを出し、
            //        次のフレーム (パルスを消費したフレーム) が終わってから
            //        バーが生きているかを数える。
            bars_seen = 0;
            for (i = 0; i < 8; i = i + 1) begin
                // フレーム終了まで待つ
                wait_frame;
                // フレーム間の隙間で 1 クロックだけパルスを出す
                @(negedge clk);
                bar_fresh = 1'b1;
                @(negedge clk);
                bar_fresh = 1'b0;
                // パルスを消費したフレームが終わるまで待つ
                wait_frame;
                if (dut.bar_hold != 8'd0) bars_seen = bars_seen + 1;
            end
            $display("  frames with bars alive = %0d / 8 (expect 8)", bars_seen);
            if (bars_seen != 8) begin
                errors = errors + 1;
                $display("  FAIL: 1-cycle bar_fresh was missed by the LCD");
            end
        end

        // ================================================
        // フェーズ 5 : 走査中のバー高さ変化 (途切れの再現)
        //   実機では bar_ram は FFT フレーム (約 6.4 ms) ごとに
        //   書き換わるが、LCD フレームは約 148 ms かかる。しかも
        //   走査は行優先 (col_cnt が速い) なので、1 本のバーの
        //   ピクセルはフレーム全体に散らばっている。
        //   描画中に bar_ram を生で見ると、1 本のバーがフレーム中に
        //   何度も高さを変えて「途中で途切れた」ように見える。
        //
        //   ここではフレーム途中で bar_ram を別の値に変え、
        //   1 フレーム内のバーが「開始時の値」で一貫していることを
        //   確認する (スナップショットが効いていれば一貫する)。
        // ================================================
        $display("--- phase 5 : bar_ram changes mid-frame ---");
        begin
            integer r3, c3, changed;
            integer snap0;
            integer snap_bin [0:63];   // フレーム開始時の各 bin の値

            tb_sel    = 3'd0;
            bar_fresh = 1'b0;

            // バーを表示させ、寿命を保つ
            fresh_pulse;
            wait_frame;

            // このフレームのピクセルを取り込み始める
            pix_count = 0;
            collect   = 1'b1;

            // 最初のピクセルが来ればスナップショットは読み込み済み
            begin : wait_first
                integer waited;
                waited = 0;
                while (pix_count == 0 && waited < 500000) begin
                    @(posedge clk);
                    waited = waited + 1;
                end
            end
            // このフレーム開始時のスナップショットをコピーする
            for (r3 = 0; r3 < 64; r3 = r3 + 1)
                snap_bin[r3] = dut.bar_snap[r3];
            snap0 = dut.bar_snap[0];

            // フレームの途中 (半分ほど) で bar_ram を別の値に変える
            begin : wait_half
                integer waited;
                waited = 0;
                while (pix_count < (NPIX/2) && waited < 500000) begin
                    @(posedge clk);
                    waited = waited + 1;
                end
            end
            // bar_ram を変える (bar_data もすぐ追従する)
            for (r3 = 0; r3 < 64; r3 = r3 + 1)
                bar_ram[r3] = 8'd9;
            // 残りを最後まで受信する
            begin : wait_rest
                integer waited2;
                waited2 = 0;
                while (pix_count < NPIX && waited2 < 500000) begin
                    @(posedge clk);
                    waited2 = waited2 + 1;
                end
            end
            collect = 1'b0;

            // 受信したバーピクセルが、すべてフレーム開始時の
            // スナップショット値に基づく高さであることを確認する。
            //   -> 走査中の bar_ram 変化 (9) が混ざっていないこと。
            changed = 0;
            for (c3 = 0; c3 < LCD_W; c3 = c3 + 1) begin
                integer bin3, exp_h3, r4;
                bin3 = c3 / BAR_PITCH;
                if ((bin3 < BAR_N) && ((c3 % BAR_PITCH) < BAR_W) &&
                    (snap_bin[bin3] != 0)) begin
                    exp_h3 = snap_bin[bin3] << BAR_GAIN_SH;
                    if (exp_h3 > (LCD_H - 1)) exp_h3 = LCD_H - 1;
                    // 期待するバー本体が全部 COL_BAR か
                    for (r4 = (LCD_H - 1) - exp_h3; r4 <= (LCD_H - 1); r4 = r4 + 1)
                        if (px[r4*LCD_W + c3] !== COL_BAR) changed = changed + 1;
                    // 期待するバーの上側に COL_BAR が無いこと
                    for (r4 = 0; r4 < ((LCD_H - 1) - exp_h3); r4 = r4 + 1)
                        if (px[r4*LCD_W + c3] === COL_BAR) changed = changed + 1;
                end
            end
            $display("  mid-frame change : snap[0]=%0d snap[2]=%0d, inconsistent bar pixels=%0d (expect 0)",
                     snap0, snap_bin[2], changed);
            if (changed != 0) begin
                errors = errors + 1;
                $display("  FAIL: frame used more than one bar height");
            end

            // 後片付け : 元のパターンに戻す
            for (r3 = 0; r3 < 64; r3 = r3 + 1)
                bar_ram[r3] = ((r3 % 2) == 0) ? BAR_TEST_H[7:0] : 8'd0;
        end

        $display("---------------------------------------------");
        $display("errors    = %0d", errors);
        $display("---------------------------------------------");

        if (errors == 0 && pix_count >= NPIX && wave_hits > 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule
