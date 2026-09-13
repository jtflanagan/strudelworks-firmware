`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// audio_doc_tb - the Ensoniq's road out of the card: audio_sampler's DOC box.
//
// WHY THIS EXISTS.  sim/audio_tb.sv drives the speaker and the AYs and names
// the Ensoniq only in a comment; it has never put a number on doc_l or doc_r.
// So between rtl/gs_doc.sv - which provably plays when fed a real machine's
// register stream (sim/gs_doc_replay_tb.sv) - and the four-word frame the host
// unpacks, there was one module nothing had ever tested, and the card sends
// doc_l = doc_r = 0 in every sample it has ever sent (2026-09-13).
//
// The check is the simplest one there is: hold a known DC level on the DOC
// inputs, wait for samples, and see what comes out.  A box average of a
// constant is that constant, so the expected answer is arithmetic, not taste:
// smp = doc / 32 * (WINDOW * K_DOC / 2^22), and with the 44.1 kHz window of
// 2268 clocks and K_DOC = 1856 that is doc/32 to within a part in 300.
module audio_doc_tb;

    logic clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    logic rst = 1'b1, enable = 1'b0;
    logic [31:0] rate_inc;
    logic spk = 1'b0;
    logic [39:0] ay_out = 40'd0;
    logic signed [20:0] doc_l = 21'sd0, doc_r = 21'sd0;
    wire smp_valid;
    wire [15:0] smp_spk, smp_doc_l, smp_doc_r;
    wire [63:0] smp_ay;

    // AUDIO_RATE: the phase step that makes 44100 Hz from 100 MHz, as
    // rtl/wb_regfile.sv's AUDIO_RATE holds it - 44100 / 100e6 * 2^32.
    localparam [31:0] RATE_44K1 = 32'd1894292;

    audio_sampler u_smp (
        .clk (clk), .rst (rst), .enable (enable), .rate_inc (rate_inc),
        .spk (spk), .ay_out (ay_out),
        .doc_l (doc_l), .doc_r (doc_r),
        .smp_valid (smp_valid), .smp_spk (smp_spk), .smp_ay (smp_ay),
        .smp_doc_l (smp_doc_l), .smp_doc_r (smp_doc_r)
    );

    int errors = 0, checks = 0;

    task automatic expect_near(input string what, input int got, input int want,
                               input int tol);
        begin
            checks++;
            if ((got > want + tol) || (got < want - tol)) begin
                $display("FAIL: %s = %0d, expected about %0d (+/- %0d)", what, got, want, tol);
                errors++;
            end else begin
                $display("ok: %s = %0d (expected about %0d)", what, got, want);
            end
        end
    endtask

    // Wait for n samples to be produced, then read the outputs.
    task automatic wait_samples(input int n);
        int seen = 0;
        begin
            while (seen < n) begin
                @(posedge clk);
                if (smp_valid) seen++;
            end
        end
    endtask

    int signed got_l, got_r;

    initial begin
        rate_inc = RATE_44K1;
        repeat (8) @(posedge clk);
        rst = 1'b0;
        enable = 1'b1;

        // ---- 1: silence in, silence out ------------------------------------
        doc_l = 21'sd0; doc_r = 21'sd0;
        wait_samples(4);
        checks++;
        if (smp_doc_l != 0 || smp_doc_r != 0) begin
            $display("FAIL: silence in gave L %0d R %0d", $signed(smp_doc_l), $signed(smp_doc_r));
            errors++;
        end else $display("ok: silence in, silence out");

        // ---- 2: a positive DC level ----------------------------------------
        // 32000 is about the peak one loud oscillator reaches; doc/32 = 1000.
        doc_l = 21'sd32000; doc_r = 21'sd16000;
        wait_samples(6);
        got_l = $signed(smp_doc_l); got_r = $signed(smp_doc_r);
        expect_near("smp_doc_l for doc_l = 32000", got_l, 1000, 40);
        expect_near("smp_doc_r for doc_r = 16000", got_r, 500, 40);

        // ---- 3: a negative DC level ----------------------------------------
        // The pair is SIGNED and centred on zero, so the negative half has to
        // survive the [20:5] slice, the accumulator and the shift alike.
        doc_l = -21'sd32000; doc_r = -21'sd16000;
        wait_samples(6);
        got_l = $signed(smp_doc_l); got_r = $signed(smp_doc_r);
        expect_near("smp_doc_l for doc_l = -32000", got_l, -1000, 40);
        expect_near("smp_doc_r for doc_r = -16000", got_r, -500, 40);

        // ---- 4: the full-scale corner --------------------------------------
        // The DOC's own range is +/- 2^20; a mix that big must not wrap.
        doc_l = 21'sd1000000; doc_r = -21'sd1000000;
        wait_samples(6);
        got_l = $signed(smp_doc_l); got_r = $signed(smp_doc_r);
        expect_near("smp_doc_l for doc_l = 1000000", got_l, 31250, 1600);
        expect_near("smp_doc_r for doc_r = -1000000", got_r, -31250, 1600);

        $display("");
        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAILED");
        $finish;
    end

endmodule
