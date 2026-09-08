`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// accel_seq - the core, faster than the bus.
//
// Between rtl/cpu65c02.sv and rtl/apple_bus_write.sv.  The core only moves on
// cyc_en, and this module owns it: every op the core puts up is DECIDED -
// served on the card in a handful of clocks (a FAST op: a read of RAM, the
// language card or a ROM answered by rtl/mem_cache.sv; a RAM write too, in
// mode 2) or handed to the driver for the next bus cycle (a BUS op: anything
// in $C000-$CFFF the card does not hold, every write in mode 1, everything in
// mode 0 and inside a slow zone).  While the core runs fast the driver keeps
// the bus alive with DUMMY cycles - parked reads of $0000 - so the machine's
// video, the on-card peripherals that count bus cycles, and the VBL lock never
// notice.  See docs/ACCELERATION.md.
//
// THE DECISION IS MADE FROM REGISTERS.  The core's outputs come off its
// microcode ROM, the class comes off the MMU's classifier behind them, and a
// decision made in the same clock was the longest path in the build (16
// levels, +0.05 ns).  So the class, the direction and the override request
// are registered once and the decision is taken the clock after the op
// appears: one more clock per fast op - nine, some 11x - and half the path.
//
// MERGING IN.  A BUS op waits for the driver's next T_PRESENT, rides that
// cycle, and the core moves on at its cyc_done - exactly the old timing for
// that one op.  If the op after it is also a BUS op it rides the very next
// cycle with no gap (the driver samples the core's op some 4 clocks after the
// core produced it - "stay merged"); otherwise bus_owns drops and the core is
// back to fast ops ("merge out").  core_valid is CLEARED on cyc_done and set
// again only by a decision, so the driver can never latch an op this module
// has not offered - the core's next op appears only ~4 clocks before the
// driver's sample point and a decision has to fit in there.
//
// HOLDING.  An override (rtl/boot_hold.sv, rtl/hd_card.sv, rtl/vbl_lock.sv)
// wants bus cycles and the core kept still, which is what ovr_en asks for.  It
// is honoured at the next decision: the bus is handed over (bus_owns, nothing
// offered) until ovr_en has dropped AND the override's last cycle has had its
// data phase (op_inflight - hd_card releases the clock after its last byte's
// present, 45 clocks before that byte lands) AND the cache is idle.  An
// override that arrives during a fast op waits that op plus at most one bus
// cycle.  boot_hold's engage is combinational on the core's live SYNC, and the
// core does not move while held, so the hold catches the fetch it wanted.
//
// ONE OP AT A TIME.  The MMU shadow and the cache pipeline hold exactly one op
// (rtl/mem_cache.sv, "ONE OP AT A TIME"), so a fast op starts only when no op
// is on the bus (op_inflight), the cache is idle (busy), and its last request
// has been taken (mq_valid - which keeps fifo_drops at zero by construction).
// The unified op stream every memory-side consumer watches is REGISTERED here
// - u_* latched at each present and held to the next - so an override's commit
// forty clocks later still sees its own address.  Fast ops have a present and
// no commit: nothing that acts on a commit can be a fast op.
//
// WHEN THE CACHE SAYS NO.  A fast read the cache decided but did not answer
// (an invalidate that began after the decision, the image going away) is
// decided AGAIN: the cache sees it twice, which for a read is nothing, and the
// second decision goes fast once the card can serve or to the bus if serving
// is off.  Never straight to the bus: in mode 2 the machine's RAM is stale and
// the bus's byte would be wrong.
//
// THE GOVERNOR is a leaky bucket in ops: every bus cycle adds `target` (8.8
// fixed point, ops per bus cycle), an op costs one, and no op starts below one
// - fast or bus alike, so a target of 1.0 averages to the machine's own speed
// and 0 means unlimited.  The bucket holds four cycles' worth, so a run of
// merged cycles is followed by at most that much of a burst.
//
// MODE 0 IS THE OLD MACHINE TO THE CLOCK: bus_owns and core_valid are forced
// high, cyc_en is the driver's, din is the driver's, and the state machine
// merely follows along in S_BUS so that switching the mode under a running
// program lands in a defined place.
//
// WHAT IS SLOW IS A MATTER OF CLASS, AND NOTHING ELSE.  Every access to
// $C000-$CFFF that is not the motherboard's own ROM - the I/O page, every
// slot's I/O and ROM pages, a slot's $C800 expansion ROM - is BUS class and
// rides a real cycle, in every mode; a read the card's memory answers is
// fast.  There is no hold-off after a slot access and no rule about a drive
// turning: a peripheral's code runs at the bus's pace exactly as far as it
// touches the bus, which is the rule the user set.
//
// RESET (RES' included) parks this module: nothing offered, no bus owned, the
// driver drives dummies until the core comes out of reset and its first op is
// decided.  A bus op the reset interrupted completes on the bus and its
// cyc_done is ignored; a fast op in flight is waited out (busy).
//
// THE RESET SEQUENCE RIDES THE BUS.  The IIe's MMU does not act on RES': it
// infers a reset from the bus sequence the 6502 makes coming out of one -
// three reads on the stack page, then the vector fetch reads of $FFFC and
// $FFFD - and only then puts its soft switches back.  Those seven cycles are
// RAM and ROM class, and the first cut served them from the card: the bus
// saw dummies, the machine's MMU never reset, INTCXROM stayed set from the
// last program, and the autostart ROM's slot scan read the motherboard ROM's
// self-test in place of every slot ROM.  Found on hardware, by the user, who
// had met it before.  So from reset until the core's read of $FFFD has
// COMPLETED on the bus (reset_seq), every op is a bus op - the two reads at
// PC, the three on the stack, the vector - exactly as in mode 0.  The op
// after that, the first opcode fetch, is decided normally; an armed boot
// hold takes it through the override path as before.
//////////////////////////////////////////////////////////////////////////////////
module accel_seq (
    input  wire        clk,
    input  wire        rst,             // the card's
    input  wire        cpu_rst,         // the core's: the card's OR RES'
    input  wire        master_active,

    // ACCEL_CTRL.
    input  wire [1:0]  mode,            // 0 off, 1 reads fast, 2 reads and writes fast
    input  wire [15:0] target,          // ops per bus cycle, 8.8; 0 = unlimited
    input  wire        cnt_clr,

    // What the card can serve right now.
    input  wire        mem_serve,
    input  wire        mem_image_ready,
    input  wire        mem_invalidating,
    input  wire [1:0]  q_cls,           // apple_mmu's class of the core's live op

    // The core.
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    input  wire [7:0]  cpu_dout,
    input  wire        cpu_sync,
    input  wire        cyc_is_i,       // the core's cycle is an instruction-stream fetch (the census)
    output wire        cyc_en,
    output wire [7:0]  cpu_din,

    // The driver.
    input  wire        op_present,
    input  wire        op_commit,
    input  wire        op_dummy,
    input  wire        op_ovr,
    input  wire        op_divert,
    input  wire        op_sync,
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire [7:0]  op_wdata,
    input  wire        cyc_done,        // the driver's cyc_en: the core's bus op ended
    input  wire [7:0]  drv_din,
    input  wire        op_inflight,
    input  wire        ovr_en,
    output wire        bus_owns,
    output wire        core_valid,

    // The cache.
    input  wire        mem_sub_en,
    input  wire [7:0]  mem_sub_data,
    input  wire        decided,
    input  wire        busy,
    input  wire        mq_valid,

    // The instruction front (rtl/iline.sv): its permission out, its books in.
    output wire        turbo_en,       // steady: accelerating, serving, past the reset sequence
    output wire        turbo_ok,       // this clock: a turbo retire may happen
    input  wire        turbo_commit,   // one op retired on this edge (charge and count)
    input  wire        d_commit,       // the data front's retire: charged the same,
                                       // counted by the front itself (rtl/dline.sv)
    input  wire        turbo_claim,    // the front is clocks from answering: hold the dispatcher
    output wire        turbo_wr,       // steady: turbo_en AND mode 2 - the data front may retire writes
    input  wire        d_pending,      // the data front's posted writes are not all in the banks

    // The internalized ops (docs/ACCELERATION.md, "The keyboard in the
    // dummies"; docs/CXXX.md, "The switch reads in the closed regime" and
    // "The switch writes"): a program's access to a $C0xx address the card
    // can answer itself - a READ of the keyboard from rtl/kbd_inject.sv's
    // parked-dummy latch, the status page from the MMU shadow, $C019 from
    // the VBL lock, a floating value from rtl/fb_sim.sv; a WRITE of a
    // switch whose whole effect is the shadow's (RAMRD and friends, the
    // video toggles, the language card; never INTCXROM/SLOTC3ROM) - served
    // instead of riding a bus cycle.  It rides S_FAST like any fast op
    // (the cache decides it with nothing served or written: a BUS-class
    // op lands in no image) and retires with a SYNTHETIC COMMIT on the
    // unified stream, the one deliberate bend of "fast ops have a present
    // and no commit", so every commit-gated consumer (the shadow's
    // switches above all) sees it as a bus op would have been.  q_swi is
    // apple_mmu's answer for the live address, registered into dq_swi
    // beside dq_cls; swi_byte is the serving authority's byte for a read,
    // selected on the registered op in master_top.  q_swi_quiet marks an
    // op that changes no switch: its fast word goes out flagged quiet
    // (fev_quiet) and the merge's door drops it, counting the cycle, so a
    // poll at the core's pace cannot flood the link (the host applies
    // switch ops from fast words, and a quiet one would be a no-op there).
    input  wire        q_swi,
    input  wire        q_swi_quiet,
    input  wire [7:0]  swi_byte,
    output logic       swi_commit,      // one clock: an internalized op retired
    // The on-card slots (docs/CXXX.md, "The on-card slots"): q_slot marks a
    // q_swi op one of the card's own peripherals answers.  slot_q_o is the
    // dispatched op's copy, held until the next dispatch; sl_win is high
    // from the op's dispatch through its synthetic commit - the window in
    // which master_top shows the peripherals the unified op instead of
    // the driver's dummies.  A slot op moves no switch: no settle.
    input  wire        q_slot,
    output wire        slot_q_o,
    output wire        sl_win,
    // Every fast op's retire, word or not: the tick the peripherals and the
    // virtual beam (rtl/vbeam.sv) keep the core's time by.  fev_valid is
    // the WORD, which a quiet internalized read does not put on the stream.
    output logic       fast_tick,
    output logic       fev_quiet,       // with fev_valid: a quiet internalized read

    // A card whose data is not ready - the floppy with a track fill pending
    // (rtl/floppy_card.sv stall_o) - holds the core's NEXT op, exactly as
    // the memory's not-ready conditions do: a credit already granted waits,
    // the governor is not consulted, and no tick passes, so the program's
    // virtual time stands still.  Registered here, off the decision cone.
    // Accelerated regimes only by construction: mode 0 runs the core from
    // the driver's cycles (cyc_done) and never reads this - a 1x physical
    // cycle cannot be stretched by it.
    input  wire        stall,

    // Time.
    input  wire        bus_tick,

    // The unified op stream, registered.
    output logic        u_present,
    output wire         u_commit,
    output logic [15:0] u_addr,
    output logic        u_rw,
    output logic [7:0]  u_wdata,
    output logic        u_sync,
    output logic        u_ovr,
    output logic        u_divert,

    // A fast op's event, for the capture (rtl/event_merge.sv): the op and the
    // byte the core read or wrote, on the clock the core takes it.
    output logic        fev_valid,
    output logic [15:0] fev_addr,
    output logic        fev_rw,
    output logic [7:0]  fev_data,
    output logic        fev_sync,

    // Status and counters (ACCEL_STAT and friends).
    output wire         accel_on,
    output wire         held_governor,  // the core is waiting for credit
    output wire [3:0]   state_o,
    output wire         reset_seq_o,    // the reset sequence is still on the bus
    output logic [31:0] fast_ops,
    // ACCEL_MAPS: how often the memory map moved (rtl/apple_mmu.sv's
    // map_changed).  Every one of them empties both fronts today, so this is
    // the denominator the revalidation rungs are measured against
    // (docs/PAGE_CACHE.md).
    input  wire         map_changed,
    output logic [31:0] maps,
    // THE CENSUS of the dispatcher's fast ops (ACCEL_FAST_*): what the two
    // fronts did NOT serve, so the next rung knows where to aim.  Seven
    // exclusive buckets that sum to fast_ops: instruction-stream fetches
    // of any class (the front missed or declined), data reads by class -
    // RAM (the data front missed), LC, ROM at $D000+, the internal ROM in
    // $Cxxx - writes, and the internalized keyboard.  Decided here, one
    // clock behind the retirement; counted in rtl/fast_census.sv beside
    // the register file, a clock region away from the fronts.
    output logic        cen_v,          // one clock: a dispatcher op retired...
    output logic [2:0]  cen_sel,        // ...into this bucket (rtl/fast_census.sv)
    output logic [31:0] turbo_ops,
    output logic [31:0] bus_ops,
    output logic [31:0] cycles,
    output logic [31:0] wait_clocks,
    output logic [7:0]  retries
);

    localparam [1:0] CLS_BUS = 2'd0;
    localparam [1:0] CLS_RAM = 2'd1;   // the census's buckets, apple_mmu's encoding
    localparam [1:0] CLS_LC  = 2'd2;
    localparam [1:0] MODE_OFF = 2'd0, MODE_READS = 2'd1, MODE_RW = 2'd2;

    typedef enum logic [2:0] {
        S_RST,      // the core is in reset, or this card is not the CPU
        S_DECIDE,   // the core has an op up; dispatch it when it can go
        S_FAST,     // on the card; waiting for the cache's decision
        S_BUS,      // offered to the driver; waiting for its cycle to end
        S_HELD      // the bus is an override's; waiting for it to let go
    } state_t;
    state_t st;
    assign state_o = {1'b0, st};
    assign reset_seq_o = reset_seq;

    logic bus_owns_q, core_valid_q;
    logic fast_rw;                      // the fast op in flight is a read
    logic reset_seq;                    // the reset sequence has not reached $FFFD on the bus

    wire off = (mode == MODE_OFF);
    assign accel_on = !off && master_active;
    // The OUTPUT muxes take a registered copy: combinational, the mode bits
    // rode out of the regfile through cpu_din into the core's AGU carries and
    // back into the front's enables - the top of round 5's failing paths.  A
    // mode switch reaching din/cyc_en one clock late is invisible: the state
    // machine (which keeps the live decode) has not moved yet either.
    logic off_q;
    always_ff @(posedge clk) begin
        if (rst) off_q <= 1'b1;
        else     off_q <= off;
    end

    // ---- the governor: a registered permission token ------------------------
    // The user's design.  The governor GRANTS one op's permission up front,
    // registered (grant_q); once up it cannot go away until an op completes
    // and consumes it.  Only the consumption verdict touches it - one bit's
    // D input - and the POOL below is the governor's own bookkeeping, pure
    // register arithmetic: deposits on bus ticks, a debit the clock AFTER a
    // consumption (spent_q), the cap, the re-arm.  Nothing in the pool's
    // cone is the consumer's data, so the credit carries live nowhere near
    // the retire/dispatch verdict - the path that missed closure by 45 ps
    // with the old same-clock debit.  Unlimited (target 0) holds the grant
    // high and debits nothing; under a finite target the one-clock re-arm
    // lag is invisible against a 98-clock deposit period, and grants pair
    // one-to-one with debits, so the long-run ratio is exact as before.
    logic [19:0] credit;
    logic        grant_q, spent_q, unl_q;
    wire  [19:0] cap = {2'b00, target, 2'b00};          // 4 * target
    // Registered: target lives in the regfile a clock region away, and a
    // live ==0 compare in can_pay would put it right back in the verdict
    // cone.  A target change taking effect a clock late is invisible.
    always_ff @(posedge clk) unl_q <= (target == 16'd0);
    wire  unlimited = unl_q;
    wire  can_pay   = unl_q || grant_q;

    // ---- the decision -------------------------------------------------------
    // What goes to the bus is a matter of class, mode and policy - never of
    // the card's momentary state.  An invalidate in progress, or the image not
    // ready, makes a fast op WAIT: in mode 2 the bus would answer a RAM read
    // with the machine's stale byte.  Serving turned off is the host's
    // decision, and then everything is the bus's (which is why the host
    // refuses that in mode 2, docs/ACCELERATION.md).
    //
    // dq_* are the registered copies the decision is made from; `settled`
    // says they describe the op the core has up now (see the header).
    logic [1:0] dq_cls, fast_cls_q;
    logic       dq_rw, dq_ovr, dq_swi, dq_quiet, swi_q, quiet_q, fast_i_q, settled;
    logic       dq_slot, slot_q;
    assign slot_q_o = slot_q;
    assign sl_win   = slot_q && ((st == S_FAST) || swi_commit);
    always_ff @(posedge clk) begin
        dq_cls   <= q_cls;
        dq_rw    <= cpu_rw;
        dq_ovr   <= ovr_en;
        dq_swi   <= q_swi;
        dq_slot  <= q_slot;
        dq_quiet <= q_swi_quiet;
    end
    wire needs_bus = off || (dq_cls == CLS_BUS && !dq_swi) || (!dq_rw && mode == MODE_READS) ||
                     !mem_serve || reset_seq;
    // The core's read of $FFFD, over: the machine's MMU has seen its reset.
    wire vector_done = cyc_done && op_rw && !op_ovr && !op_dummy && (op_addr == 16'hFFFD);
    logic stall_q;
    always_ff @(posedge clk) stall_q <= stall && !rst;
    // ...and never on a clock an override is live: a hold is coming, and a
    // fast op dispatched under it - an on-card slot's above all - would open
    // its window with the DMA's first present due (docs/CXXX.md, "The
    // on-card slots": the driver's override enable is gated for the window,
    // and this is the other half that makes the two never meet).
    wire fast_ok   = !stall_q && mem_image_ready && !mem_invalidating &&
                     !op_inflight && !busy && !mq_valid && !ovr_en;

    // The instruction front's leash.  turbo_en is the steady half - the mode,
    // the serve, the reset sequence - and it is a REGISTER: its sources live
    // in the regfile a clock region away, and combinational they topped every
    // failing path into the front's enables (-1.1 ns).  One clock of lag on a
    // host-written mode, or on the reset sequence's first clock (the core is
    // held in reset there anyway), changes nothing observable.  turbo_ok adds
    // this clock's hazards: the dispatcher idle, nothing on the bus or in the
    // cache pipeline, no override engaging (the boot hold catching a SYNC
    // cancels the retire through exactly this term), credit to pay, and never
    // on a fast op's event clock, so the two never collide at the merge.
    logic turbo_en_q, turbo_wr_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            turbo_en_q <= 1'b0;
            turbo_wr_q <= 1'b0;
        end else begin
            turbo_en_q <= accel_on && mem_serve && !reset_seq;
            turbo_wr_q <= accel_on && mem_serve && !reset_seq && (mode == MODE_RW);
        end
    end
    assign turbo_en = turbo_en_q;
    assign turbo_wr = turbo_wr_q;
    // THE SETTLE AFTER A SWITCH SERVED ON THE CARD.  A bus op's commit lands
    // in the middle of a bus cycle: the shadow flips, map_changed pulses,
    // the CAMs flash-clear and every register derived from them settles
    // long before the driver lets the core move again.  A synthetic commit
    // (swi_commit) comes one clock AFTER the core moved - the op retired at
    // fast_hit, cyc_en fired, and the fronts were free to serve the very
    // next op on the clock the shadow was still flipping.  The instruction
    // front did exactly that: after `STA $C003` (RAMRD aux) it served the
    // next opcode from a CAM line resident under the OLD map, one clock
    // before map_changed killed it - one byte from the wrong bank, and Nox
    // Archaist's DHGR splash, whose player sits in both banks and flips
    // RAMRD and keeps executing, hung on hardware (2026-09-04; docs/CXXX.md
    // "The switch writes").  So a switch-changing synthetic commit holds
    // turbo_ok and the dispatcher's `settled` for four clocks: the commit's
    // own, the shadow's, map_changed's, and one more for anything derived
    // from map_changed (rtl/dline.sv's zero-page shadow).  Only an op that
    // can move a switch holds: a $C00x write, or a $C05x/$C08x read or
    // write - and not a QUIET one.  A keyboard or status-page read ($C00x/
    // $C01x, u_addr[7:5] clear) changes nothing and holds nothing; the
    // first cut held on those too and cost the ProDOS boot bench 12% in
    // Bitsy Bye's poll loop.  The cost is four clocks per switch flip,
    // against the bus cycle each one used to be.
    logic [2:0] swi_sq;
    // ...exactly the ops that can move a switch: a $C00x write, a $C05x or
    // $C08x access.  Not the keyboard or status page, not the speaker ($C03x,
    // a toggle and nothing of the map's), not a slot's.
    wire swi_change = swi_commit && !quiet_q && !slot_q && (u_addr[15:8] == 8'hC0) &&
                      ((!u_rw && u_addr[7:4] == 4'h0) || (u_addr[7:4] == 4'h5) || (u_addr[7:4] == 4'h8));
    always_ff @(posedge clk) swi_sq <= rst ? 3'd0 : {swi_sq[1:0], swi_change};
    wire swi_settling = swi_change || (|swi_sq);

    assign turbo_ok = turbo_en_q && !stall_q && (st == S_DECIDE) && !ovr_en && !op_inflight &&
                      !busy && mem_image_ready && can_pay && !fev_valid && !swi_settling;

    // What the dispatcher will charge for on this edge, for the governor's
    // one writer: exactly the two dispatching branches below.
    wire disp_pay = (st == S_DECIDE) && settled && !d_pending && !dq_ovr && !turbo_claim && !stall_q &&
                    can_pay && (needs_bus || fast_ok) && !off &&
                    !cpu_rst && master_active;

    // A fast op's decision: the byte is there, or it is not.  An
    // internalized read's byte is swi_byte, ready by construction, and an
    // internalized write wants nothing - the cache's decided is only the
    // pacing for both.
    //
    // swi_byte is taken through ONE register.  An on-card slot's byte is
    // the card's own registered claim, valid from P1, muxed through every
    // card's claim on the way here; the core consumes it at P3, when
    // `decided` fires.  Sampling at P2 costs nothing and cuts the cards'
    // claim mux out of the din cone - the design's worst path once the
    // data front was cut (u_vidhd/rd_claim -> the slot mux -> cpu_din ->
    // the core, 13 levels at 77% wire, 2026-09-07).  The other bytes swi
    // carries (the keyboard latch, the status page, the floating bus) are
    // stable across a clock.
    logic [7:0] swi_byte_q;
    always_ff @(posedge clk) swi_byte_q <= swi_byte;
    wire fast_hit  = (st == S_FAST) && decided && (!fast_rw || mem_sub_en || swi_q);
    wire fast_miss = (st == S_FAST) && decided &&   fast_rw && !mem_sub_en && !swi_q;

    // ---- the census, one clock behind the retirement -------------------------
    // The bucket is decided on the retire clock into four flops; the
    // counters (rtl/fast_census.sv) count from those a clock later still.
    // fast_hit's fanout (it is the cyc_en and the din mux's select) gains
    // one load, not 224 counter enables, and no adder lives here.
    wire fast_retire = (st == S_FAST) && fast_hit;
    always_ff @(posedge clk) begin
        cen_v   <= fast_retire && !rst;
        cen_sel <= (swi_q && fast_rw && slot_q) ? 3'd4 :  // an on-card slot's read: CX
                   (swi_q && fast_rw)         ? 3'd6 :   // an internalized read: KBD
                   !fast_rw                   ? 3'd5 :   // every write, internalized switch included
                   fast_i_q                   ? 3'd0 :
                   (fast_cls_q == CLS_RAM)    ? 3'd1 :
                   (fast_cls_q == CLS_LC)     ? 3'd2 :
                   (u_addr[15:12] == 4'hC)    ? 3'd4 : 3'd3;
    end

    // ---- the core's side ----------------------------------------------------
    assign cyc_en     = off_q ? cyc_done : (st == S_BUS) ? cyc_done : fast_hit;
    assign cpu_din    = (off_q || st == S_BUS) ? drv_din
                      : swi_q ? swi_byte_q : mem_sub_data;
    assign bus_owns   = off_q || bus_owns_q;
    assign core_valid = off_q || core_valid_q;

    assign held_governor = (st == S_DECIDE) && settled && !can_pay;


    // ---- the unified stream -------------------------------------------------
    // Bus ops and overrides come from the driver a clock after its present;
    // fast ops from the core on the clock they are dispatched.
    wire  bus_op_present = op_present && !op_dummy;
    // The synthetic commit rides beside the driver's: u_addr/u_rw/u_wdata
    // still hold the retired op (the next present is at least two clocks
    // out), so every commit-gated consumer reads the right op.
    assign u_commit = (op_commit && !op_dummy) || swi_commit;


    always_ff @(posedge clk) begin
        u_present <= 1'b0;
        fev_valid <= 1'b0;
        fev_quiet <= 1'b0;
        fast_tick <= (st == S_FAST) && fast_hit && !rst;
        swi_commit <= (st == S_FAST) && fast_hit && swi_q && !cpu_rst;

        // The registers above describe the op the core has up once the
        // core has sat still for a clock: never on the clock of arrival -
        // and a turbo retire moves the core without this module's cyc_en,
        // so it resets the settling the same way.
        settled <= (st == S_DECIDE) && !cyc_en && !turbo_commit && !d_commit && !swi_settling;

        // From reset until $FFFD has ridden the bus (see the header).  Cleared
        // in mode 0 too, where it could not be observed but must not stick.
        if (cpu_rst)                 reset_seq <= 1'b1;
        else if (vector_done || off) reset_seq <= 1'b0;

        if (rst) begin
            st <= S_RST;
            reset_seq <= 1'b1;
            settled <= 1'b0;
            bus_owns_q <= 1'b0; core_valid_q <= 1'b0; fast_rw <= 1'b1; swi_q <= 1'b0; quiet_q <= 1'b0; slot_q <= 1'b0;
            credit <= 20'd0; grant_q <= 1'b0; spent_q <= 1'b0;
            u_addr <= 16'd0; u_rw <= 1'b1; u_wdata <= 8'd0;
            u_sync <= 1'b0; u_ovr <= 1'b0; u_divert <= 1'b0;
            fev_addr <= 16'd0; fev_rw <= 1'b1; fev_data <= 8'd0; fev_sync <= 1'b0;
            fast_ops <= 32'd0; turbo_ops <= 32'd0; bus_ops <= 32'd0; cycles <= 32'd0;
            wait_clocks <= 32'd0; retries <= 8'd0; maps <= 32'd0;
        end else begin
            if (map_changed) maps <= maps + 32'd1;
            // ---- the stream: what the bus carried ---------------------------
            if (bus_op_present) begin
                u_present <= 1'b1;
                u_addr    <= op_addr;
                u_rw      <= op_rw;
                u_wdata   <= op_wdata;
                u_sync    <= op_sync;
                u_ovr     <= op_ovr;
                u_divert  <= op_divert;
            end

            // ---- the governor: the pool, register-in register-out -----------
            begin : credit_upd
                logic [20:0] c;
                c = {1'b0, credit};
                if (bus_tick && !off) begin
                    c = c + {5'd0, target};
                    if (c > {1'b0, cap}) c = {1'b0, cap};
                end
                if (spent_q) c = c - 21'd256;
                if (cpu_rst || !master_active) c = 21'd0;
                credit <= c[19:0];
            end
            // The token: consumption (and only consumption) takes it away;
            // the pool re-arms it when it covers a credit net of the debit
            // still in flight.  The verdict lands on two one-bit D inputs.
            spent_q <= (disp_pay || turbo_commit || d_commit) && !unlimited;
            if (cpu_rst || !master_active || off || unlimited) begin
                grant_q <= 1'b0;
                spent_q <= 1'b0;
            end else if (disp_pay || turbo_commit || d_commit) begin
                grant_q <= 1'b0;
            end else if (!grant_q && credit >= (spent_q ? 20'd512 : 20'd256)) begin
                grant_q <= 1'b1;
            end
            if (bus_tick && accel_on) cycles <= cycles + 32'd1;
            if (turbo_commit) turbo_ops <= turbo_ops + 32'd1;

            // ---- the state machine --------------------------------------------
            if (cpu_rst || !master_active) begin
                st <= S_RST;
                bus_owns_q   <= 1'b0;
                core_valid_q <= 1'b0;
            end else if (off) begin
                // Following along: every op is the driver's.
                st <= S_BUS;
                bus_owns_q   <= 1'b1;
                core_valid_q <= 1'b1;
            end else begin
                case (st)
                    S_RST: begin
                        st <= S_DECIDE;
                    end

                    S_DECIDE: if (settled) begin
                        // THE POSTED WRITES FIRST (rtl/dline.sv, rung 3).
                        // Nothing leaves this state while one is short of
                        // the banks: a dispatched read of a line the front
                        // does not hold would read the pre-write byte; a
                        // map-changing bus op would classify what follows
                        // under a map the posted stamp was not; a hold's
                        // DMA would land under the write it should be
                        // over.  Bounded by the drain - a few clocks.
                        if (d_pending) begin
                        end else if (dq_ovr) begin
                            st <= S_HELD;
                            bus_owns_q   <= 1'b1;
                            core_valid_q <= 1'b0;
                        end else if (turbo_claim) begin
                            // The front is about to answer this fetch itself:
                            // hold, bounded by its fill.
                        end else if (!can_pay) begin
                            // Wait for credit.
                        end else if (needs_bus) begin
                            st <= S_BUS;
                            bus_owns_q   <= 1'b1;
                            core_valid_q <= 1'b1;
                        end else if (fast_ok) begin
                            st <= S_FAST;
                            bus_owns_q   <= 1'b0;
                            core_valid_q <= 1'b0;
                            fast_rw      <= cpu_rw;
                            swi_q        <= dq_swi;
                            slot_q       <= dq_slot;
                            quiet_q      <= dq_quiet;
                            fast_cls_q   <= dq_cls;
                            fast_i_q     <= cyc_is_i;
                            // The op, onto the stream.
                            u_present <= 1'b1;
                            u_addr    <= cpu_addr;
                            u_rw      <= cpu_rw;
                            u_wdata   <= cpu_dout;
                            u_sync    <= cpu_sync;
                            u_ovr     <= 1'b0;
                            u_divert  <= 1'b0;
                        end
                    end

                    S_FAST: begin
                        if (fast_hit) begin
                            st <= S_DECIDE;
                            fast_ops  <= fast_ops + 32'd1;
                            fev_valid <= 1'b1;
                            fev_quiet <= swi_q && quiet_q;
                            fev_addr  <= u_addr;
                            fev_rw    <= u_rw;
                            fev_data  <= u_rw ? (swi_q ? swi_byte_q : mem_sub_data)
                                              : u_wdata;
                            fev_sync  <= u_sync;
                        end else if (fast_miss) begin
                            // Decide it again.
                            st      <= S_DECIDE;
                            retries <= retries + 8'd1;
                        end
                    end

                    S_BUS: begin
                        if (cyc_done) begin
                            st <= S_DECIDE;
                            core_valid_q <= 1'b0;   // stay merged only by decision
                            bus_ops <= bus_ops + 32'd1;
                        end else begin
                            wait_clocks <= wait_clocks + 32'd1;
                        end
                    end

                    S_HELD: begin
                        if (!ovr_en && !op_inflight && !busy && !d_pending) st <= S_DECIDE;
                    end

                    default: st <= S_RST;
                endcase

                // Merging out: a fast op starts with the bus released above;
                // a decision that stays in S_DECIDE keeps whatever it had, so
                // an override arriving while the governor holds the core
                // finds the bus still owned if it was.
            end

            if (cnt_clr) begin
                fast_ops <= 32'd0; turbo_ops <= 32'd0; bus_ops <= 32'd0; cycles <= 32'd0;
                wait_clocks <= 32'd0; retries <= 8'd0; maps <= 32'd0;
            end
        end
    end

endmodule
