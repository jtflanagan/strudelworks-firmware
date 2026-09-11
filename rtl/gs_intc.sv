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
// THE TIMERS COUNT `frame_tick` - one pulse per video frame from
// rtl/vbeam.sv.  On the IIgs that beam runs at the BUS's cadence, wall time,
// whatever the 65816's speed (user decision 2026-09-11, rtl/master_top.sv
// "the beam every consumer takes"): a real accelerator cannot speed up the
// VGC, so its VBL, its quarter-second and one-second interrupts and the
// toolbox's ticks come at wall speed, and double-click works at any ratio.
// A quarter-second is 15 frames and a second is 60; KEGS uses the same
// frame counting.
//
// WHAT IS NOT HERE YET: the scan-line interrupt's actual trigger, which needs
// the 200-bit side copy of the SCB bit-6 column snooped from writes landing in
// $E1/$9D00-$9DC7 (docs/GS.md, the `fb_sim` tap pattern).  The enable, the
// status bit and the clear are all here and behave; nothing sets it.  The ADB
// source arrives with its own module; the DOC's is here (irq_doc).
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
    // The Ensoniq's (rtl/gs_doc.sv).  IT HAS NO ENABLE AND NO INTFLAG BIT:
    // the DOC's interrupt is not one of the Mega II's or the VGC's, it goes
    // to the processor through the FPI, and the enable that gates it is the
    // oscillator's own control-register bit 3.  KEGS's add_irq(IRQ_PENDING_DOC)
    // ORs it into the pending mask and nothing else; so does this.
    input  wire        irq_doc,

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
    wire irq_now = (p_vbl   && (c041 & C041_EN_VBL)   != 8'd0) ||
                   (p_25sec && (c041 & C041_EN_25SEC) != 8'd0) ||
                   (p_1sec  && (c023[2])) ||
                   (p_scan  && (c023[1])) ||
                   irq_adb || irq_doc;

    // AND IT IS A REGISTER.  Combinational, this OR put the ADB micro's state
    // machine, its own enables and master_top's mux in front of the core's
    // take_int - which decides the microcode address in the fetch cycle - and
    // the first rung-4c build failed timing on exactly that path: sixteen
    // levels, seven of its nine nanoseconds in routing across three modules
    // (docs/GS.md rung 4c).  A flop here takes the whole generation cone out
    // of the core's cycle.  The clock of latency is invisible: the core
    // samples interrupts at instruction boundaries, a hundred clocks apart,
    // and the IIe's pin IRQ already arrives through a synchroniser - this
    // makes the GS's line the same shape.
    logic irq_q;
    always_ff @(posedge clk) irq_q <= (rst || !res_sync) ? 1'b0 : irq_now;
    assign irq = irq_q;

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
                    // Disabling an interrupt drops its REQUEST (KEGS
                    // remove_irq) and nothing else: INTFLAG's bit stays
                    // until $C047.  The ROM's self-test (test 11) clears
                    // $C041 inside its handler and then reads $C046 for
                    // the bit - clearing it here failed that test on
                    // hardware (docs/GS.md rung 4's gate, 2026-09-11).
                    if ((op_wdata & C041_EN_VBL)   == 8'd0) p_vbl   <= 1'b0;
                    if ((op_wdata & C041_EN_25SEC) == 8'd0) p_25sec <= 1'b0;
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
