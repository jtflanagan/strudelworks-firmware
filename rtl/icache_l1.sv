`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// icache_l1 - 4 KB of instructions, one clock away.
//
// 256 lines of 16 bytes, direct-mapped, in one RAMB36 - physically indexed
// and physically tagged in the 25-bit space {rom, pa[23:0]} (the internal ROM
// is not in the image, and its lines must not alias it), so LC banks, ALTZP
// and every RamWorks bank coexist here without aliasing and a map change
// never invalidates a line - only the write snoop and the flash do.
//
// THE ROW REGISTER IS THE WHOLE TRICK.  A block RAM answers one clock after
// its address, so a same-clock hit is only possible if the address went in a
// clock EARLY: every clock, `steer_idx` names the row to have ready - the
// front end steers the core's predicted next fetch while the core runs, and
// the current address while it retries - and the lookup then answers
// combinationally: the steered row is the looked-up row, the LUTRAM tag
// matches, the line is valid.  A wrong prediction is not an error, it is a
// one-clock miss followed by a steered retry.
//
// row_ok covers the one blind spot: an install that lands in the row being
// steered would leave the register holding the pre-install line for a clock,
// so that clock does not count as a hit.
//
// Tags and valid bits sit outside the BRAM - tags in LUTRAM (asynchronous,
// so the compare happens in the fetch's own clock), valid in 256 flip-flops
// (so the flash clears everything at one edge, same argument as class_tlb).
// The snoop kills a line by physical address the clock a write to it is
// classified - before the write has even reached the image, which is the
// ordering self-modifying code needs.  A snoop and an install on the same
// clock both act; on the same LINE the snoop wins - the installed line
// predates the write that is killing it.
//////////////////////////////////////////////////////////////////////////////////
module icache_l1 (
    input  wire         clk,
    input  wire         rst,
    input  wire         flash,       // clear every line, this clock

    // Lookup: the core's current fetch, answered combinationally.
    input  wire [24:0]  look_pa,     // {rom, pa[23:0]}
    output wire         look_hit,
    output wire [7:0]   look_byte,

    // Steering: the row the next clock's lookup will want, and the physical
    // tag the steered address expects there.  The tag table is read and
    // compared HERE, at the steer edge, with a whole clock to do it - the
    // fetch clock then only checks registered bits (the first build proved
    // the fetch clock cannot afford a LUTRAM: docs/ACCELERATION.md).
    input  wire [7:0]   steer_idx,
    input  wire [12:0]  steer_tag,

    // Install: a whole line, from the L2's sub_line or the ROM filler.
    input  wire         inst_en,
    input  wire [24:0]  inst_pa,
    input  wire [127:0] inst_line,

    // The write snoop: an image write, by physical address.
    input  wire         snoop_en,
    input  wire [23:0]  snoop_pa
);

    // index = pa[11:4], tag = pa[24:12]: 256 lines, 13-bit tags.
    (* ram_style = "block" *)       logic [127:0] mem  [0:255];
    (* ram_style = "distributed" *) logic [12:0]  tags [0:255];
    logic [255:0] vld;

    logic [127:0] row;               // the BRAM's one-clock-late answer
    logic [7:0]   row_idx;           // which row it is
    logic         row_ok;            // and whether it postdates every install
    logic         row_hit;           // the steer-time verdict: the row being
                                     // loaded is valid AND is the line the
                                     // steered address wants

    // The fetch clock: flip-flops on both sides, nothing else.
    wire [7:0]  l_idx = look_pa[11:4];
    assign look_hit  = row_hit && (row_idx == l_idx) && row_ok;
    assign look_byte = row[8 * look_pa[3:0] +: 8];

    wire [7:0] i_idx = inst_pa[11:4];
    wire [7:0] s_idx = snoop_pa[11:4];
    // The snoop's address lives in the image half of the space: bit 24 clear.
    wire snoop_here = snoop_en && vld[s_idx] &&
                      (tags[s_idx] == {1'b0, snoop_pa[23:12]});

    always_ff @(posedge clk) begin
        row     <= mem[steer_idx];
        row_idx <= steer_idx;
        row_ok  <= !(inst_en && i_idx == steer_idx);
        // The verdict, with everything that could kill the steered row at
        // this same edge folded in as forced-low terms: the flash, a snoop
        // landing on it, an install colliding with it (the row register
        // would hold pre-install data - one extra miss clock, as row_ok
        // already imposes).  Nothing stale can ever serve.
        row_hit <= !(rst || flash) && vld[steer_idx] &&
                   (tags[steer_idx] == steer_tag) &&
                   !(inst_en && i_idx == steer_idx) &&
                   !(snoop_here && s_idx == steer_idx);

        if (inst_en) begin
            mem[i_idx]  <= inst_line;
            tags[i_idx] <= inst_pa[24:12];
        end

        if (rst || flash) begin
            vld <= 256'd0;
        end else begin
            if (inst_en)   vld[i_idx] <= 1'b1;
            if (snoop_here) vld[s_idx] <= 1'b0;   // after the install: the snoop wins
        end
    end

endmodule
