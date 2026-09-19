`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// tlb - the 65C02 card's translation entries, each carrying the L2 way
// (docs/L1_RETHINK.md, docs/CORE_REFACTOR_65C02.md rung 4).
//
// EIGHT ENTRIES, one per page L1 is working in: the virtual page (the CPU's
// address page), the physical page the map sends it to, and WHERE L2 HOLDS
// IT - the set and the way - so an L1 fill is a plain block-RAM read of one
// known way (rtl/a2/page_cache.sv dr_*), and translation lives here once per
// page instead of once per line.
//
// AN ENTRY IS FILLED FROM THE ORDINARY LOOKUP: the fetch that misses rides
// the dispatcher, the page cache names the page's placement (op_place_*),
// and L1 hands it here with the page's region, fold and physical page from
// the MMU's query.  An install takes two clocks, because it has to tell L2
// twice: the way the replaced entry pointed at is unreferenced first, then
// the new one is referenced (rtl/a2/page_cache.sv refb).  fi_busy holds the
// filler off meanwhile.
//
// AN ENTRY SURVIVES A MAP CHANGE THE WAY A LINE DID (docs/MEMORY_REFACTOR.md
// rung 3): its region index is looked up in the new read table, and it is
// valid again only if the region still classifies the same way, to the same
// bank, with the same fold - rv_ok, the lines' rule verbatim.  An entry out
// of service is RETAINED: it keeps its reference in L2 and revives when the
// map comes back.  L2's eviction broadcast (evict_v) kills the entry that
// pointed at the taken way; the invalidate walk and serve-off clear all.
//
// The lookups are combinational from the caller's REGISTERED candidates
// (eight 8-bit compares and a mux): the caller registers what it needs.
//////////////////////////////////////////////////////////////////////////////////
module tlb #(
    parameter integer SIDX = 6,     // the page cache's set index bits
    parameter integer LEV  = 3,     // ...and way index bits
    parameter integer N    = 8
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              serve,
    input  wire              inval,
    input  wire              map_changed,
    input  wire [103:0]      rt_rd_flat,
    input  wire [7:0]        rwb_p1,
    // L2's eviction: the way it took, the clock its engine started.
    input  wire              evict_v,
    input  wire [SIDX-1:0]   evict_set,
    input  wire [LEV-1:0]    evict_way,
    // The fill.
    input  wire              fi_v,
    input  wire [7:0]        fi_vpage,
    input  wire [15:0]       fi_ppn,
    input  wire [SIDX-1:0]   fi_set,
    input  wire [LEV-1:0]    fi_way,
    input  wire [3:0]        fi_reg,
    input  wire              fi_fold,
    output wire              fi_busy,
    // The second fill port (L1-D's): a request HELD until fj_ack, taken on
    // any clock the first port is quiet and no install is in flight.
    input  wire              fj_v,
    input  wire [7:0]        fj_vpage,
    input  wire [15:0]       fj_ppn,
    input  wire [SIDX-1:0]   fj_set,
    input  wire [LEV-1:0]    fj_way,
    input  wire [3:0]        fj_reg,
    input  wire              fj_fold,
    output wire              fj_ack,
    // Lookup A (the instruction side) and B (the data side, rung 5).
    input  wire [7:0]        la_vpage,
    output logic             la_hit,
    output logic [15:0]      la_ppn,
    output logic [SIDX-1:0]  la_set,
    output logic [LEV-1:0]   la_way,
    input  wire [7:0]        lb_vpage,
    output logic             lb_hit,
    output logic [15:0]      lb_ppn,
    output logic [SIDX-1:0]  lb_set,
    output logic [LEV-1:0]   lb_way,
    // The references, to L2.
    output logic             ref_v,
    output logic [SIDX-1:0]  ref_set,
    output logic [LEV-1:0]   ref_way,
    output logic             ref_on,
    // An entry replaced: its page, so buffers holding its lines die.
    output logic             kill_v,
    output logic [15:0]      kill_ppn,
    output logic [31:0]      cnt_fills,
    output logic [31:0]      cnt_deaths
);
    localparam integer IW = $clog2(N);
    localparam integer RT_W = 8;
    localparam integer NREG = 13;
    localparam [1:0] BS_AUX = 2'd1, BS_ROM = 2'd2;
    localparam [1:0] CLS_RAM = 2'd1, CLS_LC = 2'd2, CLS_ROM = 2'd3;

    logic            e_v   [N];
    logic            e_r   [N];       // retained: revivable, still referenced in L2
    logic [7:0]      e_vp  [N];
    logic [15:0]     e_ppn [N];
    logic [SIDX-1:0] e_set [N];
    logic [LEV-1:0]  e_way [N];
    logic [3:0]      e_reg [N];
    logic            e_fold[N];

    // ---- the lookups ----------------------------------------------------------
    always_comb begin
        la_hit = 1'b0; la_ppn = 16'd0; la_set = '0; la_way = '0;
        lb_hit = 1'b0; lb_ppn = 16'd0; lb_set = '0; lb_way = '0;
        for (int i = 0; i < N; i = i + 1) begin
            if (e_v[i] && e_vp[i] == la_vpage) begin
                la_hit = 1'b1; la_ppn = e_ppn[i]; la_set = e_set[i]; la_way = e_way[i];
            end
            if (e_v[i] && e_vp[i] == lb_vpage) begin
                lb_hit = 1'b1; lb_ppn = e_ppn[i]; lb_set = e_set[i]; lb_way = e_way[i];
            end
        end
    end

    // ---- the revalidation (the lines' rule, per entry) -------------------------
    wire [RT_W-1:0] rt_rd [0:15];
    genvar gr;
    generate for (gr = 0; gr < 16; gr = gr + 1) begin : g_rt
        if (gr < NREG) begin : g_real
            assign rt_rd[gr] = rt_rd_flat[gr*RT_W +: RT_W];
        end else begin : g_none
            assign rt_rd[gr] = '0;
        end
    end endgenerate
    logic reval_q;
    always_ff @(posedge clk) reval_q <= map_changed && !rst;
    logic [RT_W-1:0] rv1 [N];
    always_ff @(posedge clk) for (int i = 0; i < N; i = i + 1) rv1[i] <= rt_rd[e_reg[i]];
    function automatic logic rv_ok(input [RT_W-1:0] e, input [7:0] bank, input fold);
        logic [7:0] want;
        begin
            want  = (e[3:2] == BS_AUX) ? rwb_p1 : (e[3:2] == BS_ROM) ? 8'hFF : 8'd0;
            rv_ok = e[0] &&
                    ((bank == 8'hFF) ? (e[6:5] == CLS_ROM) : (e[6:5] == CLS_RAM || e[6:5] == CLS_LC)) &&
                    (bank == want) && (fold == e[1]);
        end
    endfunction

    // ---- the install: two clocks -------------------------------------------------
    // The slot: an entry already naming this virtual page (valid or retained)
    // is reused, else a free one, else the round-robin victim.
    logic [IW-1:0] rr;
    logic          ins_busy;          // clock 2 of an install: the new reference
    logic [IW-1:0] ins_idx;
    logic [7:0]    ins_vp;
    logic [15:0]   ins_ppn;
    logic [SIDX-1:0] ins_set;
    logic [LEV-1:0]  ins_way;
    logic [3:0]    ins_reg;
    logic          ins_fold;
    assign fi_busy = ins_busy;

    logic [IW-1:0] pick;
    logic          pick_same, pick_free;
    always_comb begin
        pick = rr; pick_same = 1'b0; pick_free = 1'b0;
        for (int i = N - 1; i >= 0; i = i - 1) if (!e_r[i]) begin pick = IW'(i); pick_free = 1'b1; end
        for (int i = N - 1; i >= 0; i = i - 1) if (e_r[i] && e_vp[i] == tk_vpage) begin pick = IW'(i); pick_same = 1'b1; end
    end
    wire take_i = fi_v && !ins_busy && serve && !inval;
    wire take_j = fj_v && !fi_v && !ins_busy && serve && !inval;
    wire take   = take_i || take_j;
    assign fj_ack = take_j;
    wire [7:0]      tk_vpage = take_i ? fi_vpage : fj_vpage;
    wire [15:0]     tk_ppn   = take_i ? fi_ppn   : fj_ppn;
    wire [SIDX-1:0] tk_set   = take_i ? fi_set   : fj_set;
    wire [LEV-1:0]  tk_way   = take_i ? fi_way   : fj_way;
    wire [3:0]      tk_reg   = take_i ? fi_reg   : fj_reg;
    wire            tk_fold  = take_i ? fi_fold  : fj_fold;

    always_ff @(posedge clk) begin
        ref_v  <= 1'b0;
        kill_v <= 1'b0;
        if (rst) begin
            for (int i = 0; i < N; i = i + 1) begin
                e_v[i] <= 1'b0; e_r[i] <= 1'b0; e_vp[i] <= 8'd0; e_ppn[i] <= 16'd0;
                e_set[i] <= '0; e_way[i] <= '0; e_reg[i] <= 4'd0; e_fold[i] <= 1'b0;
            end
            rr <= '0; ins_busy <= 1'b0;
            cnt_fills <= 32'd0; cnt_deaths <= 32'd0;
        end else begin
            if (inval || !serve) begin
                for (int i = 0; i < N; i = i + 1) begin e_v[i] <= 1'b0; e_r[i] <= 1'b0; end
                ins_busy <= 1'b0;
            end else begin
                // A map change: one clock later every entry's valid bit is the
                // new map's answer for the identity it was filled with.
                if (reval_q)
                    for (int i = 0; i < N; i = i + 1) e_v[i] <= e_r[i] && rv_ok(rv1[i], e_ppn[i][15:8], e_fold[i]);
                // L2 took a way an entry pointed at: the entry dies outright.
                if (evict_v)
                    for (int i = 0; i < N; i = i + 1)
                        if (e_r[i] && e_set[i] == evict_set && e_way[i] == evict_way) begin
                            e_v[i] <= 1'b0; e_r[i] <= 1'b0;
                            cnt_deaths <= cnt_deaths + 32'd1;
                        end
                // Clock 1: the replaced entry's reference goes, its lines die.
                if (take) begin
                    ins_idx <= pick; ins_vp <= tk_vpage; ins_ppn <= tk_ppn;
                    ins_set <= tk_set; ins_way <= tk_way; ins_reg <= tk_reg; ins_fold <= tk_fold;
                    ins_busy <= 1'b1;
                    if (e_r[pick] && !pick_same) begin
                        ref_v <= 1'b1; ref_set <= e_set[pick]; ref_way <= e_way[pick]; ref_on <= 1'b0;
                        kill_v <= 1'b1; kill_ppn <= e_ppn[pick];
                    end else if (e_r[pick] && pick_same &&
                                 (e_set[pick] != tk_set || e_way[pick] != tk_way)) begin
                        // the same page, placed elsewhere now: the old way is let go
                        ref_v <= 1'b1; ref_set <= e_set[pick]; ref_way <= e_way[pick]; ref_on <= 1'b0;
                        kill_v <= 1'b1; kill_ppn <= e_ppn[pick];
                    end
                    e_v[pick] <= 1'b0; e_r[pick] <= 1'b0;
                    if (!pick_same && !pick_free) rr <= rr + IW'(1);
                end
                // Clock 2: the entry stands, and its way is referenced.
                if (ins_busy) begin
                    ins_busy <= 1'b0;
                    e_v[ins_idx] <= 1'b1; e_r[ins_idx] <= 1'b1;
                    e_vp[ins_idx] <= ins_vp; e_ppn[ins_idx] <= ins_ppn;
                    e_set[ins_idx] <= ins_set; e_way[ins_idx] <= ins_way;
                    e_reg[ins_idx] <= ins_reg; e_fold[ins_idx] <= ins_fold;
                    ref_v <= 1'b1; ref_set <= ins_set; ref_way <= ins_way; ref_on <= 1'b1;
                    cnt_fills <= cnt_fills + 32'd1;
                end
            end
        end
    end
endmodule
