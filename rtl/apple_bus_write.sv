`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// apple_bus_write - driving the Apple II bus as its CPU.
//
// The counterpart to apple_bus_read, and deliberately a SEPARATE module: the
// reader is the instrument, it drives nothing, and keeping it that way is what
// makes a driven cycle checkable against a capture rather than inferred.  This
// one drives and never samples for its own sake; it borrows the reader's
// synchronised phi0 and data because two synchronisers on one pin are two
// answers to the same question, and they disagree exactly when it matters.
//
// It does not own the pins.  It produces values and enables; the master top
// does the tristates and the level-shifter directions, because that is where
// the `inout` ports are and where the two modules meet.
//
// THE TIMING CONTRACT is docs/BUS_MASTER.md.  In short, and in the same tap
// idiom the reader uses - a 1 shifted into a pipe on a phi0 edge, so tap N
// pulses N+1 fabric cycles after that edge:
//
//   phi0 falling                      phi0 rising
//   +--------------------------------+------------------------------------+
//   | T_PRESENT (2)                  | T_EMIT  (2)   drive write data      |
//   |   latch the core's op and       | T_DIN   (44)  sample the bus        |
//   |   present it for this cycle     | T_CYCEN (45)  advance the core      |
//   |   release the data bus          |                                     |
//   +--------------------------------+------------------------------------+
//
// WHY T_EMIT IS EARLY, and why it was not at first.  aty's equivalent tap is
// ~195 ns after the rising edge and this was scaled from it faithfully - 200 ns
// here.  The scaling was right and the number was wrong, because it answers a
// different question: in aty the card is impersonating MEMORY, driving a byte
// the CPU will sample at the END of the cycle, so late is exactly right.  We
// are the CPU.  A CPU has to have its write data up for the whole of its active
// phase, not the last third of it, or the machine's write strobe closes before
// the data arrives.
//
// Measured on hardware: with the late tap the core ran the Apple's own monitor
// correctly out of ROM and then fell over at the first RTS, because every push
// had been driven too late to land.  6740 of 6855 write-then-read-back pairs
// did not read back; reads were perfect throughout.
//
// EARLY, BUT NOT FROM T_PRESENT.  The data bus belongs to the video circuitry
// while phi0 is LOW - that is what makes the Apple's floating bus return screen
// data - so driving from the present tap would put us against the machine's own
// RAM output for half of every cycle.  Driving from just after the RISING edge
// keeps us inside the CPU's half and hands the machine the whole of it.
//
// WHY THE ADDRESS IS LATCHED AT A FIXED TAP and not when the core produces it.
// The core's next address appears the instant cyc_en advances it, mid-CURRENT-
// cycle.  Driving it from there makes the presented address flip at a point
// unanchored to the bus cycle that samples it, and over a long run that flip
// lands on the wrong side of a snap: aty saw a $C0xx write driven for two
// cycles - doubled - and a fetch dropped.  Sampling the core at T_PRESENT
// instead gives exactly one stable value per bus cycle, anchored to the cycle
// that carries it.
//
// The core's outputs are settled by then with an enormous margin: cyc_en fired
// ~50 fabric cycles earlier, near the end of the previous cycle, and nothing
// moves them again until the next one.  An earlier staging tap was tried and
// removed - putting it after cyc_en on the RISING pipe left one fabric cycle
// before the next falling edge, which is not a margin, it is a coincidence.
//
// WHY IT MUST BEAT OUR OWN SNAP.  We snoop the bus we are driving.  The address
// has to get out of the pin, through the level shifter, across the board and
// back through the reader's 2-FF synchroniser before the reader samples it at
// its own tap (19, so 20 cycles after the falling edge).  Presenting at tap 2
// leaves ~17 cycles for that round trip.  aty's equivalent margin is ~9 of
// their faster cycles, and their source records that 6 was not enough: a $C007
// write snooped back as the parked $0000, the soft switch never flipped, and
// the machine booted to BASIC.  If that failure ever appears here, this is the
// number.
//
// ADDRESS AND R/W ARE DRIVEN CONTINUOUSLY while mastering, never released
// between cycles - a floating address bus mid-mastering is floating inputs on
// everything downstream.  DATA is windowed, and only on a write: on a read the
// machine's own memory is driving and we must not.
//
// ONE EXCEPTION to "never on a read", and it is claimed, not assumed.  An
// on-card peripheral (rtl/mockingboard.sv) can raise slot_rd_claim for a read
// cycle whose address the motherboard maps to an EMPTY slot - a range nothing
// else drives, which is what makes the Apple's floating bus float.  The card
// then emits the peripheral's byte in the same window a write would use, and
// the byte comes back through the pins and the reader's synchroniser to be
// BOTH the core's din and the captured event: the CPU and the trace read the
// same wire a real slot card would have driven, and neither needs to know the
// data never left the board.  The claim is registered upstream once per cycle
// (see the peripheral), so it cannot move inside the window it gates.
//
// THE CORE IS LOCKED TO THE BUS by cyc_en, one pulse per phi0 cycle, which is
// the interface rtl/cpu65c02.sv was built for.  din is latched at T_DIN and is
// therefore already stable when the core samples it at T_CYCEN.
//
// AN OVERRIDE OP takes a cycle away from the core.  rtl/boot_hold.sv holds the
// core at its reset vector and reads the keyboard for the host in the
// meantime; rtl/hd_card.sv stalls the core on its hard disk's EXECUTE port and
// moves blocks between the Apple's memory and its own buffer.  Both do it by
// raising ovr_en, and this module then presents ovr_addr / ovr_rw / ovr_wdata
// in place of the core's op - latched at the same tap, held for the same
// cycle, so the bus sees no difference - and withholds cyc_en, so the core
// does not advance past a cycle that was not its own.  An override may be a
// WRITE: that is what a DMA into the Apple's memory is, and the write data is
// driven in exactly the window the core's own would be.  Whether a cycle was
// overridden is decided ONCE, at T_PRESENT, and remembered in drv_ovr until
// the cycle ends: a decision that changed mid-cycle would let cyc_en fire for
// an op the core never issued, and the core would swallow the keyboard's byte
// as its opcode.
//////////////////////////////////////////////////////////////////////////////////
module apple_bus_write #(
    // Tap INDICES, matching apple_bus_read's convention: tap N pulses N+1
    // fabric cycles after the edge.  Defaults are the 133 MHz numbers from
    // C:/repos/aty scaled to 100 MHz; see docs/BUS_MASTER.md for the working.
    parameter integer T_PRESENT = 2,    // after phi0 falling  (~30 ns)
    parameter integer T_EMIT    = 2,    // after phi0 rising   (~30 ns)
    parameter integer T_DIN     = 44,   // after phi0 rising   (~450 ns)
    parameter integer T_CYCEN   = 45
) (
    input  wire        clk,
    input  wire        rst,

    // Borrowed from apple_bus_read.  Synchronised, not raw pins.
    input  wire        phi0_sync,
    input  wire [7:0]  data_sync,

    // 1 while this card owns the bus.  Latched from CPU_SOURCE at a RES'
    // assertion by wb_regfile - never mid-cycle, never mid-instruction.
    input  wire        master_active,

    // The core.  addr/rw/dout are its live outputs; they are sampled at T_LATCH
    // and held for the whole of the bus cycle that carries them.
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,          // 1 = read
    input  wire [7:0]  cpu_dout,
    // The core's SYNC, latched with the rest of its op.  See drv_sync below.
    input  wire        cpu_sync,
    output logic       cyc_en,          // one pulse per bus cycle
    output logic [7:0] cpu_din,

    // The presented op, for an on-card peripheral to watch.  op_addr/op_rw/
    // op_wdata are the drv_* registers: one stable value per bus cycle.
    // op_present pulses once when they have just been latched (the address
    // phase); op_commit pulses at T_DIN (the data phase), which is where a
    // peripheral applies a write or the side effects of a read, and is also
    // its once-per-cycle tick.  Neither fires unless mastering.
    output wire [15:0] op_addr,
    output wire        op_rw,
    output wire [7:0]  op_wdata,
    output logic       op_present,
    output logic       op_commit,

    // A peripheral's answer for a claimed READ cycle: emit slot_rd_data in
    // the data window instead of leaving the bus to float.  Must be stable
    // across the cycle - registered at op_present upstream.
    input  wire        slot_rd_claim,
    input  wire [7:0]  slot_rd_data,

    // An override, from boot_hold or hd_card: while ovr_en, the next cycle
    // presents ovr_addr with ovr_rw (1 = read) and, for a write, ovr_wdata,
    // instead of the core's op, and the core is not advanced.  Sampled at
    // T_PRESENT only.
    input  wire        ovr_en,
    input  wire [15:0] ovr_addr,
    input  wire        ovr_rw,
    input  wire [7:0]  ovr_wdata,
    // The op just presented was an override, not the core's.  Announced with
    // op_present, for boot_hold to follow what the bus actually carried.
    output wire        op_ovr,

    // To the pins, via the master top.
    output wire  [15:0] addr_drive,
    output wire         rw_drive,       // 1 = read, as on the bus
    output wire  [7:0]  data_drive,
    output wire         addr_rw_oe,
    output wire         data_oe,
    output wire         dma_assert,     // 1 = pull DMA' low

    // SYNC for the cycle being driven, held stable across it.
    //
    // WHY THIS EXISTS.  The Apple's SYNC line is the real 6502's output, and
    // asserting DMA' disconnects that chip - so while we master, the pin reads
    // zero for every cycle of the capture and instruction boundaries are simply
    // not in the trace.  A recorded bus without them cannot be decoded: an
    // opcode fetch and an operand read look identical.
    //
    // The core knows, so the card can say.  This is the SAME signal the core
    // will drive onto the real SYNC line when the card moves from a slot into
    // the CPU socket; the slot has nowhere to carry it, so it takes a shorter
    // route.  Logically exact, electrically absent, and flagged as such out to
    // the trace file's header - see apple_bus_read's sync_override and the
    // host's kFlagSyncSynth.
    output wire         drv_sync,

    // Visibility, for a status register or a testbench.
    output logic        driving          // a bus cycle is being driven
);

    // ---- phi0 edges, from the reader's synchronised copy ---------------------
    logic prev_phi0;
    wire  rise = phi0_sync && !prev_phi0;
    wire  fall = !phi0_sync && prev_phi0;

    // ---- two delay lines, several taps each ---------------------------------
    logic [T_PRESENT:0] fall_pipe;
    logic [T_CYCEN:0]   rise_pipe;

    wire t_present = fall_pipe[T_PRESENT];
    wire t_emit    = rise_pipe[T_EMIT];
    wire t_din     = rise_pipe[T_DIN];
    wire t_cycen   = rise_pipe[T_CYCEN];

    // ---- the presented op ---------------------------------------------------
    // What the bus is being shown this cycle, and the only thing the pins see.
    logic [15:0] drv_addr;
    logic        drv_rw;
    logic [7:0]  drv_dout;
    logic        drv_sync_q;
    logic        drv_ovr;         // this cycle is the override's, not the core's

    // The data bus is ours only inside the emit window, and only on a write.
    logic emit_window;

    // PARKED: a read of $0000.  Not released - see the header - and not an
    // arbitrary address either: $0000 is RAM on every Apple II, so a parked
    // read disturbs nothing even if something downstream decodes it.
    localparam logic [15:0] PARK_ADDR = 16'h0000;

    assign drv_sync   = drv_sync_q;
    assign addr_drive = drv_addr;
    assign rw_drive   = drv_rw;
    // On a claimed read the peripheral's byte goes out in the write data's
    // window; R/W stays a READ, because it is one - the machine's write strobe
    // must not fire, only its bus carry the byte.
    assign data_drive = drv_rw ? slot_rd_data : drv_dout;

    assign addr_rw_oe = master_active;
    assign data_oe    = master_active && emit_window &&
                        (!drv_rw || slot_rd_claim);
    assign dma_assert = master_active;

    assign op_addr  = drv_addr;
    assign op_rw    = drv_rw;
    assign op_wdata = drv_dout;
    assign op_ovr   = drv_ovr;

    always_ff @(posedge clk) begin
        if (rst) begin
            prev_phi0   <= 1'b0;
            fall_pipe   <= '0;
            rise_pipe   <= '0;
            drv_addr    <= PARK_ADDR;
            drv_rw      <= 1'b1;
            drv_dout    <= 8'd0;
            drv_sync_q  <= 1'b0;
            drv_ovr     <= 1'b0;
            emit_window <= 1'b0;
            cyc_en      <= 1'b0;
            cpu_din     <= 8'd0;
            driving     <= 1'b0;
            op_present  <= 1'b0;
            op_commit   <= 1'b0;
        end else begin
            prev_phi0 <= phi0_sync;
            fall_pipe <= {fall_pipe[T_PRESENT-1:0], fall};
            rise_pipe <= {rise_pipe[T_CYCEN-1:0],   rise};

            cyc_en <= 1'b0;

            // One fabric cycle after t_present, so a consumer clocked on this
            // pulse reads the drv_* registers it announces, not their
            // predecessors.  op_commit needs no such delay: nothing it
            // announces is being latched on the same edge.
            op_present <= master_active && t_present;
            op_commit  <= 1'b0;

            if (!master_active) begin
                // Not ours.  Park everything so that taking the bus starts from
                // a defined state rather than from whatever the last session
                // left staged.
                drv_addr    <= PARK_ADDR;
                drv_rw      <= 1'b1;
                drv_sync_q  <= 1'b0;
                drv_ovr     <= 1'b0;
                emit_window <= 1'b0;
                driving     <= 1'b0;
            end else begin
                // Present.  This is the only place drv_* changes, which is the
                // whole point: one stable value per bus cycle, anchored to the
                // cycle that samples it.
                if (t_present) begin
                    // An override is never a SYNC: it is not an instruction,
                    // and the trace must not decode it as one.
                    drv_addr    <= ovr_en ? ovr_addr  : cpu_addr;
                    drv_rw      <= ovr_en ? ovr_rw    : cpu_rw;
                    drv_dout    <= ovr_en ? ovr_wdata : cpu_dout;
                    drv_sync_q  <= ovr_en ? 1'b0      : cpu_sync;
                    drv_ovr     <= ovr_en;
                    emit_window <= 1'b0;      // release the data bus
                    driving     <= 1'b1;
                end

                if (t_emit)  emit_window <= 1'b1;
                if (t_din)   cpu_din     <= data_sync;
                if (t_din)   op_commit   <= 1'b1;
                // The core advances only through cycles that were its own.
                if (t_cycen && !drv_ovr) cyc_en <= 1'b1;
            end
        end
    end

endmodule
