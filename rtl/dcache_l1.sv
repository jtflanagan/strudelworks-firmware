`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// dcache_l1 - 4 KB of data, two clocks away.
//
// The icache's sibling (rtl/icache_l1.sv): 256 lines of 16 bytes,
// direct-mapped, physically indexed and physically tagged in the 25-bit
// space {rom, pa[23:0]}, so LC banks, ALTZP and every RamWorks bank coexist
// without aliasing and a map change never invalidates a line - only the
// write snoop and the flash do.  The differences from the icache, and why:
//
// - THE LOOKUP ADDRESS IS REGISTERED.  A data address can contain live din
//   through the AGU (that is what an AGU is), and the l1_front lesson is
//   that nothing combinational may descend from din into a serve.  So the
//   front registers the address in the op's first clock and this module's
//   look_pa is that registered copy: the serve verdict is registered bits
//   against registered bits, one clock later than the icache's - the
//   two-clock data op, by design (docs/DCACHE_PLAN.md, law 1).
//
// - THE STEER IS A GUESS THE VERDICT CHECKS.  The row register needs its
//   index a clock before the verdict, when the matching page register is
//   not yet known - so the front steers a guess (measured: data ops
//   alternate between two pages, so the guess is the page NOT used last)
//   and look_hit additionally requires that the steered row is the row the
//   registered address wants.  A wrong guess is a one-clock miss and a
//   registered re-steer, exactly the icache's mispredict shape.
//
// - A BYTE-WRITE PORT.  A data write the front serves updates its line in
//   place, the same edge the core moves on.  The front asserts wr only on
//   a verdict that just proved the row: wr_idx is the proven row, no check
//   is repeated here.  A write landing in the row being steered kills that
//   steer for a clock (row_ok), or the row register would serve the
//   pre-write line.
//////////////////////////////////////////////////////////////////////////////////
module dcache_l1 (
    input  wire         clk,
    input  wire         rst,
    input  wire         flash,       // clear every line, this clock

    // Lookup: the front's REGISTERED address, answered combinationally
    // against the registered row.  look_ok says the row IS the looked-up
    // row and postdates every writer - with it, !look_hit is a PROVEN
    // absence (a write may then bypass to the wb lines), without it the
    // row simply was not there to ask.
    input  wire [24:0]  look_pa,
    output wire         look_hit,
    output wire         look_ok,
    // ...and what they WILL be next clock, for a front that registers its
    // verdicts an edge early (look_pa held stable across the edge): the
    // in-flight read's bookkeeping, kills at this edge included.
    output wire         look_hit_next,
    output wire         look_ok_next,
    output wire [7:0]   look_byte,

    // Steering: the row to have ready next clock, and the tag the steered
    // address expects there (read and compared at the steer edge, a whole
    // clock ahead of the verdict).
    input  wire [7:0]   steer_idx,
    input  wire [12:0]  steer_tag,

    // Install: a whole line, observed from the L2's sub_line.
    input  wire         inst_en,
    input  wire [24:0]  inst_pa,
    input  wire [127:0] inst_line,

    // The write port: one byte into a row a verdict just proved.
    input  wire         wr_en,
    input  wire [7:0]   wr_idx,
    input  wire [3:0]   wr_byte,
    input  wire [7:0]   wr_data,

    // The write snoop: an image write by another producer, by physical
    // address.  Kills the line (this is a cache - DDR3 and the L2 stay
    // authoritative underneath it).
    input  wire         snoop_en,
    input  wire [23:0]  snoop_pa
);

    // index = pa[11:4], tag = pa[24:12]: 256 lines, 13-bit tags.
    // Block RAM, read through TWO registers - cache_way_ram's arrangement:
    // the second is the BRAM's own optional output register, and the serve
    // byte then launches from that fast flop instead of the slow array
    // read (a single-register read left the row absorbed as the array's
    // output latch, and the din cone into the AGU missed by 1.5ns from its
    // fixed column).  The price is the row arriving one clock later: a D$
    // hit is THREE clocks, not two - the user's trade, ~550 LUTs returned
    // to the budget for roughly two points of ratio.
    (* ram_style = "block" *)       logic [127:0] mem  [0:255];
    (* ram_style = "distributed" *) logic [12:0]  tags [0:255];
    logic [255:0] vld;

    logic [127:0] row_q;               // the BRAM's read latch
    logic [127:0] row;                 // ...and its output register, absorbed
    logic [7:0]   idx1;                // the in-flight read's bookkeeping
    logic         ok1, hit1;
    logic [7:0]   row_idx;
    logic         row_ok;
    logic         row_hit;

    // The verdict clock: flip-flops on both sides, nothing else.
    wire [7:0]  l_idx = look_pa[11:4];
    assign look_ok   = (row_idx == l_idx) && row_ok;
    assign look_hit  = row_hit && look_ok;
    assign look_byte = row[8 * look_pa[3:0] +: 8];
    wire kills_now   = (mw_en && mw_idx == idx1) ||
                       (snoop_here && s_idx == idx1) || rst || flash;
    assign look_ok_next  = ok1 && (idx1 == l_idx) && !kills_now;
    assign look_hit_next = hit1 && (idx1 == l_idx) && !kills_now;

    wire [7:0] i_idx = inst_pa[11:4];
    wire [7:0] s_idx = snoop_pa[11:4];
    wire snoop_here = snoop_en && vld[s_idx] &&
                      (tags[s_idx] == {1'b0, snoop_pa[23:12]});

    // One write port, byte enables: an install is all sixteen lanes, the
    // front's write exactly one.  They cannot collide - an install rides a
    // sequencer-served op and the write a front-served one, and there is
    // one op at a time - but the install wins if they ever do, and the sim
    // check below is the tripwire.
    wire        mw_en   = inst_en || wr_en;
    wire [7:0]  mw_idx  = inst_en ? i_idx : wr_idx;
    wire [15:0] mw_be   = inst_en ? 16'hFFFF : (16'd1 << wr_byte);
    wire [127:0] mw_data = inst_en ? inst_line : {16{wr_data}};

`ifndef SYNTHESIS
    always @(posedge clk)
        if (inst_en && wr_en)
            $fatal(1, "dcache_l1: install and byte write on one clock");
`endif

    always_ff @(posedge clk) begin
        if (mw_en) begin
            for (int b = 0; b < 16; b = b + 1)
                if (mw_be[b]) mem[mw_idx][8*b +: 8] <= mw_data[8*b +: 8];
        end
        if (inst_en) tags[i_idx] <= inst_pa[24:12];
    end

    always_ff @(posedge clk) begin
        row_q <= mem[steer_idx];
        row   <= row_q;
        // The verdict rides two clocks behind the steer, so a writer or a
        // snoop landing in EITHER intervening clock kills the row - it
        // would describe the line as of before them.
        idx1 <= steer_idx;
        ok1  <= !(mw_en && mw_idx == steer_idx);
        hit1 <= !(rst || flash) && vld[steer_idx] &&
                (tags[steer_idx] == steer_tag) &&
                !(mw_en && mw_idx == steer_idx) &&
                !(snoop_here && s_idx == steer_idx);
        row_idx <= idx1;
        row_ok  <= ok1  && !(mw_en && mw_idx == idx1);
        row_hit <= hit1 && !(rst || flash) &&
                   !(mw_en && mw_idx == idx1) &&
                   !(snoop_here && s_idx == idx1);

        if (rst || flash) begin
            vld <= 256'd0;
        end else begin
            if (inst_en)    vld[i_idx] <= 1'b1;
            if (snoop_here) vld[s_idx] <= 1'b0;   // after the install: the snoop wins
        end
    end

endmodule
