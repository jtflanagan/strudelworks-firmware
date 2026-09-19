`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// tlb - the 65816 card's translation entries, each carrying the L2 way
// (docs/L1_RETHINK.md, docs/CORE_REFACTOR_65816.md rung 2; the 65C02 card's
// rtl/a2/tlb.sv is the sibling this was built from).
//
// SIXTEEN ENTRIES KEYED BY {BANK, PAGE}: the virtual page is the CPU's whole
// 24-bit address above the byte - the bank byte and the page byte - so any
// page in any bank is an entry like any other, and the bank-class machinery
// the old L1 carried (a valid bit per line per class, a two-entry bank table,
// the pair-bank test written five times) has nothing left to do: L1 compares
// a registered 16-bit candidate against sixteen registered entries, and no
// bank byte is ever in a serve cone.  Each entry names the physical page and
// WHERE L2 HOLDS IT (the set and the way), so an L1 fill is a direct way read
// (rtl/gs/page_cache.sv dr_*).
//
// TWO KINDS OF ENTRY.  In the PAIR BANKS ($00/$01/$E0/$E1) the map applies:
// the entry keeps the region index the MMU classified its page under, and on
// a map change it is valid again only if the region still classifies the same
// way, to the same physical bank, with the same fold (rv_ok: the lines' rule,
// verbatim from iline's GS arm - the wanted bank is ROM ? $FF : the virtual
// bank with its low bit set when the region goes to the auxiliary side).
// Everywhere else the translation is fixed by the physical layout (RAM $02-
// $7F, the extended ROM $E2-$EE, the panel's RAM $EF, ROM 3 $FC-$FF) and the
// entry survives every map change untouched.  PBR and DBR are still part of
// the map on this card (rung 5 takes them out); with the bank in the key a
// change of either invalidates nothing here.
//
// The install, the retention, the eviction broadcast, the kill and the two
// fill ports are the a2 module's (its header explains each).
//////////////////////////////////////////////////////////////////////////////////
module tlb #(
    parameter integer SIDX = 7,     // the page cache's set index bits
    parameter integer LEV  = 3,     // ...and way index bits
    parameter integer N    = 16
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              serve,
    input  wire              inval,
    input  wire              map_changed,
    input  wire [103:0]      rt_rd_flat,
    // L2's eviction: the way it took, the clock its engine started.
    input  wire              evict_v,
    input  wire [SIDX-1:0]   evict_set,
    input  wire [LEV-1:0]    evict_way,
    // The fill (L1-I's pulse port).
    input  wire              fi_v,
    input  wire [15:0]       fi_vpage,
    input  wire [15:0]       fi_ppn,
    input  wire [SIDX-1:0]   fi_set,
    input  wire [LEV-1:0]    fi_way,
    input  wire [3:0]        fi_reg,
    input  wire              fi_fold,
    output wire              fi_busy,
    // The second fill port (L1-D's): a request HELD until fj_ack.
    input  wire              fj_v,
    input  wire [15:0]       fj_vpage,
    input  wire [15:0]       fj_ppn,
    input  wire [SIDX-1:0]   fj_set,
    input  wire [LEV-1:0]    fj_way,
    input  wire [3:0]        fj_reg,
    input  wire              fj_fold,
    output wire              fj_ack,
    // Lookup A (the instruction side) and B (the data side).
    input  wire [15:0]       la_vpage,
    output logic             la_hit,
    output logic [15:0]      la_ppn,
    output logic [SIDX-1:0]  la_set,
    output logic [LEV-1:0]   la_way,
    input  wire [15:0]       lb_vpage,
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
    logic [15:0]     e_vp  [N];       // {bank, page}
    logic [15:0]     e_ppn [N];
    logic [SIDX-1:0] e_set [N];
    logic [LEV-1:0]  e_way [N];
    logic [3:0]      e_reg [N];
    logic            e_fold[N];
    logic            e_pair[N];       // a pair-bank page: the map applies

    function automatic logic is_pair(input [7:0] bank);
        is_pair = (bank[7:1] == 7'd0) || (bank[7:1] == 7'h70);
    endfunction

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

    // ---- the revalidation (the lines' GS rule, per pair-bank entry) ------------
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
    function automatic logic rv_ok(input [RT_W-1:0] e, input [7:0] bank, input fold,
                                   input [7:0] vbank, input pair);
        logic [7:0] want;
        begin
            want  = (e[3:2] == BS_ROM) ? 8'hFF : {vbank[7:1], vbank[0] | (e[3:2] == BS_AUX)};
            rv_ok = !pair ||
                    (e[0] &&
                     ((bank == 8'hFF) ? (e[6:5] == CLS_ROM) : (e[6:5] == CLS_RAM || e[6:5] == CLS_LC)) &&
                     (bank == want) && (fold == e[1]));
        end
    endfunction

    // ---- the install: two clocks -------------------------------------------------
    logic [IW-1:0] rr;
    logic          ins_busy;
    logic [IW-1:0] ins_idx;
    logic [15:0]   ins_vp;
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
    wire [15:0]     tk_vpage = take_i ? fi_vpage : fj_vpage;
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
                e_v[i] <= 1'b0; e_r[i] <= 1'b0; e_vp[i] <= 16'd0; e_ppn[i] <= 16'd0;
                e_set[i] <= '0; e_way[i] <= '0; e_reg[i] <= 4'd0; e_fold[i] <= 1'b0; e_pair[i] <= 1'b0;
            end
            rr <= '0; ins_busy <= 1'b0;
            cnt_fills <= 32'd0; cnt_deaths <= 32'd0;
        end else begin
            if (inval || !serve) begin
                for (int i = 0; i < N; i = i + 1) begin e_v[i] <= 1'b0; e_r[i] <= 1'b0; end
                ins_busy <= 1'b0;
            end else begin
                if (reval_q)
                    for (int i = 0; i < N; i = i + 1)
                        e_v[i] <= e_r[i] && rv_ok(rv1[i], e_ppn[i][15:8], e_fold[i], e_vp[i][15:8], e_pair[i]);
                if (evict_v)
                    for (int i = 0; i < N; i = i + 1)
                        if (e_r[i] && e_set[i] == evict_set && e_way[i] == evict_way) begin
                            e_v[i] <= 1'b0; e_r[i] <= 1'b0;
                            cnt_deaths <= cnt_deaths + 32'd1;
                        end
                if (take) begin
                    ins_idx <= pick; ins_vp <= tk_vpage; ins_ppn <= tk_ppn;
                    ins_set <= tk_set; ins_way <= tk_way; ins_reg <= tk_reg; ins_fold <= tk_fold;
                    ins_busy <= 1'b1;
                    if (e_r[pick] && (!pick_same || e_set[pick] != tk_set || e_way[pick] != tk_way)) begin
                        ref_v <= 1'b1; ref_set <= e_set[pick]; ref_way <= e_way[pick]; ref_on <= 1'b0;
                        kill_v <= 1'b1; kill_ppn <= e_ppn[pick];
                    end
                    e_v[pick] <= 1'b0; e_r[pick] <= 1'b0;
                    if (!pick_same && !pick_free) rr <= rr + IW'(1);
                end
                if (ins_busy) begin
                    ins_busy <= 1'b0;
                    e_v[ins_idx] <= 1'b1; e_r[ins_idx] <= 1'b1;
                    e_vp[ins_idx] <= ins_vp; e_ppn[ins_idx] <= ins_ppn;
                    e_set[ins_idx] <= ins_set; e_way[ins_idx] <= ins_way;
                    e_reg[ins_idx] <= ins_reg; e_fold[ins_idx] <= ins_fold;
                    e_pair[ins_idx] <= is_pair(ins_vp[15:8]);
                    ref_v <= 1'b1; ref_set <= ins_set; ref_way <= ins_way; ref_on <= 1'b1;
                    cnt_fills <= cnt_fills + 32'd1;
                end
            end
        end
    end
endmodule
