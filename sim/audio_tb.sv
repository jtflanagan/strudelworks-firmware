`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// audio_tb - the sound on the card, end to end (docs/AUDIO.md).
//
// A Mockingboard in slot 4 behind the real bus writer, every cycle carrying
// an op as sim/mockingboard_tb.sv does; the speaker flip-flop driven at its
// own door; the sampler and the framer behind them; a taker standing in for
// msg_master that swallows a word a clock and keeps the messages.
//
//   1. the NCO: 441 samples in 1 000 000 clocks at 44.1 kHz
//   2. the speaker: high all window = full scale, low = 0, a square wave
//      with one window's period = half
//   3. the AY: channel A at period 64 through real VIA writes (latch, write)
//      -> 996.5 Hz: 49.8 periods in 2205 samples, at a third of full scale
//   4. the time base: three fast ticks a cycle quadruple the tone in core
//      time and leave it alone in real time
//   5. the framing: every header {drops, 32, 0x2C, 128} - FOUR words a
//      sample since the Ensoniq - every sequence number
//      one more than the last
//   6. the drops: the taker stalls past the FIFO, the header's drops equal
//      the gap in the sequence, AUDIO_STAT agrees
//////////////////////////////////////////////////////////////////////////////////
module audio_tb;
    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;
    localparam integer CYCLE     = 98;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;               // 100 MHz

    integer errors = 0;
    task fail(input [8*96-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    // ---- phi0 and the bus writer, as mockingboard_tb has them -----------------
    localparam integer PHI0_LOW  = 49;
    localparam integer PHI0_HIGH = 49;
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end
    // One real-time tick a bus cycle: bus_tick, as apple_bus_read's data_tick.
    reg phi0_q = 0;
    always @(posedge clk) phi0_q <= phi0;
    wire bus_tick = phi0 && !phi0_q;

    reg  [15:0] cpu_addr = 16'h0000;
    reg         cpu_rw   = 1'b1;
    reg  [7:0]  cpu_dout = 8'h00;
    wire        cyc_en;
    wire [7:0]  cpu_din;
    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit;
    wire [7:0]  op_wdata;
    wire        rd_claim, drv_sync, addr_rw_oe, data_oe, dma_assert, driving, rw_drive;
    wire [7:0]  rd_data, data_drive;
    wire [15:0] addr_drive;
    wire [7:0]  data_sync = data_oe ? data_drive : 8'hEE;

    // Two cycle-enable edges, not one: an op set mid-cycle (after a wait on
    // samples) must not return before it was ever presented.
    task bus_op(input [15:0] addr, input rw, input [7:0] dout);
        begin
            cpu_addr = addr; cpu_rw = rw; cpu_dout = dout;
            @(posedge cyc_en);
            @(posedge cyc_en);
            @(posedge clk);
        end
    endtask
    task bus_write(input [15:0] addr, input [7:0] data);
        bus_op(addr, 1'b0, data);
    endtask
    task bus_read(input [15:0] addr);
        bus_op(addr, 1'b1, 8'h00);
    endtask

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0), .data_sync (data_sync),
        .master_active (1'b1), .park_kbd (1'b0),
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (1'b0), .drv_sync (drv_sync),
        .cyc_en (cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (rd_claim), .slot_rd_data (rd_data),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        .ovr_en (1'b0), .ovr_addr (16'h0000), .ovr_rw (1'b1), .ovr_wdata (8'h00), .op_ovr (), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the DUTs -----------------------------------------------------------
    reg         fast_tick   = 1'b0;
    reg         audio_on    = 1'b0;
    reg  [31:0] audio_rate  = 32'd1894081;
    wire [39:0] ay_out;
    wire        mb_irq;

    reg res_sync = 1'b0;
    mockingboard u_mb (
        .clk (clk), .rst (rst),
        .res_sync (res_sync),
        .master_active (1'b1),
        .slot_assign (3'd4), .phasor (1'b0),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .op_dummy (1'b0), .fast_tick (fast_tick),
        .bus_tick (bus_tick), .ay_out (ay_out),
        .rd_claim (rd_claim), .rd_data (rd_data),
        .irq (mb_irq)
    );

    reg         spk_hit = 1'b0;       // one clock: a $C030 access at the speaker's door
    wire        spk_level, spk_toggle;
    speaker u_spk (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .real_valid (spk_hit), .real_dummy (1'b0), .real_addr (16'hC030),
        .fast_valid (1'b0), .fast_addr (16'h0000),
        .level (spk_level), .toggle (spk_toggle)
    );

    wire        smp_valid;
    wire [15:0] smp_spk;
    wire [63:0] smp_ay;
    audio_sampler u_smp (
        .clk (clk), .rst (rst), .enable (audio_on), .rate_inc (audio_rate),
        .spk (spk_level), .ay_out (ay_out),
        .smp_valid (smp_valid), .smp_spk (smp_spk), .smp_ay (smp_ay)
    );

    wire [31:0] au_word, au_stat;
    wire        au_valid;
    reg         take_en = 1'b1;
    wire        au_take = au_valid && take_en;
    audio_tx u_atx (
        .clk (clk), .rst (rst), .enable (audio_on),
        .smp_valid (smp_valid), .smp_spk (smp_spk), .smp_ay (smp_ay),
        .word (au_word), .valid (au_valid), .take (au_take),
        .stat (au_stat)
    );

    // ---- the taker: messages as the host would see them ---------------------
    integer     msgs = 0, msg_errs = 0, seq_errs = 0, seq_gaps = 0;
    integer     in_body = 0, body_left = 0, widx = 0;
    reg [31:0]  last_hdr;
    reg [15:0]  last_seq = 16'hFFFF;
    reg         have_seq = 1'b0;
    reg [15:0]  gap_at_seq;
    integer     gap_size = 0;
    always @(posedge clk) begin
        if (au_take) begin
            if (!in_body) begin
                last_hdr <= au_word;
                // FOUR words a sample since the Ensoniq (docs/GS.md rung 7),
                // so a 32-sample message is 128 words, not 96.
                if (au_word[15:8] !== 8'h2C || au_word[7:0] !== 8'd128 || au_word[23:16] !== 8'd32) begin
                    msg_errs = msg_errs + 1;
                    $display("bad header %08x", au_word);
                end
                in_body = 1; body_left = 128; widx = 0; msgs = msgs + 1;
            end else begin
                // The sequence number moved into the fourth word when the
                // Ensoniq's stereo pair took the third.
                if (widx % 4 == 3) begin
                    if (have_seq && au_word[31:16] !== last_seq + 16'd1) begin
                        seq_gaps = seq_gaps + 1;
                        gap_at_seq = last_seq;
                        gap_size = (au_word[31:16] - last_seq - 16'd1) & 16'hFFFF;
                    end
                    last_seq = au_word[31:16];
                    have_seq = 1'b1;
                end
                widx = widx + 1;
                body_left = body_left - 1;
                if (body_left == 0) in_body = 0;
            end
        end
    end

    // ---- sample watchers -------------------------------------------------------
    integer     nsmp = 0;
    reg [15:0]  last_spk, last_ay0;
    reg         ay_high_q = 1'b0;
    integer     ay_edges = 0;
    reg [15:0]  ay_max = 16'd0;
    always @(posedge clk) if (smp_valid) begin
        nsmp = nsmp + 1;
        last_spk = smp_spk;
        last_ay0 = smp_ay[15:0];
        if (smp_ay[15:0] > ay_max) ay_max = smp_ay[15:0];
        if (smp_ay[15:0] > 16'd5000 && !ay_high_q) ay_edges = ay_edges + 1;
        ay_high_q = (smp_ay[15:0] > 16'd5000);
    end

    task wait_samples(input integer n);
        integer target;
        begin
            target = nsmp + n;
            while (nsmp < target) @(posedge clk);
        end
    endtask

    // The Mockingboard's VIA 0 at $C400: ORB, ORA, DDRB, DDRA.  Port B's
    // bits: BC1 (0), BDIR (1), RESET' (2).  Latch = $07, write = $06, idle = $04.
    task ay_write(input [3:0] r, input [7:0] v);
        begin
            bus_write(16'hC401, {4'd0, r});
            bus_write(16'hC400, 8'h07);
            bus_write(16'hC400, 8'h04);
            bus_write(16'hC401, v);
            bus_write(16'hC400, 8'h06);
            bus_write(16'hC400, 8'h04);
        end
    endtask

    task spk_toggle_now;
        begin
            @(posedge clk); spk_hit <= 1'b1;
            @(posedge clk); spk_hit <= 1'b0;
        end
    endtask

    // Three fast ticks a bus cycle, spaced: the core at 4x in its own time.
    integer ft_ctr = 0;
    reg     ft_on = 1'b0;
    always @(posedge clk) begin
        ft_ctr <= (ft_ctr == CYCLE - 1) ? 0 : ft_ctr + 1;
        fast_tick <= ft_on && (ft_ctr == 20 || ft_ctr == 45 || ft_ctr == 70);
    end

    integer start_n, edges0, i, gap_expect;
    initial begin
        #100;
        rst = 0;
        repeat (10) @(posedge cyc_en);
        res_sync = 1'b1;                         // RES' released: the slot switches reset
        repeat (10) @(posedge cyc_en);
        bus_read(16'h0000);
        audio_on = 1'b1;
        repeat (3000) @(posedge clk);

        // 1. the NCO
        start_n = nsmp;
        repeat (1000000) @(posedge clk);
        if (nsmp - start_n < 440 || nsmp - start_n > 442)
            fail("NCO: not 441 samples in 1e6 clocks");
        else $display("  ok: NCO %0d samples in 1e6 clocks", nsmp - start_n);
        if (last_spk !== 16'd0 || last_ay0 !== 16'd0) fail("silence is not zero");

        // 2. the speaker
        spk_toggle_now;
        wait_samples(6);
        if (last_spk < 16'd32700) fail("speaker high all window is not full scale");
        else $display("  ok: speaker high = %0d", last_spk);
        spk_toggle_now;
        wait_samples(6);
        if (last_spk !== 16'd0) fail("speaker low is not zero");
        // a square wave with one window's period: 1134 clocks up, 1134 down
        for (i = 0; i < 40; i = i + 1) begin
            spk_toggle_now;
            repeat (1133) @(posedge clk);
        end
        if (last_spk < 16'd15000 || last_spk > 16'd18000) fail("speaker square at one window = not half");
        else $display("  ok: speaker square = %0d", last_spk);
        if (spk_level) spk_toggle_now;
        wait_samples(6);

        // 3. the AY: reset, DDR, channel A period 64 at volume 15, tone only
        bus_write(16'hC403, 8'hFF);
        bus_write(16'hC402, 8'hFF);
        bus_write(16'hC400, 8'h00);
        bus_write(16'hC400, 8'h04);
        ay_write(4'd0, 8'd64);
        ay_write(4'd1, 8'd0);
        ay_write(4'd7, 8'h3E);
        ay_write(4'd8, 8'h0F);
        bus_read(16'h0000);
        wait_samples(100);
        edges0 = ay_edges;
        wait_samples(2205);
        $display("  AY at 1x: %0d periods in 2205 samples (expect ~50), peak %0d (expect ~10924)", ay_edges - edges0, ay_max);
        if (ay_edges - edges0 < 48 || ay_edges - edges0 > 52) fail("AY tone period wrong in core time");
        if (ay_max < 16'd10500 || ay_max > 16'd11300) fail("AY peak not a third of full scale");

        // 4. the time base: the AYs run in real time whatever the core does
        // (rtl/mockingboard.sv, two sets of books) - a 4x core leaves the
        // pitch alone
        ft_on = 1'b1;
        wait_samples(100);
        edges0 = ay_edges;
        wait_samples(2205);
        $display("  AY real time at 4x: %0d periods (expect ~50)", ay_edges - edges0);
        if (ay_edges - edges0 < 48 || ay_edges - edges0 > 52) fail("AY tone did not hold in real time under a 4x core");
        ft_on = 1'b0;

        // 5. the framing so far
        if (msg_errs != 0) fail("bad headers");
        if (seq_gaps != 0) fail("sequence gap before the stall");
        else $display("  ok: %0d messages, sequence continuous", msgs);

        // 6. the drops: stall the taker past the FIFO
        take_en = 1'b0;
        repeat (600000) @(posedge clk);          // 6 ms: 264 samples into a 128-sample FIFO
        take_en = 1'b1;
        wait_samples(100);
        if (seq_gaps != 1) fail("expected exactly one sequence gap after the stall");
        else begin
            gap_expect = au_stat[23:16];
            $display("  stall: gap of %0d samples after seq %0d, drops %0d", gap_size, gap_at_seq, gap_expect);
            if (gap_size != gap_expect) fail("the header's drops and the sequence gap disagree");
            // 264 samples arrive and the FIFO holds 128 of them - DEPTH/4
            // since the Ensoniq took a fourth word, where it was DEPTH/3 -
            // so the excess is ~136.  The check that MATTERS is the one
            // above: the header's drops and the sequence gap agree.
            if (gap_size < 110 || gap_size > 175) fail("gap size not the stall's excess");
        end
        if (msg_errs != 0) fail("bad headers after the stall");

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
