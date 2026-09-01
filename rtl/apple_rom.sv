`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// apple_rom - the IIe's 16 KB system ROM, on the card.
//
// $C000-$FFFF as the machine's ROM chips hold it: the internal $Cxxx ROM in the
// low 4 KB, the monitor and Applesoft in the 12 KB above.  The host loads it
// over the link (MEM_ROM, 32 chunks of 128 words) the way it loads the Disk II's
// boot ROM, so the gateware carries no Apple code; until every chunk has
// landed rom_loaded is low and nothing is served from here.
//
// WHY ITS OWN BLOCK RAM AND NOT THE IMAGE.  The ROM is 16 KB and the core
// fetches from it constantly - the monitor, BASIC, every ProDOS MLI call ends
// up here.  Held in DDR3 behind the cache it would compete with the program's
// own lines for a 32 KB cache; held here it is always a hit, at a fixed two
// clocks, and the cache is left to the RAM.  Four RAMB36 out of fifty.
//
// Two output registers on the read side for the same reason as
// cache_way_ram: the second is the BRAM's own, and it is slack.
//////////////////////////////////////////////////////////////////////////////////
module apple_rom #(
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

    // A byte, two clocks after rd_en.  rd_addr is the offset from $C000.
    input  wire        rd_en,
    input  wire [13:0] rd_addr,
    output wire [7:0]  rd_data,

    // The instruction front's line filler (rtl/iline.sv): a whole word, one
    // clock after r2_en, on the loader's port - which is idle from the moment
    // the ROM has landed.  A load in progress wins the port; the front
    // invalidates its ROM lines on any load traffic, so losing a beat to one
    // costs nothing but the retry.
    input  wire        r2_en,
    input  wire [11:0] r2_addr,       // word address: offset from $C000 >> 2
    output logic [31:0] r2_data,
    output wire        r2_busy,       // a load word is landing: this clock's read is lost

    output wire        rom_loaded
);

    localparam integer CHUNK_WORDS = 128;      // 32 chunks x 128 words = 16 KB

    (* ram_style = "block" *) logic [31:0] rom [0:4095];

    // ---- the read side ------------------------------------------------------
    logic [31:0] word_q, word_qq;
    logic [1:0]  lane_q, lane_qq;

    always_ff @(posedge clk) begin
        if (rd_en) begin
            word_q <= rom[rd_addr[13:2]];
            lane_q <= rd_addr[1:0];
        end
        word_qq <= word_q;
        lane_qq <= lane_q;
    end

    assign rd_data = word_qq[8 * lane_qq +: 8];

    // ---- the load: MEM_ROM chunks ------------------------------------------
    // Payload word 0 names the chunk; the 128 after it are its words.  A
    // message of any other length is not a chunk and is ignored whole.
    logic [7:0]  rx_type;
    logic [7:0]  rx_idx;
    logic [7:0]  rx_left;
    logic [4:0]  chunk;
    logic [31:0] seen;

    wire rx_word = pay_valid && (rx_left != 8'd0);
    wire word_rom = rx_word && (rx_type == T_MEM_ROM);
    wire rom_write = word_rom && (rx_idx != 8'd0);

    assign rom_loaded = &seen;

    // The ROM is written on its own so nothing with a reset shares its block.
    // The same port reads for the line filler when no load word is landing -
    // one port, two rare-to-collide users, the loader first.
    always_ff @(posedge clk) begin
        if (rom_write)   rom[{chunk, rx_idx[6:0] - 7'd1}] <= pay_data;
        else if (r2_en)  r2_data <= rom[r2_addr];
    end
    assign r2_busy = rom_write;

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type <= 8'd0;
            rx_idx  <= 8'd0;
            rx_left <= 8'd0;
            chunk   <= 5'd0;
            seen    <= 32'd0;
        end else begin
            if (msg_valid) begin
                rx_type <= (msg_type == T_MEM_ROM && msg_len == 8'(CHUNK_WORDS + 1))
                           ? msg_type : 8'd0;
                rx_idx  <= 8'd0;
                rx_left <= msg_len;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_rom && rx_idx == 8'd0) chunk <= pay_data[4:0];
                if (word_rom && rx_left == 8'd1) seen[chunk] <= 1'b1;
            end
        end
    end

endmodule
