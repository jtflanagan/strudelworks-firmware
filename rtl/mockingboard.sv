`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mockingboard - a Mockingboard's digital half, on the card that IS the CPU.
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
// IRQ takes the short route.  A real Mockingboard pulls the slot's IRQ' line;
// this card's soft core takes its interrupt input directly, so the VIA IRQs
// are OR'd into that instead (master_top).  Same signal, same polarity at the
// core, no pin - the same argument as drv_sync in apple_bus_write.
//
// The VIA timers count phi0 cycles: slow_clock is op_commit, which
// apple_bus_write pulses exactly once per bus cycle, so a T1 programmed for
// 1000 fires every 1002 microseconds of MACHINE time - the rate the music
// player on the other side of the vectors is counting on.
//////////////////////////////////////////////////////////////////////////////////
module mockingboard (
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

    // The presented op, from apple_bus_write: the address/RW/data the card is
    // driving this bus cycle, stable from op_present through op_commit.
    input  wire [15:0] op_addr,
    input  wire        op_rw,          // 1 = read
    input  wire [7:0]  op_wdata,
    input  wire        op_present,     // pulse: a new op has been presented
    input  wire        op_commit,      // pulse: the cycle's data phase

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

    // ---- the VIA pair -------------------------------------------------------
    // Everything a real Mockingboard's VIAs have that this one does not comes
    // down to the ports being wired to AY chips; here they go nowhere, and the
    // AY state they would have carried is reconstructed on the host.  Port
    // inputs are tied low exactly as v5_1_3 tied them.
    wire       via_reset = rst || !res_sync || !enabled;
    wire [7:0] via0_data_out, via1_data_out;
    wire       via0_irq, via1_irq;

    wire via_slow_clock = op_commit && enabled;
    wire via0_strobe    = op_commit && hit_q && !op_addr[7];
    wire via1_strobe    = op_commit && hit_q &&  op_addr[7];

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
        .porta_in   (8'd0),
        .portb_in   (8'd0),
        .ca1_in     (1'b0),
        .ca2_in     (1'b0),
        .cb1_in     (1'b0),
        .cb2_in     (1'b0),
        .porta_out  (),
        .portb_out  (),
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
        .porta_in   (8'd0),
        .portb_in   (8'd0),
        .ca1_in     (1'b0),
        .ca2_in     (1'b0),
        .cb1_in     (1'b0),
        .cb2_in     (1'b0),
        .porta_out  (),
        .portb_out  (),
        .ca2_out    (),
        .cb1_out    (),
        .cb2_out    ()
    );

    assign irq = enabled && (via0_irq || via1_irq);

    // ---- claim and read data ------------------------------------------------
    // Registered on op_present: one stable answer per bus cycle, decided in
    // the address phase, long before apple_bus_write's emit window opens.  The
    // VIA read mux is combinational off op_addr, which has been stable since
    // T_PRESENT, so sampling it one cycle later is sampling a settled value -
    // and the commit-time side effects of the PREVIOUS access (IFR clears and
    // the like) landed tens of fabric cycles before this present.
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_claim <= 1'b0;
            rd_data  <= 8'd0;
            hit_q    <= 1'b0;
        end else if (op_present) begin
            hit_q    <= slot_hit;
            rd_claim <= slot_hit && op_rw;
            rd_data  <= op_addr[7] ? via1_data_out : via0_data_out;
        end else if (!enabled) begin
            rd_claim <= 1'b0;
            hit_q    <= 1'b0;
        end
    end

endmodule
