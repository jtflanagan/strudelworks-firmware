`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// apple_bus_read - sample the Apple II bus, and nothing else.
//
// The sampling half of AppleTini v5's apple_bus_wrapper.sv, extracted.  What was
// deliberately LEFT BEHIND is most of that module: driving data/addr/RW,
// asserting INH/IRQ/RDY/DMA/NMI/RES, the bus_emit state machine, the INH
// deadline, and the soft-switch strobe.  This snooper watches; it does not
// participate.
//
// That is enforced structurally rather than by discipline: the Apple pins here
// are declared INPUT, not inout, so there is no path by which this module could
// drive the bus even if something later asked it to.  The level-shifter
// direction pins are tied to "towards the FPGA" for the same reason.
//
// WHAT IS CARRIED OVER VERBATIM, and must not be "cleaned up":
//
//   * the 3-deep synchronisers on every pin (2 ASYNC_REG stages + the output
//     register in synchronizer.sv)
//   * the sample points, counted in 100 MHz cycles from a phi0 edge:
//       address and control   20 cycles after phi0 FALLING
//       data                  45 cycles after phi0 RISING
//
// Those constants are empirical - they come from a design that ran in real
// machines - and they are only meaningful at a 100 MHz clock and an Apple II
// phi0 of roughly 1.023 MHz (~98 cycles).  Changing the clock, the synchroniser
// depth, or the taps changes where on the bus cycle the sample lands.
//
// They are CORRECT for the hardware in scope, not a known gap: this is a slot
// card in a legacy Apple II, and that is the only target until a new hardware
// spin exists.  A IIgs at 2.8 MHz would need them re-derived, but the IIgs and
// the 65816 are out of scope until then - see docs/DERISK.md.  Do not "fix"
// these for a machine this card cannot be plugged into.
//
// They also describe when the CPU PRESENTS its signals.  Driving the bus during
// DMA needs the setup and hold the rest of the machine expects, which is a
// different figure and is not derivable from these.
//
// One event is produced per phi0 cycle, at the data sample, in the v5 wire
// format so existing analysis tooling reads these dumps:
//
//   [15:0]  addr        [19:16] {m2b0, m2sel, res, rw}
//   [27:20] data        [31:28] 0xF tag
//////////////////////////////////////////////////////////////////////////////////

module apple_bus_read #(
    // Cycles after the phi0 edge at which each half of the cycle is sampled.
    parameter integer ADDR_TAP = 19,   // after phi0 falling
    parameter integer DATA_TAP = 44    // after phi0 rising
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,

    // Apple bus.  INPUTS ONLY - see the note above.
    input  wire [7:0]  apple_data_pin,
    input  wire [15:0] apple_addr_pin,
    input  wire        apple_rw_pin,
    input  wire        apple_phi0_pin,
    input  wire        apple_m2sel_pin,
    input  wire        apple_m2b0_pin,
    input  wire        apple_inh_pin,
    input  wire        apple_res_pin,
    input  wire        apple_irq_pin,
    input  wire        apple_rdy_pin,
    input  wire        apple_dma_pin,

    // The level shifters are NOT ours.  Each top drives tini_oe / the two
    // direction pins itself, because their direction is exactly the thing that
    // differs between watching the bus and driving it - and this module has no
    // opinion, having no way to drive either way.

    // SYNC SUBSTITUTION, for a master build only.
    //
    // The SYNC bit in the event word is the real 6502's, and a card that has
    // asserted DMA' has disconnected that chip - so while it drives, the pin
    // reads zero and the trace loses its instruction boundaries entirely.  An
    // opcode fetch and an operand read then look the same, and nothing
    // downstream can decode the capture.
    //
    // With `en` high the driving core's own SYNC is recorded instead.  The bit
    // is then LOGICALLY exact and electrically absent: it is the same signal
    // the core will drive onto the real SYNC line once the card sits in the CPU
    // socket rather than in a slot, arriving here by a shorter route because
    // the slot has no way to carry it.  Not a guess, and not a measurement.
    //
    // The distinction still gets recorded, because this module reports what it
    // observed and a reader is entitled to know which bits those are: the host
    // flags it in the trace file's header.  A watching build ties `en` low and
    // nothing here changes.
    input  wire         sync_override,
    input  wire         sync_override_en,

    // DATA SUBSTITUTION, likewise for a master build only.  While
    // data_override_en, the event's data byte is data_override rather than
    // the wire's: a key the host pressed, which rtl/kbd_inject.sv puts into
    // the soft core's din on the same tap this samples.  The trace then shows
    // what the CPU read, which is the property the SYNC case established.  A
    // watching build ties both low.
    input  wire [7:0]   data_override,
    input  wire         data_override_en,

    // one event per phi0 cycle
    output logic [31:0] ev_data,
    output logic        ev_valid,
    // ...and the same pulse UNGATED: one per phi0 cycle at the data sample
    // whether or not anyone is capturing.  rtl/vbl_lock.sv counts the
    // machine's cycles on it, so its counter never stops with the capture
    // and never has to be resynchronised after one.  On the clock this is
    // high, ev_valid (if enabled) carries the same cycle's event.
    output logic        data_tick,

    // for the UART report: is there a machine out there at all?
    // Synchronised RES', ACTIVE LOW, straight off the pin.  An output rather
    // than only a bit in the event word because the CPU changeover is latched
    // on its falling edge and wants it live, not a capture cycle later.
    //
    // This does not make the reader a participant: it still drives nothing on
    // the Apple bus, which is the property that matters.
    output wire         res_sync,

    // Synchronised IRQ', likewise active low, for a master top to feed the
    // soft core.  A watching build leaves it unconnected.
    output wire         irq_sync,


    // Synchronised phi0 and data, likewise.  A master top needs both live: phi0
    // to place its own taps, and data to be the CPU's `din` on a read.  Sharing
    // the synchronisers rather than adding a second set is not only cheaper -
    // two synchronisers on one pin are two answers to the same question, and
    // they disagree exactly when it matters.
    output wire         phi0_sync,
    output wire [7:0]   data_sync,

    output logic        phi0_active
);


    // ---- synchronise ---------------------------------------------------------
    wire [7:0]  data_clean;
    wire [15:0] addr_clean;
    wire [8:0]  misc_clean;

    synchronizer #(.WIDTH (8))  u_data_sync (
        .clk (clk), .rst (rst), .in (apple_data_pin), .out (data_clean));

    synchronizer #(.WIDTH (16)) u_addr_sync (
        .clk (clk), .rst (rst), .in (apple_addr_pin), .out (addr_clean));

    // Bit order carried over from v5 so the taps below read the same as there.
    synchronizer #(.WIDTH (9))  u_misc_sync (
        .clk (clk), .rst (rst),
        .in  ({apple_rw_pin, apple_phi0_pin, apple_m2sel_pin,
               apple_m2b0_pin, apple_inh_pin, apple_res_pin,
               apple_irq_pin, apple_rdy_pin, apple_dma_pin}),
        .out (misc_clean));

    wire phi0  = misc_clean[7];
    wire rw    = misc_clean[8];
    wire m2sel = misc_clean[6];
    wire m2b0  = misc_clean[5];
    wire res   = misc_clean[3];
    assign res_sync  = res;
    assign irq_sync  = misc_clean[2];
    assign phi0_sync = phi0;
    assign data_sync = data_clean;

    // ---- phi0 edges ----------------------------------------------------------
    logic prev_phi0 = 1'b0;
    wire  data_edge =  phi0 && !prev_phi0;      // rising
    wire  addr_edge = !phi0 &&  prev_phi0;      // falling

    // ---- delay lines, one tap each -------------------------------------------
    logic [ADDR_TAP:0] addr_pipe = '0;
    logic [DATA_TAP:0] data_pipe = '0;

    wire addr_snap = addr_pipe[ADDR_TAP];
    wire data_snap = data_pipe[DATA_TAP];

    // ---- sampled fields ------------------------------------------------------
    logic [15:0] addr_q = 16'd0;
    logic [3:0]  ctl_q  = 4'd0;                 // {m2b0, m2sel, res, rw}

    // ---- liveness ------------------------------------------------------------
    // A machine that is off, or a card on the bench, gives no phi0 edges.  Time
    // out well beyond one bus cycle (~980 ns) so this reports the bus, not the
    // sampling.
    localparam integer LIVE_TICKS = 1_000_000;  // 10 ms at 100 MHz
    logic [19:0] live_cnt = '0;

    always_ff @(posedge clk) begin
        if (rst) begin
            prev_phi0   <= 1'b0;
            addr_pipe   <= '0;
            data_pipe   <= '0;
            addr_q      <= 16'd0;
            ctl_q       <= 4'd0;
            ev_data     <= 32'd0;
            ev_valid    <= 1'b0;
            data_tick   <= 1'b0;
            live_cnt    <= '0;
            phi0_active <= 1'b0;
        end else begin
            prev_phi0 <= phi0;
            ev_valid  <= 1'b0;
            data_tick <= data_snap;

            addr_pipe <= {addr_pipe[ADDR_TAP-1:0], addr_edge};
            data_pipe <= {data_pipe[DATA_TAP-1:0], data_edge};

            if (addr_snap) begin
                addr_q <= addr_clean;
                ctl_q  <= {m2b0, sync_override_en ? sync_override : m2sel, res, rw};
            end

            if (data_snap && enable) begin
                ev_data  <= {4'hf, data_override_en ? data_override : data_clean,
                             ctl_q, addr_q};
                ev_valid <= 1'b1;
            end

            if (data_edge || addr_edge) begin
                live_cnt    <= '0;
                phi0_active <= 1'b1;
            end else if (live_cnt == LIVE_TICKS[19:0]) begin
                phi0_active <= 1'b0;
            end else begin
                live_cnt <= live_cnt + 1'b1;
            end
        end
    end

endmodule
