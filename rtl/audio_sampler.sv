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
    parameter integer K_AY  = 79225     // 32767 * 2^22 / (765 * 2267.57)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,          // AUDIO_CTRL[0]; low holds everything at zero
    input  wire [31:0] rate_inc,        // AUDIO_RATE

    input  wire        spk,             // the speaker flip-flop's level
    input  wire [39:0] ay_out,          // {chip3, chip2, chip1, chip0}, 10 bits each

    output logic        smp_valid,      // one clock: a sample is on the outputs
    output logic [15:0] smp_spk,
    output logic [63:0] smp_ay          // {chip3, chip2, chip1, chip0}, 16 bits each
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

    function automatic [15:0] clamp16(input [16:0] v);
        clamp16 = (v > 17'd32767) ? 16'd32767 : v[15:0];
    endfunction

endmodule
