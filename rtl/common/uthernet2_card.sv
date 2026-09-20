`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// uthernet2_card - an Uthernet II on the card that IS the CPU, with the
// network on the host.
//
// The Uthernet II is a WIZnet W5100 behind four bytes of DEVICE SELECT and
// nothing else: $C0n4 the chip's mode register (bit 1 auto-increment, bit 7
// reset), $C0n5/$C0n6 an address into the chip's 32 KB map, $C0n7 the byte
// there, stepping the address after each access when auto-increment is set.
// Only A0 and A1 are decoded, so $C0n0-$C0n3 alias.  Behind the data port:
// the common registers at $0000-$002F, four sockets' registers at $0400,
// $0500, $0600, $0700, 8 KB of TX ring at $4000 and 8 KB of RX ring at
// $6000, split between the sockets by RMSR/TMSR.  The chip does TCP, UDP and
// raw IP itself, or hands the program raw Ethernet frames (MACRAW) - which
// is what every Apple II stack in the wild asks for: Contiki and IP65 both
// open socket 0 in MACRAW, poll Sn_RX_RSR, read frames out of the ring a
// byte at a time, and write frames in the same way before a SEND.
//
// This module is AppleWin's model of the chip (source/Uthernet2.cpp, the
// project's reference) with the network taken away: the registers, the
// rings, the pointer and its wraps, the socket state machine and the pointer
// arithmetic behind OPEN/SEND/RECV/CLOSE are here, and the host is told what
// the program asked for and tells the card what came back through four
// messages (docs/UTHERNET2.md):
//
//   U2_CMD  card->host  every write to a socket's command register, and a
//                       reset: the socket, the command, and the common and
//                       socket registers as the program would read them.
//   U2_TX   card->host  after a SEND: the bytes from Sn_TX_RD to Sn_TX_WR
//                       out of the ring, in self-describing chunks.
//   U2_RX   host->card  bytes to append at a socket's RX write pointer, the
//                       W5100's header already in front; the card lands
//                       them, moves the pointer and adds to Sn_RX_RSR.
//   U2_STAT host->card  a socket's status byte, and for an accepted LISTEN
//                       the peer's address and port.
//
// The host mirrors nothing from the capture stream: the data pointer moves
// on reads too, and a driver reads Sn_RX_RSR and Sn_RX_RD in one run before
// it writes anything, so a mirror would need the reads the door drops.  The
// card is authoritative.
//
// WHERE IT HANGS: on the peripherals' view of the op stream like the mouse
// (rtl/mouse_card.sv, docs/CXXX.md "The on-card slots"): a claimed read's
// byte goes back through apple_bus_write's data window in mode 0, and in
// the closed regime the access is a fast op served at three clocks.
// DEVICE SELECT only - the card has no ROM - so nothing here is gated by a
// soft switch.  The card only exists while the soft core masters.
//
// THE DATA PORT'S TIMING.  A claimed read's byte is registered at the
// present, one clock after the dispatch, and the fast op's decision is two
// clocks later still (the mouse's contract).  A register byte is
// combinational off the pointer (distributed RAM).  A ring byte comes from
// block RAM, one clock away, so the WORD at the pointer and the word after
// it are held in registers: an auto-increment within a word needs no read,
// one that crosses a word takes the next word already held and refetches
// the one after, and a write to the pointer fetches its word on the clock
// of the commit that sets it, so the byte is there for the earliest next
// op the sequencer can present (the commit's clock + 2, sim/uthernet2_tb.sv
// drives exactly that spacing).  A read landing on the present's clock is
// bypassed straight into the byte.  A host write into a held word
// invalidates it and it is refetched; stall_o holds the core's next op
// while a held word is missing, the floppy's route, and is the only
// reason this card ever holds the core.
//
// THE RINGS: 16 KB as four byte-lane block RAMs (rtl/fd_bank.sv), byte i in
// lane i[1:0] at word i[13:2]; TX at $0000-$1FFF of that, RX at $2000-$3FFF.
// Port A is the program's; port B the host's: a U2_RX payload word is four
// consecutive bytes at an arbitrary ring offset, one write per lane at its
// own address, one clock a word, no FIFO; a U2_TX word is read the same
// way.  Host writes have the port; the sender waits.
//
// THE REGISTERS: the 240 bytes the program can address (the common block,
// four sockets' $00-$2F) in four byte-lane distributed RAMs of 128 entries
// indexed {block, word}, with a "fresh" bit per byte that reads as the
// reset constant until the byte is first written - so a reset is one
// clock, as AppleWin's is, and MR reads 0 the clock after a program sets
// its reset bit (Contiki polls for that).  The values the chip computes
// are overlaid on reads: MR, Sn_SR, Sn_CR (always 0 - the chip clears it
// as it takes the command), Sn_TX_FSR, Sn_TX_RD, Sn_TX_WR, Sn_RX_RSR,
// Sn_RX_RD.
//
// RESET: the card's reset clears everything, the data pointer included.
// RES' and the mode register's reset bit reset the chip as AppleWin's
// Reset(false) does - registers, sockets, pointers - and queue a reset
// U2_CMD; the data pointer survives them (the manual, page 10).
//
// WHAT THIS CARD NEVER DOES: take a bus cycle, or drive one it did not claim.
//////////////////////////////////////////////////////////////////////////////////
module uthernet2_card #(
    parameter [7:0] T_U2_CMD  = 8'h28,
    parameter [7:0] T_U2_TX   = 8'h29,
    parameter [7:0] T_U2_RX   = 8'h2A,
    parameter [7:0] T_U2_STAT = 8'h2B
) (
    input  wire        clk,
    // The CARD's reset: everything.
    input  wire        rst,
    // Synchronised RES', ACTIVE LOW.
    input  wire        res_sync,
    // 1 while the soft core owns the bus.  Nothing here exists otherwise.
    input  wire        master_active,
    // Which slot to answer as; 0 disables.  Latched at RES' by wb_regfile.
    input  wire [2:0]  slot_assign,
    // The presented op (the peripherals' view): stable from op_present
    // through op_commit.
    input  wire [15:0] op_addr,
    input  wire        op_rw,          // 1 = read
    input  wire [7:0]  op_wdata,
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
    // Card -> host: a whole message a word at a time, a msg_arb port.
    output wire [31:0] tx_word,
    output wire        tx_valid,
    input  wire        tx_take,
    // Hold the accelerated core's next op: a held ring word is missing.
    output wire        stall_o,
    // For the register's readback.
    output wire [3:0]  sock_open,      // Sn_SR != 0
    output wire        cmd_dropped,    // sticky: the command queue overflowed
    output wire [7:0]  cmds_o,         // U2_CMDs sent, wrapping
    output wire [7:0]  rx_chunks_o,    // U2_RX chunks landed, wrapping
    output wire [15:0] s0_rsr_o,
    output wire [15:0] s0_fsr_o
);
    // ---- the W5100's constants -------------------------------------------------
    localparam [7:0] CR_OPEN    = 8'h01, CR_LISTEN = 8'h02, CR_CONNECT = 8'h04,
                     CR_DISCON  = 8'h08, CR_CLOSE  = 8'h10, CR_SEND    = 8'h20,
                     CR_RECV    = 8'h40;
    localparam [7:0] SR_CLOSED  = 8'h00, SR_INIT   = 8'h13, SR_LISTEN  = 8'h14,
                     SR_SYNSENT = 8'h15, SR_UDP    = 8'h22, SR_IPRAW   = 8'h32,
                     SR_MACRAW  = 8'h42;
    localparam [3:0] MR_TCP = 4'h1, MR_UDP = 4'h2, MR_IPRAW = 4'h3, MR_MACRAW = 4'h4;
    localparam [13:0] CHUNK_BYTES = 14'd1020;   // 255 words

    // ---- what this card answers as ----------------------------------------------
    wire enabled = master_active && (slot_assign != 3'd0);
    wire hit_dev = enabled && !op_ovr &&
                   (op_addr[15:8] == 8'hC0) && op_addr[7] && (op_addr[6:4] == slot_assign);
    logic hit_q;

    // ---- the chip's state ------------------------------------------------------------
    logic [7:0]  mr;                    // bits 6:0; bit 7 (reset) never stays set
    logic [15:0] ptr;                   // the data pointer
    logic [7:0]  sr     [0:3];          // Sn_SR
    logic [15:0] tx_rd  [0:3];          // the chip's, moved by SEND
    logic [15:0] tx_wr  [0:3];          // the program's, shadowed here
    logic [15:0] rx_rd  [0:3];          // the program's, shadowed here
    logic [12:0] rx_wr  [0:3];          // the chip's, moved by U2_RX; an offset in the region
    logic [15:0] rsr    [0:3];          // Sn_RX_RSR
    logic [15:0] fsr_q  [0:3];          // Sn_TX_FSR, a clock behind
    logic [7:0]  rmsr, tmsr;            // shadows of the split registers

    // RES' as an edge, for the one reset message; the level holds the state.
    logic res_prev;
    always_ff @(posedge clk) res_prev <= res_sync;
    wire res_assert = res_prev && !res_sync;
    wire soft_hold  = !res_sync;

    // ---- the pointer, decoded ----------------------------------------------------------
    wire        p_common = (ptr[15:6] == 10'd0) && (ptr[5:2] < 4'd12);                          // $0000-$002F
    wire        p_sock   = (ptr[15:10] == 6'b000001) && (ptr[7:6] == 2'b00) && (ptr[5:2] < 4'd12); // $04xx-$07xx, $00-$2F
    wire        p_tx     = (ptr[15:13] == 3'b010);
    wire        p_rx     = (ptr[15:13] == 3'b011);
    wire        p_buf    = p_tx || p_rx;
    wire        p_reg    = p_common || p_sock;
    wire [2:0]  p_blk    = p_common ? 3'd0 : {1'b0, ptr[9:8]} + 3'd1;
    wire [6:0]  p_idx    = {p_blk, ptr[5:2]};
    wire [1:0]  p_lane   = ptr[1:0];
    wire [11:0] p_widx   = ptr[13:2];   // the ring word
    // The word after this one, with the auto-increment's wraps: the TX ring
    // wraps onto itself and so does the RX ring (the manual, page 12).
    wire [11:0] p_widx_next = (ptr[13:2] == 12'h7FF) ? 12'h000 :
                              (ptr[13:2] == 12'hFFF) ? 12'h800 : ptr[13:2] + 12'd1;
    wire [15:0] ptr_inc = (ptr == 16'h5FFF) ? 16'h4000 :
                          (ptr == 16'h7FFF) ? 16'h6000 : ptr + 16'd1;

    // ---- the regions from RMSR/TMSR (AppleWin's setRXSizes/setTXSizes) --------------
    // Two bits a socket, 1 KB << bits, laid end to end and clamped at 8 KB -
    // which is a RUNNING SUM, and was written as one that starts over for
    // every socket: region_base(n) summed n terms, region_size(n) called
    // region_base twice more, and the whole thing was rebuilt every clock
    // for four sockets and two registers.  A dozen adders, standing, for two
    // bytes that move once at setup and never again.
    //
    // Here it is what it is: an accumulator and a step.  A write to RMSR or
    // TMSR (or a chip reset) kicks a four-step walk that lays the four
    // regions down, one socket a clock, RX and TX together - two adders in
    // place of two dozen.  The core is held while it walks, because the
    // masks are live wiring; four clocks, once, at setup.
    localparam [14:0] REG_TOP = 15'd8192;
    logic [13:0] rx_base [0:3], rx_size [0:3], tx_base [0:3], tx_size [0:3];
    logic [12:0] rx_mask [0:3], tx_mask [0:3];
    logic [2:0]  rg_n;                  // 0..3 walking, 4 = laid down
    logic [14:0] rg_racc, rg_tacc;      // where the next region starts
    wire         rg_busy = (rg_n != 3'd4);
    wire [1:0]   rg_s    = rg_n[1:0];
    wire [14:0]  rg_rsum = rg_racc + (15'd1024 << rmsr[2*rg_s +: 2]);
    wire [14:0]  rg_tsum = rg_tacc + (15'd1024 << tmsr[2*rg_s +: 2]);
    wire [14:0]  rg_rend = (rg_rsum > REG_TOP) ? REG_TOP : rg_rsum;
    wire [14:0]  rg_tend = (rg_tsum > REG_TOP) ? REG_TOP : rg_tsum;
    wire [13:0]  rg_rlen = rg_rend[13:0] - rg_racc[13:0];
    wire [13:0]  rg_tlen = rg_tend[13:0] - rg_tacc[13:0];
    // Sn_TX_FSR, a clock behind, for the one socket whose pointers or region
    // just moved - the same clock's lag the four-at-once form had, and one
    // subtractor instead of four.
    logic [1:0]  fs_n;
    logic        fs_pend;
    wire         fs_kick_sock = reg_write && p_sock &&
                                ((ptr[5:0] == 6'h24) || (ptr[5:0] == 6'h25));
    always_ff @(posedge clk) begin
        if (rg_kick) begin
            rg_n <= 3'd0; rg_racc <= 15'd0; rg_tacc <= 15'd0;
            fs_pend <= 1'b0;
        end else if (rg_busy) begin
            rx_base[rg_s] <= rg_racc[13:0];
            rx_size[rg_s] <= rg_rlen;
            rx_mask[rg_s] <= rg_rlen[12:0] - 13'd1;  // 8192 - 1 = $1FFF, the low 13 bits wrap to it
            tx_base[rg_s] <= rg_tacc[13:0];
            tx_size[rg_s] <= rg_tlen;
            tx_mask[rg_s] <= rg_tlen[12:0] - 13'd1;
            rg_racc <= rg_rend;
            rg_tacc <= rg_tend;
            rg_n    <= rg_n + 3'd1;
            fs_n    <= rg_s;            // its FSR follows one clock behind
            fs_pend <= 1'b1;
        end else if (fs_kick_sock || cr_write) begin
            fs_n    <= cr_sock;
            fs_pend <= 1'b1;
        end else begin
            fs_pend <= 1'b0;
        end
        if (fs_pend)
            fsr_q[fs_n] <= {2'b00, tx_size[fs_n]} -
                           {3'b000, (tx_wr[fs_n][12:0] - tx_rd[fs_n][12:0]) & tx_mask[fs_n]};
    end

    // ---- the register file -----------------------------------------------------------
    // Four byte lanes of 128 entries, {block, word}: block 0 the common
    // registers, 1-4 the sockets.  A fresh byte reads as its reset value.
    logic [7:0]   rf0 [0:127], rf1 [0:127], rf2 [0:127], rf3 [0:127];
    // ONE fresh bit per WORD, not per byte.  Per byte it was four 128-bit
    // vectors - 512 flip flops, 43% of this card's, each with its own
    // lane-qualified clear - to say a thing the word can say once: a byte
    // lane is never read without the rest of its word being readable, so a
    // program write into a still-fresh word stamps the OTHER three lanes
    // with their reset constants at the same commit (rf_merge below) and the
    // word is whole from then on.  Same reads, same one-clock reset, a
    // quarter of the state.
    logic [127:0] fresh;

    // The reset value of every byte, as a 128-word table built once: a
    // function call in a combinational path is what a simulator's
    // sensitivity gets wrong, a table it cannot.
    function automatic [7:0] rf_reset(input [6:0] idx, input [1:0] lane);
        logic [5:0] off;
        begin
            off = {idx[3:0], lane};
            if (idx[6:4] == 3'd0) begin
                case (off)
                    6'h17: rf_reset = 8'h07;    // RTR0
                    6'h18: rf_reset = 8'hD0;    // RTR1
                    6'h19: rf_reset = 8'h08;    // RCR
                    6'h1A: rf_reset = 8'h55;    // RMSR
                    6'h1B: rf_reset = 8'h55;    // TMSR
                    6'h28: rf_reset = 8'h28;    // PTIMER: the real chip's, no virtual DNS
                    default: rf_reset = 8'h00;
                endcase
            end else begin
                case (off)
                    6'h06, 6'h07, 6'h08, 6'h09, 6'h0A, 6'h0B: rf_reset = 8'hFF;   // DHAR
                    6'h16: rf_reset = 8'h80;    // TTL
                    default: rf_reset = 8'h00;
                endcase
            end
        end
    endfunction
    logic [31:0] rst_tab [0:127];
    initial begin
        for (int t = 0; t < 128; t = t + 1)
            rst_tab[t] = {rf_reset(t[6:0], 2'd3), rf_reset(t[6:0], 2'd2),
                          rf_reset(t[6:0], 2'd1), rf_reset(t[6:0], 2'd0)};
    end


    // ---- ONE read of the register file, time-shared -------------------------
    // Two readers want this file: the program, one byte at the pointer, and
    // the sender, the 24 words a U2_CMD carries.  Built twice it is the
    // whole overlay twice over - the stored word, the reset constants, the
    // four sockets' registers the chip computes rather than stores - for a
    // reader that wants it a few dozen clocks a packet.  So the sender
    // BORROWS the port on the clocks the program is not using it, and waits
    // a clock when it loses.  The program never waits: its read is
    // registered at op_present and its write reads the word at op_commit,
    // and on both of those clocks the port is its own by construction.
    // The sender pays one extra clock a word - 48 a command instead of 24,
    // a couple of microseconds a packet, and never a clock of the core's -
    // and the card carries one of these instead of two.
    typedef enum logic [2:0] {
        X_IDLE,
        X_CMD_HDR,
        X_CMD_DATA,     // take a register word off the shared port
        X_CMD_OFFER,    // ...and offer it: 24 words
        X_TX_HDR,
        X_TX_FETCH,     // port B reads the word
        X_TX_LAND,      // ...which is there now
        X_TX_OFFER
    } xstate_t;
    xstate_t     xs;
    logic [1:0]  x_sock;
    logic [4:0]  x_i;                   // register word 0..23

    // The register word the sender offers: the common block, then the socket's.
    wire [6:0]  x_idx = (x_i < 5'd12) ? {3'd0, x_i[3:0]}
                                      : {{1'b0, x_sock} + 3'd1, x_i[3:0] - 4'd12};
    wire        x_wants = (xs == X_CMD_DATA);
    wire        x_gets  = x_wants && !op_present && !op_commit;
    // ...AND THE WAIT IS BOUNDED, because asking is not enough.  x_gets wants
    // a clock the program is using for neither phase, and a stream can have
    // none: the IIgs sequencer's fast override presents an op on the clock
    // the last one commits (rtl/gs/accel_seq.sv, S_OVR), so present and
    // commit can cover every clock between them for as long as the override
    // run lasts.  A sender that only ever asks then never gets past the
    // header - the U2_CMD never reaches the host, the host never answers,
    // and the driver polls Sn_SR for a status that will never come.  That is
    // a hung machine, and it hung one (2026-09-20).
    //
    // So after 15 clocks of waiting the sender TAKES a clock: x_urgent joins
    // stall_o, the sequencer starts no new op (fast_ok, ovr_ok, turbo_ok and
    // disp_pay all gate on it), the op in flight goes quiet, and the next
    // clock is free.  An ordinary stream serves the sender within three
    // clocks, so five times that is a threshold it never reaches; the worst
    // stream pays 15 clocks a word - bounded, a few microseconds a command,
    // and one held clock is what the floppy's fill does routinely.
    logic [3:0] x_wait;
    wire        x_urgent = &x_wait;
    always_ff @(posedge clk) begin
        if (rst || !x_wants || x_gets) x_wait <= 4'd0;
        else if (!x_urgent)            x_wait <= x_wait + 4'd1;
    end

    wire [6:0]   g_idx   = x_gets ? x_idx : p_idx;
    wire [1:0]   g_n     = g_idx[5:4] - 2'd1;   // block 1..4 -> socket 0..3
    wire [31:0]  g_rst   = rst_tab[g_idx];
    wire         g_fresh = fresh[g_idx];
    wire [31:0]  g_raw   = g_fresh ? g_rst
                                   : {rf3[g_idx], rf2[g_idx], rf1[g_idx], rf0[g_idx]};
    logic [31:0] g_word;
    always_comb begin
        g_word = g_raw;
        if (g_idx[6:4] == 3'd0) begin
            if (g_idx[3:0] == 4'd0) g_word[7:0] = mr;
        end else begin
            case (g_idx[3:0])
                4'd0:  g_word = {sr[g_n], 8'h00, 8'h00, g_raw[7:0]};
                4'd8:  g_word = {tx_rd[g_n][7:0], tx_rd[g_n][15:8], fsr_q[g_n][7:0], fsr_q[g_n][15:8]};
                4'd9:  g_word = {rsr[g_n][7:0], rsr[g_n][15:8], tx_wr[g_n][7:0], tx_wr[g_n][15:8]};
                4'd10: g_word = {g_raw[31:16], rx_rd[g_n][7:0], rx_rd[g_n][15:8]};
                default: ;
            endcase
        end
    end
    wire [7:0]  reg_byte    = g_word[8 * p_lane +: 8];

    // ---- the data port -------------------------------------------------------------------
    wire dp_commit = op_commit && hit_q;
    wire dp_write  = dp_commit && !op_rw;
    wire dp_data   = (op_addr[1:0] == 2'd3);
    wire dp_ai     = dp_data && mr[1];
    // What the pointer becomes at this commit: an address register WRITTEN
    // sets a half, a data-port access steps it; reading the address back
    // moves nothing.
    wire        wr_ah     = dp_write && (op_addr[1:0] == 2'd1);
    wire        wr_al     = dp_write && (op_addr[1:0] == 2'd2);
    wire        ptr_moves = dp_commit && (wr_ah || wr_al || dp_ai);
    wire [15:0] ptr_next  = wr_ah ? {op_wdata, ptr[7:0]} :
                            wr_al ? {ptr[15:8], op_wdata} :
                            dp_ai ? ptr_inc : ptr;
    wire        ptr_next_in_buf = (ptr_next[15:14] == 2'b01);
    wire [11:0] ptr_next_widx   = ptr_next[13:2];
    wire        mr_rst_commit   = dp_write && (op_addr[1:0] == 2'd0) && op_wdata[7];

    // A register write lands in its lane at the commit; the command
    // register is never stored (it reads 0).
    wire        reg_write = dp_write && dp_data && p_reg && !(p_sock && (ptr[5:0] == 6'h01));
    wire        cr_write  = dp_write && dp_data && p_sock && (ptr[5:0] == 6'h01);
    wire [1:0]  cr_sock   = ptr[9:8];

    // ---- the rings -------------------------------------------------------------------------
    wire         a_we    [0:3];
    wire  [11:0] a_addr;
    wire  [7:0]  a_rdata [0:3];
    wire         b_we    [0:3];
    wire  [11:0] b_addr  [0:3];
    wire  [7:0]  b_wdata [0:3];
    wire  [7:0]  b_rdata [0:3];
    genvar gk;
    generate
        for (gk = 0; gk < 4; gk = gk + 1) begin : g_lane
            fd_bank #(.DEPTH (4096), .AW (12)) u_lane (
                .clk     (clk),
                .a_we    (a_we[gk]),
                .a_addr  (a_addr),
                .a_wdata (op_wdata),
                .a_rdata (a_rdata[gk]),
                .b_we    (b_we[gk]),
                .b_addr  (b_addr[gk]),
                .b_wdata (b_wdata[gk]),
                .b_rdata (b_rdata[gk])
            );
        end
    endgenerate

    // Port A: the program's write at its commit, else one read a clock for
    // the held words.  A read lands the clock after it is issued.
    logic [31:0] cur_w, nxt_w;
    logic        cur_v, nxt_v;
    logic [11:0] cur_a, nxt_a;
    logic        a_rd_q, a_rd_cur_q;
    logic [11:0] a_rd_addr_q;
    logic        stall_q;

    wire buf_write = dp_write && dp_data && p_buf;
    // The word after this commit's pointer is held already: take it.
    wire shift_ok  = nxt_v && (nxt_a == ptr_next_widx);
    // Fetch on the commit clock for a pointer that lands in the rings and
    // whose word is not held (a write to the pointer, or a step across).
    wire fetch_now = ptr_moves && ptr_next_in_buf && !buf_write &&
                     !(cur_v && (cur_a == ptr_next_widx)) && !shift_ok;
    // Otherwise, from registered state: the current word if missing, else
    // the next.  One read in flight at a time.
    wire need_cur  = p_buf && !cur_v;
    wire need_nxt  = p_buf && cur_v && !(nxt_v && (nxt_a == p_widx_next));
    wire fetch_reg = !buf_write && !fetch_now && !a_rd_q && (need_cur || need_nxt);
    wire a_rd      = fetch_now || fetch_reg;
    wire a_rd_cur  = fetch_now || need_cur;
    wire [11:0] a_rd_addr = fetch_now ? ptr_next_widx : need_cur ? p_widx : p_widx_next;

    assign a_addr = buf_write ? p_widx : a_rd_addr;
    genvar gw;
    generate
        for (gw = 0; gw < 4; gw = gw + 1) begin : g_awe
            assign a_we[gw] = buf_write && (p_lane == gw[1:0]);
        end
    endgenerate
    wire [31:0] a_word = {a_rdata[3], a_rdata[2], a_rdata[1], a_rdata[0]};

    // Port B: the host's append this clock, else the sender's read.
    logic        rxw;                   // a U2_RX word lands this clock
    logic [11:0] rxw_addr [0:3];
    logic        rxw_we   [0:3];
    logic [7:0]  rxw_data [0:3];
    logic [11:0] xrd_addr [0:3];
    generate
        for (gw = 0; gw < 4; gw = gw + 1) begin : g_b
            assign b_we[gw]    = rxw && rxw_we[gw];
            assign b_addr[gw]  = rxw ? rxw_addr[gw] : xrd_addr[gw];
            assign b_wdata[gw] = rxw_data[gw];
        end
    endgenerate
    // A host write into a held word, or into one landing this clock.
    function automatic hits_word(input [11:0] w);
        integer l;
        begin
            hits_word = 1'b0;
            for (l = 0; l < 4; l = l + 1)
                if (rxw && rxw_we[l] && (rxw_addr[l] == w)) hits_word = 1'b1;
        end
    endfunction

    // The byte at the pointer, for a read presented now.
    wire        land_cur_now = a_rd_q && a_rd_cur_q && (a_rd_addr_q == p_widx);
    wire [31:0] cur_now      = land_cur_now ? a_word : cur_w;
    wire [7:0]  buf_byte     = cur_now[8 * p_lane +: 8];
    wire [7:0]  data_rd      = p_reg ? reg_byte : p_buf ? buf_byte : 8'h00;
    wire [7:0]  port_rd      = (op_addr[1:0] == 2'd0) ? mr :
                               (op_addr[1:0] == 2'd1) ? ptr[15:8] :
                               (op_addr[1:0] == 2'd2) ? ptr[7:0] : data_rd;

    assign stall_o = enabled && ((p_buf && !cur_v && !land_cur_now) || rg_busy || x_urgent);

    // ---- the command queue -------------------------------------------------------------------
    // {sock, cmd, tx offset, tx length}: what a U2_CMD needs that the live
    // registers will not hold by the time it goes out.
    localparam integer QW = 2 + 8 + 13 + 14;
    logic [QW-1:0] q_mem [0:7];
    logic [3:0]    q_wp, q_rp;
    wire           q_empty = (q_wp == q_rp);
    wire           q_full  = (q_wp[2:0] == q_rp[2:0]) && (q_wp[3] != q_rp[3]);
    logic          q_push;
    logic [QW-1:0] q_in;
    logic          q_pop;
    logic          dropped;

    // ---- U2_RX and U2_STAT in progress --------------------------------------------------------
    logic        rx_act;
    logic [1:0]  rx_sock;
    logic [11:0] rx_bytes, rx_done;
    logic [12:0] rx_pos;
    logic [7:0]  rx_left;
    logic [7:0]  rx_chunks;
    logic        st_act;
    logic [1:0]  st_sock;
    logic [7:0]  st_left;
    // A U2_STAT payload word waits here for the register file's write port.
    logic        pw_valid [0:1];
    logic [6:0]  pw_idx   [0:1];
    logic [31:0] pw_word  [0:1];

    wire hdr_rx   = msg_valid && (msg_type == T_U2_RX)   && enabled;
    wire hdr_stat = msg_valid && (msg_type == T_U2_STAT) && enabled;
    wire word_rx  = pay_valid && rx_act;
    wire word_st  = pay_valid && st_act;
    wire [11:0] rx_remaining = rx_bytes - rx_done;
    always_comb begin
        rxw = word_rx;
        for (int l = 0; l < 4; l = l + 1) begin : rxlane
            logic [1:0]  k;
            logic [12:0] off;
            logic [13:0] idx;
            k   = l[1:0] - rx_pos[1:0];
            off = (rx_pos + {11'd0, k}) & rx_mask[rx_sock];
            idx = 14'h2000 + rx_base[rx_sock] + {1'b0, off};
            rxw_addr[l] = idx[13:2];
            rxw_we[l]   = ({10'd0, k} < rx_remaining);
            rxw_data[l] = pay_data[8 * k +: 8];
        end
    end

    // The register file's write port: the program's write first, else a
    // waiting U2_STAT word.
    wire        pw_drain = !reg_write && !soft_hold && pw_valid[0];
    wire        rf_we    = reg_write || pw_drain;
    wire [6:0]  rf_widx  = reg_write ? p_idx : pw_idx[0];
    // A write into a word still carrying its reset constants writes the
    // whole word: the addressed lane takes the program's byte, the other
    // three the constants they were reading anyway (p_rst, a read of the
    // sparse reset table, never of the file - no RAM-to-RAM path).
    wire [31:0] rf_merge = {(p_lane == 2'd3) ? op_wdata : g_rst[31:24],
                            (p_lane == 2'd2) ? op_wdata : g_rst[23:16],
                            (p_lane == 2'd1) ? op_wdata : g_rst[15:8],
                            (p_lane == 2'd0) ? op_wdata : g_rst[7:0]};
    wire [31:0] rf_wword = reg_write ? (g_fresh ? rf_merge : {4{op_wdata}}) : pw_word[0];
    wire [3:0]  rf_wlane = (reg_write && !g_fresh) ? (4'b0001 << p_lane) : 4'b1111;

    always_ff @(posedge clk) begin
        if (rf_we && rf_wlane[0]) rf0[rf_widx] <= rf_wword[7:0];
        if (rf_we && rf_wlane[1]) rf1[rf_widx] <= rf_wword[15:8];
        if (rf_we && rf_wlane[2]) rf2[rf_widx] <= rf_wword[23:16];
        if (rf_we && rf_wlane[3]) rf3[rf_widx] <= rf_wword[31:24];
    end

    // ---- the chip, clock by clock -----------------------------------------------------------
    wire chip_reset = rst || soft_hold || mr_rst_commit;
    // The regions are laid down again whenever the registers that size them
    // move: a reset restores $55/$55, a program write sets what it likes.
    wire rg_kick    = chip_reset || (reg_write && p_common &&
                                     ((ptr[5:0] == 6'h1A) || (ptr[5:0] == 6'h1B)));
    integer n;
    always_ff @(posedge clk) begin
        // ---- the register file's freshness, the shadows, the pointer ----
        if (chip_reset) begin
            fresh <= {128{1'b1}};
            mr   <= 8'd0;
            rmsr <= 8'h55; tmsr <= 8'h55;
            for (n = 0; n < 4; n = n + 1) begin
                sr[n] <= SR_CLOSED; tx_rd[n] <= 16'd0; tx_wr[n] <= 16'd0;
                rx_rd[n] <= 16'd0; rx_wr[n] <= 13'd0; rsr[n] <= 16'd0;
            end
            dropped <= 1'b0;
        end else begin
            if (rf_we) fresh[rf_widx] <= 1'b0;
            if (dp_write && (op_addr[1:0] == 2'd0)) mr <= {1'b0, op_wdata[6:0]};
            if (reg_write && p_common) begin
                if (ptr[5:0] == 6'h1A) rmsr <= op_wdata;
                if (ptr[5:0] == 6'h1B) tmsr <= op_wdata;
            end
            if (reg_write && p_sock) begin
                case (ptr[5:0])
                    6'h24: tx_wr[cr_sock][15:8] <= op_wdata;
                    6'h25: tx_wr[cr_sock][7:0]  <= op_wdata;
                    6'h28: rx_rd[cr_sock][15:8] <= op_wdata;
                    6'h29: rx_rd[cr_sock][7:0]  <= op_wdata;
                    default: ;
                endcase
            end
            // The command register (AppleWin's setCommandRegister).
            if (cr_write) begin
                case (op_wdata)
                    CR_OPEN: begin
                        // The protocol from Sn_MR, byte 0 of the same word.
                        case (g_raw[3:0])
                            MR_MACRAW: sr[cr_sock] <= SR_MACRAW;
                            MR_IPRAW:  sr[cr_sock] <= SR_IPRAW;
                            MR_UDP:    sr[cr_sock] <= SR_UDP;
                            MR_TCP:    sr[cr_sock] <= SR_INIT;
                            default:   sr[cr_sock] <= SR_CLOSED;   // a virtual-DNS mode, or none
                        endcase
                        tx_rd[cr_sock] <= 16'd0; tx_wr[cr_sock] <= 16'd0;
                        rx_rd[cr_sock] <= 16'd0; rx_wr[cr_sock] <= 13'd0; rsr[cr_sock] <= 16'd0;
                    end
                    CR_CONNECT: if (sr[cr_sock] == SR_INIT) sr[cr_sock] <= SR_SYNSENT;
                    CR_LISTEN:  if (sr[cr_sock] == SR_INIT) sr[cr_sock] <= SR_LISTEN;
                    CR_DISCON, CR_CLOSE: sr[cr_sock] <= SR_CLOSED;
                    CR_SEND:    tx_rd[cr_sock] <= {3'b000, tx_wr[cr_sock][12:0] & tx_mask[cr_sock]};
                    CR_RECV:    rsr[cr_sock] <= {3'b000, (rx_wr[cr_sock] - rx_rd[cr_sock][12:0]) & rx_mask[cr_sock]};
                    default: ;
                endcase
            end
            // A U2_RX chunk's last word: the pointer and the size move.
            if (word_rx && (rx_left == 8'd1)) begin
                rx_wr[rx_sock] <= (rx_wr[rx_sock] + rx_bytes[11:0]) & rx_mask[rx_sock];
                rsr[rx_sock]   <= rsr[rx_sock] + {4'd0, rx_bytes};
            end
            // A U2_STAT: the status, at once.
            if (hdr_stat) sr[msg_free[1:0]] <= msg_free[15:8];
            if (q_push && q_full) dropped <= 1'b1;
        end

        // The pointer: the card's reset alone clears it.
        if (rst)            ptr <= 16'd0;
        else if (ptr_moves) ptr <= ptr_next;

        // ---- the held ring words ----
        if (rst) begin
            cur_v <= 1'b0; nxt_v <= 1'b0; cur_a <= 12'd0; nxt_a <= 12'd0;
            cur_w <= 32'd0; nxt_w <= 32'd0;
            a_rd_q <= 1'b0; a_rd_cur_q <= 1'b0; a_rd_addr_q <= 12'd0;
        end else begin
            a_rd_q      <= a_rd;
            a_rd_cur_q  <= a_rd_cur;
            a_rd_addr_q <= a_rd_addr;
            // A read lands.
            if (a_rd_q) begin
                if (a_rd_cur_q) begin cur_w <= a_word; cur_a <= a_rd_addr_q; cur_v <= 1'b1; end
                else            begin nxt_w <= a_word; nxt_a <= a_rd_addr_q; nxt_v <= 1'b1; end
            end
            // The program's write patches a held copy (after a landing, so
            // the fresh byte wins).
            if (buf_write) begin
                if (cur_v && (cur_a == p_widx)) cur_w[8 * p_lane +: 8] <= op_wdata;
                if (a_rd_q && a_rd_cur_q && (a_rd_addr_q == p_widx)) cur_w[8 * p_lane +: 8] <= op_wdata;
                if (nxt_v && (nxt_a == p_widx)) nxt_w[8 * p_lane +: 8] <= op_wdata;
                if (a_rd_q && !a_rd_cur_q && (a_rd_addr_q == p_widx)) nxt_w[8 * p_lane +: 8] <= op_wdata;
            end
            // The pointer moves: the held words follow it.
            if (ptr_moves) begin
                if (ptr_next_in_buf) begin
                    if (cur_v && (cur_a == ptr_next_widx)) begin
                        // still the word under the pointer
                    end else if (shift_ok) begin
                        cur_w <= nxt_w; cur_a <= nxt_a; cur_v <= 1'b1;
                        nxt_v <= 1'b0;
                    end else if (a_rd_q && a_rd_cur_q && (a_rd_addr_q == ptr_next_widx)) begin
                        // landing this clock, into cur above
                    end else begin
                        cur_v <= 1'b0;
                        nxt_v <= 1'b0;
                    end
                end
            end
            // A host write into a held word - or one landing - invalidates it.
            if (hits_word(cur_a) && cur_v) cur_v <= 1'b0;
            if (hits_word(nxt_a) && nxt_v) nxt_v <= 1'b0;
            if (a_rd_q && hits_word(a_rd_addr_q)) begin
                if (a_rd_cur_q) cur_v <= 1'b0; else nxt_v <= 1'b0;
            end
        end

        // ---- the messages in ----
        if (rst || soft_hold) begin
            rx_act <= 1'b0; rx_sock <= 2'd0; rx_bytes <= 12'd0; rx_done <= 12'd0;
            rx_pos <= 13'd0; rx_left <= 8'd0;
            st_act <= 1'b0; st_sock <= 2'd0; st_left <= 8'd0;
            pw_valid[0] <= 1'b0; pw_valid[1] <= 1'b0;
            pw_idx[0] <= 7'd0; pw_idx[1] <= 7'd0; pw_word[0] <= 32'd0; pw_word[1] <= 32'd0;
            if (rst) rx_chunks <= 8'd0;
        end else begin
            if (msg_valid) begin
                // Any header ends what was in progress (a short message).
                rx_act <= 1'b0;
                st_act <= 1'b0;
                if (hdr_rx && (msg_len != 8'd0)) begin
                    rx_act   <= 1'b1;
                    rx_sock  <= msg_free[1:0];
                    rx_bytes <= msg_free[15:4];
                    rx_done  <= 12'd0;
                    rx_pos   <= rx_wr[msg_free[1:0]];
                    rx_left  <= msg_len;
                end
                if (hdr_stat && (msg_len == 8'd2)) begin
                    st_act  <= 1'b1;
                    st_sock <= msg_free[1:0];
                    st_left <= 8'd2;
                end
            end else if (word_rx) begin
                rx_done <= rx_done + 12'd4;
                rx_pos  <= (rx_pos + 13'd4) & rx_mask[rx_sock];
                rx_left <= rx_left - 8'd1;
                if (rx_left == 8'd1) begin
                    rx_act    <= 1'b0;
                    rx_chunks <= rx_chunks + 8'd1;
                end
            end else if (word_st) begin
                st_left <= st_left - 8'd1;
                if (st_left == 8'd1) st_act <= 1'b0;
            end
            // The U2_STAT words: DIPR is the socket's word 3, DPORT/MSSR
            // its word 4.  Two slots, drained when the port is free.
            if (pw_drain) begin
                pw_valid[0] <= pw_valid[1];
                pw_idx[0]   <= pw_idx[1];
                pw_word[0]  <= pw_word[1];
                pw_valid[1] <= 1'b0;
            end
            if (word_st) begin
                if (!pw_valid[0] || (pw_drain && !pw_valid[1])) begin
                    pw_valid[0] <= 1'b1;
                    pw_idx[0]   <= {{1'b0, st_sock} + 3'd1, (st_left == 8'd2) ? 4'd3 : 4'd4};
                    pw_word[0]  <= pay_data;
                end else if (!pw_valid[1] || pw_drain) begin
                    pw_valid[1] <= 1'b1;
                    pw_idx[1]   <= {{1'b0, st_sock} + 3'd1, (st_left == 8'd2) ? 4'd3 : 4'd4};
                    pw_word[1]  <= pay_data;
                end
            end
        end
    end

    // ---- the command queue's push ----
    always_comb begin
        q_push = 1'b0;
        q_in   = {QW{1'b0}};
        if (res_assert || mr_rst_commit) begin
            q_push = enabled;
            q_in   = {2'd0, 8'h00, 13'd0, 14'd0};
        end else if (cr_write && enabled) begin
            case (op_wdata)
                CR_OPEN, CR_LISTEN, CR_CONNECT, CR_DISCON, CR_CLOSE, CR_RECV: begin
                    q_push = 1'b1;
                    q_in   = {cr_sock, op_wdata, 13'd0, 14'd0};
                end
                CR_SEND: begin
                    q_push = 1'b1;
                    q_in   = {cr_sock, op_wdata, tx_rd[cr_sock][12:0] & tx_mask[cr_sock],
                              {1'b0, (tx_wr[cr_sock][12:0] - tx_rd[cr_sock][12:0]) & tx_mask[cr_sock]}};
                end
                default: ;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            q_wp <= 4'd0; q_rp <= 4'd0;
        end else begin
            if (q_push && !q_full) begin
                q_mem[q_wp[2:0]] <= q_in;
                q_wp <= q_wp + 4'd1;
            end
            if (q_pop) q_rp <= q_rp + 4'd1;
        end
    end
    wire [QW-1:0] q_out = q_mem[q_rp[2:0]];

    // ---- card -> host: U2_CMD and U2_TX ------------------------------------------------------
    logic [7:0]  x_cmd;
    logic [12:0] x_pos;                 // the next byte's offset in the TX region
    logic [13:0] x_left;                // bytes still to send
    logic [7:0]  x_wleft;               // words left this chunk
    logic [11:0] x_cbytes;              // this chunk's bytes
    logic        x_first;
    logic [31:0] x_data;
    logic [7:0]  cmds;

    // Port B's read of the word at x_pos: byte k of the word is lane
    // (x_pos + k) & 3 at that byte's own address.
    logic [1:0]  x_lane_q;              // x_pos[1:0] of the read in flight
    always_comb begin
        for (int l = 0; l < 4; l = l + 1) begin : xlane
            logic [1:0]  k;
            logic [12:0] off;
            logic [13:0] idx;
            k   = l[1:0] - x_pos[1:0];
            off = (x_pos + {11'd0, k}) & tx_mask[x_sock];
            idx = tx_base[x_sock] + {1'b0, off};
            xrd_addr[l] = idx[13:2];
        end
    end
    wire [1:0]  xl0 = x_lane_q, xl1 = x_lane_q + 2'd1, xl2 = x_lane_q + 2'd2, xl3 = x_lane_q + 2'd3;
    wire [31:0] x_assembled = {b_rdata[xl3], b_rdata[xl2], b_rdata[xl1], b_rdata[xl0]};

    wire        x_last     = (x_left <= CHUNK_BYTES);
    wire [11:0] x_cb_next  = x_last ? x_left[11:0] : CHUNK_BYTES[11:0];
    wire [11:0] x_cw12     = (x_cb_next + 12'd3) >> 2;
    wire [7:0]  x_cw_next  = x_cw12[7:0];

    assign tx_valid = (xs == X_CMD_HDR) || (xs == X_CMD_OFFER) ||
                      (xs == X_TX_HDR)  || (xs == X_TX_OFFER);
    assign tx_word  = (xs == X_CMD_HDR)  ? {x_cmd, 6'd0, x_sock, T_U2_CMD, 8'd24} :
                      (xs == X_TX_HDR)   ? {x_cbytes, x_last, x_first, x_sock, T_U2_TX, x_wleft} :
                                           x_data;
    assign q_pop = (xs == X_IDLE) && !q_empty;

    always_ff @(posedge clk) begin
        if (rst) begin
            xs <= X_IDLE;
            x_sock <= 2'd0; x_cmd <= 8'd0; x_pos <= 13'd0; x_left <= 14'd0;
            x_i <= 5'd0; x_wleft <= 8'd0; x_cbytes <= 12'd0; x_first <= 1'b0;
            x_data <= 32'd0; x_lane_q <= 2'd0;
            cmds <= 8'd0;
        end else begin
            case (xs)
                X_IDLE: if (!q_empty) begin
                    x_sock <= q_out[QW-1 -: 2];
                    x_cmd  <= q_out[QW-3 -: 8];
                    x_pos  <= q_out[QW-11 -: 13];
                    x_left <= q_out[13:0];
                    x_i    <= 5'd0;
                    x_first <= 1'b1;
                    xs     <= X_CMD_HDR;
                end
                X_CMD_HDR: if (tx_take) begin
                    cmds <= cmds + 8'd1;
                    xs   <= X_CMD_DATA;
                end
                // The shared port, when the program is not using it.
                X_CMD_DATA: if (x_gets) begin
                    x_data <= g_word;
                    xs     <= X_CMD_OFFER;
                end
                X_CMD_OFFER: if (tx_take) begin
                    x_i <= x_i + 5'd1;
                    if (x_i == 5'd23) begin
                        if ((x_cmd == CR_SEND) && (x_left != 14'd0)) begin
                            x_cbytes <= x_cb_next;
                            x_wleft  <= x_cw_next;
                            xs       <= X_TX_HDR;
                        end else xs <= X_IDLE;
                    end else xs <= X_CMD_DATA;   // back for the next word
                end
                X_TX_HDR: if (tx_take) begin
                    x_left <= x_left - {2'd0, x_cbytes};
                    xs     <= X_TX_FETCH;
                end
                X_TX_FETCH: if (!rxw) begin
                    x_lane_q <= x_pos[1:0];
                    xs       <= X_TX_LAND;
                end
                X_TX_LAND: begin
                    x_data <= x_assembled;
                    xs     <= X_TX_OFFER;
                end
                X_TX_OFFER: if (tx_take) begin
                    x_pos   <= (x_pos + 13'd4) & tx_mask[x_sock];
                    x_wleft <= x_wleft - 8'd1;
                    if (x_wleft == 8'd1) begin
                        x_first <= 1'b0;
                        if (x_left == 14'd0) xs <= X_IDLE;
                        else begin
                            x_cbytes <= x_cb_next;
                            x_wleft  <= x_cw_next;
                            xs       <= X_TX_HDR;
                        end
                    end else xs <= X_TX_FETCH;
                end
                default: xs <= X_IDLE;
            endcase
        end
    end

    // ---- claim and read data ------------------------------------------------------------------
    // Registered on op_present: one stable answer per bus cycle, decided in
    // the address phase.  The register byte is combinational off the
    // pointer; the ring byte is the held word's, or the one landing now.
    //
    // THE HIT IS CONSUMED BY THE OP'S OWN COMMIT.  In the closed regime a
    // driver dummy presented inside a slot op's window is hidden from the
    // view, but its commit lands after the window, with the dummy's address
    // - $C063, $C067, the game port's probes - and a read of a data-port-
    // shaped address on a hit still standing would step the pointer.  On
    // hardware that put every sixth SHAR byte one place too far.  One op,
    // one commit: the hit falls with it.
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_claim <= 1'b0;
            rd_data  <= 8'd0;
            hit_q    <= 1'b0;
        end else begin
            if (dp_commit) hit_q <= 1'b0;
            if (op_present) begin
                hit_q    <= hit_dev;
                rd_claim <= hit_dev && op_rw;
                rd_data  <= port_rd;
            end else if (!enabled) begin
                rd_claim <= 1'b0;
                hit_q    <= 1'b0;
            end
        end
    end

    // ---- readback ----
    assign sock_open   = {sr[3] != 8'd0, sr[2] != 8'd0, sr[1] != 8'd0, sr[0] != 8'd0};
    assign cmd_dropped = dropped;
    assign cmds_o      = cmds;
    assign rx_chunks_o = rx_chunks;
    assign s0_rsr_o    = rsr[0];
    assign s0_fsr_o    = fsr_q[0];

endmodule
