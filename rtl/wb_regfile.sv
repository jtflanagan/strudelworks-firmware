`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// wb_regfile - the card's control registers, as a Wishbone B4 slave.
//
// WHY A SECOND WISHBONE AND NOT THE DDR3 ONE.  The DDR3 bus is 128 bits wide and
// its address is a BURST INDEX, not a byte address - one Wishbone word is one
// DDR3 burst (see docs/DDR3_USAGE.md).  That shape is right for bulk memory and
// wrong for control registers, which want 32 bits and a byte address.  So this
// is a separate 32-bit Wishbone instance rather than a decode off the DDR3 bus:
// same protocol, different geometry, and neither distorts the other.
//
// They stay independently addressable because they are in disjoint regions of
// the host-visible 32-bit address space:
//
//   0x0000_0000 .. 0x0FFF_FFFF   DDR3    (2^24 bursts x 16 bytes = 256 MB)
//   0x8000_0000 .. 0x8000_FFFF   registers
//
// so one address bit tells them apart and neither has to know the other exists.
//
// Registers are 32 bits, word aligned.  A read of an unimplemented address
// returns zero and acks; a write to a read-only or unimplemented address is
// accepted and discarded.  Neither errs, deliberately: the host discovers what
// exists by reading it, and an ERR on this bus would have to be plumbed all the
// way back through the message layer to say something the value already says.
//
// TIMING: single-cycle ack, never stalls.  A register file that made the host
// wait would be measuring nothing but itself.
//////////////////////////////////////////////////////////////////////////////////
module wb_regfile #(
    // Stamped by build/build.sh through build.tcl's -generic.  Zero means the
    // bitstream was built without a stamp - an interactive GUI build - and the
    // host is expected to say "unstamped" rather than render it as a date.
    parameter integer BUILD_DATE = 0,   // YYYYMMDD
    parameter integer BUILD_TIME = 0,   // HHMMSS

    // Top half of the byte address that selects this block.  The full 32-bit
    // address arrives here and the region is decoded HERE rather than upstream,
    // so that an access outside it still acks: a decode that simply withheld
    // ack would hang the bridge waiting for a reply that is never coming, and
    // the host would see a dead link rather than a bad address.
    parameter [15:0] REGION = 16'h8000,

    // 1 only in a bitstream whose top can actually assert DMA' and drive the
    // Apple bus.  The register below exists in EVERY build so the host reads it
    // the same way everywhere; this is how the host tells a snooper from a
    // master, and it is what stops a snoop build ever latching itself into
    // "the soft CPU is driving" when nothing in it can drive.
    parameter bit CAN_MASTER = 1'b0
) (
    input  wire            clk,
    input  wire            rst,

    // Synchronised RES', ACTIVE LOW, from apple_bus_read.
    input  wire            apple_res_sync,

    // Which CPU owns the bus.  A master top drives DMA' and the address/data
    // enables from this; see docs/BUS_MASTER.md.
    output wire            cpu_source_active,

    // Which slot the on-card Mockingboard answers as; 0 keeps it out of the
    // machine entirely.  Latched the same way CPU_SOURCE is - see below.
    output wire [2:0]      mb_slot_active,

    // Wishbone B4 classic, 32-bit.
    input  wire            wb_cyc,
    input  wire            wb_stb,
    input  wire            wb_we,
    input  wire [31:0]     wb_adr,     // full byte address
    input  wire [31:0]     wb_dat_w,
    input  wire [3:0]      wb_sel,
    output logic           wb_ack,
    output wire            wb_stall,
    output logic [31:0]    wb_dat_r
);

    // Word index within the region: the low two bits are byte lanes and are not
    // decoded, so a misaligned address reads the word containing it rather than
    // erring - the same forgiving treatment as an unknown address.
    wire        in_region = (wb_adr[31:16] == REGION);
    wire [13:0] word      = wb_adr[15:2];

    // ---- the map ------------------------------------------------------------
    // Adding a register is one localparam and one case arm.  Keep the numbering
    // dense and never reuse a retired number: a host built against an older map
    // reading a recycled address gets a plausible wrong answer, which is worse
    // than the zero it would get from a hole.
    localparam [13:0] R_BUILD_DATE = 'd0;   // 0x8000_0000, RO
    localparam [13:0] R_BUILD_TIME = 'd1;   // 0x8000_0004, RO
    localparam [13:0] R_CPU_SOURCE = 'd2;   // 0x8000_0008, RW in bit 0
    localparam [13:0] R_MB_SLOT    = 'd3;   // 0x8000_000C, RW in bits 2:0

    // ---- CPU_SOURCE ---------------------------------------------------------
    //
    //   [0]      desired   RW   0 = the native 6502 (default), 1 = the soft core
    //   [8]      active    RO   what was latched at the last RES' assertion
    //   [16]     capable   RO   this bitstream can actually master the bus
    //   [31:24]  latches   RO   RES' assertions seen, wrapping
    //
    // WHY IT LATCHES ON RES' AND NOT ON THE WRITE.  Handing the bus over is a
    // transition with no good moment in the middle of a running machine: the
    // real CPU is mid-instruction, the soft core is not where the real one was,
    // and whatever mess the DMA' transition makes lands in software's lap.
    //
    // A reset has no such lap to land in.  The Apple's own RESET is held for a
    // long time by the motherboard - far longer than the changeover - and
    // everything after it starts from the vector, so a switch made anywhere
    // inside that window is invisible by construction.  So the write only ever
    // sets an INTENTION, and the next reset is what acts on it.
    //
    // The falling edge is the assertion, RES' being active low.  Latching on
    // the edge rather than on the level keeps it to exactly one changeover per
    // reset however long the reset is held, and however much the line bounces -
    // which it does, being a switch with nothing debouncing it (see DERISK).
    //
    // `latches` is what lets the host tell whether its write has taken effect
    // yet: write desired, read back, and if the count has not moved then no
    // reset has happened and `active` is still the old answer.  Without it the
    // host cannot distinguish "not reset yet" from "reset and ignored".
    logic       cpu_src_desired;
    logic       cpu_src_active;
    logic [7:0] cpu_src_latches;
    logic       res_prev;

    // Falling edge of an active-low line is the assertion.
    wire res_assert = res_prev && !apple_res_sync;

    assign cpu_source_active = cpu_src_active;

    always_ff @(posedge clk) begin
        if (rst) begin
            cpu_src_desired <= 1'b0;      // the native CPU keeps the bus
            cpu_src_active  <= 1'b0;
            cpu_src_latches <= 8'd0;
            res_prev        <= 1'b1;      // idle high: no phantom assert at rst
        end else begin
            res_prev <= apple_res_sync;
            if (res_assert) begin
                // Forced to 0 when this bitstream cannot drive.  The readback
                // then tells the truth - desired reads back as written, active
                // stays 0, and `capable` says why - rather than a snoop build
                // reporting itself as the machine's CPU.
                cpu_src_active  <= CAN_MASTER ? cpu_src_desired : 1'b0;
                cpu_src_latches <= cpu_src_latches + 8'd1;
            end
            if (wr_cpu_source) cpu_src_desired <= wb_dat_w[0];
        end
    end

    wire [31:0] cpu_source_rd = {cpu_src_latches, 7'd0, CAN_MASTER,
                                 7'd0, cpu_src_active, 7'd0, cpu_src_desired};

    // ---- MB_SLOT ------------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the Mockingboard answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //
    // The same reset-latched contract as CPU_SOURCE, for the same reason
    // scaled down: the slot scan happens at boot, and a card that appears (or
    // moves) in the middle of a running machine is a card the software has
    // already decided about.  A reset is when the decision is re-made, so a
    // reset is when the answer changes.  Gated by CAN_MASTER because the
    // Mockingboard can only put a byte on the bus from a mastering build; in
    // a snoop build `desired` reads back as written and `active` stays 0,
    // which is the register telling the truth rather than erring.
    logic [2:0] mb_slot_desired;
    logic [2:0] mb_slot_active_q;

    assign mb_slot_active = mb_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mb_slot_desired <= 3'd0;      // no Mockingboard until asked for
            mb_slot_active_q <= 3'd0;
        end else begin
            if (res_assert) begin
                mb_slot_active_q <= CAN_MASTER ? mb_slot_desired : 3'd0;
            end
            if (wr_mb_slot) mb_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] mb_slot_rd = {21'd0, mb_slot_active_q, 5'd0, mb_slot_desired};

    assign wb_stall = 1'b0;

    wire access = wb_cyc && wb_stb;

    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack   <= 1'b0;
            wb_dat_r <= 32'd0;
        end else begin
            // One ack per strobe, and only ever one cycle wide.
            wb_ack <= access && !wb_ack;

            if (access && !wb_ack) begin
                if (!in_region) begin
                    wb_dat_r <= 32'd0;
                end else begin
                    case (word)
                        R_BUILD_DATE: wb_dat_r <= BUILD_DATE[31:0];
                        R_BUILD_TIME: wb_dat_r <= BUILD_TIME[31:0];
                        R_CPU_SOURCE: wb_dat_r <= cpu_source_rd;
                        R_MB_SLOT:    wb_dat_r <= mb_slot_rd;
                        default:      wb_dat_r <= 32'd0;
                    endcase
                end
            end
        end
    end

    // Writes.  One strobe per access, on the same edge the read uses, so a
    // write and its ack are the same single cycle a read is.  A write to a
    // read-only or unimplemented address lands nowhere and still acks, which is
    // the same forgiveness the read side gives an unknown address.
    //
    // wb_sel is not honoured: this file is whole-words-only by construction
    // (reg_bridge ties it to 4'hF), and a byte-enabled control register would
    // be a lie about what the host can express.
    wire wr_cpu_source = access && !wb_ack && in_region && wb_we &&
                         (word == R_CPU_SOURCE);
    wire wr_mb_slot    = access && !wb_ack && in_region && wb_we &&
                         (word == R_MB_SLOT);

    // wb_adr[1:0] are byte lanes within a word and are deliberately not decoded.
    wire _unused_ok = &{1'b0, wb_dat_w[31:1], wb_sel, wb_adr[1:0], 1'b0};

endmodule
