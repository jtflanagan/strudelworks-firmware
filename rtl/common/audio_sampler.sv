`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// audio_sampler - the play-rate sample clock and the box average behind it
// (docs/AUDIO.md, "Decimation").
//
// The sample clock is a 32-bit NCO on the 100 MHz clock: `rate_inc` per
// clock, a sample at every carry.  44 100 Hz is 1 894 081 (44100 * 2^32 /
// 1e8); the host trims it by parts per million to hold its buffer level,
// so the card's oscillator and the Pi's audio clock never drift apart.
//
// Between two carries EVERY CLOCK is accumulated: the speaker bit (a count
// of the clocks it was high) and each AY chip's summed output (10 bits, the
// three channels' DAC levels added in ay_pair).  That is a box filter one
// sample wide - the average a cone or an amplifier's input would see of
// what the chips did in that window, whatever time base the chips ran in.
// The accumulators saturate rather than wrap, so a slow rate written by
// mistake clips instead of folding.
//
// At the carry the five accumulators are latched and cleared (the carry
// clock's own values start the next window) and walked one a clock through
// ONE multiplier - the first DSP48 in the design - by the constant that
// maps full scale to 32767: the speaker high for the whole nominal window
// (2267.57 clocks, its count shifted up 9 first so one constant width and
// one shift serve both), a chip's three channels at level 15 (3 * 255) for
// the whole window.  `sample = acc * K >> 22`.  The window is 2267 or 2268
// clocks as the NCO's phase falls, a 0.04 % ripple of amplitude that no
// ear has, so K is a constant and there is no divide.  Five products in
// eight clocks against a window of two thousand: the pipeline is invisible.
//////////////////////////////////////////////////////////////////////////////////
module audio_sampler #(
    parameter integer K_SPK = 118378,   // 32767 * 2^22 / (2267.57 * 512): the count arrives shifted up 9
    parameter integer K_AY  = 79225,    // 32767 * 2^22 / (765 * 2267.57)
    // The Ensoniq's, on the same plan: the mix is taken down 5 bits first so
    // full scale is 32640 rather than 1044480, and 32767 * 2^22 / (32640 *
    // 2267.57) = 1856.  See the note on its accumulator below.
    parameter integer K_DOC = 1856
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,          // AUDIO_CTRL[0]; low holds everything at zero
    input  wire [31:0] rate_inc,        // AUDIO_RATE

    input  wire        spk,             // the speaker flip-flop's level
    input  wire [39:0] ay_out,          // {chip3, chip2, chip1, chip0}, 10 bits each
    // The Ensoniq's mix (rtl/gs_doc.sv), signed, already summed across the
    // oscillators.  Zero on the IIe build, where the DOC is not built.
    input  wire signed [20:0] doc_l,
    input  wire signed [20:0] doc_r,

    output logic        smp_valid,      // one clock: a sample is on the outputs
    output logic [15:0] smp_spk,
    output logic [63:0] smp_ay,         // {chip3, chip2, chip1, chip0}, 16 bits each
    output logic [15:0] smp_doc_l,      // the Ensoniq, stereo
    output logic [15:0] smp_doc_r
);

    // ---- the NCO -----------------------------------------------------------
    logic [31:0] phase = 32'd0;
    wire  [32:0] phase_next = {1'b0, phase} + {1'b0, rate_inc};
    wire         tick = enable && phase_next[32];

    always_ff @(posedge clk) begin
        if (rst || !enable) phase <= 32'd0;
        else                phase <= phase_next[31:0];
    end

    // ---- the accumulators --------------------------------------------------
    logic [11:0] spk_acc = 12'd0;
    logic [21:0] ay_acc [0:3];
    logic [11:0] spk_lat;
    logic [21:0] ay_lat [0:3];

    wire [11:0] spk_add = spk_acc + {11'd0, spk};
    wire [11:0] spk_sat = (&spk_acc) ? spk_acc : spk_add;

    integer i;
    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            spk_acc <= 12'd0;
            for (i = 0; i < 4; i = i + 1) ay_acc[i] <= 22'd0;
        end else if (tick) begin
            spk_acc <= {11'd0, spk};
            for (i = 0; i < 4; i = i + 1) ay_acc[i] <= {12'd0, ay_out[i*10 +: 10]};
        end else begin
            spk_acc <= spk_sat;
            for (i = 0; i < 4; i = i + 1) begin
                if (ay_acc[i] > 22'h3FFC00) ay_acc[i] <= 22'h3FFFFF;   // saturate
                else ay_acc[i] <= ay_acc[i] + {12'd0, ay_out[i*10 +: 10]};
            end
        end
    end

    // ---- the Ensoniq's own box, and its own multipliers ---------------------
    // WHY IT IS NOT ON THE WALK ABOVE.  That walk shares one UNSIGNED DSP, and
    // the DOC's mix is SIGNED and two decimal orders wider - full scale is 32
    // oscillators at +-128 * 255.  Biasing it non-negative to borrow the
    // shared multiplier would cost an offset subtraction afterwards and a
    // constant nobody could read; two dedicated signed multiplies cost two of
    // the 238 idle DSP48s.  The user's call, and the cheaper one.
    //
    // IT DOES NEED THE BOX.  The scan completes - and so snd_l/snd_r change -
    // at DOC_SCAN_RATE / (osc_en + 2), which with few oscillators enabled is
    // ~298 kHz, well above the 44.1 kHz Nyquist.  Sample-and-hold would alias
    // that; the window average is the same anti-aliasing the AYs get.
    //
    // The mix comes down 5 bits on the way in so the accumulator stays inside
    // 28 bits over a 2268-clock window: 32640 * 2268 < 2^27.
    logic signed [27:0] dl_acc, dr_acc, dl_lat, dr_lat;
    wire signed [15:0]  dl_in = doc_l[20:5];
    wire signed [15:0]  dr_in = doc_r[20:5];

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            dl_acc <= 28'sd0; dr_acc <= 28'sd0;
        end else if (tick) begin
            dl_acc <= {{12{dl_in[15]}}, dl_in};
            dr_acc <= {{12{dr_in[15]}}, dr_in};
        end else begin
            dl_acc <= dl_acc + {{12{dl_in[15]}}, dl_in};
            dr_acc <= dr_acc + {{12{dr_in[15]}}, dr_in};
        end
    end

    wire signed [17:0] k_doc = 18'(K_DOC);
    (* use_dsp = "yes" *) logic signed [45:0] dl_prod, dr_prod;
    logic dmul_v = 1'b0;
    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            dmul_v <= 1'b0; smp_doc_l <= 16'd0; smp_doc_r <= 16'd0;
        end else begin
            if (tick) begin dl_lat <= dl_acc; dr_lat <= dr_acc; end
            dmul_v  <= tick;
            dl_prod <= dl_lat * k_doc;
            dr_prod <= dr_lat * k_doc;
            // Ready two clocks after the tick, where the walk above takes
            // seven, so both are standing when smp_valid goes out.
            if (dmul_v) begin
                smp_doc_l <= clamp16s(dl_prod >>> 22);
                smp_doc_r <= clamp16s(dr_prod >>> 22);
            end
        end
    end

    // ---- the multiplier walk -------------------------------------------------
    // step: 0 idle, 1..5 loading operand n-1, then two pipeline stages.
    logic [2:0]  step = 3'd0;
    logic [21:0] mul_a;
    logic [16:0] mul_b;
    logic        mul_v1 = 1'b0, mul_v2 = 1'b0;
    logic [2:0]  idx1, idx2;
    (* use_dsp = "yes" *) logic [38:0] prod;

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            step   <= 3'd0;
            mul_v1 <= 1'b0;
            mul_v2 <= 1'b0;
            smp_valid <= 1'b0;
        end else begin
            // latch at the carry
            if (tick) begin
                spk_lat <= spk_acc;                                     // the window's, before this clock's
                for (i = 0; i < 4; i = i + 1) ay_lat[i] <= ay_acc[i];
                step <= 3'd1;
            end else if (step != 3'd0) begin
                step <= (step == 3'd5) ? 3'd0 : step + 3'd1;
            end

            // stage 1: operands
            mul_v1 <= (step != 3'd0);
            idx1   <= step - 3'd1;
            case (step)
                3'd1:    begin mul_a <= {1'b0, spk_lat, 9'd0}; mul_b <= 17'(K_SPK); end
                3'd2:    begin mul_a <= ay_lat[0];        mul_b <= 17'(K_AY);  end
                3'd3:    begin mul_a <= ay_lat[1];        mul_b <= 17'(K_AY);  end
                3'd4:    begin mul_a <= ay_lat[2];        mul_b <= 17'(K_AY);  end
                default: begin mul_a <= ay_lat[3];        mul_b <= 17'(K_AY);  end
            endcase

            // stage 2: the product
            mul_v2 <= mul_v1;
            idx2   <= idx1;
            prod   <= mul_a * mul_b;

            // stage 3: scale, clamp, place
            smp_valid <= 1'b0;
            if (mul_v2) begin
                case (idx2)
                    3'd0:    smp_spk          <= clamp16(prod[38:22]);
                    3'd1:    smp_ay[15:0]     <= clamp16(prod[38:22]);
                    3'd2:    smp_ay[31:16]    <= clamp16(prod[38:22]);
                    3'd3:    smp_ay[47:32]    <= clamp16(prod[38:22]);
                    default: begin smp_ay[63:48] <= clamp16(prod[38:22]); smp_valid <= 1'b1; end
                endcase
            end
        end
    end

    // The signed clamp, for the Ensoniq: the unsigned one below cannot serve,
    // its whole job being to catch a 17th bit that means "too loud".
    function automatic [15:0] clamp16s(input signed [45:0] v);
        begin
            if (v >  46'sd32767) clamp16s = 16'h7FFF;
            else if (v < -46'sd32768) clamp16s = 16'h8000;
            else clamp16s = v[15:0];
        end
    endfunction

    function automatic [15:0] clamp16(input [16:0] v);
        clamp16 = (v > 17'd32767) ? 16'd32767 : v[15:0];
    endfunction

endmodule
