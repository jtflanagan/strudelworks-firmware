`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// cache_way_ram - one way of the memory cache's data: SETS lines of 16 bytes.
//
// A simple dual-port block RAM, a whole line wide.  The read side returns the
// whole line two clocks after the address so the way select and the byte
// select can happen in registered stages after it; the write side takes a
// whole line with a byte enable per lane, which serves both a fill (all
// sixteen) and a write-through update of one byte (exactly one).
//
// TWO OUTPUT REGISTERS, deliberately.  The second is the block RAM's own
// optional output register - Vivado merges it in when it is written like this,
// a plain register with no reset and no logic on the way in - and it turns
// the BRAM's clock-to-out plus a level of routing into a whole cycle of slack.
// Every other block RAM in this design leaves that register unused (Vivado's
// SYNTH-6 note, seventeen times), and with 0.3 ns of setup slack in the last
// master build this one is not going to.  At Apple speed the extra clock costs
// nothing at all.
//
// 512 x 128 is two RAMB36 in 512 x 72 mode; the parity bits go unused.
//////////////////////////////////////////////////////////////////////////////////
module cache_way_ram #(
    parameter integer SETS = 512
) (
    input  wire                     clk,

    input  wire                     rd_en,
    input  wire [$clog2(SETS)-1:0]  rd_addr,
    output logic [127:0]            rd_data,     // two clocks after rd_en

    input  wire [15:0]              wr_be,       // one per byte lane
    input  wire [$clog2(SETS)-1:0]  wr_addr,
    input  wire [127:0]             wr_data
);

    (* ram_style = "block" *) logic [127:0] mem [0:SETS-1];

    logic [127:0] rd_q;

    always_ff @(posedge clk) begin
        for (int i = 0; i < 16; i = i + 1) begin
            if (wr_be[i]) mem[wr_addr][8*i +: 8] <= wr_data[8*i +: 8];
        end
    end

    always_ff @(posedge clk) begin
        if (rd_en) rd_q <= mem[rd_addr];
        rd_data <= rd_q;
    end

endmodule
