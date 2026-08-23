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
    parameter [15:0] REGION = 16'h8000
) (
    input  wire            clk,
    input  wire            rst,

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
                        default:      wb_dat_r <= 32'd0;
                    endcase
                end
            end
        end
    end

    // Writes: both registers here are read-only, so there is nothing to store
    // yet and wb_we is accepted and dropped.  The signals are consumed so that
    // an unused-input warning does not have to be silenced later, and so the
    // first writable register is a case arm rather than a rewiring job.
    // wb_adr[1:0] are byte lanes within a word and are deliberately not decoded.
    wire _unused_ok = &{1'b0, wb_we, wb_dat_w, wb_sel, wb_adr[1:0], 1'b0};

endmodule
