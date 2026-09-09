`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_io - the IIgs chipset's face on $C0xx, on the card.
//
// WHAT IT IS FOR.  On the IIe every $C0xx the card does not hold is BUS class
// and rides a real bus cycle to the motherboard, which answers it.  A IIgs in
// this machine has no motherboard to ask: the ADB micro, the clock, the VGC,
// the interrupt controller and the rest are not on the IIe's board and never
// were.  So the card answers them itself, and this is where.
//
// IT REUSES THE PATH THAT ALREADY EXISTS, rather than adding a class.
// docs/GS.md's plan called for a new CLS_IO and a three-bit class; but the
// card already has a path for "a $C0xx op the card answers itself" - the
// INTERNALIZED op of docs/CXXX.md, which rides S_FAST like any fast op,
// takes its byte from `swi_byte`, and retires with a SYNTHETIC COMMIT on the
// unified stream.  That is exactly the shape this needs, it is proven on
// hardware, and it costs no widening: `claim` joins the dispatcher's `q_swi`
// and `rd_byte` joins the `swi_byte` mux.  The class stays two bits.
//
// THE TWO FACES OF AN OP, and why there are two address ports.  `q_addr` is
// the LIVE address the dispatcher is deciding on, so `claim` must be
// combinational on it - the decision is taken the clock after the op appears
// and cannot wait.  `op_lo` is the REGISTERED op, stable from the dispatch
// through the synthetic commit, so the byte and every side effect hang off
// that.  Getting these the wrong way round would answer one op with another's
// byte.
//
// WHAT IT CLAIMS TODAY: the ADB micro at $C025-$C027, and nothing else.  This
// is deliberate.  Rung 3b grows the claim one register at a time, measuring
// `boot_gs_tb`'s divergence index against the KEGS trace after each, because
// an address claimed and answered WRONGLY is worse than one left to the bus:
// the bus at least returns a consistent floating byte.  The census the bench
// prints (`the $C0xx census`) is the work list, in the ROM's own order.
//
// WHAT STAYS ON THE BUS BY POLICY, not by omission (docs/GS.md, "The real IIe
// board in GS mode"): $C061-$C067 and $C070, the game port, which is REAL
// hardware this machine has; $C058-$C05F, the annunciators; and any $Cnxx
// belonging to a physical card in a slot.  Those must never be claimed here.
//////////////////////////////////////////////////////////////////////////////////
module gs_io (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,       // synchronised RES', ACTIVE LOW

    // The LIVE query: would this module answer an op at q_addr?  Answered
    // combinationally, for rtl/accel_seq.sv's decision.
    input  wire [23:0] q_addr,
    input  wire        q_rw,
    output wire        claim,

    // The REGISTERED op, and its retire on the unified stream.
    input  wire [7:0]  u_bank,
    input  wire [15:0] u_addr,
    input  wire        u_rw,
    input  wire [7:0]  u_wdata,
    input  wire        u_commit,       // the synthetic commit: one per op

    // The IIgs's registers, held by rtl/apple_mmu.sv because the map is what
    // they steer, and read back here because $C0xx is this module's window.
    input  wire [7:0]  gs_shadow,      // $C035
    input  wire [7:0]  gs_cyareg,      // $C036
    input  wire [7:0]  gs_sltrom,      // $C02D
    input  wire [7:0]  gs_state,       // $C068, composed from the switches

    // Seconds since 1904-01-01, for the clock chip.  The host's, or the
    // bench's pinned value (rtl/gs_clock.sv).
    input  wire [31:0] seed_time,
    // The border colour the VGC paints, $C034[3:0].
    output wire [3:0]  border,

    // The byte a read of the registered op would take, and whether this
    // module is the one that owns that op at all - the select for the caller's
    // internalized-read mux, which follows the REGISTERED op just as the byte
    // does (rtl/master_top.sv, "swi_byte").
    output wire        u_claim,
    output logic [7:0] rd_byte,

    // Into gs_intc, when there is one.
    output wire        irq
);

    // A IIgs sees I/O at $C0xx in a PAIR bank only - $00/$01 and the Mega
    // II's $E0/$E1 - which is the rule rtl/apple_mmu.sv applies to the
    // switches, and the same rule has to hold here or bank $02's $C0xx would
    // be answered by the chipset instead of being the plain RAM it is.
    function automatic pair_bank(input [7:0] bk);
        pair_bank = (bk == 8'h00) || (bk == 8'h01) || (bk == 8'hE0) || (bk == 8'hE1);
    endfunction

    // ---- what this module answers -------------------------------------------
    // One function, asked of the live address for the claim and of the
    // registered one for the effect, so the two can never drift apart.
    function automatic mine(input [7:0] lo);
        mine = (lo == 8'h25) || (lo == 8'h26) || (lo == 8'h27)    // the ADB micro
            || (lo == 8'h2D)                                       // SLOTROMSEL
            || (lo == 8'h33) || (lo == 8'h34)                      // the clock and battery RAM
            || (lo == 8'h35) || (lo == 8'h36) || (lo == 8'h37)     // SHADOW, CYAREG, and $C037
            || (lo == 8'h68);                                      // STATEREG
    endfunction

    wire q_io = pair_bank(q_addr[23:16]) && (q_addr[15:8] == 8'hC0);
    assign claim = q_io && mine(q_addr[7:0]);

    wire u_io = pair_bank(u_bank) && (u_addr[15:8] == 8'hC0);
    wire u_mine = u_io && mine(u_addr[7:0]);
    assign u_claim = u_mine;
    // The op retired AND it was ours.  u_commit fires for every internalized
    // op, so the decode is repeated here rather than trusted.
    wire act = u_commit && u_mine;

    wire [7:0] adb_rd;
    wire       adb_irq_data, adb_irq_mouse;
    wire [7:0] adb_cnt_cmds, adb_cnt_unknown;

    gs_adb u_adb (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (u_addr[7:0]), .op_rw (u_rw), .op_wdata (u_wdata), .act (act),
        .rd_byte (adb_rd),
        // The modifier keys, from nobody yet (rung 3c).
        .c025_val (8'h00),
        .irq_data (adb_irq_data), .irq_mouse (adb_irq_mouse),
        .cnt_cmds (adb_cnt_cmds), .cnt_unknown (adb_cnt_unknown)
    );

    // The map's registers read straight back.  $C037 reads zero on a IIgs
    // (KEGS moremem.c:1122) and is claimed rather than left to the bus so the
    // ROM's 309 reads of it get that zero from the machine that owns the
    // address, not from a floating backplane that happens to agree.
    //
    // NOTE THE WRITES STILL LAND IN apple_mmu, not here: $C02D, $C035, $C036
    // and $C068 are written on the classified op's commit, and the synthetic
    // commit an internalized op retires with IS that commit (accel_seq's
    // u_commit is the driver's OR swi_commit).  Claiming them here changes
    // where the BYTE comes from and nothing about where the write goes.
    always_comb begin
        case (u_addr[7:0])
            8'h2D:   rd_byte = gs_sltrom;
            8'h33,
            8'h34:   rd_byte = clk_rd;
            8'h35:   rd_byte = gs_shadow;
            8'h36:   rd_byte = gs_cyareg;
            8'h37:   rd_byte = 8'h00;
            8'h68:   rd_byte = gs_state;
            default: rd_byte = adb_rd;
        endcase
    end
    wire [7:0] clk_rd;
    wire [7:0] clk_cnt_strobes, clk_cnt_bad;
    gs_clock u_clock (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (u_addr[7:0]), .op_rw (u_rw), .op_wdata (u_wdata), .act (act),
        .rd_byte (clk_rd), .seed_time (seed_time), .border (border),
        .cnt_strobes (clk_cnt_strobes), .cnt_bad (clk_cnt_bad)
    );

    assign irq = adb_irq_data || adb_irq_mouse;

    // q_rw is not consulted yet: every address claimed here answers both a
    // read and a write.  It is a port because the registers that do not -
    // the write-only strobes, and $C02E/$C02F which read the beam and ignore
    // a write - arrive with the VGC.
    wire _unused_q_rw = q_rw;

endmodule
