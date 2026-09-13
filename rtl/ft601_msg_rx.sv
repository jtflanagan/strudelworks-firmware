`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_msg_rx - the receive half of the FT601 message protocol.
//
// Parses host->card frames out of the RX FIFO: header, then len payload blocks,
// then the next header.  docs/PROTOCOL.md is the spec.
//
// The parser assumes the first block it ever sees is a header, and that is not
// an assumption it can check - the format has no sync word, deliberately.  It
// holds because the host opens the conversation: after a link reset the chip's
// buffers are clear in both directions, the card is silent until asked, and the
// first thing on this path is the host's first header.  See the silent-until-
// asked rule in docs/PROTOCOL.md.
//
// An unknown type is NOT a framing error.  The length is in the header
// whatever the type, so the payload is skipped by it and framing is kept -
// and the card says what it skipped: unknown_valid pulses with the type and
// length, and card_link sends the host an UNKNOWN_TYPE notice, so the host
// learns exactly what happened and can log what needs fixing.  This replaced
// a whitelist of known types that dropped the link on the first use of any
// type it lacked - which it did twice (MEM_ROM, then VIDHD_ROM), each time
// looking like a dead link rather than a missing line.  The consumers
// downstream each match their own types and ignore the rest, so nothing
// here needs to know which types exist.
//////////////////////////////////////////////////////////////////////////////////

module ft601_msg_rx (
    input  wire        clk,
    input  wire        rst,

    // FROM the async RX FIFO (FWFT, zero read latency)
    input  wire [31:0] fifo_dout,
    input  wire        fifo_empty,
    output wire        fifo_rd_en,

    // Decoded frames
    output logic        msg_valid,      // one pulse per header accepted
    output logic [7:0]  msg_type,
    output logic [15:0] msg_free,
    output logic [7:0]  msg_len,

    // Payload, one block at a time, for types that carry any
    output logic [31:0] pay_data,
    output logic        pay_valid,

    // A header of a type nothing on this card consumes: one pulse, with the
    // type and the length whose payload is being skipped.
    output logic        unknown_valid,
    output logic [7:0]  unknown_type,
    output logic [7:0]  unknown_len
);

    // The types this card consumes, for the notice above - a header of any
    // other type is skipped by its length and reported, never fatal.  Every
    // consumer matches its own type; this list only decides what to report.
    localparam [7:0] T_IDLE       = 8'h00;
    localparam [7:0] T_BUS_ENABLE = 8'h11;
    localparam [7:0] T_REG_READ   = 8'h14;
    localparam [7:0] T_REG_WRITE  = 8'h15;
    localparam [7:0] T_HD_ROM     = 8'h18;   // rtl/hd_card.sv
    localparam [7:0] T_HD_DONE    = 8'h19;
    localparam [7:0] T_HD_FETCH   = 8'h1A;
    localparam [7:0] T_FD_ROM     = 8'h1E;   // rtl/floppy_card.sv
    localparam [7:0] T_FD_TRACK   = 8'h1F;
    localparam [7:0] T_MEM_ROM    = 8'h22;   // rtl/apple_rom.sv
    localparam [7:0] T_VIDHD_ROM  = 8'h23;   // rtl/vidhd_card.sv
    localparam [7:0] T_MOUSE_MOVE = 8'h25;   // rtl/mouse_card.sv
    localparam [7:0] T_MOUSE_ROM  = 8'h26;
    localparam [7:0] T_NSC_TIME   = 8'h27;   // rtl/no_slot_clock.sv
    localparam [7:0] T_U2_RX      = 8'h2A;   // rtl/uthernet2_card.sv
    localparam [7:0] T_U2_STAT    = 8'h2B;
    localparam [7:0] T_PRINTER_ROM = 8'h2D;  // rtl/printer_card.sv
    // The IIgs's three (docs/GS.md).  Missing from the list below until
    // rung 4b, which cost nothing but a lie: an unknown type is still
    // decoded and its payload still delivered (see hdr_known's use), so the
    // battery RAM landed and the keys arrived all along - while the card
    // announced each one as "a type the gateware does not consume, is the
    // bitstream older than this host?", which is exactly backwards and
    // buries the notices that mean something.
    localparam [7:0] T_GS_BRAM   = 8'h2E;   // rtl/gs_clock.sv
    localparam [7:0] T_ADB_KEY   = 8'h2F;   // rtl/gs_adb.sv
    localparam [7:0] T_GS_TIME   = 8'h30;   // rtl/gs_clock.sv
    localparam [7:0] T_FD35_TRACK = 8'h31;  // rtl/gs_iwm.sv (the same lie, 2026-09-12: the
                                            // first IWM bit reported every track it took)

    logic [7:0] blocks_left = 8'd0;

    // Read whenever there is something there.  Nothing downstream can stall:
    // every block is either a header we decode in one cycle or a payload block
    // we present for one cycle, so there is no back pressure to model.
    assign fifo_rd_en = !rst && !fifo_empty;

    wire        take = fifo_rd_en;
    wire [7:0]  hdr_len  = fifo_dout[7:0];
    wire [7:0]  hdr_type = fifo_dout[15:8];

    // Consumed here, or skipped and reported.  A type missing from this list
    // still costs nothing but a notice - the payload is walked by its
    // length either way.
    wire hdr_known = (hdr_type == T_IDLE)      || (hdr_type == T_BUS_ENABLE) ||
                     (hdr_type == T_REG_READ)  || (hdr_type == T_REG_WRITE)  ||
                     (hdr_type == T_HD_ROM)    || (hdr_type == T_HD_DONE)    ||
                     (hdr_type == T_HD_FETCH)  || (hdr_type == T_FD_ROM)     ||
                     (hdr_type == T_FD_TRACK)  || (hdr_type == T_MEM_ROM)    ||
                     (hdr_type == T_VIDHD_ROM) || (hdr_type == T_MOUSE_MOVE) ||
                     (hdr_type == T_MOUSE_ROM)  || (hdr_type == T_NSC_TIME)   ||
                     (hdr_type == T_U2_RX)      || (hdr_type == T_U2_STAT)   ||
                     (hdr_type == T_PRINTER_ROM) ||
                     (hdr_type == T_GS_BRAM)    || (hdr_type == T_ADB_KEY)   ||
                     (hdr_type == T_GS_TIME)    || (hdr_type == T_FD35_TRACK);

    always_ff @(posedge clk) begin
        if (rst) begin
            blocks_left <= 8'd0;
            msg_valid   <= 1'b0;
            msg_type    <= 8'd0;
            msg_free    <= 16'd0;
            msg_len     <= 8'd0;
            pay_valid   <= 1'b0;
            pay_data    <= 32'd0;
            unknown_valid <= 1'b0;
            unknown_type  <= 8'd0;
            unknown_len   <= 8'd0;
        end else begin
            msg_valid     <= 1'b0;
            pay_valid     <= 1'b0;
            unknown_valid <= 1'b0;

            if (take) begin
                if (blocks_left == 8'd0) begin
                    // Header.
                    msg_valid   <= 1'b1;
                    msg_type    <= hdr_type;
                    msg_len     <= hdr_len;
                    msg_free    <= fifo_dout[31:16];
                    blocks_left <= hdr_len;
                    if (!hdr_known) begin
                        unknown_valid <= 1'b1;
                        unknown_type  <= hdr_type;
                        unknown_len   <= hdr_len;
                    end
                end else begin
                    // Payload.
                    pay_data    <= fifo_dout;
                    pay_valid   <= 1'b1;
                    blocks_left <= blocks_left - 8'd1;
                end
            end
        end
    end

endmodule
