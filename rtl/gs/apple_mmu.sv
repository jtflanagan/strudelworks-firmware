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
// That triple is the OLD name for the byte and survives only until the page
// cache is physical (docs/PAGE_CACHE.md, Part 3); the new one is the PPN
// below, where RamWorks bank k is physical bank k+1.  pf_off is cl_off's
// combinational
// preview, valid with op_present, so the banks' block RAMs can be addressed
// the clock BEFORE the classification lands - the classifier runs beside the
// fetch, not in front of it.  pf_ppn is the same preview in the new space.
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
// Here the card IS the RamWorks, with RW_BANKS = 254 banks: RamWorks bank k
// is PHYSICAL bank k+1, the regular auxiliary memory (bank 0) at physical
// bank 1.  A write of a bank number that does not exist (254 or 255) is
// ignored and the register keeps its value, which is what AppleWin does for
// a bank beyond the configured size.  254 rather than 255 because physical
// bank $FF is the internal ROM's - see THE PHYSICAL SPACE below.
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
//
// THE PHYSICAL SPACE (docs/PAGE_CACHE.md, the 24-bit rethink).  Beside the
// old {aux, bank, folded offset} triple this module now hands out a PHYSICAL
// PAGE NUMBER, one flat name for the byte in a 16 MB space:
//
//   PPN[15:0] = {bank[7:0], page[7:0]},  byte address {PPN, off[7:0]}
//   bank 0    main memory
//   bank 1    the regular auxiliary memory, i.e. RamWorks bank 0
//   bank k+1  RamWorks bank k            (so physical 1..254)
//   bank $FF  the internal ROM, at its offsets $C000-$FFFF
//
// This is the host mirror's convention already (apple_memory.hpp: image bank
// 0 main, banks 1.. the RamWorks banks), so the two images are again the same
// bytes in the same order.  The language card's fold stays INSIDE a bank -
// bank 1 of $D000 at that bank's $C000-$CFFF - and $Cxxx CPU addresses never
// translate to a RAM bank's $Cx pages, which hold the fold; $C000-$C0FF is
// BUS always, $C100-$CFFF is bank $FF or BUS.
//
// THE REGION TABLE.  The IIe's map has ten REGIONS of the 16-bit space, each
// a function of the soft switches alone - a[7:0] never enters (the two
// byte-level facts, $CFFF and iline's $CFF0 line, stay explicit overrides):
//
//   R_ZP  $00-01   R_TXT $04-07   R_HGR $20-3F   R_RAM the rest below $C0
//   R_IO  $C0      R_CXL $C1,$C2,$C4-$C7        R_C3  $C3    R_C8 $C8-$CF
//   R_LCD $Dx      R_LCE $Ex-$Fx
//
// So the whole map is TWO TABLES OF TEN ENTRIES - one for reads, one for
// writes - each entry {cls, wr, bsel, fold, fs}: the class, whether a write
// lands in the image, which bank side (main / aux / ROM), whether the
// language card's fold applies, and FS, "front-servable", which replaces the
// fronts' own `cls != BUS` plus iline's page-$C3 rule.  The tables are
// REGISTERED and recomputed every clock from the switch registers, so they
// are new exactly when map_changed rises, one clock behind the switches; the
// settle after a switch-changing commit is what keeps any op from reading
// them in that clock.  xlate() is then a mux and a fold, not a decode - and
// the fronts can recompute a HELD line's validity from its stored region
// without re-classifying it (rt_rd_flat, docs/PAGE_CACHE.md).
//
// 65816 READINESS.  xlate() takes a 24-bit address.  Banks 2 and up are RAM
// no IIe switch touches and map to themselves; banks 0 and 1 go through the
// region table.  Nothing drives a bank above 0 yet.
//////////////////////////////////////////////////////////////////////////////////
module apple_mmu #(
    // THE MACHINE.  0 = the Apple IIe this card lives in; 1 = the IIgs the
    // soft 65816 runs (docs/GS.md).  At GS = 0 every GS-only register reads
    // zero, every GS-only term folds away, and the map is bit-for-bit the
    // one the IIe sweep has always checked - which is the parity gate.
    parameter bit GS   = 1'b0,
    // The region table's shape.  Not meant to be overridden: they are here
    // so the packed table can be a port.  Entry = {sh, cls[1:0], wr,
    // bsel[1:0], fold, fs}.
    parameter int NREG = 13,
    parameter int RT_W = 8,
    // THE GS's MAP IS OURS ABOVE $7F (docs/ENHANCED_VIDEO.md R0).  Every
    // bank is memory - the DDR3 image is the 24-bit space one to one - so
    // there is no "void": $00-$EF are RAM (bar the Mega II's $E0/$E1), and
    // $F0-$FF are ROM space, identity-mapped and read-only: our own from $F0
    // (the panel, docs/GS_CONTROL_PANEL.md), the machine's at its top ($FC
    // for a ROM 3).  The ROM's memory sizing stops at $80, so what we put
    // above it is ours: $80-$DF the enhanced video banks, $E2 their control
    // bank, $EF the panel's RAM.
    parameter logic [7:0] GS_ROM_LO = 8'hF0,
    // CYAREG's POWER-ON value (KEGS moremem.c:61 and sim65816.c:714): bit 7
    // is the speed bit, set, and bit 6 is the POWER-ON STATUS BIT, which a
    // ROM 3 sets at startup and reads back to tell a cold start from a warm
    // one.  It survives RES' - KEGS sets it before do_reset() and do_reset()
    // does not touch it - which is why this register is reset by the card's
    // `rst` alone below and not by res_sync.
    parameter logic [7:0] GS_CYAREG_POR = 8'hC0
) (
    input  wire        clk,
    input  wire        rst,
    // Synchronised RES', ACTIVE LOW.
    input  wire        res_sync,

    // The presented op, from apple_bus_write.
    // THE BANK RIDES WITH IT (docs/GS.md rung 3).  On the IIe the unified
    // stream is 16 bits and this is tied to zero, which is exactly what it
    // means; on the IIgs it is the 65816's addr[23:16], and it decides both
    // the bank class the address is translated under and whether $C0xx is
    // the I/O page at all - only a PAIR bank has I/O there.
    input  wire [7:0]  op_bank,
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
    // clock the op path is idle: it arrives already stamped with its
    // PHYSICAL PAGE under the map of its retire, and is copied into cl_*
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
    // The IIgs's SHADOW ($C035): this write ALSO lands in the matching Mega
    // II bank.  The destination is {8'hE0 | cl_ppn[8], cl_ppn[7:0]} - the
    // same page in $E0 or $E1 by the side the write landed on - so only the
    // bit needs carrying.  Always 0 at GS = 0.
    output logic        cl_sh,
    // Shadowed writes that arrived while one was still in hand.  Must be 0:
    // see the note on the duplicate's depth.  A bench asserts on it.
    output logic [7:0]  shd_drops,
    // The write's data: a byte replicated into all four lanes (an op, a
    // posted byte, a duplicate), or the RISC-V engine's word.  cl_be are its
    // lanes from cl_off: 4'b0001 for a byte, the engine's enables for a word
    // (cl_off word aligned), so the row's lanes are cl_be << cl_off[3:0].
    output logic [31:0] cl_wdata,
    output logic [3:0]  cl_be,
    output logic        cl_eng,        // the engine's write: no L1 holds its bytes
    // The posted FIFO's head, and the page cache's leave to take it.
    input  wire         pw_valid,
    input  wire [15:0]  pw_ppn,        // the entry's PHYSICAL page, stamped at its retire
    input  wire [7:0]   pw_off,        // ...and the byte in it
    input  wire [7:0]   pw_data,
    input  wire         pw_ready,      // the page cache's pipeline is clear
    output wire         pw_take,       // pulse: cl_* carries it next clock
    // THE RISC-V ENGINE'S STORES (docs/REQ_RVVM.md, rung 3b): an aligned word
    // with byte enables, already a physical page (the engine's banks are
    // RAM under every map), posted the same way after L1-D's FIFO - the
    // 65816's writes are the older ones.
    input  wire         pe_valid,
    input  wire [15:0]  pe_ppn,
    input  wire [7:0]   pe_off,        // word aligned
    input  wire [3:0]   pe_be,
    input  wire [31:0]  pe_data,
    output wire         pe_take,       // pulse: cl_* carries it next clock
    // THE SHADOW DUPLICATE'S ENTRANT, for the same reason pw_take is one:
    // it sets cl_valid a clock later exactly as a posted write does, so the
    // cache must open a P0 for it or it arrives with no directory read of
    // its own (docs/GS.md rung 3e).
    output wire         shd_take_o,
    output wire [15:0]  shd_ppn_o,
    output wire [7:0]   shd_off_o,
    // The INTC8ROM latch, for MEM_STAT.
    output logic        intc8rom,
    // cl_off's combinational preview, valid with op_present: the banks'
    // block RAMs are addressed from this the clock before cl_* stands.
    output wire  [15:0] pf_off,
    // ...and the same two in the PHYSICAL space (header, THE PHYSICAL
    // SPACE): the classified op's page, and its preview - the physical page
    // cache's P0 index source.  Nothing consumes these yet; the old triple
    // above is still what rtl/page_cache.sv takes.
    output logic [15:0] cl_ppn,
    output wire  [15:0] pf_ppn,

    // The switches, for a status register:
    //   {prewrite, wren, lc_ramrd, bank2, slotc3rom, intcxrom, hires, page2,
    //    altzp, ramwrt, ramrd, store80}
    output wire [11:0] sw_state,
    // The video switches: {col80, mixed, text}.  Separate from sw_state,
    // whose packing MEM_STAT and the host's mirror carry bit for bit.
    output wire [2:0]  vid_sw,
    // The RamWorks bank register, for MEM_CTRL's readback.
    output logic [7:0] rw_bank,
    // The IIgs's own registers, for rtl/gs_io.sv to read back.  The map holds
    // them because the map is what they steer; the chipset's face answers
    // them because $C0xx is its window (docs/GS.md rung 3b).  All zero at
    // GS = 0 except CYAREG, which is not built there either.
    output wire  [7:0] gs_shadow_o,
    output wire  [7:0] gs_cyareg_o,
    output wire  [7:0] gs_sltrom_o,
    // STATEREG composed back out of the seven switches a write to it moved
    // (KEGS set_statereg, moremem.c:606): ALTZP, PAGE2, RAMRD, RAMWRT, RDROM,
    // LCBANK2, ROMBANK, INTCXROM.  ROMBANK is always 0: this machine has one
    // ROM image.
    output wire  [7:0] gs_state_o,

    // The driver's question, combinational: would a write to q_addr, presented
    // now, reach auxiliary memory in a RamWorks bank other than 0?  See the
    // header.  q_addr is the address the driver is about to latch, so this is
    // decided on the switches as they stood before the cycle - the same
    // switches the classifier below will use for that op.
    // 24 BITS.  Every query port takes a full physical-space address, because
    // on the IIgs the bank is part of the question and the same 16 bits mean
    // different memory in different banks (docs/GS.md).  The IIe's callers
    // zero-extend, which is exactly what they mean.
    input  wire [23:0] q_addr,
    output wire        q_divert,
    // ...and the sequencer's: what class would an op at q_addr, read or
    // write, be if presented now?  Same switches, same function as the
    // classifier below, combinational.  rtl/accel_seq.sv decides on it.
    input  wire        q_rw,
    output wire [1:0]  q_cls,
    // ...and the internalized ops' question beside it (docs/CXXX.md, "The
    // switch reads in the closed regime" and "The switch writes"): would an
    // op at q_addr be one the card answers itself?  A READ: the status page
    // from this shadow, the keyboard from the parked-dummy latch, $C019 from
    // the VBL lock, a floating value from the floating-bus simulator.  A
    // WRITE: a switch whose whole effect is this shadow's - the memory-
    // mapping and IOU strobes of $C00x, the video toggles, the language
    // card - and NOT INTCXROM/SLOTC3ROM, which the motherboard must keep
    // seeing (they route I/O SELECT' to the slots; header).  swi_stat_byte
    // is the status page's answer for the REGISTERED op (op_addr, stable
    // through the fast sequence).  q_swi_quiet says the op would change no
    // switch, so its word can stay off a sparse stream (a vapor-lock poll of
    // $C054 at the core's pace would flood the link otherwise).
    input  wire        swi_on,        // the closed-regime level, chicken bit included
    input  wire        slot_on,       // the on-card hard disk's slot answered fast (the IIgs build: docs/CORE_REFACTOR_65816.md rung 4)
    input  wire        swi_kbd_ok,    // the keyboard latch holds a byte
    input  wire        swi_fb_ok,     // fb_sim can answer a floating read
    input  wire        swi_vbl_ok,    // the VBL lock stands
    input  wire        swi_vbl_bar,   // ...and this is the IIe's $C019 bit 7 now
    input  wire [6:0]  swi_kbd_low,   // the keyboard latch's low bits, under bit 7
    input  wire        swi_pb_ok,     // the game port's buttons are sampled (rtl/game_port.sv)
    input  wire        swi_pdl_ok,    // ...and a paddle measurement has completed
    // The card's OWN slots (docs/CXXX.md, "The on-card slots"): the hard
    // disk's, the floppy's and the Mockingboard's slot numbers, 0 = none.
    // An access a peripheral on this card would answer - its DEVICE SELECT
    // range $C0n0-$C0nF, or its I/O SELECT page $Cn00-$CnFF while the slot
    // owns it - is served on the card in the closed regime: q_slot marks
    // it, and q_swi includes it.
    input  wire [2:0]  swi_hd_slot,
    input  wire [2:0]  swi_fd_slot,
    input  wire [2:0]  swi_mb_slot,
    input  wire [2:0]  swi_mouse_slot,
    input  wire [2:0]  swi_u2_slot,    // the Uthernet II: DEVICE SELECT only, it has no ROM
    input  wire [2:0]  swi_prn_slot,   // the printer card: its ROM page and its device select
    output wire        q_swi,
    output wire        q_swi_quiet,
    output wire        q_slot,
    output wire [7:0]  swi_stat_byte,
    // ...and every switch the status page reports, bit n for $C01n (bit 0
    // unused), for the IIgs data front's fast reads (rtl/gs_io.sv fr_vec).
    output wire [15:0] swi_stat_bits,
    // ...and the No-Slot Clock's (rtl/no_slot_clock.sv): is q_addr in a
    // page the clock listens at - the internal ROM's $C3 while that page is
    // the internal ROM's, or its $C8 while the internal ROM is there.  Every
    // mode, serving or not: the clock is a part under the ROM, not a serve.
    output wire        q_nsc,

    // ...and the instruction front's (rtl/iline.sv): classify a READ of
    // p_addr - a line about to be prefetched - into its class, its bank side
    // and its folded offset, on the switches as they stand.  Combinational,
    // same functions again; the wanted RamWorks bank is rw_bank above.
    input  wire [23:0] p_addr,
    output wire [1:0]  p_cls,
    output wire        p_aux,
    output wire [15:0] p_off,
    // ...and its physical identity: the page, the REGION the line is
    // classified in - the index the front revalidates through - the fold
    // bit, and FS, which is what the front should ask instead of
    // `p_cls != BUS` (it carries iline's page-$C3 rule too).
    output wire [15:0] p_ppn,
    output wire [3:0]  p_reg,
    output wire        p_fold,
    output wire        p_fs,

    // ...and the data front's (rtl/dline.sv): the same question for a DATA
    // access at d_addr - rooted at dline's REGISTERED candidate address, so
    // this cone runs through the serve cycle, never on d_pred's late cone.
    // d_rw picks the bank side a write would take (rung 3 stamps posted
    // writes through this same port); the wanted RamWorks bank is rw_bank.
    input  wire [23:0] d_addr,
    input  wire        d_rw,
    output wire [1:0]  d_cls,
    output wire        d_aux,
    output wire [15:0] d_off,
    output wire [15:0] d_ppn,
    output wire [3:0]  d_reg,
    output wire        d_fold,
    // ...and the write query's shadow answer, the same bit for d_addr.
    output wire        d_sh,
    // One pulse whenever anything that feeds classification moved - a soft
    // switch, the language card, the bank register, INTC8ROM, a reset.  The
    // front's held lines die on it: their classification was captured when
    // they were fetched.
    output logic       map_changed,
    // ...stretched to the three clocks a REVALIDATION takes: map_changed
    // itself and the two after it, by which time every front's valid bits
    // and the registers derived from them stand under the new map.  The
    // sequencer's turbo leash and the fronts' fill triggers hold on this.
    output wire        map_settling,
    // The read table, packed ten entries of RT_W bits, and the PHYSICAL bank
    // a RamWorks access reaches (rw_bank + 1), both registered: a front
    // recomputes a held line's validity from its stored region against
    // these, without re-classifying the line's address.
    output wire [NREG*RT_W-1:0] rt_rd_flat,
    output wire [7:0]  rwb_p1
    // THE BANK REGISTERS ARE NOT PART OF THE MAP ANY MORE (rung 5,
    // 2026-09-20).  They joined it at rung 6 because the fronts' lines were
    // "valid in the bank they were fetched in" - a line carried no bank, so a
    // JSL, a PLB or an RTL moved the bank out from under every held line and
    // the only safe answer was to call it a map change and revalidate all of
    // them.  Rungs 2 and 3 ended that: the TLB is keyed by {bank, page}, L1-I
    // tags its buffers {bank, addr[15:4]} and l1d's candidate is 24 bits, so
    // EVERY HELD LINE CARRIES ITS OWN BANK.  A bank-register write translates
    // nothing differently; a lookup in another bank simply misses.  So PBR and
    // DBR are out of map_now, and with them the settle every write of one used
    // to cost.
);

    // RamWorks banks: 0..RW_BANKS-1 exist; a write of any other number is
    // ignored.  254 of them, plus main memory, plus the internal ROM at
    // physical bank $FF, are the 16 MB space's 256 banks.
    localparam [7:0] RW_BANKS = 8'd254;

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

    // ---- the IIgs registers (docs/GS.md; KEGS moremem.c) ---------------------
    // All four are inert at GS = 0: the strobes below are gated on GS, so
    // the registers hold their reset value and every term they feed folds
    // away.  A IIe access to $C035 or $C068 is an ordinary bus cycle.
    //
    //   $C035 SHADOW   a SET bit INHIBITS shadowing.  [0] text page 1,
    //                  [1] hires page 1, [2] hires page 2, [3] Super Hi-Res,
    //                  [4] the auxiliary bank's hires, [5] text page 2,
    //                  [6] I/O and the language card in banks $00/$01.
    //   $C036 CYAREG   [7] fast, [4] shadow in all banks.  The speed bit is
    //                  read by the governor, not by the map.
    //   $C068 STATEREG the IIe switches as ONE register, exactly as the real
    //                  FPI has them: [7] ALTZP, [6] PAGE2, [5] RAMRD,
    //                  [4] RAMWRT, [3] RDROM, [2] LCBANK2, [1] ROMBANK,
    //                  [0] INTCXROM.  Writing it moves seven switches at
    //                  once; reading it composes them back.
    //   $C02D SLOTROMSEL  bit n = slot n answers $Cn00-$CnFF rather than the
    //                  internal ROM.  Bits 0 and 3 are not slots.
    logic [6:0] gs_shadow;
    logic [7:0] gs_cyareg;
    logic [7:0] gs_sltrom;

    // $C0xx is the I/O page in a PAIR bank ($00/$01/$E0/$E1) and nowhere
    // else: on the IIgs bank $02's $C0xx is plain RAM and moves no switch.
    // gs_pair() itself is declared with the bank classes below, so the test
    // is written out here rather than called.
    wire op_pair = !GS || (op_bank == 8'h00) || (op_bank == 8'h01) ||
                          (op_bank == 8'hE0) || (op_bank == 8'hE1);
    wire io_page = op_pair && (op_addr[15:8] == 8'hC0);
    wire sw_c00x = io_page && (op_addr[7:4] == 4'h0);      // $C000-$C00F
    wire sw_c05x = io_page && (op_addr[7:4] == 4'h5);      // $C050-$C05F
    // $C071 and $C073: the RamWorks bank register, a write of the bank number.
    wire sw_rwbk = io_page && (op_addr[7:4] == 4'h7) &&
                   (op_addr[3:0] == 4'h1 || op_addr[3:0] == 4'h3);
    wire sw_c08x = io_page && (op_addr[7:4] == 4'h8);      // $C080-$C08F
    wire gs_shadow_w = GS && io_page && (op_addr[7:0] == 8'h35) && !op_rw;
    wire gs_cyareg_w = GS && io_page && (op_addr[7:0] == 8'h36) && !op_rw;
    wire gs_state_w  = GS && io_page && (op_addr[7:0] == 8'h68) && !op_rw;
    wire gs_sltrom_w = GS && io_page && (op_addr[7:0] == 8'h2D) && !op_rw;

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
            // The GS's own registers.  SHADOW clear means everything is
            // shadowed, which is the state the ROM's reset code expects
            // (KEGS do_reset: $C035 = 0).  CYAREG's power-on bit is the
            // host's to set; the map does not read it.
            gs_shadow   <= 7'd0;
            gs_sltrom   <= 8'd0;
            // CYAREG IS RESET BY THE CARD'S RESET AND NOT BY RES'.  Its bit 6
            // is the power-on status a ROM 3 reads to tell a cold start from
            // a warm one, so a warm one must leave it alone: KEGS sets it
            // before do_reset() and do_reset() does not touch it
            // (sim65816.c:714).  One block still drives this register - the
            // two resets are told apart here, not split into two writers.
            if (rst) gs_cyareg <= GS ? GS_CYAREG_POR : 8'd0;
        end else if (op_commit) begin
            if (gs_shadow_w) gs_shadow <= op_wdata[6:0];
            // CYAREG keeps bit 5 clear on every write (KEGS moremem.c:1713).
            if (gs_cyareg_w) gs_cyareg <= op_wdata & ~8'h20;
            // $C02D and the SLOTC3ROM strobe are ONE register in the
            // reference (KEGS routes $C00A/B into g_c02d_int_crom bit 3), so
            // a write to either keeps both in step.  That is also why the
            // IIe's $C3 rule falls straight out of the IIgs's: "internal
            // unless this slot's bit is set" with bit 3 IS "internal unless
            // SLOTC3ROM".
            if (gs_sltrom_w) begin
                gs_sltrom <= op_wdata;
                slotc3rom <= op_wdata[3];
            end
            // STATEREG moves seven switches at once.  It is the same state
            // the individual strobes below reach, so it is written here and
            // nowhere else: two writers of one register is how they drift.
            if (gs_state_w) begin
                altzp    <= op_wdata[7];
                page2    <= op_wdata[6];
                ramrd    <= op_wdata[5];
                ramwrt   <= op_wdata[4];
                lc_ramrd <= !op_wdata[3];   // RDROM is the complement of "read the RAM"
                lc_bank2 <= op_wdata[2];
                intcxrom <= op_wdata[0];
            end
            // $C000-$C00F: write strobes, the address selects the switch, A0
            // the value.
            if (sw_c00x && !op_rw) begin
                case (op_addr[3:1])
                    3'd0: store80   <= op_addr[0];
                    3'd1: ramrd     <= op_addr[0];
                    3'd2: ramwrt    <= op_addr[0];
                    3'd3: intcxrom  <= op_addr[0];
                    3'd4: altzp     <= op_addr[0];
                    3'd5: begin
                              slotc3rom    <= op_addr[0];
                              gs_sltrom[3] <= op_addr[0];
                          end
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

    // ---- INTC8ROM --------------------------------------------------------------
    // Set at present, cleared at commit - see the header for why they differ.
    wire acc_c3xx = (op_addr[15:8] == 8'hC3);
    wire acc_cfff = (op_addr == 16'hCFFF);
    always_ff @(posedge clk) begin
        if (rst || !res_sync)                                       intc8rom <= 1'b0;
        else if (op_present && acc_c3xx && !slotc3rom)              intc8rom <= 1'b1;
        else if (op_commit && acc_cfff)                             intc8rom <= 1'b0;
    end

    // ---- the region table ------------------------------------------------------
    // The header's ten regions: everything classification depends on, once
    // the page byte has picked a region, is a function of the switches -
    // so the map is two ten-entry tables, recomputed every clock and
    // REGISTERED, and translation is a mux, a fold and a bank select.
    localparam [3:0] R_ZP  = 4'd0, R_TXT = 4'd1, R_HGR = 4'd2, R_RAM = 4'd3,
                     R_IO  = 4'd4, R_CXL = 4'd5, R_C3  = 4'd6, R_C8  = 4'd7,
                     R_LCD = 4'd8, R_LCE = 4'd9,
                     // The three the IIe never needed: on the GS each is a
                     // SHADOW bit of its own ($C035), so each needs an entry
                     // that can differ from plain RAM's.  On the IIe they
                     // ARE plain RAM - 80STORE reaches only text page 1 and
                     // hires page 1 - and their entries are built to equal
                     // R_RAM's, which is what keeps the IIe sweep exact.
                     R_TXT2 = 4'd10,   // $0800-$0BFF, text page 2
                     R_HGR2 = 4'd11,   // $4000-$5FFF, hires page 2
                     R_SHR  = 4'd12;   // $6000-$9FFF, the rest of the SHR range
    // An entry's bank side.  BS_ROM is physical bank $FF.
    localparam [1:0] BS_MAIN = 2'd0, BS_AUX = 2'd1, BS_ROM = 2'd2;

    // ---- the GS's bank classes -------------------------------------------------
    // A pair is $00/$01 or $E0/$E1: the two banks the IIe's switches, the
    // language card and the I/O window live in.  Bit 17 of the address tells
    // the fast pair from the Mega II pair, bit 16 the even bank from the odd.
    function automatic gs_pair(input [7:0] bk);
        gs_pair = (bk == 8'h00) || (bk == 8'h01) || (bk == 8'hE0) || (bk == 8'hE1);
    endfunction
    function automatic gs_rom(input [7:0] bk);
        gs_rom = (bk >= GS_ROM_LO);
    endfunction

    function automatic [3:0] region(input [7:0] pg);
        begin
            if (pg[7:4] < 4'hC) begin
                if      (pg[7:1] == 7'd0)      region = R_ZP;    // $0000-$01FF
                else if (pg[7:2] == 6'b000001) region = R_TXT;   // $0400-$07FF
                else if (pg[7:2] == 6'b000010) region = R_TXT2;  // $0800-$0BFF
                else if (pg[7:5] == 3'b001)    region = R_HGR;   // $2000-$3FFF
                else if (pg[7:5] == 3'b010)    region = R_HGR2;  // $4000-$5FFF
                else if (pg[7:5] == 3'b011)    region = R_SHR;   // $6000-$7FFF
                else if (pg[7:5] == 3'b100)    region = R_SHR;   // $8000-$9FFF
                else                           region = R_RAM;
            end else if (pg[7:4] == 4'hC) begin
                if      (pg[3])                region = R_C8;    // $C800-$CFFF
                else if (pg[3:0] == 4'd0)      region = R_IO;    // $C000-$C0FF
                else if (pg[3:0] == 4'd3)      region = R_C3;    // $C300-$C3FF
                else                           region = R_CXL;
            end else if (pg[7:4] == 4'hD)      region = R_LCD;   // $D000-$DFFF
            else                               region = R_LCE;   // $E000-$FFFF
        end
    endfunction

    // {sh, cls[1:0], wr, bsel[1:0], fold, fs}
    //
    // `sh` is the NEW bit and it goes at the TOP, not the bottom, so that
    // every field below it keeps the bit position it has always had: xlate()
    // and both fronts decode this entry, and a shift would have moved all
    // three at once.
    //
    // `sh` is the GS's SHADOW ($C035): a write to this region in banks
    // $00/$01 ALSO lands in the matching Mega II bank, $E0 or $E1
    // (docs/GS.md).  It is zero for every region at GS = 0 and for every
    // READ entry always - shadowing is a property of writes.
    function automatic [RT_W-1:0] rt_e(input [1:0] cls, input wr, input [1:0] bsel,
                                       input fold, input fs);
        rt_e = {1'b0, cls, wr, bsel, fold, fs};
    endfunction
    // ...and the same with the shadow bit set, for the write entries that
    // take one.  A separate constructor rather than an argument on rt_e, so
    // that every existing call site keeps saying exactly what it said.
    function automatic [RT_W-1:0] rt_es(input [1:0] cls, input wr, input [1:0] bsel,
                                        input fold, input fs, input sh);
        rt_es = {sh, cls, wr, bsel, fold, fs};
    endfunction

    // The bank side each RAM region takes: the old aux_mid/aux_sel mux, split
    // one way per region so the address no longer enters it.  80STORE takes
    // the text page - and the hires page with HIRES - away from RAMRD/RAMWRT
    // and hands it to PAGE2; ALTZP owns the zero page, the stack and the
    // language card.
    wire side_zp    = altzp;
    wire side_lc    = altzp;
    wire side_txt_r = store80 ? page2 : ramrd;
    wire side_txt_w = store80 ? page2 : ramwrt;
    wire side_hgr_r = (store80 && hires) ? page2 : ramrd;
    wire side_hgr_w = (store80 && hires) ? page2 : ramwrt;

    // The internal ROM's three $Cxxx answers (UTAIIe 5-28, header), and the
    // language card's window.  rom_ok is an input of the table, so a class is
    // never ROM before the ROM has arrived.
    wire cx_rom_l = rom_ok && intcxrom;                    // $C1,$C2,$C4-$C7
    wire cx_rom_3 = rom_ok && (intcxrom || !slotc3rom);    // $C3
    wire cx_rom_8 = rom_ok && (intcxrom || intc8rom);      // $C8-$CF
    wire [1:0] lc_rd_cls = lc_ramrd ? CLS_LC : (rom_ok ? CLS_ROM : CLS_BUS);
    wire [1:0] lc_wr_cls = lc_wren  ? CLS_LC : CLS_ROM;
    wire [1:0] lc_rd_bs  = lc_ramrd ? (side_lc ? BS_AUX : BS_MAIN) : BS_ROM;
    wire [1:0] lc_wr_bs  = lc_wren  ? (side_lc ? BS_AUX : BS_MAIN) : BS_ROM;

    // ---- SHADOW, per region (docs/GS.md; KEGS moremem.c) ---------------------
    // A SET bit in $C035 INHIBITS, so every term is a negation.  Every one is
    // ANDed with GS, so the IIe's table is untouched.
    //
    // THE VETO FOLLOWS WHERE THE WRITE LANDS, not which bank the CPU named.
    // KEGS's fixup_shadow_shr is what settles it: bank $00's $6000-$9FFF takes
    // the $E1 destination ONLY when RAMWRT sent the write to auxiliary memory,
    // and takes no shadow at all when it landed in main - because Super Hi-Res
    // is auxiliary memory and main's $6000-$9FFF is not part of it.  So each
    // region has TWO answers, and the one that applies is chosen by the bank
    // side the write reaches.  That side is already in the table's own bsel
    // for the $00/$E0 path, and is auxiliary by construction for an odd bank
    // named directly.
    //
    // The aux-hires inhibit ([4]) is a second veto that applies only to the
    // auxiliary landing, and Super Hi-Res ([3]) is an alternative route to
    // shadowing the same pages - which is why the hires answers are an OR of
    // two conditions rather than a single bit.
    wire sh_txt1_m = GS && !gs_shadow[0];
    wire sh_txt1_a = GS && !gs_shadow[0];
    wire sh_txt2_m = GS && !gs_shadow[5];
    wire sh_txt2_a = GS && !gs_shadow[5];
    wire sh_hgr1_m = GS && !gs_shadow[1];
    wire sh_hgr1_a = GS && ((!gs_shadow[1] && !gs_shadow[4]) || !gs_shadow[3]);
    wire sh_hgr2_m = GS && !gs_shadow[2];
    wire sh_hgr2_a = GS && ((!gs_shadow[2] && !gs_shadow[4]) || !gs_shadow[3]);
    // Main's $6000-$9FFF is not Super Hi-Res and shadows nowhere.
    wire sh_shr_m  = 1'b0;
    wire sh_shr_a  = GS && !gs_shadow[3];
    // $C036 bit 4 carries Super Hi-Res shadowing out of bank $01 into every
    // odd RAM bank (xlate's $02-$7F arm).
    wire gs_allbanks = GS && gs_cyareg[4];

    // The table's entry carries the answer for the side ITS OWN bsel names;
    // xlate() substitutes the auxiliary answer when an odd bank is named
    // directly.  Both are exported so it can.
    function automatic sh_pick(input m, input a, input [1:0] bs);
        sh_pick = (bs == BS_AUX) ? a : m;
    endfunction
    // SHADOW[6] inhibits I/O AND the language card in banks $00/$01: with it
    // set, $C000-$FFFF there is plain RAM and the machine's own I/O window is
    // gone.  This is the `flat` view docs/MEMORY_REFACTOR.md anticipated, and
    // the fold must be OFF under it - with the fold on, a write to $D000
    // would land in page $C0, which under this bit is ordinary RAM someone
    // else owns.
    wire gs_flat = GS && gs_shadow[6];

    logic [RT_W-1:0] rt_r_n [0:NREG-1];
    logic [RT_W-1:0] rt_w_n [0:NREG-1];
    always_comb begin
        // reads
        rt_r_n[R_ZP ] = rt_e(CLS_RAM, 1'b0, side_zp    ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        rt_r_n[R_TXT] = rt_e(CLS_RAM, 1'b0, side_txt_r ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        rt_r_n[R_HGR] = rt_e(CLS_RAM, 1'b0, side_hgr_r ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        rt_r_n[R_RAM] = rt_e(CLS_RAM, 1'b0, ramrd      ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        rt_r_n[R_IO ] = rt_e(CLS_BUS, 1'b0, BS_MAIN, 1'b0, 1'b0);
        rt_r_n[R_CXL] = rt_e(cx_rom_l ? CLS_ROM : CLS_BUS, 1'b0, BS_ROM, 1'b0, cx_rom_l);
        // Page $C3 is front-servable only while INTC8ROM is SET: a $C3 access
        // with the latch clear is what SETS it, and that one must ride the
        // sequencer (header; rtl/iline.sv's excl()/kill_now).
        rt_r_n[R_C3 ] = rt_e(cx_rom_3 ? CLS_ROM : CLS_BUS, 1'b0, BS_ROM, 1'b0,
                             cx_rom_3 && intc8rom);
        rt_r_n[R_C8 ] = rt_e(cx_rom_8 ? CLS_ROM : CLS_BUS, 1'b0, BS_ROM, 1'b0, cx_rom_8);
        rt_r_n[R_LCD] = rt_e(lc_rd_cls, 1'b0, lc_rd_bs, lc_ramrd && !lc_bank2,
                             lc_rd_cls != CLS_BUS);
        rt_r_n[R_LCE] = rt_e(lc_rd_cls, 1'b0, lc_rd_bs, 1'b0, lc_rd_cls != CLS_BUS);
        // The three regions the IIe does not distinguish.  On a READ they are
        // plain RAM in every machine: nothing about SHADOW touches reads, and
        // 80STORE reaches only text page 1 and hires page 1.  Written this way
        // rather than shared with R_RAM so the write entries below, which DO
        // differ on the GS, sit beside them.
        rt_r_n[R_TXT2] = rt_e(CLS_RAM, 1'b0, ramrd ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        rt_r_n[R_HGR2] = rt_e(CLS_RAM, 1'b0, ramrd ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        rt_r_n[R_SHR ] = rt_e(CLS_RAM, 1'b0, ramrd ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        // writes
        rt_w_n[R_ZP ] = rt_e(CLS_RAM, 1'b1, side_zp    ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        rt_w_n[R_RAM] = rt_e(CLS_RAM, 1'b1, ramwrt     ? BS_AUX : BS_MAIN, 1'b0, 1'b1);
        rt_w_n[R_IO ] = rt_e(CLS_BUS, 1'b0, BS_MAIN, 1'b0, 1'b0);
        rt_w_n[R_CXL] = rt_e(CLS_BUS, 1'b0, BS_MAIN, 1'b0, 1'b0);
        rt_w_n[R_C3 ] = rt_e(CLS_BUS, 1'b0, BS_MAIN, 1'b0, 1'b0);
        rt_w_n[R_C8 ] = rt_e(CLS_BUS, 1'b0, BS_MAIN, 1'b0, 1'b0);
        rt_w_n[R_LCD] = rt_e(lc_wr_cls, lc_wren, lc_wr_bs, lc_wren && !lc_bank2, 1'b1);
        rt_w_n[R_LCE] = rt_e(lc_wr_cls, lc_wren, lc_wr_bs, 1'b0, 1'b1);
        rt_w_n[R_TXT2] = rt_es(CLS_RAM, 1'b1, ramwrt ? BS_AUX : BS_MAIN, 1'b0, 1'b1,
                               sh_pick(sh_txt2_m, sh_txt2_a, ramwrt ? BS_AUX : BS_MAIN));
        rt_w_n[R_HGR2] = rt_es(CLS_RAM, 1'b1, ramwrt ? BS_AUX : BS_MAIN, 1'b0, 1'b1,
                               sh_pick(sh_hgr2_m, sh_hgr2_a, ramwrt ? BS_AUX : BS_MAIN));
        rt_w_n[R_SHR ] = rt_es(CLS_RAM, 1'b1, ramwrt ? BS_AUX : BS_MAIN, 1'b0, 1'b1,
                               sh_pick(sh_shr_m,  sh_shr_a,  ramwrt ? BS_AUX : BS_MAIN));
        // ...and the shadow bit on the two the IIe already had.  Everything
        // else about these entries is unchanged, which is what the IIe sweep
        // checks.
        rt_w_n[R_TXT] = rt_es(CLS_RAM, 1'b1, side_txt_w ? BS_AUX : BS_MAIN, 1'b0, 1'b1,
                              sh_pick(sh_txt1_m, sh_txt1_a, side_txt_w ? BS_AUX : BS_MAIN));
        rt_w_n[R_HGR] = rt_es(CLS_RAM, 1'b1, side_hgr_w ? BS_AUX : BS_MAIN, 1'b0, 1'b1,
                              sh_pick(sh_hgr1_m, sh_hgr1_a, side_hgr_w ? BS_AUX : BS_MAIN));
    end

    // The tables and the physical bank an auxiliary access reaches, one clock
    // behind the switches - the same clock map_changed rises on, so the two
    // never disagree.  No reset: they follow the switch registers, which
    // reset, and map_changed is held high through a reset anyway.
    logic [RT_W-1:0] rt_r_q [0:NREG-1];
    logic [RT_W-1:0] rt_w_q [0:NREG-1];
    logic [7:0]      rwb_p1_q;
    integer ri;
    always_ff @(posedge clk) begin
        for (ri = 0; ri < NREG; ri = ri + 1) begin
            rt_r_q[ri] <= rt_r_n[ri];
            rt_w_q[ri] <= rt_w_n[ri];
        end
        rwb_p1_q <= rw_bank + 8'd1;
    end
    assign rwb_p1 = rwb_p1_q;
    genvar gr;
    generate
        for (gr = 0; gr < NREG; gr = gr + 1) begin : g_rt_flat
            assign rt_rd_flat[gr*RT_W +: RT_W] = rt_r_q[gr];
        end
    endgenerate

    // ---- the translation -------------------------------------------------------
    // {cls[1:0], wr, fs, reg[3:0], ppn[15:0], fold}.  Every question this
    // module answers - the presented op's, the sequencer's, both fronts' -
    // goes through here, so they cannot drift apart.
    // {sh, cls[1:0], wr, fs, reg[3:0], ppn[15:0], fold} - `sh` at the TOP, so
    // every accessor below keeps the bit it had.
    localparam int XL_W = 26;
    // rom_ok, ONE CLOCK LATE, for the query cones (docs/GS.md rung 6).  It is
    // the ROM loader's 512-wide "every chunk landed" reduction, and the IIgs's
    // per-slot ROM arm below reads it live where the region table reads it
    // registered (rt_r_q); the first rung-6 build put that reduction at the
    // head of a 9 ns route into the page cache's request queue.  A clock of
    // lag is nothing: the ROM lands long before any fetch depends on it, and
    // the table already stands a clock behind.
    logic rom_ok_q;
    always_ff @(posedge clk) rom_ok_q <= !rst && rom_ok;
    function automatic [XL_W-1:0] xlate(input [23:0] va, input rw);
        logic [3:0]      r;
        logic [RT_W-1:0] e;
        logic [1:0]      cls;
        logic            wr, fs, fold, sh;
        logic [7:0]      bank;
        logic [7:0]      pg;      // the page in the physical bank
        logic            gs_side; // the pair side the access lands on
        // Which pair: $00/$01 or the Mega II's $E0/$E1.  BIT 7 of the bank,
        // not bit 1 - $E0 is 1110_0000 and its bit 1 is zero, the same as
        // bank $00's, so a guard written on bit 1 never fires at all.  The
        // GS sweep caught exactly that: $E0 writes claiming to shadow.
        logic            gs_mega;
        begin
            gs_side = 1'b0;
            gs_mega = va[23];
            r    = region(va[15:8]);
            e    = rw ? rt_r_q[r] : rt_w_q[r];
            pg   = va[15:8];
            cls  = e[6:5];
            wr   = e[4];
            fold = e[1];
            fs   = e[0];
            sh   = e[7];
            // The fold is the region table's answer and is applied here; every
            // bank class below that overrides the class must therefore restore
            // the page as well as clearing the fold, or a bank with no language
            // card in it inherits the fold of one that has.
            if (fold) pg = {4'hC, va[11:8]};
            case (e[3:2])
                BS_AUX:  bank = rwb_p1_q;
                BS_ROM:  bank = 8'hFF;
                default: bank = 8'd0;
            endcase
            // $CFFF is the bus's in every state - it is the INTC8ROM latch's
            // clear strobe - a byte-level exception to its page's entry.
            if (va[15:0] == 16'hCFFF) begin
                cls = CLS_BUS; wr = 1'b0; fs = 1'b0; fold = 1'b0; sh = 1'b0;
            end
            // ---- the bank classes (docs/GS.md) ---------------------------
            // On the IIe only bank 0 exists and none of this is reached.  On
            // the GS the bank byte picks one of four treatments BEFORE the
            // region table's answer is used.
            // A READ of $C071-$C07F is the ROM's on a IIgs (KEGS moremem.c:
            // g_rom_fc_ff_ptr at $FF/$C0xx), where on a IIe it is the game
            // port's strobe.  A WRITE there is still the bus's - two of them
            // are the RamWorks bank register.
            //
            // THE ORDER BELOW IS LOAD-BEARING.  This runs before the bank
            // classes, and they overwrite it exactly where they should: a
            // bank with no I/O window at all ($02 and up) makes $C071
            // ordinary RAM, and the I/O inhibit does the same to $00/$01.
            // It survives only where an I/O window exists.
            if (GS && rw && (va[15:4] == 12'hC07)) begin
                r = R_IO; cls = CLS_ROM; wr = 1'b0; fs = 1'b1; fold = 1'b0;
                sh = 1'b0; bank = 8'hFF; pg = va[15:8];
            end
            if (GS) begin
                if (gs_pair(va[23:16])) begin
                    // $00/$01 and $E0/$E1: the IIe switches apply, exactly as
                    // the table computed them - but only to the EVEN bank of
                    // the pair.  An odd bank named directly IS the auxiliary
                    // memory, so it is itself, and the switches that would
                    // have redirected it do not.
                    // THE SIDE THE ACCESS LANDS ON.  Taken from the table's
                    // own bank-select, NOT from the bank it computed: on the
                    // IIe BS_AUX means RamWorks bank k+1, and bit 0 of that
                    // is only accidentally 1 when the bank register is zero.
                    // A IIgs has no RamWorks - auxiliary memory IS bank $01
                    // of the pair - so the side is the select itself, or the
                    // address naming the odd bank directly.
                    gs_side = va[16] || (e[3:2] == BS_AUX);
                    // THE PER-SLOT ROM SELECTION ($C02D), which the region
                    // table cannot carry: one entry covers $C1, $C2 and
                    // $C4-$C7, and each of those slots has a bit of its own.
                    // So it is applied here, as the pair side is, and for the
                    // same reason - see the note on rt_rd_flat in docs/GS.md
                    // about what the fronts will need when they serve a IIgs.
                    //
                    // A page is the INTERNAL ROM's unless the slot's bit is
                    // SET, or INTCXROM overrides it (KEGS fixup_intcx:
                    // `((g_c02d_int_crom & mask) == 0) || intcx`).  So a IIgs
                    // comes up with every slot page internal, where a IIe
                    // comes up with them the slots'.
                    if ((r == R_CXL || r == R_C3) && rw) begin
                        // The slot is the page's low nibble, and $C1-$C7 is
                        // all this arm sees, so three bits index the register.
                        if (rom_ok_q && (intcxrom || !gs_sltrom[va[10:8]])) begin
                            cls = CLS_ROM; wr = 1'b0; bank = 8'hFF;
                            pg  = va[15:8]; sh = 1'b0;
                            fs  = (r == R_C3) ? intc8rom : 1'b1;
                        end else begin
                            cls = CLS_BUS; wr = 1'b0; fs = 1'b0; sh = 1'b0;
                        end
                    end
                    if (va[16] && cls == CLS_RAM) begin
                        bank = {va[23:17], 1'b1};
                        // An odd bank named directly always LANDS in auxiliary
                        // memory, so the auxiliary veto is the one that
                        // applies - not the answer the table computed for
                        // whichever side its own bsel happened to name.
                        case (r)
                            R_TXT:  sh = sh_txt1_a;
                            R_TXT2: sh = sh_txt2_a;
                            R_HGR:  sh = sh_hgr1_a;
                            R_HGR2: sh = sh_hgr2_a;
                            R_SHR:  sh = sh_shr_a;
                            default: sh = 1'b0;
                        endcase
                        sh = sh & !rw;
                    end else if (cls == CLS_RAM || cls == CLS_LC)
                        bank = {va[23:17], gs_side};
                    // The Mega II banks are the DESTINATION of a shadowed
                    // write, never a source: a write there duplicates
                    // nowhere.  (KEGS routes $E0/$E1 writes through its
                    // shadow stub too, but only to keep its own video
                    // change-tracking bitmap - not because the hardware
                    // copies anything.)
                    if (gs_mega) sh = 1'b0;
                    // SHADOW[6] takes the I/O window and the language card
                    // away from banks $00/$01 - and NOT from $E0/$E1, which
                    // is why bit 17 is in the guard (KEGS fixup_shadow_iolc
                    // loops k < 2).
                    //
                    // IT IS NOT PLAIN IDENTITY RAM, which is the trap.  The
                    // two windows are SWAPPED: CPU $C000-$CFFF reads the
                    // image's $D000 - language card bank 2 - and CPU
                    // $D000-$DFFF reads the image's $C000 - bank 1, where the
                    // fold has always put it.  Both $D000 images are
                    // therefore visible at once, which is exactly what this
                    // mode is for: sixteen more kilobytes with no I/O in the
                    // way.  $E000-$FFFF is itself.
                    //
                    // ALTZP still steers, and only the two upper windows:
                    // KEGS applies it after the $C0 fixup, so $C000-$CFFF
                    // stays in the bank the address named while $D000-$FFFF
                    // follows ALTZP out of bank $00.
                    if (gs_flat && !gs_mega && (r >= R_IO) && (r <= R_LCE)) begin
                        cls = CLS_RAM; wr = !rw; fs = 1'b1; sh = 1'b0;
                        if (r == R_IO || r == R_CXL || r == R_C3 || r == R_C8) begin
                            pg   = {4'hD, va[11:8]};
                            fold = 1'b1;
                            bank = {va[23:17], va[16]};
                        end else begin
                            pg   = (r == R_LCD) ? {4'hC, va[11:8]} : va[15:8];
                            fold = (r == R_LCD);
                            bank = {va[23:17], va[16] | (!va[16] && altzp)};
                        end
                    end
                    // A write that lands nowhere duplicates nowhere.
                    sh = sh & wr;
                end else if (gs_rom(va[23:16])) begin
                    // $F0-$FF: ROM space, itself, read-only - ours from $F0,
                    // the machine's at its top ($FC-$FF for a ROM 3).
                    r = R_RAM; cls = CLS_ROM; wr = 1'b0; fs = 1'b1; fold = 1'b0;
                    sh = 1'b0; bank = va[23:16]; pg = va[15:8];
                end else begin
                    // $02-$DF and $E2-$EF: RAM, every bank of it its own,
                    // no switch on it - the machine's below $80, ours above
                    // (docs/ENHANCED_VIDEO.md R0).
                    // SHADOW IN ALL BANKS ($C036 bit 4).  With it set, an
                    // odd bank from $03 up shadows its Super Hi-Res window
                    // into $E1 exactly as bank $01 does - KEGS moremem.c
                    // fixup_shadow_all_banks: banks 3, 5, 7 ... of the RAM,
                    // $2000-$9FFF, SHR's inhibit the only veto.  The
                    // duplicate's destination needs nothing new: it is
                    // $E0 | the physical bank's low bit, which is 1 here.
                    // Found on HW 2026-09-16: Arkanoid launched from the
                    // Finder is relocated into bank $07 and draws its
                    // playfield through this; without it, every sprite
                    // left a trail.  Our banks from $80 up are not RAM the
                    // ROM sized, so bit 23 keeps them out.
                    r = R_RAM; cls = CLS_RAM; wr = !rw; fs = 1'b1; fold = 1'b0;
                    sh = gs_allbanks && !va[23] && va[16] && (va[23:17] != 7'd0) &&
                         (va[15:13] != 3'd0) && (va[15:12] < 4'hA) && sh_shr_a && !rw;
                    bank = va[23:16]; pg = va[15:8];
                end
            end else if (va[23:16] != 8'd0) begin
                // The IIe build: banks 2 and up are RAM no switch touches.
                r = R_RAM; cls = CLS_RAM; wr = !rw; fs = 1'b1; fold = 1'b0;
                sh = 1'b0; bank = va[23:16]; pg = va[15:8];
            end
            if (!GS) sh = 1'b0;
            xlate = {sh, cls, wr, fs, r, bank, pg, fold};
        end
    endfunction

    function automatic [1:0]  xl_cls (input [XL_W-1:0] x); xl_cls  = x[24:23]; endfunction
    function automatic        xl_wr  (input [XL_W-1:0] x); xl_wr   = x[22];    endfunction
    function automatic        xl_fs  (input [XL_W-1:0] x); xl_fs   = x[21];    endfunction
    function automatic [3:0]  xl_reg (input [XL_W-1:0] x); xl_reg  = x[20:17]; endfunction
    function automatic [15:0] xl_ppn (input [XL_W-1:0] x); xl_ppn  = x[16:1];  endfunction
    function automatic        xl_fold(input [XL_W-1:0] x); xl_fold = x[0];     endfunction
    function automatic        xl_sh  (input [XL_W-1:0] x); xl_sh   = x[25];    endfunction

    wire [XL_W-1:0] q_x = xlate(q_addr, q_rw);
    assign q_cls = xl_cls(q_x);

    // ---- the internalized ops' question, beside q_cls --------------------------
    // A shallow decode of the live address - range matches ANDed with
    // registered levels, nothing like the classifier's depth - registered
    // into the sequencer's dq_* set exactly as q_cls is.
    //
    // READS: the status page $C011-$C01F (bit 7 from the shadow over the
    // keyboard latch's low bits, as the IOU serves them; $C019 only with
    // the VBL lock), the keyboard $C00x (the parked-dummy latch), and the
    // floating-value reads a program watches the beam through - $C050-$C057
    // (the video toggles, their effect on this shadow at the synthetic
    // commit as at a bus commit) and $C080-$C08F (the language card,
    // likewise) - when fb_sim can answer.  $C010 is the real strobe's and
    // rides the bus; so do $C058-$C05F (annunciators, DHIRES - the shadow
    // does not carry them).
    //
    // ...and the game port (rtl/game_port.sv): the buttons $C061-$C063
    // once sampled, the paddle timers $C064-$C067 and the strobe $C070-
    // $C07F by READ once a measurement stands.  $C060 (the cassette) and
    // $C068-$C06F are nobody's; a $C07x WRITE stays on the bus, the
    // RamWorks bank register being two of them.
    //
    // WRITES: the strobes of $C00x whose whole effect is this shadow's -
    // 80STORE, RAMRD, RAMWRT, ALTZP, 80COL, ALTCHAR - and the same $C050-
    // $C057 and $C080-$C08F, their data irrelevant (the address is the
    // switch).  A write returns no byte, so none needs fb_sim.  NOT
    // internalized, by design: $C006/7 INTCXROM and $C00A/B SLOTC3ROM.
    // They are the two switches that decide whether a $Cnxx bus cycle
    // reaches a slot (I/O SELECT', I/O STROBE' via INTC8ROM), and the
    // motherboard must see every write to them so that when this card DOES
    // put a slot access on the bus - and it only does so when this shadow
    // says the slot owns the page - the motherboard routes it the same
    // way.  The four on-card peripherals track them from the driven stream
    // too (rtl/slot_switches.sv).  $C010-$C01F writes are the strobe's.
    wire [3:0] qi_hi = q_addr[7:4];
    wire [3:0] qi_lo = q_addr[3:0];
    wire qi_io   = (q_addr[15:8] == 8'hC0);
    wire qi_c05x = (qi_hi == 4'h5) && !qi_lo[3];              // $C050-$C057
    wire qi_c08x = (qi_hi == 4'h8);
    wire qi_c00w = (qi_hi == 4'h0) && (qi_lo[3:1] != 3'd3) && (qi_lo[3:1] != 3'd5);
    // ...and the speaker, $C030-$C03F (docs/CXXX.md, "The speaker"): every
    // access toggles the flip-flop, the host's sound follows the word, and
    // the motherboard's own cone is silent for it - the byte a read gets is
    // the floating bus's, fb_sim's when it can answer; a write is served
    // regardless.  Never quiet: each access is a toggle.
    wire qi_c03x = (qi_hi == 4'h3);
    wire qi_c06b = (qi_hi == 4'h6) && (qi_lo[3:2] == 2'b00) && (qi_lo[1:0] != 2'b00);   // $C061-$C063
    wire qi_c06p = (qi_hi == 4'h6) && (qi_lo[3:2] == 2'b01);                             // $C064-$C067
    wire qi_c07x = (qi_hi == 4'h7);
    wire qi_rd   = (qi_hi == 4'h0) ? swi_kbd_ok
                 : (qi_hi == 4'h1) ? ((qi_lo != 4'h0) && (qi_lo != 4'h9 || swi_vbl_ok))
                 : (qi_c05x || qi_c08x || qi_c03x) ? swi_fb_ok
                 : qi_c06b ? swi_pb_ok
                 : (qi_c06p || qi_c07x) ? swi_pdl_ok
                 : 1'b0;
    wire qi_wr   = qi_c00w || qi_c05x || qi_c08x || qi_c03x;
    // The on-card slots.  DEVICE SELECT' is never gated by a switch; I/O
    // SELECT' is the slot's only while INTCXROM is clear and, for slot 3,
    // SLOTC3ROM set - the same rule the classifier and rtl/slot_switches.sv
    // apply, so an access this says is the slot's is one the classifier
    // calls BUS.  Reads and writes alike: a write to a slot's ROM page
    // lands nowhere on a real card too.  The VidHD's slot is NOT here (its
    // signature ROM read rides the bus, as before).
    function automatic slot_page(input [2:0] n);
        slot_page = (n != 3'd0) && (q_addr[15:12] == 4'hC) && (q_addr[11:8] == {1'b0, n}) &&
                    !intcxrom && !(n == 3'd3 && !slotc3rom);
    endfunction
    function automatic slot_dev(input [2:0] n);
        slot_dev = (n != 3'd0) && qi_io && q_addr[7] && (q_addr[6:4] == n);
    endfunction
    // THE IIgs's HARD DISK SLOT, FAST (2026-09-19, the user: "all $Cxxx is
    // slow" was only ever a temporary rule; what the card knows is safe to
    // accelerate, it accelerates).  GS/OS runs the card's own SmartPort
    // firmware at $C7xx for every block, and on this build every fetch of it
    // rode a real bus cycle: 277 k of the first 6 M instructions' 472 k slow
    // fetches, a sixth of all clocks.  The slot's ROM page while SLOTROMSEL
    // gives it to the card and INTCXROM is clear (exactly when the classifier
    // calls it BUS), and its DEVICE SELECT, in the four banks whose $Cxxx is
    // the I/O window (not the fast pair under SHADOW bit 6); the sequencer's
    // fast path serves them as it does on the IIe (accel_seq sl_win).
    wire q_pair_io = GS && ((q_addr[23:17] == 7'h70) || ((q_addr[23:17] == 7'd0) && !gs_flat));
    wire q_hd_fast = slot_on && q_pair_io &&
                     ((slot_page(swi_hd_slot) && gs_sltrom[swi_hd_slot]) || slot_dev(swi_hd_slot));
    assign q_slot = (swi_on && (slot_dev(swi_hd_slot) || slot_dev(swi_fd_slot) || slot_dev(swi_mouse_slot) ||
                                slot_dev(swi_u2_slot) || slot_dev(swi_prn_slot) ||
                                slot_page(swi_hd_slot) || slot_page(swi_fd_slot) || slot_page(swi_mb_slot) ||
                                slot_page(swi_mouse_slot) || slot_page(swi_prn_slot))) ||
                    q_hd_fast;
    assign q_swi = (swi_on && qi_io && (q_rw ? qi_rd : qi_wr)) || q_slot;
    assign q_nsc = ((q_addr[15:8] == 8'hC3) && (intcxrom || !slotc3rom)) ||
                   ((q_addr[15:8] == 8'hC8) && (intcxrom || intc8rom));
    // Quiet: a $C050-$C057 op, or a $C00x write, whose switch already holds
    // the value the address sets.  The language card's ops are never quiet
    // (the prewrite state moves on every one), and the rest change nothing
    // on the host's side either way.
    logic qi_same5, qi_same0;
    always_comb begin
        case (qi_lo[2:1])
            2'd0: qi_same5 = (text  == qi_lo[0]);
            2'd1: qi_same5 = (mixed == qi_lo[0]);
            2'd2: qi_same5 = (page2 == qi_lo[0]);
            default: qi_same5 = (hires == qi_lo[0]);
        endcase
        case (qi_lo[3:1])
            3'd0: qi_same0 = (store80 == qi_lo[0]);
            3'd1: qi_same0 = (ramrd   == qi_lo[0]);
            3'd2: qi_same0 = (ramwrt  == qi_lo[0]);
            3'd4: qi_same0 = (altzp   == qi_lo[0]);
            3'd6: qi_same0 = (col80   == qi_lo[0]);
            3'd7: qi_same0 = (altchar == qi_lo[0]);
            default: qi_same0 = 1'b0;
        endcase
    end
    // The I/O page only: qi_c05x/qi_c00w are low-byte decodes, and an on-card
    // slot's I/O SELECT page shares them - a Mockingboard write to $C400 with
    // 80STORE clear looked like a quiet 80STORE write and its word was
    // dropped, starving the host's sound of VIA0 (found on hardware,
    // megademo, 2026-09-04).
    assign q_swi_quiet = qi_io && ((qi_c05x && qi_same5) || (!q_rw && qi_c00w && qi_same0));

    // The status page's byte, for the REGISTERED op: the switch in bit 7 -
    // $C019 is the IIe's VBL', low while the beam is in blanking - over the
    // keyboard latch's low bits.
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
            4'h9: swi_stat_bit = swi_vbl_bar;
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
    assign swi_stat_bits = {col80, altchar, hires, page2, mixed, text, swi_vbl_bar, store80,
                            slotc3rom, altzp, intcxrom, ramwrt, ramrd, lc_ramrd, lc_bank2, 1'b0};

    // ---- the IIgs's registers, read back (docs/GS.md rung 3b) ---------------
    // SHADOW is seven bits in the register and eight on the bus; bit 7 reads
    // zero, as it does in KEGS (g_c035_shadow_reg is only ever written with
    // the low seven).
    assign gs_shadow_o = {1'b0, gs_shadow};
    assign gs_cyareg_o = gs_cyareg;
    assign gs_sltrom_o = gs_sltrom;
    assign gs_state_o  = {altzp, page2, ramrd, ramwrt,
                          !lc_ramrd,        // RDROM: the complement, as on the write
                          lc_bank2, 1'b0,   // ROMBANK: one image, always 0
                          intcxrom};

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
    wire [XL_W-1:0] p_x = xlate(p_addr, 1'b1);
    assign p_cls  = xl_cls(p_x);
    assign p_aux  = (p_hi || p_zp) ? altzp : p_mid;
    assign p_off  = (p_d && !lc_bank2) ? {4'hC, p_addr[11:0]} : p_addr[15:0];
    assign p_ppn  = xl_ppn(p_x);
    assign p_reg  = xl_reg(p_x);
    assign p_fold = xl_fold(p_x);
    assign p_fs   = xl_fs(p_x);

    // ---- the data front's query ---------------------------------------------------
    wire d_zp_w    = (d_addr[15:9]  == 7'd0);
    wire d_text_w  = (d_addr[15:10] == 6'b000001);
    wire d_hires_w = (d_addr[15:13] == 3'b001);
    wire d_d_w     = (d_addr[15:12] == 4'hD);
    wire d_hi_w    = (d_addr[15:12] >= 4'hD);
    wire d_mid_w   = (store80 && d_text_w)           ? page2 :
                     (store80 && hires && d_hires_w) ? page2 :
                     (d_rw ? ramrd : ramwrt);
    wire [XL_W-1:0] d_x = xlate(d_addr, d_rw);
    assign d_cls  = xl_cls(d_x);
    assign d_aux  = (d_hi_w || d_zp_w) ? altzp : d_mid_w;
    assign d_off  = (d_d_w && !lc_bank2) ? {4'hC, d_addr[11:0]} : d_addr[15:0];
    assign d_ppn  = xl_ppn(d_x);
    assign d_sh   = xl_sh(d_x);
    assign d_reg  = xl_reg(d_x);
    assign d_fold = xl_fold(d_x);

    // ---- the map's edge -----------------------------------------------------------
    // Everything classification reads, watched as one word; sw_state carries
    // the LC and every switch, and the bank register and INTC8ROM ride along.
    // THE IIgs's REGISTERS ARE PART OF THE MAP TOO.  SHADOW decides where a
    // write lands a second time and, in bit 6, whether $Cxxx-$Fxxx of the
    // fast pair is I/O and language card at all; SLOTROMSEL decides which
    // $Cnxx pages are the internal ROM's.  Both are constant zero at GS = 0,
    // so this word folds back to the IIe's twenty-one bits there and
    // map_changed is bit-for-bit what the IIe sweep has always seen.
    // STATEREG needs no entry: its write moves the seven switches that are
    // already in sw_state.
    logic [36:0] map_q;
    logic        map_s1, map_s2;
    // CYAREG's shadow-in-all-banks bit moves where a write to banks $03-$7F
    // lands a second time, so it is part of the map like SHADOW.
    wire [36:0] map_now = {gs_allbanks, gs_shadow, gs_sltrom, sw_state, intc8rom, rw_bank};
    always_ff @(posedge clk) begin
        map_q       <= map_now;
        map_changed <= rst || !res_sync || (map_q != map_now);
        // ...and its three-clock stretch's two delays.  map_settling itself
        // is COMBINATIONAL over them, so it covers map_changed's OWN clock:
        // registering the OR would start it one clock late, and that clock
        // is exactly the one a front must not serve a line on - its valid
        // bits still describe the old map until the revalidation lands.
        // (Found the hard way: with the OR registered, sim/accel.s's
        // bankfetch read main's INX at $1F03 where aux's DEX was due.)
        map_s1 <= map_changed;
        map_s2 <= map_s1;
    end
    assign map_settling = map_changed || map_s1 || map_s2;

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

    wire [XL_W-1:0] n_x   = xlate({op_bank, op_addr}, op_rw);
    wire [1:0] n_cls      = xl_cls(n_x);
    wire       n_sh       = xl_sh(n_x);
    wire       n_wr_image = xl_wr(n_x);
    wire       n_aux      = in_hi ? altzp : aux_sel;
    wire [15:0] n_ppn     = xl_ppn(n_x);

    // THE PREVIEW'S PAGE BYTE FROM A SHALLOW CONE (2026-09-12).  The page
    // cache indexes its ways from pf_ppn the clock the op is presented, and
    // its set index is a hash of the PAGE byte alone (rtl/page_cache.sv
    // set_of: ppn[3:0] ^ ppn[7:4]).  Synthesis derived that byte at the end
    // of xlate()'s nine-LUT cone - region decode, the 13:1 table mux, the
    // bank classes - and then routed it to 64 block RAMs: the way address
    // was the design's tightest path at twelve levels and 7.7 ns of route
    // (docs/IWM35.md's census; build/chains_detail.tcl).  But the page byte
    // after the fold is a THREE-LEVEL function of the address and two
    // registered table bits: the fold applies only in $Dxxx of a pair bank
    // when the language card's entry says so, and the IIgs's I/O-inhibit
    // swaps $Cxxx and $Dxxx in a fast-pair bank.  Every other arm of xlate()
    // leaves the page as the address named it.  So pf_ppn's low byte comes
    // from here, its high byte from xlate() as before, and the simulation
    // assertion below holds the two equal on every op of every bench - the
    // map sweeps (sim/mmu_xlate_tb.sv, sim/mmu_xlate_gs_tb.sv) drive this
    // port through every switch state there is.
    wire pf_pairish = GS ? gs_pair(op_bank) : (op_bank == 8'd0);
    wire pf_flat    = GS && gs_shadow[6] && pf_pairish && !op_bank[7];
    wire pf_fold_q  = op_rw ? rt_r_q[R_LCD][1] : rt_w_q[R_LCD][1];
    wire [3:0] pf_hi = pf_flat ? ((op_addr[15:12] == 4'hC) ? 4'hD :
                                  (op_addr[15:12] == 4'hD) ? 4'hC : op_addr[15:12])
                     : (pf_pairish && in_d && pf_fold_q) ? 4'hC : op_addr[15:12];
    wire [7:0] pf_pg = {pf_hi, op_addr[11:8]};

    // ...AND THE BANK BYTE, the same way, because the set index hashes seven
    // bits and six of them are the bank's (SETS = 128).  Every arm of
    // xlate() gives the bank as one of four things - the address's own,
    // the RamWorks register (IIe auxiliary), $FF (the ROM's, which the
    // table's BS_ROM entries name for every $C1xx-$CFxx read and every
    // language-card access the ROM answers), or the void's - chosen by
    // flags the map already holds shallowly: n_aux (the side, one mux on
    // registered switches), the language card's read/write enables, and the
    // pair/ROM/void bank classes.
    //   $C1-$CF read      : $FF, internal ROM or not (the table's bsel)
    //   $C0xx, $C1-$CF wr : bank 0 / the pair's own even bank on the GS
    //   $Dx-$Fx           : RAM-class (lc_ramrd / lc_wren) -> the side's bank,
    //                       else $FF
    //   below $C0         : the side's bank
    //   GS I/O-inhibit    : {va[23:17], va[16]} for $Cxxx, va[16] | altzp above
    //   GS non-pair       : the address's bank, or the void's
    // The side's bank is rwb_p1_q on the IIe and {va[23:17], va[16] | side}
    // on the GS.  The assertion below holds the whole shallow ppn to
    // xlate()'s.
    wire       pf_in_cx   = (op_addr[15:12] == 4'hC);
    wire       pf_c0      = pf_in_cx && (op_addr[11:8] == 4'd0);
    wire       pf_lc_ram  = op_rw ? lc_ramrd : lc_wren;
    wire       pf_rom_cx  = pf_in_cx && !pf_c0 && op_rw;               // BS_ROM by the table
    wire       pf_rom_c07 = GS && pf_c0 && op_rw && (op_addr[7:4] == 4'h7); // the $C07x read arm
    wire       pf_rom_lc  = in_hi && !pf_lc_ram;
    wire       pf_rom     = pf_rom_cx || pf_rom_c07 || pf_rom_lc;
    wire       pf_side    = pf_in_cx ? 1'b0 : n_aux;                    // aux only where RAM is
    logic [7:0] pf_bank;
    always_comb begin
        if (!GS) begin
            if (op_bank != 8'd0)      pf_bank = op_bank;
            else if (pf_rom)          pf_bank = 8'hFF;
            else if (pf_side)         pf_bank = rwb_p1_q;
            else                      pf_bank = 8'd0;
        end else if (gs_pair(op_bank)) begin
            if (pf_flat)              pf_bank = {op_bank[7:1], op_bank[0] | (in_hi && altzp)};
            else if (pf_rom)          pf_bank = 8'hFF;
            else if (pf_in_cx)        pf_bank = 8'd0;                  // $C0xx and $Cxxx writes: BUS, bank 0
            else                      pf_bank = {op_bank[7:1], op_bank[0] | pf_side};
        end else                      pf_bank = op_bank;
    end
    assign     pf_ppn     = {pf_bank, pf_pg};
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && op_present && {pf_bank, pf_pg} !== n_ppn)
            $error("apple_mmu: the shallow ppn $%04X differs from xlate's $%04X at %02X/%04X rw=%0d",
                   {pf_bank, pf_pg}, n_ppn, op_bank, op_addr, op_rw);
    end
`endif

    // A posted write takes the classified stage only when no op is being
    // presented: the op's is the older claim on the pipeline.
    // ---- the shadow duplicate (docs/GS.md) --------------------------------------
    // A shadowed write lands TWICE: once where it was going, and once at the
    // same page of the matching Mega II bank - $E0 or $E1 by the side it
    // landed on.  The second landing is emitted here, one clock later, down
    // the same path a posted write takes: cl_* already carries a write into
    // the image that is nobody's op, and the page cache does not care which
    // producer made it.
    //
    // ONE DEEP IS ENOUGH, and that is a property of the machine rather than a
    // hope.  The op path presents a write at most once every bus cycle, and
    // the duplicate goes out on the next clock the page cache's pipeline is
    // clear.  Two shadowed writes can therefore never be in hand at once: an
    // op that would make the second cannot be dispatched while the cache is
    // working, because the dispatcher's `fast_ok` waits on that same `busy`
    // (rtl/accel_seq.sv), and a bus-cycle-paced write is a hundred clocks
    // behind.  `shd_drop` counts the case that says otherwise, and a bench
    // that ever sees it non-zero has found a machine this reasoning does not
    // describe.
    //
    // AND IT WAITS FOR `pw_ready`, WHICH IT DID NOT AT FIRST.  A duplicate
    // offered "on the very next idle clock" is offered one clock behind its
    // own op - and that op may have MISSED and started a fill in that very
    // clock.  The duplicate then arrives at the classified stage with the
    // engine busy, is blocked (page_cache's dec_block), counted as a late
    // fill, and, being a write, ITS BYTE IS GONE - silently, because the
    // drop happens downstream of `shd_drop`.  sim/boot_gs_tb.sv caught it
    // once in a million instructions of the GS ROM: a shadowed write to
    // $00/$04FB missing page $0004, and its duplicate to $E004 blocked by
    // the fill its own op had just started.  So the duplicate takes the same
    // gate a posted write takes - the page cache's pipeline clear - which is
    // exactly what `pw_ready` means and was already wired in.
    logic        shd_valid;
    logic [15:0] shd_ppn;
    logic [7:0]  shd_off, shd_data;
    logic [7:0]  shd_drop;
    assign shd_drops = shd_drop;

    wire shd_new  = cl_valid && !cl_rw && cl_wr_image && cl_sh;
    wire shd_take = shd_valid && pw_ready && !op_present && !rst;
    assign shd_take_o = shd_take;
    assign shd_ppn_o  = shd_ppn;
    assign shd_off_o  = shd_off;

    // The duplicate is offered before the front's posted write: it belongs to
    // an op that has already been classified, and holding it back behind a
    // queue would let a later read of $E0 see the write that had not landed.
    assign pw_take = pw_valid && pw_ready && !op_present && !shd_valid && !rst;
    assign pe_take = pe_valid && pw_ready && !op_present && !shd_valid && !pw_valid && !rst;

    always_ff @(posedge clk) begin
        if (rst) begin
            shd_valid <= 1'b0;
            shd_drop  <= 8'd0;
        end else begin
            if (shd_new) begin
                if (shd_valid && !shd_take) shd_drop <= shd_drop + 8'd1;
                shd_valid <= 1'b1;
                // The same page in $E0 or $E1, by the side the write landed
                // on: cl_ppn's bank bit 0 IS that side.
                shd_ppn   <= {7'h70, cl_ppn[8], cl_ppn[7:0]};
                shd_off   <= cl_off[7:0];
                shd_data  <= cl_wdata[7:0];
            end else if (shd_take) begin
                shd_valid <= 1'b0;
            end
        end
    end

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
            cl_wdata    <= 32'd0;
            cl_be       <= 4'b0001;
            cl_eng      <= 1'b0;
            cl_ppn      <= 16'd0;
            cl_sh       <= 1'b0;
        end else begin
            cl_valid <= op_present || pw_take || shd_take || pe_take;
            cl_be    <= 4'b0001;
            cl_eng   <= 1'b0;
            if (op_present) begin
                cl_cls      <= n_cls;
                cl_aux      <= n_aux;
                cl_bank     <= rw_bank;
                cl_off      <= pf_off;
                cl_rw       <= op_rw;
                cl_wr_image <= n_wr_image;
                cl_posted   <= 1'b0;
                cl_wdata    <= {4{op_wdata}};
                cl_ppn      <= pf_ppn;
                cl_sh       <= n_sh;
            end else if (shd_take) begin
                // The shadow's second landing.  A RAM write into the Mega II
                // bank, posted like the front's, and never itself shadowed.
                cl_cls      <= CLS_RAM;
                cl_aux      <= 1'b0;
                cl_bank     <= 8'd0;
                cl_off      <= {shd_ppn[7:0], shd_off};
                cl_rw       <= 1'b0;
                cl_wr_image <= 1'b1;
                cl_posted   <= 1'b1;
                cl_wdata    <= {4{shd_data}};
                cl_ppn      <= shd_ppn;
                cl_sh       <= 1'b0;
            end else if (pw_take) begin
                cl_cls      <= CLS_RAM;      // the front posts RAM class only
                // The old triple, derived from the page the front stamped:
                // main is physical bank 0, RamWorks bank k is bank k+1, so
                // the decrementer is the inverse of that convention.  It
                // lands in a register and goes away with rtl/page_cache.sv's
                // rewrite (docs/MEMORY_REFACTOR.md, Part 3); cl_bank is
                // meaningless when cl_aux is clear, as it always was.
                cl_aux      <= (pw_ppn[15:8] != 8'd0);
                cl_bank     <= pw_ppn[15:8] - 8'd1;
                cl_off      <= {pw_ppn[7:0], pw_off};
                cl_rw       <= 1'b0;
                cl_wr_image <= 1'b1;
                cl_posted   <= 1'b1;
                cl_wdata    <= {4{pw_data}};
                // A posted write was already classified at its retire and
                // carries its page; its shadow is the front's to stamp when
                // the fronts serve a IIgs (docs/GS.md, rung 6).  Nothing
                // posts on the GS build yet.
                cl_ppn      <= pw_ppn;
                cl_sh       <= 1'b0;
            end else if (pe_take) begin
                // The engine's word: RAM class in $02-$DF, never shadowed
                // (REQ_RVVM: $C036 bit 4 is kept clear under the engine).
                cl_cls      <= CLS_RAM;
                cl_aux      <= (pe_ppn[15:8] != 8'd0);
                cl_bank     <= pe_ppn[15:8] - 8'd1;
                cl_off      <= {pe_ppn[7:0], pe_off};
                cl_rw       <= 1'b0;
                cl_wr_image <= 1'b1;
                cl_posted   <= 1'b1;
                cl_wdata    <= pe_data;
                cl_be       <= pe_be;
                cl_eng      <= 1'b1;
                cl_ppn      <= pe_ppn;
                cl_sh       <= 1'b0;
            end
        end
    end

endmodule
