`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ay_pair - the two AY-3-8913s behind one VIA, on the card: the chips, with
// their sound outputs left unconnected.
//
// The AYs' sound is synthesised on the host from the VIA port writes in the
// stream (strudelworks-host src/mb_audio.cpp); nothing here makes a sound.
// But an AY's registers can be READ BACK through the VIA - port A set to
// input, port B given the PSG READ function, and the chip drives its selected
// register onto the port - and software that looks for a chip does exactly
// that: mb-audit writes the tone registers and reads them back, and a chip
// that reads back nothing is "missing".  So the chips are here: two YM2149
// cores (rtl/YM2149.sv, a2fpga's, by way of aty) per VIA, their CHANNEL
// outputs open so the generators prune away and what is left is the
// register file and the bus protocol - the chip exactly as the bus sees it.
//
// Around them, the Phasor's GAL, ported from aty's mockingboard.sv (which
// follows AppleWin's GH#1192 notes from the real card): in the Phasor's
// native and Echo+ modes (`selects`) port B's PB4 selects the first AY and
// PB3 the second, active low; a Mockingboard - or a Phasor in Mockingboard
// mode - has the first wired and nothing on the second.  In native mode
// (`native`) the GAL's cross-effects: a LATCH to the first AY deselects the
// second, a LATCH to the second selects both (and both take the address), a
// READ/WRITE to the first also reaches a selected second.  RESET' (PB2) goes
// straight to both chips.  A chip not driven sees an inactive bus.
//
// The pins are the VIA's OUTPUT pins: an input pin of port B floats, and a
// floating RESET' is a held reset (which is also power-on, before the driver
// sets DDRB); port A's input pins float high, which is what an undriven
// read returns (AppleWin: ORA | ~DDRA when the bus is not driven).
//////////////////////////////////////////////////////////////////////////////////
module ay_pair (
    input  wire        clk,
    input  wire        rst,          // the VIA's own reset: RES', or the card disabled

    // The VIA's ports as it drives them, and its direction registers.
    input  wire [7:0]  porta_out,
    input  wire [7:0]  ddra,
    input  wire [7:0]  portb_out,
    input  wire [7:0]  ddrb,

    input  wire        selects,      // PB4/PB3 select the chips (Phasor native or Echo+)
    input  wire        native,       // Phasor native mode: the GAL's cross-effects

    // What the VIA's port A inputs see.
    output wire [7:0]  porta_in
);

    // The pins, as the chips see them.
    wire [7:0] pins = portb_out & ddrb;
    wire [7:0] data = (porta_out & ddra) | ~ddra;
    wire       cs_a       = !pins[4];
    wire       cs_b       = !pins[3];
    wire       reset_func = !pins[2];
    wire       latch_func = pins[2] && (pins[1:0] == 2'b11);
    wire       rw_func    = pins[2] && (pins[1] ^ pins[0]);

    // The GAL's selects, from the LATCH functions (aty, AppleWin GH#1192).
    logic sel_a, sel_b;
    always_ff @(posedge clk) begin
        if (rst || !selects) begin
            sel_a <= 1'b0;
            sel_b <= 1'b0;
        end else if (reset_func) begin
            sel_a <= 1'b0;
            sel_b <= 1'b0;
        end else if (latch_func) begin
            if (cs_b) begin
                sel_a <= 1'b1;
                sel_b <= 1'b1;
            end else if (cs_a) begin
                sel_a <= 1'b1;
                sel_b <= 1'b0;
            end
        end
    end

    // Which chip the bus function reaches.
    wire drive_a_native = latch_func ? (cs_a || cs_b) : (rw_func && cs_a && sel_a);
    wire drive_b_native = latch_func ? cs_b : (rw_func && (cs_a || cs_b) && sel_b);
    wire drive_a_echo   = latch_func ? (cs_a || cs_b) : cs_a;
    wire drive_b_echo   = latch_func ? cs_b : (rw_func && (cs_b || (cs_a && sel_b)));
    wire drive_a = !selects ? 1'b1 : native ? drive_a_native : drive_a_echo;
    wire drive_b = !selects ? 1'b0 : native ? drive_b_native : drive_b_echo;

    wire [7:0] do_a, do_b;

    YM2149 u_a (
        .CLK (clk), .CE (1'b0), .RESET (rst || reset_func),
        .BDIR (drive_a ? pins[1] : 1'b0), .BC (drive_a ? pins[0] : 1'b0),
        .DI (data), .DO (do_a),
        .CHANNEL_A (), .CHANNEL_B (), .CHANNEL_C (),
        .SEL (1'b0), .MODE (1'b1), .ACTIVE (),
        .IOA_in (8'h00), .IOA_out (), .IOB_in (8'h00), .IOB_out ()
    );

    YM2149 u_b (
        .CLK (clk), .CE (1'b0), .RESET (rst || reset_func),
        .BDIR (drive_b ? pins[1] : 1'b0), .BC (drive_b ? pins[0] : 1'b0),
        .DI (data), .DO (do_b),
        .CHANNEL_A (), .CHANNEL_B (), .CHANNEL_C (),
        .SEL (1'b0), .MODE (1'b1), .ACTIVE (),
        .IOA_in (8'h00), .IOA_out (), .IOB_in (8'h00), .IOB_out ()
    );

    // A chip's DO is $FF unless it is answering a READ; two answering at
    // once (native mode, the second selected) OR together; none, high.
    assign porta_in = (drive_a && drive_b) ? (do_a | do_b)
                    : drive_a              ? do_a
                    : drive_b              ? do_b
                    :                        8'hFF;

endmodule
