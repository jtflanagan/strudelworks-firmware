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
// ROUND-ROBIN, for now.  With two streaming clients of equal standing the
// fair thing is to alternate when both are waiting, and that is all this does:
// after a grant ends the search for the next starts one past the holder.  A
// latency-critical client (the Apple, 180 ns) goes in a strict-priority slot
// ABOVE the rotation when it arrives, gated by the free-window predicate §6
// describes; it does not go into the rotation.
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
    parameter integer AUX_WIDTH = 4
) (
    input  wire                    clk,
    input  wire                    rst,

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

    logic          held = 1'b0;       // someone has the port
    logic [IW-1:0] holder = '0;
    logic [IW-1:0] last   = '0;       // where the next search starts from

    // Rotating pick: the first requester at or after last + 1.
    logic [IW-1:0] pick;
    logic          any;
    integer        k;
    logic [IW-1:0] cand;
    always_comb begin
        pick = '0;
        any  = 1'b0;
        for (k = N; k >= 1; k = k - 1) begin
            cand = IW'((32'(last) + k) % N);
            if (c_req[cand]) begin
                pick = cand;
                any  = 1'b1;
            end
        end
    end

    // The holder keeps the port while it asks for it.  The cycle it lets go,
    // the port is idle; a new grant lands the cycle after.
    always_ff @(posedge clk) begin
        if (rst) begin
            held   <= 1'b0;
            holder <= '0;
            last   <= '0;
        end else if (held) begin
            if (!c_req[holder]) begin
                held <= 1'b0;
                last <= holder;
            end
        end else if (any) begin
            held   <= 1'b1;
            holder <= pick;
        end
    end

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_port
            assign c_gnt[g]   = held && (holder == IW'(g));
            assign c_stall[g] = !c_gnt[g] || wb_stall;
            assign c_ack[g]   = wb_ack && (wb_rdata_aux == AUX_WIDTH'(g));
        end
    endgenerate

    assign c_rdata = wb_rdata;

    assign wb_cyc  = |c_cyc;
    assign wb_stb  = held && c_stb[holder];
    assign wb_we   = c_we[holder];
    assign wb_addr = c_addr[holder*ADDR_BITS +: ADDR_BITS];
    assign wb_data = c_data[holder*DATA_BITS +: DATA_BITS];
    assign wb_sel  = c_sel[holder*SEL_BITS +: SEL_BITS];
    assign wb_aux  = AUX_WIDTH'(holder);

endmodule
