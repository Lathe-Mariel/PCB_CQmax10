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
    localparam integer AMP_GAIN_SHIFT = 2;
    localparam integer FRAME_WAIT     = 100;
    localparam integer POWERON_WAIT   = 50;
    localparam integer SWRST_WAIT     = 20;
    localparam integer SLPOUT_WAIT    = 20;
    localparam integer DEPTH          = 64;
    localparam integer NPIX           = LCD_W * LCD_H;

    localparam [15:0] COL_BG   = 16'h0000;
    localparam [15:0] COL_GRID = 16'h1082;
    localparam [15:0] COL_AXIS = 16'h4208;
    localparam [15:0] COL_WAVE = 16'h07E0;

    logic clk = 1'b0;
    always #10 clk = ~clk;

    logic rst_n;

    logic               lcd_cs, lcd_dc, lcd_mosi, lcd_sck;
    logic [BUF_AW-1:0]  rd_addr, wr_ptr;
    logic signed [15:0] rdata;
    logic               init_done, frame_tick;

    // ---- RAM モデル (ノコギリ波) ----
    logic signed [15:0] mem [0:DEPTH-1];

    // ---- 観測 ----
    logic [15:0] px [0:NPIX-1];
    logic [8:0]  px_col [0:NPIX-1];
    logic [7:0]  px_row [0:NPIX-1];
    logic [15:0] px_ref [0:NPIX-1];
    logic [BUF_AW-1:0] px_rdbase [0:NPIX-1];
    integer      pix_count;
    integer      cmd_cnt;
    logic [7:0]  cmd_hist [0:15];

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
        .SLPOUT_WAIT    (SLPOUT_WAIT)
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
        .init_done  (init_done),
        .frame_tick (frame_tick)
    );

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
        if (word_valid && init_done && pix_count < NPIX) begin
            px[pix_count] <= word;
            // DUT が今送っているピクセルの位置と色
            px_col[pix_count]  <= dut.col_cnt;
            px_row[pix_count]  <= dut.row_cnt;
            px_ref[pix_count]  <= dut.cur_color;
            px_rdbase[pix_count] <= dut.rd_base;
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
            off = s <<< AMP_GAIN_SHIFT;
            y   = (LCD_H / 2 - 1) - off;
            if (y < 0)                 y = 0;
            else if (y > (LCD_H - 1))  y = LCD_H - 1;
            expected_y = y;
        end
    endfunction

    // 描画列 col に対応する波形 RAM のインデックス
    //   rd_idx = (wr_ptr - 1 - LCD_W + col) mod DEPTH
    function integer expected_idx;
        input integer col;
        integer idx;
        begin
            idx = (63 - 1 - LCD_W + col) % DEPTH;
            if (idx < 0) idx = idx + DEPTH;
            expected_idx = idx;
        end
    endfunction
    // --------------------------------------------------------
    // メイン
    // --------------------------------------------------------
    integer k, col, row, ey, lo, hi, idx;
    integer wave_hits, grid_hits, axis_hits, bg_hits;
    integer bad_color, bad_wave, spi_bad, errors;
    integer timeout;

    initial begin
        rst_n   = 1'b0;
        errors  = 0;

        repeat (20) @(posedge clk);
        rst_n = 1'b1;

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
        //   DUT が使ったサンプル値から期待色を計算し、受信値と比較する
        wave_hits = 0; grid_hits = 0; axis_hits = 0; bg_hits = 0;
        bad_color = 0; bad_wave  = 0;

        for (k = 0; k < NPIX; k = k + 1) begin
            col = px_col[k];
            row = px_row[k];

            // DUT がこの列で読み出した RAM インデックス
            idx = (px_rdbase[k] - 1 - LCD_W + col) % DEPTH;
            if (idx < 0) idx = idx + DEPTH;

            ey = expected_y(mem[idx]);
            lo = (ey > 0) ? ey - 1 : 0;
            hi = (ey < (LCD_H - 1)) ? ey + 1 : (LCD_H - 1);

            if (px[k] === COL_WAVE) begin
                wave_hits = wave_hits + 1;
                if (row < lo || row > hi) begin
                    bad_wave = bad_wave + 1;
                    if (bad_wave < 8)
                        $display("WAVE MISMATCH col=%0d row=%0d exp %0d..%0d (s=%0d)",
                                 col, row, lo, hi, mem[idx]);
                end
            end else if (px[k] === COL_GRID) begin
                grid_hits = grid_hits + 1;
            end else if (px[k] === COL_AXIS) begin
                axis_hits = axis_hits + 1;
            end else if (px[k] === COL_BG) begin
                bg_hits = bg_hits + 1;
            end else begin
                bad_color = bad_color + 1;
                if (bad_color < 5)
                    $display("UNKNOWN COLOR %04h col=%0d row=%0d", px[k], col, row);
            end
        end

        errors = errors + spi_bad + bad_color + bad_wave;

        $display("---------------------------------------------");
        $display("wave=%0d grid=%0d axis=%0d bg=%0d",
                 wave_hits, grid_hits, axis_hits, bg_hits);
        $display("spi_bad   = %0d", spi_bad);
        $display("bad_color = %0d  bad_wave = %0d", bad_color, bad_wave);
        $display("errors    = %0d", errors);
        $display("---------------------------------------------");

        if (errors == 0 && pix_count >= NPIX && wave_hits > 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule
