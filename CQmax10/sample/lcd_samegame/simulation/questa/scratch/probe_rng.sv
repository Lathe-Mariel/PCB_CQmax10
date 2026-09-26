// probe_rng.sv - what distribution does game_fsm's board generator produce?
//
// Reproduces the generator arithmetic exactly as written in game_fsm.sv
// (S_GENERATE + the write arbiter) and counts the resulting logo ids.
`timescale 1ns/1ps

module probe_rng;
    logic clk = 0;
    always #10 clk = ~clk;
    logic rst = 1;

    // LFSR exactly as rng_generator.sv
    localparam logic [15:0] SEED = 16'hACE1;
    logic [15:0] rng;
    logic        next;
    wire fb = rng[15] ^ rng[13] ^ rng[12] ^ rng[10];

    always_ff @(posedge clk) begin
        if (rst) rng <= SEED;
        else if (next) rng <= {rng[14:0], fb};
    end

    // the *current* game_fsm rule
    function automatic logic [2:0] id_current(input logic [15:0] r);
        return (r[2:0] < 3'd5) ? r[2:0] : 3'd0;
    endfunction

    // the *proposed* rule: rejection sampling, redraw until r[2:0] < 5
    int cnt_cur  [0:4];
    int cnt_new  [0:4];
    int n_samples;

    initial begin
        next = 0;
        for (int i = 0; i < 5; i++) begin cnt_cur[i] = 0; cnt_new[i] = 0; end
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        n_samples = 0;
        // 100000 accepted samples for both rules
        while (n_samples < 100000) begin
            @(posedge clk);
            next <= 1'b1;
            begin
                logic [2:0] v;
                v = id_current(rng);
                cnt_cur[v] = cnt_cur[v] + 1;
            end
            if (rng[2:0] < 3'd5) begin
                logic [2:0] v;
                v = rng[2:0];
                cnt_new[v] = cnt_new[v] + 1;
                n_samples++;
            end
        end

        $display("current rule  (r[2:0] < 5 ? r[2:0] : 0), 100000 cells:");
        for (int i = 0; i < 5; i++)
            $display("   Logo%0d : %6d  (%0.1f%%)", i, cnt_cur[i],
                     100.0 * cnt_cur[i] / 100000.0);
        $display("rejection-sampling rule, 100000 accepted cells:");
        for (int i = 0; i < 5; i++)
            $display("   Logo%0d : %6d  (%0.1f%%)", i, cnt_new[i],
                     100.0 * cnt_new[i] / n_samples);
        $finish;
    end
endmodule
