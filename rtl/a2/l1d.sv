`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// l1d - the 65C02 card's data side of L1 (docs/L1_RETHINK.md,
// docs/CORE_REFACTOR_65C02.md rung 5).  It replaces rtl/dline.sv: the
// one-clock accelerators stay, the cache goes, and every read they do not
// hold is served from the page cache's own row through the TLB.
//
// THREE ONE-CLOCK SERVERS, dline's, register-rooted as before:
//   * THE SHADOW: physical main pages 0 and 1 in a 512-byte LUTRAM (32 rows
//     of 16 bytes, a valid bit per row, claimed lazily from the dispatcher's
//     own read - op_row - on the miss that first touches the row).  Its
//     identity is physical: ALTZP only diverts traffic, and the content dies
//     only with the image.
//   * THE LAST ROW: one 128-bit register holding the row of the last read
//     the page cache answered - the dispatcher's (op_row) or THIS module's
//     direct way read (below) - with its line address and its page.  The
//     second byte of every 16-bit read, and every read that follows a
//     three-clock one into the same line, hits here.
//   * THE LAST BYTE: the previous read's {address, byte}; the CMOS core's
//     LAST and FIXUP dummy cycles re-read it.
//
// THE THREE-CLOCK READ (new).  A candidate outside the shadow's estate and
// outside $Cxxx whose page the TLB knows (lookup B: the set and way L2 holds
// it in) launches a DIRECT WAY READ of the page cache from the registered
// candidate: the request in the candidate's first clock, the row registered
// two clocks after the ack, and the read retires on its third clock FROM THE
// LAST ROW, which the row was written into.  Nothing is installed anywhere
// else: no line, no tag, no cache.  The dispatcher is held (claim) from the
// launch until the serve, or until the launch is abandoned - a map change,
// a write into the line while the read is in flight (the classified
// stream's or our own posted write's: the row was read before the write
// landed) - whereupon the read rides the dispatcher as before, a clock or
// two late and never wrong.  The page cache refuses the read while a posted
// write is short of the banks (the P+2 law's successor), so a read after a
// write pays the drain, exactly as the dispatcher does.
//
// It is THREE clocks and not the two the design note hoped for, because the
// only way to two is to launch from d_pred's own cone, and d_pred inherits
// din's timing (the law: nothing evaluates on it).  The row register the
// page cache hands over is the page cache's own; the last row copies it,
// so a page-cache row is never in a serve cone.
//
// THE TLB LEARNS DATA PAGES TOO: a candidate the TLB does not know, of RAM,
// LC or ROM class (the MMU's answer for the registered candidate), rides
// the dispatcher; the placement the page cache reports for that page fills
// an entry through the TLB's second fill port, once.  Pages 0 and 1 go
// through the shadow and are never filled.
//
// WRITES are dline's rung 3 verbatim: a mode-2 write below $C000 in
// RamWorks bank 0 retires in ONE clock (a virtual verdict, no classify
// cone), is spliced into the shadow and the last row a clock later from the
// stamp register - which is also L1-I's snoop (ws_*) - and is posted to the
// page cache through the FIFO.  `pending` is the term every ordering hangs
// on.  The ISA never reads a data address the clock after writing it, and
// that is CHECKED by the simulation assertion below, never fenced live.
//////////////////////////////////////////////////////////////////////////////////
module l1d #(
    parameter integer SIDX = 6,
    parameter integer LEV  = 3,
    parameter integer PW_DEPTH = 4
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,
    // The core: the prediction, and the live cycle it names.
    input  wire [15:0] d_pred,
    input  wire        d_pred_v,
    input  wire        d_pred_rw,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    input  wire [7:0]  cpu_dout,       // a write's byte, register-direct
    input  wire        cyc_is_i,
    // The chain to the core: L1-I's cyc_en in, ours out; the byte.
    input  wire        il_cyc_en,     // the sequencer's, or an I retire
    input  wire        seq_cyc_en,    // the sequencer's alone: its byte is the byte this clock
    input  wire [7:0]  accel_din,
    input  wire [7:0]  i_din,         // L1-I's byte: what an I cycle consumed
    output wire        cyc_en,
    output wire [7:0]  d_din,
    // The leash and the books, shared with L1-I through the sequencer.
    input  wire        turbo_en,
    input  wire        turbo_ok,
    input  wire        wr_en,         // turbo_en AND mode 2: writes may retire here
    output wire        d_commit,
    output wire        claim,
    output logic       tick_q,
    output wire        pending,       // posted writes not yet in the banks
    // The event.
    output logic       dev_valid,
    output logic [15:0] dev_addr,
    output logic [7:0]  dev_data,
    output logic       dev_rw,
    input  wire        ev_room,
    input  wire        ev_room_w,
    // The map: ALTZP as the MMU holds it; registered here.
    input  wire        altzp,
    // The MMU's d-side query port, rooted at dq_addr/dq_rw: the class and the
    // physical identity of the registered candidate.
    output logic [23:0] dq_addr,
    output wire        dq_rw,
    input  wire [1:0]  d_cls,
    input  wire [15:0] d_ppn,
    input  wire [3:0]  d_reg,
    input  wire        d_fold,
    input  wire [7:0]  rw_bank,
    input  wire        map_changed,
    input  wire        map_settling,
    // THE KEYBOARD AT ONE CLOCK (rung 6; the user's design, docs/CXXX.md): a
    // read of $C000 is served from the parked-dummy latch's byte
    // (rtl/common/kbd_inject.sv) instead of riding the dispatcher's
    // internalized path at seven clocks - on the Nox map that path was 1.1 M
    // polls a second, an eighth of every clock.  kbd_en = the latch holds a
    // byte and the closed regime is on; the retire tells the latch a read
    // happened (kbd_rd).  swi_busy is the dispatcher's synthetic commit: an
    // internalized $C01x write lands on that edge and reaches the latch a
    // clock later, so no serve across it.
    input  wire        kbd_en,
    input  wire [7:0]  kbd_byte,
    input  wire        swi_busy,
    output logic       kbd_rd,
    // The TLB (rtl/a2/tlb.sv): lookup B, and the second fill port.
    output wire [7:0]  lb_vpage,
    input  wire        lb_hit,
    input  wire [15:0] lb_ppn,
    input  wire [SIDX-1:0] lb_set,
    input  wire [LEV-1:0]  lb_way,
    output logic       fj_v,
    output logic [7:0] fj_vpage,
    output logic [15:0] fj_ppn,
    output logic [SIDX-1:0] fj_set,
    output logic [LEV-1:0]  fj_way,
    output logic [3:0] fj_reg,
    output logic       fj_fold,
    input  wire        fj_ack,
    // The page cache: the dispatcher's read whole, the placement report,
    // the direct way read.
    input  wire         op_take,
    input  wire         op_row_v,
    input  wire [127:0] op_row,
    input  wire [15:0]  op_row_ppn,
    input  wire        op_place_v,
    input  wire [15:0] op_place_ppn,
    input  wire [SIDX-1:0] op_place_set,
    input  wire [LEV-1:0]  op_place_way,
    output wire        dr_req,
    output wire [SIDX-1:0] dr_set,
    output wire [LEV-1:0]  dr_way,
    output wire [3:0]  dr_line,
    input  wire        dr_ack,
    input  wire        dr_done,
    input  wire [127:0] dr_row,
    // The splice: the classified stream's writes that reach the image.
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire        cl_posted,
    input  wire [15:0] cl_ppn,
    input  wire [15:0] cl_off,
    input  wire [7:0]  wdata,
    // The posted FIFO's head, to the MMU's classified stage.
    output wire        pw_valid,
    output wire [15:0] pw_ppn,
    output wire [7:0]  pw_off,
    output wire [7:0]  pw_data,
    input  wire        pw_take,
    // The retire+1 snoop, to L1-I.
    output wire        ws_valid,
    output wire [15:0] ws_ppn,
    output wire [7:0]  ws_off8,
    // The image, the debug window, the books.
    input  wire        inval,
    input  wire [3:0]  dbg_sel,
    output logic [31:0] dbg_val,
    output wire        fill_busy,
    input  wire        cnt_clr,
    output logic [31:0] cnt_serves,      // every retire, reads and writes
    output logic [31:0] cnt_l2_serves,   // reads served by the three-clock path
    output logic [31:0] cnt_tlb_fills    // TLB entries filled from this side
);
    localparam [1:0] CLS_RAM = 2'd1, CLS_LC = 2'd2, CLS_ROM = 2'd3;
    localparam integer PW_AW = $clog2(PW_DEPTH);

    // ---- the shadow ---------------------------------------------------------
    // Rows, not bytes; ONE write port, coded explicitly (dline's lesson: two
    // write statements to one array turned 4 Kb of LUTRAM into 4 k flops).
    logic [127:0] shrow [0:31];
    logic [31:0]  shv;
    (* max_fanout = 32 *) logic        sh_we;
    (* max_fanout = 32 *) logic [4:0]  sh_waddr;
    logic [127:0] sh_wdata;
    always_ff @(posedge clk) if (sh_we) shrow[sh_waddr] <= sh_wdata;

    logic zs_main_q, rwb_nz_q;
    always_ff @(posedge clk) begin
        if (rst) begin zs_main_q <= 1'b1; rwb_nz_q <= 1'b0; end
        else begin zs_main_q <= !altzp; rwb_nz_q <= (rw_bank != 8'd0); end
    end

    // ---- the candidate ------------------------------------------------------
    // Registered ONLY at edges the core moves, so it always describes the
    // LIVE cycle; the address and the prediction's validity, nothing else on
    // d_pred's cone.
    logic dq_v, dq_wv, dq_kbd;
    (* KEEP = "TRUE" *) logic [3:0] dq_ix_sh;
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval) begin
            dq_v <= 1'b0; dq_wv <= 1'b0;
        end else if (cyc_en) begin
            dq_v  <= d_pred_v &&  d_pred_rw;
            dq_wv <= d_pred_v && !d_pred_rw;
        end
        if (cyc_en) begin
            dq_addr  <= {8'd0, d_pred};
            dq_ix_sh <= d_pred[3:0];
            dq_kbd   <= (d_pred == 16'hC000);
        end
    end
    assign dq_rw = !dq_wv;
    wire [7:0] dq_byte = shrow[dq_addr[8:4]][dq_ix_sh*8 +: 8];
    wire in_sh_estate = (dq_addr[15:9] == 7'd0) && zs_main_q;
    wire sh_hit = dq_v && in_sh_estate && shv[dq_addr[8:4]];
    wire is_cx  = (dq_addr[15:12] == 4'hC);

    // ---- the keyboard ---------------------------------------------------------
    logic kbd_en_q, swi_busy_q;
    always_ff @(posedge clk) begin
        kbd_en_q   <= kbd_en && !rst;
        swi_busy_q <= swi_busy && !rst;
    end
    wire kb_hit = dq_v && dq_kbd && kbd_en_q && !swi_busy && !swi_busy_q;

    // ---- the last byte ------------------------------------------------------
    logic        lb_v;
    logic [15:0] lb_addr;
    logic [7:0]  lb_byte;
    wire lby_hit = dq_v && lb_v && (dq_addr[15:0] == lb_addr) && !is_cx;

    // ---- the last row -------------------------------------------------------
    logic         lr_v;
    logic [11:0]  lr_addr;      // addr[15:4]
    logic [15:0]  lr_ppn;
    logic [127:0] lr_row;
    wire lr_hit = dq_v && lr_v && (dq_addr[15:4] == lr_addr) && !is_cx;
    wire [7:0] lr_byte = lr_row[8 * dq_addr[3:0] +: 8];

    // ---- the three-clock read -----------------------------------------------
    // The launch, from the registered candidate and the TLB's answer for its
    // page; not for the shadow's estate (claimed there instead), not $Cxxx,
    // not during the settle (the TLB is revalidating), not with one in flight.
    logic            l2_pend;        // acked, the row not here yet
    logic            l2_live;        // ...and it is still the live candidate's (no cyc_en since)
    logic [15:0]     l2_ppn;
    logic [11:0]     l2_vt;
    logic            l2_v_q;         // the last row now holds this candidate's line
    assign lb_vpage = dq_addr[15:8];
    wire   l2_ok    = dq_v && turbo_en && lb_hit && !in_sh_estate && !is_cx &&
                      !inval && !map_settling;
    assign dr_req   = l2_ok && !l2_pend && !l2_v_q && !lr_hit;
    assign dr_set   = lb_set;
    assign dr_way   = lb_way;
    assign dr_line  = dq_addr[7:4];

    wire dr_done_l2 = dr_done;   // the top routes only our own completion here

    // The MMU's class for the registered candidate, one clock later (fresh from
    // the candidate's second clock): the read's servability and the write's LC.
    logic        pc_ok_q, pq_fresh, wc_lc_q;

    // ---- the splice register: a write's stamp, one clock after retire -------
    logic        spl_v;
    logic [7:0]  spl_data;
    logic [15:0] spl_addr;
    logic [15:0] spl_ppn;
    logic [7:0]  spl_off8;

    // ---- the retire ---------------------------------------------------------
    wire serve_hit  = sh_hit || lby_hit || lr_hit || kb_hit;
    wire d_cycle = !cyc_is_i &&  cpu_rw;
    wire w_cycle = !cyc_is_i && !cpu_rw;
    wire pf_near_full;
    logic w_room;
    always_ff @(posedge clk) begin
        if (rst) w_room <= 1'b0;
        else     w_room <= ev_room_w && !pf_near_full;
    end
    // A write below $C000 retires on its first clock by a VIRTUAL verdict (RAM
    // class under every map).  A WRITE INTO THE LANGUAGE CARD ($D000 up) retires
    // on its SECOND clock (rung 6): the class is the MMU's answer for the
    // registered candidate, registered once more (wc_lc_q, fresh from the
    // second clock), so no classify cone reaches the retire - and the
    // dispatcher is held from the first clock by w_pre, the maybe, so the two
    // never dispatch the same write.  A write the card holds as ROM class (the
    // language card write-protected) is released to the dispatcher a clock
    // late.  On the Nox map those writes were 1.1 M a second at seven clocks.
    wire w_lc   = (dq_addr[15:12] >= 4'hD);
    wire w_serv = wr_en && dq_wv && !rwb_nz_q &&
                  ((dq_addr[15:14] != 2'b11) || (w_lc && pq_fresh && wc_lc_q));
    wire w_pre  = wr_en && dq_wv && !rwb_nz_q && w_lc && !pq_fresh;

    // The claim is REGISTERED, one clock behind the verdict; the fc_q ||
    // claim_q gate fences the one-clock window.  The three-clock read claims
    // from its intent, so the dispatcher stands down for the whole read.
    logic fc_q, claim_q;
    always_ff @(posedge clk) begin
        if (rst || cpu_rst) begin
            fc_q <= 1'b0; claim_q <= 1'b0;
        end else begin
            fc_q    <= cyc_en;
            claim_q <= (turbo_en && (serve_hit || l2_ok || (l2_pend && l2_live) || l2_v_q) && d_cycle) ||
                       ((w_serv || w_pre) && w_cycle);
        end
    end
    wire addr_match = (cpu_addr == dq_addr[15:0]) && (fc_q || claim_q);
    wire r_retire = !cpu_rst && turbo_en && turbo_ok && serve_hit && d_cycle && addr_match && ev_room;
    wire w_retire = !cpu_rst && turbo_ok && w_serv && w_room && w_cycle && addr_match;
    wire retire   = r_retire || w_retire;

    assign d_commit = retire;
    assign cyc_en   = il_cyc_en || retire;
    // One flat one-hot OR (the servers never disagree: the shadow's estate is
    // never in the last row, and the last byte, when it also hits, IS that
    // byte - every write clears it), and the sequencer's byte on its own clock.
    wire [7:0] l1_byte = ({8{sh_hit}} & dq_byte) | ({8{lby_hit}} & lb_byte) | ({8{lr_hit}} & lr_byte) |
                         ({8{kb_hit}} & kbd_byte);
    assign d_din = seq_cyc_en ? accel_din : l1_byte;
    assign claim = claim_q;

    // ---- the splice ---------------------------------------------------------
    wire        cl_w    = cl_valid && !cl_rw && cl_wr_image && !cl_posted;
    wire        iw_v    = cl_w || spl_v;
    wire [15:0] iw_ppn  = spl_v ? spl_ppn  : cl_ppn;
    wire [7:0]  iw_off8 = spl_v ? spl_off8 : cl_off[7:0];
    wire [7:0]  iw_data = spl_v ? spl_data : wdata;
    wire       sp_hit  = iw_v && (iw_ppn[15:1] == 15'd0);
    wire [4:0] sp_line = {iw_ppn[0], iw_off8[7:4]};
    wire       lr_snp  = iw_v && lr_v && (iw_ppn == lr_ppn) && (iw_off8[7:4] == lr_addr[3:0]);
    wire       l2_snp  = iw_v && (iw_ppn == l2_ppn) && (iw_off8[7:4] == l2_vt[3:0]);

    // The last byte follows the retiring edge; a write clears it.
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval || map_changed) begin
            lb_v <= 1'b0;
        end else begin
            if (cl_valid && !cl_rw) lb_v <= 1'b0;
            if (cyc_en) begin
                if (cpu_rw) begin
                    lb_v    <= 1'b1;
                    lb_addr <= cpu_addr;
                    lb_byte <= cyc_is_i ? i_din : d_din;
                end else lb_v <= 1'b0;
            end
        end
    end

    // The stamp, sampled by the retire's own edge.
    always_ff @(posedge clk) begin
        if (rst || inval) spl_v <= 1'b0;
        else              spl_v <= w_retire;
        if (w_retire) begin
            spl_addr <= dq_addr[15:0];
            spl_data <= cpu_dout;
            spl_ppn  <= d_ppn;
            spl_off8 <= dq_addr[7:0];
        end
    end
    assign ws_valid = spl_v;
    assign ws_ppn   = spl_ppn;
    assign ws_off8  = spl_off8;

    // ---- the posted FIFO ----------------------------------------------------
    logic [31:0]      pf [0:PW_DEPTH-1];
    logic [PW_AW-1:0] pf_wp, pf_rp;
    logic [PW_AW:0]   pf_cnt;
    wire pf_empty = (pf_cnt == '0);
    assign pf_near_full = (pf_cnt + (PW_AW+1)'(spl_v)) >= (PW_AW+1)'(PW_DEPTH - 1);
    always_ff @(posedge clk) begin
        if (rst || inval) begin
            pf_wp <= '0; pf_rp <= '0; pf_cnt <= '0;
        end else begin
            if (spl_v) begin
                pf[pf_wp] <= {spl_ppn, spl_off8, spl_data};
                pf_wp     <= pf_wp + 1'b1;
            end
            if (pw_take) pf_rp <= pf_rp + 1'b1;
            pf_cnt <= pf_cnt + (PW_AW+1)'(spl_v) - (PW_AW+1)'(pw_take);
        end
    end
    assign pw_valid = !pf_empty;
    assign {pw_ppn, pw_off, pw_data} = pf[pf_rp];
    logic [2:0] drain_sr;
    always_ff @(posedge clk) drain_sr <= rst ? 3'd0 : {drain_sr[1:0], pw_take};
    assign pending = spl_v || !pf_empty || (drain_sr != 3'd0);

`ifndef SYNTHESIS
    always @(posedge clk)
        if (r_retire && spl_v && spl_addr == dq_addr[15:0])
            $error("l1d: a read of $%04x served on the splice clock of a write to it", dq_addr[15:0]);
    always @(posedge clk)
        if (spl_v && pf_cnt == (PW_AW+1)'(PW_DEPTH) && !pw_take)
            $error("l1d: the posted FIFO overflowed");
    always @(posedge clk)
        if (l2_v_q && !lr_hit && dq_v)
            $error("l1d: the three-clock row stands for a candidate the last row does not match");
    logic sh_hit_q_dbg, lby_hit_q_dbg, lr_hit_q_dbg, l2_hit_q_dbg, kb_hit_q_dbg;
    always_ff @(posedge clk) begin
        sh_hit_q_dbg <= sh_hit; lby_hit_q_dbg <= lby_hit; lr_hit_q_dbg <= lr_hit && !l2_v_q; kb_hit_q_dbg <= kb_hit;
        l2_hit_q_dbg <= l2_v_q;
    end
`endif

    // ---- the shadow claim ---------------------------------------------------
    // A shadow miss rides the dispatcher, and the dispatcher's read served
    // whole by the page cache (op_take, op_row_v) brings its row: installed
    // on the next clock under the address the trigger stamped, unless a
    // splice owns the shadow's port or the row's line that clock (then it
    // drops, and the next miss claims it fresh).  Anything else - a fill's
    // critical beat, the bus - claims nothing; the second touch tries again.
    localparam [1:0] C_IDLE = 2'd0, C_OPW = 2'd1, C_W2O = 2'd2;
    logic [1:0]   cst;
    logic [4:0]   c_line;
    logic         miss_q;
    logic [4:0]   miss_line_q;
    logic [127:0] orow_q;
    assign fill_busy = (cst != C_IDLE) || l2_pend;
    wire live_miss = turbo_en && d_cycle && (cpu_addr[15:9] == 7'd0) && zs_main_q &&
                     !shv[cpu_addr[8:4]] && !inval;

    wire sp_write = sp_hit && shv[sp_line] && !inval;
    logic [127:0] sp_mod;
    always_comb begin
        sp_mod = shrow[sp_line];
        sp_mod[iw_off8[3:0]*8 +: 8] = iw_data;
    end
    always_comb begin
        sh_we    = sp_write || (cst == C_W2O && !sp_hit && !rst && !inval);
        sh_waddr = sp_write ? sp_line : c_line;
        sh_wdata = sp_write ? sp_mod : orow_q;
    end

    // ---- the TLB fill from this side ----------------------------------------
    // A candidate the TLB does not know, of a servable class, outside the
    // shadow's estate and $Cxxx: remembered until the page cache reports the
    // page's placement (the dispatcher's read of it), then offered to the
    // TLB until taken.  A map change or a later miss replaces it.
    logic [15:0] p_ppn_q2;
    logic [3:0]  p_reg_q2;
    logic        p_fold_q2;
    always_ff @(posedge clk) begin
        pc_ok_q   <= (d_cls == CLS_RAM) || (d_cls == CLS_LC) || (d_cls == CLS_ROM);
        wc_lc_q   <= (d_cls == CLS_LC);
        p_ppn_q2  <= d_ppn;
        p_reg_q2  <= d_reg;
        p_fold_q2 <= d_fold;
        pq_fresh  <= !cyc_en && !rst && !cpu_rst;
    end
    wire tlb_miss = dq_v && turbo_en && !lb_hit && !in_sh_estate && !is_cx && pq_fresh && pc_ok_q &&
                    !inval && !map_settling && !fj_v;
    logic        tf_v;
    logic [7:0]  tf_vpage;
    logic [15:0] tf_ppn;
    logic [3:0]  tf_reg;
    logic        tf_fold;

    logic [31:0] cnt_claims, cnt_splices, cnt_lb_serves, cnt_lr_serves, cnt_posts, cnt_post_waits,
                 cnt_l2_launch, cnt_l2_abort, cnt_tlb_waits, cnt_kb_serves, cnt_lc_posts;
    always_ff @(posedge clk) begin
        tick_q    <= retire;
        dev_valid <= retire;
        kbd_rd    <= r_retire && dq_kbd && !rst;
        if (retire) begin
            dev_addr <= dq_addr[15:0];
            dev_data <= cpu_rw ? l1_byte : cpu_dout;
            dev_rw   <= cpu_rw;
        end
        miss_q      <= live_miss && (cst == C_IDLE);
        miss_line_q <= cpu_addr[8:4];

        if (rst || inval) begin
            shv <= 32'd0;
            cst <= C_IDLE; c_line <= 5'd0; miss_q <= 1'b0;
            lr_v <= 1'b0; l2_pend <= 1'b0; l2_v_q <= 1'b0; l2_live <= 1'b0;
            tf_v <= 1'b0; fj_v <= 1'b0;
            tick_q <= 1'b0; dev_valid <= 1'b0;
            if (rst) begin
                cnt_serves <= 32'd0; cnt_l2_serves <= 32'd0; cnt_tlb_fills <= 32'd0;
                cnt_claims <= 32'd0; cnt_splices <= 32'd0; cnt_lb_serves <= 32'd0;
                cnt_lr_serves <= 32'd0; cnt_posts <= 32'd0; cnt_post_waits <= 32'd0;
                cnt_l2_launch <= 32'd0; cnt_l2_abort <= 32'd0; cnt_tlb_waits <= 32'd0;
                cnt_kb_serves <= 32'd0; cnt_lc_posts <= 32'd0;
                dev_addr <= 16'd0; dev_data <= 8'd0; dev_rw <= 1'b1;
                l2_ppn <= 16'd0; l2_vt <= 12'd0;
            end
        end else begin
            if (retire) cnt_serves <= cnt_serves + 32'd1;
            if (r_retire) begin
                if (!sh_hit && lby_hit)             cnt_lb_serves <= cnt_lb_serves + 32'd1;
                if (!sh_hit && !lby_hit && lr_hit)  cnt_lr_serves <= cnt_lr_serves + 32'd1;
                if (!sh_hit && !lby_hit && lr_hit && l2_v_q) cnt_l2_serves <= cnt_l2_serves + 32'd1;
            end
            if (w_retire) cnt_posts <= cnt_posts + 32'd1;
            if (w_retire && w_lc) cnt_lc_posts <= cnt_lc_posts + 32'd1;
            if (r_retire && kb_hit) cnt_kb_serves <= cnt_kb_serves + 32'd1;
            if (turbo_ok && w_serv && w_cycle && addr_match && !w_room && !cpu_rst)
                cnt_post_waits <= cnt_post_waits + 32'd1;
            if (sp_write || lr_snp) cnt_splices <= cnt_splices + 32'd1;

            // The last row: spliced first, so a same-edge capture wins.
            if (lr_snp) lr_row[8 * iw_off8[3:0] +: 8] <= iw_data;
            if (op_take && d_cycle && op_row_v && turbo_en) begin
                lr_v    <= 1'b1;
                lr_addr <= cpu_addr[15:4];
                lr_ppn  <= op_row_ppn;
                lr_row  <= op_row;
            end

            // The three-clock read.
            if (dr_ack) begin
                l2_pend <= 1'b1;
                l2_live <= 1'b1;
                l2_ppn  <= lb_ppn;
                l2_vt   <= dq_addr[15:4];
                cnt_l2_launch <= cnt_l2_launch + 32'd1;
            end
            // The row lands in the last row whatever happened to the cycle
            // (it is that line's bytes either way); it stands as THIS
            // candidate's only if the cycle is still the one that launched it
            // - a read the one-clock servers answered on the launch clock has
            // moved on, and its row must not hold the dispatcher for the next.
            if (l2_pend && dr_done_l2) begin
                l2_pend <= 1'b0;
                if (!l2_snp && !map_changed && !inval) begin
                    lr_v    <= 1'b1;
                    lr_addr <= l2_vt;
                    lr_ppn  <= l2_ppn;
                    lr_row  <= dr_row;
                    l2_v_q  <= l2_live && !cyc_en;
                end else cnt_l2_abort <= cnt_l2_abort + 32'd1;
            end
            if (cyc_en) begin l2_v_q <= 1'b0; l2_live <= 1'b0; end
            if (map_changed) begin
                lr_v <= 1'b0; l2_v_q <= 1'b0; l2_live <= 1'b0;
            end

            // The shadow claim.
            case (cst)
                C_IDLE: if (miss_q) begin
                    c_line <= miss_line_q;
                    cst    <= C_OPW;
                end
                C_OPW: if (cyc_en && d_cycle) begin
                    if (op_take && op_row_v && (cpu_addr[8:4] == c_line) && (cpu_addr[15:9] == 7'd0) &&
                        (op_row_ppn == {15'd0, c_line[4]})) begin
                        orow_q <= op_row;
                        cst    <= C_W2O;
                    end else cst <= C_IDLE;
                end
                C_W2O: begin
                    if (!sp_hit) begin
                        shv[c_line] <= 1'b1;
                        cnt_claims  <= cnt_claims + 32'd1;
                    end
                    cst <= C_IDLE;
                end
                default: cst <= C_IDLE;
            endcase
            if (cst != C_IDLE && sp_hit && sp_line == c_line) cst <= C_IDLE;

            // The TLB fill.
            if (tlb_miss && !tf_v) begin
                tf_v     <= 1'b1;
                tf_vpage <= dq_addr[15:8];
                tf_ppn   <= p_ppn_q2;
                tf_reg   <= p_reg_q2;
                tf_fold  <= p_fold_q2;
                cnt_tlb_waits <= cnt_tlb_waits + 32'd1;
            end else if (tlb_miss && tf_v && tf_vpage != dq_addr[15:8]) begin
                tf_vpage <= dq_addr[15:8];      // a later miss replaces the wait
                tf_ppn   <= p_ppn_q2;
                tf_reg   <= p_reg_q2;
                tf_fold  <= p_fold_q2;
            end
            if (tf_v && op_place_v && (op_place_ppn == tf_ppn) && !fj_v) begin
                tf_v     <= 1'b0;
                fj_v     <= 1'b1;
                fj_vpage <= tf_vpage;
                fj_ppn   <= tf_ppn;
                fj_set   <= op_place_set;
                fj_way   <= op_place_way;
                fj_reg   <= tf_reg;
                fj_fold  <= tf_fold;
            end
            if (fj_v && fj_ack) begin
                fj_v <= 1'b0;
                cnt_tlb_fills <= cnt_tlb_fills + 32'd1;
            end
            if (map_changed) begin tf_v <= 1'b0; fj_v <= 1'b0; end

            if (cnt_clr) begin
                cnt_serves <= 32'd0; cnt_l2_serves <= 32'd0; cnt_tlb_fills <= 32'd0;
                cnt_claims <= 32'd0; cnt_splices <= 32'd0; cnt_lb_serves <= 32'd0;
                cnt_lr_serves <= 32'd0; cnt_posts <= 32'd0; cnt_post_waits <= 32'd0;
                cnt_l2_launch <= 32'd0; cnt_l2_abort <= 32'd0; cnt_tlb_waits <= 32'd0;
                cnt_kb_serves <= 32'd0; cnt_lc_posts <= 32'd0;
            end
        end
    end

    always_comb begin
        case (dbg_sel)
            4'd0:  dbg_val = cnt_serves;
            4'd1:  dbg_val = cnt_claims;
            4'd2:  dbg_val = cnt_splices;
            4'd3:  dbg_val = cnt_l2_serves;
            4'd4:  dbg_val = cnt_l2_launch;
            4'd5:  dbg_val = cnt_posts;
            4'd6:  dbg_val = cnt_post_waits;
            4'd7:  dbg_val = cnt_l2_abort;
            4'd8:  dbg_val = cnt_tlb_fills;
            4'd9:  dbg_val = cnt_tlb_waits;
            4'd10: dbg_val = cnt_kb_serves;
            4'd11: dbg_val = cnt_lc_posts;
            4'd12: dbg_val = cnt_lr_serves;
            4'd13: dbg_val = {cst, pending, dq_v, dq_wv, zs_main_q, turbo_en, wr_en,
                              l2_pend, l2_v_q, claim_q, fc_q, tf_v, fj_v, l2_live, 1'b0, shv[15:0]};
            default: dbg_val = cnt_lb_serves;
        endcase
    end
endmodule
