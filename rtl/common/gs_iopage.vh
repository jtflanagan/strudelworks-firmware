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

// WHAT gs_io ANSWERS on $C0xx (rtl/gs/gs_io.sv): one function for the claim on
// the live address, the effect on the registered op - in gs_io - and the same
// claim decoded in the top beside the dispatcher, where gs_io sits behind its
// register slice (rtl/gs/gs_io_slice.sv) and may be placed far away.
function automatic gs_io_mine(input [7:0] lo);
gs_io_mine = (lo == 8'h00) || (lo == 8'h10)                     // the keyboard
        || (lo == 8'h21) || (lo == 8'h22) || (lo == 8'h23)    // the VGC
        || (lo == 8'h24) || (lo == 8'h25) || (lo == 8'h26) || (lo == 8'h27)  // ADB
        || (lo == 8'h29) || (lo == 8'h2A) || (lo == 8'h2B) || (lo == 8'h2C)  // the VGC
        || (lo[7:4] == 4'h1 && lo != 8'h10)                    // $C011-$C01F, the status page
        || (lo == 8'h2D)                                       // SLOTROMSEL
        || (lo == 8'h2E) || (lo == 8'h2F)                      // VERTCNT, HORIZCNT
        // $C030 IS THE SPEAKER, AND IT MUST NOT REACH THE BACKPLANE.
        // A IIgs's speaker is the card's and the host's, but the machine
        // this card lives in decodes $C030-$C03F for ITS OWN speaker -
        // partially, as real Apple II hardware does - so any one of those
        // addresses riding a real cycle clicks the motherboard's speaker
        // audibly.  Every other address in the range is already claimed
        // below (the clock, SHADOW, CYAREG, the SCC, the sound GLU), so
        // claiming this one closes the range: nothing in $C03x is ever
        // presented to the bus again.  The card's own speaker model still
        // sees it - it watches the fast event, not the backplane
        // (rtl/speaker.sv) - so the sound still reaches the host.
        || (lo == 8'h30)                                       // the speaker
        || (lo == 8'h31) || (lo == 8'h32)                      // DISKREG, SCANINT
        || (lo == 8'h33) || (lo == 8'h34)                      // the clock and battery RAM
        || (lo == 8'h35) || (lo == 8'h36) || (lo == 8'h37)     // SHADOW, CYAREG, $C037
        || (lo[7:2] == 6'b001110)                              // $C038-$C03B, the SCC
        || (lo[7:2] == 6'b001111)                              // $C03C-$C03F, the sound GLU
        || (lo == 8'h41) || (lo == 8'h46) || (lo == 8'h47)     // the interrupt controller
        || (lo == 8'h61) || (lo == 8'h62)                      // the Apple keys (see the header)
        || (lo == 8'h68) || (lo == 8'h69)                      // STATEREG, and a reserved zero
        || (lo[7:4] == 4'hE);                                   // $C0E0-$C0EF, the IWM
endfunction
