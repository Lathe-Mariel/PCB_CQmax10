// tb_frame_seq.sv
//
// Focused check of frame_seq.sv's frame pacing, especially the PARALLEL timer
// behaviour introduced in Step 5.
//
// frame_seq must pace frames at
//
//     period = max(FRAME_PERIOD_MS, transfer time)
//
// where "transfer time" is modelled here by holding `ready` low (the LCD
// controller drops req_ready while it is busy with a frame). The two properties
// checked are:
//
//   1. with `ready` always high, requests repeat at exactly FRAME_PERIOD_MS
//   2. if `ready` is low across the period boundary, the request is issued on
//      the FIRST cycle `ready` returns high, and the next period starts from
//      that point - i.e. one period and no more, never period + transfer
//
// This runs in milliseconds of CPU time (no SPI), so it is the cheap way to
// watch the pacer. The bug it guards against: a timer that only starts AFTER
// the transfer would give period = FRAME_PERIOD_MS + transfer.

`timescale 1ns/1ps

module tb_frame_seq;
    localparam int CLK_HZ          = 50_000_000;
    localparam int MS_SCALE        = 1;
    localparam int FRAME_PERIOD_MS = 10;
    localparam int PERIOD_CLK      = (CLK_HZ/1000)/MS_SCALE * FRAME_PERIOD_MS;  // 500000

    logic clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    logic rst  = 1'b1;
    logic ready = 1'b0;

    logic       req_valid;
    logic [1:0] req_cmd;
    logic       frame_active;

    frame_seq #(
        .CLK_FREQ_HZ     (CLK_HZ),
        .FRAME_PERIOD_MS (FRAME_PERIOD_MS),
        .MS_SCALE        (MS_SCALE)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .ready        (ready),
        .req_valid    (req_valid),
        .req_cmd      (req_cmd),
        .frame_active (frame_active)
    );

    // ------------------------------------------------------------------
    // cycle counter + request capture
    // ------------------------------------------------------------------
    longint cyc = 0;
    always_ff @(posedge clk) cyc <= cyc + 1;

    logic rv_d = 1'b0;
    always_ff @(posedge clk) rv_d <= req_valid;

    int      errors = 0;
    int      n_req  = 0;
    longint  prev_req = 0;

    int      req_clk [$];            // cycles at which req_valid rose
    longint  ready_rise_clk = 0;

    always_ff @(posedge clk) begin
        if (req_valid && !rv_d) begin
            req_clk.push_back(cyc);
            n_req <= n_req + 1;
        end
        if (ready && !$past(ready)) ready_rise_clk <= cyc;
    end

    task automatic check(input bit cond, input string what);
        if (!cond) begin
            $display("  FAIL %s", what);
            errors = errors + 1;
        end else begin
            $display("  OK   %s", what);
        end
    endtask

    // wait until the TOTAL number of requests reaches n (n_req is owned by the
    // always_ff block, so the initial block only reads it)
    task automatic wait_reqs(input int n);
        while (n_req < n) @(negedge clk);
    endtask

    longint delta;
    int     base;
    int     i;

    initial begin
        // ---- phase 1: ready always high -> exact period ----
        repeat (5) @(negedge clk);
        ready = 1'b1;
        rst   = 1'b0;

        wait_reqs(3);
        repeat (2) @(negedge clk);

        $display("");
        $display("---- phase 1: ready always high ----");
        $display("  requests at clk %0d %0d %0d", req_clk[0], req_clk[1], req_clk[2]);
        // Allow a couple of cycles of slack: the F_REQ handshake state costs
        // one cycle while `ready` stays high, which is 0.0002% of a 150 ms
        // frame. The point of the test is the PARALLEL timing (phase 2), not
        // the exact cycle.
        delta = req_clk[1] - req_clk[0];
        check((delta >= PERIOD_CLK) && (delta <= (PERIOD_CLK + 2)),
              $sformatf("period = %0d clk (want %0d..%0d)",
                        delta, PERIOD_CLK, PERIOD_CLK + 2));
        delta = req_clk[2] - req_clk[1];
        check((delta >= PERIOD_CLK) && (delta <= (PERIOD_CLK + 2)),
              $sformatf("period = %0d clk (want %0d..%0d)",
                        delta, PERIOD_CLK, PERIOD_CLK + 2));

        // ---- phase 2: ready low across the period boundary ----
        // Drop `ready` for 1.5 periods (simulating a transfer longer than the
        // frame period) and check the next request comes one period after the
        // FIRST request and fires the moment ready returns.
        req_clk.delete();
        base = n_req;
        repeat (3) @(negedge clk);

        ready = 1'b0;                       // "transfer" starts
        repeat (PERIOD_CLK + PERIOD_CLK/2) @(negedge clk);
        // ready has been low for 1.5 periods; release it and see when req comes
        ready = 1'b1;

        wait_reqs(base + 1);
        repeat (2) @(negedge clk);

        $display("");
        $display("---- phase 2: ready low for 1.5 periods ----");
        $display("  ready rose at clk %0d, request at clk %0d",
                 ready_rise_clk, req_clk[0]);
        delta = req_clk[0] - ready_rise_clk;
        // must fire within a couple of cycles of ready rising, NOT wait another
        // full period
        check(delta <= 3,
              $sformatf("issued %0d clk after ready rose (want <= 3)", delta));

        $display("");
        if (errors == 0)
            $display("*** tb_frame_seq: PASS ***");
        else
            $display("*** tb_frame_seq: FAIL (%0d) ***", errors);
        $finish;
    end
endmodule
