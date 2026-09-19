`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// l1i - the 65816 card's instruction side of L1 (docs/L1_RETHINK.md,
// docs/CORE_REFACTOR_65816.md rung 2; built from the 65C02 card's
// rtl/a2/l1i.sv, whose header explains the shape).  It replaces
// rtl/gs/iline.sv and rtl/gs/iscan.sv: two 16-byte line buffers in flops,
// the "+1" predictor, the early branch resolution used for an early fetch
// of the target's line, and the one-clock serve - no cache of its own, no
// retained set, no scanner, no per-line copy of the map.
//
// WHAT IS THIS CARD'S:
//   * A BUFFER'S TAG IS {BANK, ADDR[15:4]}, twenty bits, and the TLB's key is
//     {bank, page}: the program bank is part of the identity, never a class
//     bit, so a fetch in another bank simply misses.  PBR is register-direct
//     from the core (pc_bank), as pc_addr is.  The predictor's "+1" stays a
//     16-bit step: the 65816's PC wraps inside its bank.
//   * NO ZERO-STALL TARGET SERVE (REQ_65816.md 3.1.2).  Its select is a live
//     16-bit compare on the PC, and on this core the I byte feeds the slot-0
//     decode-ROM lookahead - the binding loop - so i_din is register-direct:
//     `lhit_q ? i_byte_q : accel_din`.  A taken 65816 branch spends its add
//     cycle as an internal cycle anyway; the target's line is still fetched
//     EARLY (the want travels while the branch's dummies run), and the
//     target fetch re-aims the predictor and serves a beat later.
//   * THE I/O WINDOW EXISTS IN FOUR BANKS ($00/$01/$E0/$E1) and nowhere else:
//     the $C3xx/INTC8ROM and $CFFx exclusions are qualified by the program
//     bank being one of the pair, registered (pair_q).  In bank $FF $C3xx is
//     the ROM's own code and $CFFF an ordinary byte.
//   * The retire's event carries the bank (tev_bank).
//
// THE TWO-LINE L1-I (the user's design, 2026-09-19): the buffers are the
// CURRENT line and the NEXT one - the line after it, or a taken transfer's
// target - and nothing else is kept or prefetched on speculation.  The
// scanner (rtl/gs/iscan.sv) walks ahead of the PC and REPORTS the transfers
// it finds into a four-entry TARGET TABLE; at every opcode fetch the table is
// looked up by the fetch's address, a hit is decided THEN, from the live
// flags (the previous instruction's flag write landed on the edge before
// this cycle; checked against the operand-time truth by a simulation
// assertion), and a taken transfer's line, if not held, is fetched into the
// other buffer at once - about three cycles before the PC lands on it, which
// is what the branch's own operand and internal cycles take.  When the PC
// lands, the buffer becomes the current one.  A branch the table does not
// know falls back to the early want at its operand, as before.  No pin: the
// victim of any fill is the buffer the stream is not in.
//
// COHERENCE is the a2 module's: every image write (the classified stream's
// and the data side's posted write) is compared by physical identity against
// both buffers and the read in flight; a map change kills the buffers (PBR
// and DBR are still in the map on this card, so a bank change costs two
// refetches - rung 5 takes them out); L2's eviction and the TLB's replacement
// kill what came from them.
//////////////////////////////////////////////////////////////////////////////////
module l1i #(
    parameter integer SIDX = 7,
    parameter integer LEV  = 3
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,
    // The core: pc_addr and pc_bank REGISTER-DIRECT (rtl/gs/cpu65816.sv).
    input  wire [15:0] pc_addr,
    input  wire [7:0]  pc_bank,
    input  wire        cpu_rw,
    input  wire        cpu_sync,
    input  wire        cyc_is_i,
    input  wire [7:0]  p_flags,
    output wire        cyc_en,
    output wire [7:0]  i_din,
    // The sequencer's path through (rtl/gs/accel_seq.sv).
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
    output logic [7:0] tev_bank,
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
    // The TLB (rtl/gs/tlb.sv): lookup A, the fill, a replaced entry's page.
    output wire [15:0] la_vpage,
    input  wire        la_hit,
    input  wire [15:0] la_ppn,
    input  wire [SIDX-1:0] la_set,
    input  wire [LEV-1:0]  la_way,
    output logic       fi_v,
    output logic [15:0] fi_vpage,
    output logic [15:0] fi_ppn,
    output logic [SIDX-1:0] fi_set,
    output logic [LEV-1:0]  fi_way,
    output logic [3:0] fi_reg,
    output logic       fi_fold,
    input  wire        fi_busy,
    input  wire        kill_v,
    input  wire [15:0] kill_ppn,
    // The page cache (rtl/gs/page_cache.sv): the direct way read, the
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
    logic [19:0]     vtag  [0:1];     // {bank, addr[15:4]}
    logic [15:0]     b_ppn [0:1];
    logic [SIDX-1:0] b_set [0:1];
    logic [LEV-1:0]  b_way [0:1];
    logic [127:0]    ldata [0:1];
    logic            cur;             // the buffer the fetch stream is in

    // ---- the INTC8ROM latch and the pair bank, registered once; the exclusions
    logic intc8rom_q, pair_q;
    always_ff @(posedge clk) begin
        intc8rom_q <= rst ? 1'b0 : intc8rom;
        pair_q     <= (pc_bank[7:1] == 7'd0) || (pc_bank[7:1] == 7'h70);
    end
    function automatic logic excl(input [11:0] tag);
        excl = pair_q && ((tag[11:4] == 8'hC3 && !intc8rom_q) || (tag == 12'hCFF));
    endfunction

    // ---- the serve (iline's, without the target serve) --------------------
    wire [19:0] pc_tag = {pc_bank, pc_addr[15:4]};
    wire hit0 = v[0] && (pc_tag == vtag[0]);
    wire hit1 = v[1] && (pc_tag == vtag[1]);
    logic [15:0] exp_q;
    logic        lhit_q;
    logic [7:0]  i_byte_q;
    wire [15:0] exp_inc = exp_q + 16'd1;
    wire ihit  = cyc_is_i && cpu_rw && (hit0 || hit1);
    wire hslot = !hit0;

    wire        hi0 = v[0] && ({pc_bank, exp_inc[15:4]} == vtag[0]);
    wire        hi1 = v[1] && ({pc_bank, exp_inc[15:4]} == vtag[1]);
    wire        hc0 = hit0;
    wire        hc1 = hit1;
    wire        hh0 = v[0] && ({pc_bank, exp_q[15:4]}   == vtag[0]);
    wire        hh1 = v[1] && ({pc_bank, exp_q[15:4]}   == vtag[1]);
    wire [7:0]  b_inc  = hi0 ? ldata[0][8 * exp_inc[3:0] +: 8] : ldata[1][8 * exp_inc[3:0] +: 8];
    wire [7:0]  b_cur  = hc0 ? ldata[0][8 * pc_addr[3:0] +: 8] : ldata[1][8 * pc_addr[3:0] +: 8];
    wire [7:0]  b_hold = hh0 ? ldata[0][8 * exp_q[3:0]   +: 8] : ldata[1][8 * exp_q[3:0]   +: 8];

    // ---- early branch resolution, for the early want alone -----------------
    localparam [1:0] BK_NONE = 2'd0, BK_BR = 2'd1, BK_ABS = 2'd2;
    logic [1:0]  bk_q;
    logic        bk_hi;
    logic [7:0]  br_op, lo_q;

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

    // ---- the snoops, combinational: an image write against the buffers ------
    wire snp = cl_valid && !cl_rw && cl_wr_image;
    wire snp_kill0 = (snp      && v[0] && (b_ppn[0] == cl_ppn) && (vtag[0][3:0] == cl_off[7:4])) ||
                     (ws_valid && v[0] && (b_ppn[0] == ws_ppn) && (vtag[0][3:0] == ws_off8[7:4]));
    wire snp_kill1 = (snp      && v[1] && (b_ppn[1] == cl_ppn) && (vtag[1][3:0] == cl_off[7:4])) ||
                     (ws_valid && v[1] && (b_ppn[1] == ws_ppn) && (vtag[1][3:0] == ws_off8[7:4]));
    wire ev_kill0 = evict_v && v[0] && (b_set[0] == evict_set) && (b_way[0] == evict_way);
    wire ev_kill1 = evict_v && v[1] && (b_set[1] == evict_set) && (b_way[1] == evict_way);
    wire tk_kill0 = kill_v && v[0] && (b_ppn[0] == kill_ppn);
    wire tk_kill1 = kill_v && v[1] && (b_ppn[1] == kill_ppn);
    wire kill0 = snp_kill0 || ev_kill0 || tk_kill0;
    wire kill1 = snp_kill1 || ev_kill1 || tk_kill1;

    wire kill_now = map_settling || inval || !serve ||
                    (pair_q && pc_addr[15:8] == 8'hC3 && !intc8rom_q) ||
                    (hslot ? kill1 : kill0);

    // ---- the retire ---------------------------------------------------------
    wire retire = !cpu_rst && ihit && turbo_ok && !kill_now && ev_room &&
                  lhit_q && (exp_q == pc_addr);
    assign turbo_commit = retire;
    assign turbo_sync   = retire && cpu_sync;
    assign cyc_en       = accel_cyc_en || retire;
    assign i_din        = lhit_q ? i_byte_q : accel_din;

    // ---- the branch scanner and the target table (rtl/gs/iscan.sv) --------------
    wire        sc_rd_slot;
    wire [3:0]  sc_rd_off;
    wire [7:0]  sc_rd_byte = ldata[sc_rd_slot][8 * sc_rd_off +: 8];
    wire        sc_v0 = v[0] && (vtag[0][19:12] == pc_bank);
    wire        sc_v1 = v[1] && (vtag[1][19:12] == pc_bank);
    wire        tb_v;
    wire [15:0] tb_addr, tb_tgt;
    wire [7:0]  tb_op;
    iscan u_scan (
        .clk (clk), .rst (rst || cpu_rst), .enable (turbo_en && serve && !inval),
        .intc8rom (intc8rom_q), .pair (pair_q),
        .m_flag (p_flags[5]), .x_flag (p_flags[4]), .pc_bank (pc_bank),
        .anchor_v (i_serve && cpu_sync), .anchor_addr (pc_addr),
        .rd_slot (sc_rd_slot), .rd_off (sc_rd_off), .rd_byte (sc_rd_byte),
        .v0 (sc_v0), .v1 (sc_v1), .vtag0 (vtag[0][11:0]), .vtag1 (vtag[1][11:0]),
        .tb_v (tb_v), .tb_addr (tb_addr), .tb_op (tb_op), .tb_tgt (tb_tgt)
    );
    // Four entries {bank, opcode address, opcode, target}, replaced round-robin
    // (an entry for the same opcode is refreshed in place), cleared with the map.
    localparam integer TB_N = 4;
    logic        te_v   [0:TB_N-1];
    logic [23:0] te_addr[0:TB_N-1];
    logic [7:0]  te_op  [0:TB_N-1];
    logic [15:0] te_tgt [0:TB_N-1];
    logic [1:0]  te_rr;
    // The lookup, by the fetch's full address: register-direct pc_bank/pc_addr
    // against registered entries, its result registered into the want.
    logic        th_hit;
    logic [7:0]  th_op;
    logic [15:0] th_tgt;
    always_comb begin
        th_hit = 1'b0; th_op = 8'd0; th_tgt = 16'd0;
        for (int i = 0; i < TB_N; i = i + 1)
            if (te_v[i] && te_addr[i] == {pc_bank, pc_addr}) begin
                th_hit = 1'b1; th_op = te_op[i]; th_tgt = te_tgt[i];
            end
    end
    // The decision, from the live flags: a relative branch by its condition
    // bits, everything else the scanner reports is always taken.
    wire th_rel   = (th_op[4:0] == 5'b10000) && (th_op != 8'h80);
    wire th_flag  = (th_op[7:6] == 2'b00) ? p_flags[7] :
                    (th_op[7:6] == 2'b01) ? p_flags[6] :
                    (th_op[7:6] == 2'b10) ? p_flags[0] : p_flags[1];
    wire th_taken = !th_rel || (th_flag == th_op[5]);
    wire th_held  = (v[0] && vtag[0] == {pc_bank, th_tgt[15:4]}) || (v[1] && vtag[1] == {pc_bank, th_tgt[15:4]});
    wire th_go    = i_serve && cpu_sync && turbo_en && th_hit && th_taken;
    logic        bt_v;                // the taken target's line, wanted
    logic [11:0] bt_tag;
    logic        bt_dec_v, bt_dec;    // the opcode-time decision, for the check at the operand

    // ---- the wants ------------------------------------------------------------
    wire want_fetch = turbo_en && cyc_is_i && cpu_rw && !ihit && !cpu_rst;
    logic        ew_v;
    logic [11:0] ew_tag;
    wire [11:0]  nx_tag = exp_q[15:4] + 12'd1;
    wire nx_held = (v[0] && vtag[0] == {pc_bank, nx_tag}) || (v[1] && vtag[1] == {pc_bank, nx_tag});
    wire want_next = turbo_en && lhit_q && exp_q[3:2] == 2'b11 && !nx_held;
    wire want_any  = want_fetch || bt_v || ew_v || want_next;
    wire [11:0] want_tag = want_fetch ? pc_addr[15:4] : bt_v ? bt_tag : ew_v ? ew_tag : nx_tag;
    wire        want_is_fetch = want_fetch;
    wire        want_held = (v[0] && vtag[0] == {pc_bank, want_tag}) || (v[1] && vtag[1] == {pc_bank, want_tag});

    // ---- the engine --------------------------------------------------------
    localparam [2:0] F_IDLE = 3'd0, F_DR = 3'd1, F_W1 = 3'd2, F_W2 = 3'd3, F_TLB = 3'd4;
    logic [2:0]      fst;
    logic [19:0]     f_vtag;
    logic [15:0]     f_ppn;
    logic [SIDX-1:0] f_set;
    logic [LEV-1:0]  f_way;
    logic [3:0]      f_reg;
    logic            f_fold;
    logic            f_slot;

    assign la_vpage = {pc_bank, want_tag[11:4]};
    assign p_addr   = {pc_bank, want_tag, 4'h0};
    assign fill_busy = (fst == F_DR) || (fst == F_W1) || (fst == F_W2);
    assign claim = turbo_en && cyc_is_i && cpu_rw &&
                   (ihit || (fill_busy && (f_vtag == pc_tag)));

    wire f_live = (fst != F_IDLE);
    wire f_snp = (snp      && (f_ppn == cl_ppn) && (f_vtag[3:0] == cl_off[7:4])) ||
                 (ws_valid && (f_ppn == ws_ppn) && (f_vtag[3:0] == ws_off8[7:4]));
    wire f_restart = f_live && (map_changed || inval || !serve || f_snp ||
                     (evict_v && f_set == evict_set && f_way == evict_way) ||
                     (kill_v && f_ppn == kill_ppn));
    wire victim = !cur;

    // ---- the predictor's update (iline's) ----------------------------------
    wire step    = retire || (accel_cyc_en && cyc_is_i && cpu_rw && (pc_addr == exp_q));
    wire recover = turbo_en && cyc_is_i && cpu_rw && !step && (pc_addr != exp_q);

    always_ff @(posedge clk) begin
        if (rst || cpu_rst) begin
            exp_q <= 16'd0; lhit_q <= 1'b0; i_byte_q <= 8'd0;
            bk_q <= BK_NONE; bk_hi <= 1'b0; br_op <= 8'd0; lo_q <= 8'd0;
        end else begin
            exp_q    <= step ? exp_inc : recover ? pc_addr : exp_q;
            lhit_q   <= step    ? (hi0 || hi1) :
                        recover ? (hc0 || hc1) : (hh0 || hh1);
            i_byte_q <= step ? b_inc : recover ? b_cur : b_hold;
            if (i_serve) begin
                if (cpu_sync) begin
                    bk_q  <= (turbo_en && op_is_branch) ? BK_BR :
                             (turbo_en && op_is_abs)    ? BK_ABS : BK_NONE;
                    bk_hi <= 1'b0;
                    br_op <= i_din;
                end else if (bk_q == BK_BR) begin
                    bk_q  <= BK_NONE;
                end else if (bk_q == BK_ABS && !bk_hi) begin
                    lo_q  <= i_din;
                    bk_hi <= 1'b1;
                end else if (bk_q == BK_ABS && bk_hi) begin
                    bk_q  <= BK_NONE;
                end
            end
        end
    end

    // The early want for a taken branch's line (never into the I/O page of a
    // pair bank, never an excluded line, never a line already held).
    wire bt_taken = (fst == F_IDLE) && !map_settling && !want_fetch && bt_v;   // the engine looked at it
    wire ew_taken = (fst == F_IDLE) && !map_settling && !want_fetch && !bt_v && ew_v;
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || !turbo_en) begin
            ew_v <= 1'b0; ew_tag <= 12'd0;
            bt_v <= 1'b0; bt_tag <= 12'd0;
            bt_dec_v <= 1'b0; bt_dec <= 1'b0;
        end else begin
            if (ew_taken) ew_v <= 1'b0;
            if (bt_taken) bt_v <= 1'b0;
            // The opcode-time decision: a taken transfer whose line is not held
            // is wanted now; the early want at the operand then has nothing to
            // add (its line will be held or in flight).
            if (th_go && !th_held && !excl(th_tgt[15:4]) && !(pair_q && th_tgt[15:8] == 8'hC0)) begin
                bt_v   <= 1'b1;
                bt_tag <= th_tgt[15:4];
            end
            bt_dec_v <= i_serve && cpu_sync && th_hit && th_rel;
            bt_dec   <= th_taken;
            if (resolving && res_taken && !excl(res_tgt[15:4]) &&
                !(pair_q && res_tgt[15:8] == 8'hC0) && !bt_v &&
                !(f_live && f_vtag == {pc_bank, res_tgt[15:4]}) &&
                !((v[0] && vtag[0] == {pc_bank, res_tgt[15:4]}) || (v[1] && vtag[1] == {pc_bank, res_tgt[15:4]}))) begin
                ew_v   <= 1'b1;
                ew_tag <= res_tgt[15:4];
            end
        end
    end
`ifndef SYNTHESIS
    // The flags at the opcode fetch are the flags the branch uses: checked at
    // the operand, where the truth is computed as before.
    always @(posedge clk)
        if (resolving && bk_q == BK_BR && bt_dec_v && bt_dec != br_taken)
            $error("l1i: the opcode-time branch decision (%0d) disagrees with the operand-time truth (%0d) at $%02x/%04x",
                   bt_dec, br_taken, pc_bank, pc_addr);
