`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// floppy_card - a Disk II controller's slot and its two drives, on the card
// that IS the CPU, with the disk images on the host.
//
// The controller is AppleWin's (source/Disk.cpp, the non-WOZ path), the
// project's reference: the P5A boot ROM at $Cn00, sixteen soft switches at
// $C0n0-$C0nF that a 74LS259 latches, and a data register the software polls
// for nibbles.  This module carries everything the BUS can see and the whole
// of the timing; the host keeps the images and does the nibblizing.  See
// docs/FLOPPY.md.
//
// WHAT THE CARD CLAIMS, all reads:
//
//   $Cn00-$CnFF   the boot ROM, 256 bytes the HOST loads (FD_ROM).  Gated by
//                 rtl/slot_switches.sv, as the hard disk's is.
//   $C0n0-$C0nF   EVEN addresses: the data register.  Odd ones are not
//                 claimed and read the floating bus, as UTAIIe table 9.1 has
//                 it.  Every access, read or write, even or odd, works the
//                 switch its address names.
//
// (n = slot + 8 for the $C0nx page.)
//
// THE SWITCHES.  $C0n0-7 are the four stepper phases, off/on by A0; $C0n8/9
// the motor; $C0nA/B the drive; $C0nC/D Q6 (shift/load); $C0nE/F Q7
// (read/write).  The phases are the card's - they only reach the drive that
// is selected - and a head moves toward an energised adjacent magnet, never
// when both adjacent magnets are on, ten cycles after the write (AppleWin's
// deferral, GH#1110), and only while the drive is enabled or still coasting.
// Two phases to a track; 80 phases; the track is phase >> 1.  Motor off
// starts a one-second coast (SPINNING_CYCLES) during which the disk still
// reads and the head still steps; deselecting a drive coasts it the same
// way, as the drive's own enable line would.
//
// THE DATA REGISTER, in read mode.  A nibble is 32 bus cycles - eight 4 us
// bit cells - and the register presents it, high bit set, for the seven
// cycles after the last bit lands; after that it shows the next nibble
// shifting in, high bit clear (UTAIIe 9-15; AppleWin's LSS path,
// Disk.cpp DataLatchReadWOZ, m_latchDelay = 7).  That window is why the
// RWTS's seven-cycle `LDA $C0EC,X / BPL` loop reads every nibble exactly
// once, and it is counted here in bus cycles, so it is exact whatever the
// core is doing.  The stream is free-running: the platter turns whether or
// not anyone reads, at the drive's own count of nibbles per revolution.
// $C0nD samples write-protect into the register as $FF or $00, and the
// $C0nE read that follows delivers it in bit 7.  A stopped drive holds the
// register.  A drive with no disk - or no track yet, below - answers $80
// for the first 0x2EC cycles after it starts and noise after that
// (AppleWin's GH#864/GH#748).
//
// THE DATA REGISTER, in write mode.  A store with Q6 and Q7 both set loads
// it (any address in the page: the 74LS323's LD); the $C0nC access that
// follows shifts it out, and that is when the byte lands in the track, at
// the slot under the head.  A 10-bit self-sync $FF takes 40 cycles and so
// skips a slot; the skipped slot is filled with $FF, which is what the
// extra zero bits were, so a track INIT writes at the machine's own pace
// stays contiguous and needs no fixing up afterwards.  A write-protected
// disk, or a stopped drive, takes nothing.
//
// THE TRACK IS ON THE CARD; THE DISK IS ON THE HOST.  Each drive has one
// track of buffer (6656 bytes, the largest any image format makes, in
// BRAM).  A head movement, a disk inserted, or a switch to a drive holding
// another track marks the buffer STALE and sends the host an FD_SEEK
// {drive, track, seq}; the host answers with seven FD_TRACK chunks that
// are written straight into the buffer as they arrive, and the seventh
// clears STALE.  While a buffer is stale the register serves noise, never
// the old track - so a late host makes the RWTS keep looking for an
// address field, which it retries, rather than find one with the wrong
// track number in it, which it treats as a seek error.  `seq` is bumped
// per seek and a chunk with the wrong one is dropped: a late answer to a
// superseded seek changes nothing.  A buffer that was written to is DIRTY,
// and before its track is left - or when the drive spins down, is ejected,
// or the host asks - it goes back to the host as seven FD_DIRTY chunks,
// before the FD_SEEK for the new track, so the host has the whole track
// before it could be asked for it again.
//
// THE CARD MEASURES ITS OWN LATENESS.  `fill_max` is the longest a fill has
// taken, from the head movement to the seventh chunk, in bus cycles;
// `late` counts the fills that completed after the machine had already
// tried to read the track.  The budget is the RWTS's own settle delay -
// milliseconds - and these two numbers are how the host finds out whether
// it is keeping inside it.  See docs/FLOPPY.md.
//
// WHAT THIS CARD NEVER DOES: take a bus cycle.  No override, no stall.  A
// real floppy's loops are counted to the cycle, and a card that stole one
// to fetch a track would break the very timing the track is read with.
// Everything the host is involved in happens beside the read stream, not
// in it.
//
// RESET.  The card's reset clears everything.  The core's (RES') clears the
// controller's latches - the phases, the motor, the drive select, Q6 and
// Q7 - as it does the 74LS259's; the drives, their heads, their buffers
// and what the host has been told survive it, as a drive's would.
//////////////////////////////////////////////////////////////////////////////////
module floppy_card #(
    parameter [7:0] T_FD_ROM   = 8'h1E,
    parameter [7:0] T_FD_TRACK = 8'h1F,
    parameter [7:0] T_FD_SEEK  = 8'h20,
    parameter [7:0] T_FD_DIRTY = 8'h21,
    // Bus cycles a drive keeps turning after its enable drops: motor off,
    // or deselected.  AppleWin's SPINNING_CYCLES, ~1 s.  A tb shortens it.
    parameter integer SPIN_TICKS = 1_000_000,
    // Bus cycles after a drive starts before the LSS settles: an empty drive
    // reads $80 until then, noise after.  AppleWin's 0x2EC.
    parameter integer STABLE_TICKS = 748
) (
    input  wire        clk,
    // The CARD's reset: everything.
    input  wire        rst,
    // The CORE's reset (card reset OR RES' asserted): the 74LS259.
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

    // Card -> host: FD_SEEK and FD_DIRTY, a word at a time through msg_arb.
    output wire [31:0] tx_word,
    output wire        tx_valid,
    input  wire        tx_take,

    // FD_DRIVE1 / FD_DRIVE2, live: what is in each drive.  [12:0] and [5:0]
    // of the packed fields are drive 1's.  flush is a pulse per drive.
    input  wire [1:0]  drv_inserted,
    input  wire [1:0]  drv_wp,
    input  wire [25:0] drv_nibbles,
    input  wire [11:0] drv_tracks,
    input  wire [1:0]  drv_flush,
    // FD_STAT's W1 bits: clear the two measurements.
    input  wire        late_clr,
    input  wire        fill_clr,

    // For the registers' readback.
    output wire        rom_loaded,
    output wire [1:0]  stale_o,
    output wire [1:0]  dirty_o,
    output wire [13:0] phase_o,         // [6:0] drive 1, [13:7] drive 2
    output wire        motor_o,
    output wire        drive_sel_o,
    output wire        q6_o,
    output wire        q7_o,
    output logic [7:0] seeks,
    output logic [7:0] late,
    output logic [15:0] fill_max
);

    // ---- geometry ------------------------------------------------------------
    localparam integer TRACK_BYTES = 6656;           // 0x1A00, a .nib track
    localparam integer TRACK_WORDS = TRACK_BYTES / 4; // 1664
    localparam integer CHUNK_WORDS = 252;            // per FD_TRACK / FD_DIRTY
    localparam integer LAST_CHUNK_WORDS = TRACK_WORDS - 6 * CHUNK_WORDS;   // 152
    localparam integer HOLD_TICKS  = 7;              // the register holds a nibble
    localparam integer STEP_TICKS  = 10;             // magnet write -> cog moves
    localparam integer FILL_MAX_GAP = 16;            // slots a sync run may skip

    // ---- what this card answers as -------------------------------------------
    wire enabled = master_active && (slot_assign != 3'd0) && rom_loaded;

    wire io_select;
    slot_switches u_sw (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .slot (slot_assign),
        .io_select (io_select)
    );

    // ---- the boot ROM ----------------------------------------------------------
    // 32 bits wide, written a word at a time from FD_ROM, read a byte at a
    // time by address; one port each way, which is what lets it be a LUT RAM.
    logic [31:0] rom [0:63];
    logic        rom_ok;
    assign rom_loaded = rom_ok;

    wire [31:0] rom_word = rom[op_addr[7:2]];
    wire [7:0]  rom_byte = rom_word[8 * op_addr[1:0] +: 8];

    // ---- decode ------------------------------------------------------------------
    wire       hit_page = enabled && !op_ovr &&
                          (op_addr[15:4] == {8'hC0, 1'b1, slot_assign});
    wire [3:0] idx      = op_addr[3:0];
    wire       hit_rom  = enabled && !op_ovr && op_rw && io_select &&
                          (op_addr[15:8] == {4'hC, 1'b0, slot_assign});

    // The machine's clock: one tick per bus cycle, override cycles included -
    // the platter turns during a DMA too.
    wire tick = op_commit && enabled;
    wire page_commit = op_commit && hit_page;

    // ---- the controller's latches ---------------------------------------------
    // The 74LS259: cleared by RES'.
    logic [3:0] magnets;
    logic       motor;
    logic       drive_sel;
    logic       q6, q7;
    logic [7:0] latch;
    logic [2:0] hold;                   // ticks the register still holds a nibble
    logic [3:0] step_timer;             // ticks until a phase write moves the cog

    assign motor_o     = motor;
    assign drive_sel_o = drive_sel;
    assign q6_o        = q6;
    assign q7_o        = q7;

    // The switch state this access leaves behind, for the load rule: a store
    // with Q6 and Q7 set loads the register, and $C0nD or $C0nF may be the
    // access that sets one of them.
    wire q6_after = (idx[3:1] == 3'd6) ? idx[0] : q6;
    wire q7_after = (idx[3:1] == 3'd7) ? idx[0] : q7;

    // ---- the drives ----------------------------------------------------------------
    // Everything per drive, indexed by drive number; the selected one is `s`.
    wire s = drive_sel;

    logic [6:0]  phase     [0:1];       // 0..79, two per track
    logic [19:0] spin      [0:1];       // ticks of coast left; 0 = stopped
    logic [9:0]  stable    [0:1];       // ticks since the drive started, saturating
    logic [12:0] pos       [0:1];       // the slot under the head
    logic [4:0]  bit_ctr   [0:1];       // ticks into that slot's 32
    logic        stale     [0:1];       // the buffer is not this track yet
    logic        dirty     [0:1];       // the buffer was written to
    logic [7:0]  seq       [0:1];       // the seek the host is answering
    logic [5:0]  buf_track [0:1];       // the track the buffer is for
    logic [6:0]  chunks    [0:1];       // FD_TRACK chunks landed for `seq`
    logic [15:0] fill_ticks[0:1];       // ticks since the head moved, while stale
    logic        read_stale[0:1];       // the machine read while stale
    logic        seek_owed [0:1];       // an FD_SEEK is to be sent
    logic        up_owed   [0:1];       // an FD_DIRTY upload is to be sent
    logic [5:0]  up_track  [0:1];       // ...for this track
    logic [7:0]  up_seq    [0:1];       // ...as filled by this seek
    logic        ins_prev  [0:1];       // for the insert / eject edges

    wire [12:0] nibbles [0:1];
    wire [5:0]  tracks  [0:1];
    assign nibbles[0] = drv_nibbles[12:0];
    assign nibbles[1] = drv_nibbles[25:13];
    assign tracks[0]  = drv_tracks[5:0];
    assign tracks[1]  = drv_tracks[11:6];

    assign phase_o = {phase[1], phase[0]};
    assign stale_o = {stale[1], stale[0]};
    assign dirty_o = {dirty[1], dirty[0]};

    // The selected drive is turning: enabled by the motor, or coasting.
    wire spinning = (spin[s] != 20'd0);
    // Its buffer holds the track under its head.
    wire usable   = drv_inserted[s] && !stale[s];
    // A fill is expected: the host owes this drive a track.
    wire filling0 = stale[0] && drv_inserted[0] && (buf_track[0] < tracks[0]);
    wire filling1 = stale[1] && drv_inserted[1] && (buf_track[1] < tracks[1]);

    // Noise for an empty drive: a 16-bit LFSR stepped per tick.
    logic [15:0] lfsr;
    wire         lfsr_fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    // ---- the track buffers ----------------------------------------------------------
    // Four byte lanes per drive (rtl/fd_bank.sv): byte i in bank i[1:0] at
    // index i[12:2].  Port A is the bus side, a byte at a time; port B the
    // link side, a word at a time.
    wire         a_we    [0:7];
    wire  [10:0] a_addr  [0:1];
    wire  [7:0]  a_wdata;
    wire  [7:0]  a_rdata [0:7];
    wire         b_we    [0:1];
    wire  [10:0] b_addr  [0:1];
    wire  [7:0]  b_rdata [0:7];

    genvar gd, gk;
    generate
        for (gd = 0; gd < 2; gd = gd + 1) begin : g_drive
            for (gk = 0; gk < 4; gk = gk + 1) begin : g_bank
                fd_bank #(.DEPTH (TRACK_WORDS)) u_bank (
                    .clk     (clk),
                    .a_we    (a_we[gd*4 + gk]),
                    .a_addr  (a_addr[gd]),
                    .a_wdata (a_wdata),
                    .a_rdata (a_rdata[gd*4 + gk]),
                    .b_we    (b_we[gd]),
                    .b_addr  (b_addr[gd]),
                    .b_wdata (pay_data[8*gk +: 8]),
                    .b_rdata (b_rdata[gd*4 + gk])
                );
            end
        end
    endgenerate

    // ---- the bus side of the buffer ----------------------------------------------
    // Port A does one of three things a clock, in this priority: a store
    // (the byte the machine is writing, at the slot under the head), a
    // filler write (the $FF a skipped slot gets), or the standing read of the
    // slot under the head into `nxt` - the nibble the register will present
    // next, refreshed every few clocks so a drive switch or a store is seen
    // within the cycle.
    logic [7:0]  nxt;
    logic        a_rd_q;                // last clock read the head's slot
    logic        a_sel_q;               // ...of this drive
    logic [1:0]  a_lane_q;              // ...in this lane

    // The write burst: where the last byte landed, so a skipped slot can be
    // filled.  One burst at a time, the selected drive's, ended by leaving
    // write mode or moving the head.
    logic        wr_burst;
    logic [12:0] wr_last;
    logic [12:0] fill_ptr;
    logic [4:0]  fill_left;

    // A store: the $C0nC access in write mode, on a turning, writable disk.
    wire store = page_commit && (idx == 4'hC) && q7 && spinning &&
                 drv_inserted[s] && !drv_wp[s];

    // Slots between the last store and this one, on the circle.
    wire [13:0] gap_raw = {1'b0, pos[s]} - {1'b0, wr_last};
    wire [12:0] gap     = gap_raw[13] ? (gap_raw[12:0] + nibbles[s]) : gap_raw[12:0];
    wire        gap_fill = wr_burst && (gap > 13'd1) && (gap <= FILL_MAX_GAP[12:0]);

    wire filler_run = (fill_left != 5'd0) && !store;
    wire [12:0] wr_last_p1  = (wr_last + 13'd1 == nibbles[s]) ? 13'd0 : wr_last + 13'd1;
    wire [12:0] fill_ptr_p1 = (fill_ptr + 13'd1 == nibbles[s]) ? 13'd0 : fill_ptr + 13'd1;

    wire         a_busy    = store || filler_run;
    wire [12:0]  a_byte    = store ? pos[s] : fill_ptr;
    wire [2:0]   a_we_lane = {s, a_byte[1:0]};
    assign a_addr[0] = (a_busy && !s) ? a_byte[12:2] : pos[0][12:2];
    assign a_addr[1] = (a_busy &&  s) ? a_byte[12:2] : pos[1][12:2];
    assign a_wdata   = store ? latch : 8'hFF;
    genvar gw;
    generate
        for (gw = 0; gw < 8; gw = gw + 1) begin : g_awe
            assign a_we[gw] = a_busy && (a_we_lane == gw[2:0]);
        end
    endgenerate

    wire a_rd_issue = !store && !filler_run;

    always_ff @(posedge clk) begin
        a_rd_q   <= a_rd_issue;
        a_sel_q  <= s;
        a_lane_q <= pos[s][1:0];
        if (rst)         nxt <= 8'd0;
        else if (a_rd_q) nxt <= a_rdata[{a_sel_q, a_lane_q}];
        // A store is the byte the head is over: what a read of it would see.
        if (store) nxt <= latch;
    end

    // ---- host -> card messages: the ROM and the track chunks -----------------------
    logic [7:0] rx_type;
    logic [7:0] rx_idx;
    logic [7:0] rx_left;

    wire rx_hdr  = msg_valid;
    wire rx_word = pay_valid && (rx_left != 8'd0);
    wire rx_last = rx_word && (rx_left == 8'd1);

    wire hdr_rom   = rx_hdr && (msg_type == T_FD_ROM);
    wire hdr_track = rx_hdr && (msg_type == T_FD_TRACK);
    wire word_rom   = rx_word && (rx_type == T_FD_ROM);
    wire word_track = rx_word && (rx_type == T_FD_TRACK);

    // The chunk being filled: {seq, chunk, track, drive} is its first word.
    logic       fill_ok;                // the seq matched: the words land
    logic       fill_drive;
    logic [2:0] fill_chunk;
    logic [10:0] fill_word;             // where the next word goes

    wire        w0_drive = pay_data[0];
    wire [7:0]  w0_chunk = pay_data[23:16];
    wire [7:0]  w0_seq   = pay_data[31:24];
    wire [10:0] w0_base  = {3'd0, w0_chunk[2:0]} * CHUNK_WORDS[10:0];

    wire fill_write = word_track && (rx_idx != 8'd0) && fill_ok &&
                      (fill_word < TRACK_WORDS[10:0]);
    wire chunk_done = word_track && rx_last && fill_ok;

    // The ROM, written on its own so nothing with a reset shares its block.
    always_ff @(posedge clk) begin
        if (word_rom) rom[rx_idx[5:0]] <= pay_data;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type    <= 8'd0;
            rx_idx     <= 8'd0;
            rx_left    <= 8'd0;
            rom_ok     <= 1'b0;
            fill_ok    <= 1'b0;
            fill_drive <= 1'b0;
            fill_chunk <= 3'd0;
            fill_word  <= 11'd0;
        end else begin
            if (rx_hdr) begin
                rx_type <= msg_type;
                rx_idx  <= 8'd0;
                rx_left <= msg_len;
                // A ROM message is only a ROM if it is the whole ROM.
                if (hdr_rom && msg_len != 8'd64) rx_type <= 8'd0;
                if (hdr_track) fill_ok <= 1'b0;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_rom && rx_last) rom_ok <= 1'b1;
                if (word_track) begin
                    if (rx_idx == 8'd0) begin
                        fill_drive <= w0_drive;
                        fill_chunk <= w0_chunk[2:0];
                        fill_word  <= w0_base;
                        fill_ok    <= (w0_chunk < 8'd7) &&
                                      (w0_seq == seq[w0_drive]) &&
                                      drv_inserted[w0_drive];
                    end else if (fill_ok) begin
                        fill_word <= fill_word + 11'd1;
                    end
                end
            end
        end
    end

    // ---- card -> host: FD_DIRTY uploads and FD_SEEK notices ------------------------
    // One stream, one message at a time.  For a drive, the upload of the
    // track it is leaving goes before the seek for the one it is on, so the
    // host has the written track before it could be asked for it again.
    typedef enum logic [2:0] {
        X_IDLE,
        X_UP_HDR,       // an FD_DIRTY chunk's header
        X_UP_W0,        // its {seq, chunk, track, drive}
        X_UP_DATA,      // its words, from the buffer
        X_SEEK_HDR,
        X_SEEK_W0
    } xstate_t;

    xstate_t    xs;
    logic       x_drive;
    logic [2:0] x_chunk;
    logic [7:0] x_left;                 // data words still to send this chunk
    logic [10:0] x_word;                // the buffer word being offered

    wire [7:0] chunk_len  = (x_chunk == 3'd6) ? LAST_CHUNK_WORDS[7:0] : CHUNK_WORDS[7:0];
    wire [7:0] x_msg_len  = chunk_len + 8'd1;

    // Port B of the selected drive's buffer reads the word being offered,
    // and the one after it on the clock it is taken, so the stream never
    // stalls for the RAM's latency.  The fill's writes take the port when
    // they come; by the protocol they cannot come for a drive mid-upload.
    wire [10:0] x_word_next = ((xs == X_UP_DATA) && tx_take) ? x_word + 11'd1 : x_word;

    assign b_we[0]   = fill_write && (fill_drive == 1'b0);
    assign b_we[1]   = fill_write && (fill_drive == 1'b1);
    assign b_addr[0] = b_we[0] ? fill_word : (x_drive ? 11'd0 : x_word_next);
    assign b_addr[1] = b_we[1] ? fill_word : (x_drive ? x_word_next : 11'd0);

    wire [31:0] x_data = x_drive ? {b_rdata[7], b_rdata[6], b_rdata[5], b_rdata[4]}
                                 : {b_rdata[3], b_rdata[2], b_rdata[1], b_rdata[0]};

    wire [31:0] x_w0 = {(xs == X_SEEK_W0) ? seq[x_drive] : up_seq[x_drive],
                        5'd0, x_chunk,
                        2'd0, (xs == X_SEEK_W0) ? buf_track[x_drive] : up_track[x_drive],
                        7'd0, x_drive};

    assign tx_valid = (xs != X_IDLE);
    assign tx_word  = (xs == X_UP_HDR)   ? {16'd0, T_FD_DIRTY, x_msg_len} :
                      (xs == X_SEEK_HDR) ? {16'd0, T_FD_SEEK, 8'd1} :
                      (xs == X_UP_DATA)  ? x_data : x_w0;

    // Pulses the drive logic consumes.
    wire up_sent   = (xs == X_UP_DATA) && tx_take && (x_left == 8'd1) && (x_chunk == 3'd6);
    wire seek_sent = (xs == X_SEEK_W0) && tx_take;

    always_ff @(posedge clk) begin
        if (rst) begin
            xs      <= X_IDLE;
            x_drive <= 1'b0;
            x_chunk <= 3'd0;
            x_left  <= 8'd0;
            x_word  <= 11'd0;
        end else begin
            case (xs)
                X_IDLE: begin
                    x_chunk <= 3'd0;
                    x_word  <= 11'd0;
                    if (up_owed[0])        begin x_drive <= 1'b0; xs <= X_UP_HDR;   end
                    else if (up_owed[1])   begin x_drive <= 1'b1; xs <= X_UP_HDR;   end
                    else if (seek_owed[0]) begin x_drive <= 1'b0; xs <= X_SEEK_HDR; end
                    else if (seek_owed[1]) begin x_drive <= 1'b1; xs <= X_SEEK_HDR; end
                end
                X_UP_HDR:  if (tx_take) begin xs <= X_UP_W0; x_left <= chunk_len; end
                X_UP_W0:   if (tx_take) xs <= X_UP_DATA;
                X_UP_DATA: if (tx_take) begin
                    x_word <= x_word + 11'd1;
                    x_left <= x_left - 8'd1;
                    if (x_left == 8'd1) begin
                        if (x_chunk == 3'd6) xs <= X_IDLE;
                        else begin x_chunk <= x_chunk + 3'd1; xs <= X_UP_HDR; end
                    end
                end
                X_SEEK_HDR: if (tx_take) xs <= X_SEEK_W0;
                X_SEEK_W0:  if (tx_take) xs <= X_IDLE;
                default: xs <= X_IDLE;
            endcase
        end
    end

    // ---- the stepper ----------------------------------------------------------------
    // Evaluated STEP_TICKS bus cycles after the last phase access, from the
    // magnets as they are then - so two adjacent magnets dropped in quick
    // succession move nothing, which is AppleWin's GH#1110 in one rule.
    wire        phase_access = page_commit && !idx[3];
    wire        step_now     = tick && (step_timer == 4'd1);
    wire [1:0]  cog          = phase[s][1:0];
    wire [1:0]  cog_up       = cog + 2'd1;      // the magnet one phase on
    wire [1:0]  cog_down     = cog + 2'd3;      // ...and one phase back
    wire        mag_up   = magnets[cog_up];
    wire        mag_down = magnets[cog_down];
    wire        head_on  = motor || spinning;      // the drive is enabled or coasting
    logic [6:0] phase_new;
    always_comb begin
        phase_new = phase[s];
        if (mag_up && !mag_down && phase[s] != 7'd79) phase_new = phase[s] + 7'd1;
        if (mag_down && !mag_up && phase[s] != 7'd0)  phase_new = phase[s] - 7'd1;
    end
    wire        step_move = step_now && head_on && (phase_new != phase[s]);
    wire        step_track = step_move && (phase_new[6:1] != buf_track[s]);

    // ---- the drives, per tick -------------------------------------------------------
    // Two drives, one block each, so the per-drive state is written from
    // exactly one place.
    genvar gv;
    generate
        for (gv = 0; gv < 2; gv = gv + 1) begin : g_drv
            // This drive is enabled: the motor is on and it is the one selected.
            wire en_d    = motor && (drive_sel == gv[0]);
            wire spin_d  = (spin[gv] != 20'd0);
            wire sel_d   = (drive_sel == gv[0]);
            wire ins_edge = drv_inserted[gv] && !ins_prev[gv];
            wire ej_edge  = !drv_inserted[gv] && ins_prev[gv];
            wire filling  = (gv == 0) ? filling0 : filling1;
            wire spin_end = tick && spin_d && !en_d && (spin[gv] == 20'd1);
            // The head moves to another track on this drive.
            wire moved    = step_track && sel_d;
            wire [5:0] new_track = phase_new[6:1];
            // The buffer's track is left behind, or is otherwise finished with.
            wire leave    = moved || ins_edge || ej_edge || drv_flush[gv] || spin_end;
            // ...and the host is owed the track it holds.
            wire flush    = leave && dirty[gv];
            // A new track is wanted from the host.
            wire want     = (moved || ins_edge) && drv_inserted[gv] &&
                            (((moved) ? new_track : buf_track[gv]) < tracks[gv]);
            wire filled   = chunk_done && (fill_drive == gv[0]) &&
                            ((chunks[gv] | (7'd1 << fill_chunk)) == 7'h7F);
            wire read_now = page_commit && op_rw && (idx == 4'hC) && !q7 && sel_d;

            always_ff @(posedge clk) begin
                if (rst) begin
                    phase[gv]      <= 7'd0;
                    spin[gv]       <= 20'd0;
                    stable[gv]     <= 10'd0;
                    pos[gv]        <= 13'd0;
                    bit_ctr[gv]    <= 5'd0;
                    stale[gv]      <= 1'b1;
                    dirty[gv]      <= 1'b0;
                    seq[gv]        <= 8'd0;
                    buf_track[gv]  <= 6'd0;
                    chunks[gv]     <= 7'd0;
                    fill_ticks[gv] <= 16'd0;
                    read_stale[gv] <= 1'b0;
                    seek_owed[gv]  <= 1'b0;
                    up_owed[gv]    <= 1'b0;
                    up_track[gv]   <= 6'd0;
                    up_seq[gv]     <= 8'd0;
                    ins_prev[gv]   <= 1'b0;
                end else begin
                    ins_prev[gv] <= drv_inserted[gv];

                    // The platter.
                    if (tick) begin
                        if (en_d)        spin[gv] <= SPIN_TICKS[19:0];
                        else if (spin_d) spin[gv] <= spin[gv] - 20'd1;
                        if (!spin_d)     stable[gv] <= 10'd0;
                        else if (stable[gv] != 10'h3FF) stable[gv] <= stable[gv] + 10'd1;
                        if (spin_d) begin
                            bit_ctr[gv] <= bit_ctr[gv] + 5'd1;
                            if (bit_ctr[gv] == 5'd31)
                                pos[gv] <= (pos[gv] + 13'd1 >= nibbles[gv]) ? 13'd0
                                                                            : pos[gv] + 13'd1;
                        end
                        if (filling && fill_ticks[gv] != 16'hFFFF)
                            fill_ticks[gv] <= fill_ticks[gv] + 16'd1;
                    end

                    // The head.
                    if (step_move && sel_d) phase[gv] <= phase_new;

                    // Leaving a track: the written one goes to the host first.
                    if (flush) begin
                        up_owed[gv]  <= 1'b1;
                        up_track[gv] <= buf_track[gv];
                        up_seq[gv]   <= seq[gv];
                    end
                    if (leave) dirty[gv] <= 1'b0;
                    if (moved) buf_track[gv] <= new_track;
                    if (moved || ins_edge || ej_edge) stale[gv] <= 1'b1;
                    if (want) begin
                        seek_owed[gv]  <= 1'b1;
                        seq[gv]        <= seq[gv] + 8'd1;
                        chunks[gv]     <= 7'd0;
                        fill_ticks[gv] <= 16'd0;
                        read_stale[gv] <= 1'b0;
                    end
                    if (seek_sent && (x_drive == gv[0])) seek_owed[gv] <= 1'b0;
                    if (up_sent && (x_drive == gv[0]))   up_owed[gv]   <= 1'b0;

                    // The track arriving.
                    if (chunk_done && (fill_drive == gv[0]))
                        chunks[gv] <= chunks[gv] | (7'd1 << fill_chunk);
                    if (filled) stale[gv] <= 1'b0;
                    if (read_now && filling) read_stale[gv] <= 1'b1;

                    // The machine wrote.
                    if (store && sel_d) dirty[gv] <= 1'b1;
                end
            end
        end
    endgenerate

    // The two measurements, and the seek count.
    wire filled0 = g_drv[0].filled;
    wire filled1 = g_drv[1].filled;
    wire late0   = filled0 && read_stale[0];
    wire late1   = filled1 && read_stale[1];
    wire [15:0] fill_done_ticks = filled0 ? fill_ticks[0] : fill_ticks[1];

    always_ff @(posedge clk) begin
        if (rst) begin
            seeks    <= 8'd0;
            late     <= 8'd0;
            fill_max <= 16'd0;
        end else begin
            if (g_drv[0].want || g_drv[1].want) seeks <= seeks + 8'd1;
            if (late_clr) late <= 8'd0;
            else if ((late0 || late1) && late != 8'hFF) late <= late + 8'd1;
            if (fill_clr) fill_max <= 16'd0;
            else if ((filled0 || filled1) && fill_done_ticks > fill_max)
                fill_max <= fill_done_ticks;
        end
    end

    // ---- the controller: switches, the register, the write burst --------------------
    // The nibble the register takes when the slot completes: the buffer's,
    // or what an empty drive shows.
    wire        settled   = (stable[s] >= STABLE_TICKS[9:0]);
    wire [7:0]  empty_val = settled ? lfsr[7:0] : 8'h80;
    wire [7:0]  slot_val  = usable ? nxt : empty_val;
    wire        complete  = tick && spinning && (bit_ctr[s] == 5'd31);
    // Bits of the next slot shifted in so far, after this tick.
    wire [4:0]  bits_next = bit_ctr[s] + 5'd1;
    wire [2:0]  bits_in   = bits_next[4:2];
    wire [7:0]  partial   = slot_val >> (4'd8 - {1'b0, bits_in});

    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr <= 16'hACE1;
        end else if (tick) begin
            lfsr <= {lfsr[14:0], lfsr_fb};
        end
    end

    always_ff @(posedge clk) begin
        if (cpu_rst) begin
            magnets    <= 4'd0;
            motor      <= 1'b0;
            drive_sel  <= 1'b0;
            q6         <= 1'b0;
            q7         <= 1'b0;
            step_timer <= 4'd0;
            latch      <= 8'd0;
            hold       <= 3'd0;
            wr_burst   <= 1'b0;
            fill_left  <= 5'd0;
            fill_ptr   <= 13'd0;
            wr_last    <= 13'd0;
        end else begin
            if (tick && step_timer != 4'd0) step_timer <= step_timer - 4'd1;

            // The register, in read mode: a nibble every 32 ticks, held for
            // HOLD_TICKS, then the next one shifting in.  A stopped drive
            // holds it.
            if (!q7 && tick && spinning) begin
                if (complete) begin
                    latch <= slot_val;
                    hold  <= HOLD_TICKS[2:0];
                end else if (hold != 3'd0) begin
                    hold <= hold - 3'd1;
                end else begin
                    latch <= partial;
                end
            end

            if (page_commit) begin
                case (idx[3:1])
                    3'd0, 3'd1, 3'd2, 3'd3: begin
                        magnets[idx[2:1]] <= idx[0];
                        step_timer <= STEP_TICKS[3:0];
                    end
                    3'd4: begin
                        motor <= idx[0];
                        if (!idx[0]) magnets <= 4'd0;
                    end
                    3'd5: drive_sel <= idx[0];
                    3'd6: q6 <= idx[0];
                    default: q7 <= idx[0];
                endcase

                // $C0nD samples write-protect, in either mode (GH#537)...
                if (idx == 4'hD && spinning) latch <= drv_wp[s] ? 8'hFF : 8'h00;
                // ...and a store with Q6 and Q7 set loads the register: the
                // sequencer's LD, whichever address it was aimed at.
                if (!op_rw && q6_after && q7_after) latch <= op_wdata;
            end

            // The write burst: a store lands at the head, and a slot the burst
            // skipped - a 40-cycle sync byte - is filled with $FF behind it.
            if (store) begin
                if (gap_fill && fill_left == 5'd0) begin
                    fill_ptr  <= wr_last_p1;
                    fill_left <= gap[4:0] - 5'd1;
                end
                wr_last  <= pos[s];
                wr_burst <= 1'b1;
            end else if (filler_run) begin
                fill_ptr  <= fill_ptr_p1;
                fill_left <= fill_left - 5'd1;
            end
            // Leaving write mode, changing drive, or moving the head ends it.
            if ((page_commit && ((idx == 4'hE) || (idx[3:1] == 3'd5))) || step_move)
                wr_burst <= 1'b0;
        end
    end

    // ---- claim and read data --------------------------------------------------------
    // Decided in the address phase from the presented op, registered so it
    // is stable long before the emit window.  Even addresses in the page
    // read the register; odd ones are the floating bus and nobody's.
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_claim <= 1'b0;
            rd_data  <= 8'd0;
        end else if (op_present) begin
            rd_claim <= 1'b0;
            rd_data  <= 8'd0;
            if (hit_rom) begin
                rd_claim <= 1'b1;
                rd_data  <= rom_byte;
            end else if (hit_page && op_rw && !idx[0]) begin
                rd_claim <= 1'b1;
                rd_data  <= latch;
            end
        end else if (!enabled) begin
            rd_claim <= 1'b0;
        end
    end

    wire _unused_ok = &{1'b0, msg_free, 1'b0};

endmodule
