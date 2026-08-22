`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// cpu816_equiv_tb - hold the pipelined sequencer to the one it replaced.
//
// The decode-once rewrite changes WHEN the microcode is read and WHEN a
// condition is evaluated, and changes nothing about what the machine is
// supposed to do.  That is exactly the kind of change a cycle-count table
// cannot police: sim/gen_cycle_table816.py walks the microcode image, which the
// rewrite does not touch, so it would pass unchanged even if the RTL pipeline
// were wrong.
//
// So this compares the two cores directly.  Both are driven from the same
// memory and the same din, and every cycle their addr, rw, dout and sync must
// agree.  The stimulus is PSEUDO-RANDOM BYTES: letting both cores run wild
// through arbitrary opcodes covers far more of the sequencer than any program
// anyone would write on purpose, and any divergence in slot sequencing shows up
// as a mismatched address within a cycle or two of the instruction that caused
// it.
//
// $DB (STP) and $CB (WAI) are excluded from the fill, because a core that parks
// stops being a source of coverage.
//////////////////////////////////////////////////////////////////////////////////

module cpu816_equiv_tb;

    parameter UCODE  = "cpu65816_ucode.hex";
    parameter UCODE0 = "cpu65816_ucode0.hex";
    parameter USEQ0  = "cpu65816_useq0.hex";
    parameter integer CYCLES = 200000;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    // One memory, both cores see the same data.  If they ever disagree about an
    // address the run stops there, so feeding them from a single model is safe
    // and keeps the comparison honest.
    logic [7:0] mem [0:(1<<24)-1];

    logic [23:0] a_new, a_ref;
    logic        rw_new, rw_ref, sync_new, sync_ref;
    logic [7:0]  d_new, d_ref;
    logic [7:0]  din;

    assign din = mem[a_new];

    cpu65816 #(.UCODE_FILE(UCODE), .UCODE0_FILE(UCODE0), .USEQ0_FILE(USEQ0)) dut (
        .clk(clk), .rst(rst), .cyc_en(1'b1),
        .addr(a_new), .rw(rw_new), .dout(d_new), .din(din),
        .irq_n(1'b1), .nmi_n(1'b1),
        .sync(sync_new), .emu(), .halted()
    );

    cpu65816_ref #(.UCODE_FILE(UCODE)) refcore (
        .clk(clk), .rst(rst), .cyc_en(1'b1),
        .addr(a_ref), .rw(rw_ref), .dout(d_ref), .din(din),
        .irq_n(1'b1), .nmi_n(1'b1),
        .sync(sync_ref), .emu(), .halted()
    );

    integer i, errors = 0, checked = 0, syncs = 0;
    integer seed = 32'h6816_c0de;
    logic [7:0] b;

    initial begin
        // Pseudo-random fill.  Deterministic, so a failure reproduces.
        for (i = 0; i < (1<<24); i = i + 1) begin
            b = $random(seed);
            if (b == 8'hDB || b == 8'hCB) b = 8'hEA;   // no parking
            mem[i] = b;
        end
        // The reset vector has to land somewhere sane; anywhere is fine, the
        // point is that both cores go to the same place.
        mem[24'h00FFFC] = 8'h00;
        mem[24'h00FFFD] = 8'h10;

        repeat (4) @(posedge clk);
        rst = 0;

        // The two cores do not leave reset in lockstep - the pipelined one has
        // a deeper pipe to fill - so skip the first few cycles and then require
        // exact agreement from there on.
        repeat (8) @(posedge clk);

        for (i = 0; i < CYCLES; i = i + 1) begin
            @(negedge clk);
            checked = checked + 1;
            if (sync_new) syncs = syncs + 1;
            if (a_new !== a_ref || rw_new !== rw_ref || sync_new !== sync_ref ||
                (rw_new == 1'b0 && d_new !== d_ref)) begin
                errors = errors + 1;
                $display("MISMATCH at cycle %0d", checked);
                $display("   new: addr=%06h rw=%b sync=%b dout=%02h",
                         a_new, rw_new, sync_new, d_new);
                $display("   ref: addr=%06h rw=%b sync=%b dout=%02h",
                         a_ref, rw_ref, sync_ref, d_ref);
                if (errors > 10) begin
                    $display("too many mismatches, stopping");
                    i = CYCLES;
                end
            end
        end

        $display("==============================================================");
        $display("compared %0d cycles, %0d opcode fetches", checked, syncs);
        if (errors == 0)
            $display("PASS: the pipelined sequencer matches the one it replaced");
        else
            $display("FAIL: %0d mismatched cycles", errors);
        $display("==============================================================");
        if (errors != 0) $fatal(1);
        $finish;
    end

endmodule
