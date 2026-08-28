`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// msg_arb - the message bus: N Wishbone masters, one slave, a grant per CYC.
//
// WHY THIS EXISTS.  The stream to the host has no sync word and cannot
// resynchronise (docs/PROTOCOL.md), so a word from one source landing inside
// another source's message does not break the link loudly - it makes the
// stream plausible and wrong from that point on.  Every source therefore has
// to go through one place that hands the stream to one of them at a time.
//
// THAT PLACE IS A STANDARD WISHBONE ARBITER, and nothing more.  A message is a
// burst: the master asserts CYC for the header, keeps it through the last
// payload word and its ack, and drops it.  Wishbone's own rule - the arbiter
// does not take the bus from a master while its CYC is asserted - is exactly
// message atomicity, and it needs no knowledge of the frame format here.
// (The length is still snooped once, downstream in tx_ring, as a GUARD: a
// master that drops CYC mid-message is a bug, and bugs get flagged.)
//
// This replaced a message-aware arbiter that snooped every header to find
// the boundaries itself.  That worked, and it was one place too many that
// had to understand the protocol; a linear Wishbone burst has no maximum
// length, so the bus can carry the atomicity instead.
//
// PRIORITY IS THE PORT INDEX, FIXED.  At a boundary the lowest port with CYC
// asserted goes next.  Fixed priority is safe here for a reason that has to
// stay true of every source ever attached above the capture: each must be
// rate-bounded by something outside the card - a host request it answers, a
// bus event it reports - so it cannot saturate.  The one continuous source,
// the capture, is last.  docs/TX_RING.md.
//
// PIPELINED.  STB/STALL, one beat a cycle; a master presents STB and holds it
// while stalled.  The slave acks a beat the cycle after accepting it, and the
// ack goes back to whichever master owned that beat.  A master keeps CYC up
// until its last ack is in, which is the rule that makes "route to the owner"
// and "letting_go on CYC low" agree.
//
// The grant is combinational when the bus is idle, so a one-word message -
// the notice - goes through the cycle it is offered.  Masters must therefore
// not derive CYC combinationally from STALL; msg_master registers it.
//////////////////////////////////////////////////////////////////////////////////
module msg_arb #(
    parameter integer N = 4
) (
    input  wire            clk,
    input  wire            rst,

    // ---- the masters.  Port i is bit i / slice i; lower index wins. ------
    input  wire [N-1:0]    m_cyc,
    input  wire [N-1:0]    m_stb,
    input  wire [N-1:0]    m_we,
    input  wire [N*32-1:0] m_adr,
    input  wire [N*32-1:0] m_dat,
    input  wire [N*4-1:0]  m_sel,
    output wire [N-1:0]    m_stall,
    output wire [N-1:0]    m_ack,

    // ---- the slave ------------------------------------------------------------
    output wire            s_cyc,
    output wire            s_stb,
    output wire            s_we,
    output wire [31:0]     s_adr,
    output wire [31:0]     s_dat,
    output wire [3:0]      s_sel,
    input  wire            s_stall,
    input  wire            s_ack
);

    localparam integer IW = (N > 1) ? $clog2(N) : 1;

    logic          held   = 1'b0;
    logic [IW-1:0] holder = '0;

    // The holder keeps the bus for as long as its CYC is up.  The cycle it
    // lets go is a bubble - nobody is granted - so the slave sees CYC low
    // between every two bursts, even with the next master already waiting.
    // That is what lets a slave tell "a new burst" from "the same one", and
    // it is what tx_ring's guard relies on.
    wire active  = held && m_cyc[holder];
    wire letting_go = held && !m_cyc[holder];

    logic [IW-1:0] pick;
    integer        i;
    always_comb begin
        pick = '0;
        for (i = N - 1; i >= 0; i = i - 1)
            if (m_cyc[i]) pick = IW'(i);
    end

    wire          any = |m_cyc;
    wire [IW-1:0] sel = active ? holder : pick;
    wire          granted = active || (any && !letting_go);

    assign s_cyc = granted;
    assign s_stb = granted && m_stb[sel];
    assign s_we  = m_we[sel];
    assign s_adr = m_adr[sel*32 +: 32];
    assign s_dat = m_dat[sel*32 +: 32];
    assign s_sel = m_sel[sel*4 +: 4];

    wire accept = s_cyc && s_stb && !s_stall;

    // Who owns the beat the slave will ack next cycle.
    logic [IW-1:0] ack_owner = '0;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_port
            assign m_stall[g] = !(granted && (sel == IW'(g))) || s_stall;
            assign m_ack[g]   = s_ack && (ack_owner == IW'(g));
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            held      <= 1'b0;
            holder    <= '0;
            ack_owner <= '0;
        end else begin
            held   <= granted;
            holder <= sel;
            if (accept) ack_owner <= sel;
        end
    end

endmodule
