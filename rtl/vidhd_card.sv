`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// vidhd_card - a VidHD's slot, on the card that IS the CPU, with the picture
// on the host.
//
// A VidHD is a video card: it watches the bus, keeps its own copy of the
// machine's memory, and draws the IIgs's Super Hi-Res modes from auxiliary
// memory $2000-$9FFF when NEWVIDEO ($C029) asks for them.  Software finds one
// by scanning the slot ROMs for three bytes - $24 $EA $4C at $Cn00 - and
// then simply writes the IIgs's video registers, which on a IIe are mapped
// to nothing.  That is the whole of what the bus can see of it, and so the
// whole of what this module is: A SLOT ROM.
//
// WHAT THE CARD CLAIMS: $Cn00-$CnFF reads, the 256 bytes the HOST loads
// (VIDHD_ROM), gated by rtl/slot_switches.sv as the disk's and the floppy's
// are.  The host synthesises the ROM - the signature and a JMP to an RTS -
// so nothing in the gateware knows what a VidHD's firmware looks like, and a
// dump of a real one can be substituted from the host without a rebuild.
//
// WHAT IT DOES NOT CLAIM, deliberately:
//
//   $C0n0-$C0nF   a VidHD has no device-select registers (AppleWin's model,
//                 the project's reference: IO_Null there).
//   $C022/$C029/$C034/$C035   the IIgs's video registers.  A VidHD never
//                 answers a READ of them from an earlier Apple II - software
//                 that reads one gets the floating bus, and software written
//                 for a VidHD knows not to (4cade's PreSHRMode).  The WRITES
//                 go out on the bus as they would with no card at all, and
//                 the host's capture carries every $Cxxx access whatever the
//                 capture mode (rtl/bus_event_filter.sv), so the host sees
//                 them, keeps the register, and draws accordingly.
//   $C800-$CFFF   no expansion ROM (rtl/slot_switches.sv says why not).
//
// So the pixels are the host's, entirely: the memory image already holds
// auxiliary memory (rtl/apple_mmu.sv puts every aux write in image bank 1)
// and the host's own mirror of it is what the picture is drawn from.  See
// docs/VIDHD.md.
//
// WHAT THIS CARD NEVER DOES: take a bus cycle, or drive one it did not claim.
//
// RESET.  The card's reset clears everything, the ROM included - the host
// loads it again, as it does the floppy's.  RES' clears nothing here; the
// slot switches it depends on are slot_switches' business.
//////////////////////////////////////////////////////////////////////////////////
module vidhd_card #(
    parameter [7:0] T_VIDHD_ROM = 8'h23
) (
    input  wire        clk,
    // The CARD's reset: everything.
    input  wire        rst,
    // Synchronised RES', ACTIVE LOW, for the soft-switch tracker.
    input  wire        res_sync,

    // 1 while the soft core owns the bus.  Nothing here exists otherwise.
    input  wire        master_active,
    // Which slot to answer as; 0 disables.  Latched at RES' by wb_regfile.
    input  wire [2:0]  slot_assign,

    // The presented op, from apple_bus_write: stable from op_present through
    // op_commit.  op_ovr says the op was an override rather than the core's.
    input  wire [15:0] op_addr,
    input  wire        op_rw,          // 1 = read
    input  wire        op_present,     // pulse: a new op has been presented
    input  wire        op_commit,      // pulse: the cycle's data phase
    input  wire        op_ovr,

    // A claimed READ cycle and the byte to emit.  Registered at op_present.
    output logic       rd_claim,
    output logic [7:0] rd_data,

    // Host -> card messages, as ft601_msg_rx decodes them.
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [15:0] msg_free,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,

    // For the register's readback.
    output wire        rom_loaded
);

    // ---- what this card answers as -------------------------------------------
    wire enabled = master_active && (slot_assign != 3'd0) && rom_loaded;

    wire io_select;
    slot_switches u_sw (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .slot (slot_assign),
        .io_select (io_select)
    );

    // ---- the slot ROM ------------------------------------------------------------
    // 32 bits wide, written a word at a time from VIDHD_ROM, read a byte at
    // a time by address; one port each way, which is what lets it be a LUT
    // RAM.  The same shape as the floppy's (rtl/floppy_card.sv).
    logic [31:0] rom [0:63];
    logic        rom_ok;
    assign rom_loaded = rom_ok;

    wire [31:0] rom_word = rom[op_addr[7:2]];
    wire [7:0]  rom_byte = rom_word[8 * op_addr[1:0] +: 8];

    // ---- decode ------------------------------------------------------------------
    wire hit_rom = enabled && !op_ovr && op_rw && io_select &&
                   (op_addr[15:8] == {4'hC, 1'b0, slot_assign});

    // ---- host -> card messages: the ROM ---------------------------------------------
    logic [7:0] rx_type;
    logic [7:0] rx_idx;
    logic [7:0] rx_left;

    wire rx_hdr  = msg_valid;
    wire rx_word = pay_valid && (rx_left != 8'd0);
    wire rx_last = rx_word && (rx_left == 8'd1);

    wire hdr_rom  = rx_hdr && (msg_type == T_VIDHD_ROM);
    wire word_rom = rx_word && (rx_type == T_VIDHD_ROM);

    // The ROM, written on its own so nothing with a reset shares its block.
    always_ff @(posedge clk) begin
        if (word_rom) rom[rx_idx[5:0]] <= pay_data;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type <= 8'd0;
            rx_idx  <= 8'd0;
            rx_left <= 8'd0;
            rom_ok  <= 1'b0;
        end else begin
            if (rx_hdr) begin
                rx_type <= msg_type;
                rx_idx  <= 8'd0;
                rx_left <= msg_len;
                // A ROM message is only a ROM if it is the whole ROM.
                if (hdr_rom && msg_len != 8'd64) rx_type <= 8'd0;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_rom && rx_last) rom_ok <= 1'b1;
            end
        end
    end

    // ---- claim and read data --------------------------------------------------------
    // Decided in the address phase from the presented op, registered so it
    // is stable long before the emit window.
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_claim <= 1'b0;
            rd_data  <= 8'd0;
        end else if (op_present) begin
            rd_claim <= hit_rom;
            rd_data  <= hit_rom ? rom_byte : 8'd0;
        end else if (!enabled) begin
            rd_claim <= 1'b0;
        end
    end

    wire _unused_ok = &{1'b0, msg_free, 1'b0};

endmodule
