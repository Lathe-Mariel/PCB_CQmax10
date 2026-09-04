// =============================================================================
// jingle_player.sv
// Plays a short 5-tone chime (F#-C#-F#-C#-G#) in the style of the
// well-known "Intel Inside" audio sonic logo, using a small wavetable
// synthesizer (DDS phase accumulator + bell/chime-like harmonic waveform
// ROM + attack/decay envelope) driving an 8-bit PWM DAC.
//
// Chime character comes from two things:
//   1) A waveform ROM built from a sparse set of partials (strong 1st,
//      2nd, 5th, 7th, 9th, 11th; weak in between) instead of a smoothly
//      decaying harmonic series -- closer to a real bell/chime spectrum
//      than the earlier piano-style table.
//   2) A long, slow envelope decay (~2.5s time constant) that keeps
//      oscillating at the last-struck pitch through the trailing rest
//      step, so each note rings out into the gap instead of being cut
//      off -- this is what actually reads as "reverb"/sustain; a
//      single-cycle wavetable on its own cannot produce true reverb
//      (that needs a time-domain delay/reflection effect), so this is
//      the practical way to get that impression on this hardware.
//
// Output feeds PMOD-AUDIO v1.2's onboard RC filter + PAM8403 amplifier
// (IL input, board Port1). Loops with a long gap between repeats so the
// tail has room to ring out.
//
// All ROM content is implemented as synthesis-safe `case` statements
// (no `initial` blocks), matching project convention.
// =============================================================================
module jingle_player #(
    parameter int CLK_HZ    = 50_000_000,
    parameter int AUDIO_DIV = 1042          // audio sample tick every AUDIO_DIV clk cycles (~48kHz)
) (
    input  logic clk,
    input  logic rst,
    output logic audio
);

    // -------------------------------------------------------------------
    // Note / duration step table (5 tones + trailing rest/gap, then loop).
    // The rest step keeps oscillating at the last note's pitch (G#4) so
    // the decaying envelope produces an audible ring-out, not silence.
    //
    //  step | note | freq(Hz) | phase_inc (Q16, Fs~=48kHz) | dur(ms)
    //   0   | F#4  |  369.99  |  505                        |  200
    //   1   | C#4  |  277.18  |  379                        |  200
    //   2   | F#4  |  369.99  |  505                        |  200
    //   3   | C#4  |  277.18  |  379                        |  200
    //   4   | G#4  |  415.30  |  567                        |  600
    //   5   | (ring-out / gap, G#4 pitch held) |  567        | 2600
    // -------------------------------------------------------------------
    localparam int         NUM_STEPS = 7;
    localparam logic [2:0] REST_STEP = 3'd1;

    logic [2:0]  step;
    logic [2:0]  next_step;
    logic [15:0] phase_inc;
    logic [26:0] duration_cyc;

    assign next_step = (step == NUM_STEPS - 1) ? 3'd0 : step + 3'd1;

    always_comb begin
        unique case (step)
            3'd0: begin phase_inc = 16'd1010; duration_cyc = 27'd6_800_000;  end // F#4, 200ms
            3'd1: begin phase_inc = 16'd0; duration_cyc = 27'd18_700_000;  end // F#4, 200ms
            3'd2: begin phase_inc = 16'd758; duration_cyc = 27'd10_000_000;  end // C#4, 200ms
            3'd3: begin phase_inc = 16'd1010; duration_cyc = 27'd10_000_000;  end // F#4, 200ms
            3'd4: begin phase_inc = 16'd758; duration_cyc = 27'd10_000_000;  end // C#4, 200ms
            3'd5: begin phase_inc = 16'd1134; duration_cyc = 27'd23_000_000;  end // G#4, 600ms
            default: begin phase_inc = 16'd0; duration_cyc = 27'd120_000_000; end // ring-out, 2.6s
        endcase
    end

    // ---------------------------------------------------------------
    // Step/duration sequencer
    // ---------------------------------------------------------------
    logic [26:0] dur_cnt;
    logic        step_done;
    logic        note_on_pulse;   // fires only when the *upcoming* step is a real note

    assign step_done     = (dur_cnt == duration_cyc - 27'd1);
    assign note_on_pulse = step_done && (next_step != REST_STEP);

    always_ff @(posedge clk) begin
        if (rst) begin
            dur_cnt <= '0;
            step    <= '0;
        end else if (step_done) begin
            dur_cnt <= '0;
            step    <= next_step;
        end else begin
            dur_cnt <= dur_cnt + 27'd1;
        end
    end

    // ---------------------------------------------------------------
    // Audio sample-rate tick (~48kHz strobe, free running)
    // ---------------------------------------------------------------
    logic [10:0] smp_cnt;
    logic        smp_en;

    assign smp_en = (smp_cnt == AUDIO_DIV - 1);

    always_ff @(posedge clk) begin
        if (rst)          smp_cnt <= '0;
        else if (smp_en)  smp_cnt <= '0;
        else              smp_cnt <= smp_cnt + 11'd1;
    end

    // ---------------------------------------------------------------
    // DDS phase accumulator. Resets to 0 only on a real note-on (not on
    // entering the rest step) so the oscillator keeps running at the
    // last pitch while the envelope rings out.
    // ---------------------------------------------------------------
    logic [15:0] phase;

    always_ff @(posedge clk) begin
        if (rst) begin
            phase <= '0;
        end else if (note_on_pulse) begin
            phase <= '0;
        end else if (smp_en) begin
            phase <= phase + phase_inc;
        end
    end

    // ---------------------------------------------------------------
    // Attack/decay envelope. Fast linear attack, then a slow "leaky"
    // exponential decay (~2.5s time constant) for a long bell-like ring.
    // Only retriggers (fresh attack) on a real note-on; during the rest
    // step it simply continues decaying from wherever it left off.
    // ---------------------------------------------------------------
    localparam logic       ENV_ATTACK  = 1'b0;
    localparam logic       ENV_DECAY   = 1'b1;
    localparam logic [7:0] ATTACK_STEP = 8'd8;   // envelope units added per sample (~0.7ms to full scale)
    localparam int         DECAY_TICK  = 48;     // samples between each decay update (~1ms @48kHz)
    localparam int         DECAY_SHIFT = 9;       // decay rate: env -= env >> DECAY_SHIFT (~2.5s to silence)

    logic       env_state;
    logic [7:0] env;
    logic [5:0] decay_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            env       <= 8'd0;
            env_state <= ENV_ATTACK;
            decay_cnt <= '0;
        end else if (note_on_pulse) begin
            env       <= 8'd0;
            env_state <= ENV_ATTACK;
            decay_cnt <= '0;
        end else if (smp_en) begin
            if (env_state == ENV_ATTACK) begin
                if (env >= 8'd255 - ATTACK_STEP) begin
                    env       <= 8'd255;
                    env_state <= ENV_DECAY;
                end else begin
                    env <= env + ATTACK_STEP;
                end
            end else begin // ENV_DECAY
                if (decay_cnt == DECAY_TICK - 1) begin
                    decay_cnt <= '0;
                    env       <= env - (env >> DECAY_SHIFT);
                end else begin
                    decay_cnt <= decay_cnt + 6'd1;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Bell/chime-like single-cycle waveform ROM (256 entries, signed
    // 8-bit): a sparse set of partials (1st, 2nd, 5th, 7th, 9th, 11th
    // strong; others weak) rather than a smoothly decaying harmonic
    // series, closer to a real bell/chime spectrum.
    // ---------------------------------------------------------------
    function automatic logic signed [7:0] wave_rom(input logic [7:0] idx);
        case (idx)
            8'd0: wave_rom = 8'sd0;
            8'd1: wave_rom = 8'sd20;
            8'd2: wave_rom = 8'sd40;
            8'd3: wave_rom = 8'sd58;
            8'd4: wave_rom = 8'sd75;
            8'd5: wave_rom = 8'sd90;
            8'd6: wave_rom = 8'sd103;
            8'd7: wave_rom = 8'sd113;
            8'd8: wave_rom = 8'sd120;
            8'd9: wave_rom = 8'sd125;
            8'd10: wave_rom = 8'sd127;
            8'd11: wave_rom = 8'sd127;
            8'd12: wave_rom = 8'sd125;
            8'd13: wave_rom = 8'sd122;
            8'd14: wave_rom = 8'sd118;
            8'd15: wave_rom = 8'sd113;
            8'd16: wave_rom = 8'sd108;
            8'd17: wave_rom = 8'sd103;
            8'd18: wave_rom = 8'sd98;
            8'd19: wave_rom = 8'sd95;
            8'd20: wave_rom = 8'sd92;
            8'd21: wave_rom = 8'sd90;
            8'd22: wave_rom = 8'sd89;
            8'd23: wave_rom = 8'sd89;
            8'd24: wave_rom = 8'sd89;
            8'd25: wave_rom = 8'sd90;
            8'd26: wave_rom = 8'sd92;
            8'd27: wave_rom = 8'sd94;
            8'd28: wave_rom = 8'sd95;
            8'd29: wave_rom = 8'sd97;
            8'd30: wave_rom = 8'sd98;
            8'd31: wave_rom = 8'sd99;
            8'd32: wave_rom = 8'sd99;
            8'd33: wave_rom = 8'sd99;
            8'd34: wave_rom = 8'sd99;
            8'd35: wave_rom = 8'sd99;
            8'd36: wave_rom = 8'sd98;
            8'd37: wave_rom = 8'sd98;
            8'd38: wave_rom = 8'sd98;
            8'd39: wave_rom = 8'sd98;
            8'd40: wave_rom = 8'sd98;
            8'd41: wave_rom = 8'sd99;
            8'd42: wave_rom = 8'sd100;
            8'd43: wave_rom = 8'sd102;
            8'd44: wave_rom = 8'sd104;
            8'd45: wave_rom = 8'sd107;
            8'd46: wave_rom = 8'sd109;
            8'd47: wave_rom = 8'sd112;
            8'd48: wave_rom = 8'sd114;
            8'd49: wave_rom = 8'sd116;
            8'd50: wave_rom = 8'sd118;
            8'd51: wave_rom = 8'sd119;
            8'd52: wave_rom = 8'sd119;
            8'd53: wave_rom = 8'sd119;
            8'd54: wave_rom = 8'sd118;
            8'd55: wave_rom = 8'sd116;
            8'd56: wave_rom = 8'sd114;
            8'd57: wave_rom = 8'sd111;
            8'd58: wave_rom = 8'sd108;
            8'd59: wave_rom = 8'sd104;
            8'd60: wave_rom = 8'sd101;
            8'd61: wave_rom = 8'sd97;
            8'd62: wave_rom = 8'sd94;
            8'd63: wave_rom = 8'sd90;
            8'd64: wave_rom = 8'sd87;
            8'd65: wave_rom = 8'sd85;
            8'd66: wave_rom = 8'sd82;
            8'd67: wave_rom = 8'sd79;
            8'd68: wave_rom = 8'sd77;
            8'd69: wave_rom = 8'sd74;
            8'd70: wave_rom = 8'sd72;
            8'd71: wave_rom = 8'sd69;
            8'd72: wave_rom = 8'sd66;
            8'd73: wave_rom = 8'sd62;
            8'd74: wave_rom = 8'sd58;
            8'd75: wave_rom = 8'sd54;
            8'd76: wave_rom = 8'sd49;
            8'd77: wave_rom = 8'sd43;
            8'd78: wave_rom = 8'sd38;
            8'd79: wave_rom = 8'sd32;
            8'd80: wave_rom = 8'sd27;
            8'd81: wave_rom = 8'sd21;
            8'd82: wave_rom = 8'sd16;
            8'd83: wave_rom = 8'sd11;
            8'd84: wave_rom = 8'sd6;
            8'd85: wave_rom = 8'sd2;
            8'd86: wave_rom = -8'sd2;
            8'd87: wave_rom = -8'sd5;
            8'd88: wave_rom = -8'sd7;
            8'd89: wave_rom = -8'sd9;
            8'd90: wave_rom = -8'sd11;
            8'd91: wave_rom = -8'sd12;
            8'd92: wave_rom = -8'sd13;
            8'd93: wave_rom = -8'sd14;
            8'd94: wave_rom = -8'sd15;
            8'd95: wave_rom = -8'sd16;
            8'd96: wave_rom = -8'sd17;
            8'd97: wave_rom = -8'sd18;
            8'd98: wave_rom = -8'sd19;
            8'd99: wave_rom = -8'sd20;
            8'd100: wave_rom = -8'sd21;
            8'd101: wave_rom = -8'sd22;
            8'd102: wave_rom = -8'sd22;
            8'd103: wave_rom = -8'sd22;
            8'd104: wave_rom = -8'sd21;
            8'd105: wave_rom = -8'sd19;
            8'd106: wave_rom = -8'sd17;
            8'd107: wave_rom = -8'sd13;
            8'd108: wave_rom = -8'sd8;
            8'd109: wave_rom = -8'sd3;
            8'd110: wave_rom = 8'sd3;
            8'd111: wave_rom = 8'sd10;
            8'd112: wave_rom = 8'sd17;
            8'd113: wave_rom = 8'sd24;
            8'd114: wave_rom = 8'sd31;
            8'd115: wave_rom = 8'sd38;
            8'd116: wave_rom = 8'sd44;
            8'd117: wave_rom = 8'sd49;
            8'd118: wave_rom = 8'sd52;
            8'd119: wave_rom = 8'sd54;
            8'd120: wave_rom = 8'sd54;
            8'd121: wave_rom = 8'sd52;
            8'd122: wave_rom = 8'sd49;
            8'd123: wave_rom = 8'sd44;
            8'd124: wave_rom = 8'sd37;
            8'd125: wave_rom = 8'sd29;
            8'd126: wave_rom = 8'sd20;
            8'd127: wave_rom = 8'sd10;
            8'd128: wave_rom = 8'sd0;
            8'd129: wave_rom = -8'sd10;
            8'd130: wave_rom = -8'sd20;
            8'd131: wave_rom = -8'sd29;
            8'd132: wave_rom = -8'sd37;
            8'd133: wave_rom = -8'sd44;
            8'd134: wave_rom = -8'sd49;
            8'd135: wave_rom = -8'sd52;
            8'd136: wave_rom = -8'sd54;
            8'd137: wave_rom = -8'sd54;
            8'd138: wave_rom = -8'sd52;
            8'd139: wave_rom = -8'sd49;
            8'd140: wave_rom = -8'sd44;
            8'd141: wave_rom = -8'sd38;
            8'd142: wave_rom = -8'sd31;
            8'd143: wave_rom = -8'sd24;
            8'd144: wave_rom = -8'sd17;
            8'd145: wave_rom = -8'sd10;
            8'd146: wave_rom = -8'sd3;
            8'd147: wave_rom = 8'sd3;
            8'd148: wave_rom = 8'sd8;
            8'd149: wave_rom = 8'sd13;
            8'd150: wave_rom = 8'sd17;
            8'd151: wave_rom = 8'sd19;
            8'd152: wave_rom = 8'sd21;
            8'd153: wave_rom = 8'sd22;
            8'd154: wave_rom = 8'sd22;
            8'd155: wave_rom = 8'sd22;
            8'd156: wave_rom = 8'sd21;
            8'd157: wave_rom = 8'sd20;
            8'd158: wave_rom = 8'sd19;
            8'd159: wave_rom = 8'sd18;
            8'd160: wave_rom = 8'sd17;
            8'd161: wave_rom = 8'sd16;
            8'd162: wave_rom = 8'sd15;
            8'd163: wave_rom = 8'sd14;
            8'd164: wave_rom = 8'sd13;
            8'd165: wave_rom = 8'sd12;
            8'd166: wave_rom = 8'sd11;
            8'd167: wave_rom = 8'sd9;
            8'd168: wave_rom = 8'sd7;
            8'd169: wave_rom = 8'sd5;
            8'd170: wave_rom = 8'sd2;
            8'd171: wave_rom = -8'sd2;
            8'd172: wave_rom = -8'sd6;
            8'd173: wave_rom = -8'sd11;
            8'd174: wave_rom = -8'sd16;
            8'd175: wave_rom = -8'sd21;
            8'd176: wave_rom = -8'sd27;
            8'd177: wave_rom = -8'sd32;
            8'd178: wave_rom = -8'sd38;
            8'd179: wave_rom = -8'sd43;
            8'd180: wave_rom = -8'sd49;
            8'd181: wave_rom = -8'sd54;
            8'd182: wave_rom = -8'sd58;
            8'd183: wave_rom = -8'sd62;
            8'd184: wave_rom = -8'sd66;
            8'd185: wave_rom = -8'sd69;
            8'd186: wave_rom = -8'sd72;
            8'd187: wave_rom = -8'sd74;
            8'd188: wave_rom = -8'sd77;
            8'd189: wave_rom = -8'sd79;
            8'd190: wave_rom = -8'sd82;
            8'd191: wave_rom = -8'sd85;
            8'd192: wave_rom = -8'sd87;
            8'd193: wave_rom = -8'sd90;
            8'd194: wave_rom = -8'sd94;
            8'd195: wave_rom = -8'sd97;
            8'd196: wave_rom = -8'sd101;
            8'd197: wave_rom = -8'sd104;
            8'd198: wave_rom = -8'sd108;
            8'd199: wave_rom = -8'sd111;
            8'd200: wave_rom = -8'sd114;
            8'd201: wave_rom = -8'sd116;
            8'd202: wave_rom = -8'sd118;
            8'd203: wave_rom = -8'sd119;
            8'd204: wave_rom = -8'sd119;
            8'd205: wave_rom = -8'sd119;
            8'd206: wave_rom = -8'sd118;
            8'd207: wave_rom = -8'sd116;
            8'd208: wave_rom = -8'sd114;
            8'd209: wave_rom = -8'sd112;
            8'd210: wave_rom = -8'sd109;
            8'd211: wave_rom = -8'sd107;
            8'd212: wave_rom = -8'sd104;
            8'd213: wave_rom = -8'sd102;
            8'd214: wave_rom = -8'sd100;
            8'd215: wave_rom = -8'sd99;
            8'd216: wave_rom = -8'sd98;
            8'd217: wave_rom = -8'sd98;
            8'd218: wave_rom = -8'sd98;
            8'd219: wave_rom = -8'sd98;
            8'd220: wave_rom = -8'sd98;
            8'd221: wave_rom = -8'sd99;
            8'd222: wave_rom = -8'sd99;
            8'd223: wave_rom = -8'sd99;
            8'd224: wave_rom = -8'sd99;
            8'd225: wave_rom = -8'sd99;
            8'd226: wave_rom = -8'sd98;
            8'd227: wave_rom = -8'sd97;
            8'd228: wave_rom = -8'sd95;
            8'd229: wave_rom = -8'sd94;
            8'd230: wave_rom = -8'sd92;
            8'd231: wave_rom = -8'sd90;
            8'd232: wave_rom = -8'sd89;
            8'd233: wave_rom = -8'sd89;
            8'd234: wave_rom = -8'sd89;
            8'd235: wave_rom = -8'sd90;
            8'd236: wave_rom = -8'sd92;
            8'd237: wave_rom = -8'sd95;
            8'd238: wave_rom = -8'sd98;
            8'd239: wave_rom = -8'sd103;
            8'd240: wave_rom = -8'sd108;
            8'd241: wave_rom = -8'sd113;
            8'd242: wave_rom = -8'sd118;
            8'd243: wave_rom = -8'sd122;
            8'd244: wave_rom = -8'sd125;
            8'd245: wave_rom = -8'sd127;
            8'd246: wave_rom = -8'sd127;
            8'd247: wave_rom = -8'sd125;
            8'd248: wave_rom = -8'sd120;
            8'd249: wave_rom = -8'sd113;
            8'd250: wave_rom = -8'sd103;
            8'd251: wave_rom = -8'sd90;
            8'd252: wave_rom = -8'sd75;
            8'd253: wave_rom = -8'sd58;
            8'd254: wave_rom = -8'sd40;
            8'd255: wave_rom = -8'sd20;
        endcase
    endfunction

    logic signed [7:0] wave_sample;
    assign wave_sample = wave_rom(phase[15:8]);

    // ---------------------------------------------------------------
    // wave_sample (signed) x env (unsigned volume) -> 8-bit PWM duty
    // ---------------------------------------------------------------
    logic signed [16:0] product;
    logic signed [9:0]  duty_sum;
    logic [7:0]          pwm_duty;

    assign product  = wave_sample * $signed({1'b0, env});
    assign duty_sum = 10'sd128 + (product >>> 8);
    assign pwm_duty = duty_sum[7:0];

    // ---------------------------------------------------------------
    // 8-bit PWM DAC, free-running at CLK_HZ/256 (~195kHz carrier)
    // ---------------------------------------------------------------
    logic [7:0] pwm_cnt;

    always_ff @(posedge clk) begin
        if (rst) pwm_cnt <= '0;
        else     pwm_cnt <= pwm_cnt + 8'd1;
    end

    assign audio = (pwm_cnt < pwm_duty);

endmodule
