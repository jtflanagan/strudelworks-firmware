`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// l1i - the 65C02 card's instruction side of L1 (docs/L1_RETHINK.md,
// docs/CORE_REFACTOR_65C02.md rung 4).  It replaces rtl/iline.sv and
// rtl/iscan.sv: two 16-byte line buffers in flops, the same "+1" predictor,
// the same early branch resolution and the same one-clock serve, and
// nothing else - no cache of its own, no retained set, no scanner.
//
// WHAT CHANGED UNDERNEATH.  A line is fetched by a DIRECT WAY READ of the
// page cache (dr_*): the TLB (rtl/a2/tlb.sv) says which set and way L2
// holds the page in, and the row is here two clocks after the ack, no
// directory, no compare.  A page the TLB does not know is learned from the
// ordinary lookup: the fetch rides the dispatcher, the page cache names the
// page's placement (op_place_*), and the entry is filled from that and the
// MMU's own classification of the page (p_*), once per page.  Translation
// therefore lives in eight TLB entries instead of in every line, and a line
// buffer carries only its page, its line and where L2 holds it - for the
// snoops and the eviction broadcast.
//
// THE SERVE IS ILINE'S, KEPT WHOLE: the byte and its select are registers,
// fed by the predictor's three candidates (step, recovery, hold) looked up
// in parallel from registers, and the late retire verdict only picks (the
// house rule: late verdicts pick, they never compute).  A taken branch or
// jump resolves at its operand from registered truth and serves with zero
// stall when its target line is in the other buffer; otherwise its line is
// fetched early (the want travels while the branch's dummies run) and the
// target re-aims the predictor a few clocks later.
//
// THE PIN replaces the scanner's pinned pair: the buffer a taken branch
// last landed in is not a prefetch's victim, so a loop held whole in the
// two buffers refetches nothing.  A fetch miss may still take it.
//
// COHERENCE, unchanged in kind: every write that lands in the image (the
// classified stream's, and the data side's posted write the clock after it
// retired) is compared by PHYSICAL identity against both buffers and the
// read in flight, and kills what it matches - there is no splice here.  A
// map change kills both buffers and the read in flight outright (two lines
// cost nothing to refetch; the TLB is what survives a map change).  L2's
// eviction of a way and the TLB's replacement of an entry kill the buffers
// that came from them.
//
// THE $Cxxx RULES ARE THE MMU'S: an entry is filled only for a page the map
// calls front-servable (p_fs, which carries the page-$C3 rule), the $CFFx
// line is never wanted, and a $C3 serve is refused on the clock the
// registered INTC8ROM latch reads clear (the RTS after the 80-column
// firmware's own LDX $CFFF rides the sequencer whatever the spacing).
//////////////////////////////////////////////////////////////////////////////////
module l1i #(
    parameter integer SIDX = 6,
    parameter integer LEV  = 3
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,
    // The core: pc_addr REGISTER-DIRECT (rtl/cpu65c02.sv), the flags likewise.
    input  wire [15:0] pc_addr,
    input  wire        cpu_rw,
    input  wire        cpu_sync,
    input  wire        cyc_is_i,
    input  wire [7:0]  p_flags,
    output wire        cyc_en,
    output wire [7:0]  i_din,
    // The sequencer's path through (rtl/accel_seq.sv).
    input  wire        accel_cyc_en,
    input  wire [7:0]  accel_din,
    input  wire        turbo_en,
    input  wire        turbo_ok,
    output wire        claim,
    output wire        turbo_commit,
    output wire        turbo_sync,
    output logic       tick_q,
    output logic       tev_valid,
    output logic [15:0] tev_addr,
    output logic [7:0] tev_data,
    output logic       tev_sync,
    input  wire        ev_room,
    // The MMU: the wanted page's classification (for a TLB fill), the map's edge.
    output wire [23:0] p_addr,
    input  wire [15:0] p_ppn,
    input  wire [3:0]  p_reg,
    input  wire        p_fold,
    input  wire        p_fs,
    input  wire        map_changed,
    input  wire        map_settling,
    input  wire        intc8rom,
    // The TLB (rtl/a2/tlb.sv): lookup A, the fill, a replaced entry's page.
    output wire [7:0]  la_vpage,
    input  wire        la_hit,
    input  wire [15:0] la_ppn,
    input  wire [SIDX-1:0] la_set,
    input  wire [LEV-1:0]  la_way,
    output logic       fi_v,
    output logic [7:0] fi_vpage,
    output logic [15:0] fi_ppn,
    output logic [SIDX-1:0] fi_set,
    output logic [LEV-1:0]  fi_way,
    output logic [3:0] fi_reg,
    output logic       fi_fold,
    input  wire        fi_busy,
    input  wire        kill_v,
    input  wire [15:0] kill_ppn,
    // The page cache (rtl/a2/page_cache.sv): the direct way read, the
    // placement, the eviction.
    output logic       dr_req,
    output logic [SIDX-1:0] dr_set,
    output logic [LEV-1:0]  dr_way,
    output logic [3:0] dr_line,
    input  wire        dr_ack,
    input  wire        dr_done,
    input  wire [127:0] dr_row,
    input  wire        op_place_v,
    input  wire [15:0] op_place_ppn,
    input  wire [SIDX-1:0] op_place_set,
    input  wire [LEV-1:0]  op_place_way,
    input  wire        evict_v,
    input  wire [SIDX-1:0] evict_set,
    input  wire [LEV-1:0]  evict_way,
    // The write snoop: the MMU's classified op (P1), and the data side's
    // posted write the clock after it retired.
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [15:0] cl_ppn,
    input  wire [15:0] cl_off,
    input  wire        ws_valid,
    input  wire [15:0] ws_ppn,
    input  wire [7:0]  ws_off8,
    // The flushes, the books.
    input  wire        serve,
    input  wire        inval,
    input  wire [3:0]  dbg_sel,
    output logic [31:0] dbg_val,
    output wire        fill_busy
);
    // ---- the two buffers ----------------------------------------------------
    logic            v     [0:1];
    logic [11:0]     vtag  [0:1];     // addr[15:4]
    logic [15:0]     b_ppn [0:1];
    logic [SIDX-1:0] b_set [0:1];
    logic [LEV-1:0]  b_way [0:1];
    logic [127:0]    ldata [0:1];
    logic            cur;             // the buffer the fetch stream is in
    logic            pin_v, pin;      // the buffer a taken branch last landed in

    // ---- the INTC8ROM latch, registered once, and the exclusions -----------
    logic intc8rom_q;
    always_ff @(posedge clk) intc8rom_q <= rst ? 1'b0 : intc8rom;
    function automatic logic excl(input [11:0] tag);
        excl = (tag[11:4] == 8'hC3 && !intc8rom_q) || (tag == 12'hCFF);
    endfunction

    // ---- the serve (iline's) -----------------------------------------------
    wire hit0 = v[0] && (pc_addr[15:4] == vtag[0]);
    wire hit1 = v[1] && (pc_addr[15:4] == vtag[1]);
    logic [15:0] exp_q;
    logic        lhit_q;
    logic [7:0]  i_byte_q;
    wire [15:0] exp_inc = exp_q + 16'd1;
    wire ihit  = cyc_is_i && cpu_rw && (hit0 || hit1);
    wire hslot = !hit0;

    wire        hi0 = v[0] && (exp_inc[15:4] == vtag[0]);
    wire        hi1 = v[1] && (exp_inc[15:4] == vtag[1]);
    wire        hc0 = v[0] && (pc_addr[15:4] == vtag[0]);
    wire        hc1 = v[1] && (pc_addr[15:4] == vtag[1]);
    wire        hh0 = v[0] && (exp_q[15:4]   == vtag[0]);
    wire        hh1 = v[1] && (exp_q[15:4]   == vtag[1]);
    wire [7:0]  b_inc  = hi0 ? ldata[0][8 * exp_inc[3:0] +: 8] : ldata[1][8 * exp_inc[3:0] +: 8];
    wire [7:0]  b_cur  = hc0 ? ldata[0][8 * pc_addr[3:0] +: 8] : ldata[1][8 * pc_addr[3:0] +: 8];
    wire [7:0]  b_hold = hh0 ? ldata[0][8 * exp_q[3:0]   +: 8] : ldata[1][8 * exp_q[3:0]   +: 8];

    // ---- early branch resolution (iline's, the user's design) --------------
    localparam [1:0] BK_NONE = 2'd0, BK_BR = 2'd1, BK_ABS = 2'd2;
    logic [1:0]  bk_q;
    logic        bk_hi;
    logic [7:0]  br_op, lo_q;
    logic        tgt_v;
    logic [15:0] tgt_q;
    logic        tgt_lhit_q;
    logic [7:0]  tgt_byte_q;

    wire i_serve = cyc_en && cyc_is_i && cpu_rw;
    wire op_is_branch = (i_din[4:0] == 5'b10000) || (i_din == 8'h80);
    wire op_is_abs    = (i_din == 8'h4C) || (i_din == 8'h20);
    wire br_flag  = (br_op[7:6] == 2'b00) ? p_flags[7] :
                    (br_op[7:6] == 2'b01) ? p_flags[6] :
                    (br_op[7:6] == 2'b10) ? p_flags[0] : p_flags[1];
    wire br_taken = (br_op == 8'h80) || (br_flag == br_op[5]);
    wire [15:0] br_tgt = pc_addr + 16'd1 + {{8{i_din[7]}}, i_din};
    wire resolving = i_serve && !cpu_sync &&
                     ((bk_q == BK_BR) || (bk_q == BK_ABS && bk_hi));
    wire [15:0] res_tgt   = (bk_q == BK_BR) ? br_tgt : {i_din, lo_q};
    wire        res_taken = (bk_q == BK_BR) ? br_taken : 1'b1;
    wire        spec_pending = (bk_q == BK_ABS && bk_hi);
    wire [15:0] spec_tgt = {i_byte_q, lo_q};
    wire [15:0] tgt_look = spec_pending ? spec_tgt : tgt_q;
    wire [15:0] tgt_inc  = tgt_q + 16'd1;
    wire        ht0 = v[0] && (tgt_look[15:4] == vtag[0]);
    wire        ht1 = v[1] && (tgt_look[15:4] == vtag[1]);
    wire        hg0 = v[0] && (tgt_inc[15:4]  == vtag[0]);
    wire        hg1 = v[1] && (tgt_inc[15:4]  == vtag[1]);
    wire [7:0] b_tgt    = ht0 ? ldata[0][8 * tgt_look[3:0] +: 8] : ldata[1][8 * tgt_look[3:0] +: 8];
    wire [7:0] b_tgtinc = hg0 ? ldata[0][8 * tgt_inc[3:0]  +: 8] : ldata[1][8 * tgt_inc[3:0]  +: 8];
    wire tgt_here  = tgt_v && cyc_is_i && cpu_rw && (pc_addr == tgt_q);
    wire tgt_serve = tgt_here && tgt_lhit_q && !(lhit_q && (exp_q == pc_addr));

    // ---- the snoops, combinational: an image write against the buffers ------
    wire snp = cl_valid && !cl_rw && cl_wr_image;
    wire snp_kill0 = (snp      && v[0] && (b_ppn[0] == cl_ppn) && (vtag[0][3:0] == cl_off[7:4])) ||
                     (ws_valid && v[0] && (b_ppn[0] == ws_ppn) && (vtag[0][3:0] == ws_off8[7:4]));
    wire snp_kill1 = (snp      && v[1] && (b_ppn[1] == cl_ppn) && (vtag[1][3:0] == cl_off[7:4])) ||
                     (ws_valid && v[1] && (b_ppn[1] == ws_ppn) && (vtag[1][3:0] == ws_off8[7:4]));
    // ...and the other deaths: L2's eviction of a way, the TLB's replacement.
    wire ev_kill0 = evict_v && v[0] && (b_set[0] == evict_set) && (b_way[0] == evict_way);
    wire ev_kill1 = evict_v && v[1] && (b_set[1] == evict_set) && (b_way[1] == evict_way);
    wire tk_kill0 = kill_v && v[0] && (b_ppn[0] == kill_ppn);
    wire tk_kill1 = kill_v && v[1] && (b_ppn[1] == kill_ppn);
    wire kill0 = snp_kill0 || ev_kill0 || tk_kill0;
    wire kill1 = snp_kill1 || ev_kill1 || tk_kill1;

    wire kill_now = map_settling || inval || !serve ||
                    (pc_addr[15:8] == 8'hC3 && !intc8rom_q) ||
                    (hslot ? kill1 : kill0);

    // ---- the retire ---------------------------------------------------------
    wire retire = !cpu_rst && ihit && turbo_ok && !kill_now && ev_room &&
                  ((lhit_q && (exp_q == pc_addr)) || tgt_serve);
    assign turbo_commit = retire;
    assign turbo_sync   = retire && cpu_sync;
    assign cyc_en       = accel_cyc_en || retire;
    assign i_din        = tgt_serve ? tgt_byte_q :
                          lhit_q    ? i_byte_q  : accel_din;

    // ---- the wants ------------------------------------------------------------
    // The fetch on offer that nothing holds; the branch target resolved early;
    // the next line once the stream is in the last quarter of this one.
    wire want_fetch = turbo_en && cyc_is_i && cpu_rw && !ihit && !cpu_rst;
    logic        ew_v;
    logic [11:0] ew_tag;
    wire [11:0]  nx_tag = exp_q[15:4] + 12'd1;
    wire nx_held = (v[0] && vtag[0] == nx_tag) || (v[1] && vtag[1] == nx_tag);
    wire want_next = turbo_en && lhit_q && exp_q[3:2] == 2'b11 && !nx_held &&
                     !(pin_v && pin == !cur);          // the pinned buffer is not a prefetch's victim
    wire want_any  = want_fetch || ew_v || want_next;
    wire [11:0] want_tag = want_fetch ? pc_addr[15:4] : ew_v ? ew_tag : nx_tag;
    wire        want_is_fetch = want_fetch;

    // ---- the engine --------------------------------------------------------
    localparam [2:0] F_IDLE = 3'd0, F_DR = 3'd1, F_W1 = 3'd2, F_W2 = 3'd3, F_TLB = 3'd4;
    logic [2:0]      fst;
    logic [11:0]     f_vtag;
    logic [15:0]     f_ppn;
    logic [SIDX-1:0] f_set;
    logic [LEV-1:0]  f_way;
    logic [3:0]      f_reg;
    logic            f_fold;
    logic            f_slot;

    assign la_vpage = want_tag[11:4];
    assign p_addr   = {8'd0, want_tag, 4'h0};
    assign fill_busy = (fst == F_DR) || (fst == F_W1) || (fst == F_W2);
    assign claim = turbo_en && cyc_is_i && cpu_rw &&
                   (ihit || (fill_busy && (f_vtag == pc_addr[15:4])));

    // The read in flight (or the wait on the TLB) dies with the map, with a
    // write into its line, with L2 taking its way, with the TLB dropping its
    // page.  Idle, the stale f_* compare with nothing.
    wire f_live = (fst != F_IDLE);
    wire f_snp = (snp      && (f_ppn == cl_ppn) && (f_vtag[3:0] == cl_off[7:4])) ||
                 (ws_valid && (f_ppn == ws_ppn) && (f_vtag[3:0] == ws_off8[7:4]));
    wire f_restart = f_live && (map_changed || inval || !serve || f_snp ||
                     (evict_v && f_set == evict_set && f_way == evict_way) ||
                     (kill_v && f_ppn == kill_ppn));

    // The victim buffer: for the fetch's own line the other buffer, pinned or
    // not; for a prefetch never the pinned one (the want is not raised then).
    wire victim = !cur;

    // ---- the predictor's update (iline's) ----------------------------------
    wire step    = retire || (accel_cyc_en && cyc_is_i && cpu_rw && (pc_addr == exp_q));
    wire recover = turbo_en && cyc_is_i && cpu_rw && !step && (pc_addr != exp_q);

    always_ff @(posedge clk) begin
        if (rst || cpu_rst) begin
            exp_q <= 16'd0; lhit_q <= 1'b0; i_byte_q <= 8'd0;
            bk_q <= BK_NONE; bk_hi <= 1'b0; br_op <= 8'd0; lo_q <= 8'd0;
            tgt_v <= 1'b0; tgt_q <= 16'd0; tgt_lhit_q <= 1'b0; tgt_byte_q <= 8'd0;
        end else begin
            if (retire && tgt_serve) begin
                exp_q    <= tgt_inc;
                lhit_q   <= (hg0 || hg1);
                i_byte_q <= b_tgtinc;
            end else begin
                exp_q    <= step ? exp_inc : recover ? pc_addr : exp_q;
                lhit_q   <= step    ? (hi0 || hi1) :
                            recover ? (hc0 || hc1) : (hh0 || hh1);
                i_byte_q <= step ? b_inc : recover ? b_cur : b_hold;
            end
            tgt_lhit_q <= (resolving ? (res_taken && lhit_q && !tgt_serve) : tgt_v) && (ht0 || ht1);
            tgt_byte_q <= b_tgt;
            if (i_serve) begin
                if (cpu_sync) begin
                    bk_q  <= (turbo_en && op_is_branch) ? BK_BR :
                             (turbo_en && op_is_abs)    ? BK_ABS : BK_NONE;
                    bk_hi <= 1'b0;
                    br_op <= i_din;
                    tgt_v <= 1'b0;
                end else if (bk_q == BK_BR) begin
                    bk_q  <= BK_NONE;
                    tgt_v <= br_taken;
                    tgt_q <= br_tgt;
                end else if (bk_q == BK_ABS && !bk_hi) begin
                    lo_q  <= i_din;
                    bk_hi <= 1'b1;
                end else if (bk_q == BK_ABS && bk_hi) begin
                    bk_q  <= BK_NONE;
                    tgt_v <= 1'b1;
                    tgt_q <= {i_din, lo_q};
                end
            end
        end
    end

    // The early want for a taken branch's line.
    wire ew_taken = (fst == F_IDLE) && !map_settling && !want_fetch && ew_v;   // the engine looked at it
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || !turbo_en) begin
            ew_v <= 1'b0; ew_tag <= 12'd0;
        end else begin
            if (ew_taken) ew_v <= 1'b0;
            if (resolving && res_taken && !excl(res_tgt[15:4]) &&
                !((v[0] && vtag[0] == res_tgt[15:4]) || (v[1] && vtag[1] == res_tgt[15:4]))) begin
                ew_v   <= 1'b1;
                ew_tag <= res_tgt[15:4];
            end
        end
    end

    // ---- the books -----------------------------------------------------------
    logic [31:0] cnt_slow_i, cnt_fills, cnt_tgt_serves, cnt_kills, cnt_unserv, cnt_tlb_waits, cnt_prefetch;

    // ---- the engine, the buffers, the events -----------------------------------
    always_ff @(posedge clk) begin
        tick_q    <= retire;
        tev_valid <= retire;
        if (retire) begin
            tev_addr <= pc_addr;
            tev_data <= i_din;
            tev_sync <= cpu_sync;
        end
        fi_v <= 1'b0;

        if (rst) begin
            v[0] <= 1'b0; v[1] <= 1'b0;
            vtag[0] <= 12'd0; vtag[1] <= 12'd0;
            b_ppn[0] <= 16'd0; b_ppn[1] <= 16'd0;
            b_set[0] <= '0; b_set[1] <= '0; b_way[0] <= '0; b_way[1] <= '0;
            cur <= 1'b0; pin_v <= 1'b0; pin <= 1'b0;
            fst <= F_IDLE; f_vtag <= 12'd0; f_ppn <= 16'd0; f_set <= '0; f_way <= '0;
            f_reg <= 4'd0; f_fold <= 1'b0; f_slot <= 1'b0;
            dr_req <= 1'b0; dr_set <= '0; dr_way <= '0; dr_line <= 4'd0;
            cnt_slow_i <= 32'd0; cnt_fills <= 32'd0; cnt_tgt_serves <= 32'd0;
            cnt_kills <= 32'd0; cnt_unserv <= 32'd0; cnt_tlb_waits <= 32'd0; cnt_prefetch <= 32'd0;
        end else begin
            if (accel_cyc_en && cyc_is_i && cpu_rw) cnt_slow_i <= cnt_slow_i + 32'd1;
            if (retire && tgt_serve) cnt_tgt_serves <= cnt_tgt_serves + 32'd1;

            // Where the stream is, and the pin.
            if (hit0 && cyc_is_i && cpu_rw) cur <= 1'b0;
            if (hit1 && cyc_is_i && cpu_rw) cur <= 1'b1;
            if (retire && tgt_serve) begin pin_v <= 1'b1; pin <= hslot; end

            // The kills.
            if (kill0) begin v[0] <= 1'b0; cnt_kills <= cnt_kills + 32'd1; end
            if (kill1) begin v[1] <= 1'b0; cnt_kills <= cnt_kills + 32'd1; end

            // The engine.
            if (f_restart) begin
                if (fst == F_DR) dr_req <= 1'b0;
                fst <= F_IDLE;
            end else case (fst)
                // Nothing launches during the settle: the TLB's entries are
                // revalidated one clock after map_changed, and a lookup on
                // either of those clocks would name the OLD map's page (the
                // bankfetch scenario: RAMRD on, the next opcode is aux's).
                F_IDLE: if (want_any && !map_settling) begin
                    if (excl(want_tag)) begin
                        cnt_unserv <= cnt_unserv + 32'd1;   // the fetch rides the sequencer
                    end else if (la_hit) begin
                        f_vtag  <= want_tag;
                        f_ppn   <= la_ppn;
                        f_set   <= la_set;
                        f_way   <= la_way;
                        f_slot  <= victim;
                        dr_req  <= 1'b1;
                        dr_set  <= la_set;
                        dr_way  <= la_way;
                        dr_line <= want_tag[3:0];
                        if (!want_is_fetch && !ew_v) cnt_prefetch <= cnt_prefetch + 32'd1;
                        fst <= F_DR;
                    end else if (!p_fs) begin
                        cnt_unserv <= cnt_unserv + 32'd1;   // never servable: BUS class, or $C3 with the latch clear
                    end else if (want_is_fetch || ew_v) begin
                        // The page is not in the TLB: the fetch rides the
                        // dispatcher, whose lookup names the placement.
                        f_vtag <= want_tag;
                        f_ppn  <= p_ppn;
                        f_reg  <= p_reg;
                        f_fold <= p_fold;
                        cnt_tlb_waits <= cnt_tlb_waits + 32'd1;
                        fst <= F_TLB;
                    end
                    // a prefetch into an unknown page is not worth a wait
                end
                F_TLB: begin
                    if (op_place_v && (op_place_ppn == f_ppn) && !fi_busy) begin
                        fi_v     <= 1'b1;
                        fi_vpage <= f_vtag[11:4];
                        fi_ppn   <= f_ppn;
                        fi_set   <= op_place_set;
                        fi_way   <= op_place_way;
                        fi_reg   <= f_reg;
                        fi_fold  <= f_fold;
                        fst <= F_IDLE;
                    end else if (!(want_any && want_tag[11:4] == f_vtag[11:4])) begin
                        fst <= F_IDLE;                      // the stream moved on
                    end
                end
                F_DR: if (dr_ack) begin dr_req <= 1'b0; fst <= F_W1; end
                F_W1: fst <= F_W2;
                F_W2: begin
                    // dr_done stands here with the row (two clocks after the ack).
`ifndef SYNTHESIS
                    if (!dr_done) $error("l1i: no dr_done two clocks after the ack");
