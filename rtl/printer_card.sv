`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// printer_card - a parallel printer interface card's slot, on the card that IS
// the CPU, with the printer on the host.
//
// AppleWin's model (ParallelPrinter.cpp, the project's reference), which is
// the Apple Parallel Interface Card as software sees it:
//
//   $Cn00-$CnFF   the slot ROM - the firmware PR#n hands the output hook to.
//                 The HOST loads it (PRINTER_ROM), AppleWin's Parallel.rom or
//                 the host's own synthesis of the output hook; the card holds
//                 256 bytes and knows nothing of their meaning.
//   $C0n0         the output register: a WRITE is one byte to the printer.
//   $C0n0-$C0nF   a READ anywhere in the range answers $FF - "ready", the
//                 status AppleWin returns and its firmware is happy with.
//
// WHAT THE CARD CLAIMS: the ROM page's reads, gated by rtl/slot_switches.sv
// as every on-card slot ROM is, and the device-select range's reads, with
// $FF.  WHAT IT DOES NOT: the writes.  A write to $C0n0 lands nowhere on a
// real card's bus either (the card takes it off the data bus by itself), and
// the host's capture carries every $Cxxx access whatever the mode
// (rtl/bus_event_filter.sv; under acceleration the sequencer's fast word),
// so the host's printer half takes the bytes from the stream exactly as the
// Mockingboard's host half takes its register writes.  Nothing to buffer,
// nothing to lose, no message from the card at all.
//
// The same shape as rtl/vidhd_card.sv - a ROM page - plus the Uthernet II's
// device-select claim.  It never takes a bus cycle, or drives one it did not
// claim.  See docs/PRINTER.md.
//////////////////////////////////////////////////////////////////////////////////
module printer_card #(
    parameter [7:0] T_PRINTER_ROM = 8'h2D
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,
    input  wire        master_active,

    // The slot this card answers as (PRINTER_SLOT, latched at RES'); 0 = none.
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
    output wire        rom_loaded,
    output logic [7:0] writes          // $C0n0 writes seen, wrapping (a sign of life)
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
    // 32 bits wide, written a word at a time from PRINTER_ROM, read a byte at
    // a time by address; one port each way, which is what lets it be a LUT
    // RAM.  The VidHD's shape (rtl/vidhd_card.sv).
    logic [31:0] rom [0:63];
    logic        rom_ok;
    assign rom_loaded = rom_ok;

    wire [31:0] rom_word = rom[op_addr[7:2]];
    wire [7:0]  rom_byte = rom_word[8 * op_addr[1:0] +: 8];

    // ---- decode ------------------------------------------------------------------
    wire hit_rom = enabled && !op_ovr && op_rw && io_select &&
                   (op_addr[15:8] == {4'hC, 1'b0, slot_assign});
    // DEVICE SELECT' is never gated by a switch (rtl/apple_mmu.sv says so).
    wire hit_dev = enabled && !op_ovr && (op_addr[15:8] == 8'hC0) &&
                   op_addr[7] && (op_addr[6:4] == slot_assign);
    wire hit_rd  = hit_rom || (hit_dev && op_rw);
    wire hit_wr  = hit_dev && !op_rw && (op_addr[3:0] == 4'd0);

    // ---- host -> card messages: the ROM ---------------------------------------------
    logic [7:0] rx_type;
    logic [7:0] rx_idx;
    logic [7:0] rx_left;

    wire rx_hdr  = msg_valid;
    wire rx_word = pay_valid && (rx_left != 8'd0);
    wire rx_last = rx_word && (rx_left == 8'd1);

    wire hdr_rom  = rx_hdr && (msg_type == T_PRINTER_ROM);
    wire word_rom = rx_word && (rx_type == T_PRINTER_ROM);

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
            writes   <= 8'd0;
        end else begin
            if (op_present) begin
                rd_claim <= hit_rd;
                rd_data  <= hit_rom ? rom_byte : hit_dev ? 8'hFF : 8'd0;
            end else if (!enabled) begin
                rd_claim <= 1'b0;
            end
            if (op_commit && hit_wr) writes <= writes + 8'd1;
        end
    end

    wire _unused_ok = &{1'b0, msg_free, 1'b0};

endmodule
