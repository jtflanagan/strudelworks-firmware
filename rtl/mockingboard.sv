`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mockingboard - a Mockingboard's (or a Phasor's) digital half, on the card that IS the CPU.
//
// A real Mockingboard is two 6522 VIAs whose ports drive two AY-3-8913 sound
// chips.  The 6502 only ever talks to the VIAs; the AYs hang off the VIA ports
// and never touch the Apple bus.  So the card carries exactly the half the bus
// can see - the VIA pair - and the HOST carries the half the bus cannot: it
// already receives every captured cycle for the display, and it reconstructs
// the AY state from the VIA port writes in that same stream and synthesises
// the audio.  Nothing here makes a sound; it makes the software believe the
// slot is populated, which is what makes the software produce the writes the
// host turns into sound.
//
// Ported from AppleTini v5_1_3's mockingboard.sv, with one structural
// difference that changes where everything hooks on.  There the card sat in a
// slot IMPERSONATING a peripheral against a real 6502, so it worked from bus
// snoops and drove the data bus on the peripheral's schedule.  Here the card's
// own soft core is the machine's CPU (see docs/BUS_MASTER.md), so this module
// hangs off apple_bus_write's presented op - the address the card itself is
// driving - and hands its read data back for apple_bus_write to emit in the
// CPU's own data window.  The byte still goes out the pins and returns through
// the level shifters, so the capture stream records what a snooper would have
// seen and the host needs no special case.  It also follows that the
// Mockingboard only exists while the soft core is mastering: with the native
// 6502 driving, nothing can put a byte on the bus at the peripheral's tap, and
// the module holds its VIAs in reset.
//
// SOFT SWITCH TRACKING lives in rtl/slot_switches.sv, shared with the hard
// disk: $C400-$C4FF is not always the slot 4 card - with INTCXROM set the
// motherboard ROM owns all of $C100-$CFFF, and a IIe boots that way - so a
// cycle is claimed only when that module says the slot page is actually
// mapped to the slots.  A card that answered $Cnxx unconditionally would
// fight the motherboard ROM's own bus driver.
//
// Register decode matches the real card and v5_1_3 both: A7 picks the VIA
// (VIA 0 at $Cn00-$Cn7F, VIA 1 at $Cn80-$CnFF), A3-A0 pick the register, and
// A4-A6 are not decoded, so each VIA mirrors through its half page.  Reads
// anywhere in the claimed page return VIA data, which is also what the
// undecoded hardware does.
//
// AS A PHASOR (phasor = 1, MB_SLOT bit 3): Applied Engineering's card is the
// same two VIAs behind a mode register, plus a second AY on each VIA that the
// host synthesises as it does the first (the chip-select bits ride on port B
// and are the host's business, like everything else the ports carry).  The
// mode register is set by ANY access, read or write, to the slot's DEVICE
// SELECT' range $C0n0-$C0nF - AppleWin's PhasorIO, from measurements on the
// real card: A3 set clears the mode, then A2-A0 are OR'd in.  RES' clears
// it: a Phasor wakes up as a Mockingboard.  The mode picks the VIA decode
// (AppleWin's IORead/IOWrite):
//
//   mode 0 (Mockingboard)   A7 picks the VIA, as above
//   mode 5 (Phasor native)  A4 selects VIA 0, A7 selects VIA 1: neither,
//                           either or BOTH, so a write can land in both and
//                           a read is the OR of both; $Cn00-$Cn0F selects no
//                           VIA and is not claimed, and $Cn2x/$Cn4x/$Cn6x
//                           are the speech chips' (below)
//   mode 7 (Echo+)          VIA 1 at every 16-byte offset of the page
//   1-4, 6                  undefined on the real card; nothing answers
//
// THE SPEECH CHIPS (2026-09-05).  A Phasor's two SSI-263 sockets are
// populated: rtl/ssi263.sv, one per socket, the bus-visible half of the
// chip (its registers, D7, and above all the cycle-exact phoneme timer);
// the speech itself is the host's, from the same writes.  AppleWin's
// IOWrite/IORead, confirmed on the real card:
//
//   writes   in Mockingboard and native modes (not Echo+, not the undefined
//            ones): A6 set writes the PRIMARY chip ($Cn4x, the socket
//            behind VIA 1), A5 set the SECONDARY ($Cn2x, behind VIA 0),
//            both at $Cn6x; register = A2-A0; A4 and A7 are not looked at,
//            so in Mockingboard mode a write to $Cn4x lands in the primary
//            chip AND VIA 0 (A7 clear, A4-A6 undecoded), as it does on the
//            hardware
//   reads    native mode only, at A4 = A7 = 0 with A5 or A6 set: the chip
//            drives D7 (its request flag) and nothing else; the card claims
//            the read and puts the rest of the byte low.  In Mockingboard
//            mode D7 is not readable ($Cn4x reads VIA 0)
//   A/!R     Mockingboard mode: to the socket's VIA's CA1 (the primary's
//            to VIA 1, the secondary's to VIA 0), where PCR bit 0 = 0 makes
//            the falling edge IFR bit 1, the speech interrupt every driver
//            enables through IER; native mode: straight to the 6502's
//            IRQ' - and not to CA1; Echo+ and the undefined modes: nowhere
//
// The VIAs' CA1 inputs are therefore no longer tied off: they idle high
// and go low while a chip requests, which is also how a mode change into
// Mockingboard mode with a request already up raises the flag (AppleWin's
// SetCardMode does that by hand).  A Mockingboard - phasor = 0 - has no
// sockets, and the chips sit in reset.
//
// The DEVICE SELECT' accesses are never gated by INTCXROM (the hardware's
// rule too), and they are bus cycles in every acceleration mode - the
// Mockingboard's $C0nX range is not among the on-card slot ops (CXXX.md) -
// so the host sees each one in the stream and follows the mode from it,
// exactly as it follows the VIA writes.
//
// IRQ takes the short route.  A real Mockingboard pulls the slot's IRQ' line;
// this card's soft core takes its interrupt input directly, so the VIA IRQs
// are OR'd into that instead (master_top).  Same signal, same polarity at the
// core, no pin - the same argument as drv_sync in apple_bus_write.
//
// AY REGISTER READS (2026-09-05, mb-audit's finding).  The AYs' registers
// can be read back through the VIA (port A as input, PSG READ on port B),
// and software that looks for a chip does exactly that; the port A inputs
// were tied low and every chip read as missing.  So the chips are here:
// rtl/ay_pair.sv behind each VIA, two YM2149 cores with their sound outputs
// open (the generators prune away; the register files and the bus protocol
// stay) and the Phasor's GAL around them, driving port A during a READ.
// Still no sound on the card - the host synthesises it from the same writes.
//
// THE TIMER FLAGS SET ON THE $0000 -> $FFFF TICK (2026-09-05, mb-audit test
// 6522:F): a read of IFR on exactly the (N+2)th cycle after the T1C-H write
// sees the T1 flag, on the (N+1)th not yet.  The VIA raised it a tick later,
// on the reload.  And mb-audit test 6522:3 pins the counter itself: a read
// on cycle W+k after the write sees N-(k-1) - the state at the END OF THE
// PREVIOUS cycle - which is what registering the byte at the op's present,
// before the cycle's own tick at its commit, gives.  So the tick stays at
// commit; only the flag moved (rtl/via6522.v irq_t1_set, irq_t2_set).
//
// The VIA timers count the CORE's cycles, not the bus's: slow_clock ticks
// once per op the core completes - a bus cycle that carried one of its ops,
// or a fast op the sequencer served from the card's memory - and never for a
// dummy cycle the driver put on the bus while the core ran ahead.  With the
// core locked to the bus that is exactly one tick per phi0 cycle, so a T1
// programmed for 1000 fires every 1002 microseconds of machine time, the rate
// the music player on the other side of the vectors is counting on.  With the
// core accelerated the timers run at the core's pace, which is what the
// software expects: every Mockingboard detection routine (Ultima, Skyfox,
// Total Replay's) writes a timer and reads it back a known number of
// INSTRUCTIONS later, and accepts the card only if the count moved by the
// cycles those instructions took.  A timer on bus time under a 12x core
// moves by a twelfth of that and the card is "not present" - the floppy's
// lesson (rtl/floppy_card.sv) over again.
//////////////////////////////////////////////////////////////////////////////////
module mockingboard #(
    // The speech chips' sample clock: 22050 per 1020408 core cycles.  A
    // bench shortens it.
    parameter integer SSI_TICK_NUM = 22050,
    parameter integer SSI_TICK_DEN = 1020408
) (
    input  wire        clk,
    input  wire        rst,

    // Synchronised RES', ACTIVE LOW, from apple_bus_read.  The slot's RES pin
    // resets a real Mockingboard's VIAs; same here.
    input  wire        res_sync,

    // 1 while the soft core owns the bus.  See the header: no mastering, no
    // Mockingboard.
    input  wire        master_active,

    // Which slot this card answers as; 0 disables it entirely.  Latched by
    // wb_regfile at a RES' assertion, so it never moves mid-boot.
    input  wire [2:0]  slot_assign,
    // ...and whether, in that slot, it is a Phasor.  Latched with the slot.
    input  wire        phasor,

    // The presented op, from apple_bus_write: the address/RW/data the card is
    // driving this bus cycle, stable from op_present through op_commit.
    input  wire [15:0] op_addr,
    input  wire        op_rw,          // 1 = read
    input  wire [7:0]  op_wdata,
    input  wire        op_present,     // pulse: a new op has been presented
    input  wire        op_commit,      // pulse: the cycle's data phase
    input  wire        op_dummy,       // this bus cycle carried no op: no tick
    // A fast op of the accelerated core completed: a tick of the core's
    // time that the bus never saw.  Tied low without the sequencer.
    input  wire        fast_tick,

    // The AYs' clock (docs/AUDIO.md): one phi0 cycle of the REAL bus
    // (`bus_tick`) when `ay_realtime`, else the core's clock as the VIA
    // timers count it.  Doubled in Phasor native mode either way.
    input  wire        bus_tick,
    input  wire        ay_realtime,
    // The chips' sound, {chip3, chip2, chip1, chip0} at 10 bits: chip 0 is
    // VIA 0's first AY, 1 VIA 1's first, 2 and 3 their seconds (the host's
    // ay_[n*2 + via] order, strudelworks-host src/mb_audio.hpp).
    output wire [39:0] ay_out,

    // Back to apple_bus_write: claim this read cycle and the byte to emit.
    // Registered at op_present, so they are stable long before the emit window
    // opens and do not move until the next cycle presents.
    output logic       rd_claim,
    output logic [7:0] rd_data,

    // ACTIVE HIGH, for the top to fold into the soft core's irq_n.
    output wire        irq
);

    wire enabled = master_active && (slot_assign != 3'd0);

    // ---- soft switches ------------------------------------------------------
    wire io_select;

    slot_switches u_sw (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .slot (slot_assign),
        .io_select (io_select)
    );

    // ---- decode -------------------------------------------------------------
    // Live decode of the presented op; registered users only.
    wire slot_hit = enabled &&
                    op_addr[15:12] == 4'hC &&
                    op_addr[11:8]  == {1'b0, slot_assign} &&
                    io_select;

    logic hit_q;        // this cycle's op is ours; qualifies the commit strobe

    // ---- the Phasor's mode register -----------------------------------------
    // See the header.  dev_hit: the op is in the slot's DEVICE SELECT' range;
    // registered at present like hit_q, acted on at the commit of a real
    // (non-dummy) cycle.  A Mockingboard has no such register and ignores
    // the range, as the real card does.
    logic [2:0] mode;
    wire dev_hit = enabled && phasor &&
                   op_addr[15:8] == 8'hC0 && op_addr[7] && op_addr[6:4] == slot_assign;
    logic dev_hit_q;

    // Which VIAs the presented address selects, by the mode: bit 0 VIA 0,
    // bit 1 VIA 1.  Live off op_addr and mode, both stable across the cycle.
    wire [1:0] cs = (!phasor || mode == 3'd0) ? {op_addr[7], !op_addr[7]}
                  : (mode == 3'd5)            ? {op_addr[7],  op_addr[4]}
                  : (mode == 3'd7)            ? 2'b10
                  :                             2'b00;
    logic [1:0] cs_q;

    // The speech chips: which the presented op writes ({primary, secondary}
    // by A6/A5, in Mockingboard and native modes), and whether it reads one
    // (native mode, A4 = A7 = 0, A5 or A6).  Registered at present with cs.
    wire       ssi_modes = phasor && (mode == 3'd0 || mode == 3'd5);
    wire [1:0] ssi_wsel  = {2{ssi_modes && !op_rw}} & {op_addr[6], op_addr[5]};
    wire       ssi_rd    = phasor && mode == 3'd5 && op_rw &&
                           !op_addr[4] && !op_addr[7] && (op_addr[5] || op_addr[6]);
    logic [1:0] ssi_wsel_q;
    wire [1:0] ssi_d7, ssi_ar_n;
    // The routing of A/!R, by the mode (see the header).
    wire       ssi_to_via = phasor && (mode == 3'd0);
    wire       ssi_to_cpu = phasor && (mode == 3'd5);
    wire [1:0] ssi_ca1_n  = ssi_to_via ? ssi_ar_n : 2'b11;
    wire       ssi_irq    = ssi_to_cpu && (!ssi_ar_n[0] || !ssi_ar_n[1]);

    // ---- the VIA pair -------------------------------------------------------
    // The ports go to the AYs (rtl/ay_pair.sv): port A out is the AYs' data
    // bus and reads back the selected register during a PSG READ, port B out
    // carries the control pins.  The AYs' sound is the host's.  Port B's
    // input pins float high, as port A's do (AppleWin GH#1260; mb-audit's
    // after-reset test reads IRB with DDRB clear and expects $FF).
    wire       via_reset = rst || !res_sync || !enabled;
    wire [7:0] via0_data_out, via1_data_out;
    wire       via0_irq, via1_irq;
    wire [7:0] via0_pa_out, via0_pb_out, via0_ddra, via0_ddrb, via0_pa_in;
    wire [7:0] via1_pa_out, via1_pb_out, via1_ddra, via1_ddrb, via1_pa_in;

    // The core's clock, see the header: a bus cycle that carried one of the
    // core's ops, ticked at its commit, or a fast op; never a dummy.
    wire via_slow_clock = enabled && ((op_commit && !op_dummy) || fast_tick);
    wire via0_strobe    = op_commit && hit_q && cs_q[0];
    wire via1_strobe    = op_commit && hit_q && cs_q[1];

    wire ay_selects = phasor && (mode == 3'd5 || mode == 3'd7);
    wire ay_native  = phasor && (mode == 3'd5);

    // The AY clock: the chosen time base's tick, and in native mode a second
    // pulse the clock after (the host's `div_` 4 for 8 - AppleWin's clock
    // scale factor 2).  Under turbo the core's ticks can come every clock
    // and the doubling saturates; that sound is not music in any case.
    wire  ay_tick = enabled && (ay_realtime ? bus_tick : via_slow_clock);
    logic ay_dbl_q = 1'b0;
    always_ff @(posedge clk) ay_dbl_q <= ay_tick && ay_native;
    wire  ay_ce = ay_tick || ay_dbl_q;

    ay_pair u_ay0 (
        .clk (clk), .rst (via_reset),
        .porta_out (via0_pa_out), .ddra (via0_ddra),
        .portb_out (via0_pb_out), .ddrb (via0_ddrb),
        .selects (ay_selects), .native (ay_native),
        .ce (ay_ce),
        .porta_in (via0_pa_in),
        .out_a (ay_out[9:0]), .out_b (ay_out[29:20])
    );

    ay_pair u_ay1 (
        .clk (clk), .rst (via_reset),
        .porta_out (via1_pa_out), .ddra (via1_ddra),
        .portb_out (via1_pb_out), .ddrb (via1_ddrb),
        .selects (ay_selects), .native (ay_native),
        .ce (ay_ce),
        .porta_in (via1_pa_in),
        .out_a (ay_out[19:10]), .out_b (ay_out[39:30])
    );

    // The speech chips, one per socket: 0 the secondary ($Cn2x, VIA 0's
    // CA1), 1 the primary ($Cn4x, VIA 1's).  Their registers are written
    // at the commit of the op that selected them; their sample clock is
    // the VIAs'.
    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : g_ssi
            ssi263 #(.TICK_NUM (SSI_TICK_NUM), .TICK_DEN (SSI_TICK_DEN)) u_ssi (
                .clk (clk), .rst (via_reset || !phasor),
                .slow_clock (via_slow_clock),
                .wr_strobe (op_commit && hit_q && ssi_wsel_q[g]),
                .wr_reg (op_addr[2:0]), .wr_data (op_wdata),
                .d7 (ssi_d7[g]), .ar_n (ssi_ar_n[g]), .tick ()
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (via_reset)                                 mode <= 3'd0;
        else if (op_commit && !op_dummy && dev_hit_q)  mode <= (op_addr[3] ? 3'd0 : mode) | op_addr[2:0];
    end

    via6522 via0 (
        .clk        (clk),
        .reset      (via_reset),
        .strobe     (via0_strobe),
        .we         (!op_rw),
        .addr       (op_addr[3:0]),
        .data_in    (op_wdata),
        .data_out   (via0_data_out),
        .irq        (via0_irq),
        .slow_clock (via_slow_clock),
        .porta_in   (via0_pa_in),
        .portb_in   (8'hFF),        // input pins float high (AppleWin GH#1260)
        .ca1_in     (ssi_ca1_n[0]), // the secondary speech chip's A/!R
        .ca2_in     (1'b0),
        .cb1_in     (1'b0),
        .cb2_in     (1'b0),
        .porta_out  (via0_pa_out),
        .portb_out  (via0_pb_out),
        .ddra_out   (via0_ddra),
        .ddrb_out   (via0_ddrb),
        .ca2_out    (),
        .cb1_out    (),
        .cb2_out    ()
    );

    via6522 via1 (
        .clk        (clk),
        .reset      (via_reset),
        .strobe     (via1_strobe),
        .we         (!op_rw),
        .addr       (op_addr[3:0]),
        .data_in    (op_wdata),
        .data_out   (via1_data_out),
        .irq        (via1_irq),
        .slow_clock (via_slow_clock),
        .porta_in   (via1_pa_in),
        .portb_in   (8'hFF),        // input pins float high (AppleWin GH#1260)
        .ca1_in     (ssi_ca1_n[1]), // the primary speech chip's A/!R
        .ca2_in     (1'b0),
        .cb1_in     (1'b0),
        .cb2_in     (1'b0),
        .porta_out  (via1_pa_out),
        .portb_out  (via1_pb_out),
        .ddra_out   (via1_ddra),
        .ddrb_out   (via1_ddrb),
        .ca2_out    (),
        .cb1_out    (),
        .cb2_out    ()
    );

    // Registered on the way out, as the mouse card's is (rtl/mouse_card.sv):
    // the VIAs' halves are registered inside the 6522, the OR and the enable
    // were not.  One card clock later, and interrupts are asynchronous.
    logic irq_r;
    always_ff @(posedge clk) irq_r <= rst ? 1'b0 : (enabled && (via0_irq || via1_irq || ssi_irq));
    assign irq = irq_r;

    // ---- claim and read data ------------------------------------------------
    // Registered on op_present: one stable answer per bus cycle, decided in
    // the address phase, long before apple_bus_write's emit window opens.  The
    // VIA read mux is combinational off op_addr, which has been stable since
    // T_PRESENT, so sampling it one cycle later is sampling a settled value -
    // and the commit-time side effects of the PREVIOUS access (IFR clears and
    // the like) landed tens of fabric cycles before this present.  A read
    // that selects no VIA (a Phasor in native mode at $Cn00-$Cn0F, or in an
    // undefined mode) is not claimed.  A speech chip's read (native mode,
    // disjoint from every VIA address) is: D7 and seven zeros.
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_claim   <= 1'b0;
            rd_data    <= 8'd0;
            hit_q      <= 1'b0;
            dev_hit_q  <= 1'b0;
            cs_q       <= 2'b00;
            ssi_wsel_q <= 2'b00;
        end else if (op_present) begin
            hit_q      <= slot_hit;
            dev_hit_q  <= dev_hit;
            cs_q       <= cs;
            ssi_wsel_q <= ssi_wsel;
            rd_claim   <= slot_hit && op_rw && (cs != 2'b00 || ssi_rd);
            rd_data    <= ssi_rd ? {(op_addr[6] & ssi_d7[1]) | (op_addr[5] & ssi_d7[0]), 7'd0}
                                 : ({8{cs[0]}} & via0_data_out) | ({8{cs[1]}} & via1_data_out);
        end else if (!enabled) begin
            rd_claim   <= 1'b0;
            hit_q      <= 1'b0;
            dev_hit_q  <= 1'b0;
            ssi_wsel_q <= 2'b00;
        end else if (op_commit) begin
            // The claim is one commit's.  Under acceleration a fast op of
            // ours presents and commits INSIDE a bus cycle the driver has
            // already presented - a dummy, parked on the game port's
            // $C061-$C067 - and that dummy's commit came here next with
            // hit_q and cs_q still ours: a read of VIA register 1-7 by
            // the dummy's low nibble, and reading T1C-L is what clears the
            // T1 flag.  mb-audit failed a different timer or interrupt check
            // on every run in mode 2 at 1x, and passed with the dummies at
            // $0000 (swint off) - found by two full captures, accel off
            // against mode 2, diverging at exactly that write (2026-09-06).
            hit_q      <= 1'b0;
            dev_hit_q  <= 1'b0;
            cs_q       <= 2'b00;
            ssi_wsel_q <= 2'b00;
        end
    end

endmodule
