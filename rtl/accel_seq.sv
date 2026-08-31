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
    // The HOLD's override alone, LIVE: its contract - the core stopped at
    // the exact SYNC, an instruction boundary with every register defined -
    // needs turbo blocked the very clock it engages, and its engage is a
    // few gates off flip-flops.  The other overrides (the disk's DMA, the
    // VBL lock) reach turbo through the registered dq_ovr instead: their
    // one-clock slide is harmless - a DMA lands its blocks via the bus
    // wherever the core's PC sits - and hd_card's DMA-active comparison is
    // a carry chain that must never sit in front of the fetch path.
    input  wire        ovr_hold,
    output wire        bus_owns,
    output wire        core_valid,

    // The cache.
    input  wire        mem_sub_en,
    input  wire [7:0]  mem_sub_data,
    input  wire        decided,
    input  wire        busy,
    input  wire        mq_valid,

    // Time.
    input  wire        bus_tick,

    // The L1 front (rtl/l1_front.sv).  A turbo op is one the front served in
    // a single clock: this module never sees it as an op, only as the books -
    // the governor's charge, the counter, the capture event, the tick.
    input  wire        l1_claim,      // an I-fetch the front may yet serve: hold dispatch
    input  wire        ext_cyc_en,    // the fronts' cyc_en (turbo OR d), for settled's bookkeeping
    input  wire        turbo_commit,  // one turbo op retired this clock
    input  wire [15:0] turbo_addr,
    input  wire [7:0]  turbo_data,
    input  wire        turbo_sync,
    output wire        turbo_ok,      // this module's permission: S_DECIDE, credit, no override

    // The D front (rtl/d_front.sv): same contract as the L1's - a claim
    // that holds the dispatcher, a permission, and a commit that is only
    // books.  d_commit is COMBINATIONAL with the serve's cyc_en, so the
    // governor's payment lands the same clock the credit was checked -
    // a registered commit would let two ops ride one credit.  The event
    // is emitted unconditionally: the front's verdict already required
    // fev_room (law 5 - a d-served write leaves no other trace).
    input  wire        d_claim,
    input  wire        d_commit,      // one op the D front served this clock
    input  wire [15:0] dev_addr,
    input  wire        dev_rw,
    input  wire [7:0]  dev_data,
    input  wire        dev_sync,
    output wire        d_ok,          // permission to serve a data read
    output wire        d_ok_w,        // ...and a write (mode 2 only)
    output logic       op_tick,       // one pulse per op served off the bus, for the op-time clocks
    input  wire        fev_room,      // the event merge has headroom: a turbo
                                      // event may be emitted.  Turbo runs
                                      // outpace the merge's drain three to
                                      // one, so their events - fetches, which
                                      // a sparse capture discards anyway -
                                      // are shed HERE, and the merge's
                                      // overflow counter stays a fault flag.
                                      // The books are never shed.

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
    output logic [31:0] bus_ops,
    output logic [31:0] cycles,
    output logic [31:0] wait_clocks,
    output logic [7:0]  retries,
    output logic [31:0] turbo_ops
);

    localparam [1:0] CLS_BUS = 2'd0;
    localparam [1:0] MODE_OFF = 2'd0, MODE_READS = 2'd1;

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

    // ---- the governor -------------------------------------------------------
    // credit in 1/256 op; one op is 256.  Capped at four cycles' worth.
    logic [19:0] credit;
    wire  [19:0] cap = {2'b00, target, 2'b00};          // 4 * target
    wire  unlimited = (target == 16'd0);
    wire  can_pay   = unlimited || (credit >= 20'd256);

    // Next clock's credit: deposit, cap, then this clock's payment.  The one
    // place credit moves (outside the resets); `pay` is defined below with
    // the dispatch.
    logic [19:0] gov_next;
    always_comb begin
        gov_next = credit;
        if (bus_tick) begin
            gov_next = (credit + {4'd0, target} > cap) ? cap
                                                       : credit + {4'd0, target};
        end
        if (pay) gov_next = gov_next - 20'd256;
    end

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
    logic [1:0] dq_cls;
    logic       dq_rw, dq_ovr, dq_rst, settled;
    always_ff @(posedge clk) begin
        dq_cls <= q_cls;
        dq_rw  <= cpu_rw;
        dq_ovr <= ovr_en;
        // cpu_rst arrives through the link's command-reset counter and a
        // fanout-2393 reset network - the last live head into turbo_ok's
        // cone.  Registered here: S_RST was always a registered transition,
        // and a turbo cyc_en on the reset clock itself is void (the core's
        // rst branch outranks cyc_en at that edge).
        dq_rst <= cpu_rst;
    end
    wire needs_bus = off || (dq_cls == CLS_BUS) || (!dq_rw && mode == MODE_READS) ||
                     !mem_serve || reset_seq;
    // The core's read of $FFFD, over: the machine's MMU has seen its reset.
    wire vector_done = cyc_done && op_rw && !op_ovr && !op_dummy && (op_addr == 16'hFFFD);
    wire fast_ok   = mem_image_ready && !mem_invalidating &&
                     !op_inflight && !busy && !mq_valid;

    // A fast op's decision: the byte is there, or it is not.
    wire fast_hit  = (st == S_FAST) && decided && (!fast_rw || mem_sub_en);
    wire fast_miss = (st == S_FAST) && decided &&   fast_rw && !mem_sub_en;

    // ---- turbo permission and the dispatch ----------------------------------
    // turbo_ok requires the CLAIM as well as S_DECIDE, so a turbo op and a
    // dispatch can never fire on one clock: the dispatch waits for !l1_claim,
    // and once the claim has lapsed the op is the dispatcher's for good.
    // Everything here is a registered term - no loop through the front.
    assign turbo_ok = (st == S_DECIDE) && !off && master_active && !dq_rst &&
                      can_pay && !ovr_hold && !dq_ovr && !reset_seq &&
                      mem_serve && !mem_invalidating && l1_claim;

    // The D front's permission: the same registered terms, WITHOUT the
    // claim - the claim's address decode would close a combinational loop
    // through cpu_din (a data address descends from din).  The mutual
    // exclusion holds anyway: whenever a D verdict can fire, d_claim is up
    // by construction (a servable op in its try window), so decide_go is
    // blocked; and a turbo and a D serve are exclusive by op kind.
    assign d_ok   = (st == S_DECIDE) && !off && master_active && !dq_rst &&
                    can_pay && !ovr_hold && !dq_ovr && !reset_seq &&
                    mem_serve && !mem_invalidating;
    assign d_ok_w = d_ok && (mode == 2'd2);

    wire decide_go = (st == S_DECIDE) && settled && !dq_ovr && can_pay &&
                     !l1_claim && !d_claim;
    wire go_bus    = decide_go && needs_bus;
    wire go_fast   = decide_go && !needs_bus && fast_ok;
    wire pay       = (go_bus || go_fast || turbo_commit || d_commit) && !unlimited;

    // ---- the core's side ----------------------------------------------------
    // go_bus rides beside the registered levels: the driver freezes its take
    // one clock before T_PRESENT (apple_bus_write's t_pre, where the op must
    // agree with the MMU's registered divert answer), and a dispatch decided
    // on that very clock would otherwise miss the cycle - the PHI0_HIGH=47
    // sweep of accel_tb is the proof.  Every term of go_bus is a registered
    // level, so nothing combinational from the core enters the driver's cone.
    assign cyc_en     = off ? cyc_done : (st == S_BUS) ? cyc_done : fast_hit;
    assign cpu_din    = (off || st == S_BUS) ? drv_din : mem_sub_data;
    assign bus_owns   = off || bus_owns_q   || go_bus;
    assign core_valid = off || core_valid_q || go_bus;

    assign held_governor = (st == S_DECIDE) && settled && !can_pay;


    // ---- the unified stream -------------------------------------------------
    // Bus ops and overrides come from the driver a clock after its present;
    // fast ops from the core on the clock they are dispatched.
    wire  bus_op_present = op_present && !op_dummy;
    assign u_commit = op_commit && !op_dummy;


    always_ff @(posedge clk) begin
        u_present <= 1'b0;
        fev_valid <= 1'b0;
        // The op-time clocks' tick: one pulse per op served off the bus,
        // turbo or fast - bus ops tick at their own commit in the cards.
        op_tick   <= ((st == S_FAST) && fast_hit) || turbo_commit || d_commit;

        // The registers above describe the op the core has up once the
        // core has sat still for a clock: never on the clock of arrival -
        // and a clock the FRONT advanced the core on counts as an arrival
        // too, or dq_* would describe the op before the one that is up.
        settled <= (st == S_DECIDE) && !cyc_en && !ext_cyc_en;

        // From reset until $FFFD has ridden the bus (see the header).  Cleared
        // in mode 0 too, where it could not be observed but must not stick.
        if (cpu_rst)                 reset_seq <= 1'b1;
        else if (vector_done || off) reset_seq <= 1'b0;

        if (rst) begin
            st <= S_RST;
            reset_seq <= 1'b1;
            settled <= 1'b0;
            bus_owns_q <= 1'b0; core_valid_q <= 1'b0; fast_rw <= 1'b1;
            credit <= 20'd0;
            u_addr <= 16'd0; u_rw <= 1'b1; u_wdata <= 8'd0;
            u_sync <= 1'b0; u_ovr <= 1'b0; u_divert <= 1'b0;
            fev_addr <= 16'd0; fev_rw <= 1'b1; fev_data <= 8'd0; fev_sync <= 1'b0;
            fast_ops <= 32'd0; bus_ops <= 32'd0; cycles <= 32'd0;
            wait_clocks <= 32'd0; retries <= 8'd0; turbo_ops <= 32'd0;
        end else begin
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

            // ---- the governor ------------------------------------------------
            // One writer: the tick's deposit and this clock's payment (a
            // dispatch, or a turbo op) settle together.  They used to be
            // separate non-blocking writes, and a tick landing on a dispatch
            // clock lost one or the other.  Payment never underflows: every
            // payer is gated on can_pay.
            if (!off) begin
                credit <= gov_next;
            end
            if (bus_tick && accel_on) cycles <= cycles + 32'd1;

            // ---- a turbo op: the front served it; the books are ours --------
            // (!cpu_rst: the one op that can retire on the reset clock
            // itself is void in the core, so it gets no books either.)
            if (turbo_commit && !cpu_rst) begin
                turbo_ops <= turbo_ops + 32'd1;
                if (fev_room) begin
                    fev_valid <= 1'b1;
                    fev_addr  <= turbo_addr;
                    fev_rw    <= 1'b1;
                    fev_data  <= turbo_data;
                    fev_sync  <= turbo_sync;
                end
            end

            // ---- a D-front op: same books.  A WRITE's event is NEVER shed
            // (law 5: the front's verdict held it until the merge had room);
            // a READ's is shed like a turbo fetch's when the merge is full -
            // reads must not wait for room, or a read of an authoritative
            // zp/stack line could fall to the sequencer's stale path.
            if (d_commit && !cpu_rst) begin
                fast_ops  <= fast_ops + 32'd1;
                if (!dev_rw || fev_room) begin
                    fev_valid <= 1'b1;
                    fev_addr  <= dev_addr;
                    fev_rw    <= dev_rw;
                    fev_data  <= dev_data;
                    fev_sync  <= dev_sync;
                end
            end

            // ---- the state machine --------------------------------------------
            if (cpu_rst || !master_active) begin
                st <= S_RST;
                bus_owns_q   <= 1'b0;
                core_valid_q <= 1'b0;
                credit       <= 20'd0;
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
                        if (dq_ovr) begin
                            st <= S_HELD;
                            bus_owns_q   <= 1'b1;
                            core_valid_q <= 1'b0;
                        end else if (go_bus) begin
                            st <= S_BUS;
                            bus_owns_q   <= 1'b1;
                            core_valid_q <= 1'b1;
                        end else if (go_fast) begin
                            st <= S_FAST;
                            bus_owns_q   <= 1'b0;
                            core_valid_q <= 1'b0;
                            fast_rw      <= cpu_rw;
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
                            fev_addr  <= u_addr;
                            fev_rw    <= u_rw;
                            fev_data  <= u_rw ? mem_sub_data : u_wdata;
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
                        if (!ovr_en && !op_inflight && !busy) st <= S_DECIDE;
                    end

                    default: st <= S_RST;
                endcase

                // Merging out: a fast op starts with the bus released above;
                // a decision that stays in S_DECIDE keeps whatever it had, so
                // an override arriving while the governor holds the core
                // finds the bus still owned if it was.
            end

            if (cnt_clr) begin
                fast_ops <= 32'd0; bus_ops <= 32'd0; cycles <= 32'd0;
                wait_clocks <= 32'd0; retries <= 8'd0; turbo_ops <= 32'd0;
            end
        end
    end

endmodule
