`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// apple_mmu - the IIe's memory map, shadowed: which memory does this op touch?
//
// The card is about to keep its own copy of the Apple's memory (rtl/page_cache.sv)
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
// The classified op is that fold (cl_off, the offset in a 64 KB bank), a
// main-or-auxiliary bit (cl_aux), and the RamWorks bank register AS WRITTEN
// (cl_bank).  MAIN memory lives in its own block RAM bank
// (rtl/page_cache.sv) and nothing banks it; an auxiliary access reaches
// RamWorks bank cl_bank, and the DDR3 backs the banks that are not resident.
// There is no 24-bit physical address and no +1 anywhere: RamWorks bank k is
// DDR3 aux bank k (docs/PAGE_CACHE.md).  pf_off is cl_off's combinational
// preview, valid with op_present, so the banks' block RAMs can be addressed
// the clock BEFORE the classification lands - the classifier runs beside the
// fetch, not in front of it.
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
// Here the card IS the RamWorks, with RW_BANKS = 255 banks: bank k is DDR3
// aux bank k, the regular auxiliary memory (bank 0) at the region's start.
// A write of a bank number that does not exist (255) is ignored and the
// register keeps its value, which is what AppleWin does for a bank beyond
// the configured size.
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
// in the same clock from the switches as they stand: would a WRITE here reach
// auxiliary memory in a bank other than 0?  The driver adds the one condition
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
// SLOTC3ROM is clear - in EITHER state of INTCXROM (UTAIIe 5-28, AppleWin's
// Memory.cpp: with INTCXROM set the latch is invisible until INTCXROM is
// cleared again, and then $C800-$CFFF stays the internal ROM's without a
// $C3xx access in between) - cleared by any access to $CFFF or by RES'.  It
// decides whether $C800-$CFFF is the internal ROM's.  It is set at
// op_present rather than op_commit, because a $C3xx fetch served from the
// card has no data phase on the bus - and for one that does, present-versus-
// commit only differs for the NEXT op, which cannot be presented before this
// one's commit.  $CFFF is a bus op and clears it at commit like every other
// switch.  MEM_STAT[13] reads it.  The instruction front (rtl/iline.sv)
// serves page $C3 only while the latch is SET: a turbo retire never reaches
// this stream, so the access that sets it always rides the sequencer.
//
// The internal ROM not yet loaded classifies as BUS, so "ROM class" always
// means "the card has the byte": rtl/page_cache.sv needs no further check.
//
// NOT MODELLED, deliberately: a physical card's $C800-$CFFF expansion ROM and
// the per-slot I/O SELECT flip-flops that pick it - that page is BUS unless
// the internal ROM answers, and the machine does the rest.
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

    // The classified op, one clock after op_present - or a POSTED WRITE
    // from the data front (rtl/dline.sv, rung 3), taken from pw_* on a
    // clock the op path is idle: it arrives already stamped {aux, bank,
    // folded off} under the map of its retire, and is copied into cl_*
    // as an image write with cl_posted set.  Nothing is re-classified:
    // the map cannot have moved since (every map-changing op waits for
    // the front's pending to clear).  cl_wdata carries the write's byte
    // for both kinds - the stream's op_wdata, or the posted entry's.
    output logic        cl_valid,
    output logic [1:0]  cl_cls,        // CLS_*
    output logic        cl_aux,        // reaches the auxiliary memory
    output logic [7:0]  cl_bank,       // the RamWorks bank, as written
    output logic [15:0] cl_off,        // offset in a 64 KB bank, LC folded
    output logic        cl_rw,
    output logic        cl_wr_image,   // a write that lands in the image
    output logic        cl_posted,     // a posted write draining, not an op
    output logic [7:0]  cl_wdata,      // the write's byte
    // The posted FIFO's head, and the page cache's leave to take it.
    input  wire         pw_valid,
    input  wire         pw_aux,
    input  wire [7:0]   pw_bank,
    input  wire [15:0]  pw_off,
    input  wire [7:0]   pw_data,
    input  wire         pw_ready,      // the page cache's pipeline is clear
    output wire         pw_take,       // pulse: cl_* carries it next clock
    // The INTC8ROM latch, for MEM_STAT.
    output logic        intc8rom,
    // cl_off's combinational preview, valid with op_present: the banks'
    // block RAMs are addressed from this the clock before cl_* stands.
    output wire  [15:0] pf_off,

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

    // ...and the instruction front's (rtl/iline.sv): classify a READ of
    // p_addr - a line about to be prefetched - into its class, its bank side
    // and its folded offset, on the switches as they stand.  Combinational,
    // same functions again; the wanted RamWorks bank is rw_bank above.
    input  wire [15:0] p_addr,
    output wire [1:0]  p_cls,
    output wire        p_aux,
    output wire [15:0] p_off,

    // ...and the data front's (rtl/dline.sv): the same question for a DATA
    // access at d_addr - rooted at dline's REGISTERED candidate address, so
    // this cone runs through the serve cycle, never on d_pred's late cone.
    // d_rw picks the bank side a write would take (rung 3 stamps posted
    // writes through this same port); the wanted RamWorks bank is rw_bank.
    input  wire [15:0] d_addr,
    input  wire        d_rw,
    output wire [1:0]  d_cls,
    output wire        d_aux,
    output wire [15:0] d_off,
    // One pulse whenever anything that feeds classification moved - a soft
    // switch, the language card, the bank register, INTC8ROM, a reset.  The
    // front's held lines die on it: their classification was captured when
    // they were fetched.
    output logic       map_changed
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
    logic text, mixed, col80;
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
                    default: ;
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

    // ---- INTC8ROM --------------------------------------------------------------
    // Set at present, cleared at commit - see the header for why they differ.
    wire acc_c3xx = (op_addr[15:8] == 8'hC3);
    wire acc_cfff = (op_addr == 16'hCFFF);
    always_ff @(posedge clk) begin
        if (rst || !res_sync)                                       intc8rom <= 1'b0;
        else if (op_present && acc_c3xx && !slotc3rom)              intc8rom <= 1'b1;
        else if (op_commit && acc_cfff)                             intc8rom <= 1'b0;
    end

    // ---- the classifier, as a function of the address and the switches ---------
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

    // ---- the instruction front's query ------------------------------------------
    // A read's classification and steering for a line address: the same
    // functions the presented op goes through, asked out of band.
    wire p_zp    = (p_addr[15:9]  == 7'd0);
    wire p_text  = (p_addr[15:10] == 6'b000001);
    wire p_hires = (p_addr[15:13] == 3'b001);
    wire p_d     = (p_addr[15:12] == 4'hD);
    wire p_hi    = (p_addr[15:12] >= 4'hD);
    wire p_mid   = (store80 && p_text)           ? page2 :
                   (store80 && hires && p_hires) ? page2 : ramrd;
    wire [2:0] p_class = classify(p_addr, 1'b1);
    assign p_cls = p_class[2:1];
    assign p_aux = (p_hi || p_zp) ? altzp : p_mid;
    assign p_off = (p_d && !lc_bank2) ? {4'hC, p_addr[11:0]} : p_addr;

    // ---- the data front's query ---------------------------------------------------
    wire d_zp_w    = (d_addr[15:9]  == 7'd0);
    wire d_text_w  = (d_addr[15:10] == 6'b000001);
    wire d_hires_w = (d_addr[15:13] == 3'b001);
    wire d_d_w     = (d_addr[15:12] == 4'hD);
    wire d_hi_w    = (d_addr[15:12] >= 4'hD);
    wire d_mid_w   = (store80 && d_text_w)           ? page2 :
                     (store80 && hires && d_hires_w) ? page2 :
                     (d_rw ? ramrd : ramwrt);
    wire [2:0] d_class = classify(d_addr, d_rw);
    assign d_cls = d_class[2:1];
    assign d_aux = (d_hi_w || d_zp_w) ? altzp : d_mid_w;
    assign d_off = (d_d_w && !lc_bank2) ? {4'hC, d_addr[11:0]} : d_addr;

    // ---- the map's edge -----------------------------------------------------------
    // Everything classification reads, watched as one word; sw_state carries
    // the LC and every switch, and the bank register and INTC8ROM ride along.
    logic [20:0] map_q;
    always_ff @(posedge clk) begin
        map_q       <= {sw_state, intc8rom, rw_bank};
        map_changed <= rst || !res_sync || (map_q != {sw_state, intc8rom, rw_bank});
    end

    // ---- the driver's query ---------------------------------------------------------
    wire q_zp    = (q_addr[15:9]  == 7'd0);
    wire q_text  = (q_addr[15:10] == 6'b000001);
    wire q_hires = (q_addr[15:13] == 3'b001);
    wire q_io    = (q_addr[15:12] == 4'hC);
    wire q_hi    = (q_addr[15:12] >= 4'hD);
    wire q_aux_mid = (store80 && q_text)           ? page2 :
                     (store80 && hires && q_hires) ? page2 : ramwrt;
    wire q_aux   = (q_hi || q_zp) ? altzp : q_aux_mid;
    assign q_divert = (rw_bank != 8'd0) && !q_io && q_aux;

    // ---- the physical page --------------------------------------------------------
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

    // The language card's RAM: bank 1 of $D000 lives in the bank's $C000
    // hole.  This is the whole of the offset's classification, so it is also
    // the preview the banks' block RAMs are addressed from at op_present -
    // one mux on a registered switch, beside the fetch, not in front of it.
    assign pf_off = (in_d && !lc_bank2) ? {4'hC, op_addr[11:0]} : op_addr;

    wire [2:0] n_class    = classify(op_addr, op_rw);
    wire [1:0] n_cls      = n_class[2:1];
    wire       n_wr_image = n_class[0];
    wire       n_aux      = in_hi ? altzp : aux_sel;

    // A posted write takes the classified stage only when no op is being
    // presented: the op's is the older claim on the pipeline.
    assign pw_take = pw_valid && pw_ready && !op_present && !rst;

    always_ff @(posedge clk) begin
        if (rst) begin
            cl_valid    <= 1'b0;
            cl_cls      <= CLS_BUS;
            cl_aux      <= 1'b0;
            cl_bank     <= 8'd0;
            cl_off      <= 16'd0;
            cl_rw       <= 1'b1;
            cl_wr_image <= 1'b0;
            cl_posted   <= 1'b0;
            cl_wdata    <= 8'd0;
        end else begin
            cl_valid <= op_present || pw_take;
            if (op_present) begin
                cl_cls      <= n_cls;
                cl_aux      <= n_aux;
                cl_bank     <= rw_bank;
                cl_off      <= pf_off;
                cl_rw       <= op_rw;
                cl_wr_image <= n_wr_image;
                cl_posted   <= 1'b0;
                cl_wdata    <= op_wdata;
            end else if (pw_take) begin
                cl_cls      <= CLS_RAM;      // the front posts RAM class only
                cl_aux      <= pw_aux;
                cl_bank     <= pw_bank;
                cl_off      <= pw_off;
                cl_rw       <= 1'b0;
                cl_wr_image <= 1'b1;
                cl_posted   <= 1'b1;
                cl_wdata    <= pw_data;
            end
        end
    end

endmodule
