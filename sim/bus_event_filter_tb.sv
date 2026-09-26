`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// bus_event_filter_tb - the sparse capture's keep rule and its SKIP words.
//
// A scripted stream of events - reads and writes, in and out of $Cxxx, the
// blanking level and RES' moving - through the filter in both modes, with a
// small CAP so the lone SKIP is reachable; then the filter chained into the
// real bus_event_capture, decoded as the host decodes it, to see the SKIP,
// the VBL_MARK notice and the marked event arrive in that order.
//
// The checks: full mode passes everything unchanged, in order, marks and
// all; sparse keeps exactly the rule and nothing else; a SKIP precedes its
// event with the right count and the mark stays on the event; the cap
// emits a SKIP of CAP on its own; the counts and the kept events add up to
// every cycle that went in; no two words leave on consecutive clocks
// except a SKIP and its event; disable drops the count and re-enable keeps
// the first event again.
//////////////////////////////////////////////////////////////////////////////////

module bus_event_filter_tb;

    localparam integer CAP = 16;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg         enable = 1'b0, sparse = 1'b0, virt = 1'b0, in_carrier = 1'b0;
    reg  [15:0] in_drop = 16'd0;
    reg  [63:0] in_data = 64'd0;
    reg         in_valid = 1'b0, in_mark = 1'b0, in_dummy = 1'b0;
    reg  [15:0] in_mark_free = 16'd0;
    wire [63:0] out_data;
    wire        out_valid, out_mark;
    wire [15:0] out_mark_free;

    bus_event_filter #(.CAP (CAP)) dut (
        .clk (clk), .rst (rst), .enable (enable), .sparse (sparse),
        .in_data (in_data), .in_valid (in_valid), .in_mark (in_mark), .in_mark_free (in_mark_free),
        .in_dummy (in_dummy), .virt (virt), .in_drop (in_drop), .in_carrier (in_carrier),
        .out_data (out_data), .out_valid (out_valid), .out_mark (out_mark), .out_mark_free (out_mark_free)
    );

    // ---- the record of what came out --------------------------------------------
    reg  [63:0] got      [0:4095];
    reg         got_mark [0:4095];
    reg  [15:0] got_free [0:4095];
    integer     got_n = 0;
    integer     last_out_clk = -10, consecutive = 0, consecutive_bad = 0;
    integer     clk_n = 0;
    always @(posedge clk) begin
        clk_n = clk_n + 1;
        if (out_valid) begin
            got[got_n]      = out_data;
            got_mark[got_n] = out_mark;
            got_free[got_n] = out_mark_free;
            if (clk_n == last_out_clk + 1) begin
                consecutive = consecutive + 1;
                // Only a SKIP may be followed on the next clock, and only
                // by an event - a cycle's or a fast op's.
                if (got[got_n - 1][31:28] != 4'hD || (out_data[31:28] != 4'hF && out_data[31:28] != 4'hC))
                    consecutive_bad = consecutive_bad + 1;
            end
            last_out_clk = clk_n;
            got_n = got_n + 1;
        end
    end

    // ---- the stream ---------------------------------------------------------------
    reg  [63:0] sent   [0:4095];
    integer     sent_n = 0;
    integer     cycles = 0;
    reg         cur_vbl = 1'b0, cur_res = 1'b1;

    // The 64-bit record (docs/PROTOCOL.md): word 1 {data, class, cpu, spare}
    // above word 0 {tag, bank, flags, addr}.
    function [63:0] ev(input [15:0] addr, input rw, input [7:0] data, input vbl, input res);
        ev = {data, 4'd0, 4'd0, 16'd0, 4'hF, 8'd0, vbl, 1'b0, res, rw, addr};
    endfunction

    // One bus cycle: the event, one clock wide, then three quiet clocks -
    // closer than the hardware ever puts them, far enough for the module's
    // contract.
    task cycle(input [15:0] addr, input rw, input [7:0] data, input mark);
        begin
            @(negedge clk);
            in_data      = ev(addr, rw, data, cur_vbl, cur_res);
            in_valid     = 1'b1;
            in_mark      = mark;
            in_mark_free = mark ? 16'hA501 : 16'd0;
            sent[sent_n] = in_data;
            sent_n = sent_n + 1;
            cycles = cycles + 1;
            @(negedge clk);
            in_valid = 1'b0;
            in_mark  = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    // A dummy cycle: the parked read, flagged.  A cycle, so it counts.
    task dummy;
        begin
            @(negedge clk);
            in_data  = ev(16'h0000, 1'b1, 8'h00, cur_vbl, cur_res);
            in_valid = 1'b1; in_dummy = 1'b1;
            sent[sent_n] = in_data; sent_n = sent_n + 1;
            cycles = cycles + 1;
            @(negedge clk);
            in_valid = 1'b0; in_dummy = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask
    // A fast op's word: tag 0xC, the current levels.  Not a cycle.
    function [63:0] fw(input [15:0] addr, input rw, input [7:0] data);
        fw = {data, 4'd1, 4'd0, 16'd0, 4'hC, 8'd0, cur_vbl, 1'b0, cur_res, rw, addr};
    endfunction
    task fast(input [15:0] addr, input rw, input [7:0] data);
        begin
            @(negedge clk);
            in_data  = fw(addr, rw, data);
            in_valid = 1'b1;
            sent[sent_n] = in_data; sent_n = sent_n + 1;
            @(negedge clk);
            in_valid = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    // A fast op's word carrying a mark (rtl/vbeam.sv's, in the virtual base).
    task fastm(input [15:0] addr);
        begin
            @(negedge clk);
            in_data  = fw(addr, 1'b1, 8'h33);
            in_valid = 1'b1; in_mark = 1'b1; in_mark_free = 16'hA503;
            sent[sent_n] = in_data; sent_n = sent_n + 1;
            @(negedge clk);
            in_valid = 1'b0; in_mark = 1'b0; in_mark_free = 16'd0;
            repeat (2) @(negedge clk);
        end
    endtask
    // A fast op's word carrying the merge's count of dropped cycles before it.
    task fast_d(input [15:0] addr, input rw, input [7:0] data, input [15:0] ndrop);
        begin
            @(negedge clk);
            in_data  = fw(addr, rw, data); in_drop = ndrop;
            in_valid = 1'b1;
            sent[sent_n] = in_data; sent_n = sent_n + 1;
            @(negedge clk);
            in_valid = 1'b0; in_drop = 16'd0;
            repeat (2) @(negedge clk);
        end
    endtask
    // A carrier: a count with no word.
    task carrier_d(input [15:0] ndrop);
        begin
            @(negedge clk);
            in_data = 64'd0; in_drop = ndrop; in_carrier = 1'b1; in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0; in_carrier = 1'b0; in_drop = 16'd0;
            repeat (2) @(negedge clk);
        end
    endtask
    task rd(input [15:0] addr);  begin cycle(addr, 1'b1, 8'h5A, 1'b0); end endtask
    task wr(input [15:0] addr);  begin cycle(addr, 1'b0, 8'hA5, 1'b0); end endtask
    task settle;                 begin repeat (8) @(negedge clk); end endtask

    integer errors = 0;
    task fail(input string what);
        begin $display("FAIL: %0s", what); errors = errors + 1; end
    endtask

    // Kept events and skipped cycles in the record: do they add up?
    function integer skipped_total;
        integer i;
        begin
            skipped_total = 0;
            for (i = 0; i < got_n; i = i + 1)
                if (got[i][31:28] == 4'hD) skipped_total = skipped_total + got[i][27:0];
        end
    endfunction
    function integer kept_total;
        integer i;
        begin
            kept_total = 0;
            for (i = 0; i < got_n; i = i + 1)
                if (got[i][31:28] == 4'hF) kept_total = kept_total + 1;
        end
    endfunction

    task reset_record;
        begin got_n = 0; sent_n = 0; cycles = 0; consecutive = 0; consecutive_bad = 0; last_out_clk = -10; end
    endtask

    integer i, bad, n_c, n_w, n_r;

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        // --- case 1 / full mode: everything through, in order, marks on ------------
        $display("case 1: full mode is a wire");
        enable = 1'b1; sparse = 1'b0;
        reset_record;
        rd(16'h0300); wr(16'h0400); rd(16'hC000); cur_vbl = 1'b1; rd(16'h0301);
        cycle(16'h0302, 1'b1, 8'h11, 1'b1);   // a marked read
        cur_vbl = 1'b0; rd(16'h0303); cur_res = 1'b0; rd(16'hFFFC); cur_res = 1'b1; rd(16'h0304);
        settle;
        if (got_n != sent_n) fail("case 1: word count differs");
        bad = 0;
        for (i = 0; i < sent_n && i < got_n; i = i + 1) begin
            if (got[i] !== sent[i]) bad = bad + 1;
            if (got_mark[i] !== (i == 4)) bad = bad + 1;
            if (i == 4 && got_free[i] !== 16'hA501) bad = bad + 1;
        end
        if (bad != 0) fail("case 1: words or marks differ");
        if (consecutive != 0) fail("case 1: two words on consecutive clocks");
        else $display("  ok: %0d events through unchanged, the mark on the fifth, none adjacent", got_n);

        // --- case 2 / sparse: the rule ---------------------------------------------
        $display("case 2: sparse keeps the rule and counts the rest");
        enable = 1'b0; settle; sparse = 1'b1; enable = 1'b1; @(negedge clk);
        reset_record;
        rd(16'h0300);                       // first: kept
        rd(16'h0301); rd(16'h0302);         // dropped: 2
        wr(16'h0400);                       // kept, SKIP 2 first
        rd(16'hC000);                       // kept ($Cxxx read)
        rd(16'hCFFF);                       // kept
        rd(16'h0303); rd(16'hBFFF);         // dropped: 2
        wr(16'hC055);                       // kept, SKIP 2 first
        rd(16'h0304);                       // dropped: 1
        cur_vbl = 1'b1; rd(16'h0305);       // kept: blanking begins, SKIP 1 first
        rd(16'h0306);                       // dropped
        cur_vbl = 1'b0; cycle(16'h0307, 1'b1, 8'h22, 1'b1);   // kept, marked: the origin, SKIP 1 first
        rd(16'h0308);                       // dropped
        cur_res = 1'b0; rd(16'hFFFC);       // kept: RES' fell, SKIP 1 first
        rd(16'hFFFD);                       // dropped (still in reset, no change)
        cur_res = 1'b1; rd(16'hF000);       // kept: RES' rose, SKIP 1 first
        settle;
        // Expected out: E0 S2 W400 C000 CFFF S2 WC055 S1 E305 S1 E307(mark) S1 FFFC S1 F000
        if (got_n != 15) fail("case 2: expected 15 words out");
        else begin
            bad = 0;
            if (got[0] !== sent[0]) bad = bad + 1;
            if (got[1] !== {32'd0, 4'hD, 28'd2}) bad = bad + 1;
            if (got[2] !== sent[3]) bad = bad + 1;
            if (got[3] !== sent[4] || got[4] !== sent[5]) bad = bad + 1;
            if (got[5] !== {32'd0, 4'hD, 28'd2} || got[6] !== sent[8]) bad = bad + 1;
            if (got[7] !== {32'd0, 4'hD, 28'd1} || got[8] !== sent[10]) bad = bad + 1;
            if (got[9] !== {32'd0, 4'hD, 28'd1} || got[10] !== sent[12]) bad = bad + 1;
            if (got_mark[10] !== 1'b1 || got_free[10] !== 16'hA501) bad = bad + 1;
            if (got_mark[9] !== 1'b0) bad = bad + 1;
            if (got[11] !== {32'd0, 4'hD, 28'd1} || got[12] !== sent[14]) bad = bad + 1;
            if (got[13] !== {32'd0, 4'hD, 28'd1} || got[14] !== sent[16]) bad = bad + 1;
            for (i = 0; i < got_n; i = i + 1) if (got_mark[i] && i != 10) bad = bad + 1;
            if (bad != 0) fail("case 2: the words out are not the expected ones");
            else $display("  ok: first, writes, $Cxxx, both blanking edges and both RES' edges kept, each behind its SKIP; the mark on the origin");
        end
        if (skipped_total() + kept_total() != cycles) fail("case 2: skipped + kept != cycles");
        else $display("  ok: %0d skipped + %0d kept = %0d cycles", skipped_total(), kept_total(), cycles);
        if (consecutive_bad != 0) fail("case 2: a word other than an event followed a SKIP on the next clock");
        else $display("  ok: %0d SKIP/event pairs on adjacent clocks, nothing else adjacent", consecutive);

        // --- case 3 / the cap -------------------------------------------------------
        $display("case 3: a run of unsent cycles is flushed at CAP");
        reset_record;
        for (i = 0; i < CAP * 2 + 5; i = i + 1) rd(16'h0300 + i[15:0]);
        wr(16'h0400);
        settle;
        if (got_n != 4) fail("case 3: expected SKIP CAP, SKIP CAP, SKIP 5, event");
        else begin
            if (got[0] !== {32'd0, 4'hD, 28'(CAP)} || got[1] !== {32'd0, 4'hD, 28'(CAP)} || got[2] !== {32'd0, 4'hD, 28'd5} || got[3] !== sent[sent_n - 1])
                fail("case 3: wrong words");
            else $display("  ok: SKIP %0d, SKIP %0d, SKIP 5, then the write", CAP, CAP);
        end
        if (skipped_total() + kept_total() != cycles) fail("case 3: skipped + kept != cycles");

        // --- case 4 / disable drops the count; re-enable keeps the first ------------
        $display("case 4: disable drops the pending count, re-enable starts with a kept event");
        reset_record;
        rd(16'h0300); rd(16'h0301);         // wait: the capture was on since case 3, no 'first' - these are dropped
        enable = 1'b0;
        settle;
        if (got_n != 0) fail("case 4: something left at disable");
        enable = 1'b1; @(negedge clk);
        reset_record;
        rd(16'h0300);                       // first after enable: kept, no SKIP
        rd(16'h0301);
        wr(16'h0400);
        settle;
        if (got_n != 3 || got[0] !== sent[0] || got[1] !== {32'd0, 4'hD, 28'd1} || got[2] !== sent[2])
            fail("case 4: expected the first read, SKIP 1, the write");
        else $display("  ok: the first event after enable is kept and the dropped count did not carry over");

        // --- case 5 / a long full-mode run is byte-exact -------------------------------
        $display("case 5: full mode over a long mixed run");
        enable = 1'b0; settle; sparse = 1'b0; enable = 1'b1; @(negedge clk);
        reset_record;
        for (i = 0; i < 300; i = i + 1) begin
            if (i % 7 == 0) wr(16'h2000 + i[15:0]); else rd(16'h0300 + i[15:0]);
            if (i % 50 == 25) cur_vbl = ~cur_vbl;
        end
        settle;
        bad = 0;
        for (i = 0; i < sent_n; i = i + 1) if (got[i] !== sent[i]) bad = bad + 1;
        if (got_n != sent_n || bad != 0) fail("case 5: full mode changed something");
        else $display("  ok: %0d words, unchanged", got_n);

        // --- case 6 / chained into the capture: SKIP, VBL_MARK, the origin --------------
        $display("case 6: through bus_event_capture - the cut lands between the SKIP and the marked event");
        run_chain;

        // --- case 7 / accelerated, full mode: dummies counted unless an edge, fast words through
        $display("case 7: full mode under acceleration - dummies become SKIPs, fast words pass, edges survive");
        enable = 1'b0; settle; sparse = 1'b0; enable = 1'b1; @(negedge clk);
        reset_record;
        dummy();                              // first after enable: kept, as the $0000 read
        dummy(); dummy();                     // counted: 2
        fast(16'h1000, 1'b1, 8'h11);          // kept, SKIP 2 first; not a cycle
        fast(16'h1001, 1'b0, 8'h22);          // kept
        dummy();                              // counted: 1
        cur_vbl = 1'b1; dummy();              // blanking begins on a dummy: kept, SKIP 1 first
        dummy();                              // counted: 1
        rd(16'h0300);                         // an ordinary cycle, full mode: kept, SKIP 1 first
        cur_vbl = 1'b0;
        fast(16'h1002, 1'b1, 8'h33);          // carries the new level; kept, and must not eat the edge
        dummy();                              // the cycle the level changed on: kept
        cur_res = 1'b0; dummy();              // RES' fell on a dummy: kept
        cur_res = 1'b1; dummy();              // ...and rose: kept
        wr(16'h0400);                         // kept
        settle;
        // Expected: D S2 F F S1 D S1 E F D D D W = 13 words
        if (got_n != 13) fail($sformatf("case 7: expected 13 words out, got %0d", got_n));
        else begin
            bad = 0;
            if (got[0] !== sent[0]) bad = bad + 1;                        // first dummy, kept
            if (got[1] !== {32'd0, 4'hD, 28'd2}) bad = bad + 1;
            if (got[2] !== sent[3] || got[3] !== sent[4]) bad = bad + 1;  // the fast words
            if (got[4] !== {32'd0, 4'hD, 28'd1} || got[5] !== sent[6]) bad = bad + 1;   // the blanking edge, on a dummy
            if (got[6] !== {32'd0, 4'hD, 28'd1} || got[7] !== sent[8]) bad = bad + 1;   // the ordinary cycle
            if (got[8] !== sent[9]) bad = bad + 1;                        // the fast word with the new level
            if (got[9] !== sent[10]) bad = bad + 1;                       // the dummy on which the level changed: kept, no SKIP
            if (got[10] !== sent[11] || got[11] !== sent[12]) bad = bad + 1;  // RES' edges on dummies
            if (got[12] !== sent[13]) bad = bad + 1;
            if (bad != 0) fail("case 7: the words out are not the expected ones");
            else $display("  ok: dummies counted, kept on the first cycle and on every edge; fast words pass and leave the edge to the cycle");
        end
        if (skipped_total() + kept_total() != cycles) fail($sformatf("case 7: skipped %0d + kept %0d != %0d cycles", skipped_total(), kept_total(), cycles));
        else $display("  ok: %0d skipped + %0d kept = %0d cycles; the %0d fast words are not cycles", skipped_total(), kept_total(), cycles, 3);
        if (consecutive_bad != 0) fail("case 7: bad adjacency");

        // --- case 8 / accelerated, sparse, the real base: a fast word is kept (the
        // merge's door already dropped the reads, case 9b) and is not a cycle ----
        $display("case 8: sparse under acceleration, the real base");
        enable = 1'b0; settle; sparse = 1'b1; enable = 1'b1; @(negedge clk);
        reset_record;
        dummy();                              // first: kept
        fast(16'h1001, 1'b0, 8'h22);          // a fast write: kept, not a cycle
        dummy(); dummy(); dummy();            // counted: 3
        wr(16'h0400);                         // kept, SKIP 3 first
        rd(16'h0300);                         // an ordinary RAM read: counted 1
        cur_vbl = 1'b1;
        rd(16'h0301);                         // the edge's cycle: kept, SKIP 1 first
        settle;
        if (got_n != 6) fail($sformatf("case 8: expected 6 words out, got %0d", got_n));
        else begin
            bad = 0;
            if (got[0] !== sent[0]) bad = bad + 1;
            if (got[1] !== sent[1]) bad = bad + 1;
            if (got[2] !== {32'd0, 4'hD, 28'd3} || got[3] !== sent[5]) bad = bad + 1;
            if (got[4] !== {32'd0, 4'hD, 28'd1} || got[5] !== sent[7]) bad = bad + 1;
            if (bad != 0) fail("case 8: the words out are not the expected ones");
            else $display("  ok: a fast write is kept and not a cycle, the edge stays with its cycle");
        end
        if (skipped_total() + kept_total() != cycles) fail("case 8: skipped + kept != cycles");

        // --- case 10 / the virtual base: the core's cycles are the cycles --------
        $display("case 10: the virtual base counts the door's drops in order, not dummies");
        enable = 1'b0; settle; sparse = 1'b1; virt = 1'b1; cur_vbl = 1'b0; cur_res = 1'b1; enable = 1'b1; @(negedge clk);
        reset_record;
        rd(16'h0300);                                   // first: kept          sent[0]
        dummy; dummy;                                   // not cycles here       sent[1..2]
        fast_d(16'h2000, 1'b0, 8'h44, 16'd3);           // kept, 3 dropped reads before it: SKIP 3 first   sent[3]
        fast_d(16'hC054, 1'b1, 8'hA0, 16'd2);           // kept (a switch read), SKIP 2 first   sent[4]
        cur_vbl = 1'b1; fast_d(16'h1004, 1'b1, 8'h06, 16'd1);   // kept: an edge on a fast word, SKIP 1 first   sent[5]
        fastm(16'h1005);                                // kept, marked          sent[6]
        carrier_d(16'd7);                               // a count with no word: 7
        rd(16'h0301);                                   // dropped, counted: 1   sent[7]
        dummy;                                          // not a cycle           sent[8]
        wr(16'h0400);                                   // kept, SKIP 8 first    sent[9]
        settle;
        // Expected out: E300 S3 W2000 S2 C054 S1 F1004 F1005(mark) S8 W400
        if (got_n != 10) fail($sformatf("case 10: expected 10 words out, got %0d", got_n));
        else begin
            bad = 0;
            if (got[0] !== sent[0]) bad = bad + 1;
            if (got[1] !== {32'd0, 4'hD, 28'd3} || got[2] !== sent[3]) bad = bad + 1;
            if (got[3] !== {32'd0, 4'hD, 28'd2} || got[4] !== sent[4]) bad = bad + 1;
            if (got[5] !== {32'd0, 4'hD, 28'd1} || got[6] !== sent[5]) bad = bad + 1;
            if (got[7] !== sent[6] || got_mark[7] !== 1'b1 || got_free[7] !== 16'hA503) bad = bad + 1;
            if (got[8] !== {32'd0, 4'hD, 28'd8} || got[9] !== sent[9]) bad = bad + 1;
            for (i = 0; i < got_n; i = i + 1) if (got_mark[i] && i != 7) bad = bad + 1;
            if (bad != 0) begin
                fail("case 10: the words out are not the expected ones");
                for (i = 0; i < got_n; i = i + 1) $display("    got[%0d] = %016x mark %0d", i, got[i], got_mark[i]);
            end else $display("  ok: the door's counts and a carrier into the SKIPs, dummies dropped uncounted, the switch read, the edge and the mark on fast words");
        end
        if (consecutive_bad != 0) fail("case 10: a word other than an event followed a SKIP on the next clock");
        virt = 1'b0; enable = 1'b0; settle;


        // --- case 9 / the merge in front of the filter ------------------------------------
        $display("case 9: event_merge - order, spacing, the same-clock collision, the dummy flag");
        run_merge;
        $display("case 9b: the merge's door in the virtual base");
        run_door;

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // ---- case 6: the filter into the real capture --------------------------------
    // A second filter and a capture, with a decoder that records every word
    // that leaves the arbiter port in order.
    reg         c_enable = 1'b0;
    reg  [63:0] c_in_data = 64'd0;
    reg         c_in_valid = 1'b0, c_in_mark = 1'b0;
    wire [63:0] f_data;
    wire        f_valid, f_mark;
    wire [15:0] f_free;
    wire [31:0] tx_data;
    wire        tx_valid;
    wire        overflow;
    wire [31:0] captured;

    bus_event_filter #(.CAP (CAP)) dut2 (
        .clk (clk), .rst (rst), .enable (c_enable), .sparse (1'b1),
        .in_data (c_in_data), .in_valid (c_in_valid), .in_mark (c_in_mark), .in_mark_free (16'h0700),
        .in_dummy (1'b0), .virt (1'b0), .in_drop (16'd0), .in_carrier (1'b0),
        .out_data (f_data), .out_valid (f_valid), .out_mark (f_mark), .out_mark_free (f_free)
    );
    bus_event_capture #(.DEPTH (64), .FRAME_EVENTS (8), .FLUSH_TICKS (200)) cap (
        .clk (clk), .rst (rst), .enable (c_enable), .status_req (1'b0),
        .ev_data (f_data), .ev_valid (f_valid), .ev_mark (f_mark), .ev_mark_free (f_free),
        .tx_data (tx_data), .tx_valid (tx_valid), .tx_take (1'b1),
        .overflow (overflow), .captured (captured)
    );
    reg  [31:0] wire_seq [0:1023];
    integer     wire_n = 0;
    always @(posedge clk) if (!rst && tx_valid) begin wire_seq[wire_n] = tx_data; wire_n = wire_n + 1; end

    task c_cycle(input [15:0] addr, input rw, input vbl, input mark);
        begin
            @(negedge clk);
            c_in_data  = {8'h33, 24'd0, 4'hF, 8'd0, vbl, 1'b0, 1'b1, rw, addr};
            c_in_valid = 1'b1;
            c_in_mark  = mark;
            @(negedge clk);
            c_in_valid = 1'b0; c_in_mark = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    integer k, at_origin, words_pushed;
    task run_chain;
        begin
            c_enable = 1'b1; @(negedge clk);
            c_cycle(16'h0300, 1'b1, 1'b0, 1'b0);     // first: kept
            for (k = 0; k < 5; k = k + 1) c_cycle(16'h0300, 1'b1, 1'b0, 1'b0);   // dropped: 5
            c_cycle(16'h0300, 1'b1, 1'b1, 1'b0);     // blanking begins: kept, SKIP 5
            for (k = 0; k < 3; k = k + 1) c_cycle(16'h0300, 1'b1, 1'b1, 1'b0);   // dropped: 3
            c_cycle(16'h0468, 1'b1, 1'b0, 1'b1);     // the origin, marked: kept, SKIP 3
            c_cycle(16'h0400, 1'b0, 1'b0, 1'b0);     // a write
            repeat (400) @(negedge clk);              // the flush timer
            // The marked event's index is 4 (E0, S5, E192, S3, MARKED, W):
            // the first message carries records 0..3, then VBL_MARK, then a
            // message with the marked event and the write.  Two words per
            // record on the wire, word 0 first; the SKIP's word 1 is zero.
            at_origin = -1;
            for (k = 0; k < wire_n; k = k + 1) if (wire_seq[k] == {4'hF, 8'd0, 1'b0, 1'b0, 1'b1, 1'b1, 16'h0468}) at_origin = k;
            if (at_origin < 6) fail("case 6: the marked event did not appear");
            else begin
                if (wire_seq[at_origin + 1] !== {8'h33, 24'd0}) fail("case 6: the marked event's second word is wrong");
                if (wire_seq[at_origin - 1][15:0] !== 16'h1204) fail("case 6: the marked event does not open a BUS_EVENTS message of 2 records (4 words)");
                if (wire_seq[at_origin - 2] !== {16'h0700, 8'h1D, 8'h00}) fail("case 6: no VBL_MARK notice before it");
                if (wire_seq[at_origin - 3] !== 32'd0) fail("case 6: the SKIP's second word is not zero");
                if (wire_seq[at_origin - 4] !== {32'd0, 4'hD, 28'd3}) fail("case 6: the SKIP 3 is not the last record before the notice");
                if (wire_seq[at_origin - 5] !== {8'h33, 24'd0}) fail("case 6: the blanking event's second word is wrong");
                if (wire_seq[at_origin - 6] !== {4'hF, 8'd0, 1'b1, 1'b0, 1'b1, 1'b1, 16'h0300}) fail("case 6: the blanking event is not before the SKIP");
                if (errors == 0) $display("  ok: on the wire: ... E(192,0), SKIP 3 | VBL_MARK | [BUS_EVENTS] E(0,0), W - two words a record");
            end
            words_pushed = 6;
            if (captured !== words_pushed) begin $display("FAIL: case 6: captured=%0d, expected %0d records", captured, words_pushed); errors = errors + 1; end
            else $display("  ok: captured counts records: %0d", captured);
            c_enable = 1'b0;
        end
    endtask

    // ---- case 9: the merge into the filter ----------------------------------------
    reg         m_enable = 1'b0;
    reg         m_bus_valid = 1'b0, m_bus_dummy = 1'b0, m_bus_mark = 1'b0;
    reg  [63:0] m_bus_data = 64'd0;
    reg         m_fast_valid = 1'b0, m_fast_rw = 1'b1, m_vbl = 1'b0;
    reg         m_sparse = 1'b0, m_virt = 1'b0, m_quiet = 1'b0, m_fmark = 1'b0;
    reg  [15:0] m_fast_addr = 16'd0;
    reg  [7:0]  m_fast_data = 8'd0;
    wire [63:0] m_data, m3_data;
    wire        m_valid, m_mark, m_dummy, m3_valid, m3_mark, m_carrier;
    wire [15:0] m_drop;
    wire [15:0] m_free, m3_free;
    wire [7:0]  m_overflows;

    event_merge #(.DEPTH (8)) mrg (
        .clk (clk), .rst (rst), .enable (m_enable),
        .bus_valid (m_bus_valid), .bus_data (m_bus_data), .bus_mark (m_bus_mark),
        .bus_mark_free (16'h0700), .bus_dummy (m_bus_dummy),
        .fast_valid (m_fast_valid), .fast_addr (m_fast_addr), .fast_bank (8'd0), .fast_rw (m_fast_rw),
        .fast_data (m_fast_data), .fast_sync (1'b0), .fast_mark (m_fmark), .fast_mark_free (16'hA503),
        .fast_quiet (m_quiet), .fast_force (1'b0), .eng_valid (1'b0), .eng_rec (64'd0), .eng_take (), .vbl_level (m_vbl), .res_level (1'b1), .sparse (m_sparse), .virt (m_virt),
        .out_valid (m_valid), .out_data (m_data), .out_mark (m_mark), .out_mark_free (m_free),
        .out_dummy (m_dummy), .out_drop (m_drop), .out_carrier (m_carrier), .overflows (m_overflows)
    );
    bus_event_filter #(.CAP (CAP)) dut3 (
        .clk (clk), .rst (rst), .enable (m_enable), .sparse (1'b0),
        .in_data (m_data), .in_valid (m_valid), .in_mark (m_mark), .in_mark_free (m_free),
        .in_dummy (m_dummy), .virt (1'b0), .in_drop (m_drop), .in_carrier (m_carrier),
        .out_data (m3_data), .out_valid (m3_valid), .out_mark (m3_mark), .out_mark_free (m3_free)
    );
    reg  [63:0] m_got [0:255];
    reg         m_got_mark [0:255];
    integer     m_got_n = 0, m_last_clk = -10, m_gap_bad = 0, m_in_clk = -10, m_in_gap_bad = 0, m_clk = 0;
    always @(posedge clk) begin
        m_clk = m_clk + 1;                  // this block's own clock: no race with clk_n
        if (m_valid) begin
            if (m_clk - m_in_clk < 3) m_in_gap_bad = m_in_gap_bad + 1;
            m_in_clk = m_clk;
        end
        if (m3_valid) begin
            m_got[m_got_n] = m3_data; m_got_mark[m_got_n] = m3_mark;
            if (m_clk == m_last_clk + 1 && !(m_got[m_got_n - 1][31:28] == 4'hD)) m_gap_bad = m_gap_bad + 1;
            m_last_clk = m_clk; m_got_n = m_got_n + 1;
        end
    end
    integer j;
    // The door (case 9b): the merge's own output recorded.
    reg  [63:0] d_data [0:31]; reg [15:0] d_drop [0:31]; reg d_carrier [0:31]; reg d_mark [0:31];
    integer     d_n = 0;
    always @(posedge clk) if (m_valid) begin
        d_data[d_n] = m_data; d_drop[d_n] = m_drop; d_carrier[d_n] = m_carrier; d_mark[d_n] = m_mark; d_n = d_n + 1;
    end
    task m_op(input [15:0] addr, input rw, input [7:0] data, input quiet, input mark);
        begin
            m_fast_valid = 1'b1; m_fast_addr = addr; m_fast_rw = rw; m_fast_data = data; m_quiet = quiet; m_fmark = mark;
            @(negedge clk);
            m_fast_valid = 1'b0; m_quiet = 1'b0; m_fmark = 1'b0;
            repeat (3) @(negedge clk);
        end
    endtask
    task run_door;
        begin
            m_enable = 1'b0; repeat (4) @(negedge clk);
            m_sparse = 1'b1; m_virt = 1'b1; m_vbl = 1'b0; d_n = 0;
            m_enable = 1'b1; repeat (2) @(negedge clk);
            m_op(16'h1000, 1'b1, 8'h11, 1'b0, 1'b0);    // a read: dropped, counted 1
            m_op(16'h1001, 1'b1, 8'h12, 1'b0, 1'b0);    // a read: dropped, counted 2
            m_op(16'h2000, 1'b0, 8'h44, 1'b0, 1'b0);    // a write: kept, carrying 2
            m_vbl = 1'b1;
            m_op(16'h1002, 1'b1, 8'h13, 1'b0, 1'b0);    // a read on the blanking edge: kept, carrying 0
            m_op(16'hC054, 1'b1, 8'hA0, 1'b1, 1'b0);    // a quiet switch read: dropped, counted 1
            m_op(16'hC055, 1'b1, 8'hA0, 1'b0, 1'b0);    // a switch read: kept, carrying 1
            m_op(16'h1003, 1'b1, 8'h14, 1'b0, 1'b1);    // a read at the origin, marked: kept, carrying 0
            repeat (30) @(negedge clk);
            if (d_n != 4) fail($sformatf("case 9b: expected 4 entries out of the door, got %0d", d_n));
            else begin
                bad = 0;
                if (d_data[0][15:0] !== 16'h2000 || d_drop[0] !== 16'd2 || d_carrier[0]) bad = bad + 1;
                if (d_data[1][15:0] !== 16'h1002 || d_drop[1] !== 16'd0 || d_data[1][19] !== 1'b1) bad = bad + 1;
                if (d_data[2][15:0] !== 16'hC055 || d_drop[2] !== 16'd1) bad = bad + 1;
                if (d_data[3][15:0] !== 16'h1003 || d_drop[3] !== 16'd0 || !d_mark[3]) bad = bad + 1;
                if (bad != 0) begin
                    fail("case 9b: the door's entries are not the expected ones");
                    for (j = 0; j < d_n; j = j + 1) $display("    entry %0d: %016x drop %0d carrier %0d mark %0d", j, d_data[j], d_drop[j], d_carrier[j], d_mark[j]);
                end else $display("  ok: the door drops the reads and a quiet switch read with their counts in order, keeps the write, the edge, the switch read and the mark");
            end
            if (m_overflows != 0) fail("case 9b: the merge overflowed");
            m_enable = 1'b0; m_sparse = 1'b0; m_virt = 1'b0;
        end
    endtask
    task run_merge;
        begin
            m_enable = 1'b1; repeat (2) @(negedge clk);
            // An ordinary cycle's event and a fast op on the SAME clock.
            m_bus_valid = 1'b1; m_bus_data = {8'h33, 24'd0, 4'hF, 8'd0, 1'b0, 1'b0, 1'b1, 1'b1, 16'h0300};
            m_fast_valid = 1'b1; m_fast_addr = 16'h1000; m_fast_rw = 1'b0; m_fast_data = 8'h44;
            @(negedge clk);
            m_bus_valid = 1'b0;
            // ...and four more fast ops on the clocks right after, closer than
            // the filter can take them.
            for (j = 1; j < 5; j = j + 1) begin
                m_fast_addr = 16'h1000 + j[15:0]; m_fast_data = 8'h44 + j[7:0];
                @(negedge clk);
            end
            m_fast_valid = 1'b0;
            repeat (30) @(negedge clk);
            // Then a dummy cycle, a fast op, a marked cycle.
            m_bus_valid = 1'b1; m_bus_dummy = 1'b1; m_bus_data = {8'h00, 24'd0, 4'hF, 8'd0, 1'b0, 1'b0, 1'b1, 1'b1, 16'h0000};
            @(negedge clk); m_bus_valid = 1'b0; m_bus_dummy = 1'b0;
            repeat (3) @(negedge clk);
            m_fast_valid = 1'b1; m_fast_addr = 16'h2000; m_fast_rw = 1'b1; m_fast_data = 8'h55; m_vbl = 1'b1;
            @(negedge clk); m_fast_valid = 1'b0;
            repeat (3) @(negedge clk);
            m_bus_valid = 1'b1; m_bus_mark = 1'b1; m_bus_data = {8'h33, 24'd0, 4'hF, 8'd0, 1'b1, 1'b0, 1'b1, 1'b1, 16'h0468};
            @(negedge clk); m_bus_valid = 1'b0; m_bus_mark = 1'b0;
            repeat (40) @(negedge clk);
            // Expected out of the filter: E300 F1000..F1004 S1(the dummy) F2000 E468(marked) = 9 words
            if (m_got_n != 9) fail($sformatf("case 9: expected 9 words, got %0d", m_got_n));
            else begin
                bad = 0;
                if (m_got[0] !== {8'h33, 24'd0, 4'hF, 8'd0, 1'b0, 1'b0, 1'b1, 1'b1, 16'h0300}) bad = bad + 1;
                for (j = 0; j < 5; j = j + 1)
                    if (m_got[1 + j] !== {8'h44 + j[7:0], 4'd1, 4'd0, 16'd0, 4'hC, 8'd0, 1'b0, 1'b0, 1'b1, 1'b0, 16'h1000 + j[15:0]}) bad = bad + 1;
                if (m_got[6] !== {32'd0, 4'hD, 28'd1}) bad = bad + 1;
                if (m_got[7] !== {8'h55, 4'd1, 4'd0, 16'd0, 4'hC, 8'd0, 1'b1, 1'b0, 1'b1, 1'b1, 16'h2000}) bad = bad + 1;
                if (m_got[8] !== {8'h33, 24'd0, 4'hF, 8'd0, 1'b1, 1'b0, 1'b1, 1'b1, 16'h0468} || !m_got_mark[8]) bad = bad + 1;
                for (j = 0; j < 8; j = j + 1) if (m_got_mark[j]) bad = bad + 1;
                if (bad != 0) fail("case 9: the words out are not the expected ones, in order");
                else $display("  ok: the bus's word first on a collision, the fast ops in order behind it, the dummy a SKIP, the mark on its cycle");
            end
            if (m_in_gap_bad != 0) fail($sformatf("case 9: %0d words left the merge closer than three clocks apart", m_in_gap_bad));
            else $display("  ok: never two words within three clocks");
            if (m_overflows != 0) fail("case 9: the merge overflowed");
            if (m_gap_bad != 0) fail("case 9: bad adjacency after the filter");
            m_enable = 1'b0;
        end
    endtask

    initial begin
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
