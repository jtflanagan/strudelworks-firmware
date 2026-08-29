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
// An unknown type therefore means the two ends no longer agree on where frames
// begin.  That is unrecoverable by design, so it is reported as frame_error and
// the top level turns it into a link reset - the same treatment as a watchdog
// expiry, because it is the same condition.
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

    // An unknown type: we have lost framing.  Latched until reset.
    output logic        frame_error
);

    // Types this card accepts.  Anything else is a desync, not an extension
    // point - a new type has to be added here before it can be sent.
    localparam [7:0] T_IDLE       = 8'h00;
    localparam [7:0] T_BUS_ENABLE = 8'h11;
    localparam [7:0] T_REG_READ   = 8'h14;
    localparam [7:0] T_REG_WRITE  = 8'h15;
    // The hard disk's three, host -> card: the slot ROM, a command's result
    // (with any bytes to put in the Apple's memory), and a request for bytes
    // out of it.  See rtl/hd_card.sv and docs/HARDDISK.md.
    localparam [7:0] T_HD_ROM     = 8'h18;
    localparam [7:0] T_HD_DONE    = 8'h19;
    localparam [7:0] T_HD_FETCH   = 8'h1A;
    // The floppy's two, host -> card: the boot ROM and a track chunk.  See
    // rtl/floppy_card.sv and docs/FLOPPY.md.
    localparam [7:0] T_FD_ROM     = 8'h1E;
    localparam [7:0] T_FD_TRACK   = 8'h1F;
    // The memory image's one, host -> card: a chunk of the system ROM for the
    // card's copy.  See rtl/apple_rom.sv and docs/MEMORY.md.  (Its absence
    // from this list was a whole evening: the host sent it, the card called it
    // lost framing, and the link dropped at every connect - docs/MEMORY.md.)
    localparam [7:0] T_MEM_ROM    = 8'h22;
    // The VidHD's one, host -> card: its slot ROM.  See rtl/vidhd_card.sv
    // and docs/VIDHD.md.
    localparam [7:0] T_VIDHD_ROM  = 8'h23;

    logic [7:0] blocks_left = 8'd0;

    // Read whenever there is something there.  Nothing downstream can stall:
    // every block is either a header we decode in one cycle or a payload block
    // we present for one cycle, so there is no back pressure to model.
    assign fifo_rd_en = !rst && !fifo_empty;

    wire        take = fifo_rd_en;
    wire [7:0]  hdr_len  = fifo_dout[7:0];
    wire [7:0]  hdr_type = fifo_dout[15:8];

    // Every host->card type has to appear here.  An unknown one is treated as
    // lost sync and reset the link, so forgetting to add a type is not a
    // message that gets ignored - it is a link that drops the moment the host
    // first uses it.
    wire hdr_known = (hdr_type == T_IDLE)      || (hdr_type == T_BUS_ENABLE) ||
                     (hdr_type == T_REG_READ)  || (hdr_type == T_REG_WRITE)  ||
                     (hdr_type == T_HD_ROM)    || (hdr_type == T_HD_DONE)    ||
                     (hdr_type == T_HD_FETCH)  || (hdr_type == T_FD_ROM)     ||
                     (hdr_type == T_FD_TRACK)  || (hdr_type == T_MEM_ROM)    ||
                     (hdr_type == T_VIDHD_ROM);

    always_ff @(posedge clk) begin
        if (rst) begin
            blocks_left <= 8'd0;
            msg_valid   <= 1'b0;
            msg_type    <= 8'd0;
            msg_free    <= 16'd0;
            msg_len     <= 8'd0;
            pay_valid   <= 1'b0;
            pay_data    <= 32'd0;
            frame_error <= 1'b0;
        end else begin
            msg_valid <= 1'b0;
            pay_valid <= 1'b0;

            if (take) begin
                if (blocks_left == 8'd0) begin
                    // Header.
                    msg_valid   <= 1'b1;
                    msg_type    <= hdr_type;
                    msg_len     <= hdr_len;
                    msg_free    <= fifo_dout[31:16];
                    blocks_left <= hdr_len;
                    if (!hdr_known) frame_error <= 1'b1;
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
