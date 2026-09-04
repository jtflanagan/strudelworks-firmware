`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
// vbeam_tb - the virtual beam (rtl/vbeam.sv) against a reference stepped per
// core cycle: passthrough of the real counter while virt is low, the seed on
// the transition, the step per fast tick and per bus tick of the core's own
// (never a dummy's or an override's), two steps on a colliding clock, the
// level, the mark on the word at line 0 cycle 0 - bus or fast, with the
// frame count and the virtual flag - and the return to the real counter.
module vbeam_tb;
    `include "scan_addr.vh"
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rst = 1'b1;
    reg virt = 1'b0, real_locked = 1'b1, pal = 1'b0, notify = 1'b1;
    reg [8:0] real_v = 9'd100; reg [6:0] real_h = 7'd10;
    reg real_mark = 1'b0; reg [15:0] real_mark_free = 16'h0700;
    reg bus_tick = 1'b0, op_dummy = 1'b0, op_ovr = 1'b0, fast_tick = 1'b0;
    wire locked, vbl_level, mark_bus, mark_fast;
    wire [8:0] scan_v; wire [6:0] scan_h; wire [15:0] mark_free;
    vbeam dut (.clk (clk), .rst (rst), .virt (virt),
        .real_locked (real_locked), .real_v (real_v), .real_h (real_h), .pal (pal), .notify (notify),
        .real_mark (real_mark), .real_mark_free (real_mark_free),
        .bus_tick (bus_tick), .op_dummy (op_dummy), .op_ovr (op_ovr), .fast_tick (fast_tick),
        .locked (locked), .scan_v (scan_v), .scan_h (scan_h), .vbl_level (vbl_level),
        .mark_bus (mark_bus), .mark_fast (mark_fast), .mark_free (mark_free));

    integer errors = 0, checks = 0, marks_bus = 0, marks_fast = 0, steps = 0;
    task fail(input string what); begin $display("FAIL: %0s", what); errors = errors + 1; end endtask
    // The reference counter.
    reg [8:0] rv; reg [6:0] rh;
    wire [8:0] lines = pal ? SCAN_PAL_LINES : SCAN_NTSC_LINES;
    task step_ref; begin
        if (rh != 7'd64) rh = rh + 7'd1;
        else begin rh = 7'd0; rv = (rv == lines - 9'd1) ? 9'd0 : rv + 9'd1; end
        steps = steps + 1;
    end endtask
    // The real counter, free-running one step per "bus cycle" of 4 clocks.
    integer rc = 0;
    always @(posedge clk) begin
        rc <= rc + 1;
        if (rc % 4 == 3) begin
            if (real_h != 7'd64) real_h <= real_h + 7'd1;
            else begin real_h <= 7'd0; real_v <= (real_v == lines - 9'd1) ? 9'd0 : real_v + 9'd1; end
        end
    end

    integer i, n_bus, n_fast;
    initial begin
        $display("vbeam_tb: the virtual beam against a reference\n");
        repeat (3) @(negedge clk); rst = 1'b0; repeat (2) @(negedge clk);
        // --- passthrough ------------------------------------------------------------
        for (i = 0; i < 300; i = i + 1) begin
            @(negedge clk);
            checks = checks + 1;
            if (scan_v !== real_v || scan_h !== real_h) fail("passthrough: position is not the real counter's");
            if (vbl_level !== (real_v >= 9'd192)) fail("passthrough: level");
            if (mark_fast !== 1'b0) fail("passthrough: a fast mark");
        end
        real_mark = 1'b1; @(negedge clk);
        if (mark_bus !== 1'b1 || mark_free !== 16'h0700) fail("passthrough: the real mark is not passed through");
        real_mark = 1'b0; @(negedge clk);
        $display("  ok: passthrough - position, level and the real mark are the lock's");
        // --- the transition: seeded from the real counter --------------------------
        @(negedge clk); virt = 1'b1; rv = real_v; rh = real_h;
        @(negedge clk);   // the clock virt rises: the seed lands
        @(negedge clk);
        if (scan_v !== rv || scan_h !== rh) fail($sformatf("seed: %0d/%0d vs reference %0d/%0d", scan_v, scan_h, rv, rh));
        else $display("  ok: seeded from the real counter at the transition (%0d,%0d)", rv, rh);
        // --- the steps: fast ticks, bus ticks of the core's own, collisions ---------
        n_bus = 0; n_fast = 0;
        for (i = 0; i < 40000; i = i + 1) begin
            @(negedge clk);
            fast_tick = ($urandom % 3 == 0);
            bus_tick  = ($urandom % 5 == 0);
            op_dummy  = ($urandom % 2 == 0);
            op_ovr    = ($urandom % 7 == 0);
            checks = checks + 1;
            if (scan_v !== rv || scan_h !== rh) begin
                if (errors < 5) fail($sformatf("step %0d: %0d/%0d vs reference %0d/%0d", i, scan_v, scan_h, rv, rh));
                else errors = errors + 1;
            end
            if (vbl_level !== (rv >= 9'd192)) fail("level");
            #1;
            if (bus_tick && !op_dummy && !op_ovr) begin
                if (mark_bus !== ((rv == 0) && (rh == 0))) fail($sformatf("bus mark at %0d/%0d = %0d", rv, rh, mark_bus));
                if (mark_bus) marks_bus = marks_bus + 1;
                step_ref; n_bus = n_bus + 1;
            end else if (mark_bus) fail("a bus mark on a dummy/override/no tick");
            if (fast_tick) begin
                if (mark_fast !== ((rv == 0) && (rh == 0))) fail($sformatf("fast mark at %0d/%0d = %0d", rv, rh, mark_fast));
                if (mark_fast) marks_fast = marks_fast + 1;
                step_ref; n_fast = n_fast + 1;
            end else if (mark_fast) fail("a fast mark with no fast tick");
            if (mark_free[1] !== 1'b1) fail("virtual flag");
        end
        fast_tick = 0; bus_tick = 0;
        @(negedge clk);
        $display("  ok: %0d steps (%0d fast, %0d bus of the core's own) tracked the reference; marks: %0d on bus words, %0d on fast words (frames %0d)",
                 steps, n_fast, n_bus, marks_bus, marks_fast, mark_free[15:8]);
        if (mark_free[15:8] != marks_bus + marks_fast) fail("the frame count");
        // --- back to the real counter -----------------------------------------------
        @(negedge clk); virt = 1'b0; @(negedge clk); @(negedge clk);
        if (scan_v !== real_v || scan_h !== real_h) fail("return: not the real counter");
        else $display("  ok: back on the real counter when virt drops");
        $display("\n%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
