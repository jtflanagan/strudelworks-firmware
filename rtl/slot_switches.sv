`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// slot_switches - is $Cn00-$CnFF the slot's, right now?
//
// $Cnxx is not always slot n.  With INTCXROM set the motherboard ROM owns all
// of $C100-$CFFF - and a IIe boots that way, its firmware clearing the switch
// before the slot scan - and with SLOTC3ROM clear, $C3xx is motherboard ROM
// regardless (the IIe's 80-column firmware).  An on-card peripheral that
// answered $Cnxx unconditionally would drive against the ROM's own output
// buffer.  So a peripheral asks THIS module, which watches the driven ops for
// writes to the two switches that gate I/O SELECT' and says whether slot n's
// page is mapped to the slots at the moment.
//
// Carried from AppleTini v5_1_3's soft_switch_manager, cut down to those two
// switches:
//
//   $C006/$C007  INTCXROM   set -> the whole of $C1-$CF is motherboard ROM
//   $C00A/$C00B  SLOTC3ROM  clear -> $C3xx is motherboard ROM regardless
//
// Deliberately NOT carried: the $C8xx expansion-ROM select and the $CFFF
// release.  Neither peripheral on this card has a $C8xx presence.  When one
// does, that logic comes back from v5_1_3 as its own module rather than
// growing here.
//
// DEVICE SELECT' ($C0n0-$C0nF, n = slot + 8) is NOT gated by either switch and
// is not this module's business: a peripheral decodes that range itself.
//
// One instance per peripheral - two flops each - rather than one instance and
// a copy of the gate expression in every consumer, because the expression is
// the part that has to be right and this is where it lives.
//
// Held at the reset values while RES' is down, which is how the IIe's MMU
// behaves and what the host's own tracker (apple_video.cpp) assumes.
//////////////////////////////////////////////////////////////////////////////////
module slot_switches (
    input  wire        clk,
    input  wire        rst,
    // Synchronised RES', ACTIVE LOW.
    input  wire        res_sync,

    // The presented op, from apple_bus_write.  Only writes at op_commit
    // matter here.
    input  wire [15:0] op_addr,
    input  wire        op_rw,          // 1 = read
    input  wire        op_commit,

    // The slot being asked about, 1..7.
    input  wire [2:0]  slot,

    // 1 while $Cn00-$CnFF belongs to that slot.
    output wire        io_select
);

    logic intcxrom, slotc3rom;

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            intcxrom  <= 1'b0;
            slotc3rom <= 1'b0;
        end else if (op_commit && !op_rw) begin
            // Write strobes: the address selects the switch, A0 the value.
            if (op_addr[15:1] == 15'h6003) intcxrom  <= op_addr[0];  // $C006/7
            if (op_addr[15:1] == 15'h6005) slotc3rom <= op_addr[0];  // $C00A/B
        end
    end

    assign io_select = !intcxrom && !(slot == 3'd3 && !slotc3rom);

endmodule
