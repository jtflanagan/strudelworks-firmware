`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// fd_bank - one byte lane of a floppy track buffer, as a true dual-port RAM.
//
// A track buffer (rtl/floppy_card.sv) is four of these: byte i of the track
// lives in bank i[1:0] at index i[12:2], so the bus side reads and writes one
// byte at a time through port A while the link side moves a 32-bit word at a
// time - all four banks at one index - through port B.  Two ports because the
// two sides never wait for each other: the nibble the core is about to read
// has to be in a register on the bus side's schedule, and a track arriving
// from the host lands one word per clock with no handshake at all.
//
// Written in the two-process shape Vivado infers a true dual-port block RAM
// from (UG901, "Dual-Port Block RAM with Two Write Ports"), read-first on
// both ports.  1664 x 8 is one RAMB18; the buffer is two RAMB36 per drive.
// A collision - both ports at one index, one of them writing - returns
// stale data on the reader's port for that one access, and the bus side
// refreshes its copy a few clocks later anyway.
//////////////////////////////////////////////////////////////////////////////////
module fd_bank #(
    parameter integer DEPTH = 1664
) (
    input  wire        clk,

    input  wire        a_we,
    input  wire [10:0] a_addr,
    input  wire [7:0]  a_wdata,
    output logic [7:0] a_rdata,

    input  wire        b_we,
    input  wire [10:0] b_addr,
    input  wire [7:0]  b_wdata,
    output logic [7:0] b_rdata
);

    (* ram_style = "block" *) logic [7:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_wdata;
        a_rdata <= mem[a_addr];
    end

    always_ff @(posedge clk) begin
        if (b_we) mem[b_addr] <= b_wdata;
        b_rdata <= mem[b_addr];
    end

endmodule
