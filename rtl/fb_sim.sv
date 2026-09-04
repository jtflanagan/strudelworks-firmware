`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// fb_sim - the floating bus, simulated: the byte the video scanner would fetch
// on this cycle, from a side copy of the display pages, without the bus.
//
// WHAT THIS IS FOR.  A read of an address nothing drives - a video soft
// switch, the speaker, the language card's switches - returns the byte the
// video scanner fetched during phi0-low, and software finds the beam that way
// (docs/VBL.md, "vapor lock").  At the bus's pace every such read goes to the
// real bus and comes back right.  A core running faster than the bus
// (docs/ACCELERATION.md) cannot rendezvous with the machine for those: the
// byte it needs is the one the scanner WOULD fetch at the core's own cycle,
// from memory as the core has written it.  This module produces that byte,
// and on the unaccelerated machine PROVES it against the real floating bus on
// every floating read, every cycle, in every video mode.  docs/FLOATING_BUS.md
// is the design.
//
// THE SIDE COPY.  Main memory's text pages ($0400-$0BFF) and hi-res pages
// ($2000-$5FFF) are kept in two block RAMs of their own - 2 KB and 16 KB, the
// floppy's true-dual-port template (rtl/fd_bank.sv) - written from the page
// cache's MAIN-BANK WRITE TAP (rtl/page_cache.sv, mw_*): the strobe, address
// and byte of every write the main bank takes, on the very clock it takes
// it.  Whatever reaches the main bank - the core's writes fast or slow, a
// posted write draining, a disk DMA, the VBL lock's fill - reaches the copy
// on the same edge, and nothing else can: the main bank IS bank 0 of the
// image, so the tap is already after every switch that steers a write to
// the auxiliary bank (80STORE+PAGE2, RAMWRT, a RamWorks bank).  The aux
// byte never floats: it goes to the 80-column card's own latch, never onto
// the main data bus (AppleWin reads pMain[]).
//
// Why a copy and not the bank itself: the byte has to be CYCLE-CORRECT for
// an accelerated core, and it has to come from a port that is never busy
// and never behind.  The main bank's ports serve the op path, the line
// fills and the page engine on schedules of their own; a copy with one
// writer and one reader is always one clock behind the write and never
// stalls.  The one thing the two ports can do to each other - the write
// landing on the clock the scanner reads the same byte, routine under
// acceleration where writes land on any clock - is the defined case for a
// read-first writer (UG473): the scanner gets the OLD byte, which is exactly
// the machine's - its scanner fetches during phi0-low, before the 6502's
// write lands at the end of phi0-high.
//
// THE PREDICTION.  The scanner's position comes in as a line and a cycle
// (rtl/vbl_lock.sv's counter today; an accelerated design's virtual counter
// later, through the same ports), the mode from the MMU shadow's switches,
// and rtl/scan_addr.vh turns them into the address the scanner reads:
//
//   text addressing  when TEXT, or MIXED on the lines the IOU's HIRES TIME
//                    is off (V4 && V2: lines 160-191 and 224-261, NOT 192-223)
//                    one cycle late: cycle 0 of a line still goes by the
//                    line before (the machine's own lag, rtl/scan_addr.vh)
//   hi-res otherwise when HIRES
//   page 2           when PAGE2 and not 80STORE - with 80STORE the display is
//                    always page 1 and PAGE2 only steers writes
//
// The address is registered, the block RAM reads it every clock, and the byte
// comes out two clocks later: THREE CLOCKS from a new position to its byte.
// A bus cycle is ~98 clocks and the counter steps one clock after the data
// tick, so at the data phase the byte is long settled.  A virtual counter
// has to allow the same three clocks.  No one-cycle offset: the counter's
// origin is DEFINED by the floating bus (docs/VBL.md, "What the machine
// said" - it is the IIe's VBL' pin that is a cycle early, not the byte), and
// vbl_lock's verify frame is already this comparison in text mode.
//
// WHAT FLOATS.  On a IIe a read of $C020-$C05F or $C070-$C08F drives nothing
// onto the bus - cassette out, the speaker, the utility strobe, the video
// switches, the paddle trigger, the language card - and its side effect is
// the read's own switch, which still happens: the bus is still driven with
// the read.  Excluded: $C000-$C01F (the keyboard latch is in bits 6:0),
// $C060-$C06F (bit 7 is driven), $C090-$C0FF (a slot's I/O floats only if
// the slot is empty, which the card cannot know), and everything above.  A
// read a peripheral on the card claims (slot_rd_claim), or the keyboard or
// the buttons substitute, is theirs and never compared.
//
// THE MONITOR runs serving or not, on every floating read while the counter
// is locked - the core's and the overrides' alike, so the VBL probe's frame
// of $C054 reads is a frame of comparisons.  Three counts: `mismatches` on
// ordinary cycles; `hole_mismatches` when the scanner's address is a screen
// hole ($x78-$x7F of a 128-byte stride: the copy follows the firmware writes
// that go there, but they are the one place the lock's fill never writes);
// `col80_mismatches` on 80-column cycles, where the scanner fetches main and
// auxiliary memory in the same cycle and which byte floats is a question the
// count answers rather than the design assumes.  Unwritten bytes of the copy
// are garbage, by the image's policy: the count climbs until the program has
// drawn its screen and then stops, and a count that keeps climbing under a
// settled program is the finding.  FB_LAST carries the position of the last
// ORDINARY mismatch so a wrong cycle can be named; the other two kinds are
// counted and never overwrite it.
//
// SERVE substitutes the prediction for the bus's byte in the core's din and
// in the captured event, through the same route the keyboard uses (din_sub).
// Never on an override (the VBL probe's reads must stay real), never while
// unlocked, never on an 80-column cycle until the count above has spoken.
// The bus is still driven; the monitor still compares.  This is the
// accelerated core's byte, proven on the real machine before there is one.
//
// PEEK reads the copy through the write port's idle clocks - a write is at
// most one clock in a handful even under acceleration - for a host test to
// check the copy against its own mirror of the machine's memory.  Bit 14 of
// its address picks text or hi-res, and the low bits are the page-folded
// index.
//////////////////////////////////////////////////////////////////////////////////
module fb_sim (
    input  wire        clk,
    input  wire        rst,

    // The presented op, from apple_bus_write.
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire        op_present,
    input  wire        op_commit,
    input  wire        op_ovr,

    // The main bank's writes as they land (rtl/page_cache.sv): one byte a
    // clock, on the same edge the bank takes it.
    input  wire        mw_stb,
    input  wire [15:0] mw_addr,
    input  wire [7:0]  mw_byte,

    // The switches, from apple_mmu: sw_state's packing is MEM_STAT's,
    // vid_sw is {col80, mixed, text}.
    input  wire [11:0] sw_state,
    input  wire [2:0]  vid_sw,

    // The scanner's position: the line and the cycle the data phase in
    // flight belongs to, and the frame's length.  From vbl_lock.
    input  wire        locked,
    input  wire [8:0]  scan_v,
    input  wire [6:0]  scan_h,
    input  wire        pal,

    // 1 while the soft core owns the bus.
    input  wire        master_active,
    // The bus's byte, synchronised: the T_DIN sample is data_sync a clock
    // before op_commit, as page_cache takes it.
    input  wire [7:0]  data_sync,
    // Reads that are somebody else's: a peripheral on the card, the
    // keyboard, the buttons.
    input  wire        slot_rd_claim,
    input  wire        kbd_sub_en,
    input  wire        pb_sub_en,

    // From FB_CTRL and FB_PEEK.
    input  wire        serve,
    input  wire        cnt_clr,
    input  wire [14:0] peek_addr,    // [14] 0 = text page + [10:0], 1 = hi-res + [13:0]

    // To master_top's din_sub mux.
    output wire        sub_en,
    output wire [7:0]  sub_data,

    // For the registers.
    output wire [6:0]  mode,         // {store80, col80, page2_disp, hires, mixed, text, locked}
    output logic [31:0] compared,
    output logic [31:0] mismatches,
    output logic [31:0] last,        // {expected, got, v[8:0], h[6:0]}
    output logic [31:0] last2,       // {op_addr[7:0], scanner address, mode bits}
    output logic [31:0] other,       // [15:0] hole mismatches, [31:16] col80 mismatches
    output wire  [7:0]  peek_data
);

    `include "scan_addr.vh"

    // ---- the switches ------------------------------------------------------------
    wire store80 = sw_state[0];
    wire page2   = sw_state[4];
    wire hires   = sw_state[5];
    wire text    = vid_sw[0];
    wire mixed   = vid_sw[1];
    wire col80   = vid_sw[2];

    // ---- the side copy's write: the tap, decoded ----------------------------------
    // Text: $0400-$0BFF -> {A11, A9:A0}; hi-res: $2000-$5FFF -> {A14, A12:A0}.
    // Either page of either region is one contiguous block RAM index.  The
    // tap's fields are registers in page_cache, so this is one decode
    // between a register and the RAM's pins.
    wire        t_we    = mw_stb && (mw_addr[15:12] == 4'h0) && (mw_addr[11] ^ mw_addr[10]);
    wire        h_we    = mw_stb && !mw_addr[15] && (mw_addr[14] ^ mw_addr[13]);
    wire [10:0] t_waddr = {mw_addr[11], mw_addr[9:0]};
    wire [13:0] h_waddr = {mw_addr[14], mw_addr[12:0]};

    // ---- the prediction ---------------------------------------------------------
    wire text_addr  = text || (mixed && scan_mixed_text_at(scan_v, scan_h, pal));
    wire hires_addr = hires && !text_addr;
    wire page2_disp = page2 && !store80;
    wire [15:0] saddr = scan_addr(scan_v, scan_h, pal, hires_addr, page2_disp);

    // Registered once before the RAMs' address pins; the read follows every
    // clock and the byte lands two clocks after the address.
    logic [15:0] s_addr_q;
    logic        s_hires_q, s_hires_q2;
    always_ff @(posedge clk) begin
        s_addr_q   <= saddr;
        s_hires_q  <= hires_addr;
        s_hires_q2 <= s_hires_q;
    end

    // Port A: the write, or the peek while there is none.  Port B: the scanner.
    // Both read-first: a write on A and the scanner's read of the same byte
    // on B in one clock hands B the old byte (the header says why that is
    // the right one).
    wire [7:0] t_a_rdata, h_a_rdata, t_b_rdata, h_b_rdata;

    fd_bank #(.DEPTH (2048), .AW (11)) u_text (
        .clk     (clk),
        .a_we    (t_we),
        .a_addr  (t_we ? t_waddr : peek_addr[10:0]),
        .a_wdata (mw_byte),
        .a_rdata (t_a_rdata),
        .b_we    (1'b0),
        .b_addr  ({s_addr_q[11], s_addr_q[9:0]}),
        .b_wdata (8'd0),
        .b_rdata (t_b_rdata)
    );

    fd_bank #(.DEPTH (16384), .AW (14)) u_hgr (
        .clk     (clk),
        .a_we    (h_we),
        .a_addr  (h_we ? h_waddr : peek_addr[13:0]),
        .a_wdata (mw_byte),
        .a_rdata (h_a_rdata),
        .b_we    (1'b0),
        .b_addr  ({s_addr_q[14], s_addr_q[12:0]}),
        .b_wdata (8'd0),
        .b_rdata (h_b_rdata)
    );

    // The byte, and the address it came from, three clocks from the position.
    logic [7:0]  pred;
    logic [15:0] pred_addr, pred_addr_q;
    always_ff @(posedge clk) begin
        pred        <= s_hires_q2 ? h_b_rdata : t_b_rdata;
        pred_addr_q <= s_addr_q;
        pred_addr   <= pred_addr_q;
    end

    // The peek: port A's byte is the peek's whenever the previous clock did
    // not write, so it refreshes within a clock or two of any change.
    logic t_we_q, h_we_q;
    logic [7:0] peek_text, peek_hgr;
    always_ff @(posedge clk) begin
        t_we_q <= t_we;
        h_we_q <= h_we;
        if (!t_we_q) peek_text <= t_a_rdata;
        if (!h_we_q) peek_hgr  <= h_a_rdata;
    end
    assign peek_data = peek_addr[14] ? peek_hgr : peek_text;

    // ---- what floats -------------------------------------------------------------
    function automatic floats(input [15:0] a);
        begin
            floats = (a[15:8] == 8'hC0) &&
                     (((a[7:4] >= 4'h2) && (a[7:4] <= 4'h5)) ||
                      (a[7:4] == 4'h7) || (a[7:4] == 4'h8));
        end
    endfunction

    // A read the floating bus answers, and nobody on the card does.
    wire cand = op_rw && floats(op_addr) && !slot_rd_claim && !kbd_sub_en && !pb_sub_en;

    // ---- serve --------------------------------------------------------------------
    assign sub_en   = serve && locked && master_active && !op_ovr && !col80 && cand;
    assign sub_data = pred;

    assign mode = {store80, col80, page2_disp, hires, mixed, text, locked};

    // ---- the monitor, at the data phase -------------------------------------------
    logic [7:0] data_q;
    wire        hole = (pred_addr[6:0] >= 7'h78);
    wire        cmp  = op_commit && master_active && locked && cand;
    wire        miss = (pred != data_q);

    always_ff @(posedge clk) begin
        data_q <= data_sync;
        if (rst) begin
            compared   <= 32'd0;
            mismatches <= 32'd0;
            other      <= 32'd0;
            last       <= 32'd0;
            last2      <= 32'd0;
        end else begin
            if (cmp) begin
                compared <= compared + 32'd1;
                if (miss) begin
                    if (col80)     other[31:16] <= other[31:16] + 16'd1;
                    else if (hole) other[15:0]  <= other[15:0]  + 16'd1;
                    else begin
                        // The position of the last ORDINARY mismatch: the
                        // holes and the 80-column cycles are counted, and
                        // must not overwrite the one worth reproducing.
                        mismatches <= mismatches + 32'd1;
                        last  <= {pred, data_q, scan_v, scan_h};
                        last2 <= {op_addr[7:0], pred_addr,
                                  hole, col80, store80, page2_disp, hires_addr, text_addr, mixed, text};
                    end
                end
            end
            if (cnt_clr) begin
                compared   <= 32'd0;
                mismatches <= 32'd0;
                other      <= 32'd0;
                last       <= 32'd0;
                last2      <= 32'd0;
            end
        end
    end

    wire _unused_ok = &{1'b0, op_present, 1'b0};

endmodule