`endif
                    ldata[f_slot] <= dr_row;
                    v[f_slot]     <= 1'b1;
                    vtag[f_slot]  <= f_vtag;
                    b_ppn[f_slot] <= f_ppn;
                    b_set[f_slot] <= f_set;
                    b_way[f_slot] <= f_way;
                    if (pin_v && pin == f_slot) pin_v <= 1'b0;   // the pinned line is gone
                    cnt_fills <= cnt_fills + 32'd1;
                    fst <= F_IDLE;
                end
                default: fst <= F_IDLE;
            endcase

            if (map_changed || inval || !serve) begin
                v[0] <= 1'b0; v[1] <= 1'b0;
                pin_v <= 1'b0;
            end
        end
    end

    // The debug pair's window.
    always_comb begin
        case (dbg_sel)
            4'd0:  dbg_val = cnt_slow_i;
            4'd1:  dbg_val = cnt_fills;
            4'd2:  dbg_val = cnt_tgt_serves;
            4'd3:  dbg_val = cnt_kills;
            4'd4:  dbg_val = cnt_unserv;
            4'd5:  dbg_val = cnt_tlb_waits;
            4'd6:  dbg_val = cnt_prefetch;
            4'd14: dbg_val = {v[1], v[0], fst, cur, pin_v, pin, turbo_en, serve, inval,
                              intc8rom_q, lhit_q, ew_v, dr_req, 17'd0};
            default: dbg_val = 32'hDEAD_0001;
        endcase
    end
endmodule
