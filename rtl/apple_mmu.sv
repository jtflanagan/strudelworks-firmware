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
// $C000-$CFFF, bank 2 of $D000 and the shared $E000-$FFFF where they sit.  Bank 0
// is main memory, bank 1 is auxiliary; the eight bank bits leave room for a
// RamWorks-style card's banks when the image grows.  cl_pa is that 24-bit
// physical address.
//
// THE SWITCHES, as the IIe's MMU implements them (Sather, Understanding the
// Apple IIe, ch. 5; AppleWin's Memory.cpp and LanguageCard.cpp agree):
//
//   $C000/1  80STORE   write only, A0 = value
//   $C002/3  RAMRD     write only        $C004/5  RAMWRT     write only
//   $C006/7  INTCXROM  write only        $C008/9  ALTZP      write only
//   $C00A/B  SLOTC3ROM write only
//   $C054/5  PAGE2     read or write     $C056/7  HIRES      read or write
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
// TIMING.  The switches change at op_commit, the data phase, as on the bus;
// the classification is registered at op_present, one clock after the op is
// stable, so it reflects every earlier cycle and not this one - a cycle that
// flips a switch is a BUS cycle anyway.  The IIe's own MMU has the same
// ordering.
//
// NOT MODELLED, deliberately: the $C800-$CFFF expansion-ROM select and $CFFF,
// and INTCXROM/SLOTC3ROM's effect on what answers in $C100-$CFFF.  The two
// switches are tracked and exported so a CX class can be added when something
// needs the internal ROM served; until then that whole page is BUS.
//////////////////////////////////////////////////////////////////////////////////
module apple_mmu (
    input  wire        clk,
    input  wire        rst,
    // Synchronised RES', ACTIVE LOW.
    input  wire        res_sync,

    // The presented op, from apple_bus_write.
    input  wire [15:0] op_addr,
    input  wire        op_rw,          // 1 = read
    input  wire        op_present,     // pulse: op_* have just been latched
    input  wire        op_commit,      // pulse: the data phase

    // The classified op, one clock after op_present.
    output logic        cl_valid,
    output logic [1:0]  cl_cls,        // CLS_*
    output logic [23:0] cl_pa,         // physical address in the image
    output logic [13:0] cl_rom_addr,   // offset from $C000 in the ROM
    output logic        cl_rw,
    output logic        cl_wr_image,   // a write that lands in the image

    // The switches, for a status register:
    //   {prewrite, wren, lc_ramrd, bank2, slotc3rom, intcxrom, hires, page2,
    //    altzp, ramwrt, ramrd, store80}
    output wire [11:0] sw_state
);

    localparam [1:0] CLS_BUS = 2'd0;
    localparam [1:0] CLS_RAM = 2'd1;
    localparam [1:0] CLS_LC  = 2'd2;
    localparam [1:0] CLS_ROM = 2'd3;

    // ---- the switches ----------------------------------------------------------
    logic store80, ramrd, ramwrt, intcxrom, altzp, slotc3rom;
    logic page2, hires;
    logic lc_bank2, lc_ramrd, lc_wren, lc_prewrite;

    assign sw_state = {lc_prewrite, lc_wren, lc_ramrd, lc_bank2,
                       slotc3rom, intcxrom, hires, page2,
                       altzp, ramwrt, ramrd, store80};

    wire io_page = (op_addr[15:8] == 8'hC0);
    wire sw_c00x = io_page && (op_addr[7:4] == 4'h0);      // $C000-$C00F
    wire sw_c05x = io_page && (op_addr[7:4] == 4'h5);      // $C050-$C05F
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
            lc_bank2    <= 1'b1;
            lc_ramrd    <= 1'b0;
            lc_wren     <= 1'b1;
            lc_prewrite <= 1'b0;
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
                    default: ;
                endcase
            end
            // $C054-$C057: read or write alike.
            if (sw_c05x) begin
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

    // ---- the classifier ----------------------------------------------------------
    wire in_zp    = (op_addr[15:9]  == 7'd0);           // $0000-$01FF
    wire in_text  = (op_addr[15:10] == 6'b000001);      // $0400-$07FF
    wire in_hires = (op_addr[15:13] == 3'b001);         // $2000-$3FFF
    wire in_io    = (op_addr[15:12] == 4'hC);           // $C000-$CFFF
    wire in_d     = (op_addr[15:12] == 4'hD);           // $D000-$DFFF
    wire in_hi    = (op_addr[15:12] >= 4'hD);           // $D000-$FFFF

    // Which bank a RAM access reaches.  80STORE takes the text page - and the
    // hires page with HIRES - away from RAMRD/RAMWRT and hands them to PAGE2;
    // ALTZP owns the zero page, the stack and the language card.
    wire aux_mid = (store80 && in_text)           ? page2 :
                   (store80 && hires && in_hires) ? page2 :
                   (op_rw ? ramrd : ramwrt);
    wire aux_sel = in_zp ? altzp : aux_mid;

    // The language card's RAM: bank 1 of $D000 lives in the image's $C000 hole.
    wire [15:0] lc_off = (in_d && !lc_bank2) ? {4'hC, op_addr[11:0]} : op_addr;

    logic [1:0]  n_cls;
    logic [23:0] n_pa;
    logic        n_wr_image;

    always_comb begin
        n_cls      = CLS_BUS;
        n_pa       = {7'd0, aux_sel, op_addr};
        n_wr_image = 1'b0;
        if (in_io) begin
            n_cls = CLS_BUS;
        end else if (in_hi) begin
            n_pa = {7'd0, altzp, lc_off};
            if (op_rw) begin
                n_cls = lc_ramrd ? CLS_LC : CLS_ROM;
            end else begin
                n_cls      = lc_wren ? CLS_LC : CLS_ROM;
                n_wr_image = lc_wren;
            end
        end else begin
            n_cls      = CLS_RAM;
            n_wr_image = !op_rw;
        end
    end

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
