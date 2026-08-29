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

    reg         enable = 1'b0, sparse = 1'b0;
    reg  [31:0] in_data = 32'd0;
    reg         in_valid = 1'b0, in_mark = 1'b0;
    reg  [15:0] in_mark_free = 16'd0;
    wire [31:0] out_data;
    wire        out_valid, out_mark;
    wire [15:0] out_mark_free;

    bus_event_filter #(.CAP (CAP)) dut (
        .clk (clk), .rst (rst), .enable (enable), .sparse (sparse),
        .in_data (in_data), .in_valid (in_valid), .in_mark (in_mark), .in_mark_free (in_mark_free),
        .out_data (out_data), .out_valid (out_valid), .out_mark (out_mark), .out_mark_free (out_mark_free)
    );

    // ---- the record of what came out --------------------------------------------
    reg  [31:0] got      [0:4095];
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
                // by an event.
                if (got[got_n - 1][31:28] != 4'hD || out_data[31:28] != 4'hF) consecutive_bad = consecutive_bad + 1;
            end
            last_out_clk = clk_n;
            got_n = got_n + 1;
        end
    end

    // ---- the stream ---------------------------------------------------------------
    reg  [31:0] sent   [0:4095];
    integer     sent_n = 0;
    integer     cycles = 0;
    reg         cur_vbl = 1'b0, cur_res = 1'b1;

    function [31:0] ev(input [15:0] addr, input rw, input [7:0] data, input vbl, input res);
        ev = {4'hF, data, vbl, 1'b0, res, rw, addr};
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

    task rd(input [15:0] addr);  begin cycle(addr, 1'b1, 8'h5A, 1'b0); end endtask
    task wr(input [15:0] addr);  begin cycle(addr, 1'b0, 8'hA5, 1'b0); end endtask
    task settle;                 begin repeat (8) @(negedge clk); end endtask

    integer errors = 0;
    task fail(input [8*80-1:0] what);
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
            if (got[1] !== {4'hD, 28'd2}) bad = bad + 1;
            if (got[2] !== sent[3]) bad = bad + 1;
            if (got[3] !== sent[4] || got[4] !== sent[5]) bad = bad + 1;
            if (got[5] !== {4'hD, 28'd2} || got[6] !== sent[8]) bad = bad + 1;
            if (got[7] !== {4'hD, 28'd1} || got[8] !== sent[10]) bad = bad + 1;
            if (got[9] !== {4'hD, 28'd1} || got[10] !== sent[12]) bad = bad + 1;
            if (got_mark[10] !== 1'b1 || got_free[10] !== 16'hA501) bad = bad + 1;
            if (got_mark[9] !== 1'b0) bad = bad + 1;
            if (got[11] !== {4'hD, 28'd1} || got[12] !== sent[14]) bad = bad + 1;
            if (got[13] !== {4'hD, 28'd1} || got[14] !== sent[16]) bad = bad + 1;
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
            if (got[0] !== {4'hD, 28'(CAP)} || got[1] !== {4'hD, 28'(CAP)} || got[2] !== {4'hD, 28'd5} || got[3] !== sent[sent_n - 1])
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
        if (got_n != 3 || got[0] !== sent[0] || got[1] !== {4'hD, 28'd1} || got[2] !== sent[2])
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

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // ---- case 6: the filter into the real capture --------------------------------
    // A second filter and a capture, with a decoder that records every word
    // that leaves the arbiter port in order.
    reg         c_enable = 1'b0;
    reg  [31:0] c_in_data = 32'd0;
    reg         c_in_valid = 1'b0, c_in_mark = 1'b0;
    wire [31:0] f_data;
    wire        f_valid, f_mark;
    wire [15:0] f_free;
    wire [31:0] tx_data;
    wire        tx_valid;
    wire        overflow;
    wire [31:0] captured;

    bus_event_filter #(.CAP (CAP)) dut2 (
        .clk (clk), .rst (rst), .enable (c_enable), .sparse (1'b1),
        .in_data (c_in_data), .in_valid (c_in_valid), .in_mark (c_in_mark), .in_mark_free (16'h0700),
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
            c_in_data  = {4'hF, 8'h33, vbl, 1'b0, 1'b1, rw, addr};
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
            // Expected wire: [BUS_EVENTS len 3] E0 S5 E192 S3  ... no: the cut.
            // The marked event's index is 4 (E0, S5, E192, S3, MARKED, W):
            // the first message carries words 0..3, then VBL_MARK, then a
            // message with the marked event and the write.
            at_origin = -1;
            for (k = 0; k < wire_n; k = k + 1) if (wire_seq[k] == {4'hF, 8'h33, 1'b0, 1'b0, 1'b1, 1'b1, 16'h0468}) at_origin = k;
            if (at_origin < 3) fail("case 6: the marked event did not appear");
            else begin
                if (wire_seq[at_origin - 1][15:0] !== 16'h1202) fail("case 6: the marked event does not open a BUS_EVENTS message of 2");
                if (wire_seq[at_origin - 2] !== {16'h0700, 8'h1D, 8'h00}) fail("case 6: no VBL_MARK notice before it");
                if (wire_seq[at_origin - 3] !== {4'hD, 28'd3}) fail("case 6: the SKIP 3 is not the last word before the notice");
                if (wire_seq[at_origin - 4] !== {4'hF, 8'h33, 1'b1, 1'b0, 1'b1, 1'b1, 16'h0300}) fail("case 6: the blanking event is not before the SKIP");
                if (errors == 0) $display("  ok: on the wire: ... E(192,0), SKIP 3 | VBL_MARK | [BUS_EVENTS] E(0,0), W");
            end
            words_pushed = 6;
            if (captured !== words_pushed) begin $display("FAIL: case 6: captured=%0d, expected %0d words", captured, words_pushed); errors = errors + 1; end
            else $display("  ok: captured counts words: %0d", captured);
            c_enable = 1'b0;
        end
    endtask

    initial begin
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
