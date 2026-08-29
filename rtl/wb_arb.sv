`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// wb_arb - the DDR3's one Wishbone port, shared by batches.
//
// UberDDR3 has a single data port (docs/DDR3_USAGE.md §6: SECOND_WISHBONE is a
// 32-bit debug interface, not a data path), so every client of the memory
// goes through this.  The first two are the TX ring's reader and writer
// (rtl/tx_ring.sv); the Apple's memory and host DMA are the ones §6 reserves
// places for.
//
// A GRANT IS A BATCH, NOT A CYCLE.  A client raises `req` when it has a run of
// work - a batch of lines to write, or room and data for a batch of reads -
// holds the port while it issues them, and drops `req` when the run is done.
// The arbiter never takes the port back from a client that still wants it.
// That is what pays for the DDR3's two expensive switches - read<->write
// turnaround, which applies to every bank, and the row change between two
// clients in the same bank - once per batch rather than once per burst.
//
// ROUND-ROBIN among the streaming clients.  With two of equal standing the
// fair thing is to alternate when both are waiting, and that is all the
// rotation does: after a grant ends the search for the next starts one past
// the holder.
//
// ONE STRICT-PRIORITY SLOT ABOVE THE ROTATION, when HAS_PRIO is set: client
// N-1 - the Apple's memory (rtl/mem_client.sv), whose fill has a bus cycle's
// deadline.  It is never in the rotation and it does not wait for a batch to
// end: the clock after it asks, the port is its, and the rotation's holder is
// stalled where it stands.  Nothing is cancelled - a stalled stb is the
// pipelined-Wishbone way of saying "not yet", every client here already holds
// its request through a stall, and cyc stays the OR of everyone's so no ack
// is aborted.  When the priority client lets go the holder carries on with
// its batch.  The one thing the priority client can still wait for is a burst
// the controller has ALREADY accepted, plus a read<->write turnaround; that is
// the ~8 clocks docs/DDR3_USAGE.md budgets, not a batch.
//
// rot_ok is the free-window predicate §6 describes: a rotation grant may only
// START while it is high.  mem_client raises it early in a bus cycle, so a
// batch begun then is over before the next cycle can need the memory.  The
// pre-emption is what makes this a performance knob rather than a correctness
// requirement.
//
// ACKS ARE ROUTED BY TAG, not by grant.  Each request carries its client's
// index in `wb_aux`, which the controller returns with the ack, so the grant
// can move on while a previous holder's acks are still in flight and every
// ack still reaches the client that asked.
//
// CYC IS THE OR OF EVERY CLIENT'S.  The controller ABORTS every outstanding
// ack the cycle i_wb_cyc goes low (ddr3_controller.v, "abort any outgoing ack
// when cyc is low").  So a client holds its `cyc` from its first request until
// its last ack, whatever else happens to the grant - and the port's cyc is
// high while anyone is waiting.
//////////////////////////////////////////////////////////////////////////////////
module wb_arb #(
    parameter integer N         = 2,
    parameter integer ADDR_BITS = 24,
    parameter integer DATA_BITS = 128,
    parameter integer SEL_BITS  = 16,
    parameter integer AUX_WIDTH = 4,
    // 1: client N-1 is the strict-priority slot, outside the rotation.
    parameter bit     HAS_PRIO  = 1'b0
) (
    input  wire                    clk,
    input  wire                    rst,
    // A rotation grant may only START while this is high.  Tie high when
    // there is no priority client to keep clear of.
    input  wire                    rot_ok,

    // ---- clients.  Port i is bit i / slice i.  ----------------------------
    input  wire [N-1:0]            c_req,      // wants the port; hold for the batch
    output logic [N-1:0]           c_gnt,      // has it; issue stb only while high
    input  wire [N-1:0]            c_cyc,      // hold from first stb to last ack
    input  wire [N-1:0]            c_stb,
    input  wire [N-1:0]            c_we,
    input  wire [N*ADDR_BITS-1:0]  c_addr,
    input  wire [N*DATA_BITS-1:0]  c_data,
    input  wire [N*SEL_BITS-1:0]   c_sel,
    output wire [N-1:0]            c_stall,    // high unless granted and the port is free
    output wire [N-1:0]            c_ack,      // this client's ack, by tag
    output wire [DATA_BITS-1:0]    c_rdata,    // shared; meaningful with c_ack

    // ---- the port -----------------------------------------------------------
    output wire                    wb_cyc,
    output wire                    wb_stb,
    output wire                    wb_we,
    output wire [ADDR_BITS-1:0]    wb_addr,
    output wire [DATA_BITS-1:0]    wb_data,
    output wire [SEL_BITS-1:0]     wb_sel,
    output wire [AUX_WIDTH-1:0]    wb_aux,
    input  wire                    wb_stall,
    input  wire                    wb_ack,
    input  wire [DATA_BITS-1:0]    wb_rdata,
    input  wire [AUX_WIDTH-1:0]    wb_rdata_aux
);

    localparam integer IW = (N > 1) ? $clog2(N) : 1;
    localparam integer NR = HAS_PRIO ? N - 1 : N;      // clients in the rotation
    localparam [IW-1:0] PRIO = IW'(N - 1);

    logic          held = 1'b0;       // someone in the rotation has the port
    logic [IW-1:0] holder = '0;
    logic [IW-1:0] last   = '0;       // where the next search starts from
    logic          pre    = 1'b0;     // the priority client has the port

    // Rotating pick: the first requester at or after last + 1.
    logic [IW-1:0] pick;
    logic          any;
    integer        k;
    logic [IW-1:0] cand;
    always_comb begin
        pick = '0;
        any  = 1'b0;
        for (k = NR; k >= 1; k = k - 1) begin
            cand = IW'((32'(last) + k) % NR);
            if (c_req[cand]) begin
                pick = cand;
                any  = 1'b1;
            end
        end
    end

    // The holder keeps the port while it asks for it.  The cycle it lets go,
    // the port is idle; a new grant lands the cycle after, and only in a
    // window the priority client has declared free.
    always_ff @(posedge clk) begin
        if (rst) begin
            held   <= 1'b0;
            holder <= '0;
            last   <= '0;
            pre    <= 1'b0;
        end else begin
            pre <= HAS_PRIO && c_req[PRIO];
            if (held) begin
                if (!c_req[holder]) begin
                    held <= 1'b0;
                    last <= holder;
                end
            end else if (any && rot_ok) begin
                held   <= 1'b1;
                holder <= pick;
            end
        end
    end

    // Who the port answers to this clock.  pre is a flop so the wide muxes
    // below select on a register, not on a request line.
    wire [IW-1:0] eff = pre ? PRIO : holder;
    wire          eff_held = pre || held;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_port
            assign c_gnt[g]   = eff_held && (eff == IW'(g));
            assign c_stall[g] = !c_gnt[g] || wb_stall;
            assign c_ack[g]   = wb_ack && (wb_rdata_aux == AUX_WIDTH'(g));
        end
    endgenerate

    assign c_rdata = wb_rdata;

    assign wb_cyc  = |c_cyc;
    assign wb_stb  = eff_held && c_stb[eff];
    assign wb_we   = c_we[eff];
    assign wb_addr = c_addr[eff*ADDR_BITS +: ADDR_BITS];
    assign wb_data = c_data[eff*DATA_BITS +: DATA_BITS];
    assign wb_sel  = c_sel[eff*SEL_BITS +: SEL_BITS];
    assign wb_aux  = AUX_WIDTH'(eff);

endmodule
