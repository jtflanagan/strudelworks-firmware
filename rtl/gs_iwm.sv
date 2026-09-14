`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_iwm - the IIgs's Integrated Woz Machine at $C0E0-$C0EF, with ONE 3.5"
// DRIVE and TWO 5.25" DRIVES on it, the disks on the host and one track of
// the drive in use in the card.
//
// THE REFERENCE IS KEGS's iwm.c: iwm_touch_switches for the soft switches,
// read_iwm and write_iwm for the data path, iwm_read_status35 and
// iwm_do_action35 for the 3.5" drive's sixteen-way register, iwm_read_data
// for the data register; the 5.25" head's stepper and the 5.25" write model
// are the Disk II's (rtl/floppy_card.sv).  docs/IWM35.md.
//
// THE VIRTUAL DRIVES RUN IN THE CORE'S CYCLES AND NOTHING ELSE (the user's
// rule, 2026-09-13).  A nibble is a fixed number of the soft core's cycles:
// 32 for a 5.25" drive (a 4-cycle bit cell, the speed the 5.25" firmware's
// loops are written for) and 44.8 for the 3.5" drive (a 2 us bit cell at the
// 2.8 MHz the 3.5" drivers run at - every one of the 1.76 M 3.5" data reads
// of the XMAS demo's and Arkanoid's boots was made with $C036's speed bit
// set).  No speed request, no motor-on slowdown, no 1 MHz or wall time moves
// it: the loops a driver counts in cycles line up by construction, and the
// load goes as fast as the core is accelerated.  (This drive used to follow
// $C036 bit 7, as KEGS does.  A wall-time path is for a physical drive, if
// one is ever attached.)
//
// THE ADDRESS IS THE REGISTER.  $C0E0-$C0EF is eight pairs of soft switches:
// the low bit is the value and the rest select which.  $C0E0-$C0E7 are the
// four phase lines, $C0E8/9 the motor (the IWM's ENABLE), $C0EA/B the drive
// select, $C0EC/D Q6 and $C0EE/F Q7.  Every access touches its switch, READ
// OR WRITE, before anything else happens - which is why the ROM can use BIT.
//
// WHAT Q7:Q6 SELECT on an EVEN address (read_iwm):
//   0 0  the DATA register
//   0 1  the STATUS register: {sense, 0, motor_on, mode[4:0]}
//   1 0  the write HANDSHAKE - $C0/$80 alternating under ENABLE2, else $80
//   1 1  nothing (a read of an odd address returns 0)
// An ODD address with Q7:Q6 = 1,1 and the motor OFF writes the MODE register,
// five bits; with the motor ON it is a DATA WRITE (write_iwm's
// iwm_write_data): a 5.25" drive takes it into the track (WRITES, below), the
// 3.5" drive drops it (its writes are not built; its disks read locked).
//
// $C031 bit 6 CHOOSES THE SIDE: set, the 3.5" drive; clear, the 5.25" pair.
//
// THE 3.5" DRIVE'S OWN REGISTER.  The phase lines and $C031's bit 7 make a
// four-bit address, {ph1, ph0, $C031[7], ph2}; with Q6 set, bit 7 of the
// status byte is the sense line that address selects (iwm_read_status35), and
// a strobe of phase 3 performs the action it names (iwm_do_action35).  Two
// of the sense reads have a SIDE EFFECT: $1 and $3 select the lower and the
// upper head, which is how the side is chosen - $C031's bit 7 is a select
// bit, not the side.  KEGS, case for case; the table is in the always_comb.
//
// THE 5.25" DRIVES' HEADS are the Disk II's: the four phases are magnets, the
// head a cog in half-tracks 0..79 per drive, and TEN CYCLES after the last
// phase access the selected drive's cog steps one half-track toward the one
// energised neighbour - not at all with both on - while the IWM's ENABLE is
// on (rtl/floppy_card.sv's rule, AppleWin's GH#1110).  The status byte's bit
// 7 is the drive's WRITE PROTECT (iwm.c: `status = dsk->write_prot`), from
// FD_DRIVE1/2; a drive with no disk reads protected.
//
// THE PLATTER.  The track under the head is a NIBBLE STREAM in the track
// buffer, `nibbles` of them per track - the 3.5" fill says how many (9694 in
// zone 0 down to 6578 in zone 4, tools/nib35.py), a 5.25" drive's register
// says it for its disk (6384 for a sector image, tools/nib525.py).  It turns
// one slot per nibble time whenever the IWM's ENABLE is on, as KEGS's does.
//
// THE DATA REGISTER.  In LATCH MODE (mode bit 0, which every 3.5" driver
// sets) a completed nibble is held, high bit set, until it is READ, and each
// nibble is returned ONCE - the read after it sees the next nibble's bits
// shifting in, high bit clear (iwm_read_data's latch-mode arm).  Without
// latch mode - the 5.25" firmware's - the nibble is held for a while and then
// the shift-in shows: seven cycles for a 5.25" drive, the Disk II's hold
// (rtl/floppy_card.sv HOLD_TICKS), half a nibble for the 3.5".
//
// WRITES (5.25", 2026-09-14).  A data write on a writable disk whose track is
// in the buffer is taken at the load (on the IWM the load is the write) and
// lands CONTIGUOUSLY: a burst's first byte in the slot under the head, each
// byte after it in the next slot.  A slow byte's extra zero bits are nothing
// a reader takes for a nibble, so they take no slot (THE WRITE BURST, below,
// has why the Disk II card's $FF filler broke DOS 3.3 here).  In the core's
// cycles like everything else here.  A buffer that was written is DIRTY, and before
// the buffer's claim on its track ends - another track, drive or side wanted,
// the motor stopping, the disk ejected, the host asking (FD_DRIVE's flush) -
// the track goes back to the host as the Disk II's seven FD_DIRTY chunks
// {seq, chunk, track, drive}, carrying the seq that filled it (the host keeps
// only a track it answered), ahead of the seek for whatever comes next.
//
// THE BUFFER AND THE HOST are the Disk II's design (docs/FLOPPY.md), one
// buffer for whichever drive is in use, tagged {side, drive, track}.  When
// the selected drive has a disk and the buffer is not its track - a step, a
// head or drive or side select, an insertion - the buffer goes STALE and the
// card asks the host: the 3.5" drive with FD35_SEEK {seq, 0, track*2+side, 0},
// answered by FD35_TRACK chunks {seq, chunk, track*2+side, 0}, {chunks, 0,
// nibbles}, up to 252 words; a 5.25" drive with the Disk II's own FD_SEEK
// {seq, chunk 0, track, drive}, answered by seven FD_TRACK chunks {seq, chunk,
// track, drive} then 252 words (152 in the last) - the host's floppy service,
// unchanged, and on a IIgs the Disk II card is not built at all
// (rtl/master_top.sv g_no_fd).  A select to a side or drive with NO disk moves
// nothing, so $C031 flicking to the empty 5.25" pair never throws away the
// 3.5" track.  While stale the register serves noise, never a wrong track;
// the 3.5" drive reports itself STEPPING (sense $4 = 0) after a step; and the
// accelerated core is held (stall_o, as the Disk II's).  A seek nobody
// answered is asked again after FILL_RETRY_CLKS.
//
// NOT HERE YET: 3.5" writes (dropped; the host's 3.5" disks are locked), a
// second 3.5" drive (sense $F says drive 1 is not installed, as KEGS says),
// eject (action $D is taken and does nothing).
//////////////////////////////////////////////////////////////////////////////////
module gs_iwm #(
    parameter [7:0] T_FD35_TRACK = 8'h31,   // host -> card
    parameter [7:0] T_FD35_SEEK  = 8'h32,   // card -> host
    parameter [7:0] T_FD_TRACK   = 8'h1F,   // host -> card, the Disk II's
    parameter [7:0] T_FD_SEEK    = 8'h20,   // card -> host, the Disk II's
    parameter [7:0] T_FD_DIRTY   = 8'h21,   // card -> host, the Disk II's
    // Ticks the IWM's ENABLE stays on after $C0E8 with the mode register's
    // "immediate off" bit clear: KEGS's 60 VBLs, one second.  A tb shortens.
    parameter integer MOTOR_OFF_TICKS = 1_000_000,
    // Clocks a stale buffer waits for its fill before asking again.
    parameter integer FILL_RETRY_CLKS = 4_000_000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,       // synchronised RES', ACTIVE LOW

    // The registered op and its retire.
    input  wire [7:0]  op_lo,          // the low byte of $C0xx
    input  wire        op_rw,
    input  wire [7:0]  op_wdata,
    input  wire        act,

    output logic [7:0] rd_byte,

    // $C031 DISKREG: bit 6 selects the 3.5" drives over the 5.25" (iwm.h
    // IWM_BIT_C031_APPLE35SEL is 6), bit 7 is the drive's SEL line, one of
    // the status multiplexer's four select bits (IWM_BIT_C031_CTRL is 7).
    input  wire        apple35_sel,
    input  wire        c031_ctrl,

    // THE CORE'S CLOCK: one per op the core retired - a bus cycle that
    // carried one, or a fast op the bus never saw - never a dummy cycle.  The
    // drives' only time base.
    input  wire        tick,

    // Host -> card messages, as ft601_msg_rx decodes them.
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,

    // Card -> host: FD35_SEEK, FD_SEEK or FD_DIRTY, a word at a time through
    // msg_arb.
    output wire [31:0] tx_word,
    output wire        tx_valid,
    input  wire        tx_take,

    // FD35_DRIVE, live: what is in the 3.5" drive.
    input  wire        drv_inserted,
    input  wire        drv_wp,
    // FD35_STAT's W1 bits.
    input  wire        late_clr,
    input  wire        fill_clr,

    // FD_DRIVE1/FD_DRIVE2, live: what is in the two 5.25" drives - the Disk
    // II's registers, [0] drive 1 and [1] drive 2; nibbles [12:0] and tracks
    // [5:0] per drive; flush a pulse per drive.
    input  wire [1:0]  d5_inserted,
    input  wire [1:0]  d5_wp,
    input  wire [25:0] d5_nibbles,
    input  wire [11:0] d5_tracks,
    input  wire [1:0]  d5_flush,

    // For the registers' readback.
    output wire        stale_o,
    output wire [6:0]  track_o,
    output wire        side_o,
    output wire        motor35_o,
    output wire        motor_o,
    output wire [7:0]  ctl_o,          // {phases, q7, q6, drive_sel, apple35_sel}
    output logic [7:0] seeks,
    output logic [7:0] late,
    output logic [15:0] fill_max,      // microseconds, seek to last chunk
    // ...and FD_DRIVE1/2 and FD_STAT's: the buffer is not this 5.25" drive's
    // track, the buffer holds this 5.25" drive's track written, and each
    // drive's head in half-tracks.
    output wire [1:0]  d5_stale_o,
    output wire [1:0]  d5_dirty_o,
    output wire [13:0] d5_phase_o,     // [6:0] drive 1, [13:7] drive 2
    // The drive in use is turning with a disk in and the buffer is not its
    // track: the accelerated core waits for the fill (rtl/accel_seq.sv stall).
    output wire        stall_o,

    // Diagnostics.
    output logic [7:0] cnt_mode_wr
);

    // ---- geometry ------------------------------------------------------------
    localparam integer BUF_BYTES   = 10240;          // > zone 0's 9694, > 5.25"'s 6656
    localparam integer BUF_WORDS   = BUF_BYTES / 4;  // 2560
    localparam integer CHUNK_WORDS = 252;
    localparam integer D5_CHUNKS   = 7;              // the Disk II's fill (docs/FLOPPY.md)
    localparam integer D5_LAST     = 152;            // ...words in its seventh chunk
    localparam integer BURST_MAX_GAP = 16;           // slots a write burst may be off the head
    // The nibble time in FIFTHS of a core cycle, fixed (see the header).
    localparam [7:0]   P35         = 8'd224;         // 44.8 cycles
    localparam [7:0]   P525        = 8'd160;         // 32 cycles
    // How long a completed 5.25" nibble stays readable - cleared sooner by the
    // read that takes it (see "THE 5.25\" HOLD" below).
    localparam [7:0]   HOLD525     = 8'd120;         // 24 cycles
    localparam [3:0]   STEP_TICKS  = 4'd10;          // phase access -> cog moves

    // ---- the IWM's own latches --------------------------------------------------
    logic [4:0] mode;               // the IWM mode register
    logic [3:0] phases;
    logic       motor_on;           // the IWM's ENABLE, $C0E8/$C0E9
    logic       motor_off_pend;     // ...counting down after $C0E8
    logic [21:0] motor_off_ticks;
    logic       drive_sel;
    logic       q6, q7;
    logic [1:0] hs_count;           // the ENABLE2 handshake's three-then-one

    wire enable2   = (phases[1] && phases[3]);
    wire iwm_reset = (phases[0] && phases[2]);

    assign motor_o = motor_on;
    assign ctl_o   = {phases, q7, q6, drive_sel, apple35_sel};

    // The switch this access touches has NOT been applied yet when the byte
    // is composed (KEGS calls iwm_touch_switches BEFORE it composes the
    // byte), so the two that matter for the read are taken as they will be.
    wire       t_q6 = (op_lo[3:1] == 3'd6) ? op_lo[0] : q6;
    wire       t_q7 = (op_lo[3:1] == 3'd7) ? op_lo[0] : q7;
    wire [1:0] q7q6 = {t_q7, t_q6};
    // ...and the motor: a read of $C0E9 sees ENABLE on.
    wire       t_motor = (op_lo[3:1] == 3'd4) ? op_lo[0] : motor_on;

    // ---- the 3.5" drive's own state (iwm_do_action35) -----------------------
    logic       step_dir35;         // 0 = inward (higher tracks), 1 = outward
    logic       motor35;            // the drive's motor
    logic [6:0] track35;            // the head's track, 0..79
    logic       side35;             // the head in use: 0 lower, 1 upper
    logic       stepped;            // a step's fill is what the buffer waits on

    assign track_o   = track35;
    assign side_o    = side35;
    assign motor35_o = motor35;

    // ---- the 5.25" drives' heads (rtl/floppy_card.sv's stepper) -------------
    logic [6:0] hp [0:1];           // each drive's head, in half-tracks 0..79
    logic [3:0] step_timer;         // cycles until a phase access moves the cog
    wire  [6:0] hp_sel   = hp[drive_sel];
    wire  [5:0] trk5     = hp_sel[6:1];
    assign d5_phase_o = {hp[1], hp[0]};

    // ---- the platter ----------------------------------------------------------
    logic [13:0] pos;               // 0 .. nibbles-1
    logic [7:0]  nib_acc;           // fifths of a cycle into this slot
    wire  [7:0]  nib_period = apple35_sel ? P35 : P525;
    wire         spinning   = motor_on;
    wire         complete   = tick && spinning && (nib_acc + 8'd5 >= nib_period);
    // The bits of the next slot shifted in so far, for the partial byte a
    // read sees between nibbles: nothing decodes it, it only has to look
    // like a byte shifting in - bit 7 clear, the rest moving.
    wire  [7:0]  bits_q     = apple35_sel ? (nib_acc / 8'd28) : (nib_acc / 8'd20);
    wire  [2:0]  bits_in    = (bits_q > 8'd7) ? 3'd7 : bits_q[2:0];

    // ---- the buffer's state ---------------------------------------------------
    // Its identity, {side, 8 bits}: side 0 the 3.5" drive with {track, head},
    // side 1 a 5.25" drive with {drive, 0, track}.
    logic        stale;             // the buffer is not its identity's track yet
    logic [8:0]  buf_id;
    logic [7:0]  seq;               // the seek the host is answering
    logic [13:0] nibbles35;         // a 3.5" track's nibbles, from its fill
    logic [15:0] chunks_r;          // chunks landed for `seq`
    logic [3:0]  chunks_total;      // ...of how many
    logic        seek_owed;
    logic        read_stale;        // the machine read while stale
    logic [21:0] retry_clks;
    logic [6:0]  us_pre;            // 100 clocks to the microsecond
    logic [15:0] fill_us;           // microseconds since the seek, saturating
    // The written track going home.
    logic        dirty;             // the buffer (a 5.25" track) was written to
    logic        up_owed;           // an FD_DIRTY upload is to be sent
    logic        up_again;          // ...and another after the one going out
    logic [8:0]  up_id;             // ...of this track
    logic [7:0]  up_seq;            // ...as filled by this seek
    logic        motor_prev;        // for the motor stopping

    // Driven below, named here so every use follows its declaration.
    wire [11:0] a_addr;             // the head's port
    wire [3:0]  a_we;
    wire [31:0] a_wdata;
    wire        a_read;             // ...doing the standing read this clock
    wire [11:0] b_addr;             // the link's port
    wire [31:0] b_word;
    wire        store;              // the machine writes a byte at the head
    wire        want;               // a new track is wanted from the host

    // THE ONE 3.5" DRIVE IS DRIVE 1.  With $C0EB selecting drive 2 there is
    // nothing there: no disk, not installed, locked, at track 0, and a step
    // moves nothing - which is what KEGS's empty drive35[1] answers, and
    // what the ROM's probe relies on to pass drive 2 by and look at drive 1
    // (it asks drive 2 first).  The STEP DIRECTION and the DRIVE MOTOR are
    // not the drive's: KEGS keeps them in the IWM's own state word, shared
    // by both selects, and the ROM sets the direction with drive 2 selected
    // and reads it back expecting to see it.
    wire         here     = !drive_sel;
    wire         disk_in  = drv_inserted && here;
    // A 5.25" drive has a disk under the head when one is in and the head is
    // on a track the image has.
    wire  [5:0]  tracks_sel = drive_sel ? d5_tracks[11:6] : d5_tracks[5:0];
    wire  [12:0] nib5_sel   = drive_sel ? d5_nibbles[25:13] : d5_nibbles[12:0];
    wire         d5_in      = d5_inserted[drive_sel] && (trk5 < tracks_sel);

    // What the drive in use wants in the buffer, and whether it has a disk.
    wire  [8:0]  tgt_id = apple35_sel ? {1'b0, track35, side35}
                                      : {1'b1, drive_sel, 1'b0, trk5};
    wire         tgt_in = apple35_sel ? disk_in : d5_in;
    wire         usable = tgt_in && !stale && (buf_id == tgt_id);
    wire  [13:0] nibbles = buf_id[8] ? {1'b0, (buf_id[7] ? d5_nibbles[25:13] : d5_nibbles[12:0])}
                                     : nibbles35;
    assign stale_o    = stale;
    assign d5_stale_o = {!(buf_id[8] &&  buf_id[7] && !stale), !(buf_id[8] && !buf_id[7] && !stale)};
    assign d5_dirty_o = {buf_id[8] && buf_id[7] && dirty, buf_id[8] && !buf_id[7] && dirty};
    assign stall_o    = spinning && tgt_in && !usable;

    // Noise for an empty drive or a stale buffer: a 16-bit LFSR per tick.
    logic [15:0] lfsr;
    wire         lfsr_fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    // ---- the track buffer -------------------------------------------------------
    // THREE BLOCK RAM TILES, 1024 words of 32 bits each, 3072 words for the
    // 2560 a zone-0 3.5" track needs (a 5.25" track is 1664): word w lives in
    // tile w[11:10] at index w[9:0].  Three full tiles, not four byte lanes:
    // the count matters (docs/GS.md "The retained set and the DDR3").
    //   Port A is the HEAD'S: the host's fill a word at a time, the machine's
    // writes a byte at a time (a byte-wide write enable), and between them
    // the standing read of the word the head's slot is in.  Port B is the
    // LINK'S and only reads: a written track going back to the host.  One
    // port writes, so nothing drives a tile from two places.
    (* ram_style = "block" *) logic [31:0] tbuf0 [0:1023];
    (* ram_style = "block" *) logic [31:0] tbuf1 [0:1023];
    (* ram_style = "block" *) logic [31:0] tbuf2 [0:1023];
    logic [31:0] a_rd0, a_rd1, a_rd2;
    logic [31:0] b_rd0, b_rd1, b_rd2;
    logic [1:0]  a_tile_q, b_tile_q;
    always_ff @(posedge clk) begin
        for (int k = 0; k < 4; k++)
            if (a_we[k] && a_addr[11:10] == 2'd0) tbuf0[a_addr[9:0]][8*k +: 8] <= a_wdata[8*k +: 8];
        a_rd0 <= tbuf0[a_addr[9:0]];
    end
    always_ff @(posedge clk) begin
        for (int k = 0; k < 4; k++)
            if (a_we[k] && a_addr[11:10] == 2'd1) tbuf1[a_addr[9:0]][8*k +: 8] <= a_wdata[8*k +: 8];
        a_rd1 <= tbuf1[a_addr[9:0]];
    end
    always_ff @(posedge clk) begin
        for (int k = 0; k < 4; k++)
            if (a_we[k] && a_addr[11:10] == 2'd2) tbuf2[a_addr[9:0]][8*k +: 8] <= a_wdata[8*k +: 8];
        a_rd2 <= tbuf2[a_addr[9:0]];
    end
    always_ff @(posedge clk) begin
        b_rd0 <= tbuf0[b_addr[9:0]];
        b_rd1 <= tbuf1[b_addr[9:0]];
        b_rd2 <= tbuf2[b_addr[9:0]];
        a_tile_q <= a_addr[11:10];
        b_tile_q <= b_addr[11:10];
    end
    wire [31:0] a_word = (a_tile_q == 2'd0) ? a_rd0 : (a_tile_q == 2'd1) ? a_rd1 : a_rd2;
    assign      b_word = (b_tile_q == 2'd0) ? b_rd0 : (b_tile_q == 2'd1) ? b_rd1 : b_rd2;

    // The nibble the register will take next, refreshed from the word the
    // head's slot is in whenever port A last did the standing read (one
    // clock of RAM latency, one of lane select - a slot lasts sixteen cycles
    // at the least).  A store holds it: the byte may not be under the head.
    logic [7:0] nxt;
    logic [1:0] a_lane_q;
    logic       a_rd_q;
    always_ff @(posedge clk) begin
        a_lane_q <= pos[1:0];
        a_rd_q   <= a_read;
        if (rst)         nxt <= 8'd0;
        else if (a_rd_q) nxt <= a_word[8*a_lane_q +: 8];
    end

    // ---- host -> card: the track chunks ----------------------------------------
    logic [7:0]  rx_type;
    logic [7:0]  rx_idx;
    logic [7:0]  rx_left;
    logic        fill_ok;
    logic [3:0]  fill_chunk;
    logic [11:0] fill_word;

    wire rx_hdr  = msg_valid;
    wire rx_word = pay_valid && (rx_left != 8'd0);
    wire rx_last = rx_word && (rx_left == 8'd1);
    wire is35    = (rx_type == T_FD35_TRACK);
    wire is525   = (rx_type == T_FD_TRACK);
    wire word_track = rx_word && (is35 || is525);
    // Where a chunk's nibble words start: the 3.5" chunk carries a geometry
    // word first.
    wire [7:0] data_start = is35 ? 8'd2 : 8'd1;

    // Word 0: {seq, chunk, qtr, 0} for the 3.5" drive; {seq, chunk, track,
    // drive} for a 5.25" drive.
    wire [7:0]  w0_lo    = pay_data[7:0];
    wire [7:0]  w0_qtr   = pay_data[15:8];
    wire [7:0]  w0_chunk = pay_data[23:16];
    wire [7:0]  w0_seq   = pay_data[31:24];
    wire        accept35  = (w0_chunk < 8'd16) && !buf_id[8] && (w0_qtr == buf_id[7:0]) &&
                            (w0_seq == seq) && drv_inserted;
    wire        accept525 = (w0_chunk < 8'(D5_CHUNKS)) && buf_id[8] &&
                            (w0_lo == {7'd0, buf_id[7]}) && (w0_qtr == {2'd0, buf_id[5:0]}) &&
                            (w0_seq == seq) && d5_inserted[buf_id[7]];

    wire fill_write = word_track && (rx_idx >= data_start) && fill_ok &&
                      (fill_word < 12'(BUF_WORDS));
    wire chunk_done = word_track && rx_last && fill_ok;

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type    <= 8'd0;
            rx_idx     <= 8'd0;
            rx_left    <= 8'd0;
            fill_ok    <= 1'b0;
            fill_chunk <= 4'd0;
            fill_word  <= '0;
        end else begin
            if (rx_hdr) begin
                rx_type <= msg_type;
                rx_idx  <= 8'd0;
                rx_left <= msg_len;
                if (msg_type == T_FD35_TRACK || msg_type == T_FD_TRACK) fill_ok <= 1'b0;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_track) begin
                    if (rx_idx == 8'd0) begin
                        fill_chunk <= w0_chunk[3:0];
                        fill_word  <= 12'(w0_chunk[3:0]) * 12'(CHUNK_WORDS);
                        // The chunk lands only if it answers the buffer's
                        // OWN seek: the right drive, track and seq.
                        fill_ok    <= is35 ? accept35 : accept525;
                    end else if (fill_ok) begin
                        if (rx_idx >= data_start) fill_word <= fill_word + 1'b1;
                    end
                end
            end
        end
    end
    // Word 1 of every 3.5" chunk: {chunks[7:0], 8'd0, nibbles[15:0]}.
    wire fill_w1  = word_track && is35 && (rx_idx == 8'd1) && fill_ok;
    // A 5.25" chunk's count is fixed; its first word says so.
    wire fill_w0_525 = word_track && is525 && (rx_idx == 8'd0) && accept525;

    // ---- card -> host: FD_DIRTY uploads, FD35_SEEK and FD_SEEK ------------------------
    // One stream, one message at a time.  A written track's upload goes
    // before any seek, so the host has the track before it could be asked
    // for it again - and, the buffer holding that track until the seek's
    // answer overwrites it, the upload reads it through port B while the
    // seek for the next one waits.
    typedef enum logic [2:0] {
        X_IDLE,
        X_HDR,          // a seek's header
        X_W0,           // ...and its word
        X_UP_HDR,       // an FD_DIRTY chunk's header
        X_UP_W0,        // ...its {seq, chunk, track, drive}
        X_UP_DATA       // ...its words, from the buffer
    } xstate_t;
    xstate_t     xs;
    logic [8:0]  tx_id;             // the seek being sent, latched as it starts
    logic [7:0]  tx_seq;
    logic [2:0]  x_chunk;
    logic [7:0]  x_left;            // data words still to send this chunk
    logic [11:0] x_word;            // the buffer word being offered

    wire [7:0] chunk_len = (x_chunk == 3'd6) ? 8'(D5_LAST) : 8'(CHUNK_WORDS);
    wire       xs_up     = (xs == X_UP_HDR) || (xs == X_UP_W0) || (xs == X_UP_DATA);

    // Port B reads the word being offered, and the one after it on the clock
    // it is taken, so the stream never waits on the RAM's latency.
    assign b_addr   = ((xs == X_UP_DATA) && tx_take) ? x_word + 12'd1 : x_word;

    assign tx_valid = (xs != X_IDLE);
    assign tx_word  = (xs == X_HDR)    ? {16'd0, (tx_id[8] ? T_FD_SEEK : T_FD35_SEEK), 8'd1}
                    : (xs == X_W0)     ? (tx_id[8] ? {tx_seq, 8'd0, 2'd0, tx_id[5:0], 7'd0, tx_id[7]}
                                                   : {tx_seq, 8'd0, tx_id[7:0], 8'd0})
                    : (xs == X_UP_HDR) ? {16'd0, T_FD_DIRTY, chunk_len + 8'd1}
                    : (xs == X_UP_W0)  ? {up_seq, 5'd0, x_chunk, 2'd0, up_id[5:0], 7'd0, up_id[7]}
                    :                    b_word;
    wire seek_sent = (xs == X_W0) && tx_take;
    wire up_sent   = (xs == X_UP_DATA) && tx_take && (x_left == 8'd1) && (x_chunk == 3'd6);
    always_ff @(posedge clk) begin
        if (rst) begin
            xs      <= X_IDLE;
            tx_id   <= 9'd0;
            tx_seq  <= 8'd0;
            x_chunk <= 3'd0;
            x_left  <= 8'd0;
            x_word  <= 12'd0;
        end else case (xs)
            X_IDLE: begin
                x_chunk <= 3'd0;
                x_word  <= 12'd0;
                if (up_owed) begin
                    xs <= X_UP_HDR;
                end else if (seek_owed) begin
                    xs     <= X_HDR;
                    tx_id  <= buf_id;
                    tx_seq <= seq;
                end
            end
            X_HDR:     if (tx_take) xs <= X_W0;
            X_W0:      if (tx_take) xs <= X_IDLE;
            X_UP_HDR:  if (tx_take) begin xs <= X_UP_W0; x_left <= chunk_len; end
            X_UP_W0:   if (tx_take) xs <= X_UP_DATA;
            X_UP_DATA: if (tx_take) begin
                x_word <= x_word + 12'd1;
                x_left <= x_left - 8'd1;
                if (x_left == 8'd1) begin
                    if (x_chunk == 3'd6) xs <= X_IDLE;
                    else begin x_chunk <= x_chunk + 3'd1; xs <= X_UP_HDR; end
                end
            end
            default: xs <= X_IDLE;
        endcase
    end

    // ---- the status multiplexer (iwm_read_status35) --------------------------
    //   stat35 = {phase[1], phase[0], $C031 bit 7, phase[2]}
    wire [3:0] stat35 = {phases[1], phases[0], c031_ctrl, phases[2]};
    logic status35;
    always_comb begin
        if (!t_motor) begin
            status35 = 1'b1;                 // "Read 3.5 status with drive off"
        end else begin
            case (stat35)
                4'h0: status35 = step_dir35;           // the step direction LATCH
                4'h1: status35 = pos[0];               // lower head: data under it
                4'h2: status35 = !disk_in;             // disk in place: 1 = NO DISK
                4'h3: status35 = pos[0];               // upper head: likewise
                4'h4: status35 = !(stepped && stale);  // 1 = not stepping
                4'h5: status35 = 1'b1;                 // ROM 3's unknown function
                4'h6: status35 = here && !drv_wp;      // 0 = locked (an empty drive reads locked)
                4'h8: status35 = !motor35;             // 0 = on, 1 = off (the IWM's latch)
                4'h9: status35 = 1'b1;                 // 1 = two sides
                4'hA: status35 = here && ((track35 != 7'd0) || side35);   // 1 = NOT at track 0
                4'hB: status35 = !motor35;             // ready: 0 = ready
                4'hC: status35 = 1'b0;                 // switched: 0 = not
                4'hD: status35 = 1'b1;                 // the false read when ejecting
                4'hE: status35 = pos[3];               // tachometer
                4'hF: status35 = drive_sel;            // installed: 0 = drive 0 exists
                default: status35 = 1'b1;
            endcase
        end
    end
    // A 5.25" drive's sense is its write protect (iwm.c:1137): the disk's
    // own, and PROTECTED with no disk in (an empty drive does in KEGS too).
    // UNDER ENABLE2 THE SENSE IS 1 FOR EITHER SIDE ("Read status under
    // enable2: 1"): phases 1 and 3 together address the SmartPort bus, the
    // drives are disabled, and bit 7 is a SmartPort device's ACK - which the
    // ROM's slot-5 probe polls at FF/581F.  A writable 5.25" disk read as 0
    // there answered for a device that is not there, and the ROM sat in that
    // loop and never booted slot 6 (2026-09-14, the first build with writes;
    // the drives had always read protected, which hid it).
    wire sense = enable2     ? 1'b1
               : apple35_sel ? status35
                             : (!d5_inserted[drive_sel] || d5_wp[drive_sel]);

    // KEGS: val = ((sense & 1) << 7) | (state & 0x3f): bit 5 is the IWM's
    // ENABLE latch, the mode in [4:0], bit 6 zero.
    wire [7:0] status_byte = {sense, 1'b0, t_motor, mode};
    wire [7:0] handshake   = (hs_count == 2'd3) ? 8'h80 : 8'hC0;

    // The stub's empty-5.25" register: a position that advances per read,
    // so the ROM's SmartPort probe sees a byte with bit 6 clear (KEGS's
    // `(fbit_pos*25)>>11` for a drive with no track).
    logic [23:0] fbit;
    wire [31:0] fbit_scaled = fbit * 24'd25;

    // ---- the data register -----------------------------------------------------
    logic [7:0] latch;              // the completed nibble
    logic       latch_valid;        // ...not yet read (latch mode)
    logic       half_gone;          // the hold since it completed has run out
    // The byte a data read returns: the held nibble, or the next shifting in.
    wire [7:0]  slot_val  = usable ? nxt : lfsr[7:0];
    wire [7:0]  partial   = slot_val >> (4'd8 - {1'b0, bits_in});
    // THE 5.25" HOLD (2026-09-13).  A 5.25" nibble is readable from the cycle
    // it completes until the read that takes it, or 24 cycles, whichever is
    // first - for either mode.  The Disk II's plain seven-cycle hold (and the
    // 3.5" side's, below) PHASE-LOCKED: the stream here is exactly periodic
    // (32 cycles, sync bytes included) and ProDOS 2.4.3's boot-block poll,
    // `LDA $C08C,X / BPL` across a page boundary, is exactly 8 cycles - four
    // polls a nibble, always landing 7.4 cycles after it completed, 0.4 past
    // the hold, so after one D5 the loop missed every nibble for ever (the
    // bench's trace at instruction 1,308,597).  A real drive's ten-bit sync
    // bytes and its jitter keep the phase moving; a cycle-exact stream cannot.
    // Clear-on-read keeps a search that polls again five cycles after a hit
    // (`CMP #$D5 / BNE`) from seeing the same nibble twice; 24 cycles is well
    // before the next nibble at 32.  A deliberate departure from the Disk II
    // and from KEGS's non-latch arm, docs/IWM35.md.
    wire        held      = !apple35_sel ? (latch_valid && !half_gone)
                          : mode[0]      ? latch_valid : !half_gone;
    wire [7:0]  hold_len  = apple35_sel ? {1'b0, P35[7:1]} : HOLD525;
    wire [7:0]  data_byte = (apple35_sel || d5_inserted[drive_sel]) ? (held ? latch : partial)
                                                                    : fbit_scaled[18:11];

    wire data_read = act && op_rw && !op_lo[0] && (q7q6 == 2'b00) && !enable2 && t_motor;

    always_comb begin
        if (op_lo[0]) begin
            rd_byte = 8'h00;            // an odd address reads zero
        end else begin
            case (q7q6)
                2'b00:   rd_byte = enable2 ? 8'hFF
                                 : t_motor ? data_byte
                                           : 8'hFF;
                2'b01:   rd_byte = status_byte;
                // Bit 6 is the write underrun, clear with nothing writing.
                2'b10:   rd_byte = enable2 ? handshake : 8'h80;
                default: rd_byte = 8'h00;
            endcase
        end
    end

    // ---- it has to be one of ours ----------------------------------------------
    // `act` fires for every register gs_io claims; the decode below reads
    // op_lo[3:1] only, so the page is checked here.
    wire iwm_act = act && (op_lo[7:4] == 4'hE);

    // The phase-3 strobe: the action fires on every touch of $C0E7 with the
    // motor on and the 3.5" path selected, indexed by the phases as they
    // stand (this access touched phase 3, not one of the index bits).
    wire action = iwm_act && (op_lo[3:1] == 3'd3) && op_lo[0] && motor_on && apple35_sel;
    // The two head selects, on a status read.
    wire status_read = iwm_act && op_rw && !op_lo[0] && (q7q6 == 2'b01) && !enable2 &&
                       t_motor && apple35_sel && here;
    wire sel_lower = status_read && (stat35 == 4'h1);
    wire sel_upper = status_read && (stat35 == 4'h3);
    wire do_step   = action && (stat35 == 4'h4) && here;   // drive 2 has no head to move
    wire [6:0] track_stepped = step_dir35 ? (track35 == 7'd0  ? 7'd0  : track35 - 7'd1)
                                          : (track35 == 7'd79 ? 7'd79 : track35 + 7'd1);

    // The 5.25" stepper: a phase access with the 5.25" side selected starts
    // the ten-cycle wait; when it runs out the selected drive's cog moves
    // toward the one energised neighbour.
    wire        phase_access5 = iwm_act && !op_lo[3] && !apple35_sel;
    wire        step_now      = tick && (step_timer == 4'd1);
    wire [1:0]  cog      = hp_sel[1:0];
    wire        mag_up   = phases[cog + 2'd1];
    wire        mag_down = phases[cog + 2'd3];
    logic [6:0] hp_new;
    always_comb begin
        hp_new = hp_sel;
        if (mag_up && !mag_down && hp_sel != 7'd79) hp_new = hp_sel + 7'd1;
        if (mag_down && !mag_up && hp_sel != 7'd0)  hp_new = hp_sel - 7'd1;
    end
    wire        step5 = step_now && spinning && !apple35_sel;

    // Insertions, remembered until their side is in use: the drive fetches
    // its track the first time it is selected with the disk in.
    logic       ins_prev;
    logic [1:0] ins5_prev;
    logic       ins_pend;           // the 3.5" drive
    logic [1:0] ins5_pend;          // the 5.25" drives
    wire        ins_edge  = drv_inserted && !ins_prev;
    wire        ej_edge   = !drv_inserted && ins_prev;
    wire [1:0]  ins5_edge = d5_inserted & ~ins5_prev;
    wire [1:0]  ej5_edge  = ~d5_inserted & ins5_prev;
    wire        pend_tgt  = apple35_sel ? ins_pend : ins5_pend[drive_sel];
    // The buffer's own disk left.
    wire        buf_ejected = buf_id[8] ? ej5_edge[buf_id[7]] : ej_edge;

    // A new track is wanted from the host: the drive in use has a disk and
    // the buffer is not its track, or it was just put in, or a stale fill
    // was never answered.
    assign want = tgt_in && ((tgt_id != buf_id) || pend_tgt ||
                  (stale && !seek_owed && (xs == X_IDLE) && (retry_clks == 22'd0)));
    wire  filled = chunk_done && (chunks_total != 4'd0) &&
                   ((chunks_r | (16'd1 << fill_chunk)) == ((16'd1 << chunks_total) - 16'd1));

    // ---- the machine's writes (5.25") ------------------------------------------------
    // A data write (write_iwm: Q7 and Q6 set after the touch, the motor on,
    // not ENABLE2) on a writable disk whose track is in the buffer.  Not on
    // the clock a new track is wanted - the buffer is leaving - and not under
    // a fill, which has the port.
    assign store = iwm_act && !op_rw && op_lo[0] && (q7q6 == 2'b11) && t_motor && !enable2 &&
                   !apple35_sel && usable && buf_id[8] && !d5_wp[drive_sel] &&
                   !want && !fill_write;

    // THE WRITE BURST LANDS CONTIGUOUSLY.  A burst's first byte goes in the
    // slot under the head; every byte after it goes in the slot after the
    // last one, wherever the head has got to - as long as the head is within
    // BURST_MAX_GAP slots of it either way (further, and it is a new burst,
    // at the head).  A slot is eight bits.  A byte written slower than 32
    // cycles is a nine- or ten-bit cell whose extra zero bits no reader ever
    // takes for a nibble, so they take no slot: the burst falls a little
    // behind the head, which is harmless, and never gets ahead of it.
    //   The first write build did the Disk II card's rule (rtl/floppy_card.sv):
    // every byte in the slot under the head, a slot the burst skipped filled
    // with $FF.  Right for a run of 40-cycle sync bytes; WRONG at DOS 3.3's
    // two 36-cycle steps - the last sync to $D5, and the data prologue's $AD
    // to the first data nibble (RWTS WRITE16: ORA, RTS, TYA, LDY, BNE, EOR
    // abs,Y across a page, TAX, LDA abs,X, LDX, STA).  The write starts a fixed
    // time after the address field was read, so the phase is the same every
    // time, and at the phase this drive's read hold leaves it the second step
    // crossed a slot boundary: a phantom $FF at the head of every data field.
    // Every sector SAVE wrote on the card decoded one byte late and
    // complemented, and DOS said I/O ERROR (2026-09-14).
    logic        wr_burst;
    logic [13:0] wr_last;

    // Slots from the last store to the head, on the circle.
    wire [14:0] gap_raw    = {1'b0, pos} - {1'b0, wr_last};
    wire [13:0] gap        = gap_raw[14] ? (gap_raw[13:0] + nibbles) : gap_raw[13:0];
    wire [13:0] wr_last_p1 = (wr_last + 14'd1 >= nibbles) ? 14'd0 : wr_last + 14'd1;
    wire        contig     = wr_burst && ((gap <= 14'(BURST_MAX_GAP)) ||
                                          (gap >= nibbles - 14'(BURST_MAX_GAP)));
    wire [13:0] wr_slot    = contig ? wr_last_p1 : pos;
    wire        burst_end  = (iwm_act && ((op_lo[3:0] == 4'hE) || (op_lo[3:1] == 3'd5))) ||
                             (step5 && (hp_new != hp_sel)) || want;

    // Port A, in this priority: the host's fill (a word), a store (a byte),
    // else the standing read of the head's word.
    assign a_read  = !fill_write && !store;
    assign a_addr  = fill_write ? fill_word
                   : store      ? wr_slot[13:2]
                   :              pos[13:2];
    assign a_we    = fill_write ? 4'hF
                   : store      ? (4'd1 << wr_slot[1:0])
                   :              4'h0;
    assign a_wdata = fill_write ? pay_data : {4{op_wdata}};

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            wr_burst <= 1'b0;
            wr_last  <= 14'd0;
        end else begin
            if (store) begin
                wr_last  <= wr_slot;
                wr_burst <= 1'b1;
            end
            if (burst_end) wr_burst <= 1'b0;
        end
    end

    // The events that end the buffer's claim on a written 5.25" track.
    wire motor_stop = motor_prev && !motor_on;
    wire d5_leave   = buf_id[8] && (want || buf_ejected || d5_flush[buf_id[7]] || motor_stop);
    wire flush      = d5_leave && dirty;

    always_ff @(posedge clk) begin
        if (rst) begin
            stale       <= 1'b1;
            buf_id      <= 9'd0;
            seq         <= 8'd0;
            nibbles35   <= 14'd9694;
            chunks_r    <= 16'd0;
            chunks_total <= 4'd0;
            seek_owed   <= 1'b0;
            read_stale  <= 1'b0;
            retry_clks  <= 22'd0;
            us_pre      <= 7'd0;
            fill_us     <= 16'd0;
            ins_prev    <= 1'b0;
            ins5_prev   <= 2'd0;
            ins_pend    <= 1'b0;
            ins5_pend   <= 2'd0;
            stepped     <= 1'b0;
            seeks       <= 8'd0;
            late        <= 8'd0;
            fill_max    <= 16'd0;
            dirty       <= 1'b0;
            up_owed     <= 1'b0;
            up_again    <= 1'b0;
            up_id       <= 9'd0;
            up_seq      <= 8'd0;
            motor_prev  <= 1'b0;
        end else begin
            ins_prev  <= drv_inserted;
            ins5_prev <= d5_inserted;
            motor_prev <= motor_on;
            if (ins_edge) ins_pend <= 1'b1;
            if (ej_edge)  ins_pend <= 1'b0;
            ins5_pend <= (ins5_pend | ins5_edge) & ~ej5_edge;
            if (stale && retry_clks != 22'd0) retry_clks <= retry_clks - 22'd1;
            us_pre <= (us_pre == 7'd99) ? 7'd0 : us_pre + 7'd1;
            if (stale && (us_pre == 7'd99) && fill_us != 16'hFFFF) fill_us <= fill_us + 16'd1;

            // Leaving a written track: it goes to the host, with the seq that
            // filled it, before anything else goes out.  A flush while an
            // upload is still going out - the machine wrote again behind it -
            // sends the track once more when that one is done.
            if (up_sent) begin
                up_owed  <= up_again || flush;
                up_again <= 1'b0;
            end else if (flush) begin
                if (xs_up) up_again <= 1'b1;
                else       up_owed  <= 1'b1;
            end
            if (flush) begin
                up_id  <= buf_id;
                up_seq <= seq;
            end
            if (d5_leave) dirty <= 1'b0;
            if (store)    dirty <= 1'b1;

            if (buf_ejected) stale <= 1'b1;
            if (do_step) stepped <= 1'b1;
            if (want) begin
                stale      <= 1'b1;
                buf_id     <= tgt_id;
                seek_owed  <= 1'b1;
                seq        <= seq + 8'd1;
                chunks_r   <= 16'd0;
                chunks_total <= 4'd0;
                retry_clks <= 22'(FILL_RETRY_CLKS);
                fill_us    <= 16'd0;
                read_stale <= 1'b0;
                seeks      <= seeks + 8'd1;
                if (apple35_sel) ins_pend <= 1'b0;
                else             ins5_pend[drive_sel] <= 1'b0;
            end
            if (seek_sent) seek_owed <= 1'b0;

            // The track arriving.
            if (fill_w1) begin
                chunks_total <= pay_data[27:24];
                nibbles35    <= pay_data[13:0];
            end
            if (fill_w0_525) chunks_total <= 4'(D5_CHUNKS);
            if (chunk_done) chunks_r <= chunks_r | (16'd1 << fill_chunk);
            if (filled) begin
                stale   <= 1'b0;
                stepped <= 1'b0;
                if (read_stale && late != 8'hFF) late <= late + 8'd1;
                if (fill_us > fill_max) fill_max <= fill_us;
            end
            if (data_read && stale && tgt_in) read_stale <= 1'b1;
            if (late_clr) late <= 8'd0;
            if (fill_clr) fill_max <= 16'd0;
        end
    end

    // ---- the platter, per cycle ---------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            pos         <= 14'd0;
            nib_acc     <= 8'd0;
            lfsr        <= 16'hACE1;
            latch       <= 8'd0;
            latch_valid <= 1'b0;
            half_gone   <= 1'b1;
        end else begin
            if (tick) lfsr <= {lfsr[14:0], lfsr_fb};
            if (tick && spinning) begin
                if (complete) begin
                    nib_acc <= nib_acc + 8'd5 - nib_period;
                    pos     <= (pos + 14'd1 >= nibbles) ? 14'd0 : pos + 14'd1;
                    latch       <= slot_val;
                    latch_valid <= 1'b1;
                    half_gone   <= 1'b0;
                end else begin
                    nib_acc <= nib_acc + 8'd5;
                    if (nib_acc + 8'd5 >= hold_len) half_gone <= 1'b1;
                end
            end
            // Read once: the nibble is spent.
            if (data_read && latch_valid) latch_valid <= 1'b0;
        end
    end

    // ---- the switches and the drives, per access -------------------------------
    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            mode <= 5'd0;
            phases <= 4'd0;
            motor_on <= 1'b0;
            motor_off_pend <= 1'b0;
            motor_off_ticks <= 22'd0;
            step_dir35 <= 1'b0; motor35 <= 1'b0; track35 <= 7'd0; side35 <= 1'b0;
            hp[0] <= 7'd0; hp[1] <= 7'd0;
            step_timer <= 4'd0;
            drive_sel <= 1'b0;
            q6 <= 1'b0; q7 <= 1'b0;
            hs_count <= 2'd0;
            fbit <= 24'd0;
            cnt_mode_wr <= 8'd0;
        end else begin
            // The motor-off timer (iwm_vbl_update): ENABLE drops a second
            // after $C0E8 unless the mode register says at once.
            if (motor_off_pend && tick) begin
                if (motor_off_ticks == 22'd0) begin
                    motor_on <= 1'b0;
                    motor_off_pend <= 1'b0;
                end else begin
                    motor_off_ticks <= motor_off_ticks - 22'd1;
                end
            end

            // The 5.25" cog, ten cycles after the last phase access.
            if (tick && step_timer != 4'd0) step_timer <= step_timer - 4'd1;
            if (step5) hp[drive_sel] <= hp_new;

            if (iwm_act) begin
                // ---- every access touches its switch first ----------------
                case (op_lo[3:1])
                    3'd0, 3'd1, 3'd2, 3'd3:
                        phases[op_lo[2:1]] <= op_lo[0];
                    3'd4: begin
                        if (op_lo[0]) begin
                            motor_on <= 1'b1;
                            motor_off_pend <= 1'b0;
                        end else if (mode[2]) begin
                            motor_on <= 1'b0;
                            motor_off_pend <= 1'b0;
                        end else if (motor_on && !motor_off_pend) begin
                            motor_off_pend <= 1'b1;
                            motor_off_ticks <= 22'(MOTOR_OFF_TICKS);
                        end
                    end
                    3'd5: drive_sel <= op_lo[0];
                    3'd6: q6        <= op_lo[0];
                    default: q7     <= op_lo[0];
                endcase
                if (phase_access5) step_timer <= STEP_TICKS;

                // ---- the 3.5" ACTION (iwm_do_action35) ----------------------
                if (action) begin
                    case (stat35)
                        4'h0: step_dir35 <= 1'b0;   // step inward, higher tracks
                        4'h1: step_dir35 <= 1'b1;   // step outward, lower tracks
                        4'h3: ;                     // reset the disk-switched flag
                        4'h4: if (here) track35 <= track_stepped;
                        4'h8: motor35 <= 1'b1;      // the drive's motor on
                        4'h9: motor35 <= 1'b0;      // ...and off
                        4'hD: ;                     // eject: nothing to eject
                        default: ;                  // KEGS ignores $02, $07, $0B
                    endcase
                end
                // ---- the head select, on a status read ----------------------
                if (sel_lower) side35 <= 1'b0;
                if (sel_upper) side35 <= 1'b1;

                // ---- then the data path -----------------------------------
                if (!op_rw && op_lo[0] && (q7q6 == 2'b11) && !t_motor) begin
                    mode <= op_wdata[4:0];          // the MODE register
                    cnt_mode_wr <= cnt_mode_wr + 8'd1;
                end
                if (op_rw && !op_lo[0] && !enable2 && t_motor && (q7q6 == 2'b00) && !apple35_sel)
                    fbit <= fbit + 24'd1024;
                if (op_rw && !op_lo[0] && enable2 && (q7q6 == 2'b10)) begin
                    if (hs_count == 2'd3) hs_count <= 2'd0;
                    else                  hs_count <= hs_count + 2'd1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // The data reads each side served from a disk, the 5.25" bytes written
    // and the tracks sent home: the benches print them.
    integer rd35 = 0, rd525 = 0, wr525 = 0, up525 = 0;
    always @(posedge clk)
        if (!rst) begin
            if (data_read && usable) begin
                if (apple35_sel) rd35  <= rd35 + 1;
                else             rd525 <= rd525 + 1;
            end
            if (store)   wr525 <= wr525 + 1;
            if (up_sent) up525 <= up525 + 1;
        end
`endif

    // The reset line the phases can assert is decoded but drives nothing.
    wire _unused = &{1'b0, iwm_reset, nib5_sel,
                     op_wdata[7:5], fbit_scaled[31:19], fbit_scaled[10:0], 1'b0};
endmodule
