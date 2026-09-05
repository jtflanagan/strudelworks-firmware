`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// hd_card - a hard disk controller's slot, on the card that IS the CPU, with
// the disk itself on the host.
//
// The controller is AppleWin's SmartPort HDC (source/Harddisk.cpp and
// firmware/HDD-SmartPort), the project's reference: a slot ROM ProDOS talks
// to, a page of I/O registers the ROM pokes a command into, and an EXECUTE
// port that runs it and reports busy until it is done.  This module carries
// the half of that the BUS can see and nothing of the half it cannot - it
// does not know what a command is.  The host decodes the register writes out
// of the capture stream it already receives (strudelworks-host
// src/hd_card.cpp mirrors AppleWin's IOWrite and CmdExecute), keeps the .hdv
// images, and tells this module what to answer.  See docs/HARDDISK.md.
//
// WHAT THE CARD CLAIMS, all reads:
//
//   $Cn00-$CnFF   the slot ROM.  256 bytes the HOST loads (HD_ROM), so the
//                 gateware carries no 6502 code and the firmware can change
//                 without a bitstream.  Gated by rtl/slot_switches.sv,
//                 because $Cnxx is motherboard ROM when INTCXROM is set.
//   $C0n0         EXECUTE / STATUS - busy, below.
//   $C0n1         STATUS: the same byte.
//   $C0n9/$C0nA   image size in blocks, low/high, latched from the last
//                 HD_DONE.  The ROM reads them after a BLK STATUS.
//
// (n = slot + 8 for the $C0nx page.)  Writes are not claimed by anyone, which
// is what a write to an empty slot's DEVICE SELECT' is anyway; the host sees
// them in the stream, and that is the whole of the command path.
//
// BUSY.  A read of $C0n0 with a command ARMED - a register written since the
// last EXECUTE - is an EXECUTE: the card counts it outstanding and answers
// $80, busy.  Every read after that is a poll, answered $80 while anything is
// outstanding, and the ROM's `lda IO_Execute,x / bmi` loop spins on it while
// the host does the work.  The host's HD_DONE, in order, answers the oldest
// EXECUTE: when the last is answered the port reads the status it carried.
// The CPU runs throughout; the card is a slot card with a slow disk.
//
// Why "armed" and "outstanding", which AppleWin has no need of: AppleWin
// completes every command on the EXECUTE read itself, and the ROM's
// bootstrap relies on that - it issues a BLK STATUS with NO poll loop and
// goes straight on to the block READ.  With the answer a round trip away the
// second EXECUTE arrives while the first is still busy, and a card that took
// every read as a poll would swallow it.  So a read executes only when a
// write has armed one, and two commands can be outstanding at once.  Ordinary
// drivers poll before their next command and never reach two.
//
// DMA is the one moment the CPU is stopped.  The bytes of a block read (or a
// SmartPort status list) arrive with the HD_DONE; the card raises the
// driver's override - the boot hold's mechanism, with the address stepping
// and R/W low - and writes them into the Apple's memory one per bus cycle,
// in the window the core's own write would use, with the core simply not
// advanced.  A block write is the reverse: HD_FETCH names the bytes, the card
// reads them out the same way, sends them to the host as HD_DATA, and stays
// busy until the HD_DONE.  Every byte moved is a captured event, so the
// host's display shadow sees a block land in memory as ordinary writes.  512
// bytes is half a millisecond of machine time, which is what AppleWin charges
// for the same transfer.
//
// A HOST THAT NEVER ANSWERS - dead, or not running the disk - would leave the
// ROM spinning forever.  So busy times out, and the port reads AppleWin's own
// "no device connected" status ($51: error $28 in bits 6..1, bit 0 set): the
// ROM gives up on the slot and the machine boots from the next one.  The
// host's own timeout is shorter, so a live host always answers first; see
// docs/HARDDISK.md for the one race that leaves.
//
// RESET DROPS EVERYTHING OUTSTANDING.  The command state follows the core's
// reset, as the boot hold does, and RES' resets the core; the ROM, the slot
// and the size latch survive, as a card's would.
//////////////////////////////////////////////////////////////////////////////////
module hd_card #(
    // Fabric cycles a command stays busy before the card gives up on the
    // host.  2 s at 100 MHz; a testbench shortens it.
    parameter integer STALL_TIMEOUT = 200_000_000,
    parameter [7:0] T_HD_ROM   = 8'h18,
    parameter [7:0] T_HD_DONE  = 8'h19,
    parameter [7:0] T_HD_FETCH = 8'h1A,
    parameter [7:0] T_HD_DATA  = 8'h1B
) (
    input  wire        clk,
    // The CARD's reset: clears the ROM, the buffer and the size latch.
    input  wire        rst,
    // The CORE's reset (card reset OR RES' asserted): drops what is busy.
    input  wire        cpu_rst,
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
    // The byte the bus returned, valid at op_commit.
    input  wire [7:0]  din,

    // To apple_bus_write, through the top's mux with the boot hold's.
    output wire        ovr_en,
    output wire [15:0] ovr_addr,
    output wire        ovr_rw,
    output wire [7:0]  ovr_wdata,

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

    // Card -> host: HD_DATA, streamed through msg_arb's application port.
    output wire [31:0] tx_word,
    output wire        tx_valid,
    input  wire        tx_take,

    // For the HD_SLOT register.
    output wire        rom_loaded,
    output wire        busy,
    output logic [7:0] execs,
    // The presented op is an EXECUTE (an armed read of $C0n0), registered
    // at present and held to the next: the stream's door keeps that read's
    // word for the host in the closed regime, where the port's busy polls
    // are fast ops and dropped (docs/CXXX.md, "The on-card slots").
    output logic       exec_q
);

    // ---- what this card answers as -----------------------------------------
    wire enabled = master_active && (slot_assign != 3'd0) && rom_loaded;

    wire io_select;
    slot_switches u_sw (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .slot (slot_assign),
        .io_select (io_select)
    );

    // ---- the slot ROM --------------------------------------------------------
    // 32 bits wide, written a word at a time from HD_ROM, read a byte at a
    // time by address; one port each way, which is what lets it be a LUT RAM.
    logic [31:0] rom [0:63];
    logic        rom_ok;
    assign rom_loaded = rom_ok;

    wire [31:0] rom_word = rom[op_addr[7:2]];
    wire [7:0]  rom_byte = rom_word[8 * op_addr[1:0] +: 8];

    // ---- the block buffer ----------------------------------------------------
    // 512 bytes as four 128-byte banks, byte i in bank i[1:0] at i[8:2].  A
    // word from the host (HD_DONE) lands in all four at once; a byte off the
    // bus (a fetch) in one; a word to the host (HD_DATA) reads all four.
    // Each bank has exactly one write port, muxed between the two writers,
    // which never run at once - a fetch is a bus operation, and the host's
    // words arrive while the bus is the core's.
    logic [7:0] bank0 [0:127];
    logic [7:0] bank1 [0:127];
    logic [7:0] bank2 [0:127];
    logic [7:0] bank3 [0:127];

    // ---- the command port ----------------------------------------------------
    // What the ROM does to the page, seen in the presented ops.
    wire       hit_page = enabled && (op_addr[15:4] == {8'hC0, 1'b1, slot_assign});
    wire [3:0] idx      = op_addr[3:0];

    // A register write arms a command; the core's read of $C0n0 executes it.
    wire arm_write = op_commit  && hit_page && !op_rw && (idx >= 4'h2) && (idx <= 4'hA);
    wire exec_read = op_present && !op_ovr && hit_page && op_rw && (idx == 4'h0);

    logic       armed;
    logic [1:0] outstanding;        // EXECUTEs taken and not yet answered
    assign busy = (outstanding != 2'd0);

    wire take_exec = exec_read && armed;
    always_ff @(posedge clk) begin
        if (rst)             exec_q <= 1'b0;
        else if (op_present) exec_q <= take_exec;
    end

    // ---- host -> card messages ---------------------------------------------
    // Which message's payload is arriving, and where in it we are.
    logic [7:0] rx_type;
    logic [7:0] rx_idx;             // payload words received so far
    logic [7:0] rx_left;            // payload words still to come

    wire rx_hdr  = msg_valid;
    wire rx_word = pay_valid && (rx_left != 8'd0);
    wire rx_last = rx_word && (rx_left == 8'd1);   // this word completes it

    wire hdr_rom   = rx_hdr && (msg_type == T_HD_ROM);
    wire hdr_done  = rx_hdr && (msg_type == T_HD_DONE);
    wire hdr_fetch = rx_hdr && (msg_type == T_HD_FETCH);

    wire word_rom   = rx_word && (rx_type == T_HD_ROM);
    wire word_done  = rx_word && (rx_type == T_HD_DONE);
    wire word_fetch = rx_word && (rx_type == T_HD_FETCH);

    // What a DMA has been told: base address, byte count, and the status the
    // command ends with.  `size` is the size-in-blocks latch for $C0n9/$C0nA.
    logic [15:0] dma_base;
    logic [9:0]  dma_count;         // 0..512
    logic [7:0]  status;
    logic [15:0] size;

    // Registered one-cycle events out of the receiver.
    logic done_evt;                 // an HD_DONE is complete
    logic fetch_evt;                // an HD_FETCH is complete

    // Bytes to 0..512, from a 16-bit field the host is trusted with.
    function automatic [9:0] clamp512(input [15:0] n);
        clamp512 = (n > 16'd512) ? 10'd512 : n[9:0];
    endfunction

    // The ROM, written on its own so nothing with a reset shares its block.
    always_ff @(posedge clk) begin
        if (word_rom) rom[rx_idx[5:0]] <= pay_data;
    end

    // A command that stayed busy past the timeout: completed as AppleWin
    // completes one for a unit that is not there.  Declared ahead of the
    // state machine because the status latch below is written from here.
    wire timed_out;

    // An HD_DONE or HD_FETCH is only listened to while a command is
    // outstanding and the bus is the core's.  Late - after a timeout, or
    // after a reset dropped the command - it is consumed and ignored, so it
    // cannot corrupt the status and size a later command will read back.
    // Arriving while a previous answer's DMA is still in progress it would
    // be lost too: the host spaces its answers for exactly that reason (see
    // strudelworks-host hd_service.cpp).
    typedef enum logic [1:0] {
        S_IDLE,     // the core runs; the port answers busy or the status
        S_DMA_W,    // writing the host's bytes into the Apple's memory
        S_DMA_R,    // reading bytes out of it, for the host
        S_SEND      // streaming them to the host as HD_DATA
    } state_t;

    state_t st;

    wire accept = busy && (st == S_IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type   <= 8'd0;
            rx_idx    <= 8'd0;
            rx_left   <= 8'd0;
            rom_ok    <= 1'b0;
            dma_base  <= 16'd0;
            dma_count <= 10'd0;
            status    <= 8'h51;     // no device connected, until told otherwise
            size      <= 16'd0;
            done_evt  <= 1'b0;
            fetch_evt <= 1'b0;
        end else begin
            done_evt  <= 1'b0;
            fetch_evt <= 1'b0;

            if (timed_out) status <= 8'h51;     // error $28, no device connected

            if (rx_hdr) begin
                rx_type <= msg_type;
                rx_idx  <= 8'd0;
                rx_left <= msg_len;
                if (hdr_done && accept) begin
                    // The status rides in the header; the rest, if any, in
                    // the payload.  A header-only HD_DONE is "no bytes".
                    status    <= msg_free[7:0];
                    dma_count <= 10'd0;
                    if (msg_len == 8'd0) done_evt <= 1'b1;
                end
                if ((hdr_done || hdr_fetch) && !accept) rx_type <= 8'd0;
                // A ROM message is only a ROM if it is the whole ROM.
                if (hdr_rom && msg_len != 8'd64) rx_type <= 8'd0;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;

                if (word_rom && rx_last) rom_ok <= 1'b1;
                if (word_done) begin
                    // [0] = {count, addr}, [1] = {0, size}, [2..] = the bytes.
                    if (rx_idx == 8'd0) begin
                        dma_base  <= pay_data[15:0];
                        dma_count <= clamp512(pay_data[31:16]);
                    end else if (rx_idx == 8'd1) begin
                        size <= pay_data[15:0];
                    end
                    if (rx_last) done_evt <= 1'b1;
                end
                if (word_fetch) begin
                    if (rx_idx == 8'd0) begin
                        dma_base  <= pay_data[15:0];
                        dma_count <= clamp512(pay_data[31:16]);
                    end
                    if (rx_last) fetch_evt <= 1'b1;
                end
            end
        end
    end

    // ---- the DMA ---------------------------------------------------------------
    // pidx counts bytes presented, cidx bytes captured; one op is in flight
    // between the two.
    logic [9:0] pidx, cidx;
    logic       in_flight;
    wire [15:0] dma_addr = dma_base + {6'd0, pidx};

    wire dma_w_active = (st == S_DMA_W) && (pidx != dma_count);
    wire dma_r_active = (st == S_DMA_R) && (pidx != dma_count);

    // The override is raised only for a byte to move, so the core resumes
    // the cycle after the last one is presented.
    assign ovr_en    = dma_w_active || dma_r_active;
    assign ovr_addr  = dma_addr;
    assign ovr_rw    = !dma_w_active;

    // The byte for the write being offered, from the bank pidx selects.
    logic [7:0] wbyte;
    always_comb begin
        case (pidx[1:0])
            2'd0:    wbyte = bank0[pidx[8:2]];
            2'd1:    wbyte = bank1[pidx[8:2]];
            2'd2:    wbyte = bank2[pidx[8:2]];
            default: wbyte = bank3[pidx[8:2]];
        endcase
    end
    assign ovr_wdata = wbyte;

    // The driver latched what was being offered: the presented op is ours.
    wire ours = op_present && op_ovr && (op_addr == ovr_addr) && (op_rw == ovr_rw);

    // ---- the timeout --------------------------------------------------------------
    localparam integer TO_W = $clog2(STALL_TIMEOUT + 1);
    logic [TO_W-1:0] to_cnt;
    wire  to_fire = (to_cnt == STALL_TIMEOUT[TO_W-1:0]);
    assign timed_out = accept && to_fire && !done_evt && !fetch_evt;

    // ---- HD_DATA out -----------------------------------------------------------
    // Header, then ceil(count / 4) words of the buffer.
    wire [9:0] nwords = (dma_count + 10'd3) >> 2;
    logic [9:0] widx;                 // 0 = header, 1.. = payload
    wire [6:0]  wsel = widx[6:0] - 7'd1;
    wire [31:0] buf_word = {bank3[wsel], bank2[wsel], bank1[wsel], bank0[wsel]};

    assign tx_valid = (st == S_SEND);
    assign tx_word  = (widx == 10'd0) ? {6'd0, dma_count, T_HD_DATA, nwords[7:0]}
                                      : buf_word;

    // ---- buffer writes -----------------------------------------------------------
    // One writer at a time per bank: the host's word, or a captured byte.
    wire        cap      = (st == S_DMA_R) && op_commit && in_flight;
    wire        host_wr  = word_done && (rx_idx >= 8'd2) && (rx_idx < 8'd130);
    wire [6:0]  host_idx = rx_idx[6:0] - 7'd2;
    wire [6:0]  waddr    = host_wr ? host_idx : cidx[8:2];

    always_ff @(posedge clk) begin
        if (host_wr || (cap && cidx[1:0] == 2'd0)) bank0[waddr] <= host_wr ? pay_data[7:0]   : din;
        if (host_wr || (cap && cidx[1:0] == 2'd1)) bank1[waddr] <= host_wr ? pay_data[15:8]  : din;
        if (host_wr || (cap && cidx[1:0] == 2'd2)) bank2[waddr] <= host_wr ? pay_data[23:16] : din;
        if (host_wr || (cap && cidx[1:0] == 2'd3)) bank3[waddr] <= host_wr ? pay_data[31:24] : din;
    end

    // ---- the state machine -------------------------------------------------------
    always_ff @(posedge clk) begin
        if (cpu_rst || !enabled) begin
            st          <= S_IDLE;
            armed       <= 1'b0;
            outstanding <= 2'd0;
            pidx        <= 10'd0;
            cidx        <= 10'd0;
            in_flight   <= 1'b0;
            to_cnt      <= '0;
            widx        <= 10'd0;
        end else begin
            // The port.  A write arms; an armed read executes, saturating at
            // three outstanding, which no driver reaches.
            if (arm_write) armed <= 1'b1;
            if (take_exec) begin
                armed <= 1'b0;
                if (outstanding != 2'd3) outstanding <= outstanding + 2'd1;
            end

            // Busy time, towards the timeout.  Restarted by every answer.
            if (!busy || done_evt || fetch_evt) to_cnt <= '0;
            else                                to_cnt <= to_cnt + 1'b1;
            if (timed_out) outstanding <= 2'd0;

            case (st)
                S_IDLE: begin
                    if (done_evt) begin
                        // The oldest outstanding command is answered.  With
                        // bytes to move the core is paused first; the count
                        // drops when the last has gone out, so the port stays
                        // busy until the block is in memory.
                        if (dma_count != 10'd0) begin
                            pidx <= 10'd0;
                            st   <= S_DMA_W;
                        end else begin
                            outstanding <= outstanding - 2'd1;
                        end
                    end else if (fetch_evt) begin
                        pidx      <= 10'd0;
                        cidx      <= 10'd0;
                        in_flight <= 1'b0;
                        widx      <= 10'd0;
                        st        <= (dma_count != 10'd0) ? S_DMA_R : S_SEND;
                    end
                end

                S_DMA_W: begin
                    if (ours && dma_w_active) begin
                        pidx <= pidx + 10'd1;
                        if (pidx == dma_count - 10'd1) begin
                            st          <= S_IDLE;
                            outstanding <= outstanding - 2'd1;
                        end
                    end
                end

                S_DMA_R: begin
                    if (ours && dma_r_active) begin
                        pidx      <= pidx + 10'd1;
                        in_flight <= 1'b1;
                    end
                    if (cap) begin
                        cidx      <= cidx + 10'd1;
                        in_flight <= 1'b0;
                        if (cidx == dma_count - 10'd1) st <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (tx_take) begin
                        widx <= widx + 10'd1;
                        if (widx == nwords) st <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // The EXECUTE count survives the core's reset: it is a count of what
    // happened, and a reset is not a reason to forget it.
    always_ff @(posedge clk) begin
        if (rst)                     execs <= 8'd0;
        else if (take_exec && enabled) execs <= execs + 8'd1;
    end

    // ---- claim and read data ---------------------------------------------------
    // Decided in the address phase from the presented op, registered so it is
    // stable long before the emit window.  A DMA read is never claimed: those
    // cycles are the memory's to answer.
    wire hit_rom = enabled && op_rw && io_select &&
                   (op_addr[15:8] == {4'hC, 1'b0, slot_assign});

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_claim <= 1'b0;
            rd_data  <= 8'd0;
        end else if (op_present) begin
            rd_claim <= 1'b0;
            rd_data  <= 8'd0;
            if (st != S_DMA_R) begin
                if (hit_rom) begin
                    rd_claim <= 1'b1;
                    rd_data  <= rom_byte;
                end else if (hit_page && op_rw) begin
                    case (idx)
                        // Busy while anything is outstanding - including the
                        // read that is itself an EXECUTE, which is busy by
                        // definition - and the status otherwise.
                        4'h0: begin rd_claim <= 1'b1; rd_data <= (busy || armed) ? 8'h80 : status; end
                        4'h1: begin rd_claim <= 1'b1; rd_data <= busy ? 8'h80 : status; end
                        4'h9: begin rd_claim <= 1'b1; rd_data <= size[7:0];  end
                        4'hA: begin rd_claim <= 1'b1; rd_data <= size[15:8]; end
                        default: ;
                    endcase
                end
            end
        end else if (!enabled) begin
            rd_claim <= 1'b0;
        end
    end

endmodule
