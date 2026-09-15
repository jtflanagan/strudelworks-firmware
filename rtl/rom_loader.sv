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
// THE WIRE FORMAT IS THE SAME SHAPE - N chunks, each a word naming the chunk
// and 128 words of data - because there is nothing wrong with it.  What is
// parameterised is WHERE the chunks land and HOW MANY there are, so that this
// loads any run of physical pages and not only the IIe's ROM: the IIgs's is
// 256 KB at bank $FC (docs/GS.md), the same message carrying eight times the
// chunks to a different base.  The defaults are the IIe's, so nothing about
// that machine moves.  What changes is
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
    parameter [7:0] T_MEM_ROM = 8'h22,
    // Chunks of 512 bytes, and the physical page the first of them lands on.
    // IIe: 32 chunks of the 16 KB ROM at bank $FF page $C0.
    // IIgs ROM 3: 512 chunks of 256 KB at bank $FC page $00.
    parameter int          N_CHUNKS = 32,
    parameter logic [15:0] ROM_PPN0 = 16'hFFC0,
    // THE FORMAL LOAD (docs/CLEAN_START.md CS2).  1: a MEM_ROM is taken only
    // while `hold` says the machine is held for the startup checklist - the
    // ROM never lands under a running machine.  0 (the benches that drive the
    // loader directly): never refused for that.
    parameter bit          REQUIRE_HOLD = 1'b0
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
    output wire        rom_ok,        // all 32 chunks have landed whole

    // The start hold (rtl/start_hold.sv): the machine is held.
    input  wire        hold,
    // MEM_ROM_ACK, card -> host (docs/CLEAN_START.md CS2), a msg_master port:
    //   header   {16'd0, T_MEM_ROM_ACK, len=1}
    //   payload  {sum16, status[3:0], chunk[11:0]}
    // One per MEM_ROM: `ok` when its 512 bytes have drained, carrying the
    // sum of those bytes as they left for the image; a refusal at once.
    output wire [31:0] ack_word,
    output wire        ack_valid,
    input  wire        ack_take,
    // The sum of every chunk's bytes on its FIRST landing, cleared with
    // `seen`: the host compares it with its own file once rom_ok is set.  A
    // chunk sent again (a retry after a lost ack) is acked but not added.
    output logic [31:0] rom_sum
);

    localparam [7:0] T_MEM_ROM_ACK = 8'h36;
    localparam [3:0] ST_OK        = 4'd0,
                     ST_OVERRUN   = 4'd1,   // arrived while a chunk was draining
                     ST_NOT_HELD  = 4'd2,   // the machine is running: refused
                     ST_BAD_LEN   = 4'd3,   // not {chunk} + 128 words
                     ST_BAD_INDEX = 4'd4;   // chunk number past the ROM

    localparam integer CHUNK_WORDS = 128;      // 128 words = 512 bytes a chunk
    localparam integer CW = $clog2(N_CHUNKS);  // bits of chunk index

    // ---- the message ---------------------------------------------------------
    logic [7:0]  rx_type;
    logic [7:0]  rx_idx;
    logic [7:0]  rx_left;
    logic [CW-1:0]        chunk;
    logic [N_CHUNKS-1:0]  seen;

    wire rx_word  = pay_valid && (rx_left != 8'd0);
    wire word_rom = rx_word && (rx_type == T_MEM_ROM);
    wire buf_we   = word_rom && (rx_idx != 8'd0);
    wire msg_end  = word_rom && (rx_left == 8'd1);

    assign rom_ok = &seen;

    // ---- the staging buffer: one chunk ---------------------------------------
    (* ram_style = "distributed" *) logic [31:0] stage [0:CHUNK_WORDS-1];
    logic [8:0] dr_k;              // the byte being drained, 0..511
    logic       draining;
    logic [CW-1:0] dr_chunk;

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
    // A chunk is two 256-byte pages, so the page this byte belongs to is the
    // chunk number and the top bit of the byte index, counted from the base.
    wire [CW:0] dr_page = {dr_chunk, dr_k[8]};
    assign pw_valid = draining && image_ready && in_window;
    assign pw_ppn   = ROM_PPN0 + {{(15 - CW){1'b0}}, dr_page};
    assign pw_off   = dr_k[7:0];
    assign pw_data  = dr_word[8 * dr_k[1:0] +: 8];
    assign busy     = draining;

    // ---- the ack --------------------------------------------------------------
    // kbd_notice's shape: one pending flag, the payload latched as the header
    // goes out.  The host sends one chunk and waits for its ack, so two acks
    // owed at once means a host that did not wait; the latest wins.
    logic        ack_pending, ack_in_msg;
    logic        ack_raise;                 // this clock owes an ack...
    logic [3:0]  ack_raise_status;          // ...with these
    logic [11:0] ack_raise_chunk;
    logic [15:0] ack_raise_sum;
    logic [3:0]  nx_status, tx_status;
    logic [11:0] nx_chunk,  tx_chunk;
    logic [15:0] nx_sum,    tx_sum;

    assign ack_valid = ack_pending || ack_in_msg;
    assign ack_word  = ack_in_msg ? {tx_sum, tx_status, tx_chunk}
                                  : {16'd0, T_MEM_ROM_ACK, 8'd1};

    always_ff @(posedge clk) begin
        if (rst) begin
            ack_pending <= 1'b0;
            ack_in_msg  <= 1'b0;
            nx_status <= '0; nx_chunk <= '0; nx_sum <= '0;
            tx_status <= '0; tx_chunk <= '0; tx_sum <= '0;
        end else begin
            if (ack_raise) begin
                ack_pending <= 1'b1;
                nx_status   <= ack_raise_status;
                nx_chunk    <= ack_raise_chunk;
                nx_sum      <= ack_raise_sum;
            end
            if (ack_take) begin
                if (!ack_in_msg) begin
                    ack_in_msg <= 1'b1;
                    tx_status  <= nx_status;
                    tx_chunk   <= nx_chunk;
                    tx_sum     <= nx_sum;
                    if (!ack_raise) ack_pending <= 1'b0;
                end else begin
                    ack_in_msg <= 1'b0;
                end
            end
        end
    end

    // ---- the message ------------------------------------------------------------
    // A MEM_ROM is REFUSED (never staged, never drained) for a wrong length,
    // for arriving while a chunk drains, for a machine that is not held, and -
    // once its first word says which chunk - for a chunk past the ROM.  Every
    // refusal is acked with its reason, and with its chunk number when the
    // message carried one.
    logic        rej;             // the current MEM_ROM was refused at its header
    logic [3:0]  rej_status;
    logic [16:0] dr_sum;          // the drained chunk's bytes, summed
    // ...with this clock's byte, for the last one: what the ack carries and
    // what a first landing adds to rom_sum.
    wire  [16:0] dr_sum_last = dr_sum + {9'd0, pw_data};

    always_ff @(posedge clk) begin
        ack_raise        <= 1'b0;
        ack_raise_status <= ST_OK;
        ack_raise_chunk  <= '0;
        ack_raise_sum    <= '0;
        if (rst) begin
            rx_type  <= 8'd0;
            rx_idx   <= 8'd0;
            rx_left  <= 8'd0;
            chunk    <= '0;
            seen     <= '0;
            draining <= 1'b0;
            dr_k     <= 9'd0;
            dr_chunk <= '0;
            overruns <= 8'd0;
            rej      <= 1'b0;
            rej_status <= ST_OK;
            dr_sum   <= '0;
            rom_sum  <= '0;
        end else begin
            if (msg_valid) begin
                rej     <= 1'b0;
                rx_type <= 8'd0;
                if (msg_type == T_MEM_ROM) begin
                    if (msg_len != 8'(CHUNK_WORDS + 1)) begin
                        rej <= 1'b1; rej_status <= ST_BAD_LEN;
                    end else if (draining) begin
                        rej <= 1'b1; rej_status <= ST_OVERRUN;
                        overruns <= overruns + 8'd1;
                    end else if (REQUIRE_HOLD && !hold) begin
                        rej <= 1'b1; rej_status <= ST_NOT_HELD;
                    end else begin
                        rx_type <= msg_type;
                    end
                    // A wrong length with no payload has no chunk to name.
                    if (msg_len == 8'd0) begin
                        ack_raise        <= 1'b1;
                        ack_raise_status <= ST_BAD_LEN;
                    end
                end
                rx_idx  <= 8'd0;
                rx_left <= msg_len;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (rx_idx == 8'd0 && (word_rom || rej)) begin
                    if (rej) begin
                        ack_raise        <= 1'b1;
                        ack_raise_status <= rej_status;
                        ack_raise_chunk  <= pay_data[11:0];
                        rej              <= 1'b0;
                    end else if (pay_data[31:CW] != '0) begin
                        // Past the ROM: stop staging this one.
                        rx_type          <= 8'd0;
                        ack_raise        <= 1'b1;
                        ack_raise_status <= ST_BAD_INDEX;
                        ack_raise_chunk  <= pay_data[11:0];
                    end else begin
                        chunk <= pay_data[CW-1:0];
                    end
                end
            end

            // The message's last word starts the drain; the last byte of the
            // drain is what marks the chunk seen, and what acks it.
            if (msg_end) begin
                draining <= 1'b1;
                dr_k     <= 9'd0;
                dr_chunk <= chunk;
                dr_sum   <= '0;
            end else if (draining && pw_take) begin
                if (dr_k == 9'd511) begin
                    draining       <= 1'b0;
                    seen[dr_chunk] <= 1'b1;
                    if (!seen[dr_chunk]) rom_sum <= rom_sum + {15'd0, dr_sum_last};
                    ack_raise        <= 1'b1;
                    ack_raise_status <= ST_OK;
                    ack_raise_chunk  <= 12'(dr_chunk);
                    ack_raise_sum    <= dr_sum_last[15:0];
                end else begin
                    dr_k   <= dr_k + 9'd1;
                    dr_sum <= dr_sum_last;
                end
            end
        end
    end

endmodule
