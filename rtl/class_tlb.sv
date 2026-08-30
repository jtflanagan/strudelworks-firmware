`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// class_tlb - a page-granular cache of the MMU's answer.
//
// Everything the IIe's memory map decides, it decides per 256-byte page, so
// classification and translation cache perfectly at that grain: 256 entries
// direct-mapped by addr[15:8] cover the whole 64K space, and there is no such
// thing as a capacity or conflict miss - only cold entries after a flush.
// With a valid entry in hand, an L1 cache knows in one asynchronous LUTRAM
// read whether it may serve an access and which physical line it wants,
// without a cycle - or the classifier's long combinational path - spent
// asking rtl/apple_mmu.sv.
//
// Each entry holds BOTH views of its page, because on this machine they
// really differ: a read and a write to the same address can reach different
// banks (RAMRD vs RAMWRT), different classes ($D000 reads ROM while writes
// land in the language card), different everything.  The entry is exactly
// apple_mmu's t_* answer, stored: {r_ok, r_ppage, w_ok, w_ppage}.
//
// INVALIDATE-ALL IN ONE CLOCK, NEVER UPDATE IN PLACE.  A map change (any
// mapping soft-switch access, RES', INTC8ROM moving, the ROM arriving -
// apple_mmu.map_changed) can remap many pages at once, so no scheme that
// rewrites entries can keep up.  This one never tries: the payloads sit in
// LUTRAM, which cannot flash-clear, and the VALIDITY sits beside them in a
// 256-bit flip-flop vector, which can.  flush clears the vector at its edge;
// entries refill lazily, one classify each, as pages are touched again.  The
// alternative epoch-tag scheme was considered and rejected: without a
// scrub-per-flush rule a counter wrap lets a long-untouched entry falsely
// match, and with one it is three interacting mechanisms where this is none.
//
// A flush and an install can collide on one clock: the flush wins, the
// install dies with everything else.  The installer sees its entry invalid
// and asks again, which is the retry it already knows how to do.
//////////////////////////////////////////////////////////////////////////////////
module class_tlb (
    input  wire        clk,
    input  wire        rst,
    input  wire        flush,       // apple_mmu.map_changed: clear every entry

    // Lookup: asynchronous, an address in and the page's entry out this same
    // clock.  l_hit gates everything; with it low the payload is stale.
    input  wire [15:0] l_addr,
    output wire        l_hit,
    output wire        l_r_ok,      // reads L1-servable
    output wire [16:0] l_r_ppage,   // {rom_space, pa[23:8]} for reads
    output wire        l_w_ok,      // a write lands in the image
    output wire [16:0] l_w_ppage,   // {1'b0, pa[23:8]} for writes

    // Install: one entry per clock, apple_mmu's t_* answer for w_page.
    input  wire        w_en,
    input  wire [7:0]  w_page,
    input  wire        w_r_ok,
    input  wire [16:0] w_r_ppage,
    input  wire        w_w_ok,
    input  wire [16:0] w_w_ppage
);

    localparam int EW = 1 + 17 + 1 + 17;    // {r_ok, r_ppage, w_ok, w_ppage}

    (* ram_style = "distributed" *) logic [EW-1:0] entries [0:255];
    logic [255:0] vld;

    wire [7:0]    idx = l_addr[15:8];
    wire [EW-1:0] ent = entries[idx];

    assign l_hit     = vld[idx];
    assign l_r_ok    = ent[35];
    assign l_r_ppage = ent[34:18];
    assign l_w_ok    = ent[17];
    assign l_w_ppage = ent[16:0];

    always_ff @(posedge clk) begin
        if (w_en) entries[w_page] <= {w_r_ok, w_r_ppage, w_w_ok, w_w_ppage};

        // The vector, not the payload, is the truth - and flush outranks the
        // install racing it: an entry computed from the old map must not
        // survive into the new one.
        if (rst || flush)  vld <= 256'd0;
        else if (w_en)     vld[w_page] <= 1'b1;
    end

endmodule