`endif
    // The table.
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval || !serve || map_changed) begin
            for (int i = 0; i < TB_N; i = i + 1) te_v[i] <= 1'b0;
            te_rr <= 2'd0;
        end else if (tb_v) begin
            logic [1:0] slot; logic same;
            slot = te_rr; same = 1'b0;
            for (int i = TB_N - 1; i >= 0; i = i - 1)
                if (te_v[i] && te_addr[i] == {pc_bank, tb_addr}) begin slot = 2'(i); same = 1'b1; end
            te_v[slot]    <= 1'b1;
            te_addr[slot] <= {pc_bank, tb_addr};
            te_op[slot]   <= tb_op;
            te_tgt[slot]  <= tb_tgt;
            if (!same) te_rr <= te_rr + 2'd1;
        end
    end

    // ---- the books -----------------------------------------------------------
    logic [31:0] cnt_slow_i, cnt_fills, cnt_kills, cnt_unserv, cnt_tlb_waits, cnt_prefetch, cnt_bt, cnt_bt_held, cnt_bt_miss;

    // ---- the engine, the buffers, the events -----------------------------------
    always_ff @(posedge clk) begin
        tick_q    <= retire;
        tev_valid <= retire;
        if (retire) begin
            tev_addr <= pc_addr;
            tev_data <= i_din;
            tev_sync <= cpu_sync;
            tev_bank <= pc_bank;
        end
        fi_v <= 1'b0;

        if (rst) begin
            v[0] <= 1'b0; v[1] <= 1'b0;
            vtag[0] <= 20'd0; vtag[1] <= 20'd0;
            b_ppn[0] <= 16'd0; b_ppn[1] <= 16'd0;
            b_set[0] <= '0; b_set[1] <= '0; b_way[0] <= '0; b_way[1] <= '0;
            cur <= 1'b0;
            fst <= F_IDLE; f_vtag <= 20'd0; f_ppn <= 16'd0; f_set <= '0; f_way <= '0;
            f_reg <= 4'd0; f_fold <= 1'b0; f_slot <= 1'b0;
            dr_req <= 1'b0; dr_set <= '0; dr_way <= '0; dr_line <= 4'd0;
            tev_bank <= 8'd0;
            cnt_slow_i <= 32'd0; cnt_fills <= 32'd0;
            cnt_kills <= 32'd0; cnt_unserv <= 32'd0; cnt_tlb_waits <= 32'd0; cnt_prefetch <= 32'd0;
            cnt_bt <= 32'd0; cnt_bt_held <= 32'd0; cnt_bt_miss <= 32'd0;
        end else begin
            if (accel_cyc_en && cyc_is_i && cpu_rw) cnt_slow_i <= cnt_slow_i + 32'd1;

            // Where the stream is.
            if (hit0 && cyc_is_i && cpu_rw) cur <= 1'b0;
            if (hit1 && cyc_is_i && cpu_rw) cur <= 1'b1;
            // The table's books: taken decisions whose line was held, and
            // opcode fetches of a relative branch the table did not know.
            if (th_go && th_held) cnt_bt_held <= cnt_bt_held + 32'd1;
            if (i_serve && cpu_sync && !th_hit && turbo_en && op_is_branch) cnt_bt_miss <= cnt_bt_miss + 32'd1;

            if (kill0) begin v[0] <= 1'b0; cnt_kills <= cnt_kills + 32'd1; end
            if (kill1) begin v[1] <= 1'b0; cnt_kills <= cnt_kills + 32'd1; end

            if (f_restart) begin
                if (fst == F_DR) dr_req <= 1'b0;
                fst <= F_IDLE;
            end else case (fst)
                F_IDLE: if (want_any && !map_settling) begin
                    if (excl(want_tag) || (!want_is_fetch && want_held)) begin
                        cnt_unserv <= cnt_unserv + 32'd1;   // the fetch rides the sequencer; a held want drops
                    end else if (la_hit) begin
                        f_vtag  <= {pc_bank, want_tag};
                        f_ppn   <= la_ppn;
                        f_set   <= la_set;
                        f_way   <= la_way;
                        f_slot  <= victim;
                        dr_req  <= 1'b1;
                        dr_set  <= la_set;
                        dr_way  <= la_way;
                        dr_line <= want_tag[3:0];
                        if (!want_is_fetch && !bt_v && !ew_v) cnt_prefetch <= cnt_prefetch + 32'd1;
                        if (!want_is_fetch && bt_v) cnt_bt <= cnt_bt + 32'd1;
                        fst <= F_DR;
                    end else if (!p_fs) begin
                        cnt_unserv <= cnt_unserv + 32'd1;
                    end else if (want_is_fetch || ew_v) begin
                        f_vtag <= {pc_bank, want_tag};
                        f_ppn  <= p_ppn;
                        f_reg  <= p_reg;
                        f_fold <= p_fold;
                        cnt_tlb_waits <= cnt_tlb_waits + 32'd1;
                        fst <= F_TLB;
                    end
                end
                F_TLB: begin
                    if (op_place_v && (op_place_ppn == f_ppn) && !fi_busy) begin
                        fi_v     <= 1'b1;
                        fi_vpage <= f_vtag[19:4];
                        fi_ppn   <= f_ppn;
                        fi_set   <= op_place_set;
                        fi_way   <= op_place_way;
                        fi_reg   <= f_reg;
                        fi_fold  <= f_fold;
                        fst <= F_IDLE;
                    end else if (!(want_any && {pc_bank, want_tag[11:4]} == f_vtag[19:4])) begin
                        fst <= F_IDLE;
                    end
                end
                F_DR: if (dr_ack) begin dr_req <= 1'b0; fst <= F_W1; end
                F_W1: fst <= F_W2;
                F_W2: begin
`ifndef SYNTHESIS
                    if (!dr_done) $error("l1i: no dr_done two clocks after the ack");
