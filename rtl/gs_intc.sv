`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_intc - the IIgs's interrupt controller: $C023, $C032, $C041, $C046, $C047.
//
// THE REFERENCE IS KEGS's moremem.c (the $C023/$C032/$C041/$C046/$C047 cases)
// and its IRQ_PENDING_* bits in defc.h, transcribed rather than reasoned out.
//
// TWO REGISTER PAIRS, AND THEY ARE NOT THE SAME MACHINE.  The IIgs has two
// separate interrupt sources with two separate status registers, and the ROM
// uses both:
//
//   $C041 INTEN  / $C046 INTFLAG / $C047 CLRVBLINT - the Mega II's: the VBL
//       interrupt and the quarter-second interrupt, plus the mouse's move and
//       switch bits.  $C046 is READ-AND-MODIFY: reading it copies bit 7 down
//       into bit 6 and clears bit 7, which is how the ROM tells "an interrupt
//       happened" from "one is happening".  $C047 clears both timer
//       interrupts, on a READ OR A WRITE - it is a strobe, and the read
//       returns zero.
//
//   $C023 VGCINT / $C032 SCANINT - the video graphics controller's: the
//       one-second interrupt and the scan-line interrupt.  Bits 1 and 2 are
//       the ENABLES, bits 5 and 6 the STATUS, and bit 7 is "any of mine is
//       pending" - composed, never written.  $C032 CLEARS by writing a ZERO
//       to the status bit: a write with bit 6 clear clears the one-second
//       interrupt, bit 5 clear the scan line.  That inverted sense is the
//       reference's, not a guess (moremem.c:1676).
//
// THE TIMERS RUN IN VIRTUAL TIME, from `frame_tick` - one pulse per video
// frame, from rtl/vbeam.sv, which already counts the machine's own cycles
// (docs/VIRTUAL_TIME.md).  So an accelerated program sees the same number of
// VBLs per program-second that a 1x one does, which is the rule the whole
// design keeps.  A quarter-second is 15 frames and a second is 60; KEGS uses
// the same frame counting.
//
// WHAT IS NOT HERE YET: the scan-line interrupt's actual trigger, which needs
// the 200-bit side copy of the SCB bit-6 column snooped from writes landing in
// $E1/$9D00-$9DC7 (docs/GS.md, the `fb_sim` tap pattern).  The enable, the
// status bit and the clear are all here and behave; nothing sets it.  The ADB
// and DOC sources arrive with their own modules.
//////////////////////////////////////////////////////////////////////////////////
module gs_intc (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,       // synchronised RES', ACTIVE LOW

    // The registered op and its retire.
    input  wire [7:0]  op_lo,
    input  wire        op_rw,
    input  wire [7:0]  op_wdata,
    input  wire        act,

    output logic [7:0] rd_byte,

    // One pulse per video frame, in the machine's own time (rtl/vbeam.sv).
    input  wire        frame_tick,

    // The other sources, each already gated by its own enable.
    input  wire        irq_adb,
    input  wire        irq_scan,       // the scan-line comparator, when it exists

    // The one line into the core.
    output wire        irq
);

    // $C041's enables (defc.h:262-266).
    localparam [7:0] C041_EN_25SEC  = 8'h10;
    localparam [7:0] C041_EN_VBL    = 8'h08;
    localparam [7:0] C041_EN_SWITCH = 8'h04;
    localparam [7:0] C041_EN_MOVE   = 8'h02;
    localparam [7:0] C041_EN_MOUSE  = 8'h01;

    logic [7:0] c041;               // INTEN, five bits wide
    logic [7:0] c046;               // INTFLAG
    logic [7:0] c023;               // VGCINT

    logic p_vbl, p_25sec;           // the Mega II's two pending flags
    logic p_1sec, p_scan;           // the VGC's two

    // Frames since the last quarter-second and second.  KEGS counts frames
    // for both, and so does this: 15 frames is a quarter of a second at
    // 59.92 Hz, 60 frames is one.
    logic [5:0] frame_ctr;

    // ---- reads ---------------------------------------------------------------
    // $C046's read is destructive - bit 7 moves down to bit 6 and clears - so
    // the composed value is named once here and the side effect applied on the
    // commit below, from the same expression.
    wire [7:0] c046_rd = c046;
    wire [7:0] c023_rd = c023 | ((p_1sec || p_scan) ? 8'h80 : 8'h00);

    always_comb begin
        case (op_lo)
            8'h23:   rd_byte = c023_rd;
            8'h41:   rd_byte = c041;
            8'h46:   rd_byte = c046_rd;
            8'h47:   rd_byte = 8'h00;   // a strobe; the read's byte is zero
            default: rd_byte = 8'h00;
        endcase
    end

    // The line into the core.  Each source is ANDed with its own enable where
    // the enable lives: the Mega II's two in $C041, the VGC's two in $C023.
    assign irq = (p_vbl   && (c041 & C041_EN_VBL)   != 8'd0) ||
                 (p_25sec && (c041 & C041_EN_25SEC) != 8'd0) ||
                 (p_1sec  && (c023[2])) ||
                 (p_scan  && (c023[1])) ||
                 irq_adb;

    wire wr = act && !op_rw;
    wire rd = act &&  op_rw;

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            c041 <= 8'd0;
            c046 <= 8'd0;
            c023 <= 8'd0;
            p_vbl <= 1'b0; p_25sec <= 1'b0; p_1sec <= 1'b0; p_scan <= 1'b0;
            frame_ctr <= 6'd0;
        end else begin
            // ---- the timers, in the machine's own time ----------------------
            if (frame_tick) begin
                if (frame_ctr == 6'd59) frame_ctr <= 6'd0;
                else                    frame_ctr <= frame_ctr + 6'd1;

                // Every frame: the VBL interrupt, if enabled.
                if ((c041 & C041_EN_VBL) != 8'd0) begin
                    p_vbl <= 1'b1;
                    c046[3] <= 1'b1;        // VBL int in INTFLAG
                end
                // Every fifteenth: the quarter-second.
                if (frame_ctr[3:0] == 4'd14 && (c041 & C041_EN_25SEC) != 8'd0) begin
                    p_25sec <= 1'b1;
                    c046[4] <= 1'b1;        // 1/4-second int in INTFLAG
                end
                // Every sixtieth: the VGC's one-second, if enabled.
                if (frame_ctr == 6'd59 && c023[2]) begin
                    p_1sec <= 1'b1;
                    c023[6] <= 1'b1;
                end
            end

            if (irq_scan && c023[1]) begin
                p_scan  <= 1'b1;
                c023[5] <= 1'b1;
            end

            // ---- the ops ----------------------------------------------------
            case (op_lo)
                8'h23: if (wr) begin
                    // Only the four low bits are the CPU's; the status bits
                    // above them are the controller's (moremem.c:1582).
                    c023[3:0] <= op_wdata[3:0];
                    // Disabling a source drops its pending flag with it.
                    if (!op_wdata[2]) begin p_1sec <= 1'b0; c023[6] <= 1'b0; end
                    if (!op_wdata[1]) begin p_scan <= 1'b0; c023[5] <= 1'b0; end
                end

                8'h32: if (wr) begin
                    // SCANINT clears by writing a ZERO to the status bit.
                    if (!op_wdata[6]) begin p_1sec <= 1'b0; c023[6] <= 1'b0; end
                    if (!op_wdata[5]) begin p_scan <= 1'b0; c023[5] <= 1'b0; end
                end

                8'h41: if (wr) begin
                    c041 <= op_wdata & 8'h1F;
                    // Turning an enable off drops what it had pending.
                    if ((op_wdata & C041_EN_VBL)   == 8'd0) begin p_vbl   <= 1'b0; c046[3] <= 1'b0; end
                    if ((op_wdata & C041_EN_25SEC) == 8'd0) begin p_25sec <= 1'b0; c046[4] <= 1'b0; end
                end

                // $C046 ignores writes; a READ copies bit 7 down into bit 6
                // and clears bit 7 (moremem.c:1152).
                8'h46: if (rd) c046 <= (c046 & 8'hBF) | ((c046 & 8'h80) >> 1);

                // $C047 is a strobe: read or write, it clears both Mega II
                // timer interrupts and their INTFLAG bits.
                8'h47: if (rd || wr) begin
                    p_vbl <= 1'b0; p_25sec <= 1'b0;
                    c046 <= c046 & 8'hE7;
                end

                default: ;
            endcase
        end
    end
endmodule
