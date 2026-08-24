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
// THE CORE IS LOCKED TO THE BUS by cyc_en, one pulse per phi0 cycle, which is
// the interface rtl/cpu65c02.sv was built for.  din is latched at T_DIN and is
// therefore already stable when the core samples it at T_CYCEN.
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
    output logic       cyc_en,          // one pulse per bus cycle
    output logic [7:0] cpu_din,

    // To the pins, via the master top.
    output wire  [15:0] addr_drive,
    output wire         rw_drive,       // 1 = read, as on the bus
    output wire  [7:0]  data_drive,
    output wire         addr_rw_oe,
    output wire         data_oe,
    output wire         dma_assert,     // 1 = pull DMA' low

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

    // The data bus is ours only inside the emit window, and only on a write.
    logic emit_window;

    // PARKED: a read of $0000.  Not released - see the header - and not an
    // arbitrary address either: $0000 is RAM on every Apple II, so a parked
    // read disturbs nothing even if something downstream decodes it.
    localparam logic [15:0] PARK_ADDR = 16'h0000;

    assign addr_drive = drv_addr;
    assign rw_drive   = drv_rw;
    assign data_drive = drv_dout;

    assign addr_rw_oe = master_active;
    assign data_oe    = master_active && emit_window && !drv_rw;
    assign dma_assert = master_active;

    always_ff @(posedge clk) begin
        if (rst) begin
            prev_phi0   <= 1'b0;
            fall_pipe   <= '0;
            rise_pipe   <= '0;
            drv_addr    <= PARK_ADDR;
            drv_rw      <= 1'b1;
            drv_dout    <= 8'd0;
            emit_window <= 1'b0;
            cyc_en      <= 1'b0;
            cpu_din     <= 8'd0;
            driving     <= 1'b0;
        end else begin
            prev_phi0 <= phi0_sync;
            fall_pipe <= {fall_pipe[T_PRESENT-1:0], fall};
            rise_pipe <= {rise_pipe[T_CYCEN-1:0],   rise};

            cyc_en <= 1'b0;

            if (!master_active) begin
                // Not ours.  Park everything so that taking the bus starts from
                // a defined state rather than from whatever the last session
                // left staged.
                drv_addr    <= PARK_ADDR;
                drv_rw      <= 1'b1;
                emit_window <= 1'b0;
                driving     <= 1'b0;
            end else begin
                // Present.  This is the only place drv_* changes, which is the
                // whole point: one stable value per bus cycle, anchored to the
                // cycle that samples it.
                if (t_present) begin
                    drv_addr    <= cpu_addr;
                    drv_rw      <= cpu_rw;
                    drv_dout    <= cpu_dout;
                    emit_window <= 1'b0;      // release the data bus
                    driving     <= 1'b1;
                end

                if (t_emit)  emit_window <= 1'b1;
                if (t_din)   cpu_din     <= data_sync;
                if (t_cycen) cyc_en      <= 1'b1;
            end
        end
    end

endmodule
