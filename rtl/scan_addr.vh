// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// scan_addr.vh - the Apple II video scanner's address, as a function of where
// the beam is.  `included inside a module, so every user shares one formula:
// rtl/vbl_lock.sv finds and follows the scanner with it (text page 1 only),
// rtl/fb_sim.sv predicts the floating bus with it in every mode.
//
// THE MODEL is Sather's (Understanding the Apple II, ch. 5, and the IIe's
// IOU, UTAIIe 5-7..5-9) as AppleWin's VideoGetScannerAddress writes it, and
// as the host's src/scanner.hpp transliterates it: a horizontal state H and a
// vertical state V, with the address bits picked off them - and A3-A6 a SUM
// of bits from both, which is what makes horizontal blanking read another
// row's tail.  `line` is 0..lines-1 and `hc` 0..64, with 0..24 the blanking
// cycles; the frame is 262 lines (NTSC) or 312 (PAL).
//
//   V state:  $100 + line, until the vertical preset at line 256 takes it to
//             $FA (NTSC) or $C8 (PAL).  Bits: [2:0] VA VB VC, [5:3] V0-V2,
//             [7:6] V3 V4, [8] V5.
//   H state:  $00 for the first blanking cycle, $40-$57 for the rest of the
//             blanking, $58-$7F for the forty displayed; only the low six
//             bits reach the address, so from cycle 1 on the state is hc-1.
//   A0-A2  =  H0-H2
//   A3-A6  =  H5 H4 H3 + V4 V3 V4 V3 + 1101, kept to four bits
//   A7-A9  =  V0-V2
//   text:     A10 = PAGE1, A11 = PAGE2                    ($0400 / $0800)
//   hires:    A10-A12 = VA-VC, A13 = PAGE1, A14 = PAGE2   ($2000 / $4000)
//
// MIXED MODE takes the text-page form on the lines the IOU's HIRES TIME
// signal is off: MIXED && V4 && V2 (AppleWin Video.cpp, UTAIIe 5-7 P3) -
// V-state bits 7 and 5 both set.  That is lines 160-191 and 224-261 on NTSC
// and NOT 192-223, which a "line >= 160" rule gets wrong; a program that
// reads the floating bus during blanking in mixed hi-res cares.  The IIe
// does not add $1000 during blanking in text mode as the ][ and ][+ do
// (AppleWin's "HBL bug"); the card serves a IIe.
//
// sim/vbl_lock_tb.sv and sim/fb_sim_tb.sv derive the same addresses from
// Sather's counters themselves, independently, and the two agreeing on every
// cycle of a frame in every mode is what the testbenches check.
//////////////////////////////////////////////////////////////////////////////////

localparam [8:0] SCAN_NTSC_LINES = 9'd262;
localparam [8:0] SCAN_PAL_LINES  = 9'd312;

// The V state for a line.
function automatic [8:0] scan_vstate(input [8:0] line, input is_pal);
    begin
        scan_vstate = (line < 9'd256) ? (line | 9'h100)
                    : (line + 9'd256 - (is_pal ? SCAN_PAL_LINES : SCAN_NTSC_LINES));
    end
endfunction

// The lines of a mixed-mode frame that read the text page: V4 && V2.
function automatic scan_mixed_text(input [8:0] line, input is_pal);
    logic [8:0] vs;
    begin
        vs = scan_vstate(line, is_pal);
        scan_mixed_text = vs[7] && vs[5];
    end
endfunction

// The scanner's address on cycle `hc` of `line`, in text (and lo-res)
// addressing or hi-res, from page 1 or page 2.
function automatic [15:0] scan_addr(input [8:0] line, input [6:0] hc, input is_pal,
                                    input hires, input page2);
    logic [8:0] vs;
    logic [5:0] h6;
    logic [4:0] sum;
    begin
        vs  = scan_vstate(line, is_pal);
        h6  = (hc == 7'd0) ? 6'd0 : 6'(hc - 7'd1);
        sum = {2'b00, h6[5:3]} + {1'b0, vs[7:6], 2'b00} + {3'b000, vs[7:6]} + 5'd13;
        if (hires) scan_addr = {1'b0, page2, !page2, vs[2:0], vs[5:3], sum[3:0], h6[2:0]};
        else       scan_addr = {4'b0000, page2, !page2, vs[5:3], sum[3:0], h6[2:0]};
    end
endfunction
