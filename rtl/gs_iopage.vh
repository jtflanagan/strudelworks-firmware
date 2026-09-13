// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// gs_iopage.vh - THE IIgs's I/O PAGE, defined once (docs/LONG_DATA.md rung 3).
// Included INSIDE a module: rtl/gs_io.sv (whose claim it decides),
// rtl/dline.sv (whose fast reads it gates) and sim/mmu_xlate_gs_tb.sv (which
// checks it against the KEGS-derived map oracle at every map it sweeps).
//
// $C0xx is the chipset's in the Mega II banks $E0/$E1 always, and in the fast
// pair $00/$01 only while SHADOW ($C035) bit 6 is CLEAR: with it set, $C000-
// $FFFF in $00/$01 is RAM and the machine's I/O window there is gone (KEGS
// moremem.c fixup_shadow_iolc; rtl/apple_mmu.sv gs_flat).  Every other bank's
// $C0xx is RAM.  Which way the CPU named the bank - literally zero, the DBR,
// a long address - makes no difference: the bank decides.

function automatic gs_is_io(input [7:0] bk, input flat);
    gs_is_io = (bk[7:1] == 7'h70) || ((bk[7:1] == 7'd0) && !flat);
endfunction

// THE FAST READS: the chipset registers whose read is a pure function of card
// state - no latch cleared, no protocol stepped, no toggle - so the data front
// may serve them from a registered copy (rtl/gs_io.sv fr_vec).  The index is
// the byte's slot in fr_vec, eight bits each; bit 5 is "in the set".  NOT in
// it, because the read itself does something: $C000 (auto-repeat - served
// separately, with its own retire pulse), $C010, $C024, $C026, $C030,
// $C033/$C034, $C038/$C039, $C03C-$C03F, $C046, $C047, $C0Ex.
localparam integer GS_FR_N = 31;
function automatic [5:0] gs_fr_sel(input [7:0] lo);
    case (lo)
        8'h11: gs_fr_sel = 6'h20;  8'h12: gs_fr_sel = 6'h21;  8'h13: gs_fr_sel = 6'h22;
        8'h14: gs_fr_sel = 6'h23;  8'h15: gs_fr_sel = 6'h24;  8'h16: gs_fr_sel = 6'h25;
        8'h17: gs_fr_sel = 6'h26;  8'h18: gs_fr_sel = 6'h27;  8'h19: gs_fr_sel = 6'h28;
        8'h1A: gs_fr_sel = 6'h29;  8'h1B: gs_fr_sel = 6'h2A;  8'h1C: gs_fr_sel = 6'h2B;
        8'h1D: gs_fr_sel = 6'h2C;  8'h1E: gs_fr_sel = 6'h2D;  8'h1F: gs_fr_sel = 6'h2E;
        8'h21: gs_fr_sel = 6'h2F;  8'h22: gs_fr_sel = 6'h30;  8'h23: gs_fr_sel = 6'h31;
        8'h25: gs_fr_sel = 6'h32;  8'h27: gs_fr_sel = 6'h33;  8'h29: gs_fr_sel = 6'h34;
        8'h2B: gs_fr_sel = 6'h35;  8'h2D: gs_fr_sel = 6'h36;  8'h2E: gs_fr_sel = 6'h37;
        8'h2F: gs_fr_sel = 6'h38;  8'h35: gs_fr_sel = 6'h39;  8'h36: gs_fr_sel = 6'h3A;
        8'h41: gs_fr_sel = 6'h3B;  8'h61: gs_fr_sel = 6'h3C;  8'h62: gs_fr_sel = 6'h3D;
        8'h68: gs_fr_sel = 6'h3E;
        default: gs_fr_sel = 6'h00;
    endcase
endfunction
