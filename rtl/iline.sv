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
//   * page $C3 and the $CFF0 line: an access there moves the IIe's INTC8ROM
//     latch, which the MMU shadow learns from the unified op stream - a
//     turbo retire never reaches that stream, so these ride the sequencer
//     (rtl/apple_mmu.sv, "INTC8ROM");
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
module iline (
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
    input  wire        cpu_rw,
    input  wire        cpu_sync,
    input  wire        cyc_is_i,
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
    input  wire         ev_room,      // the merge can take a word this clock

    // The MMU: the prefetch's classification, and the map's edge.
    output wire [15:0] p_addr,
    input  wire [1:0]  p_cls,         // CLS_* as apple_mmu has them
    input  wire        p_aux,
    input  wire [15:0] p_off,
    input  wire [7:0]  rw_bank,
    input  wire        map_changed,

    // The page cache's line port (rtl/page_cache.sv).
    output wire         il_req,
    output wire         il_aux,
    output wire [7:0]   il_bank,
    output wire [11:0]  il_line,
    input  wire         il_ack,
    input  wire         il_ok,
    input  wire [127:0] il_row,

    // The ROM's line port (rtl/apple_rom.sv).
    output wire        r2_en,
    output wire [11:0] r2_addr,
    input  wire [31:0] r2_data,
    input  wire        r2_busy,       // load traffic: ROM lines and fills die

    // The write snoop: the MMU's classified op (P1).
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire        cl_aux,
    input  wire [7:0]  cl_bank,
    input  wire [15:0] cl_off,

    // The flushes.
    input  wire        serve,         // MEM_CTRL's: off empties the front
    input  wire        inval
);

    localparam [1:0] CLS_BUS = 2'd0;

    // ---- the two lines ------------------------------------------------------
    logic         v      [0:1];
    logic [11:0]  vtag   [0:1];       // pc_addr[15:4] of the line
    logic         t_rom  [0:1];       // served from the ROM, not the banks
    logic         t_aux  [0:1];
    logic [7:0]   t_bank [0:1];
    logic [11:0]  t_poff [0:1];       // folded off[15:4], the snoop's identity
    logic [127:0] ldata  [0:1];
    logic         cur;                // the slot execution is in

    // ---- the retention CAM --------------------------------------------------
    // The last CAMN distinct lines the engine fetched, and the scanner's
    // branch-target prefetches: tags and identities in flip-flops (the snoop
    // and the want compare read them all at once), the bytes in distributed
    // RAM - one write port, one asynchronous read, NO block RAM.  A want
    // whose line the CAM holds is PROMOTED: one clock, no page-cache round
    // trip - and no re-classification, because the CAM is flash-cleared on
    // any map change, so a surviving entry's captured identity is still the
    // map's truth for its tag.  Entries die exactly as slot lines do: the
    // write snoop by identity, ROM load traffic for ROM entries, a map
    // change, an invalidate, serving off.  A page engine eviction does not
    // invalidate, for the slots' reason: the bytes stay the bank's truth.
    localparam integer CAMN = 8;
    logic               cam_v    [0:CAMN-1];
    logic [11:0]        cam_vtag [0:CAMN-1];
    logic               cam_rom  [0:CAMN-1];
    logic               cam_aux  [0:CAMN-1];
    logic [7:0]         cam_bank [0:CAMN-1];
    logic [11:0]        cam_poff [0:CAMN-1];
    logic [127:0]       cam_data [0:CAMN-1];   // the LUTRAM
    logic [2:0]         cam_wp;                // round-robin allocation
    logic [127:0]       f_cbuf;                // a CAM-only ROM fill's staging

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
    wire ihit = cyc_is_i && cpu_rw && (hit0 || hit1);
    wire hslot = !hit0;               // slot 0 wins a (never-built) double hit

    logic [15:0] exp_q;              // the predicted next program-stream fetch
    logic        lhit_q;             // the lookup found a held line...
    logic [7:0]  i_byte_q;           // ...and this is its byte

    // The three candidates, register-sourced, in parallel; slot 0 wins.
    wire [15:0] exp_inc = exp_q + 16'd1;
    wire        hi0 = v[0] && (exp_inc[15:4]  == vtag[0]);
    wire        hi1 = v[1] && (exp_inc[15:4]  == vtag[1]);
    wire        hc0 = v[0] && (pc_addr[15:4] == vtag[0]);
    wire        hc1 = v[1] && (pc_addr[15:4] == vtag[1]);
    wire        hh0 = v[0] && (exp_q[15:4]    == vtag[0]);
    wire        hh1 = v[1] && (exp_q[15:4]    == vtag[1]);
    wire [7:0]  b_inc  = hi0 ? ldata[0][8 * exp_inc[3:0]  +: 8] : ldata[1][8 * exp_inc[3:0]  +: 8];
    wire [7:0]  b_cur  = hc0 ? ldata[0][8 * pc_addr[3:0] +: 8] : ldata[1][8 * pc_addr[3:0] +: 8];
    wire [7:0]  b_hold = hh0 ? ldata[0][8 * exp_q[3:0]    +: 8] : ldata[1][8 * exp_q[3:0]    +: 8];

    // A program-stream fetch the prediction missed re-aims the predictor;
    // one the sequencer served slow still steps it, so the fetch AFTER a
    // miss is back at cadence.
    wire step    = retire || (accel_cyc_en && cyc_is_i && cpu_rw && (pc_addr == exp_q));
    wire recover = turbo_en && cyc_is_i && cpu_rw && !step && (pc_addr != exp_q);

    always_ff @(posedge clk) begin
        if (rst || cpu_rst) begin
            exp_q <= 16'd0; lhit_q <= 1'b0; i_byte_q <= 8'd0;
        end else begin
            exp_q    <= step ? exp_inc : recover ? pc_addr : exp_q;
            lhit_q   <= step ? (hi0 || hi1) : recover ? (hc0 || hc1) : (hh0 || hh1);
            i_byte_q <= step ? b_inc : recover ? b_cur : b_hold;
        end
    end

    // The snoop, combinational: an image write's folded identity against a
    // held line - and the same-clock race with a serve is a late cancel.
    wire        snp = cl_valid && !cl_rw && cl_wr_image;
    wire snp_kill0 = snp && v[0] && !t_rom[0] && (t_aux[0] == cl_aux) &&
                     (!cl_aux || t_bank[0] == cl_bank) && (t_poff[0] == cl_off[15:4]);
    wire snp_kill1 = snp && v[1] && !t_rom[1] && (t_aux[1] == cl_aux) &&
                     (!cl_aux || t_bank[1] == cl_bank) && (t_poff[1] == cl_off[15:4]);

    // ...and against every CAM entry, the same terms: a retained line is a
    // held line for coherence purposes, however long it sits.
    wire [CAMN-1:0] cam_snp_kill;
    genvar gk;
    generate for (gk = 0; gk < CAMN; gk = gk + 1) begin : g_camsnp
        assign cam_snp_kill[gk] = snp && cam_v[gk] && !cam_rom[gk] &&
                                  (cam_aux[gk] == cl_aux) &&
                                  (!cl_aux || cam_bank[gk] == cl_bank) &&
                                  (cam_poff[gk] == cl_off[15:4]);
    end endgenerate

    // The scanner's seams (rtl/iscan.sv, instantiated below).
    wire        sw_v;
    wire [11:0] sw_tag;
    wire        lb_v, lb_slot;
    wire [15:0] sc_addr;

    wire kill_now = map_changed || inval || !serve ||
                    (hslot ? snp_kill1 : snp_kill0) ||
                    ((hslot ? t_rom[1] : t_rom[0]) && r2_busy);

    // Retire only when the prediction matches the fetch on offer AND the
    // live tags still agree - every term register-vs-register now that the
    // compares run on pc_addr.
    wire retire = !cpu_rst && ihit && lhit_q && (exp_q == pc_addr) &&
                  turbo_ok && !kill_now;
    assign turbo_commit = retire;
    assign turbo_sync   = retire && cpu_sync;
    assign cyc_en       = accel_cyc_en || retire;
    assign i_din        = lhit_q ? i_byte_q : accel_din;

    // ---- the wants and the fill engine --------------------------------------
    // A want is a line a slot should hold; the engine serves one at a time.
    logic        want_v   [0:1];
    logic [11:0] want_tag [0:1];

    localparam [2:0] F_IDLE = 3'd0, F_REQ = 3'd1, F_W1 = 3'd2, F_W2 = 3'd3,
                     F_R0 = 3'd4, F_R1 = 3'd5, F_R2 = 3'd6, F_R3 = 3'd7;
    logic [2:0]  fst;
    logic        f_slot, f_rom, f_aux;
    logic        f_cam;               // a CAM-only fill: the scanner's, no slot
    logic [7:0]  f_bank;
    logic [11:0] f_vtag, f_poff;
    logic [127:0] f_buf;
    wire f_active = (fst != F_IDLE);

    // Pages a retire must never eat (the INTC8ROM latch's food).
    function automatic logic excl(input [11:0] tag);
        excl = (tag[11:4] == 8'hC3) || (tag == 12'hCFF);
    endfunction

    // The engine's pick, and the classifier's answer for it.  The demand
    // preference compares against the REGISTERED miss tag, not the live
    // pc_addr: the AGU cone has no business in the fill launch's enables.
    wire        pick   = want_v[1] && !want_v[0] ? 1'b1 :
                         (want_v[1] && want_v[0] &&
                          (want_tag[1] == miss_tag_q)) ? 1'b1 : 1'b0;
    wire        want_pending = want_v[0] || want_v[1];
    // The scanner's want takes the classifier only when no slot wants it -
    // lowest priority, always.
    wire        pick_scan = !want_pending && sw_v;
    wire [11:0] p_tag  = pick_scan ? sw_tag : want_tag[pick];
    assign p_addr = {p_tag, 4'h0};
    wire p_bus = (p_cls == CLS_BUS);
    localparam [1:0] CLS_ROM = 2'd3;
    wire p_rom = (p_cls == CLS_ROM);

    // The CAM against the picked tag (a hit is a promote or a drop), and
    // against the fill in flight (the allocation's dedupe).
    wire [CAMN-1:0] cam_m, cam_mf, cam_mpc;
    generate for (gk = 0; gk < CAMN; gk = gk + 1) begin : g_cammatch
        assign cam_m[gk]   = cam_v[gk] && (cam_vtag[gk] == p_tag);
        assign cam_mf[gk]  = cam_v[gk] && (cam_vtag[gk] == f_vtag);
        assign cam_mpc[gk] = cam_v[gk] && (cam_vtag[gk] == pc_addr[15:4]);
    end endgenerate
    wire cam_hit    = |cam_m;
    wire cam_dup    = |cam_mf;
    wire cam_pc_hit = |cam_mpc;       // the fetch's line is retained: claim it
    logic [2:0] cam_idx;
    always_comb begin
        cam_idx = 3'd0;
        for (int k = CAMN - 1; k >= 0; k = k - 1)
            if (cam_m[k]) cam_idx = 3'(k);
    end
    // A snoop or ROM traffic hitting the entry the very clock it would
    // promote: abort, the entry dies, the retry takes the fill path.
    wire cam_prom_abort = cam_snp_kill[cam_idx] || (cam_rom[cam_idx] && r2_busy);

    // The snoop against the fill in flight.
    wire snp_fill = snp && f_active && !f_rom && (f_aux == cl_aux) &&
                    (!cl_aux || f_bank == cl_bank) && (f_poff == cl_off[15:4]);
    // Everything that restarts or kills a fill.  A restart keeps the want:
    // the relaunch re-classifies and re-reads.
    wire f_restart = f_active && (map_changed || inval || snp_fill ||
                                  (f_rom && r2_busy));

    assign il_req  = (fst == F_REQ);
    assign il_aux  = f_aux;
    assign il_bank = f_bank;
    assign il_line = f_poff;
    assign r2_en   = (fst == F_R0) || (fst == F_R1) || (fst == F_R2) || (fst == F_R3);
    assign r2_addr = {f_vtag[9:0], fst[1:0]};   // F_R0..3 encode the beat in [1:0]

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
    // A retained line claims too: the miss trains, the want promotes, the
    // serve is a handful of stall clocks instead of a sequencer ride.  Still
    // bounded: if the entry dies under the claim (a snoop), the claim falls
    // with it and the op rides the sequencer as before; a promote-then-
    // decline chain always ends in a commit or a dropped want.
    assign claim = turbo_en && cyc_is_i && cpu_rw &&
                   (ihit || wanted_now || cam_pc_hit);

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
    wire promote_go  = (fst == F_IDLE) && !f_restart && want_pending &&
                       !stale_own && !stale_other && cam_hit && !cam_prom_abort;
    wire scan_go     = (fst == F_IDLE) && !f_restart && pick_scan;
    wire sw_taken    = scan_go;
    // The rotation, unless the pair is a pinned loop (the scanner's bit) or
    // the other slot ALREADY HOLDS the next line - a jump back into the held
    // pair: killing it to refetch the same line was the hot loop's thrash.
    wire rot0 = cross0 && !loop_sup[0] && !(v[1] && vtag[1] == vtag[0] + 12'd1);
    wire rot1 = cross1 && !loop_sup[1] && !(v[0] && vtag[0] == vtag[1] + 12'd1);

    // The loop bits' keeper: set by the scanner, cleared the clock either
    // slot's content changes - conservative, and a live loop is re-found
    // within one iteration because the scan re-anchors every opcode fetch.
    wire slots_disturbed = ((fst == F_W2) && !f_restart && !f_cam) || promote_go ||
                           snp_kill0 || snp_kill1 || map_changed || inval || !serve ||
                           (r2_busy && (t_rom[0] || t_rom[1])) ||
                           (miss_q && !wanted_now) || rot0 || rot1;
    always_ff @(posedge clk) begin
        if (rst || slots_disturbed) begin
            loop_sup[0] <= 1'b0; loop_sup[1] <= 1'b0;
        end else if (lb_v) begin
            loop_sup[lb_slot] <= 1'b1;
        end
    end

    // The books, for the bench and the bring-up (hierarchy-visible).
    logic [31:0] cnt_promotes, cnt_cam_fills, cnt_scan_fills, cnt_loop_hold;
    logic [31:0] cnt_scan_block;      // clocks a slot want waited on a scan fill
    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_promotes <= 32'd0; cnt_cam_fills <= 32'd0;
            cnt_scan_fills <= 32'd0; cnt_loop_hold <= 32'd0;
            cnt_scan_block <= 32'd0;
        end else begin
            if (want_pending && f_active && f_cam)
                cnt_scan_block <= cnt_scan_block + 32'd1;
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
    // program-stream opcode fetch, turbo or slow.
    wire        sc0 = v[0] && (sc_addr[15:4] == vtag[0]);
    wire        sc1 = v[1] && (sc_addr[15:4] == vtag[1]);
    wire        sc_held = sc0 || sc1;
    wire [7:0]  sc_byte = sc0 ? ldata[0][8 * sc_addr[3:0] +: 8]
                              : ldata[1][8 * sc_addr[3:0] +: 8];
    wire        anchor_v = !cpu_rst && cyc_is_i && cpu_rw && cpu_sync &&
                           (retire || accel_cyc_en);
    iscan u_scan (
        .clk         (clk),
        .rst         (rst),
        .enable      (turbo_en && serve && !cpu_rst),
        .anchor_v    (anchor_v),
        .anchor_addr (pc_addr),
        .rd_addr     (sc_addr),
        .rd_held     (sc_held),
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
        tev_valid <= retire && ev_room;
        if (retire) begin
            tev_addr <= pc_addr;
            tev_data <= i_din;
            tev_sync <= cpu_sync;
        end

        if (rst) begin
            v[0] <= 1'b0; v[1] <= 1'b0;
            vtag[0] <= 12'd0; vtag[1] <= 12'd0;
            t_rom[0] <= 1'b0; t_rom[1] <= 1'b0;
            t_aux[0] <= 1'b0; t_aux[1] <= 1'b0;
            t_bank[0] <= 8'd0; t_bank[1] <= 8'd0;
            t_poff[0] <= 12'd0; t_poff[1] <= 12'd0;
            cur <= 1'b0;
            want_v[0] <= 1'b0; want_v[1] <= 1'b0;
            want_tag[0] <= 12'd0; want_tag[1] <= 12'd0;
            fst <= F_IDLE;
            f_slot <= 1'b0; f_rom <= 1'b0; f_aux <= 1'b0; f_cam <= 1'b0;
            f_bank <= 8'd0; f_vtag <= 12'd0; f_poff <= 12'd0;
            tick_q <= 1'b0; tev_valid <= 1'b0;
            for (s = 0; s < CAMN; s = s + 1) cam_v[s] <= 1'b0;
            cam_wp <= 3'd0;
        end else begin
            // ---- the engine ------------------------------------------------
            if (f_restart) begin
                fst <= F_IDLE;
                // A slot fill retries through its want (the relaunch
                // re-classifies and re-reads); a ROM reload drops it; a
                // CAM-only fill is speculation - dropped, the scanner asks
                // again if it still matters.
                if (!f_cam) begin
                    if (!(f_rom && r2_busy)) begin
                        want_v[f_slot]   <= 1'b1;                  // retry...
                        want_tag[f_slot] <= f_vtag;
                    end else want_v[f_slot] <= 1'b0;               // ...but not a reload
                end
            end else case (fst)
                F_IDLE: if (want_pending) begin
                    // A want its slot already holds is stale bookkeeping.
                    if (stale_own || stale_other) begin
                        want_v[pick] <= 1'b0;
                    end else if (promote_go) begin
                        // THE PROMOTE: the CAM's copy into the slot, one
                        // clock, no page-cache round trip and no
                        // re-classification (the CAM's note above says why
                        // the captured identity still stands).
                        ldata[pick]  <= cam_data[cam_idx];
                        v[pick]      <= 1'b1;
                        vtag[pick]   <= p_tag;
                        t_rom[pick]  <= cam_rom[cam_idx];
                        t_aux[pick]  <= cam_aux[cam_idx];
                        t_bank[pick] <= cam_bank[cam_idx];
                        t_poff[pick] <= cam_poff[cam_idx];
                        want_v[pick] <= 1'b0;
                    end else if (p_bus || excl(p_tag)) begin
                        want_v[pick] <= 1'b0;      // never servable: leave empty
                    end else begin
                        f_slot <= pick;
                        f_cam  <= 1'b0;
                        f_vtag <= p_tag;
                        f_rom  <= p_rom;
                        f_aux  <= !p_rom && p_aux;
                        f_bank <= rw_bank;
                        f_poff <= p_off[15:4];
                        want_v[pick] <= 1'b0;
                        fst <= p_rom ? F_R0 : F_REQ;
                    end
                end else if (scan_go) begin
                    // The scanner's want: lowest priority, and only ever a
                    // CAM fill.  A target already held, already retained or
                    // never servable is dropped; sw_taken retires the want
                    // either way.
                    if (!stale_own && !stale_other && !cam_hit &&
                        !p_bus && !excl(p_tag)) begin
                        f_cam  <= 1'b1;
                        f_vtag <= p_tag;
                        f_rom  <= p_rom;
                        f_aux  <= !p_rom && p_aux;
                        f_bank <= rw_bank;
                        f_poff <= p_off[15:4];
                        fst    <= p_rom ? F_R0 : F_REQ;
                    end
                end
                F_REQ: begin
                    if (il_ack && il_ok)       fst <= F_W1;
                    else if (il_ack && !il_ok) fst <= F_IDLE;   // not resident: decline
                end
                F_W1: fst <= F_W2;
                F_W2: begin
                    if (!f_cam) begin
                        if (!f_rom) ldata[f_slot] <= il_row;
                        v[f_slot]      <= 1'b1;
                        vtag[f_slot]   <= f_vtag;
                        t_rom[f_slot]  <= 1'b0;
                        t_aux[f_slot]  <= f_aux;
                        t_bank[f_slot] <= f_bank;
                        t_poff[f_slot] <= f_poff;
                    end
                    // EVERY committed line is retained: the CAM records it,
                    // deduplicated - a live entry with this tag keeps its
                    // claim, its bytes identical by the snoop.
                    if (!cam_dup) begin
                        cam_data[cam_wp] <= f_rom ? (f_cam ? f_cbuf : ldata[f_slot])
                                                  : il_row;
                        cam_v[cam_wp]    <= 1'b1;
                        cam_vtag[cam_wp] <= f_vtag;
                        cam_rom[cam_wp]  <= f_rom;
                        cam_aux[cam_wp]  <= f_aux;
                        cam_bank[cam_wp] <= f_bank;
                        cam_poff[cam_wp] <= f_poff;
                        cam_wp <= cam_wp + 3'd1;
                    end
                    fst <= F_IDLE;
                end
                // The ROM's four words: issue beat N, its word lands with
                // beat N+1's issue.  r2_busy restarts above.  A CAM-only
                // fill stages into f_cbuf; the slots' bytes are not its.
                F_R0: fst <= F_R1;
                F_R1: begin
                    if (f_cam) f_cbuf[31:0] <= r2_data;
                    else       ldata[f_slot][31:0] <= r2_data;
                    fst <= F_R2;
                end
                F_R2: begin
                    if (f_cam) f_cbuf[63:32] <= r2_data;
                    else       ldata[f_slot][63:32] <= r2_data;
                    fst <= F_R3;
                end
                F_R3: begin
                    if (f_cam) f_cbuf[95:64] <= r2_data;
                    else       ldata[f_slot][95:64] <= r2_data;
                    fst <= F_W1;                   // one more clock for word 3
                end
                default: fst <= F_IDLE;
            endcase
            // Word 3 of a ROM line, and its commit, share F_W1/F_W2 with the
            // RAM path's wait: F_W1 samples it, F_W2 commits.
            if (fst == F_W1 && f_rom) begin
                if (f_cam) f_cbuf[127:96] <= r2_data;
                else       ldata[f_slot][127:96] <= r2_data;
            end
            if (fst == F_W2 && f_rom && !f_cam) begin
                t_rom[f_slot] <= 1'b1;             // overrides F_W2's clear
                t_aux[f_slot] <= 1'b0;
            end

            // ---- the train and the rotation --------------------------------
            if (miss_q && !wanted_now) begin
                want_v[cur]   <= 1'b1;
                want_tag[cur] <= miss_tag_q;
                v[cur]        <= 1'b0;
                if (!(v[!cur] && vtag[!cur] == miss_tag_q + 12'd1) &&
                    !(f_active && f_vtag == miss_tag_q + 12'd1)) begin
                    want_v[!cur]   <= 1'b1;
                    want_tag[!cur] <= miss_tag_q + 12'd1;
                    v[!cur]        <= 1'b0;
                end
            end
            if (cross0) begin
                cur <= 1'b0;
                if (rot0) begin
                    v[1] <= 1'b0;
                    want_v[1]   <= 1'b1;
                    want_tag[1] <= vtag[0] + 12'd1;
                    if (f_active && !f_cam && f_slot == 1'b1) fst <= F_IDLE;   // abort the stale fill
                end
            end
            if (cross1) begin
                cur <= 1'b1;
                if (rot1) begin
                    v[0] <= 1'b0;
                    want_v[0]   <= 1'b1;
                    want_tag[0] <= vtag[1] + 12'd1;
                    if (f_active && !f_cam && f_slot == 1'b0) fst <= F_IDLE;
                end
            end

            // ---- the kills, last: they beat every commit above -------------
            if (snp_kill0) v[0] <= 1'b0;
            if (snp_kill1) v[1] <= 1'b0;
            for (s = 0; s < CAMN; s = s + 1)
                if (cam_snp_kill[s]) cam_v[s] <= 1'b0;
            // The wants survive a map change (the retry re-classifies); an
            // emptied front with serving off wants nothing.  The CAM does
            // NOT survive one: promotion trusts the captured identity, and
            // that trust is exactly as old as the map.
            if (map_changed || inval || !serve) begin
                v[0] <= 1'b0; v[1] <= 1'b0;
                for (s = 0; s < CAMN; s = s + 1) cam_v[s] <= 1'b0;
            end
            if (!serve) begin
                want_v[0] <= 1'b0; want_v[1] <= 1'b0;
                fst <= F_IDLE;
            end
            if (r2_busy) begin
                if (t_rom[0]) v[0] <= 1'b0;
                if (t_rom[1]) v[1] <= 1'b0;
                for (s = 0; s < CAMN; s = s + 1)
                    if (cam_rom[s]) cam_v[s] <= 1'b0;
            end
        end
    end

endmodule
