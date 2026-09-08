`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// rom_loader - the IIe's 16 KB system ROM into the physical memory space.
//
// This replaces rtl/apple_rom.sv, which held the ROM in a block RAM of its own
// and served it from there.  With memory one physical space (docs/PAGE_CACHE.md)
// the ROM is bank $FF, pages $C0-$FF, and it is cached like anything else: the
// host's MEM_ROM message is now a producer of PHYSICAL WRITES, and after the
// load the ROM's sixty-four pages sit in the cache dirty, hit like any other
// page, and flush to the DDR3 only if something ever evicts them.
//
// THE WIRE FORMAT IS UNCHANGED - 32 chunks, each a word naming the chunk and
// 128 words of data - because there is nothing wrong with it.  What changes is
// the rate.  A chunk arrives at up to a word a clock, and a byte leaves through
// the posted-write seam every four clocks (apple_mmu takes one only when the
// cache's pipeline is clear), so the load is sixteen times slower than the link
// can deliver it and something has to give.  What gives is a 512-byte STAGING
// BUFFER, one chunk deep, and the host waiting for `busy` to fall between
// chunks (its MEM_STAT bit).  A chunk that arrives while the previous one is
// still draining is counted as an OVERRUN and dropped whole - it is not marked
// seen, so `rom_ok` stays low and the failure is loud rather than a ROM with a
// hole in it.
//
// The drain waits for `image_ready`: before the DDR3 has calibrated a write
// that misses is dropped, and every one of these misses (the first byte of
// each of the ROM's sixty-four pages fills the page first).
//
// THE WINDOW, and why the drain is not free-running.  The page cache serves
// one miss at a time and an op that misses while the engine is busy is
// counted (late_fills) and NOT served - which for a WRITE means the byte is
// lost.  That never happened before because only OPS started fills, and ops
// are ninety-eight clocks apart while a fill is fifty: the engine was always
// idle before the next one.  This loader is the first thing that can start a
// fill of its own, asynchronously, so it would break that invariant - and the
// first byte of each of the ROM's sixty-four pages is exactly such a fill.
//
// So a byte is offered only just after a bus cycle has begun, where a fill
// has the whole cycle to finish in, or when the machine has presented nothing
// for long enough that there is no cycle to be inside.  The load then takes a
// few milliseconds instead of half of one, at startup, once.
//////////////////////////////////////////////////////////////////////////////////
module rom_loader #(
    parameter [7:0] T_MEM_ROM = 8'h22
) (
    input  wire        clk,
    input  wire        rst,

    // Host -> card messages, as ft601_msg_rx decodes them.
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,

    // The posted-write seam, arbitrated with the data front's in master_top.
    // op_present is the bus cycle's start: see THE WINDOW below.
    input  wire        op_present,
    input  wire        image_ready,
    output wire        pw_valid,
    output wire [15:0] pw_ppn,
    output wire [7:0]  pw_off,
    output wire [7:0]  pw_data,
    input  wire        pw_take,

    output wire        busy,          // draining: the host waits on this
    output logic [7:0] overruns,      // chunks dropped because one was draining
    output wire        rom_ok         // all 32 chunks have landed whole
);

    localparam integer CHUNK_WORDS = 128;      // 32 chunks x 128 words = 16 KB

    // ---- the message ---------------------------------------------------------
    logic [7:0]  rx_type;
    logic [7:0]  rx_idx;
    logic [7:0]  rx_left;
    logic [4:0]  chunk;
    logic [31:0] seen;

    wire rx_word  = pay_valid && (rx_left != 8'd0);
    wire word_rom = rx_word && (rx_type == T_MEM_ROM);
    wire buf_we   = word_rom && (rx_idx != 8'd0);
    wire msg_end  = word_rom && (rx_left == 8'd1);

    assign rom_ok = &seen;

    // ---- the staging buffer: one chunk ---------------------------------------
    (* ram_style = "distributed" *) logic [31:0] stage [0:CHUNK_WORDS-1];
    logic [8:0] dr_k;              // the byte being drained, 0..511
    logic       draining;
    logic [4:0] dr_chunk;

    // Clocks since the last op, saturating: 0..WIN is the safe window, and
    // the saturated value means the machine has stopped presenting at all.
    localparam integer WIN = 24;
    logic [7:0] since_op;
    always_ff @(posedge clk) begin
        if (rst || op_present)        since_op <= 8'd0;
        else if (since_op != 8'hFF)   since_op <= since_op + 8'd1;
    end
    wire in_window = (since_op <= 8'(WIN)) || (since_op == 8'hFF);

    wire [31:0] dr_word = stage[dr_k[8:2]];

    always_ff @(posedge clk) begin
        if (buf_we) stage[rx_idx[6:0] - 7'd1] <= pay_data;
    end

    // ---- the drain ------------------------------------------------------------
    // Byte i of the ROM is at CPU address $C000 + i, which is physical
    // {$FF, $C0 + i[13:8]} offset i[7:0].
    wire [13:0] dr_byte = {dr_chunk, dr_k};
    assign pw_valid = draining && image_ready && in_window;
    assign pw_ppn   = {8'hFF, 2'b11, dr_byte[13:8]};
    assign pw_off   = dr_byte[7:0];
    assign pw_data  = dr_word[8 * dr_k[1:0] +: 8];
    assign busy     = draining;

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type  <= 8'd0;
            rx_idx   <= 8'd0;
            rx_left  <= 8'd0;
            chunk    <= 5'd0;
            seen     <= 32'd0;
            draining <= 1'b0;
            dr_k     <= 9'd0;
            dr_chunk <= 5'd0;
            overruns <= 8'd0;
        end else begin
            if (msg_valid) begin
                rx_type <= (msg_type == T_MEM_ROM && msg_len == 8'(CHUNK_WORDS + 1) &&
                            !draining) ? msg_type : 8'd0;
                if (msg_type == T_MEM_ROM && draining) overruns <= overruns + 8'd1;
                rx_idx  <= 8'd0;
                rx_left <= msg_len;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_rom && rx_idx == 8'd0) chunk <= pay_data[4:0];
            end

            // The message's last word starts the drain; the last byte of the
            // drain is what marks the chunk seen.
            if (msg_end) begin
                draining <= 1'b1;
                dr_k     <= 9'd0;
                dr_chunk <= chunk;
            end else if (draining && pw_take) begin
                if (dr_k == 9'd511) begin
                    draining     <= 1'b0;
                    seen[dr_chunk] <= 1'b1;
                end else begin
                    dr_k <= dr_k + 9'd1;
                end
            end
        end
    end

endmodule
