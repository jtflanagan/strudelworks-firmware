`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// apple_mmu - the IIe's memory map, shadowed: which memory does this op touch?
//
// The card is about to keep its own copy of the Apple's memory (rtl/mem_cache.sv)
// and answer the core's reads from it.  That is only possible if the card knows,
// for every bus cycle, WHICH byte the machine's MMU would have reached - and on a
// IIe that depends on a dozen soft switches: main or auxiliary RAM (RAMRD, RAMWRT,
// ALTZP, 80STORE with PAGE2 and HIRES), the language card's two banks and its
// read/write enables, and whether $D000-$FFFF is RAM or ROM at all.  This module
// watches the ops the card drives, keeps the switches the way the IIe's MMU
// would, and classifies each presented op into a class and a PHYSICAL address in
// the card's image.
//
// It watches EVERY op, override cycles included.  The VBL lock writes $C000 and
// $C004 through an override, the hard disk DMAs blocks into RAM through one;
// the machine's MMU sees those cycles on the bus like any other, so this
// shadow must too.  Sampling only the core's ops would drift from the machine
// on the first override.
//
// THE CLASSES.
//
//   BUS   $C000-$CFFF.  I/O, soft switches, the slots' ROMs, the internal
//         $Cxxx ROM.  Never the card's business here: the byte comes from the bus.
//   RAM   $0000-$BFFF, main or aux by the switches.  In the image.
//   LC    $D000-$FFFF when it reaches the language card's RAM.  In the image.
//   ROM   $D000-$FFFF when the ROM answers.  In rtl/apple_rom.sv, not the image.
//
// THE IMAGE'S LAYOUT is the one emulators use: 64 KB per bank, with the
// language card's 16 KB folded into the $C000-$FFFF hole - bank 1 of $D000 at
// $C000-$CFFF, bank 2 of $D000 and the shared $E000-$FFFF where they sit.
// Image bank 0 is MAIN MEMORY, always: nothing banks it.  Image banks 1-255
// are the AUXILIARY memory, one per RamWorks bank.  cl_pa is that 24-bit
// physical address: 16 MB, the whole image.
//
// THE RAMWORKS.  An Applied Engineering RamWorks III in the auxiliary slot
// replaces the 64 KB auxiliary memory with up to 256 banks of it, each a
// complete auxiliary memory - $0000-$BFFF, the zero page and stack ALTZP
// moves, the language card ALTZP moves - and a bank register at $C073
// (AppleWin's Memory.cpp also honours $C071, the earlier extended-memory
// cards' address; so does this) selecting which of them every auxiliary
// access reaches.  Bank 0 IS the regular auxiliary memory of a 128K IIe -
// what the 80-column firmware, DHGR and ProDOS's /RAM use - and banks 1 and
// up are the extension.  Writes only; the register cannot be read back on the
// real card, and software finds the banks by writing a signature into each
// and looking for it.
//
// Here the card IS the RamWorks, with RW_BANKS = 255 banks: RamWorks bank k
// is image bank k+1, so the regular auxiliary memory (bank 0) is image bank 1
// exactly as it was before the RamWorks existed, and the 255 banks plus main
// memory fill the 16 MB.  A write of a bank number that does not exist (255)
// is ignored and the register keeps its value, which is what AppleWin does
// for a bank beyond the configured size.
//
// THE BANK REGISTER RESETS ON RES', by decision.  The real card's does not
// (AppleWin resets it only on a power cycle, GH#1414), so a program that
// leaves bank 5 selected and then Ctrl-Resets finds the monitor's auxiliary
// memory in bank 5.  Nothing reliable depends on that, and clearing it makes
// every reset land in the memory the ROM and the 80-column firmware expect;
// the convenience wins.  The host's mirror (apple_memory.hpp) does the same.
//
// THE MACHINE'S OWN AUXILIARY MEMORY MUST NOT SEE THE OTHER BANKS' WRITES.
// The bus is driven for every cycle and the real IIe has no bank register, so
// a write to bank 5's $2000, sent out as a write, would land in the machine's
// one auxiliary bank over whatever bank 0 put there - and the video scanner
// reads that RAM.  So the driver DIVERTS such a write: the cycle goes out on
// the pins as a READ of the same address (harmless: nothing in $0000-$BFFF or
// $D000-$FFFF has a read side effect), the image takes the write as it would
// have, and the capture still records the write with the core's byte
// (apple_bus_write.sv, apple_bus_read.sv).  The q_addr/q_divert port is the
// driver's question, asked of the address it is about to present and answered
// one clock later (the address is registered here for timing; the driver
// samples the answer at T_PRESENT, several clocks after the address settled,
// and asserts the stale copy matched) from the switches as they stand:
// would a WRITE here reach auxiliary memory in a bank other than 0?  The driver adds the one condition
// this module cannot know - that the card is serving, since with serving off
// the core reads the machine's memory and the write had better be in it.
//
// THE SWITCHES, as the IIe's MMU implements them (Sather, Understanding the
// Apple IIe, ch. 5; AppleWin's Memory.cpp and LanguageCard.cpp agree):
//
//   $C000/1  80STORE   write only, A0 = value
//   $C002/3  RAMRD     write only        $C004/5  RAMWRT     write only
//   $C006/7  INTCXROM  write only        $C008/9  ALTZP      write only
//   $C00A/B  SLOTC3ROM write only
//   $C054/5  PAGE2     read or write     $C056/7  HIRES      read or write
//   and three the memory map does not need but the video scanner does, kept
//   here so one decoder tracks every switch (rtl/fb_sim.sv reads them):
//   $C00C/D  80COL     write only        $C050/1  TEXT       read or write
//   $C052/3  MIXED     read or write
//   $C080-F  the language card, read or write:
//              A3 = 0 selects bank 2, A3 = 1 bank 1;
//              A0 == A1 (i.e. $x0, $x3) reads RAM, otherwise ROM;
//              A0 = 0 write-protects the RAM and clears PRE-WRITE;
//              A0 = 1 on a READ sets PRE-WRITE, and write-ENABLES if PRE-WRITE
//              was already set - the "two consecutive reads" rule;
//              A0 = 1 on a WRITE clears PRE-WRITE and leaves the enable alone.
//
// At reset (RES' low) the IIe's MMU clears the auxiliary and ROM switches and
// puts the language card at bank 2, reading ROM, RAM write-enabled - AppleWin's
// kMemModeInitialState.  Held there while RES' is down, like slot_switches.
//
// WHAT A WRITE DOES.  A write to $D000-$FFFF lands in the language card's RAM
// if it is write-enabled, whether or not the RAM is what a read would return -
// that is exactly how the LC is loaded, under the ROM.  A write to $D000-$FFFF
// with the RAM write-protected lands nowhere.  cl_wr_image says whether this
// write changes the image at all.
//
// TIMING.  The switches change at op_commit, the data phase, as on the bus
// (INTC8ROM excepted, below);
// the classification is registered at op_present, one clock after the op is
// stable, so it reflects every earlier cycle and not this one - a cycle that
// flips a switch is a BUS cycle anyway.  The IIe's own MMU has the same
// ordering.
//
// THE CX CLASS: $C100-$CFFF.  A read the MOTHERBOARD'S ROM answers there is
// ROM class - served from the card, never a bus rendezvous for the
// accelerated core (docs/ACCELERATION.md); everything a slot answers is BUS.
// UTAIIe 5-28, as AppleWin's Memory.cpp implements it:
//
//   $C100-$C7FF, page n   INTCXROM, or n == 3 with SLOTC3ROM clear
//                                      -> the internal ROM (rtl/apple_rom.sv)
//                         else          -> BUS: the slot's - on this card or
//                                          not, a ROM or a VIA or nothing -
//                                          every slot is hardware and rides
//                                          the bus, by the user's rule
//   $C800-$CFFE           INTCXROM or INTC8ROM -> the internal ROM
//                         else          -> BUS: a slot's expansion ROM
//   $CFFF, every write, every $C0xx    -> BUS
//
// INTC8ROM is the IIe's unreadable latch: set by any access to $C3xx while
// INTCXROM and SLOTC3ROM are both clear, cleared by any access to $CFFF or by
// RES'.  It decides whether $C800-$CFFF is the internal ROM's.  It is set at op_present rather than op_commit, because a $C3xx fetch
// served from the card has no data phase on the bus - and for one that does,
// present-versus-commit only differs for the NEXT op, which cannot be presented
// before this one's commit.  $CFFF is a bus op and clears it at commit like
// every other switch.  MEM_STAT[13] reads it.
//
// The internal ROM not yet loaded classifies as BUS, so "ROM class" always
// means "the card has the byte": rtl/mem_cache.sv needs no further check.
//
// NOT MODELLED, deliberately: a physical card's $C800-$CFFF expansion ROM and
// the per-slot I/O SELECT flip-flops that pick it - that page is BUS unless the
// internal ROM answers, and the machine does the rest.
//////////////////////////////////////////////////////////////////////////////////
module apple_mmu (
    input  wire        clk,
    input  wire        rst,
    // Synchronised RES', ACTIVE LOW.
    input  wire        res_sync,

    // The presented op, from apple_bus_write.
    input  wire [15:0] op_addr,
    input  wire        op_rw,          // 1 = read
    input  wire [7:0]  op_wdata,       // a write's byte: the bank register's value
    input  wire        op_present,     // pulse: op_* have just been latched
    input  wire        op_commit,      // pulse: the data phase

    // The internal ROM has arrived (rtl/apple_rom.sv): until then a read it
    // would answer is BUS class.
    input  wire        rom_ok,

    // The classified op, one clock after op_present.
    output logic        cl_valid,
    output logic [1:0]  cl_cls,        // CLS_*
    output logic [23:0] cl_pa,         // physical address in the image
    output logic [13:0] cl_rom_addr,   // offset from $C000 in the ROM
    output logic        cl_rw,
    output logic        cl_wr_image,   // a write that lands in the image
    // The INTC8ROM latch, for MEM_STAT.
    output logic        intc8rom,

    // The switches, for a status register:
    //   {prewrite, wren, lc_ramrd, bank2, slotc3rom, intcxrom, hires, page2,
    //    altzp, ramwrt, ramrd, store80}
    output wire [11:0] sw_state,
    // The video switches: {col80, mixed, text}.  Separate from sw_state,
    // whose packing MEM_STAT and the host's mirror carry bit for bit.
    output wire [2:0]  vid_sw,
    // The RamWorks bank register, for MEM_CTRL's readback.
    output logic [7:0] rw_bank,

    // The driver's question, combinational: would a write to q_addr, presented
    // now, reach auxiliary memory in a RamWorks bank other than 0?  See the
    // header.  q_addr is the address the driver is about to latch, so this is
    // decided on the switches as they stood before the cycle - the same
    // switches the classifier below will use for that op.
    input  wire [15:0] q_addr,
    output wire        q_divert,
    // ...and the sequencer's: what class would an op at q_addr, read or
    // write, be if presented now?  Same switches, same function as the
    // classifier below, combinational.  rtl/accel_seq.sv decides on it.
    input  wire        q_rw,
    output wire [1:0]  q_cls,

    // ---- the internalized soft switches (docs/ACCELERATION.md) --------------
    // In the closed regime - mode 2, serving, RAM never exported - the
    // switches whose whole effect is this shadow stop riding the bus: the
    // sequencer serves them fast, retires them with a synthetic commit
    // (op_commit fires and the update block above runs as for a bus op),
    // and the event stream still carries them to the host.  q_swi is the
    // live-op question beside q_cls; swi_stat_byte is the status page's
    // answer for the REGISTERED op (op_addr, stable through the fast
    // sequence).  INTCXROM and SLOTC3ROM writes stay on the bus: four slot
    // cards track them from the bus stream (rtl/slot_switches.sv).
    input  wire        swi_on,       // the closed-regime level, chicken bit included
    input  wire        swi_kbd_ok,   // the keyboard latch holds a byte (kbd_inject)
    input  wire        swi_fb_ok,    // fb_sim can answer a floating-value read
    input  wire        swi_vbl_ok,   // the VBL level is locked and known
    input  wire        swi_vbl,      // ...and this is it (1 = in vertical blanking)
    input  wire [6:0]  swi_kbd_low,  // the keyboard latch's low bits, for status reads
    output wire        q_swi,
    output wire [7:0]  swi_stat_byte,

    // ---- the TLB's question, combinational ---------------------------------
    // The two views of one 256-byte page, on the switches as they stand.  All
    // Apple II mapping is page-oriented, so within any page the class and
    // pa[23:8] depend only on the switches and on rw - never on the low byte.
    // The two exceptions are exactly why t_r_ok excludes them: $CFFF breaks
    // page $CF's uniformity AND clears INTC8ROM, and any $C3xx access can SET
    // INTC8ROM - both must keep reaching this module as presented ops, so
    // those pages are never servable from an L1.
    //
    // ppage is a 17-bit physical page: {1'b1, 10'd0, rom index} for the
    // internal ROM (its own space - the ROM is not in the image, and its
    // lines must not alias the image's), {1'b0, pa[23:8]} for the image.
    input  wire [7:0]  t_page,
    output wire        t_r_ok,      // reads L1-servable (RAM/LC/ROM class)
    output wire [16:0] t_r_ppage,   // where a read reaches
    output wire        t_w_ok,      // a write lands in the image
    output wire [16:0] t_w_ppage,   // where a write lands

    // A second, identical page query: the DMA line-drain engine's.  It
    // translates once per page of a block, into registers, with a whole
    // clock - never on a fast path.
    input  wire [7:0]  t2_page,
    output wire        t2_w_ok,
    output wire [16:0] t2_w_ppage,
    // A third: the D front's (rtl/d_front.sv), both views.  Reloads a
    // floating page register during a claim-stall clock, and re-answers
    // "do logical pages 0/1 still map to main" after a map change - always
    // from a registered page, never on a serve path.
    input  wire [7:0]  t3_page,
    output wire        t3_r_ok,
    output wire [16:0] t3_r_ppage,
    output wire        t3_w_ok,
    output wire [16:0] t3_w_ppage,
    // Any access that moves the map, the clock it takes effect: the TLBs
    // flush on it.  Combinational, so the flush lands at the same edge as the
    // change and no lookup can slip between them.
    output wire        map_changed
);

    // RamWorks banks: 0..RW_BANKS-1 exist; a write of any other number is
    // ignored.  255 banks plus main memory are the image's 256.
    localparam [7:0] RW_BANKS = 8'd255;

    localparam [1:0] CLS_BUS = 2'd0;
    localparam [1:0] CLS_RAM = 2'd1;
    localparam [1:0] CLS_LC  = 2'd2;
    localparam [1:0] CLS_ROM = 2'd3;

    // ---- the switches ----------------------------------------------------------
    logic store80, ramrd, ramwrt, intcxrom, altzp, slotc3rom;
    logic page2, hires;
    logic text, mixed, col80, altchar;
    logic lc_bank2, lc_ramrd, lc_wren, lc_prewrite;

    assign sw_state = {lc_prewrite, lc_wren, lc_ramrd, lc_bank2,
                       slotc3rom, intcxrom, hires, page2,
                       altzp, ramwrt, ramrd, store80};
    assign vid_sw   = {col80, mixed, text};

    wire io_page = (op_addr[15:8] == 8'hC0);
    wire sw_c00x = io_page && (op_addr[7:4] == 4'h0);      // $C000-$C00F
    wire sw_c05x = io_page && (op_addr[7:4] == 4'h5);      // $C050-$C05F
    // $C071 and $C073: the RamWorks bank register, a write of the bank number.
    wire sw_rwbk = io_page && (op_addr[7:4] == 4'h7) &&
                   (op_addr[3:0] == 4'h1 || op_addr[3:0] == 4'h3);
    wire sw_c08x = io_page && (op_addr[7:4] == 4'h8);      // $C080-$C08F

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            store80     <= 1'b0;
            ramrd       <= 1'b0;
            ramwrt      <= 1'b0;
            intcxrom    <= 1'b0;
            altzp       <= 1'b0;
            slotc3rom   <= 1'b0;
            page2       <= 1'b0;
            hires       <= 1'b0;
            text        <= 1'b1;       // the IOU's reset state: 40-column text
            mixed       <= 1'b0;
            col80       <= 1'b0;
            altchar     <= 1'b0;
            lc_bank2    <= 1'b1;
            lc_ramrd    <= 1'b0;
            lc_wren     <= 1'b1;
            lc_prewrite <= 1'b0;
            rw_bank     <= 8'd0;       // by decision: see the header
        end else if (op_commit) begin
            // $C000-$C00F: write strobes, the address selects the switch, A0
            // the value.
            if (sw_c00x && !op_rw) begin
                case (op_addr[3:1])
                    3'd0: store80   <= op_addr[0];
                    3'd1: ramrd     <= op_addr[0];
                    3'd2: ramwrt    <= op_addr[0];
                    3'd3: intcxrom  <= op_addr[0];
                    3'd4: altzp     <= op_addr[0];
                    3'd5: slotc3rom <= op_addr[0];
                    3'd6: col80     <= op_addr[0];
                    3'd7: altchar   <= op_addr[0];
                endcase
            end
            // $C071/$C073: the RamWorks bank, if it exists.
            if (sw_rwbk && !op_rw && op_wdata < RW_BANKS) rw_bank <= op_wdata;
            // $C050-$C057: read or write alike.
            if (sw_c05x) begin
                if (op_addr[3:1] == 3'd0) text  <= op_addr[0];
                if (op_addr[3:1] == 3'd1) mixed <= op_addr[0];
                if (op_addr[3:1] == 3'd2) page2 <= op_addr[0];
                if (op_addr[3:1] == 3'd3) hires <= op_addr[0];
            end
            // $C080-$C08F: the language card.
            if (sw_c08x) begin
                lc_bank2 <= !op_addr[3];
                lc_ramrd <= (op_addr[1] == op_addr[0]);
                if (!op_addr[0]) begin
                    lc_wren     <= 1'b0;
                    lc_prewrite <= 1'b0;
                end else if (op_rw) begin
                    if (lc_prewrite) lc_wren <= 1'b1;
                    lc_prewrite <= 1'b1;
                end else begin
                    lc_prewrite <= 1'b0;
                end
            end
        end
    end

    // ---- INTC8ROM ---------------------------------------------------------------------
    // Set at present, cleared at commit - see the header for why they differ.
    wire acc_c3xx = (op_addr[15:8] == 8'hC3);
    wire acc_cfff = (op_addr == 16'hCFFF);
    always_ff @(posedge clk) begin
        if (rst || !res_sync)                                   intc8rom <= 1'b0;
        else if (op_present && acc_c3xx && !intcxrom && !slotc3rom) intc8rom <= 1'b1;
        else if (op_commit && acc_cfff)                         intc8rom <= 1'b0;
    end

    // ---- the classifier, as a function of the address and the switches -----
    // Returns {class, write lands in the image}.  Called twice: on the
    // presented op (registered at op_present) and on the sequencer's question
    // (combinational).
    function automatic [2:0] classify(input [15:0] a, input rw);
        logic [1:0] c;
        logic       wr;
        logic [3:0] page;
        logic       in_io_f, in_hi_f, int_cx, int_c8;
        begin
            in_io_f = (a[15:12] == 4'hC);
            in_hi_f = (a[15:12] >= 4'hD);
            page    = a[11:8];
            int_cx  = intcxrom || (page == 4'd3 && !slotc3rom);
            int_c8  = intcxrom || intc8rom;
            c = CLS_BUS; wr = 1'b0;
            if (in_io_f) begin
                // The internal ROM's pages, and only those: every slot is BUS.
                if (rw && rom_ok && page != 4'd0 && a != 16'hCFFF &&
                    (page[3] ? int_c8 : int_cx)) c = CLS_ROM;
            end else if (in_hi_f) begin
                if (rw) begin
                    c = lc_ramrd ? CLS_LC : (rom_ok ? CLS_ROM : CLS_BUS);
                end else begin
                    c  = lc_wren ? CLS_LC : CLS_ROM;
                    wr = lc_wren;
                end
            end else begin
                c  = CLS_RAM;
                wr = !rw;
            end
            classify = {c, wr};
        end
    endfunction

    wire [2:0] q_class = classify(q_addr, q_rw);
    assign q_cls = q_class[2:1];

    // ---- the internalized-switch question, beside q_cls ---------------------
    // Decoded from qd_addr - the one-clock-registered copy the divert
    // answer already uses - never the live address: a data address descends
    // from din through the AGU, and a live decode here was the design's
    // worst path by -0.74 ns the first time it was tried.  The register is
    // sufficient for the same reason q_divert's is: the sequencer cannot
    // decide before `settled`, one clock behind, so qd_addr always
    // describes the op being decided.  q_swi is therefore shallow LUTs off
    // registers, and the sequencer uses it DIRECTLY - re-registering it
    // would put it a clock behind dq_cls and misclassify.
    //
    // Writes: the mapping and video switches whose whole effect is the
    // shadow above ($C000-$C005, $C008/9, $C00C-$C00F - never INTCXROM or
    // SLOTC3ROM, the slot cards' trackers ride the bus stream), the video
    // toggles, the RamWorks bank, the language card.  Reads: the status
    // page (bit 7 from the shadow), the keyboard (the parked-dummy latch),
    // and the floating-value toggles/LC when fb_sim can answer; $C019 only
    // with the VBL level locked.  $C010 and the $C01x writes are the real
    // strobe's and always ride the bus.
    wire [3:0] qi_hi = qd_addr[7:4];
    wire [3:0] qi_lo = qd_addr[3:0];
    wire qi_io      = (qd_addr[15:8] == 8'hC0);
    wire qi_c00x_wr = (qi_hi == 4'h0) &&
                      (qi_lo[3:1] != 3'd3) && (qi_lo[3:1] != 3'd5);
    wire qi_c05x    = (qi_hi == 4'h5) && !qi_lo[3];        // $C050-$C057
    wire qi_c08x    = (qi_hi == 4'h8);
    wire qi_rwbk    = (qi_hi == 4'h7) && (qi_lo == 4'h1 || qi_lo == 4'h3);
    wire qi_wr = !q_rw && (qi_c00x_wr || qi_c05x || qi_c08x || qi_rwbk);
    wire qi_rd =  q_rw && ((qi_hi == 4'h0) ? swi_kbd_ok
                         : (qi_hi == 4'h1) ? ((qi_lo != 4'h0) &&
                                              (qi_lo != 4'h9 || swi_vbl_ok))
                         : (qi_c05x || qi_c08x) ? swi_fb_ok
                         : 1'b0);
    assign q_swi = swi_on && qi_io && (qi_wr || qi_rd);

    // The status page's byte, for the REGISTERED op: the switch in bit 7 -
    // $C019 is VBL', low while the beam is in blanking - over the keyboard
    // latch's low bits, as the IOU serves them.
    logic swi_stat_bit;
    always_comb begin
        case (op_addr[3:0])
            4'h1: swi_stat_bit = lc_bank2;
            4'h2: swi_stat_bit = lc_ramrd;
            4'h3: swi_stat_bit = ramrd;
            4'h4: swi_stat_bit = ramwrt;
            4'h5: swi_stat_bit = intcxrom;
            4'h6: swi_stat_bit = altzp;
            4'h7: swi_stat_bit = slotc3rom;
            4'h8: swi_stat_bit = store80;
            4'h9: swi_stat_bit = !swi_vbl;
            4'hA: swi_stat_bit = text;
            4'hB: swi_stat_bit = mixed;
            4'hC: swi_stat_bit = page2;
            4'hD: swi_stat_bit = hires;
            4'hE: swi_stat_bit = altchar;
            4'hF: swi_stat_bit = col80;
            default: swi_stat_bit = 1'b0;
        endcase
    end
    assign swi_stat_byte = {swi_stat_bit, swi_kbd_low};

    // ---- the TLB's page views ----------------------------------------------
    // The physical page a 256-byte page maps to, as a function of the page and
    // the switches - the page-granular restatement of the op path's "physical
    // address" block below, and kept textually parallel to it on purpose.
    function automatic [15:0] pa_page_of(input [7:0] pg, input rw);
        logic p_zp, p_text, p_hires, p_d, p_hi, p_aux_mid;
        logic [7:0] lc_pg, bank;
        begin
            p_zp    = (pg[7:1] == 7'd0);            // $0000-$01FF
            p_text  = (pg[7:2] == 6'b000001);       // $0400-$07FF
            p_hires = (pg[7:5] == 3'b001);          // $2000-$3FFF
            p_d     = (pg[7:4] == 4'hD);            // $D000-$DFFF
            p_hi    = (pg[7:4] >= 4'hD);            // $D000-$FFFF
            p_aux_mid = (store80 && p_text)           ? page2 :
                        (store80 && hires && p_hires) ? page2 :
                        (rw ? ramrd : ramwrt);
            lc_pg = (p_d && !lc_bank2) ? {4'hC, pg[3:0]} : pg;
            bank  = ((p_hi || p_zp) ? altzp : p_aux_mid) ? (rw_bank + 8'd1)
                                                         : 8'd0;
            pa_page_of = {bank, p_hi ? lc_pg : pg};
        end
    endfunction

    wire [2:0] t_r_class = classify({t_page, 8'h00}, 1'b1);
    wire [2:0] t_w_class = classify({t_page, 8'h00}, 1'b0);

    assign t_r_ok    = (t_r_class[2:1] != CLS_BUS) &&
                       (t_page != 8'hC3) && (t_page != 8'hCF);
    assign t_r_ppage = (t_r_class[2:1] == CLS_ROM)
                       ? {1'b1, 10'd0, t_page[5:0]}         // rom index a[13:8]
                       : {1'b0, pa_page_of(t_page, 1'b1)};
    assign t_w_ok    = t_w_class[0];                        // lands in the image
    assign t_w_ppage = {1'b0, pa_page_of(t_page, 1'b0)};

    wire [2:0] t2_w_class = classify({t2_page, 8'h00}, 1'b0);
    assign t2_w_ok    = t2_w_class[0];
    assign t2_w_ppage = {1'b0, pa_page_of(t2_page, 1'b0)};

    wire [2:0] t3_r_class = classify({t3_page, 8'h00}, 1'b1);
    wire [2:0] t3_w_class = classify({t3_page, 8'h00}, 1'b0);
    assign t3_r_ok    = (t3_r_class[2:1] != CLS_BUS) &&
                        (t3_page != 8'hC3) && (t3_page != 8'hCF);
    assign t3_r_ppage = (t3_r_class[2:1] == CLS_ROM)
                        ? {1'b1, 10'd0, t3_page[5:0]}
                        : {1'b0, pa_page_of(t3_page, 1'b1)};
    assign t3_w_ok    = t3_w_class[0];
    assign t3_w_ppage = {1'b0, pa_page_of(t3_page, 1'b0)};

    // ---- map changes, for the TLB flush ------------------------------------
    // Access-based, by decision: touching a mapping switch flushes whether or
    // not the value changed.  TEXT/MIXED/80COL are video-only and excluded -
    // split-screen code hammers $C050/$C052 every frame and none of them
    // enter the map.  PAGE2/HIRES do (80STORE), so $C054-$C057 flush.
    wire map_c00x = sw_c00x && !op_rw && (op_addr[3:1] <= 3'd5);
    // PAGE2 and HIRES move the MEMORY map only under 80STORE (UTAIIe 5-7:
    // without it they are display switches alone), so the flush is gated on
    // it: a page-flipping game touches $C054/$C055 every frame, and an
    // unconditional flush cold-started the TLB, the floating pages and the
    // zp/stack proof twice a frame for nothing.  The registers above still
    // update unconditionally, and the 80STORE access that would make them
    // matter is itself a flush.
    wire map_c05x = sw_c05x && (op_addr[3:1] == 3'd2 || op_addr[3:1] == 3'd3) &&
                    store80;
    wire map_c8_set = op_present && acc_c3xx && !intcxrom && !slotc3rom &&
                      !intc8rom;
    wire map_c8_clr = op_commit && acc_cfff && intc8rom;

    logic rom_ok_q;
    always_ff @(posedge clk) rom_ok_q <= rom_ok;

    assign map_changed = rst || !res_sync ||
                         (op_commit && (map_c00x || (sw_rwbk && !op_rw) ||
                                        map_c05x || sw_c08x)) ||
                         map_c8_set || map_c8_clr ||
                         (rom_ok != rom_ok_q);

    // ---- the driver's query ---------------------------------------------------------
    // Answered from a one-clock-registered copy of q_addr, NOT the live
    // value.  The driver samples q_divert once per bus cycle at T_PRESENT,
    // ~5 clocks after cyc_en advanced the core, so the address has been
    // stable for several clocks by then and the stale copy is always the
    // settled one (apple_bus_write asserts exactly that, in sim, at every
    // sample).  Live, this decode sat at the end of the turbo fetch cone -
    // icache row -> AGU -> cpu_addr -> here - and was the design's worst
    // setup path; the register cuts the cone at cpu_addr for free.  The
    // switches stay live: they are registered locally and change at
    // op_commit, never in the clock before a present.
    logic [15:0] qd_addr;
    always_ff @(posedge clk) qd_addr <= q_addr;
    wire q_zp    = (qd_addr[15:9]  == 7'd0);
    wire q_text  = (qd_addr[15:10] == 6'b000001);
    wire q_hires = (qd_addr[15:13] == 3'b001);
    wire q_io    = (qd_addr[15:12] == 4'hC);
    wire q_hi    = (qd_addr[15:12] >= 4'hD);
    wire q_aux_mid = (store80 && q_text)           ? page2 :
                     (store80 && hires && q_hires) ? page2 : ramwrt;
    wire q_aux   = (q_hi || q_zp) ? altzp : q_aux_mid;
    assign q_divert = (rw_bank != 8'd0) && !q_io && q_aux;

    // ---- the physical address ----------------------------------------------------
    wire in_zp    = (op_addr[15:9]  == 7'd0);           // $0000-$01FF
    wire in_text  = (op_addr[15:10] == 6'b000001);      // $0400-$07FF
    wire in_hires = (op_addr[15:13] == 3'b001);         // $2000-$3FFF
    wire in_d     = (op_addr[15:12] == 4'hD);           // $D000-$DFFF
    wire in_hi    = (op_addr[15:12] >= 4'hD);           // $D000-$FFFF

    // Which bank a RAM access reaches.  80STORE takes the text page - and the
    // hires page with HIRES - away from RAMRD/RAMWRT and hands them to PAGE2;
    // ALTZP owns the zero page, the stack and the language card.
    wire aux_mid = (store80 && in_text)           ? page2 :
                   (store80 && hires && in_hires) ? page2 :
                   (op_rw ? ramrd : ramwrt);
    wire aux_sel = in_zp ? altzp : aux_mid;

    // Which image bank: main is 0, and an auxiliary access reaches RamWorks
    // bank rw_bank, which is image bank rw_bank + 1.
    wire [7:0] aux_bank = rw_bank + 8'd1;

    // The language card's RAM: bank 1 of $D000 lives in the image's $C000 hole.
    wire [15:0] lc_off = (in_d && !lc_bank2) ? {4'hC, op_addr[11:0]} : op_addr;

    wire [2:0]  n_class    = classify(op_addr, op_rw);
    wire [1:0]  n_cls      = n_class[2:1];
    wire        n_wr_image = n_class[0];
    wire [23:0] n_pa       = in_hi ? {altzp ? aux_bank : 8'd0, lc_off}
                                   : {aux_sel ? aux_bank : 8'd0, op_addr};

    always_ff @(posedge clk) begin
        if (rst) begin
            cl_valid    <= 1'b0;
            cl_cls      <= CLS_BUS;
            cl_pa       <= 24'd0;
            cl_rom_addr <= 14'd0;
            cl_rw       <= 1'b1;
            cl_wr_image <= 1'b0;
        end else begin
            cl_valid <= op_present;
            if (op_present) begin
                cl_cls      <= n_cls;
                cl_pa       <= n_pa;
                cl_rom_addr <= op_addr[13:0];
                cl_rw       <= op_rw;
                cl_wr_image <= n_wr_image;
            end
        end
    end

endmodule
