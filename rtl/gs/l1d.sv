`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// l1d - the 65816 card's data side of L1 (docs/L1_RETHINK.md,
// docs/CORE_REFACTOR_65816.md rung 3; built from the 65C02 card's
// rtl/a2/l1d.sv, whose header explains the shape).  It replaces
// rtl/gs/dline.sv: the one-clock servers stay, the 8x4 cache, the bank table
// and the per-line copies of the map go, and every read they do not hold is
// served from the page cache's own row through the TLB.
//
// THE CANDIDATE IS 24 BITS and the TLB's key is {bank, page}: the bank byte
// is registered with the address (dq_addr) and compared against registered
// entries, never classified - the bank CLASS the core reports (zero, the DBR,
// other) is not used here at all.  So the shadow is bank zero's physical main
// pages 0/1 by the registered bank byte being zero; the last row and the last
// byte carry the bank; the L2 read (lookup B) covers any page in any bank the
// TLB knows - a long read into bank $E1's screen, a DBR-relative read into
// $02-$7F, a JSL'd routine's data in ROM - at the same cost.
//
// THE 816 READS FROM A REGISTER (docs/GS.md rung 6): the byte and the hit of
// every server are registered at the end of the cycle's first clock
// (sv_hit_q, sv_byte_q) and the read retires on its second, because the
// 65816's AGU is a 16-bit adder under a bank incrementer and its din must be
// register-direct.  The L2 read lands its row the same way: the row register
// is written into the last row AND its byte into sv_byte_q on the clock
// dr_done stands, so a read the TLB covers retires on its FOURTH clock from
// the candidate (request, wait, land, retire), against the dispatcher's seven
// to eight.  Writes and the internal cycle keep one clock.
//
// THE IIgs's OWN SERVERS, from dline unchanged in kind:
//   * the chipset's side-effect-free registers (io_vec, gs_iopage.vh) and the
//     keyboard's $C000 in ANY bank the I/O page is in (gs_is_io: the Mega II
//     banks always, the fast pair while SHADOW bit 6 is clear);
//   * THE INTERNAL CYCLE at one clock (n_cycle): a 65816 cycle with VDA and
//     VPA both low touches nothing - no address, no byte, no event - and it
//     is one core cycle in five on Nox's loop.
//
// WRITES are dline's GS rung 3 (docs/LONG_DATA.md): a mode-2 write in bank
// zero below $C000, or ANYWHERE in banks $02-$7F (RAM under every map, so the
// qualifier is virtual and exact), retires in one clock, is spliced into the
// shadow and the last row a clock later from the stamp register, and is
// posted through the FIFO.  THE SHADOW DUPLICATE IS MADE HERE: a write into a
// region SHADOW duplicates (d_sh, the MMU's answer for the registered
// candidate, sampled with the stamp) reloads the splice register the next
// clock with the same byte at {$E0 | side, page}, so every coherence rule
// applies to the duplicate unchanged; a retire on that clock is held one
// clock (dup_go); the FIFO is 8 deep with the room sample three entries short.
// Pair-bank long writes and language-card writes ride the dispatcher (they
// name the map and SHADOW).
//////////////////////////////////////////////////////////////////////////////////
module l1d #(
    parameter integer SIDX = 7,
    parameter integer LEV  = 3,
    parameter integer PW_DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,
    // The core: the prediction, and the live cycle it names.
    input  wire [23:0] d_pred,
    input  wire        d_pred_v,
    input  wire        d_pred_rw,
    input  wire        d_pred_vpb,    // the predicted cycle is a vector pull
    input  wire [33:0] d_pred_arms,   // d_pred's late choices and their arms (cpu65816)
    input  wire [15:0] cpu_addr,
    input  wire [7:0]  cpu_bank,      // as the board presents it (the vector pull's $FF included)
    input  wire        cyc_int,       // VDA and VPA both low: an internal cycle
    input  wire        cpu_rw,
    input  wire [7:0]  cpu_dout,
    input  wire        cyc_is_i,
    // The chain to the core: L1-I's cyc_en in, ours out; the byte.
    input  wire        il_cyc_en,
    input  wire        seq_cyc_en,
    input  wire [7:0]  accel_din,
    input  wire [7:0]  i_din,
    output wire        cyc_en,
    output wire [7:0]  d_din,
    // The leash and the books.
    input  wire        turbo_en,
    input  wire        turbo_ok,
    input  wire        wr_en,
    output wire        d_commit,
    output wire        claim,
    output logic       tick_q,
    output wire        pending,
    // The event.
    output logic       dev_valid,
    output logic [15:0] dev_addr,
    output logic [7:0]  dev_data,
    output logic       dev_rw,
    output logic [7:0]  dev_bank,
    input  wire        ev_room,
    input  wire        ev_room_w,
    // The map: ALTZP as the MMU holds it; registered here.
    input  wire        altzp,
    // The MMU's d-side query port, rooted at dq_addr/dq_rw.
    output logic [23:0] dq_addr,
    output wire        dq_rw,
    input  wire [1:0]  d_cls,
    input  wire [15:0] d_ppn,
    input  wire [3:0]  d_reg,
    input  wire        d_fold,
    input  wire        d_sh,          // the write lands where SHADOW duplicates
    input  wire [7:0]  rw_bank,
    input  wire        map_changed,
    input  wire        map_settling,
    // The IIgs's I/O page: the keyboard's byte and the chipset's fast reads
    // (rtl/gs/gs_io.sv fr_vec, registered in the top), the SHADOW flat bit.
    input  wire        kbd_en,
    input  wire [7:0]  kbd_byte,
    input  wire        io_flat,
    input  wire [247:0] io_vec,
    input  wire        swi_busy,
    output logic       kbd_rd,
    // The TLB (rtl/gs/tlb.sv): lookup B, and the second fill port.
    output wire [15:0] lb_vpage,
    input  wire        lb_hit,
    input  wire [15:0] lb_ppn,
    input  wire [SIDX-1:0] lb_set,
    input  wire [LEV-1:0]  lb_way,
    output logic       fj_v,
    output logic [15:0] fj_vpage,
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
    // The RISC-V engine's word write (docs/REQ_RVVM.md rung 3b): posted by
    // another producer, so nothing here holds its bytes to splice - the last
    // row, the L2 read in flight and the neighbour slot simply die on it.
    // The 65816 is in the VM's hot loop whenever the engine writes, so
    // killing them wholesale costs nothing a row compare would save.
    input  wire        cl_eng,
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
    output logic [31:0] cnt_serves,
    output logic [31:0] cnt_l2_serves,
    output logic [31:0] cnt_tlb_fills
);
    localparam [1:0] CLS_RAM = 2'd1, CLS_LC = 2'd2, CLS_ROM = 2'd3;
    localparam integer PW_AW = $clog2(PW_DEPTH);
    `include "gs_iopage.vh"

    function automatic logic is_pair(input [7:0] bank);
        is_pair = (bank[7:1] == 7'd0) || (bank[7:1] == 7'h70);
    endfunction

    // ---- the shadow ---------------------------------------------------------
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
    // Registered ONLY at edges the core moves; the address, the prediction's
    // validity, and three decodes of the address into registers - nothing
    // else on d_pred's cone.
    logic dq_v, dq_wv, dq_kbd, dq_bz, dq_pair;
    // THE VECTOR PULL'S BANK IS THE BOARD'S (REQ_65816.md 2.1.3): the core
    // predicts a vector pull in bank zero and the board presents it in ROM
    // bank $FF unless SHADOW bit 6 inhibits the redirect (gs_top's cpu_bank).
    // The candidate takes the bank the live cycle will carry, or the address
    // match could never pass while the claim held the dispatcher - the
    // GS/OS boot's first interrupt deadlocked that way (2026-09-19).
    wire [7:0] pred_bank = (d_pred_vpb && !io_flat) ? 8'hFF : d_pred[23:16];
    (* KEEP = "TRUE" *) logic [3:0] dq_ix_sh;
    // THE CARRY PICKS LAST (2026-09-22, the 50T census): the three decodes
    // were taken of d_pred after its carry and bank-move selects, so the
    // compare and is_pair sat behind din's adder and both selects.  Each is
    // decoded on both arms instead, and the late bit chooses - one mux
    // after the carry.  KEPT, or synthesis folds the select back in first.
    wire        a_bkm   = d_pred_arms[33];
    wire [7:0]  a_bk_c  = d_pred_arms[32:25];
    wire [7:0]  a_bk_nc = d_pred_arms[24:17];
    wire        a_hic   = d_pred_arms[16];
    wire [7:0]  a_hi_c  = d_pred_arms[15:8];
    wire [7:0]  a_hi_nc = d_pred_arms[7:0];
    wire        a_vec   = d_pred_vpb && !io_flat;
    (* keep = "true" *) wire kbd_c   = (a_hi_c  == 8'hC0);
    (* keep = "true" *) wire kbd_nc  = (a_hi_nc == 8'hC0);
    (* keep = "true" *) wire bz_c    = (a_bk_c  == 8'd0);
    (* keep = "true" *) wire bz_nc   = (a_bk_nc == 8'd0);
    (* keep = "true" *) wire pair_c  = is_pair(a_bk_c);
    (* keep = "true" *) wire pair_nc = is_pair(a_bk_nc);
    wire kbd_pick  = (d_pred[7:0] == 8'h00) && (a_hic ? kbd_c : kbd_nc);
    wire bz_pick   = a_vec ? 1'b0             : a_bkm ? bz_c   : bz_nc;
    wire pair_pick = a_vec ? is_pair(8'hFF)   : a_bkm ? pair_c : pair_nc;
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (!rst && cyc_en && !$isunknown(d_pred) &&
            (kbd_pick  != (d_pred[15:0] == 16'hC000) ||
             bz_pick   != (pred_bank == 8'd0) ||
             pair_pick != is_pair(pred_bank)))
            $error("l1d: the carry-picked decodes differ from d_pred's (%06x)", d_pred);
`endif
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval) begin
            dq_v <= 1'b0; dq_wv <= 1'b0;
        end else if (cyc_en) begin
            dq_v  <= d_pred_v &&  d_pred_rw;
            dq_wv <= d_pred_v && !d_pred_rw;
        end
        if (cyc_en) begin
            dq_addr  <= {pred_bank, d_pred[15:0]};
            dq_ix_sh <= d_pred[3:0];
            dq_kbd   <= kbd_pick;
            dq_bz    <= bz_pick;
            dq_pair  <= pair_pick;
        end
    end
    assign dq_rw = !dq_wv;
    wire [7:0] dq_byte = shrow[dq_addr[8:4]][dq_ix_sh*8 +: 8];
    wire in_sh_estate = (dq_addr[15:9] == 7'd0) && zs_main_q && dq_bz;
    wire sh_hit = dq_v && in_sh_estate && shv[dq_addr[8:4]];
    // $Cxxx is the I/O page in the pair banks alone; elsewhere it is memory.
    // ...and $EF:FExx is the RISC-V engine's window (rtl/gs/rv_engine.sv,
    // docs/REQ_RVVM.md): its registers, never the RAM under it - the
    // dispatcher serves it through the internalized path, so no server here
    // may answer it.
    wire is_cx  = ((dq_addr[15:12] == 4'hC) && dq_pair) || (dq_addr[23:8] == 16'hEFFE);

    // ---- the I/O page: the keyboard and the chipset's fast reads --------------
    logic io_flat_q, swi_busy_q;
    always_ff @(posedge clk) begin
        io_flat_q  <= io_flat && !rst;
        swi_busy_q <= swi_busy && !rst;
    end
    wire       io_bank  = gs_is_io(dq_addr[23:16], io_flat_q);
    wire       io_quiet = !swi_busy && !swi_busy_q;
    wire [5:0] io_sel   = gs_fr_sel(dq_addr[7:0]);
    wire       io_hit   = dq_v && io_bank && (dq_addr[15:8] == 8'hC0) && io_sel[5] && kbd_en && io_quiet;
    wire [7:0] io_byte  = io_vec[8*io_sel[4:0] +: 8];
    wire       kb_hit   = dq_v && dq_kbd && io_bank && kbd_en && io_quiet;

    // ---- the last byte ------------------------------------------------------
    logic        lb_v;
    logic [23:0] lb_addr;
    logic [7:0]  lb_byte;
    wire lby_hit = dq_v && lb_v && (dq_addr == lb_addr) && !is_cx;

    // ---- the last row -------------------------------------------------------
    logic         lr_v;
    logic [19:0]  lr_addr;      // {bank, addr[15:4]}
    logic [15:0]  lr_ppn;
    logic [127:0] lr_row;
    wire lr_hit = dq_v && lr_v && (dq_addr[23:4] == lr_addr) && !is_cx;
    wire [7:0] lr_byte = lr_row[8 * dq_addr[3:0] +: 8];

    // ---- the L2 read ---------------------------------------------------------
    logic            l2_pend;
    logic            l2_live;
    logic [15:0]     l2_ppn;
    logic [19:0]     l2_vt;
    logic            l2_v_q;
    assign lb_vpage = dq_addr[23:8];
    // LOOKUP B'S ANSWER IS REGISTERED: the first Pt build (gs_r3) missed by
    // 0.444 ns from dq_addr through the sixteen 16-bit compares, the way mux
    // and the page cache's ack into the way RAM's address, three quarters of
    // it route.  So the launch is from the candidate's SECOND clock, when the
    // register describes it (pq_fresh, the same clock the MMU's class is
    // fresh), and a read the TLB covers retires on its fifth: request, wait,
    // wait, land, retire - still under the dispatcher's seven to eight.
    logic            lb_hit_q;
    logic [15:0]     lb_ppn_q;
    logic [SIDX-1:0] lb_set_q;
    logic [LEV-1:0]  lb_way_q;
    logic            pc_ok_q, pq_fresh;
    always_ff @(posedge clk) begin
        lb_hit_q <= lb_hit && !rst;
        lb_ppn_q <= lb_ppn; lb_set_q <= lb_set; lb_way_q <= lb_way;
    end
    wire   l2_ok    = dq_v && turbo_en && pq_fresh && lb_hit_q && !in_sh_estate && !is_cx &&
                      !inval && !map_settling;
    // ...and the MAYBE on the first clock: a read the TLB might cover claims
    // the dispatcher before the register can say (the a2's w_pre shape), or
    // the dispatcher takes the cycle a clock before the launch and the leash
    // is gone.  A miss is released a clock late.
    wire   l2_pre   = dq_v && turbo_en && !pq_fresh && !in_sh_estate && !is_cx &&
                      !inval && !map_settling;
    assign dr_req   = l2_ok && !l2_pend && !l2_v_q && !lr_hit;
    assign dr_set   = lb_set_q;
    assign dr_way   = lb_way_q;
    assign dr_line  = dq_addr[7:4];
    wire dr_done_l2 = dr_done;

    // ---- the splice register ----------------------------------------------------
    logic        spl_v, spl_sh, spl_dup;
    logic [7:0]  spl_data;
    logic [23:0] spl_addr;
    logic [15:0] spl_ppn;
    logic [7:0]  spl_off8;
    wire         dup_go = spl_v && spl_sh;

    // ---- the serve, registered ---------------------------------------------
    wire serve_hit  = sh_hit || lby_hit || lr_hit || kb_hit || io_hit;
    wire [7:0] serve_byte = ({8{sh_hit}} & dq_byte) | ({8{lby_hit}} & lb_byte) | ({8{lr_hit}} & lr_byte) |
                            ({8{kb_hit}} & kbd_byte) | ({8{io_hit}} & io_byte);
    // The L2 row lands: into the last row, and its byte straight into the
    // serve register, if the candidate that launched it still stands.
    wire l2_snp;
    wire l2_land = l2_pend && dr_done_l2 && !l2_snp && !map_changed && !inval;
    wire l2_serve_now = l2_land && l2_live && !cyc_en;
    logic       sv_hit_q;
    logic [7:0] sv_byte_q;
    always_ff @(posedge clk) begin
        if (rst || cpu_rst) sv_hit_q <= 1'b0;
        else                sv_hit_q <= (serve_hit && !cyc_en) || l2_serve_now;
        sv_byte_q <= l2_serve_now ? dr_row[8 * dq_addr[3:0] +: 8] : serve_byte;
    end

    // ---- THE NEIGHBOUR SLOT: a read that retires on its FIRST clock ---------
    // MEASURED FIRST (2026-09-20, the GS/OS row, 16.58 M reads): 50.6% are the
    // previous read's address + 1 at the VERY NEXT data cycle - the second byte
    // of a 16-bit access - and another 14% are +/-1 further on, a block move's
    // source stream walking past its destination write and two internal cycles
    // (the gaps cluster at 0, then 2 and 3, and nowhere else).  35.5% are
    // neither, and they stay two-clock reads: their address comes out of the
    // AGU, and that chain is the one docs/GS.md already cut once.
    //
    // WHY THESE TWO ARE REACHABLE AND THE REST ARE NOT: a read costs two clocks
    // because the 816's AGU is a chained adder and din must be register-direct,
    // so the byte cannot be muxed out of a row in the cycle that asks for it
    // (the byte reaches din 5.6 ns in).  The addresses above are the only ones
    // the unit can know WITHOUT the AGU - the previous read's address plus the
    // stride - so the byte is picked out of the row we ALREADY HOLD, into a
    // register, on the clock the previous read retires.  When the next cycle
    // turns out to ask for it, it is served from that register on its first
    // clock.  din stays register-direct: the existing 2:1 becomes a 3:1, which
    // is one LUT6 either way.
    //
    // IT PERFORMS NO MEMORY ACCESS.  The byte comes from the row register, so a
    // prediction never used costs nothing, cannot reach the I/O page and cannot
    // evict a line; the row-crossing case (the next byte in the NEXT row) is
    // simply not predicted, which is why no prefetch, no `mv_done` and no
    // region gate are needed here.  A wrong prediction cannot be served either:
    // the address is compared before anything retires.  What is left is
    // STALENESS - a write to that byte between the copy and its use - and the
    // slot dies on it.
    logic        pb_v;
    logic [23:0] pb_addr;
    logic [7:0]  pb_byte;
    logic        pb_dn;              // the stride: 0 = +1, 1 = -1
    logic [23:0] pr_addr;            // the previous read's address
    logic        pr_v;
    // The row this read is being served out of: the one arriving, else the last.
    wire         pb_take = op_take && d_cycle && op_row_v && turbo_en;
    wire [19:0]  pb_rtag = pb_take ? {cpu_bank, cpu_addr[15:4]} : lr_addr;
    wire         pb_rok  = pb_take ? 1'b1 : lr_v;
    // The stride, from the step this read just made; unchanged when it made
    // none, so a run of +1s survives one unrelated read in the middle.
    wire         pb_up_n = pr_v && (dq_addr == (pr_addr + 24'd1));
    wire         pb_dn_n = pr_v && (dq_addr == (pr_addr - 24'd1));
    wire         pb_str  = pb_dn_n ? 1'b1 : (pb_up_n ? 1'b0 : pb_dn);
    wire [23:0]  pb_next = pb_str ? (dq_addr - 24'd1) : (dq_addr + 24'd1);
    wire         pb_same = pb_rok && (pb_next[23:4] == pb_rtag);
    wire [7:0]   pb_pick = pb_take ? op_row[8 * pb_next[3:0] +: 8]
                                   : lr_row[8 * pb_next[3:0] +: 8];
    // A write into the slot's ROW kills it (the row, not the byte: cheaper, and
    // a block move's source and destination are different rows).  The splices
    // are the core's own write landing a clock later, and they are killed
    // wholesale - in a block move they do not fire, the last row being the
    // source's while the write goes to the destination's.
    wire         ex_w    = cl_valid && cl_eng;    // the engine's write: see cl_eng
    wire         pb_kill = map_changed || inval || sp_write || lr_snp || ex_w ||
                           (w_retire && (dq_addr[23:4] == pb_addr[23:4]));

    wire d_cycle = !cyc_is_i &&  cpu_rw && !cyc_int;
    wire w_cycle = !cyc_is_i && !cpu_rw;
    wire n_cycle = cyc_int;
    wire pf_near_full;
    logic w_room;
    always_ff @(posedge clk) begin
        if (rst) w_room <= 1'b0;
        else     w_room <= ev_room_w && !pf_near_full;
    end
    // Bank zero below $C000 (RAM class under every map), or any address in
    // banks $02-$7F; RamWorks bank 0 only; mode 2 (wr_en).
    wire w_hi   = !dq_addr[23] && (dq_addr[22:17] != 6'd0);
    wire w_serv = wr_en && dq_wv && !rwb_nz_q &&
                  (((dq_addr[15:14] != 2'b11) && dq_bz) || w_hi);

    // The slot itself: refilled by every read that retires (the fast ones too,
    // so a run walks itself forward), emptied when the next byte is in another
    // row or a write lands in this one.
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval || map_changed) begin
            pb_v <= 1'b0; pb_addr <= 24'd0; pb_byte <= 8'd0; pb_dn <= 1'b0;
            pr_v <= 1'b0; pr_addr <= 24'd0;
        end else if (r_retire) begin
            pr_v    <= 1'b1;
            pr_addr <= dq_addr;
            pb_dn   <= pb_str;
            pb_v    <= pb_same;
            pb_addr <= pb_next;
            pb_byte <= pb_pick;
        end else if (pb_kill) begin
            pb_v <= 1'b0;
        end
    end

    logic fc_q, claim_q;
    always_ff @(posedge clk) begin
        if (rst || cpu_rst) begin
            fc_q <= 1'b0; claim_q <= 1'b0;
        end else begin
            fc_q    <= cyc_en;
            claim_q <= (turbo_en && (serve_hit || sv_hit_q || l2_pre || l2_ok || (l2_pend && l2_live) || l2_v_q) && d_cycle) ||
                       (w_serv && w_cycle) ||
                       (turbo_en && n_cycle);
        end
    end
    wire addr_match = (cpu_addr == dq_addr[15:0]) && (cpu_bank == dq_addr[23:16]) && (fc_q || claim_q);
    // A read retires from the registered hit, never on the cycle's first clock
    // - UNLESS the neighbour slot already holds this very address, in which
    // case the byte is in a register before the cycle began and it retires on
    // the first.  `!is_cx` for the same reason lr_hit carries it: a row's byte
    // is not what a $Cxxx address means.
    wire pb_hit   = pb_v && dq_v && !is_cx && (dq_addr == pb_addr);
    wire r_fast   = pb_hit && fc_q;
    wire r_hit    = (sv_hit_q && !fc_q) || r_fast;
    wire r_retire = !cpu_rst && turbo_en && turbo_ok && r_hit && d_cycle && addr_match && ev_room;
    wire w_retire = !cpu_rst && turbo_ok && w_serv && w_room && w_cycle && addr_match && !dup_go;
    wire n_retire = !cpu_rst && turbo_en && turbo_ok && n_cycle && (fc_q || claim_q);
    wire retire   = r_retire || w_retire || n_retire;

    assign d_commit = retire;
    assign cyc_en   = il_cyc_en || retire;
    // Three registers into one mux, one LUT6 deep, so din is still whole at
    // the AGU: the neighbour slot, the registered serve, the dispatcher's.
    assign d_din    = r_fast ? pb_byte : (sv_hit_q ? sv_byte_q : accel_din);
    assign claim    = claim_q;

    // ---- the splice ---------------------------------------------------------
    wire        cl_w    = cl_valid && !cl_rw && cl_wr_image && !cl_posted;
    wire        iw_v    = cl_w || spl_v;
    wire [15:0] iw_ppn  = spl_v ? spl_ppn  : cl_ppn;
    wire [7:0]  iw_off8 = spl_v ? spl_off8 : cl_off[7:0];
    wire [7:0]  iw_data = spl_v ? spl_data : wdata;
    wire       sp_hit  = iw_v && (iw_ppn[15:1] == 15'd0);
    wire [4:0] sp_line = {iw_ppn[0], iw_off8[7:4]};
    wire       lr_snp  = iw_v && lr_v && (iw_ppn == lr_ppn) && (iw_off8[7:4] == lr_addr[3:0]);
    assign     l2_snp  = (iw_v && (iw_ppn == l2_ppn) && (iw_off8[7:4] == l2_vt[3:0])) || ex_w;

    // The last byte follows the retiring edge; a write clears it; an internal
    // cycle is not an access.
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval || map_changed) begin
            lb_v <= 1'b0;
        end else begin
            if (cl_valid && !cl_rw) lb_v <= 1'b0;
            if (cyc_en && !cyc_int) begin
                if (cpu_rw) begin
                    lb_v    <= 1'b1;
                    lb_addr <= {cpu_bank, cpu_addr};
                    lb_byte <= cyc_is_i ? i_din : d_din;
                end else lb_v <= 1'b0;
            end
        end
    end

    // The stamp, sampled by the retire's own edge; the duplicate reloads it
    // the clock after with the Mega II bank's page by the side the primary
    // landed on (physical bank 0 is main, 1 auxiliary; $E0/$E1 follow it).
    always_ff @(posedge clk) begin
        if (rst || inval) begin
            spl_v <= 1'b0; spl_sh <= 1'b0; spl_dup <= 1'b0;
        end else begin
            spl_v   <= w_retire || dup_go;
            spl_sh  <= w_retire && d_sh;
            spl_dup <= dup_go;
        end
        if (w_retire) begin
            spl_addr <= dq_addr;
            spl_data <= cpu_dout;
            spl_ppn  <= d_ppn;
            spl_off8 <= dq_addr[7:0];
        end else if (dup_go) begin
            spl_ppn  <= {7'h70, spl_ppn[8], spl_ppn[7:0]};
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
    // Room for the entry in the register, the retire the sample could not
    // see, and the duplicate either may owe: three short.
    assign pf_near_full = (pf_cnt + (PW_AW+1)'(spl_v)) >= (PW_AW+1)'(PW_DEPTH - 2);
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
        if (r_retire && spl_v && !spl_dup && spl_addr == dq_addr)
            $error("l1d: a read of $%06x served on the splice clock of a write to it", dq_addr);
    always @(posedge clk)
        if (spl_v && pf_cnt == (PW_AW+1)'(PW_DEPTH) && !pw_take)
            $error("l1d: the posted FIFO overflowed");
    always @(posedge clk)
        if (l2_v_q && !lr_hit && dq_v)
            $error("l1d: the L2 row stands for a candidate the last row does not match");
    // A claim is a promise to retire: one that stands for thousands of clocks
    // without a cyc_en, with the leash granted, has deadlocked the dispatcher.
    // Name the state.  (With turbo_ok low the machine is held - a disk's
    // seek, a DMA - and the claim may legitimately stand for as long.)
    integer claim_clocks = 0;
    always @(posedge clk) begin
        if (rst || cyc_en || !claim_q || !turbo_ok) claim_clocks <= 0;
        else claim_clocks <= claim_clocks + 1;
        if (claim_clocks == 4096)
            $error("l1d: the claim has held the dispatcher 4096 clocks: dq_addr=$%06x dq_v=%0d dq_wv=%0d cpu=$%02x/%04x rw=%0d is_i=%0d int=%0d turbo_ok=%0d ev_room=%0d sv_hit_q=%0d serve_hit=%0d (sh %0d lb %0d lr %0d kb %0d io %0d) l2_ok=%0d l2_pend=%0d l2_live=%0d l2_v_q=%0d lb_hit=%0d fc_q=%0d w_serv=%0d w_room=%0d dup_go=%0d pending=%0d",
                   dq_addr, dq_v, dq_wv, cpu_bank, cpu_addr, cpu_rw, cyc_is_i, cyc_int, turbo_ok, ev_room, sv_hit_q, serve_hit,
                   sh_hit, lby_hit, lr_hit, kb_hit, io_hit, l2_ok, l2_pend, l2_live, l2_v_q, lb_hit, fc_q, w_serv, w_room, dup_go, pending);
    end

    // ---- THE READS' NEIGHBOURHOOD, for sizing a one-clock serve -------------
    // SIM ONLY: no synthesis, no timing, no hardware.  Every read retires on
    // its SECOND clock because the 816's AGU is a chained adder and its din
    // must be register-direct (the header), and the general fix - start the
    // lookup from the core's early address - is the chain docs/GS.md already
    // cut once: the byte reaches din 5.6 ns in, and the AGU is behind it.
    //
    // What IS reachable is a read whose address the unit can know WITHOUT the
    // AGU, because it is the previous read's address plus one: the second byte
    // of a 16-bit access (the very next data cycle) and a block move's source
    // stream (+/-1, but a write and two internal cycles away - seven core
    // cycles per byte moved).  Those two want different machinery - a register
    // valid for one cycle against a persistent pair of slots - so this counts
    // which reads are which BEFORE either is built.
    //
    // `gap` is the D-side retires (writes, internal cycles) between this read
    // and the last one: gap 0 is the 16-bit pair, gap 3 with a write in it is
    // the block move's signature.
    logic [23:0] m_prev_addr;
    logic        m_prev_v;
    logic [3:0]  m_gap;
    logic [31:0] m_reads, m_p1_now, m_p1_gap, m_m1_now, m_m1_gap, m_other;
    logic [31:0] m_gaphist [0:7];        // the gap a +/-1 read came at
    always_ff @(posedge clk) begin
        if (rst) begin
            m_prev_v <= 1'b0; m_prev_addr <= 24'd0; m_gap <= 4'd0;
            m_reads <= '0; m_p1_now <= '0; m_p1_gap <= '0;
            m_m1_now <= '0; m_m1_gap <= '0; m_other <= '0;
            for (int g = 0; g < 8; g = g + 1) m_gaphist[g] <= '0;
        end else if (r_retire) begin
            m_reads <= m_reads + 32'd1;
            if (m_prev_v && dq_addr == (m_prev_addr + 24'd1)) begin
                if (m_gap == 4'd0) m_p1_now <= m_p1_now + 32'd1;
                else               m_p1_gap <= m_p1_gap + 32'd1;
                m_gaphist[m_gap[2:0]] <= m_gaphist[m_gap[2:0]] + 32'd1;
            end else if (m_prev_v && dq_addr == (m_prev_addr - 24'd1)) begin
                if (m_gap == 4'd0) m_m1_now <= m_m1_now + 32'd1;
                else               m_m1_gap <= m_m1_gap + 32'd1;
                m_gaphist[m_gap[2:0]] <= m_gaphist[m_gap[2:0]] + 32'd1;
            end else begin
                m_other <= m_other + 32'd1;
            end
            m_prev_addr <= dq_addr;
            m_prev_v    <= 1'b1;
            m_gap       <= 4'd0;
        end else if (w_retire || n_retire) begin
            if (m_gap != 4'd15) m_gap <= m_gap + 4'd1;
        end
    end
`endif

    // ---- the shadow claim ---------------------------------------------------
    localparam [1:0] C_IDLE = 2'd0, C_OPW = 2'd1, C_W2O = 2'd2;
    logic [1:0]   cst;
    logic [4:0]   c_line;
    logic         miss_q;
    logic [4:0]   miss_line_q;
    logic [127:0] orow_q;
    assign fill_busy = (cst != C_IDLE) || l2_pend;
    wire live_zs   = (cpu_addr[15:9] == 7'd0) && (cpu_bank == 8'd0) && !cyc_int;
    wire live_miss = turbo_en && d_cycle && live_zs && zs_main_q &&
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
    logic [15:0] p_ppn_q2;
    logic [3:0]  p_reg_q2;
    logic        p_fold_q2;
    always_ff @(posedge clk) begin
        pc_ok_q   <= (d_cls == CLS_RAM) || (d_cls == CLS_LC) || (d_cls == CLS_ROM);
        p_ppn_q2  <= d_ppn;
        p_reg_q2  <= d_reg;
        p_fold_q2 <= d_fold;
        pq_fresh  <= !cyc_en && !rst && !cpu_rst;
    end
    wire tlb_miss = dq_v && turbo_en && !lb_hit_q && !in_sh_estate && !is_cx && pq_fresh && pc_ok_q &&
                    !inval && !map_settling && !fj_v;
    logic        tf_v;
    logic [15:0] tf_vpage;
    logic [15:0] tf_ppn;
    logic [3:0]  tf_reg;
    logic        tf_fold;

    logic [31:0] cnt_claims, cnt_splices, cnt_lb_serves, cnt_lr_serves, cnt_posts, cnt_post_waits,
                 cnt_l2_launch, cnt_l2_abort, cnt_tlb_waits, cnt_kb_serves, cnt_io_serves,
                 cnt_post_hi, cnt_dups, cnt_null, cnt_fast_rd;
    logic bk_rr_q, bk_lb_q, bk_lr_q, bk_l2_q, bk_kb_q, bk_io_q;
    always_ff @(posedge clk) begin
        bk_rr_q <= r_retire && !rst;
        bk_lb_q <= !sh_hit && lby_hit;
        bk_lr_q <= !sh_hit && !lby_hit && lr_hit;
        bk_l2_q <= l2_v_q;
        bk_kb_q <= kb_hit;
        bk_io_q <= io_hit;
    end
    always_ff @(posedge clk) begin
        tick_q    <= retire;
        dev_valid <= retire && !n_retire;
        kbd_rd    <= r_retire && dq_kbd && !rst;
        if (retire && !n_retire) begin
            dev_addr <= dq_addr[15:0];
            dev_data <= cpu_rw ? sv_byte_q : cpu_dout;
            dev_rw   <= cpu_rw;
            dev_bank <= dq_addr[23:16];
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
                cnt_kb_serves <= 32'd0; cnt_io_serves <= 32'd0; cnt_post_hi <= 32'd0;
                cnt_dups <= 32'd0; cnt_null <= 32'd0;
                dev_addr <= 16'd0; dev_data <= 8'd0; dev_rw <= 1'b1; dev_bank <= 8'd0;
                l2_ppn <= 16'd0; l2_vt <= 20'd0;
            end
        end else begin
            if (retire) cnt_serves <= cnt_serves + 32'd1;
            // The serve books count a clock late, from registered flags: the
            // core's instruction register into a counter's enable was the
            // deep tail lut1 named (2026-09-20).
            if (bk_rr_q) begin
                if (bk_lb_q) cnt_lb_serves <= cnt_lb_serves + 32'd1;
                if (bk_lr_q) cnt_lr_serves <= cnt_lr_serves + 32'd1;
                if (bk_l2_q) cnt_l2_serves <= cnt_l2_serves + 32'd1;
                if (bk_kb_q) cnt_kb_serves <= cnt_kb_serves + 32'd1;
                if (bk_io_q) cnt_io_serves <= cnt_io_serves + 32'd1;
            end
            if (w_retire) cnt_posts <= cnt_posts + 32'd1;
            if (w_retire && w_hi) cnt_post_hi <= cnt_post_hi + 32'd1;
            if (dup_go) cnt_dups <= cnt_dups + 32'd1;
            if (n_retire) cnt_null <= cnt_null + 32'd1;
            if (r_retire && r_fast) cnt_fast_rd <= cnt_fast_rd + 32'd1;
            if (turbo_ok && w_serv && w_cycle && addr_match && !w_room && !cpu_rst)
                cnt_post_waits <= cnt_post_waits + 32'd1;
            if (sp_write || lr_snp) cnt_splices <= cnt_splices + 32'd1;

            // The last row: spliced first, so a same-edge capture wins.
            if (lr_snp) lr_row[8 * iw_off8[3:0] +: 8] <= iw_data;
            if (op_take && d_cycle && op_row_v && turbo_en) begin
                lr_v    <= 1'b1;
                lr_addr <= {cpu_bank, cpu_addr[15:4]};
                lr_ppn  <= op_row_ppn;
                lr_row  <= op_row;
            end

            // The L2 read.
            if (dr_ack) begin
                l2_pend <= 1'b1;
                l2_live <= 1'b1;
                l2_ppn  <= lb_ppn_q;
                l2_vt   <= dq_addr[23:4];
                cnt_l2_launch <= cnt_l2_launch + 32'd1;
            end
            if (l2_pend && dr_done_l2) begin
                l2_pend <= 1'b0;
                if (l2_land) begin
                    lr_v    <= 1'b1;
                    lr_addr <= l2_vt;
                    lr_ppn  <= l2_ppn;
                    lr_row  <= dr_row;
                    l2_v_q  <= l2_live && !cyc_en;
                end else cnt_l2_abort <= cnt_l2_abort + 32'd1;
            end
            if (cyc_en) begin l2_v_q <= 1'b0; l2_live <= 1'b0; end
            // after every capture above: a row read before the engine's write
            // landed must not survive it
            if (ex_w) lr_v <= 1'b0;
            if (map_changed) begin
                lr_v <= 1'b0; l2_v_q <= 1'b0; l2_live <= 1'b0;
            end

            // The shadow claim, from the dispatcher's own read of the row.
            case (cst)
                C_IDLE: if (miss_q) begin
                    c_line <= miss_line_q;
                    cst    <= C_OPW;
                end
                C_OPW: if (cyc_en && d_cycle) begin
                    if (op_take && op_row_v && (cpu_addr[8:4] == c_line) && (cpu_addr[15:9] == 7'd0) &&
                        (cpu_bank == 8'd0) && (op_row_ppn == {15'd0, c_line[4]})) begin
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
                tf_vpage <= dq_addr[23:8];
                tf_ppn   <= p_ppn_q2;
                tf_reg   <= p_reg_q2;
                tf_fold  <= p_fold_q2;
                cnt_tlb_waits <= cnt_tlb_waits + 32'd1;
            end else if (tlb_miss && tf_v && tf_vpage != dq_addr[23:8]) begin
                tf_vpage <= dq_addr[23:8];
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
                cnt_kb_serves <= 32'd0; cnt_io_serves <= 32'd0; cnt_post_hi <= 32'd0;
                cnt_dups <= 32'd0; cnt_null <= 32'd0; cnt_fast_rd <= 32'd0;
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
            4'd11: dbg_val = cnt_io_serves;
            4'd12: dbg_val = cnt_lr_serves;
            4'd13: dbg_val = {cst, pending, dq_v, dq_wv, zs_main_q, turbo_en, wr_en,
                              l2_pend, l2_v_q, claim_q, fc_q, tf_v, fj_v, l2_live, sv_hit_q, shv[15:0]};
            4'd14: dbg_val = cnt_post_hi;
            default: dbg_val = cnt_null;
        endcase
    end
endmodule
