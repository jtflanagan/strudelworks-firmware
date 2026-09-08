`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// way_ram - one way of the physical page cache: SETS x 16 rows of 16 bytes,
// true dual port.  rtl/bank_ram.sv's shape and rtl/bank_ram.sv's reasons; the
// difference is that a way is no longer a 64 KB region of the machine's
// address space but SETS pages of anywhere in the 16 MB physical space, and
// there are WAYS of them (rtl/phys_cache.sv, docs/MEMORY_REFACTOR.md Part 3).
//
// Port A is the op path's: the entrant's read (an op's P0, a posted write's,
// a front's line request) and, two clocks later, a write landing.  Its read
// side carries TWO output registers - the block RAM's own optional output
// register is the second - so the row is out at the entrant's clock + 2, the
// way mux and the byte select have a whole stage, and the write that lands in
// the same clock cannot disturb a row already captured (a_rdata takes the old
// a_q on that edge).
//
// Port B is the page engine's: the dirty victim's snapshot, a fill's installs
// and the write miss's patch.  One output register - the engine has a clock
// to spare everywhere it reads.
//
// Written in the two-process shape Vivado infers a true dual-port block RAM
// from (UG901), read-first on both ports, a byte enable per lane on both.  At
// 128 sets that is 2048 x 128 = eight RAMB36 per way; the ways never share a
// row, so a fill on port B and a hit on port A of two different ways run in
// the same clock with no interaction at all.
//////////////////////////////////////////////////////////////////////////////////
module way_ram #(
    parameter integer ROWS = 2048,
    parameter integer AW   = $clog2(ROWS)
) (
    input  wire          clk,

    input  wire          a_en,
    input  wire [15:0]   a_we,        // one per byte lane
    input  wire [AW-1:0] a_addr,
    input  wire [127:0]  a_wdata,
    output logic [127:0] a_rdata,     // two clocks after a_en

    input  wire          b_en,
    input  wire [15:0]   b_we,
    input  wire [AW-1:0] b_addr,
    input  wire [127:0]  b_wdata,
    output logic [127:0] b_rdata      // one clock after b_en
);

    (* ram_style = "block" *) logic [127:0] mem [0:ROWS-1];

    logic [127:0] a_q;

    always_ff @(posedge clk) begin
        if (a_en) begin
            for (int i = 0; i < 16; i = i + 1) begin
                if (a_we[i]) mem[a_addr][8*i +: 8] <= a_wdata[8*i +: 8];
            end
            a_q <= mem[a_addr];
        end
        a_rdata <= a_q;
    end

    always_ff @(posedge clk) begin
        if (b_en) begin
            for (int i = 0; i < 16; i = i + 1) begin
                if (b_we[i]) mem[b_addr][8*i +: 8] <= b_wdata[8*i +: 8];
            end
            b_rdata <= mem[b_addr];
        end
    end

endmodule
