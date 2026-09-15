`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// floppy_card - a Disk II controller's slot and its two drives, on the card
// that IS the CPU, with the disk images on the host.
//
// The controller is AppleWin's (source/Disk.cpp), the project's reference:
// the P5A boot ROM at $Cn00, sixteen soft switches at $C0n0-$C0nF that a
// 74LS259 latches, and a data register the software polls for nibbles.
// This module carries everything the BUS can see and the whole of the
// timing; the host keeps the images.  See docs/FLOPPY.md.
//
// THE TRACK IS A BIT STREAM (branch woz_support, 2026-09-14).  Until now the
// buffer held nibbles and the register took one whole every 32 cycles -
// AppleWin's non-WOZ path.  Now it holds the track as the head sees it, a
// bit per cell, and the register is the logic state sequencer's shift
// register, fed one bit per cell - AppleWin's WOZ path (DataLatchReadWOZ,
// DataShiftWriteWOZ, ControlStepperDeferred), the physical one.  Every
// image format goes through this one engine: a WOZ's tracks are bit
// streams already, and a sector or nibble image's are its nibbles' bits,
// eight per nibble, which is exactly what those formats can express.  So
// quarter tracks, timing bits, weak bits and the 10-bit sync nibbles a
// track INIT writes are all just bits in the buffer, and the card knows
// nothing about formats.
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
// is selected.  Ten cycles after a phase access (AppleWin's deferral,
// GH#1110) the head is evaluated against the magnets as they are then, in
// QUARTER TRACKS: one energised magnet adjacent to the cog pulls the head a
// half track (two quarters) toward it, two adjacent magnets on together
// hold it a quarter track toward the pair, and the quarter offset lasts
// only while that pair is energised.  Eighty half-track phases, 160
// quarter-track positions; the head moves only while the drive is enabled
// or still coasting.  Motor off starts a one-second coast (SPIN_TICKS)
// during which the disk still reads and the head still steps; deselecting
// a drive coasts it the same way, as the drive's own enable line would.
//
// THE PLATTER.  A bit cell is the image's optimal bit timing in eighths
// of a CPU cycle (32 = four cycles, the standard; off-speed masters say 31
// or 33) - the Disk II's sequencer runs off the Apple's own 2 MHz, so a
// cell is a count of cycles, which is why every RWTS loop is written to
// 32 a nibble.  The platter keeps a fixed-point accumulator: TICK_UNITS
// per cycle, the timing byte's worth per bit, a bit whenever it overflows
// - AppleWin's m_extraCycles, in integers.  Each drive's position is a bit
// offset into its track that persists across seeks and drive switches,
// wrapping at the track's own bit count.
//
// THE DATA REGISTER, in read mode: the LSS.  Every cell the bit under the
// head enters a four-bit window; the bit the sequencer sees is the one
// before it, unless the window is all zeros, when the MC3470 has nothing
// to lock on and the sequencer sees noise - a 1 about 30% of the time
// (WOZ 2.0's rule; AppleWin's RAND_THRESHOLD(3, 10)).  The bit shifts into
// the register.  When the register's high bit lands the latch takes it and
// holds it for 7 us - one cell, plus the second cell's decrement leaves it
// - then follows the register again, high bit clear, shifting in; zeros
// arriving while the latch holds extend the hold (a zero-filled register,
// GH#662), which is how the sync gap's extra zeros are absorbed.  That
// window is why the RWTS's `LDA $C0EC,X / BPL` loop reads every nibble
// exactly once.  A stopped drive holds the register.  A drive with no disk
// - or a position with no track on it - reads $80 for the first 0x2EC
// cycles after it starts, noise after (AppleWin's GH#864/GH#748; the noise
// is the window rule on a stream of zeros).
//
// THE DATA REGISTER, in write mode.  A store with Q6 and Q7 both set loads
// the shift register (the 74LS323's LD, any address in the page), and from
// that first load on, in write mode every cell - whatever Q6 says - writes
// the register's high bit at the head and shifts a zero in: the byte goes
// out at the cell rate, a 40-cycle sync $FF writes its eight ones and two
// zeros, and nothing here counts nibbles or fills slots.  A write-protected
// disk, or a stopped drive, takes nothing.  $C0nD with Q7 clear samples
// write-protect into the register as $FF or $00, and the $C0nE read that
// follows delivers it in bit 7.
//
// THE CYCLES ARE THE CORE'S.  A cycle here is one op of the core - a bus
// cycle that carried one, an override's, or a fast op the accelerated core
// took from the card (rtl/accel_seq.sv, docs/ACCELERATION.md) - and never a
// dummy cycle the bus ran with no op on it.  With the core locked to the bus
// that is one tick per bus cycle; with it accelerated the platter turns as
// fast as the core runs, so every loop counted in cycles sees the count it
// always saw.  There is no drive on the card, only a track in BRAM: nothing
// here is real time, and the one clock the fiction has to keep is the
// program's.  fill_max and late are in these ticks too.
//
// THE TRACK IS ON THE CARD; THE DISK IS ON THE HOST.  There is ONE track
// of buffer (6656 bytes, 53,248 bits - a WOZ's largest 5.25" track is 13
// blocks, exactly that, in BRAM), shared by the two drives and tagged with
// whose track it holds - only one drive is ever live: the phases and the
// enable reach the selected drive alone.  A head movement to a new quarter
// track, a disk inserted, or the SELECT MOVING TO THE OTHER DRIVE marks the
// buffer STALE and sends the host an FD_SEEK {drive, quarter track, phase,
// seq}; the host answers with seven FD_TRACK chunks - each {seq, chunk,
// qtr, drive} then {bits}, the track's bit count, then the bytes - written
// straight into the buffer as they arrive, and the seventh clears STALE.  A
// bit count of zero is a position with no track on it (a WOZ's unmapped
// quarter track): the head reads noise there, as it would.  While the
// buffer is stale the register serves noise, never a wrong track.  `seq` is
// bumped per seek and a chunk with the wrong one is dropped.  A buffer that
// was written to is DIRTY, and before its track is left - the head moving,
// the select switching, the drive spinning down, an eject, or the host
// asking - it goes back to the host as seven FD_DIRTY chunks with the same
// two header words, before the FD_SEEK for the new track.
//
// THE CARD MEASURES ITS OWN LATENESS.  `fill_max` is the longest a fill has
// taken, from the head movement to the seventh chunk, in ticks; `late`
// counts the fills that completed after the machine had already tried to
// read the track.  See docs/FLOPPY.md.
//
// WHAT THIS CARD NEVER DOES: take a bus cycle.  No override, no stall.
// Everything the host is involved in happens beside the read stream.
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
    input  wire        op_dummy,       // this bus cycle carried no op: no tick
    // A fast op of the accelerated core completed: a tick of the core's
    // time that the bus never saw.  Tied low without the sequencer.
    input  wire        fast_tick,

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
    // of the packed fields are drive 1's.  The cell is the disk's bit
    // timing in eighths of a cycle, [7:0] of the 13-bit field (32 = four).
    // flush is a pulse per drive.
    input  wire [1:0]  drv_inserted,
    input  wire [1:0]  drv_wp,
    input  wire [25:0] drv_cell,
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
    output logic [15:0] fill_max,
    // The selected drive is turning with a disk in it and the buffer is not
    // its track yet: the accelerated core must wait for the fill rather
    // than read noise (rtl/accel_seq.sv stall; docs/VIRTUAL_TIME.md).  Not
    // a bus-cycle matter: mode 0 never sees it.
    output wire        stall_o
);

    // ---- geometry ------------------------------------------------------------
    localparam integer TRACK_BYTES = 6656;           // 0x1A00: a WOZ's 13 blocks, a .nib track
    localparam integer TRACK_WORDS = TRACK_BYTES / 4; // 1664
    localparam integer CHUNK_WORDS = 252;            // data words per FD_TRACK / FD_DIRTY
    localparam integer LAST_CHUNK_WORDS = TRACK_WORDS - 6 * CHUNK_WORDS;   // 152
    localparam integer HDR_WORDS   = 2;              // {seq,chunk,qtr,drive}, {bits}
    localparam integer STEP_TICKS  = 10;             // magnet write -> cog moves
    // The platter's clock: units of a 128th of the WOZ's 125 ns.  The Disk
    // II's sequencer runs off the Apple's own 2 MHz, so its bit cell is a
    // fixed number of CPU cycles, not of nanoseconds: the WOZ timing byte
    // counts eighths of a cycle, and a core cycle is 8 x 128 = 1024 of
    // these.  At the standard 32 a cell is 4096: exactly four cycles a bit,
    // 32 a nibble, the count every RWTS loop is written to; at 31 or 33 a
    // master that ran off-speed gets its 3.875 or 4.125.  (AppleWin's
    // GetBitCellDelta divides cycles by 0.125 x timing, the same rule.)
    localparam integer TICK_UNITS  = 1024;
    // A drive's bit count until a fill says otherwise: 6384 nibbles' worth.
    localparam integer DEFAULT_BITS = 6384 * 8;
    // The latch's hold after a full byte, in microseconds: AppleWin's 7,
    // decremented 4 per cell.
    localparam [2:0] LATCH_HOLD = 3'd7;

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

    // The core's clock: one tick per op - a bus cycle that carried one,
    // override cycles included (the platter turns during a DMA too), and
    // every fast op.  Never a dummy.  See the header.
    wire tick = enabled && ((op_commit && !op_dummy) || fast_tick);
    wire page_commit = op_commit && hit_page;

    // ---- the controller's latches ---------------------------------------------
    // The 74LS259: cleared by RES'.
    logic [3:0] magnets;
    logic       motor;
    logic       drive_sel;
    logic       q6, q7;
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
    // The PLATTERS are per drive, indexed by drive number; the selected one
    // is `s`.  The BUFFER is one, tagged with whose track it holds.
    wire s = drive_sel;

    logic [6:0]  phase     [0:1];       // 0..79, two per track
    logic signed [1:0] qoff [0:1];      // -1, 0, +1 quarter track, while a pair holds
    logic [19:0] spin      [0:1];       // ticks of coast left; 0 = stopped
    logic [9:0]  stable    [0:1];       // ticks since the drive started, saturating
    logic [15:0] bpos      [0:1];       // the bit under the head
    logic [15:0] tbits     [0:1];       // the bits its track turns over
    logic [15:0] acc       [0:1];       // the cell accumulator
    logic        ins_prev  [0:1];       // for the insert / eject edges

    // The one buffer's state.
    logic        buf_drive;             // whose track the buffer holds
    logic        stale;                 // the buffer is not that track yet
    logic        dirty;                 // the buffer was written to
    logic [7:0]  seq;                   // the seek the host is answering
    logic [7:0]  buf_qtr;               // the quarter track the buffer is for
    logic [15:0] buf_bits;              // the bits in it; 0 = no track here
    logic [6:0]  chunks_r;              // FD_TRACK chunks landed for `seq`
    logic [15:0] fill_ticks;            // ticks since the buffer went stale
    logic        read_stale;            // the machine read while stale
    logic        seek_owed;             // an FD_SEEK is to be sent
    logic        up_owed;               // an FD_DIRTY upload is to be sent
    logic        up_drive;              // ...for this drive
    logic [7:0]  up_qtr;                // ...and this quarter track
    logic [7:0]  up_seq;                // ...as filled by this seek
    logic [15:0] up_bits;               // ...turning over this many bits

    wire [7:0]  bcell    [0:1];
    wire [5:0]  tracks  [0:1];
    assign bcell[0]   = drv_cell[7:0];
    assign bcell[1]   = drv_cell[20:13];
    assign tracks[0] = drv_tracks[5:0];
    assign tracks[1] = drv_tracks[11:6];

    // The quarter-track position of a drive: 2 * phase + the quarter
    // offset, never below zero (AppleWin's newPhasePrecise).
    function automatic [7:0] qpos_of(input [6:0] ph, input signed [1:0] qo);
        logic signed [9:0] q;
        begin
            q = $signed({3'd0, ph}) * 10'sd2 + $signed({{8{qo[1]}}, qo});
            qpos_of = (q < 10'sd0) ? 8'd0 : q[7:0];
        end
    endfunction
    wire [7:0] qpos [0:1];
    assign qpos[0] = qpos_of(phase[0], qoff[0]);
    assign qpos[1] = qpos_of(phase[1], qoff[1]);

    assign phase_o = {phase[1], phase[0]};
    // The buffer's drive reports the buffer's state; the other drive is,
    // truthfully, a drive whose track is not buffered.
    assign stale_o = {buf_drive ? stale : 1'b1, buf_drive ? 1'b1 : stale};
    assign dirty_o = {buf_drive && dirty, !buf_drive && dirty};

    // The selected drive is turning: enabled by the motor, or coasting.
    wire spinning = (spin[s] != 20'd0);
    // The buffer is the selected drive's and holds the track under its head.
    wire usable   = drv_inserted[s] && !stale && (buf_drive == s);
    assign stall_o = enabled && motor && drv_inserted[s] && !usable;
    // A fill is expected: the host owes the buffer a track.
    wire filling  = stale && drv_inserted[buf_drive] && (buf_qtr[7:2] < tracks[buf_drive]);

    // Noise: a 16-bit LFSR stepped per tick.  The MC3470's, and the empty
    // drive's.
    logic [15:0] lfsr;
    wire         lfsr_fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    // ---- the track buffer -----------------------------------------------------------
    // Four byte lanes (rtl/fd_bank.sv): byte i in bank i[1:0] at index
    // i[12:2].  Port A is the bus side, a word at a time through the four
    // lanes; port B the link side, a word at a time.  One buffer for both
    // drives - see the header.
    wire         a_we    [0:3];
    wire  [10:0] a_addr;
    wire  [7:0]  a_wdata;
    wire  [7:0]  a_rdata [0:3];
    wire         b_we;
    wire  [10:0] b_addr;
    wire  [7:0]  b_rdata [0:3];

    genvar gk;
    generate
        for (gk = 0; gk < 4; gk = gk + 1) begin : g_bank
            fd_bank #(.DEPTH (TRACK_WORDS)) u_bank (
                .clk     (clk),
                .a_we    (a_we[gk]),
                .a_addr  (a_addr),
                .a_wdata (a_wdata),
                .a_rdata (a_rdata[gk]),
                .b_we    (b_we),
                .b_addr  (b_addr),
                .b_wdata (pay_data[8*gk +: 8]),
                .b_rdata (b_rdata[gk])
            );
        end
    endgenerate

    // ---- the head's window on the buffer -------------------------------------------
    // Port A reads the word under the head and the word after it on
    // alternate clocks into two tagged registers, so the bit under the head
    // is always in one of them - a word boundary crossed is a word already
    // read - and a bit written lands in the RAM and in the copies in the
    // same clock.  A bit cell is four clocks at the least (a tick a clock
    // under turbo, 4.09 ticks a cell), the refresh two.
    wire [15:0] hpos    = bpos[s];
    wire [10:0] hword   = hpos[15:5];
    wire [1:0]  hbyte   = hpos[4:3];
    wire [2:0]  hbit    = 3'd7 - hpos[2:0];
    // The word after the head's, on the circle: the track's last word is
    // followed by its first.  A track's last bit may sit mid-word; the
    // wrap of bpos to 0 makes word 0 the head's then.
    wire [15:0] tlast   = tbits[s] - 16'd1;
    wire [10:0] lword   = tlast[15:5];
    wire [10:0] hword_p1 = (hword == lword) ? 11'd0 : hword + 11'd1;

    logic [31:0] win_q   [0:1];
    logic [10:0] win_tag [0:1];
    logic        win_v   [0:1];
    logic        rd_sel_q;              // which window the next read is for
    logic        rd_dst_q;              // ...and last clock's
    logic        rd_v_q;                // last clock issued a read
    logic [10:0] rd_tag_q;

    // The write: one bit at the head, as a read-modify-write of its byte
    // from the window copy.  Held in `wpend` until a window has the byte,
    // which is at most two clocks and never long enough for the head to
    // move (a cell is four clocks or more).
    logic        wpend;
    logic        wpend_bit;
    logic [15:0] wpend_pos;
    wire  [10:0] wword = wpend_pos[15:5];
    wire  [1:0]  wbyte = wpend_pos[4:3];
    wire  [2:0]  wbit  = 3'd7 - wpend_pos[2:0];
    wire         w_in0 = win_v[0] && (win_tag[0] == wword);
    wire         w_in1 = win_v[1] && (win_tag[1] == wword);
    wire  [31:0] wwin  = w_in0 ? win_q[0] : win_q[1];
    wire  [7:0]  wold  = wwin[8 * wbyte +: 8];
    wire  [7:0]  wnew  = wpend_bit ? (wold | (8'd1 << wbit)) : (wold & ~(8'd1 << wbit));
    wire         w_go  = wpend && (w_in0 || w_in1);

    // The byte under the head, from whichever window has it.
    wire         h_in0 = win_v[0] && (win_tag[0] == hword);
    wire         h_in1 = win_v[1] && (win_tag[1] == hword);
    wire  [31:0] hwin  = h_in0 ? win_q[0] : win_q[1];
    wire  [7:0]  hbyte_v = hwin[8 * hbyte +: 8];
    wire         h_ok    = h_in0 || h_in1;

    assign a_addr  = w_go ? wword : (rd_sel_q ? hword : hword_p1);
    assign a_wdata = wnew;
    genvar gw;
    generate
        for (gw = 0; gw < 4; gw = gw + 1) begin : g_awe
            assign a_we[gw] = w_go && (wbyte == gw[1:0]);
        end
    endgenerate

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

    // The chunk being filled: {seq, chunk, qtr, drive} is its first word,
    // {bits} its second.
    logic       fill_ok;                // the seq matched: the words land
    logic       fill_drive;
    logic [2:0] fill_chunk;
    logic [10:0] fill_word;             // where the next word goes
    logic [15:0] fill_bits;

    wire        w0_drive = pay_data[0];
    wire [7:0]  w0_chunk = pay_data[23:16];
    wire [7:0]  w0_seq   = pay_data[31:24];
    wire [10:0] w0_base  = {3'd0, w0_chunk[2:0]} * CHUNK_WORDS[10:0];

    wire fill_write = word_track && (rx_idx >= HDR_WORDS[7:0]) && fill_ok &&
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
            fill_bits  <= 16'd0;
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
                        // The chunk lands only if it answers the buffer's
                        // OWN seek: right drive, right seq.  A drive switch
                        // bumps seq, so a late answer for the other drive's
                        // track changes nothing.
                        fill_ok    <= (w0_chunk < 8'd7) &&
                                      (w0_drive == buf_drive) &&
                                      (w0_seq == seq) &&
                                      drv_inserted[w0_drive];
                    end else if (rx_idx == 8'd1) begin
                        if (fill_ok) fill_bits <= pay_data[15:0];
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
        X_UP_W0,        // its {seq, chunk, qtr, drive}
        X_UP_W1,        // its {bits}
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
    wire [7:0] x_msg_len  = chunk_len + HDR_WORDS[7:0];

    // Port B reads the word being offered, and the one after it on the
    // clock it is taken, so the stream never stalls for the RAM's latency.
    // The fill's writes take the port when they come; by the protocol they
    // cannot come mid-upload - the seek that provokes them is sent only
    // after the upload finishes.
    wire [10:0] x_word_next = ((xs == X_UP_DATA) && tx_take) ? x_word + 11'd1 : x_word;

    assign b_we   = fill_write;
    assign b_addr = b_we ? fill_word : x_word_next;

    wire [31:0] x_data = {b_rdata[3], b_rdata[2], b_rdata[1], b_rdata[0]};

    // The seek names the quarter track AND the half-track phase, so a host
    // serving a sector image can keep AppleWin's integer rule (phase >> 1)
    // and a host serving a WOZ can map the quarter track through TMAP.
    wire [31:0] x_seek_w0 = {seq, 8'd0, buf_qtr, phase[buf_drive], x_drive};
    wire [31:0] x_up_w0   = {up_seq, 5'd0, x_chunk, up_qtr, 7'd0, x_drive};

    assign tx_valid = (xs != X_IDLE);
    assign tx_word  = (xs == X_UP_HDR)   ? {16'd0, T_FD_DIRTY, x_msg_len} :
                      (xs == X_SEEK_HDR) ? {16'd0, T_FD_SEEK, 8'd1} :
                      (xs == X_UP_DATA)  ? x_data :
                      (xs == X_UP_W1)    ? {16'd0, up_bits} :
                      (xs == X_SEEK_W0)  ? x_seek_w0 : x_up_w0;

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
                    if (up_owed)        begin x_drive <= up_drive;  xs <= X_UP_HDR;   end
                    else if (seek_owed) begin x_drive <= buf_drive; xs <= X_SEEK_HDR; end
                end
                X_UP_HDR:  if (tx_take) begin xs <= X_UP_W0; x_left <= chunk_len; end
                X_UP_W0:   if (tx_take) xs <= X_UP_W1;
                X_UP_W1:   if (tx_take) xs <= X_UP_DATA;
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
    // magnets as they are then (AppleWin's ControlStepperDeferred): the
    // magnet one phase on pulls +1, the one back pulls -1; two adjacent
    // magnets on - 0011, 0110, 1100, 1001 - turn that pull into a quarter
    // offset instead and leave the phase alone; anything else leaves the
    // quarter offset behind.  So two adjacent magnets dropped in quick
    // succession move nothing (GH#1110), and a pair released puts the head
    // back on its phase.
    wire        phase_access = page_commit && !idx[3];
    wire        step_now     = tick && (step_timer == 4'd1);
    wire [1:0]  cog          = phase[s][1:0];
    wire [1:0]  cog_up       = cog + 2'd1;      // the magnet one phase on
    wire [1:0]  cog_down     = cog + 2'd3;      // ...and one phase back
    wire        mag_up   = magnets[cog_up];
    wire        mag_down = magnets[cog_down];
    wire        mag_pair = (magnets == 4'b0011) || (magnets == 4'b0110) ||
                           (magnets == 4'b1100) || (magnets == 4'b1001);
    wire        head_on  = motor || spinning;      // the drive is enabled or coasting
    logic [6:0] phase_new;
    logic signed [1:0] qoff_new;
    always_comb begin
        phase_new = phase[s];
        qoff_new  = 2'sd0;
        if (mag_pair) begin
            if (mag_up && !mag_down)  qoff_new = 2'sd1;
            if (mag_down && !mag_up)  qoff_new = -2'sd1;
        end else begin
            if (mag_up && !mag_down && phase[s] != 7'd79) phase_new = phase[s] + 7'd1;
            if (mag_down && !mag_up && phase[s] != 7'd0)  phase_new = phase[s] - 7'd1;
        end
    end
    wire [7:0] qpos_new  = qpos_of(phase_new, qoff_new);
    wire       step_move = step_now && head_on && (qpos_new != qpos[s]);

    // ---- the platters, per tick -------------------------------------------------------
    // Two drives, one block each, so the per-drive state is written from
    // exactly one place.  Only the physics is per drive; the buffer's
    // state is below.  A platter turns a bit at a time, on the cell
    // accumulator, whether or not it is the selected one.
    wire [15:0] cell_units [0:1];
    assign cell_units[0] = {1'b0, bcell[0], 7'd0};
    assign cell_units[1] = {1'b0, bcell[1], 7'd0};

    // The seventh chunk of the buffer's own fill has landed.
    wire filled = chunk_done && (fill_drive == buf_drive) &&
                  ((chunks_r | (7'd1 << fill_chunk)) == 7'h7F);

    // The selected drive's cell tick: this tick advances its head a bit.
    wire [16:0] acc_sum_s = {1'b0, acc[s]} + TICK_UNITS[16:0];
    wire        cell_tick = tick && spinning && (acc_sum_s >= {1'b0, cell_units[s]});

    genvar gv;
    generate
        for (gv = 0; gv < 2; gv = gv + 1) begin : g_drv
            // This drive is enabled: the motor is on and it is the one selected.
            wire en_d    = motor && (drive_sel == gv[0]);
            wire spin_d  = (spin[gv] != 20'd0);
            wire sel_d   = (drive_sel == gv[0]);
            wire ins_edge = drv_inserted[gv] && !ins_prev[gv];
            wire ej_edge  = !drv_inserted[gv] && ins_prev[gv];
            wire spin_end = tick && spin_d && !en_d && (spin[gv] == 20'd1);
            wire [16:0] acc_sum = {1'b0, acc[gv]} + TICK_UNITS[16:0];
            wire        adv     = tick && spin_d && (acc_sum >= {1'b0, cell_units[gv]});
            wire [16:0] acc_wrap = acc_sum - {1'b0, cell_units[gv]};
            wire [15:0] bpos_p1  = bpos[gv] + 16'd1;
            // The track this drive's buffer just received: its length.
            wire        filled_d = filled && (buf_drive == gv[0]);
            wire [15:0] nbits    = (fill_bits != 16'd0) ? fill_bits : tbits[gv];

            always_ff @(posedge clk) begin
                if (rst) begin
                    phase[gv]      <= 7'd0;
                    qoff[gv]       <= 2'sd0;
                    spin[gv]       <= 20'd0;
                    stable[gv]     <= 10'd0;
                    bpos[gv]       <= 16'd0;
                    tbits[gv]      <= DEFAULT_BITS[15:0];
                    acc[gv]        <= 16'd0;
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
                            if (adv) begin
                                acc[gv]  <= acc_wrap[15:0];
                                bpos[gv] <= (bpos_p1 >= tbits[gv]) ? 16'd0 : bpos_p1;
                            end else begin
                                acc[gv]  <= acc_sum[15:0];
                            end
                        end
                    end

                    // A fill landed: the track's length is the platter's
                    // circumference from here, and a position past the
                    // end wraps onto it (AppleWin rescales; a disk's tracks
                    // are within a percent of one another, and the wrap
                    // keeps the position for all but the tail).
                    if (filled_d) begin
                        tbits[gv] <= nbits;
                        if (bpos[gv] >= nbits) bpos[gv] <= bpos[gv] - nbits;
                    end

                    // The head.
                    if (step_move && sel_d) begin
                        phase[gv] <= phase_new;
                        qoff[gv]  <= qoff_new;
                    end
                end
            end
        end
    endgenerate

    // ---- the buffer, per tick ---------------------------------------------------------
    // The events that end the buffer's claim to its track.  The select
    // moving to the other drive is one of them, and is LEVEL-sensed - the
    // clock buf_drive disagrees with the select, the buffer changes owner,
    // flushing and refetching exactly as a head movement would.
    wire sel_mismatch = (buf_drive != s);
    wire moved        = step_move && !sel_mismatch;
    wire ins_edge_b   = g_drv[0].ins_edge && (buf_drive == 1'b0) ||
                        g_drv[1].ins_edge && (buf_drive == 1'b1);
    wire ej_edge_b    = g_drv[0].ej_edge && (buf_drive == 1'b0) ||
                        g_drv[1].ej_edge && (buf_drive == 1'b1);
    wire spin_end_b   = g_drv[0].spin_end && (buf_drive == 1'b0) ||
                        g_drv[1].spin_end && (buf_drive == 1'b1);
    wire flush_req    = drv_flush[buf_drive];
    // The buffer's track is left behind, or is otherwise finished with.
    wire leave        = sel_mismatch || moved || ins_edge_b || ej_edge_b ||
                        flush_req || spin_end_b;
    // ...and the host is owed the track it holds.
    wire flush        = leave && dirty;
    // The quarter track the buffer should hold next: under the selected head.
    wire [7:0] tgt    = moved ? qpos_new : qpos[s];
    // A new track is wanted from the host.
    wire want         = (sel_mismatch || moved ||
                         (g_drv[0].ins_edge && !s && !buf_drive) ||
                         (g_drv[1].ins_edge &&  s &&  buf_drive)) &&
                        drv_inserted[s] && (tgt[7:2] < tracks[s]);
    wire read_now     = page_commit && op_rw && (idx == 4'hC) && !q7;

    always_ff @(posedge clk) begin
        if (rst) begin
            buf_drive  <= 1'b0;
            stale      <= 1'b1;
            dirty      <= 1'b0;
            seq        <= 8'd0;
            buf_qtr    <= 8'd0;
            buf_bits   <= 16'd0;
            chunks_r   <= 7'd0;
            fill_ticks <= 16'd0;
            read_stale <= 1'b0;
            seek_owed  <= 1'b0;
            up_owed    <= 1'b0;
            up_drive   <= 1'b0;
            up_qtr     <= 8'd0;
            up_seq     <= 8'd0;
            up_bits    <= 16'd0;
        end else begin
            if (tick && filling && fill_ticks != 16'hFFFF)
                fill_ticks <= fill_ticks + 16'd1;

            // Leaving a track: the written one goes to the host first.
            if (flush) begin
                up_owed  <= 1'b1;
                up_drive <= buf_drive;
                up_qtr   <= buf_qtr;
                up_seq   <= seq;
                up_bits  <= buf_bits;
            end
            if (leave) dirty <= 1'b0;
            if (sel_mismatch) buf_drive <= s;
            if (sel_mismatch || moved) buf_qtr <= tgt;
            if (sel_mismatch || moved || ins_edge_b || ej_edge_b) stale <= 1'b1;
            if (want) begin
                seek_owed  <= 1'b1;
                seq        <= seq + 8'd1;
                chunks_r   <= 7'd0;
                fill_ticks <= 16'd0;
                read_stale <= 1'b0;
            end
            if (seek_sent) seek_owed <= 1'b0;
            if (up_sent)   up_owed   <= 1'b0;

            // The track arriving.
            if (chunk_done && (fill_drive == buf_drive))
                chunks_r <= chunks_r | (7'd1 << fill_chunk);
            if (filled) begin
                stale    <= 1'b0;
                buf_bits <= fill_bits;
            end
            if (read_now && filling) read_stale <= 1'b1;

            // The machine wrote.
            if (w_go) dirty <= 1'b1;
        end
    end

    // The two measurements, and the seek count.
    always_ff @(posedge clk) begin
        if (rst) begin
            seeks    <= 8'd0;
            late     <= 8'd0;
            fill_max <= 16'd0;
        end else begin
            if (want) seeks <= seeks + 8'd1;
            if (late_clr) late <= 8'd0;
            else if (filled && read_stale && late != 8'hFF) late <= late + 8'd1;
            if (fill_clr) fill_max <= 16'd0;
            else if (filled && fill_ticks > fill_max)
                fill_max <= fill_ticks;
        end
    end

    always_ff @(posedge clk) begin
        rd_v_q   <= !w_go;
        rd_tag_q <= a_addr;
        rd_dst_q <= rd_sel_q;
        rd_sel_q <= w_go ? rd_sel_q : !rd_sel_q;
        if (rst) begin
            win_v[0] <= 1'b0; win_v[1] <= 1'b0;
            win_tag[0] <= 11'd0; win_tag[1] <= 11'd0;
            win_q[0] <= 32'd0; win_q[1] <= 32'd0;
        end else begin
            // Last clock's read lands in the window it was for; a write's
            // byte goes into every copy that holds its word.
            if (rd_v_q) begin
                win_q[rd_dst_q]   <= {a_rdata[3], a_rdata[2], a_rdata[1], a_rdata[0]};
                win_tag[rd_dst_q] <= rd_tag_q;
                win_v[rd_dst_q]   <= 1'b1;
            end
            if (w_go) begin
                if (w_in0) win_q[0][8 * wbyte +: 8] <= wnew;
                if (w_in1) win_q[1][8 * wbyte +: 8] <= wnew;
            end
            // A fill in flight makes every copy suspect.
            if (fill_write) begin
                win_v[0] <= 1'b0; win_v[1] <= 1'b0;
            end
        end
    end

    // ---- the controller: the LSS, the register, the write ---------------------------
    logic [7:0] latch;                  // what a data read returns
    logic [7:0] shift;                  // the sequencer's shift register
    logic [3:0] window;                 // the last four bits under the head
    logic [2:0] hold;                   // the latch's hold, in microseconds
    logic       wr_started;             // a load since write mode began

    wire        settled   = (stable[s] >= STABLE_TICKS[9:0]);
    // The bit under the head: the buffer's if it holds this track and the
    // track has bits; nothing otherwise, which the window turns to noise.
    wire        track_here = usable && (buf_bits != 16'd0);
    wire        head_bit   = track_here && h_ok && hbyte_v[hbit];
    // The MC3470's answer: the previous bit while the window has any 1 in
    // it, else a 1 about 30% of the time (5 of 16).
    wire [3:0]  win_new    = {window[2:0], head_bit};
    wire        out_bit    = (win_new != 4'd0) ? win_new[1] : (lfsr[3:0] < 4'd5);
    wire [7:0]  shift_new  = {shift[6:0], out_bit};
    // The hold: 4 us off per cell, then 4 us back on if the register is
    // still empty (GH#662).
    wire [2:0]  hold_dec   = (hold >= 3'd4) ? hold - 3'd4 : 3'd0;
    wire [2:0]  hold_next  = (shift_new == 8'd0) ? hold_dec + 3'd4 : hold_dec;
    // Write mode with a load since it began, on a disk that takes it.  The
    // sequencer shifts and writes at every cell in write mode WHATEVER Q6
    // says - a cell that falls in the one or two cycles of a load (Q6 set)
    // still writes the register's high bit, the freshly loaded byte's.
    // The first cut wrote only in shift state and let the platter advance
    // through the load window without writing: a stale bit left inside
    // every byte whose load a cell boundary happened to fall in, which is
    // one byte in a few at 32-cycle writes on a phase the bench never hit,
    // and what made Wizardry's formatter fail its verify (2026-09-14).
    wire        writing    = q7 && wr_started && spinning &&
                             drv_inserted[s] && !drv_wp[s] && track_here;

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
            shift      <= 8'd0;
            window     <= 4'd0;
            hold       <= 3'd0;
            wr_started <= 1'b0;
            wpend      <= 1'b0;
            wpend_bit  <= 1'b0;
            wpend_pos  <= 16'd0;
        end else begin
            if (tick && step_timer != 4'd0) step_timer <= step_timer - 4'd1;

            // A cell passes under the head.
            if (cell_tick) begin
                if (!q7) begin
                    // Read mode: the LSS.
                    window <= win_new;
                    if (hold != 3'd0) begin
                        hold  <= hold_next;
                        shift <= shift_new;
                        if (hold_next == 3'd0) begin
                            latch <= shift_new;
                            if (shift_new[7]) begin hold <= LATCH_HOLD; shift <= 8'd0; end
                        end
                    end else begin
                        latch <= shift_new;
                        if (shift_new[7]) begin hold <= LATCH_HOLD; shift <= 8'd0; end
                        else shift <= shift_new;
                    end
                    // An empty drive shows $80 until the LSS settles.
                    if (!drv_inserted[s] && !settled) latch <= 8'h80;
                end else begin
                    // Write mode: the high bit goes to the disk, every cell.
                    if (writing) begin
                        wpend     <= 1'b1;
                        wpend_bit <= shift[7];
                        wpend_pos <= hpos;
                    end
                    shift <= {shift[6:0], 1'b0};
                end
            end
            if (w_go) wpend <= 1'b0;

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
                // sequencer's LD, whichever address it was aimed at.  The
                // first load after entering write mode is when the head
                // starts writing (AppleWin's m_writeStarted).
                if (!op_rw && q6_after && q7_after) begin
                    latch      <= op_wdata;
                    shift      <= op_wdata;
                    wr_started <= 1'b1;
                end
                // Leaving write mode ends the write.
                if (idx == 4'hE) wr_started <= 1'b0;
            end
            // So does a drive change, a head movement, or the motor stopping.
            if ((page_commit && (idx[3:1] == 3'd5)) || step_move || !spinning)
                wr_started <= 1'b0;
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

    wire _unused_ok = &{1'b0, msg_free, phase_access, 1'b0};

endmodule