`endif
                    ldata[f_slot] <= dr_row;
                    v[f_slot]     <= 1'b1;
                    vtag[f_slot]  <= f_vtag;
                    b_ppn[f_slot] <= f_ppn;
                    b_set[f_slot] <= f_set;
                    b_way[f_slot] <= f_way;
                    cnt_fills <= cnt_fills + 32'd1;
                    fst <= F_IDLE;
                end
                default: fst <= F_IDLE;
            endcase

            if (map_changed || inval || !serve) begin
                v[0] <= 1'b0; v[1] <= 1'b0;
            end
        end
    end

    always_comb begin
        case (dbg_sel)
            4'd0:  dbg_val = cnt_slow_i;
            4'd1:  dbg_val = cnt_fills;
            4'd3:  dbg_val = cnt_kills;
            4'd4:  dbg_val = cnt_unserv;
            4'd5:  dbg_val = cnt_tlb_waits;
            4'd6:  dbg_val = cnt_prefetch;
            4'd7:  dbg_val = cnt_bt;
            4'd8:  dbg_val = cnt_bt_held;
            4'd9:  dbg_val = cnt_bt_miss;
            4'd14: dbg_val = {v[1], v[0], fst, cur, bt_v, 1'b0, turbo_en, serve, inval,
                              intc8rom_q, lhit_q, ew_v, dr_req, pair_q, 16'd0};
            default: dbg_val = 32'hDEAD_0001;
        endcase
    end
endmodule
