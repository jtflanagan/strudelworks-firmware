`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// bank_ram - one 64 KB bank of the page cache: 4096 rows of 16 bytes, true
// dual port.
//
// Port A is the op path's: a read at op_present, a write at the decision, and
// the two never share a clock.  Its read side carries TWO output registers -
// the second is the block RAM's own optional output register, the same slack
// cache_way_ram bought and for the same reason: the row is wide, the byte
// select and the tag compare want a whole stage, and at Apple speed the extra
// clock costs nothing.
//
// Port B is the page engine's: the snapshot's reads, a fill's installs, the
// write-miss patch.  One output register only - the engine's schedule has a
// clock to spare everywhere it reads.
//
// Written in the two-process shape Vivado infers a true dual-port block RAM
// from (UG901), read-first on both ports, a byte enable per lane on both.  A
// same-clock same-row collision between the ports returns stale read data;
// the op path and the engine are scheduled so it cannot happen (the engine
// runs only while the op path is parked on a miss).  The one collision the
// accelerated core adds - a main-bank write on port A landing on the clock
// the floating-bus simulator reads the same row on port B - is SAFE because
// the writing port is read-first: the opposite port's read returns the OLD
// data, valid on hardware (UG473), and a one-clock-stale byte is immaterial
// to a scanner whose whole question is "what does the video see this cycle".  4096 x 128 is sixteen
// RAMB36 in 4096 x 9 pairs' worth of fabric - the price docs/PAGE_CACHE.md
// budgets.
//////////////////////////////////////////////////////////////////////////////////
module bank_ram (
    input  wire          clk,

    input  wire          a_en,
    input  wire [15:0]   a_we,        // one per byte lane
    input  wire [11:0]   a_addr,
    input  wire [127:0]  a_wdata,
    output logic [127:0] a_rdata,     // two clocks after a_en

    input  wire          b_en,
    input  wire [15:0]   b_we,
    input  wire [11:0]   b_addr,
    input  wire [127:0]  b_wdata,
    output logic [127:0] b_rdata      // one clock after b_en
);

    (* ram_style = "block" *) logic [127:0] mem [0:4095];

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
