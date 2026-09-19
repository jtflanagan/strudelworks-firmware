`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// iline - the instruction stream's line front: two 16-byte lines ahead of the
// sequencer, riding the program's linearity.  docs/ISTREAM.md.
//
// Between rtl/cpu65c02.sv and rtl/accel_seq.sv.  The core names each cycle's
// stream (cyc_is_i) and its data return is split (i_din/d_din); this module
// owns i_din.  It holds TWO lines - the one the program is executing from and
// the one after it - and a program-stream fetch that lands in either retires
// in ONE CLOCK: the byte was looked up a clock early at i_pred (the core's
// exact next-fetch address) and stands REGISTERED on i_din, the tag compare
// runs off the PC registers, cyc_en is asserted for the core, and the
// sequencer sees only the books (turbo_commit: the governor's charge, the
// ACCEL_TURBO count, the floppy's and the Mockingboard's tick, a capture
// event when the merge has room).  A fetch that lands in neither line rides
// the sequencer exactly as before - and trains this module in parallel, so
// the NEXT fetch hits.
//
// THE PREFETCH is the user's design: predict that the instruction stream is
// linear.  On the first retire out of a newly-entered line the other slot is
// retired from duty and the line after the new one is fetched into it, so by
// the time execution crosses the boundary the next sixteen bytes are already
// registered.  Jumps and taken branches out of the held pair are not
// predicted: they miss once, pay the sequencer's price, and the train
// follows them.  A short branch WITHIN the held pair is free - the compare
// is against both tags, not against an expected next address.
//
// THE LATE CANCEL.  cyc_en is asserted speculatively and every late "oops"
// - an override engaging on this very fetch (the boot hold catching its
// SYNC), a map change landing this clock, a snoop killing the line being
// served - pulls it low at the end of the clock, and a cancelled edge
// consumes nothing (rtl/cpu65c02.sv, the contract sim/run_cpu_predict_tb.sh
// proves under random cancels with garbage on both din ports).
//
// WHAT IS NEVER SERVED HERE, by rule:
//   * anything the classifier calls BUS - so all of $C000-$C0FF, every
//     slot's pages, and the internal ROM before it has loaded;
//   * the $CFF0 line, always, and page $C3 while the IIe's INTC8ROM latch
//     is CLEAR: an access there moves the latch, which the MMU shadow
//     learns from the unified op stream - a turbo retire never reaches
//     that stream, so the access that sets it rides the sequencer
//     (rtl/apple_mmu.sv, "INTC8ROM").  Once set, a $C3xx access changes
//     nothing on the card or the machine and the page is served like any
//     internal-ROM page; the clear ($CFFF, reset) pulses map_changed,
//     which empties the front, and the exclusion resumes;
//   * any cycle while an op is on the bus, an override is engaging, the
//     reset sequence is riding the pins, or the sequencer lacks credit -
//     all folded into turbo_ok (rtl/accel_seq.sv).
//
// COHERENCE.  Every write that lands in the image passes the MMU classified
// (cl_*), and its folded identity {aux, bank, off} snoops both lines and the
// fill in flight the same clock - before the write reaches the banks - so
// self-modifying code cannot fetch a stale byte; the write op itself rides
// the sequencer, and the core is serial, so the refetch is behind it by
// construction.  A map change (any soft switch, the LC, the bank register,
// INTC8ROM, a reset) kills both lines and restarts the fill: their
// classification was captured when they were fetched.  ROM lines die on any
// ROM load traffic.  Serving turned off, or the image invalidated, empties
// the front.
//
// THE CLAIM holds the sequencer's dispatcher off while a fetch this module
// is about to answer is in flight - the demand fill of a fresh miss, or the
// crossing into a prefetch still one or two clocks out.  It is bounded: a
// fill either commits or declines within a handful of clocks, and a decline
// drops the want, the claim with it, and the op rides the sequencer.
//
// THE RETENTION CAM AND THE BRANCH SCANNER (the branch_prefetch work).
// Behind the slots stands a small CAM - tags and identities in flip-flops,
// the lines' bytes in distributed RAM, NO block RAM - holding the last
// lines the engine committed plus the branch scanner's prefetches.  The
// scanner (rtl/iscan.sv) walks instruction boundaries ahead of the program
// through the held pair and asks for every branch, JMP and JSR target's
// line, so the line stands retained before the branch is taken.  A want the
// CAM holds is PROMOTED - one clock into the slot, no page-cache round trip
// - and a transfer the scanner finds from one held line into the other pins
// the pair against the crossing's rotation, so a loop held whole in two
// lines runs at the within-pair branch's price with NO refetch at all.  The
// serve path reads only the slots, exactly as before: the CAM is behind the
// engine, never in the retire cones.  For coherence the CAM is held to the
// slots' own rules - the write snoop entry by entry, the map-change flash
// clear (which is also what lets promotion skip re-classification), ROM
// entries dying on ROM load traffic - and the scanner cannot poison
// anything: its wants are classified, filtered and snooped like any fill,
// so a misread stream only ever wastes a prefetch.
//////////////////////////////////////////////////////////////////////////////////
module iline #(
    // 1 = the Apple IIgs build (docs/GS.md rung 6): the lines carry the
    // virtual bank they were fetched in, the fill asks the map with a bank,
    // and the I/O window's exclusions apply in the four pair banks alone.
    // At 0 every bank below is a constant zero and the IIe's netlist is
    // what it was.
    parameter bit GS = 1'b0
) (
    input  wire        clk,
    input  wire        rst,           // the card's
    // The core's: the card's OR RES'.  The machine resetting kills the
    // PREDICTOR (not the lines - real RAM survives a reset): the core's
    // first post-reset cycles are PC-sourced with the OLD PC, reset_seq and
    // the map-change kill each lag a clock behind cpu_rst, and a retire in
    // that window feeds a resetting core a stale byte and desynchronizes
    // its reset sequence from the machine's.  Found as zero passes after
    // the boot hold's reset, one wrong byte on the monitor.
    input  wire        cpu_rst,

    // The core.  pc_addr is {pch, pcl} REGISTER-DIRECT (rtl/cpu65c02.sv):
    // on every program-stream cycle it equals the bus address by
    // construction, and it is free of the AGU and din always - so every
    // compare in this module starts at flip-flop outputs.
    input  wire [15:0] pc_addr,
    // ...and the bank it is in - the 65816's PBR, register-direct; a 65C02
    // has none and the caller ties it.  A program-stream fetch is at
    // {pc_bank, pc_addr} by construction.  PBR is part of the map (the
    // MMU's map_now), so a change of it revalidates every line here.
    input  wire [7:0]  pc_bank,
    input  wire        cpu_rw,
    input  wire        cpu_sync,
    input  wire        cyc_is_i,
    input  wire [7:0]  p_flags,      // {N,V,1,0,D,I,Z,C} register-direct: what
                                     // a branch will test (rtl/cpu65c02.sv)
    output wire        cyc_en,        // to the core: the sequencer's, or a turbo retire
    output wire [7:0]  i_din,         // the core's I-stream byte

    // The sequencer's path through (rtl/accel_seq.sv).
    input  wire        accel_cyc_en,
    input  wire [7:0]  accel_din,     // the sequencer/driver byte: a slow-served I-cycle's
    input  wire        turbo_en,      // steady: accelerating, serving, out of reset_seq
    input  wire        turbo_ok,      // this clock's permission (includes the late gates)
    output wire        claim,         // hold the dispatcher: this fetch is almost mine
    output wire        turbo_commit,  // combinational: one op retired on this edge
    output wire        turbo_sync,    // ...and it was an opcode fetch (boot_hold's books)

    // The registered tick and the capture event.
    output logic        tick_q,       // one pulse per retired op (floppy, Mockingboard)
    output logic        tev_valid,    // the event, when the merge had room
    output logic [15:0] tev_addr,
    output logic [7:0]  tev_data,
    output logic        tev_sync,
    output logic [7:0]  tev_bank,     // the retire's bank (GS); zero on a IIe
    input  wire         ev_room,      // the merge can take a word this clock

    // The MMU: the prefetch's classification, and the map's edge.
    output wire [23:0] p_addr,        // {pc_bank, the line, 4'h0}
    input  wire        map_changed,
    // The PHYSICAL side of the same picture (docs/MEMORY_REFACTOR.md, rung 3):
    // the picked line's page, the REGION it classifies in, the fold bit, and
    // FS - "front-servable", which replaces `p_cls != BUS` and carries the
    // page-$C3 rule.  rt_rd_flat is the thirteen packed read-table entries a held
    // line is revalidated against, rwb_p1 the physical bank an auxiliary
    // access reaches, map_settling map_changed stretched over the clocks a
    // revalidation needs.
    input  wire [15:0] p_ppn,
    input  wire [3:0]  p_reg,
    input  wire        p_fold,
    input  wire        p_fs,
    input  wire [15:0] cl_ppn,        // the classified write's page, for the snoop
    input  wire [103:0] rt_rd_flat,
    input  wire [7:0]  rwb_p1,
    input  wire        map_settling,
    input  wire        intc8rom,      // apple_mmu's latch: page $C3 is servable while set

    // The page cache's line port (rtl/page_cache.sv).  The request names a
    // PHYSICAL page and the line in it; the grant is il_ack, and il_done
    // stands exactly three clocks later with il_ok (the page was resident)
    // and the row.  A page that is not resident DECLINES: the fetch rides
    // the sequencer instead, and the miss it takes fills the page.
    output wire         il_req,
    output wire [15:0]  il_ppn,
    output wire [3:0]   il_line,
    input  wire         il_ack,
    input  wire         il_done,
    input  wire         il_ok,
    input  wire [127:0] il_row,

    // The write snoop: the MMU's classified op (P1)...
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    // ...and the data front's POSTED write (rtl/dline.sv, rung 3), the
    // clock after it retired: its stamped identity, register-rooted in the
    // front.  The store into the very next opcode is one clock from its
    // fetch, so this port cannot wait for the write to come round through
    // the classified stream at its drain (where it snoops again, harmlessly:
    // fills are held off while the write is in flight).
    output wire [31:0] idrop_o,       // ACCEL_IDROP: lines a map change dropped
    output wire [31:0] irevive_o,     // ACCEL_IREVIVE: ...and lines one put back

    input  wire        ws_valid,
    input  wire [15:0] ws_ppn,        // the posted write's PHYSICAL page...
    input  wire [7:0]  ws_off8,       // ...and the byte in it
    input  wire        cl_aux,
    input  wire [7:0]  cl_bank,
    input  wire [15:0] cl_off,

    // The flushes.
    input  wire        serve,         // MEM_CTRL's: off empties the front
    input  wire        inval,

    // The debug pair's window (rtl/wb_regfile.sv DBG_SEL/DBG_VAL): the
    // books below, and a state snapshot, by item.
    input  wire [3:0]  dbg_sel,
    output logic [31:0] dbg_val,

    // A line fill is in flight (F_REQ through F_W2): the clock histogram in
    // rtl/master_top.sv charges the core's stalled clocks to it.
    output wire        fill_busy
);

    localparam [1:0] CLS_BUS = 2'd0;

    // ---- the two lines ------------------------------------------------------
    logic         v      [0:1];
    // RETAINED, beside valid (docs/MEMORY_REFACTOR.md, rung 3): the tags and
    // the bytes still mean something and the line can be revived.  A map
    // change no longer empties the front - it recomputes each line's VALID
    // bit from the line's stored identity against the map's new region
    // table.  A line only loses `r` to a write's snoop, to the image going
    // away, or to being replaced.
    logic         r      [0:1];
    logic [11:0]  vtag   [0:1];       // pc_addr[15:4] of the line
    // The line's PHYSICAL IDENTITY: its page, the REGION it was classified
    // in, and whether the language card's fold applied.  The page plus
    // vtag[3:0] (the line within the page - the fold never touches a[11:4])
    // is what a write's snoop compares.
    logic [15:0]  t_ppn  [0:1];
    logic [3:0]   t_reg  [0:1];
    logic         t_fold [0:1];
    // ...and the VIRTUAL bank it was fetched in (GS): valid only while it is
    // the program's bank, which the revalidation checks - the tags stay
    // sixteen bits and no bank byte is compared in a serve cone.
    logic [7:0]   t_vbank [0:1];
    logic [127:0] ldata  [0:1];
    logic         cur;                // the slot execution is in

    // ---- the retained set, indexed (2026-09-11; docs/ISTREAM.md) ----------
    // What was an eight-entry fully-associative CAM is a SIXTEEN-SET BY
    // FOUR-WAY line cache, the data front's shape: every line the engine
    // commits, the scanner's branch-target prefetches, a want that hits here
    // is PROMOTED (one beat, no page-cache round trip).  THE SET IS THE
    // LINE-IN-PAGE, addr[7:4], which is the same in the virtual and the
    // physical space (a page is 256 bytes): so the snoop and the dedupe
    // index by the write's line-in-page and compare ICW physical pages, the
    // candidates index by their own and compare ICW eight-bit tags, and
    // nothing compares across the whole set.  Identities in flip-flops (a
    // map change reads them all at once); the rows in one 64-deep LUTRAM
    // per read port, addressed by {way, set} - the way from the compare, so
    // a candidate's byte is compare -> read -> select inside the full clock
    // the lookups already have into their registers.
    //
    // Lines die exactly as slot lines do: the write snoop by physical
    // identity (both sources), ROM load traffic for ROM lines, an
    // invalidate, serving off.  A map change takes nothing: every line's
    // VALID bit is recomputed from its stored identity against the new
    // region table (the slots' two register-rooted stages), so a line whose
    // region did not move keeps serving and one whose bank comes back
    // revives.  Promotion needs no re-classification by the same argument.
    // The dedupe compares PHYSICAL identities within a set, so main's and
    // aux's copies of one virtual tag coexist with at most one valid.
    // EIGHT SETS, the data front's size (the user's call: 16 x 4 closed at
    // +0.003 and its bitstream never calibrated the DDR3 - docs/GS.md).  The
    // set is addr[6:4]; the tag is addr[15:7]; the physical identity the
    // snoop and the dedupe compare is the page AND addr[7], the one bit of
    // the line-in-page the set leaves out (the data front's PTW).
    localparam integer ICS = 8;                  // sets: addr[6:4]
    localparam integer ISW = 3;                  // the set index's width
    localparam integer ICW = 4;                  // ways
    localparam integer IWW = 2;                  // a way index
    localparam integer ITW = 9;                  // the tag: addr[15:7]
    logic [ICS-1:0]     ic_v    [0:ICW-1];
    logic [ICS-1:0]     ic_r    [0:ICW-1];
    logic [ITW-1:0]     ic_tag  [0:ICW-1][0:ICS-1];
    logic [15:0]        ic_ppn  [0:ICW-1][0:ICS-1];
    logic [ICS-1:0]     ic_a7   [0:ICW-1];      // addr[7] of the line, the identity's odd bit
    logic [3:0]         ic_reg  [0:ICW-1][0:ICS-1];
    logic               ic_fold [0:ICW-1][0:ICS-1];
    logic [7:0]         ic_vbank[0:ICW-1][0:ICS-1];
    logic [127:0]       ic_mem  [0:ICW*ICS-1];   // the LUTRAM, {way, set}
    logic [IWW-1:0]     ic_rrp  [0:ICS-1];       // the next victim, per set

    // The lookups: the ways of an address's set, valid and tagged with its
    // page; the way index of a (one-hot, by the dedupe) match; a byte out
    // of a row.
    function automatic [ICW-1:0] ic_match(input [15:0] a);
        for (int w = 0; w < ICW; w = w + 1)
            ic_match[w] = ic_v[w][a[6:4]] && (ic_tag[w][a[6:4]] == a[15:7]);
    endfunction
    function automatic [IWW-1:0] ic_way(input [ICW-1:0] m);
        ic_way = '0;
        for (int w = ICW - 1; w >= 0; w = w - 1) if (m[w]) ic_way = IWW'(w);
    endfunction
    function automatic [7:0] ic_sel(input [127:0] row, input [3:0] off, input hit);
        ic_sel = hit ? row[8 * off +: 8] : 8'h00;
    endfunction

    // The loop bits: the scanner saw a transfer from slot s's line into the
    // other's - the pair holds a loop whole, so the crossing must not rotate
    // it away.  Cleared whenever either slot's content changes; the scanner
    // re-finds a live loop within an iteration.
    logic         loop_sup [0:1];

    // ---- the serve ----------------------------------------------------------
    // THE BYTE AND ITS SELECT ARE REGISTERS, fed by the front's own "+1"
    // PREDICTOR - the user's design, and the only shape that closes timing.
    // A live byte mux on pc_addr closes a structural loop through the
    // core's AGU (din -> addr -> byte mux -> i_din -> din: never logically
    // active, but synthesis ballooned to 52 GB on it), and a lookup at the
    // core's i_pred drags its next-PC carry chains plus the late cyc_en
    // select into one 18-level cone (-1.5 ns).  So the front predicts for
    // itself: exp_q is the last program-stream fetch plus one, three byte
    // candidates are looked up IN PARALLEL from registers - the sequential
    // step (exp_q+1), the recovery (pc_addr: a mispredict re-aims here),
    // the hold (exp_q) - and the late retire/recover verdicts only pick
    // among them.  A correctly predicted fetch retires at a cadence of one;
    // a taken branch or jump - even into the held pair - re-aims in ONE
    // stall beat and runs on; a fill's first serve is one clock after its
    // commit.
    wire hit0 = v[0] && (pc_addr[15:4] == vtag[0]);
    wire hit1 = v[1] && (pc_addr[15:4] == vtag[1]);

    logic [15:0] exp_q;              // the predicted next program-stream fetch
    logic        lhit_q;             // the lookup found a held line...
    logic [7:0]  i_byte_q;           // ...and this is its byte
    wire [15:0] exp_inc = exp_q + 16'd1;

    // THE CAM SERVES TOO (the branch_prefetch work): every candidate looks
    // up all ten lines - the slots and every retained entry - so a fetch
    // into ANY resident line runs at the cadence of one; the retained line
    // needs no promote first, the promote only re-centers the pair behind
    // it.  The lookups have a full clock into a register, so their width is
    // not in the late cones.  Dedupe (one live entry per tag, every copy
    // snooped identically) is what makes any matching source's byte THE
    // byte.  The live widths that DO grow - eight more register-to-register
    // compares in the retire's ihit, two snoop terms in kill_now - are the
    // build's watchpoints, each with a registered-hint fallback.
    wire [ICW-1:0] cam_mpc = ic_match(pc_addr);
    wire [ICW-1:0] cam_hi  = ic_match(exp_inc);
    wire [ICW-1:0] cam_hh  = ic_match(exp_q);
    wire [127:0]   ic_row_pc  = ic_mem[{ic_way(cam_mpc), pc_addr[6:4]}];
    wire [127:0]   ic_row_inc = ic_mem[{ic_way(cam_hi),  exp_inc[6:4]}];
    wire [127:0]   ic_row_hh  = ic_mem[{ic_way(cam_hh),  exp_q[6:4]}];
    wire cam_pc_hit = |cam_mpc;       // the fetch's line is retained

    wire ihit = cyc_is_i && cpu_rw && (hit0 || hit1 || cam_pc_hit);
    wire hslot = !hit0;               // slot 0 wins a (never-built) double hit

    // The three candidates, register-sourced, in parallel; slots win a
    // double residency (their byte is identical by the snoop).
    wire        hi0 = v[0] && (exp_inc[15:4]  == vtag[0]);
    wire        hi1 = v[1] && (exp_inc[15:4]  == vtag[1]);
    wire        hc0 = v[0] && (pc_addr[15:4] == vtag[0]);
    wire        hc1 = v[1] && (pc_addr[15:4] == vtag[1]);
    wire        hh0 = v[0] && (exp_q[15:4]    == vtag[0]);
    wire        hh1 = v[1] && (exp_q[15:4]    == vtag[1]);
    wire [7:0]  b_inc  = hi0 ? ldata[0][8 * exp_inc[3:0]  +: 8] :
                         hi1 ? ldata[1][8 * exp_inc[3:0]  +: 8] :
                               ic_sel(ic_row_inc, exp_inc[3:0], |cam_hi);
    wire [7:0]  b_cur  = hc0 ? ldata[0][8 * pc_addr[3:0] +: 8] :
                         hc1 ? ldata[1][8 * pc_addr[3:0] +: 8] :
                               ic_sel(ic_row_pc, pc_addr[3:0], |cam_mpc);
    wire [7:0]  b_hold = hh0 ? ldata[0][8 * exp_q[3:0]    +: 8] :
                         hh1 ? ldata[1][8 * exp_q[3:0]    +: 8] :
                               ic_sel(ic_row_hh, exp_q[3:0], |cam_hh);

    // ---- early branch resolution (the user's design) ------------------------
    // At a branch's operand cycle everything needed is already registered
    // truth: the OPCODE (latched at its own fetch), the OFFSET (the byte
    // being served this very cycle - a slow serve delivers it too, so the
    // line-boundary case guards itself), and the FLAGS (the previous
    // instruction's writeback landed entering T0, and a branch writes
    // none; p_flags is the same register the core's own condition reads).
    // So the front decides taken-and-where right there, looks the target
    // up as a FOURTH candidate, and the target fetch - however many dummy
    // cycles later, page cross included - serves with ZERO stall.  The
    // conclusion cannot be wrong, only useless: the candidate serves only
    // when the core's real fetch address equals it, and the byte is
    // revalidated by the live tags like every serve.  A lingering target
    // (an interrupt hijacked the boundary) is therefore still a CORRECT
    // serve if it ever matches, and is cleared at the next opcode fetch.
    localparam [1:0] BK_NONE = 2'd0, BK_BR = 2'd1, BK_ABS = 2'd2;
    logic [1:0]  bk_q;                // what the last opcode fetched was
    logic        bk_hi;               // ABS: low byte captured, the high is next
    logic [7:0]  br_op, lo_q;
    logic        tgt_v;
    logic [15:0] tgt_q;
    logic        tgt_lhit_q;          // the target lookup, registered like lhit_q
    logic [7:0]  tgt_byte_q;

    wire i_serve = cyc_en && cyc_is_i && cpu_rw;   // an I-byte consumed this edge
    wire op_is_branch = (i_din[4:0] == 5'b10000) || (i_din == 8'h80);
    wire op_is_abs    = (i_din == 8'h4C) || (i_din == 8'h20);   // JMP abs, JSR
    // The core's own rule (rtl/cpu65c02.sv "Branch condition"): op[7:6]
    // picks the flag, op[5] the sense; BRA is always.
    wire br_flag  = (br_op[7:6] == 2'b00) ? p_flags[7] :
                    (br_op[7:6] == 2'b01) ? p_flags[6] :
                    (br_op[7:6] == 2'b10) ? p_flags[0] : p_flags[1];
    wire br_taken = (br_op == 8'h80) || (br_flag == br_op[5]);
    wire [15:0] br_tgt = pc_addr + 16'd1 + {{8{i_din[7]}}, i_din};

    // The RESOLVE: a branch's at its operand; a JMP's or JSR's at its high
    // byte - which for both is the very cycle before the target fetch.
    // JSR's stack cycles between the operands are data, invisible to
    // i_serve, so "the second operand serve" holds for both shapes.
    wire resolving = i_serve && !cpu_sync &&
                     ((bk_q == BK_BR) || (bk_q == BK_ABS && bk_hi));
    wire [15:0] res_tgt   = (bk_q == BK_BR) ? br_tgt : {i_din, lo_q};
    wire        res_taken = (bk_q == BK_BR) ? br_taken : 1'b1;

    // THE LOOKUP ADDRESS IS SPECULATIVE, REGISTERS ONLY - the house rule:
    // late verdicts pick, they never compute.  The first build's only
    // violations (-0.038) were this address qualified by `resolving`,
    // which threads i_serve -> cyc_en -> retire -> kill_now -> the write
    // snoop: half the period gone before the ten-line lookup even starts.
    // So the address speculates from bk state, the registered flags
    // verdict and the REGISTERED candidate byte (i_byte_q, standing for
    // the operand about to be served), and the late truth gates only the
    // one-bit valid below: if the operand actually arrived from the
    // sequencer or the target path instead, the valid stays low and the
    // lookup self-heals off tgt_q a cycle later - the one-beat fallback,
    // paid only there.  A branch's dummy cycle absorbs even that.
    //
    // A BRANCH DOES NOT SPECULATE HERE (2026-09-14, the scan-target
    // experiment).  It used to: the lookup address was pc_addr + 1 + the
    // candidate offset, gated by the flags verdict - a 16-bit add off the
    // core's PC and carry flag at the head of the target lookup, the
    // longest chain in the design (17 levels, -0.121 ns in the two-ledger
    // Mockingboard build).  But a taken branch always spends a dummy cycle
    // between its operand and its target fetch, and the lookup below
    // self-heals off tgt_q - the registered truth from the resolve - on
    // exactly that clock, so the byte is registered before the target fetch
    // asks for it whether or not it was speculated a clock earlier.  Only a
    // JMP/JSR has no such clock: its lookup still runs on the high byte
    // being served, register-fed ({i_byte_q, lo_q}, no arithmetic).  The
    // accel bench's zero-stall count (cnt_tgt_serves) is the proof either
    // way.
    wire        spec_pending = (bk_q == BK_ABS && bk_hi);
    wire [15:0] spec_tgt = {i_byte_q, lo_q};
    wire [15:0] tgt_look = spec_pending ? spec_tgt : tgt_q;
    wire [15:0] tgt_inc  = tgt_q + 16'd1;
    wire        ht0 = v[0] && (tgt_look[15:4] == vtag[0]);
    wire        ht1 = v[1] && (tgt_look[15:4] == vtag[1]);
    wire        hg0 = v[0] && (tgt_inc[15:4]  == vtag[0]);
    wire        hg1 = v[1] && (tgt_inc[15:4]  == vtag[1]);
    wire [ICW-1:0] cam_ht = ic_match(tgt_look);
    wire [ICW-1:0] cam_hg = ic_match(tgt_inc);
    wire [127:0]   ic_row_tgt = ic_mem[{ic_way(cam_ht), tgt_look[6:4]}];
    wire [127:0]   ic_row_tin = ic_mem[{ic_way(cam_hg), tgt_inc[6:4]}];
    wire [7:0] b_tgt    = ht0 ? ldata[0][8 * tgt_look[3:0] +: 8] :
                          ht1 ? ldata[1][8 * tgt_look[3:0] +: 8] :
                                ic_sel(ic_row_tgt, tgt_look[3:0], |cam_ht);
    wire [7:0] b_tgtinc = hg0 ? ldata[0][8 * tgt_inc[3:0]  +: 8] :
                          hg1 ? ldata[1][8 * tgt_inc[3:0]  +: 8] :
                                ic_sel(ic_row_tin, tgt_inc[3:0], |cam_hg);

    // The fourth candidate's serve: exp-independent, so the branch's dummy
    // cycles (and a page cross's second dummy) never disturb it.
    // NOT ON THE IIgs (docs/GS.md rung 6).  Its select is a live 16-bit
    // compare on the PC, and on the 65816 the byte it selects feeds the
    // slot-0 lookahead - the opcode's decode-ROM read, its condition and
    // the block RAM's address, the core's binding loop - so the I byte
    // must be register-direct there: `lhit_q ? i_byte_q : accel_din`.  A
    // 65816's taken branch spends its add cycle as an internal cycle on
    // the dispatcher anyway, so the zero-stall target serve bought it
    // nothing; the target fetch re-aims the predictor and serves a beat
    // later, as any jump does.
    wire tgt_here  = !GS && tgt_v && cyc_is_i && cpu_rw && (pc_addr == tgt_q);
    wire tgt_serve = tgt_here && tgt_lhit_q && !(lhit_q && (exp_q == pc_addr));

    // ---- the INTC8ROM latch, registered once -------------------------------
    // Pages a retire must never eat while the latch could still move: page
    // $C3 until the latch is set (the first access rides the sequencer and
    // sets it at op_present; map_changed pulses the clock after, before any
    // $C3 line can even be wanted), and the $CFFx line always ($CFFF is the
    // clear itself).  A clear pulses map_changed too, which kills every
    // line and the CAM; kill_now below also refuses a $C3 serve on the
    // clock the registered latch reads clear, so the RTS that follows the
    // 80-column firmware's own `LDX $CFFF` ($C372) rides the sequencer and
    // re-sets the latch whatever the driver's data/cyc_en spacing.  ONE
    // register stage here (a second would still be safe - a want relaunched
    // by f_restart re-evaluates at F_IDLE two clocks after the pulse - a
    // third would not).
    logic intc8rom_q;
    always_ff @(posedge clk) intc8rom_q <= rst ? 1'b0 : intc8rom;
    // THE I/O WINDOW EXISTS IN FOUR BANKS ON A IIgs - $00/$01 and $E0/$E1 -
    // and nowhere else: in bank $FF $C3xx is the ROM's own code and $CFFF
    // is a byte like any other (rtl/apple_mmu.sv, the bank classes).  So
    // every exclusion below is qualified by the program bank being one of
    // the pair, registered: it lags a bank change by one clock, and that
    // clock is under the bank hold (cpu65816's bank_wr).  A IIe is always
    // in the window.
    logic pair_q;
    always_ff @(posedge clk)
        pair_q <= !GS || (pc_bank[7:1] == 7'd0) || (pc_bank[7:1] == 7'h70);
    function automatic logic excl(input [11:0] tag);
        excl = pair_q && ((tag[11:4] == 8'hC3 && !intc8rom_q) || (tag == 12'hCFF));
    endfunction

    // A taken branch to a non-resident line asks the engine early (the
    // want travels while the branch's own dummies run); the engine filters
    // residency and class exactly as it does the scanner's wants.
    logic        ew_v;
    logic [11:0] ew_tag;
    wire         ew_taken;            // the engine took (or dropped) it
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || !turbo_en) begin
            ew_v <= 1'b0; ew_tag <= 12'd0;
        end else begin
            if (ew_taken) ew_v <= 1'b0;
            if (resolving && res_taken &&
                !(pair_q && res_tgt[15:8] == 8'hC0) && !excl(res_tgt[15:4])) begin
                ew_v   <= 1'b1;
                ew_tag <= res_tgt[15:4];
            end
        end
    end

    // A program-stream fetch the prediction missed re-aims the predictor;
    // one the sequencer served slow still steps it, so the fetch AFTER a
    // miss is back at cadence.
    wire step    = retire || (accel_cyc_en && cyc_is_i && cpu_rw && (pc_addr == exp_q));
    wire recover = turbo_en && cyc_is_i && cpu_rw && !step && (pc_addr != exp_q);

    always_ff @(posedge clk) begin
        if (rst || cpu_rst) begin
            exp_q <= 16'd0; lhit_q <= 1'b0; i_byte_q <= 8'd0;
            bk_q <= BK_NONE; bk_hi <= 1'b0; br_op <= 8'd0; lo_q <= 8'd0;
            tgt_v <= 1'b0; tgt_q <= 16'd0;
            tgt_lhit_q <= 1'b0; tgt_byte_q <= 8'd0;
        end else begin
            if (retire && tgt_serve) begin
                // The branch lands: continue at the cadence of one from
                // target+1, exactly as a step continues from exp+1.
                exp_q    <= tgt_inc;
                lhit_q   <= (hg0 || hg1 || |cam_hg);
                i_byte_q <= b_tgtinc;
            end else begin
                exp_q    <= step ? exp_inc : recover ? pc_addr : exp_q;
                lhit_q   <= step    ? (hi0 || hi1 || |cam_hi) :
                            recover ? (hc0 || hc1 || |cam_mpc) :
                                      (hh0 || hh1 || |cam_hh);
                i_byte_q <= step ? b_inc : recover ? b_cur : b_hold;
            end
            // The valid pairs the registered byte with the address it was
            // looked up at: on a resolve it demands the speculation held
            // (the served operand WAS i_byte_q - lhit_q, and not the
            // target path's byte).
            tgt_lhit_q <= (resolving ? (res_taken && lhit_q && !tgt_serve)
                                     : tgt_v) && (ht0 || ht1 || |cam_ht);
            tgt_byte_q <= b_tgt;
            if (i_serve) begin
                if (cpu_sync) begin
                    bk_q  <= (turbo_en && op_is_branch) ? BK_BR :
                             (turbo_en && op_is_abs)    ? BK_ABS : BK_NONE;
                    bk_hi <= 1'b0;
                    br_op <= i_din;
                    tgt_v <= 1'b0;         // a new instruction: the old target is spent
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

    // The snoop, combinational: an image write's folded identity against a
    // held line - and the same-clock race with a serve is a late cancel.
    // Two sources, each its own compare set (a mux in front of the
    // compares would sit in kill_now's cone; an OR behind them is free):
    // the classified stream's write, and the data front's posted write.
    // Twenty bits flat: the page, and the line within it.  RETAINED lines
    // are compared, not just valid ones - a line out of service must not
    // revive holding a byte a write has since replaced, and the instruction
    // front has no splice, so the write KILLS it outright.
    wire        snp = cl_valid && !cl_rw && cl_wr_image;
    wire snp_kill0 = (snp && r[0] &&
                      (t_ppn[0] == cl_ppn) && (vtag[0][3:0] == cl_off[7:4])) ||
                     (ws_valid && r[0] &&
                      (t_ppn[0] == ws_ppn) && (vtag[0][3:0] == ws_off8[7:4]));
    wire snp_kill1 = (snp && r[1] &&
                      (t_ppn[1] == cl_ppn) && (vtag[1][3:0] == cl_off[7:4])) ||
                     (ws_valid && r[1] &&
                      (t_ppn[1] == ws_ppn) && (vtag[1][3:0] == ws_off8[7:4]));

    // ...and against the retained set: the write's set is its line-in-page
    // bits, and every retained way there whose page and addr[7] match dies -
    // a retained line is a held line for coherence purposes, however long
    // it sits.  THE KILL LANDS A CLOCK LATER, from a registered compare:
    // live, the select of a 16-bit page by the write's set and its compare
    // ran into kill_now, the retire and the core's every enable (16 levels
    // at 0.005 ns in the 16x4 build).  What stays live is a 3-bit SET MATCH
    // that refuses a retained-set serve on the write's clock, and its
    // registered copy refuses the next one, by which time the kill has
    // landed: a write anywhere in the same set as the fetch costs one
    // clock, and nothing ever serves a dead line.
    wire [ICW-1:0] ic_kill_cl_w, ic_kill_ws_w;
    genvar gk;
    generate for (gk = 0; gk < ICW; gk = gk + 1) begin : g_icsnp
        assign ic_kill_cl_w[gk] = snp && ic_r[gk][cl_off[6:4]] &&
                                  (ic_ppn[gk][cl_off[6:4]] == cl_ppn) &&
                                  (ic_a7[gk][cl_off[6:4]] == cl_off[7]);
        assign ic_kill_ws_w[gk] = ws_valid && ic_r[gk][ws_off8[6:4]] &&
                                  (ic_ppn[gk][ws_off8[6:4]] == ws_ppn) &&
                                  (ic_a7[gk][ws_off8[6:4]] == ws_off8[7]);
    end endgenerate
    logic [ICW-1:0] kq_cl_v, kq_ws_v;
    logic [ISW-1:0] kq_cl_set, kq_ws_set;
    logic           cs_cl_q, cs_ws_q;   // the set matched the fetch's on the write's clock
    always_ff @(posedge clk) begin
        kq_cl_v   <= rst ? '0 : ic_kill_cl_w;
        kq_ws_v   <= rst ? '0 : ic_kill_ws_w;
        kq_cl_set <= cl_off[6:4];
        kq_ws_set <= ws_off8[6:4];
        cs_cl_q   <= !rst && snp      && (cl_off[6:4]  == pc_addr[6:4]);
        cs_ws_q   <= !rst && ws_valid && (ws_off8[6:4] == pc_addr[6:4]);
    end
    wire ic_cancel = (snp      && (cl_off[6:4]  == pc_addr[6:4])) ||
                     (ws_valid && (ws_off8[6:4] == pc_addr[6:4])) ||
                     cs_cl_q || cs_ws_q;

    // ---- the revalidation ---------------------------------------------------
    // The data front's, over the two slots and the retained set's sixty-four
    // lines (docs/MEMORY_REFACTOR.md, rung 3).  Stage 1
    // muxes the stored region's table entry every clock; stage 2, one clock
    // after map_changed, recomputes VALID from the line's stored identity.
    // Nothing here reaches a serve cone: both stages are register-rooted and
    // land in the valid bits, which the serve already reads.
    // {sh, cls[1:0], wr, bsel[1:0], fold, fs} - the shadow bit is the IIgs's
    // and sits at the TOP, so every field this front reads is where it was.
    localparam integer RT_W = 8;
    localparam integer NREG = 13;
    localparam [1:0] BS_AUX = 2'd1, BS_ROM = 2'd2;
    localparam [1:0] CLS_RAM = 2'd1, CLS_LC = 2'd2;
    wire [RT_W-1:0] rt_rd [0:15];
    genvar gr;
    generate for (gr = 0; gr < 16; gr = gr + 1) begin : g_rt
        if (gr < NREG) begin : g_real
            assign rt_rd[gr] = rt_rd_flat[gr*RT_W +: RT_W];
        end else begin : g_none
            assign rt_rd[gr] = '0;    // a region no line can carry
        end
    end endgenerate

    logic reval_q;
    always_ff @(posedge clk) reval_q <= map_changed && !rst;

    // Stage 1: the entry each line's region names, registered.
    logic [RT_W-1:0] rv1_t [0:1];
    logic [RT_W-1:0] rv1_ic [0:ICW-1][0:ICS-1];
    integer rr, rs;
    always_ff @(posedge clk) begin
        for (rr = 0; rr < 2; rr = rr + 1)    rv1_t[rr] <= rt_rd[t_reg[rr]];
        for (rr = 0; rr < ICW; rr = rr + 1)
            for (rs = 0; rs < ICS; rs = rs + 1) rv1_ic[rr][rs] <= rt_rd[ic_reg[rr][rs]];
    end

    // Stage 2, combinational into the always_ff below: does the entry still
    // name this line?  A ROM line wants ROM class, a RAM/LC line wants
    // RAM or LC - and both want the bank and the fold they were filled with.
    // The ROM is bank $FF now, so a line's own bank says which class the
    // table must still be naming: no separate ROM flag per line.
    // ON THE IIgs the same rule holds inside the four pair banks, where the
    // IIe's switches apply - with the side the table names OR'd with the
    // bank's own low bit, since an odd bank named directly IS the auxiliary
    // memory (rtl/apple_mmu.sv xlate) - and NOTHING outside them ever
    // moves: the ROM, RAM $02-$7F and the void page are themselves under
    // every map.  And a line is valid only in the bank it was fetched in:
    // the tags are sixteen bits, so this compare is what keeps bank $FE's
    // $1000 line from serving bank $FF's fetch.
    function automatic logic rv_ok(input [RT_W-1:0] e,
                                   input [7:0] bank, input fold,
                                   input [7:0] vbank);
        logic [7:0] want;
        logic       pair;
        begin
            pair = !GS || (vbank[7:1] == 7'd0) || (vbank[7:1] == 7'h70);
            if (GS) want = (e[3:2] == BS_ROM) ? 8'hFF
                                              : {vbank[7:1], vbank[0] | (e[3:2] == BS_AUX)};
            else    want = (e[3:2] == BS_AUX) ? rwb_p1 : (e[3:2] == BS_ROM) ? 8'hFF : 8'd0;
            rv_ok = (!GS || (vbank == pc_bank)) &&
                    (!pair ||
                     (e[0] &&                                   // front-servable
                      ((bank == 8'hFF) ? (e[6:5] == CLS_ROM)
                                       : (e[6:5] == CLS_RAM || e[6:5] == CLS_LC)) &&
                      (bank == want) && (fold == e[1])));
        end
    endfunction
    wire rv_t0 = r[0] && rv_ok(rv1_t[0], t_ppn[0][15:8], t_fold[0], t_vbank[0]);
    wire rv_t1 = r[1] && rv_ok(rv1_t[1], t_ppn[1][15:8], t_fold[1], t_vbank[1]);
    logic [ICS-1:0] rv_ic [0:ICW-1];
    integer rw_, rx_;
    always_comb
        for (rw_ = 0; rw_ < ICW; rw_ = rw_ + 1)
            for (rx_ = 0; rx_ < ICS; rx_ = rx_ + 1)
                rv_ic[rw_][rx_] = ic_r[rw_][rx_] &&
                                  rv_ok(rv1_ic[rw_][rx_], ic_ppn[rw_][rx_][15:8],
                                        ic_fold[rw_][rx_], ic_vbank[rw_][rx_]);

    // The scanner's seams (rtl/iscan.sv, instantiated below).
    wire        sw_v;
    wire [11:0] sw_tag;
    wire        lb_v, lb_slot;
    wire        sc_slot;
    wire [3:0]  sc_off;

    wire kill_now = map_settling || inval || !serve ||
                    // The INTC8ROM latch read clear under a $C3 fetch: the
                    // serve is refused before map_changed's kill lands.
                    (pair_q && pc_addr[15:8] == 8'hC3 && !intc8rom_q) ||
                    (hslot ? snp_kill1 : snp_kill0) ||
                    // ...and a retained copy of THIS fetch's line dying on
                    // this very clock cancels a serve sourced from it, the
                    // slots' race handled the slots' way.
                    ((|cam_mpc) && ic_cancel);

    // Retire only when a prediction matches the fetch on offer AND the
    // live tags still agree - every term register-vs-register now that the
    // compares run on pc_addr.  The resolved branch target is the second
    // way in: its own registered lookup, its own address equality.
    // ...and only into room on the stream: a retire without a word would
    // be a core cycle the host cannot place (docs/VIRTUAL_TIME.md), so with
    // the merge full the op falls to the dispatcher instead.
    wire retire = !cpu_rst && ihit && turbo_ok && !kill_now && ev_room &&
                  ((lhit_q && (exp_q == pc_addr)) || tgt_serve);
    assign turbo_commit = retire;
    assign turbo_sync   = retire && cpu_sync;
    assign cyc_en       = accel_cyc_en || retire;
    assign i_din        = tgt_serve ? tgt_byte_q :
                          lhit_q    ? i_byte_q  : accel_din;

    // ---- the wants and the fill engine --------------------------------------
    // A want is a line a slot should hold; the engine serves one at a time.
    logic        want_v   [0:1];
    // FANOUT (2026-09-18).  These three are compared against every way of the
    // retention CAM and every set within it, so one bit of them reaches a
    // hundred and more LUTs: the IIgs build's worst path was want_tag ->
    // f_ppn at -0.359, and of its 10.3 ns only 3.3 was logic - 7.0 was route,
    // across twenty rows of the die, with two nets on it at fanouts of 157 and
    // 104.  A limit lets Vivado keep a local copy for each group of readers,
    // which is the cheapest thing that shortens a route-bound path: no cycle,
    // no restructure, a few dozen flops.
    (* max_fanout = 24 *) logic [11:0] want_tag [0:1];

    localparam [2:0] F_IDLE = 3'd0, F_REQ = 3'd1, F_W1 = 3'd2, F_W2 = 3'd3,
                     F_CAM = 3'd4;    // the promote's own beat
    logic [2:0]  fst;
    logic [IWW-1:0] cam_pidx;         // the way a promote is copying (its set is f_vtag[2:0])
    logic        f_slot;
    logic        f_cam;               // a CAM-only fill: the scanner's, no slot
    (* max_fanout = 24 *) logic [11:0] f_vtag;
    // ...and the identity the filled line will carry.  The line-row request
    // speaks the physical space now: the page, and the line in it.
    (* max_fanout = 24 *) logic [15:0] f_ppn;
    logic [3:0]  f_reg;
    logic        f_fold;
    logic [7:0]  f_vbank;
    wire f_active = (fst != F_IDLE);
    assign fill_busy = f_active;

    // The engine's pick, and the classifier's answer for it.  The demand
    // preference compares against the REGISTERED miss tag, not the live
    // pc_addr: the AGU cone has no business in the fill launch's enables.
    wire        pick   = want_v[1] && !want_v[0] ? 1'b1 :
                         (want_v[1] && want_v[0] &&
                          (want_tag[1] == miss_tag_q)) ? 1'b1 : 1'b0;
    wire        want_pending = want_v[0] || want_v[1];
    // The speculative wants take the classifier only when no slot wants
    // it - the resolved branch's early want first, the scanner's last.
    wire        pick_early = !want_pending && ew_v;
    wire        pick_scan  = !want_pending && !ew_v && sw_v;
    wire [11:0] p_tag  = want_pending ? want_tag[pick] :
                         pick_early   ? ew_tag : sw_tag;
    assign p_addr = {pc_bank, p_tag, 4'h0};
    // FS replaces `p_cls != BUS`: it is the region table's own answer for
    // whether this front may serve the line, and it carries the page-$C3
    // rule (a $C3 line is servable only while INTC8ROM is set).
    wire p_bus = !p_fs;
    localparam [1:0] CLS_ROM = 2'd3;

    // The retained set against the picked tag (a hit is a promote or a
    // drop), and against the fill in flight (the allocation's dedupe).  The
    // promote lookup is VIRTUAL and reads VALID ways of the tag's set: at
    // most one way per tag is valid at a time, so it is unambiguous.  The
    // dedupe is PHYSICAL and reads RETAINED ways of the fill's set, so
    // main's and aux's copies of one vtag can both sit here; the set IS the
    // line within the page, so the page alone is the identity.
    wire [ICW-1:0] cam_m = ic_match({p_tag, 4'h0});
    wire [ICW-1:0] cam_mf;
    generate for (gk = 0; gk < ICW; gk = gk + 1) begin : g_icdup
        assign cam_mf[gk] = ic_r[gk][f_vtag[2:0]] && (ic_ppn[gk][f_vtag[2:0]] == f_ppn) &&
                            (ic_a7[gk][f_vtag[2:0]] == f_vtag[3]);
    end endgenerate
    wire cam_hit = |cam_m;
    wire cam_dup = |cam_mf;
    wire [IWW-1:0] cam_idx = ic_way(cam_m);
    // The promote's row, read by the way and set the launch latched.
    wire [127:0] ic_row_pro = ic_mem[{cam_pidx, f_vtag[2:0]}];
    // A kill in flight for the way the promote is copying (registered the
    // clock the launch stamped f_*, so the fill's own snoop missed it).
    wire ic_pro_dying = (kq_cl_v[cam_pidx] && (kq_cl_set == f_vtag[2:0])) ||
                        (kq_ws_v[cam_pidx] && (kq_ws_set == f_vtag[2:0]));

    // The snoop against the fill in flight, both sources.  A posted
    // write's grant-clock race is exactly this: a fill granted on the
    // write's retire clock read the banks before the write could reach
    // them, and the posted snoop a clock later restarts it.
    wire snp_fill = (snp && f_active &&
                     (f_ppn == cl_ppn) && (f_vtag[3:0] == cl_off[7:4])) ||
                    (ws_valid && f_active &&
                     (f_ppn == ws_ppn) && (f_vtag[3:0] == ws_off8[7:4]));
    // Everything that restarts or kills a fill.  A restart keeps the want:
    // the relaunch re-classifies and re-reads.
    wire f_restart = f_active && (map_changed || inval || snp_fill);

    assign il_req  = (fst == F_REQ);
    assign il_ppn  = f_ppn;
    assign il_line = f_vtag[3:0];      // the line within the page

    // ---- the claim ----------------------------------------------------------
    // A fetch this module holds, or is clocks from holding, is THIS module's:
    // the dispatcher stands down for it.  A hit retires as soon as turbo_ok
    // allows (every blocker in it is transient); a fill either commits or
    // declines within a handful of clocks, and a decline drops the want, the
    // claim with it, and the op rides the sequencer.  Without the hit term a
    // claimed fill's commit clock would race the by-then-settled dispatcher
    // into serving the same fetch twice.
    wire wanted_now = (want_v[0] && want_tag[0] == pc_addr[15:4]) ||
                      (want_v[1] && want_tag[1] == pc_addr[15:4]) ||
                      (f_active  && f_vtag      == pc_addr[15:4]);
    // ihit already covers a retained line - the CAM serves directly - so a
    // fetch anywhere in the ten lines claims and retires; the wants cover
    // the fills and promotes still in flight.  Bounded as ever: an entry
    // dying under the claim (a snoop) drops the claim with it and the op
    // rides the sequencer.
    assign claim = turbo_en && cyc_is_i && cpu_rw && (ihit || wanted_now);

    // ---- the misses that train, the crossings that rotate -------------------
    // The train trigger is REGISTERED: the miss's compare-and-increment cone
    // (both tags, wanted_now, the +1) fed the want registers' enables at 16
    // levels from a clock region away.  A missing fetch rides the sequencer
    // for several clocks, so acting one clock later costs nothing.
    wire i_miss = turbo_en && cyc_is_i && cpu_rw && !hit0 && !hit1 &&
                  !excl(pc_addr[15:4]);
    // The crossings too: a retire's full cone fed a dozen far-flung enables
    // (fst, the wants, cur) at 20 levels; folded into two one-bit registers
    // it feeds two D-inputs with a full cycle, and the rotation applies a
    // clock later - the new line keeps serving meanwhile, the prefetch
    // starts one clock later, and the old slot's kill lands while its line
    // is a clock further behind the program.  All harmless.
    logic cross_q0, cross_q1;
    logic        miss_q;
    logic [11:0] miss_tag_q;
    always_ff @(posedge clk) begin
        if (rst) begin miss_q <= 1'b0; miss_tag_q <= 12'd0; end
        else begin
            miss_q     <= i_miss && !wanted_now;
            miss_tag_q <= pc_addr[15:4];
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin cross_q0 <= 1'b0; cross_q1 <= 1'b0; end
        else begin
            cross_q0 <= retire && hit0;
            cross_q1 <= retire && hit1;
        end
    end
    wire cross0 = cross_q0 && (cur == 1'b1);   // entered slot 0's line
    wire cross1 = cross_q1 && (cur == 1'b0);   // entered slot 1's line

    // ---- the promote, the scan launch, the pinned pair ----------------------
    // The engine's F_IDLE decisions, named once so the loop bits' keeper and
    // the counters see exactly what the engine does.
    wire stale_own   = v[pick]  && (vtag[pick]  == p_tag);
    wire stale_other = v[!pick] && (vtag[!pick] == p_tag);
    // The promote LAUNCHES here and commits a beat later (F_CAM): the
    // first build's second violation family was this cone driving the
    // 128-bit slot register's enables live through the pick and the CAM
    // compare.  Latching first keeps the heavy enables on a registered
    // state bit; a kill racing the launch just clears cam_v, and F_CAM
    // sees it and retries down the fill path.
    // These deliberately do NOT wait for the map to settle, and the reason
    // matters because the first cut did and it cost 40-70 ps: the worst path
    // in the design became miss_tag_q -> f_poff's clock enable, which is this
    // cone.
    //
    // The hazard a settle-wide gate would cover is an INSTALL landing on
    // map_changed's own clock: stage 1 registers rt_rd[reg] from the region a
    // line held BEFORE the install, so a revalidation one clock later would
    // judge the new line by the old line's region.  But an install can never
    // land on that clock - every one of them sits inside `else case (fst)`
    // behind `if (f_restart)`, and f_restart carries map_changed.  A promote
    // landing the clock AFTER is safe either way: the revalidation either
    // drops the fresh line (a refill, nothing worse) or keeps it, and keeping
    // it is right, because it was stamped from the table that already stands.
    // A launch during the settle stamps p_ppn/p_reg from that same new table.
    wire promote_go  = (fst == F_IDLE) && !f_restart && want_pending &&
                       !stale_own && !stale_other && cam_hit;
    wire scan_go     = (fst == F_IDLE) && !f_restart && (pick_early || pick_scan);
    wire sw_taken    = (fst == F_IDLE) && !f_restart && pick_scan;
    assign ew_taken  = (fst == F_IDLE) && !f_restart && pick_early;
    // The rotation, unless the pair is a pinned loop (the scanner's bit) or
    // the other slot ALREADY HOLDS the next line - a jump back into the held
    // pair: killing it to refetch the same line was the hot loop's thrash.
    wire rot0 = cross0 && !loop_sup[0] && !(v[1] && vtag[1] == vtag[0] + 12'd1);
    wire rot1 = cross1 && !loop_sup[1] && !(v[0] && vtag[0] == vtag[1] + 12'd1);

    // The loop bits' keeper: set by the scanner, cleared the clock either
    // slot's content changes - conservative, and a live loop is re-found
    // within one iteration because the scan re-anchors every opcode fetch.
    wire slots_disturbed = ((fst == F_W2) && !f_restart && !f_cam) || (fst == F_CAM) ||
                           snp_kill0 || snp_kill1 || map_changed || inval || !serve ||
                           (miss_q && !wanted_now) || rot0 || rot1;
    always_ff @(posedge clk) begin
        if (rst || slots_disturbed) begin
            loop_sup[0] <= 1'b0; loop_sup[1] <= 1'b0;
        end else if (lb_v) begin
            loop_sup[lb_slot] <= 1'b1;
        end
    end

    // The revalidation's books, over the slots and the CAM together - off a
    // REGISTERED copy of the verdict, and counted a clock later.  Straight
    // off rv_* the chain ran rwb_p1 -> the bank mux -> an eight-bit compare
    // -> a popcount -> a 32-bit carry, fifteen levels ending in a counter,
    // and it was one of the design's longest (docs/MEMORY_REFACTOR.md).  The
    // valid bits are still written from rv_* at reval_q, untouched.
    logic [ICS-1:0]  rv_ic_q [0:ICW-1];
    logic [ICS-1:0]  ic_v_q  [0:ICW-1];
    logic            rv_t0_q, rv_t1_q, v0_q, v1_q, reval_q2;
    integer nq;
    always_ff @(posedge clk) begin
        for (nq = 0; nq < ICW; nq = nq + 1) begin
            rv_ic_q[nq] <= rv_ic[nq];
            ic_v_q[nq]  <= ic_v[nq];
        end
        rv_t0_q  <= rv_t0;
        rv_t1_q  <= rv_t1;
        v0_q     <= v[0];
        v1_q     <= v[1];
        reval_q2 <= reval_q && !rst;
    end
    logic [6:0] n_idrop, n_irev;
    integer np, ns;
    always_comb begin
        n_idrop = 7'd0; n_irev = 7'd0;
        if ( v0_q && !rv_t0_q) n_idrop = n_idrop + 7'd1;
        if (!v0_q &&  rv_t0_q) n_irev  = n_irev  + 7'd1;
        if ( v1_q && !rv_t1_q) n_idrop = n_idrop + 7'd1;
        if (!v1_q &&  rv_t1_q) n_irev  = n_irev  + 7'd1;
        for (np = 0; np < ICW; np = np + 1)
            for (ns = 0; ns < ICS; ns = ns + 1) begin
                if ( ic_v_q[np][ns] && !rv_ic_q[np][ns]) n_idrop = n_idrop + 7'd1;
                if (!ic_v_q[np][ns] &&  rv_ic_q[np][ns]) n_irev  = n_irev  + 7'd1;
            end
    end

    // The books, for the bench and the bring-up (hierarchy-visible).
    logic [31:0] cnt_promotes, cnt_cam_fills, cnt_scan_fills, cnt_loop_hold;
    logic [31:0] cnt_scan_block;      // clocks a slot want waited on a scan fill
    logic [31:0] cnt_cam_serves;      // retires whose byte came from the CAM
    logic [31:0] cnt_tgt_serves;      // zero-stall branch-target serves
    logic [31:0] cnt_slow_i;          // I-stream cycles the sequencer still serves
    // The revalidation's books, exported: ACCEL_IDROP / ACCEL_IREVIVE.
    logic [31:0] cnt_reval_drop, cnt_reval_revive;
    assign idrop_o   = cnt_reval_drop;
    assign irevive_o = cnt_reval_revive;
    // ...and the fill engine's and the retire's, for the hardware (docs/GS.md
    // rung 6): grants, declines, installs, restarts, unservable wants, and
    // the clocks a held fetch stood blocked - by turbo_ok, by the merge's
    // room, by a kill.
    logic [31:0] cnt_acks, cnt_decl, cnt_inst, cnt_restart, cnt_unserv;
    logic [31:0] cnt_blk_ok, cnt_blk_room, cnt_blk_kill;
    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_promotes <= 32'd0; cnt_cam_fills <= 32'd0;
            cnt_scan_fills <= 32'd0; cnt_loop_hold <= 32'd0;
            cnt_scan_block <= 32'd0; cnt_cam_serves <= 32'd0;
            cnt_tgt_serves <= 32'd0; cnt_slow_i <= 32'd0;
            cnt_acks <= 32'd0; cnt_decl <= 32'd0; cnt_inst <= 32'd0; cnt_restart <= 32'd0;
            cnt_unserv <= 32'd0; cnt_blk_ok <= 32'd0; cnt_blk_room <= 32'd0; cnt_blk_kill <= 32'd0;
        end else begin
            if (il_ack) cnt_acks <= cnt_acks + 32'd1;
            if ((fst == F_W1) && il_done && !il_ok) cnt_decl <= cnt_decl + 32'd1;
            if ((fst == F_W2) && !f_restart && !f_cam) cnt_inst <= cnt_inst + 32'd1;
            if (f_restart) cnt_restart <= cnt_restart + 32'd1;
            if ((fst == F_IDLE) && !f_restart && want_pending && !stale_own && !stale_other &&
                !promote_go && (p_bus || excl(p_tag)))
                cnt_unserv <= cnt_unserv + 32'd1;
            if (ihit && turbo_en && !turbo_ok) cnt_blk_ok <= cnt_blk_ok + 32'd1;
            if (ihit && turbo_ok && !ev_room) cnt_blk_room <= cnt_blk_room + 32'd1;
            if (ihit && turbo_ok && ev_room && kill_now) cnt_blk_kill <= cnt_blk_kill + 32'd1;
            if (accel_cyc_en && cyc_is_i && cpu_rw)
                cnt_slow_i <= cnt_slow_i + 32'd1;
            if (want_pending && f_active && f_cam)
                cnt_scan_block <= cnt_scan_block + 32'd1;
            if (retire && !hit0 && !hit1)
                cnt_cam_serves <= cnt_cam_serves + 32'd1;
            if (retire && tgt_serve)
                cnt_tgt_serves <= cnt_tgt_serves + 32'd1;
            if (promote_go) cnt_promotes <= cnt_promotes + 32'd1;
            if ((fst == F_W2) && !f_restart && !cam_dup) begin
                if (f_cam) cnt_scan_fills <= cnt_scan_fills + 32'd1;
                else       cnt_cam_fills  <= cnt_cam_fills  + 32'd1;
            end
            if ((cross0 && !rot0) || (cross1 && !rot1))
                cnt_loop_hold <= cnt_loop_hold + 32'd1;
        end
    end

    // ---- the branch scanner (rtl/iscan.sv) ----------------------------------
    // Reads the held lines a byte at a time through its own mux - the serve
    // path's registers are untouched - and anchors on every completed
    // program-stream opcode fetch, turbo or slow.  The scanner resolves which
    // slot holds its line from its own registered memberships, so the seam is
    // a slot bit and an offset and this mux is all that remains here.
    wire [7:0]  sc_byte = sc_slot ? ldata[1][8 * sc_off +: 8]
                                  : ldata[0][8 * sc_off +: 8];
    wire        anchor_v = !cpu_rst && cyc_is_i && cpu_rw && cpu_sync &&
                           (retire || accel_cyc_en);
    iscan u_scan (
        .clk         (clk),
        .rst         (rst),
        .enable      (turbo_en && serve && !cpu_rst),
        .intc8rom    (intc8rom_q || !pair_q),
        .anchor_v    (anchor_v),
        .anchor_addr (pc_addr),
        .rd_slot     (sc_slot),
        .rd_off      (sc_off),
        .rd_byte     (sc_byte),
        .v0          (v[0]),
        .v1          (v[1]),
        .vtag0       (vtag[0]),
        .vtag1       (vtag[1]),
        .sw_v        (sw_v),
        .sw_tag      (sw_tag),
        .sw_taken    (sw_taken),
        .lb_v        (lb_v),
        .lb_slot     (lb_slot)
    );

    integer s;
    always_ff @(posedge clk) begin
        tick_q    <= retire;
        tev_valid <= retire;
        if (retire) begin
            tev_addr <= pc_addr;
            tev_data <= i_din;
            tev_sync <= cpu_sync;
            tev_bank <= GS ? pc_bank : 8'd0;
        end

        if (rst) begin
            v[0] <= 1'b0; v[1] <= 1'b0;
            r[0] <= 1'b0; r[1] <= 1'b0;
            vtag[0] <= 12'd0; vtag[1] <= 12'd0;
            t_ppn[0] <= 16'd0; t_ppn[1] <= 16'd0;
            t_reg[0] <= 4'd0; t_reg[1] <= 4'd0;
            t_fold[0] <= 1'b0; t_fold[1] <= 1'b0;
            t_vbank[0] <= 8'd0; t_vbank[1] <= 8'd0;
            cur <= 1'b0;
            want_v[0] <= 1'b0; want_v[1] <= 1'b0;
            want_tag[0] <= 12'd0; want_tag[1] <= 12'd0;
            fst <= F_IDLE;
            f_slot <= 1'b0; f_cam <= 1'b0;
            f_vtag <= 12'd0;
            f_ppn <= 16'd0; f_reg <= 4'd0; f_fold <= 1'b0; f_vbank <= 8'd0;
            tick_q <= 1'b0; tev_valid <= 1'b0; tev_bank <= 8'd0;
            for (s = 0; s < ICW; s = s + 1) begin ic_v[s] <= '0; ic_r[s] <= '0; ic_a7[s] <= '0; end
            for (s = 0; s < ICS; s = s + 1) ic_rrp[s] <= '0;
            cnt_reval_drop <= 32'd0; cnt_reval_revive <= 32'd0;
        end else begin
            // ---- the engine ------------------------------------------------
            if (f_restart) begin
                fst <= F_IDLE;
                // A slot fill retries through its want (the relaunch
                // re-classifies and re-reads); a ROM reload drops it; a
                // CAM-only fill is speculation - dropped, the scanner asks
                // again if it still matters.
                if (!f_cam) begin
                    want_v[f_slot]   <= 1'b1;                      // retry
                    want_tag[f_slot] <= f_vtag;
                end
            end else case (fst)
                F_IDLE: if (want_pending) begin
                    // A want its slot already holds is stale bookkeeping.
                    if (stale_own || stale_other) begin
                        want_v[pick] <= 1'b0;
                    end else if (promote_go) begin
                        // THE PROMOTE, latched: the entry's index and
                        // identity into the engine's registers, the copy
                        // itself next beat (F_CAM).  No page-cache round
                        // trip and no re-classification (the CAM's note
                        // above says why the captured identity stands);
                        // setting f_* here also puts the promote under the
                        // fill's own snoop (f_restart) for its one beat.
                        f_slot   <= pick;
                        f_cam    <= 1'b0;
                        f_vtag   <= p_tag;
                        f_ppn    <= ic_ppn[cam_idx][p_tag[2:0]];
                        f_reg    <= ic_reg[cam_idx][p_tag[2:0]];
                        f_fold   <= ic_fold[cam_idx][p_tag[2:0]];
                        f_vbank  <= ic_vbank[cam_idx][p_tag[2:0]];
                        cam_pidx <= cam_idx;
                        want_v[pick] <= 1'b0;
                        fst <= F_CAM;
                    end else if (p_bus || excl(p_tag)) begin
                        want_v[pick] <= 1'b0;      // never servable: leave empty
                    end else begin
                        f_slot <= pick;
                        f_cam  <= 1'b0;
                        f_vtag <= p_tag;
                        f_ppn  <= p_ppn;
                        f_reg  <= p_reg;
                        f_fold <= p_fold;
                        f_vbank <= GS ? pc_bank : 8'd0;
                        want_v[pick] <= 1'b0;
                        fst <= F_REQ;
                    end
                end else if (scan_go) begin
                    // The speculative wants - the resolved branch's early
                    // want, then the scanner's: lowest priority, and only
                    // ever a CAM fill.  A target already held, already
                    // retained or never servable is dropped; the want
                    // retires either way.
                    if (!stale_own && !stale_other && !cam_hit &&
                        !p_bus && !excl(p_tag)) begin
                        f_cam  <= 1'b1;
                        f_vtag <= p_tag;
                        f_ppn  <= p_ppn;
                        f_reg  <= p_reg;
                        f_fold <= p_fold;
                        f_vbank <= GS ? pc_bank : 8'd0;
                        fst    <= F_REQ;
                    end
                end
                F_CAM: begin
                    // The copy - unless the entry died under the launch (a
                    // same-clock kill cleared cam_v): then retry through
                    // the want, which now misses the CAM and fills.
                    if (ic_v[cam_pidx][f_vtag[2:0]] && !ic_pro_dying) begin
                        ldata[f_slot]  <= ic_row_pro;
                        v[f_slot]      <= 1'b1;
                        vtag[f_slot]   <= f_vtag;
                        r[f_slot]      <= 1'b1;
                        t_ppn[f_slot]  <= f_ppn;
                        t_reg[f_slot]  <= f_reg;
                        t_fold[f_slot] <= f_fold;
                        t_vbank[f_slot] <= f_vbank;
                    end else begin
                        want_v[f_slot]   <= 1'b1;
                        want_tag[f_slot] <= f_vtag;
                    end
                    fst <= F_IDLE;
                end
                F_REQ: if (il_ack) fst <= F_W1;
                // The cache answers three clocks after the grant, residency
                // and row together (rtl/page_cache.sv): a physically indexed
                // directory cannot say whether it holds a page until its own
                // tag compare has run.  A decline drops the want and the op
                // rides the sequencer, whose miss fills the page.
                F_W1: if (il_done) fst <= il_ok ? F_W2 : F_IDLE;
                F_W2: begin
                    if (!f_cam) begin
                        ldata[f_slot]  <= il_row;
                        v[f_slot]      <= 1'b1;
                        r[f_slot]      <= 1'b1;
                        vtag[f_slot]   <= f_vtag;
                        t_ppn[f_slot]  <= f_ppn;
                        t_reg[f_slot]  <= f_reg;
                        t_fold[f_slot] <= f_fold;
                        t_vbank[f_slot] <= f_vbank;
                    end
                    // EVERY committed line is retained: the set records it
                    // in its round-robin victim way, deduplicated - a
                    // retained way with this physical identity keeps its
                    // claim, its bytes identical by the snoop.
                    if (!cam_dup) begin
                        ic_mem[{ic_rrp[f_vtag[2:0]], f_vtag[2:0]}] <= il_row;
                        ic_v[ic_rrp[f_vtag[2:0]]][f_vtag[2:0]]     <= 1'b1;
                        ic_r[ic_rrp[f_vtag[2:0]]][f_vtag[2:0]]     <= 1'b1;
                        ic_a7[ic_rrp[f_vtag[2:0]]][f_vtag[2:0]]    <= f_vtag[3];
                        ic_tag[ic_rrp[f_vtag[2:0]]][f_vtag[2:0]]   <= f_vtag[11:3];
                        ic_ppn[ic_rrp[f_vtag[2:0]]][f_vtag[2:0]]   <= f_ppn;
                        ic_reg[ic_rrp[f_vtag[2:0]]][f_vtag[2:0]]   <= f_reg;
                        ic_fold[ic_rrp[f_vtag[2:0]]][f_vtag[2:0]]  <= f_fold;
                        ic_vbank[ic_rrp[f_vtag[2:0]]][f_vtag[2:0]] <= f_vbank;
                        ic_rrp[f_vtag[2:0]] <= ic_rrp[f_vtag[2:0]] + IWW'(1);
                    end
                    fst <= F_IDLE;
                end
                default: fst <= F_IDLE;
            endcase

            // ---- the train and the rotation --------------------------------
            // A slot the train or the rotation re-aims is about to hold a
            // different line: its retention goes with its valid bit.  (The
            // CAM still holds the bytes, so this costs nothing but a
            // promote.)
            if (miss_q && !wanted_now) begin
                want_v[cur]   <= 1'b1;
                want_tag[cur] <= miss_tag_q;
                v[cur]        <= 1'b0;
                r[cur]        <= 1'b0;
                if (!(v[!cur] && vtag[!cur] == miss_tag_q + 12'd1) &&
                    !(f_active && f_vtag == miss_tag_q + 12'd1)) begin
                    want_v[!cur]   <= 1'b1;
                    want_tag[!cur] <= miss_tag_q + 12'd1;
                    v[!cur]        <= 1'b0;
                    r[!cur]        <= 1'b0;
                end
            end
            if (cross0) begin
                cur <= 1'b0;
                if (rot0) begin
                    v[1] <= 1'b0;
                    r[1] <= 1'b0;
                    want_v[1]   <= 1'b1;
                    want_tag[1] <= vtag[0] + 12'd1;
                    if (f_active && !f_cam && f_slot == 1'b1) fst <= F_IDLE;   // abort the stale fill
                end
            end
            if (cross1) begin
                cur <= 1'b1;
                if (rot1) begin
                    v[0] <= 1'b0;
                    r[0] <= 1'b0;
                    want_v[0]   <= 1'b1;
                    want_tag[0] <= vtag[1] + 12'd1;
                    if (f_active && !f_cam && f_slot == 1'b0) fst <= F_IDLE;
                end
            end

            // ---- the kills, last: they beat every commit above -------------
            // A write kills a held line outright - valid AND retained.  The
            // instruction front has no splice, so a line a write touched can
            // never be revived: its bytes are stale for good.
            if (snp_kill0) begin v[0] <= 1'b0; r[0] <= 1'b0; end
            if (snp_kill1) begin v[1] <= 1'b0; r[1] <= 1'b0; end
            // The registered kills land here, a clock behind the write.
            for (s = 0; s < ICW; s = s + 1) begin
                if (kq_cl_v[s]) begin ic_v[s][kq_cl_set] <= 1'b0; ic_r[s][kq_cl_set] <= 1'b0; end
                if (kq_ws_v[s]) begin ic_v[s][kq_ws_set] <= 1'b0; ic_r[s][kq_ws_set] <= 1'b0; end
            end
            // The wants survive a map change (the retry re-classifies); an
            // emptied front with serving off wants nothing.  The image going
            // away, or serving stopping, takes the lines outright - valid
            // AND retained: their bytes are no longer anybody's truth.
            if (inval || !serve) begin
                v[0] <= 1'b0; v[1] <= 1'b0;
                r[0] <= 1'b0; r[1] <= 1'b0;
                for (s = 0; s < ICW; s = s + 1) begin
                    ic_v[s] <= '0; ic_r[s] <= '0;
                end
            end
            // A MAP CHANGE takes nothing.  One clock later every line's
            // valid bit is the new map's answer for the identity that line
            // was filled with, and a line whose region did not move never
            // stopped being servable (docs/MEMORY_REFACTOR.md, rung 3).
            // Nothing else writes a valid bit on this clock: every install
            // sits behind `if (f_restart)`, and f_restart carries
            // map_changed, so none can land here.
            if (reval_q) begin
                v[0] <= rv_t0;
                v[1] <= rv_t1;
                for (s = 0; s < ICW; s = s + 1) ic_v[s] <= rv_ic[s];
            end
            if (reval_q2) begin
                cnt_reval_drop   <= cnt_reval_drop   + 32'(n_idrop);
                cnt_reval_revive <= cnt_reval_revive + 32'(n_irev);
            end
            if (!serve) begin
                want_v[0] <= 1'b0; want_v[1] <= 1'b0;
                fst <= F_IDLE;
            end
        end
    end

    // The debug pair's window.
    logic [7:0] cam_v_pk;             // valid lines in the retained set, 0-64
    always_comb begin
        cam_v_pk = 8'd0;
        for (int q = 0; q < ICW; q = q + 1)
            for (int q2 = 0; q2 < ICS; q2 = q2 + 1)
                cam_v_pk = cam_v_pk + {7'd0, ic_v[q][q2]};
        case (dbg_sel)
            4'd0:  dbg_val = cnt_slow_i;
            4'd1:  dbg_val = cnt_cam_fills;
            4'd2:  dbg_val = cnt_scan_fills;
            4'd3:  dbg_val = cnt_promotes;
            4'd4:  dbg_val = cnt_cam_serves;
            4'd5:  dbg_val = cnt_tgt_serves;
            4'd6:  dbg_val = cnt_acks;
            4'd7:  dbg_val = cnt_decl;
            4'd8:  dbg_val = cnt_inst;
            4'd9:  dbg_val = cnt_restart;
            4'd10: dbg_val = cnt_blk_ok;
            4'd11: dbg_val = cnt_blk_room;
            4'd12: dbg_val = cnt_blk_kill;
            4'd13: dbg_val = cnt_unserv;
            4'd14: dbg_val = {v[1], v[0], r[1], r[0], fst, want_v[1], want_v[0],
                              turbo_en, serve, inval, pair_q, intc8rom_q, lhit_q, 1'b0,
                              cam_v_pk, cur, f_cam, f_slot, 5'd0};
            default: dbg_val = cnt_reval_drop;
        endcase
    end

endmodule
