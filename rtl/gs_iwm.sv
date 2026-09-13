`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_iwm - the IIgs's Integrated Woz Machine at $C0E0-$C0EF, with ONE 3.5"
// DRIVE on it, the disk on the host and one track of it in the card.
//
// THE REFERENCE IS KEGS's iwm.c: iwm_touch_switches for the soft switches,
// read_iwm and write_iwm for the data path, iwm_read_status35 and
// iwm_do_action35 for the drive's sixteen-way register, iwm_read_data (the
// timed path, NOT the fast one) for the data register.  docs/IWM35.md.
//
// WHAT CHANGED (2026-09-12).  This was a stub: a believable EMPTY IWM whose
// whole job was to make the ROM's startup scan give up and boot from the
// slot-7 SmartPort.  The FTA demos boot from a 3.5" disk through their own
// loaders and nothing else - the boot block reads one sector through the
// SmartPort ROM and the rest straight off the IWM - so the drive had to be
// real.  The stub's parts are all still here: the switches, the mode
// register, the ENABLE2 handshake, the status multiplexer.  What is new is
// a disk under the head.
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
// five bits; with the motor ON it is a data write, which this drive DROPS
// (writes are not built yet: the drive reports write-protected, see below).
//
// THE 3.5" DRIVE'S OWN REGISTER.  The phase lines and $C031's bit 7 make a
// four-bit address, {ph1, ph0, $C031[7], ph2}; with Q6 set, bit 7 of the
// status byte is the sense line that address selects (iwm_read_status35), and
// a strobe of phase 3 performs the action it names (iwm_do_action35).  Two
// of the sense reads have a SIDE EFFECT: $1 and $3 select the lower and the
// upper head, which is how the side is chosen - $C031's bit 7 is a select
// bit, not the side.  KEGS, case for case; the table is in the always_comb.
//
// THE PLATTER.  The track under the head is a NIBBLE STREAM in four lanes
// of block RAM (rtl/fd_bank.sv, as the Disk II's), `nibbles` of them per
// track - the host says how many with the fill, since the zones differ:
// 9694 in zone 0 down to 6578 in zone 4 (tools/nib35.py).  It turns one
// slot per nibble time whenever the IWM's ENABLE is on, as KEGS's does
// (iwm_touch_switches advances the position on IWM_STATE_MOTOR_ON, not on
// the drive's own motor).  A nibble is eight 2 us bit cells, 16 us; in the
// CORE'S TIME that is 16 ticks with the CPU at 1 MHz and 44.8 with it at
// 2.8 (rtl/floppy_card.sv says why the tick is the core's op and not the
// bus's cycle: a loader's loops are counted in the CPU's cycles, and a
// platter that turned at wall time would run away from an accelerated
// core - or the ROM's bounded sync searches would expire on a platter that
// did not).  $C036 bit 7 says which; the count is kept in fifths of a tick.
//
// THE DATA REGISTER, IN LATCH MODE (mode bit 0, which every 3.5" driver
// sets): a completed nibble is held, high bit set, until it is READ, and
// each nibble is returned ONCE - the read after it sees the next nibble's
// bits shifting in, high bit clear, so the `LDA $C0EC / BPL` poll reads
// every nibble exactly once at any polling rate.  That is what KEGS's timed
// path does (iwm_read_data's latch-mode arm, "don't return it again") and
// what the IWM's own latch mode is for.  Without latch mode the nibble is
// held for half a nibble time and then the shift-in shows, as a 5.25"
// controller does it.
//
// THE BUFFER AND THE HOST are the Disk II's design (docs/FLOPPY.md): a head
// movement, a side switch or a disk inserted makes the buffer STALE and
// sends the host an FD35_SEEK {seq, 0, track*2+side, 0}; the host answers
// with FD35_TRACK chunks - {seq, chunk, track*2+side, 0}, {chunks, 0,
// nibbles}, then up to 252 words of nibbles - written straight into the
// lanes, and the last chunk clears STALE.  While stale the register serves
// noise, never a wrong track, and the drive reports itself STEPPING (sense
// $4 = 0) after a step, so a driver that waits for the head to settle waits
// for the fill.  The accelerated core is held while the buffer is stale
// (stall_o, as the Disk II's).  A seek nobody answered is asked again after
// FILL_RETRY_CLKS.
//
// NOT HERE YET: writes (dropped; the host marks its disks write-protected
// and sense $6 says so), a second drive (sense $F says drive 1 is not
// installed, as KEGS says), eject (action $D is taken and does nothing),
// the 5.25" side of the chip - the Disk II is rtl/floppy_card.sv, and with
// $C031 bit 6 clear this answers as the stub always did: no 5.25" drive.
//////////////////////////////////////////////////////////////////////////////////
module gs_iwm #(
    parameter [7:0] T_FD35_TRACK = 8'h31,   // host -> card
    parameter [7:0] T_FD35_SEEK  = 8'h32,   // card -> host
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
    // carried one, or a fast op the bus never saw - never a dummy cycle.
    input  wire        tick,
    // $C036 bit 7: the CPU at 2.8 MHz, so a nibble time is 44.8 ticks.
    input  wire        fast_cpu,

    // Host -> card messages, as ft601_msg_rx decodes them.
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,

    // Card -> host: FD35_SEEK, a word at a time through msg_arb.
    output wire [31:0] tx_word,
    output wire        tx_valid,
    input  wire        tx_take,

    // FD35_DRIVE, live: what is in the drive.
    input  wire        drv_inserted,
    input  wire        drv_wp,
    // FD35_STAT's W1 bits.
    input  wire        late_clr,
    input  wire        fill_clr,

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
    // The drive is turning with a disk in and the buffer is not its track:
    // the accelerated core waits for the fill (rtl/accel_seq.sv stall).
    output wire        stall_o,

    // Diagnostics.
    output logic [7:0] cnt_mode_wr
);

    // ---- geometry ------------------------------------------------------------
    localparam integer BUF_BYTES   = 10240;          // > zone 0's 9694
    localparam integer BUF_WORDS   = BUF_BYTES / 4;  // 2560
    localparam integer CHUNK_WORDS = 252;

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

    // ---- the platter ----------------------------------------------------------
    // The slot under the head and the nibble time.  A nibble is 16 ticks at
    // 1 MHz and 44.8 at 2.8: the count runs in FIFTHS of a tick, 80 or 224
    // per nibble, so the fast figure is exact.
    logic [13:0] pos;               // 0 .. nibbles-1
    logic [7:0]  nib_acc;           // fifths of a tick into this slot
    wire  [7:0]  nib_period = fast_cpu ? 8'd224 : 8'd80;
    wire         spinning   = motor_on;
    wire         complete   = tick && spinning && (nib_acc + 8'd5 >= nib_period);
    // The bits of the next slot shifted in so far, for the partial byte a
    // read sees between nibbles: nothing decodes it, it only has to look
    // like a byte shifting in - bit 7 clear, the rest moving.
    wire  [2:0]  bits_in    = fast_cpu ? nib_acc[7:5] : nib_acc[6:4];

    // ---- the buffer's state ---------------------------------------------------
    logic        stale;             // the buffer is not the head's track yet
    logic [7:0]  seq;               // the seek the host is answering
    logic [7:0]  buf_qtr;           // the track*2+side the buffer is for
    logic [13:0] nibbles;           // nibbles in it, from the fill
    logic [15:0] chunks_r;          // chunks landed for `seq`
    logic [3:0]  chunks_total;      // ...of how many, from the fill's word 1
    logic        seek_owed;
    logic        read_stale;        // the machine read while stale
    logic [21:0] retry_clks;
    logic [6:0]  us_pre;            // 100 clocks to the microsecond
    logic [15:0] fill_us;           // microseconds since the seek, saturating

    // THE ONE DRIVE IS DRIVE 1.  With $C0EB selecting drive 2 there is
    // nothing there: no disk, not installed, locked, at track 0, and a step
    // moves nothing - which is what KEGS's empty drive35[1] answers, and
    // what the ROM's probe relies on to pass drive 2 by and look at drive 1
    // (it asks drive 2 first).  The STEP DIRECTION and the DRIVE MOTOR are
    // not the drive's: KEGS keeps them in the IWM's own state word, shared
    // by both selects, and the ROM sets the direction with drive 2 selected
    // and reads it back expecting to see it.
    wire         here     = !drive_sel;
    wire         disk_in  = drv_inserted && here;
    wire  [7:0]  head_qtr = {track35, side35};
    wire         usable   = disk_in && !stale;
    assign stale_o = stale;
    assign stall_o = spinning && apple35_sel && disk_in && stale;

    // Noise for an empty drive or a stale buffer: a 16-bit LFSR per tick.
    logic [15:0] lfsr;
    wire         lfsr_fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    // ---- the track buffer -------------------------------------------------------
    // THREE BLOCK RAM TILES, 1024 words of 32 bits each, 3072 words for the
    // 2560 a zone-0 track needs: word w lives in tile w[11:10] at index
    // w[9:0].  Port A is the bus side (the standing read of the word the
    // head's slot is in), port B the link side (the fill, a word at a time).
    // Four byte lanes of 2560 (the Disk II's shape, rtl/fd_bank.sv) took a
    // RAMB36 each at 62%; three full tiles are one fewer, and the count
    // matters: the IIgs builds that never calibrated their DDR3 were the
    // largest ones (docs/GS.md "The retained set and the DDR3").
    (* ram_style = "block" *) logic [31:0] tbuf0 [0:1023];
    (* ram_style = "block" *) logic [31:0] tbuf1 [0:1023];
    (* ram_style = "block" *) logic [31:0] tbuf2 [0:1023];
    wire  [11:0] a_word_addr = pos[13:2];
    logic [31:0] a_rd0, a_rd1, a_rd2;
    logic [1:0]  a_tile_q;
    wire         b_we;
    wire  [11:0] b_addr;
    always_ff @(posedge clk) begin
        a_rd0 <= tbuf0[a_word_addr[9:0]];
        a_rd1 <= tbuf1[a_word_addr[9:0]];
        a_rd2 <= tbuf2[a_word_addr[9:0]];
        a_tile_q <= a_word_addr[11:10];
    end
    always_ff @(posedge clk) begin
        if (b_we && b_addr[11:10] == 2'd0) tbuf0[b_addr[9:0]] <= pay_data;
        if (b_we && b_addr[11:10] == 2'd1) tbuf1[b_addr[9:0]] <= pay_data;
        if (b_we && b_addr[11:10] == 2'd2) tbuf2[b_addr[9:0]] <= pay_data;
    end
    wire [31:0] a_word = (a_tile_q == 2'd0) ? a_rd0 : (a_tile_q == 2'd1) ? a_rd1 : a_rd2;

    // The nibble the register will take next, refreshed every clock from the
    // word the head's slot is in (one clock of RAM latency, one of lane
    // select - a slot lasts sixteen ticks at the least).
    logic [7:0] nxt;
    logic [1:0] a_lane_q, a_lane_qq;
    always_ff @(posedge clk) begin
        a_lane_q  <= pos[1:0];
        a_lane_qq <= a_lane_q;
        if (rst) nxt <= 8'd0;
        else     nxt <= a_word[8*a_lane_q +: 8];
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
    wire word_track = rx_word && (rx_type == T_FD35_TRACK);

    wire [7:0]  w0_qtr   = pay_data[15:8];
    wire [7:0]  w0_chunk = pay_data[23:16];
    wire [7:0]  w0_seq   = pay_data[31:24];

    // Words 0 and 1 are the chunk's own; the data starts at index 2.
    wire fill_write = word_track && (rx_idx >= 8'd2) && fill_ok &&
                      (fill_word < 12'(BUF_WORDS));
    wire chunk_done = word_track && rx_last && fill_ok;

    assign b_we   = fill_write;
    assign b_addr = fill_word;

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
                if (msg_type == T_FD35_TRACK) fill_ok <= 1'b0;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_track) begin
                    if (rx_idx == 8'd0) begin
                        fill_chunk <= w0_chunk[3:0];
                        fill_word  <= 12'(w0_chunk[3:0]) * 12'(CHUNK_WORDS);
                        // The chunk lands only if it answers the buffer's
                        // OWN seek: the right track and the right seq.
                        fill_ok    <= (w0_chunk < 8'd16) && (w0_qtr == buf_qtr) &&
                                      (w0_seq == seq) && drv_inserted;
                    end else if (fill_ok) begin
                        if (rx_idx != 8'd1) fill_word <= fill_word + 1'b1;
                    end
                end
            end
        end
    end
    // Word 1 of every chunk: {chunks[7:0], 8'd0, nibbles[15:0]}.
    wire fill_w1 = word_track && (rx_idx == 8'd1) && fill_ok;

    // ---- card -> host: FD35_SEEK ------------------------------------------------
    typedef enum logic [1:0] { X_IDLE, X_HDR, X_W0 } xstate_t;
    xstate_t xs;
    assign tx_valid = (xs != X_IDLE);
    assign tx_word  = (xs == X_HDR) ? {16'd0, T_FD35_SEEK, 8'd1}
                                    : {seq, 8'd0, buf_qtr, 8'd0};
    wire seek_sent = (xs == X_W0) && tx_take;
    always_ff @(posedge clk) begin
        if (rst) xs <= X_IDLE;
        else case (xs)
            X_IDLE: if (seek_owed) xs <= X_HDR;
            X_HDR:  if (tx_take) xs <= X_W0;
            X_W0:   if (tx_take) xs <= X_IDLE;
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
    // A 5.25" drive with no disk reads write-protected (iwm.c:133).
    wire sense = apple35_sel ? status35 : 1'b1;

    // KEGS: val = ((sense & 1) << 7) | (state & 0x3f): bit 5 is the IWM's
    // ENABLE latch, the mode in [4:0], bit 6 zero.
    wire [7:0] status_byte = {sense, 1'b0, t_motor, mode};
    wire [7:0] handshake   = (hs_count == 2'd3) ? 8'h80 : 8'hC0;

    // The stub's empty-5.25" register: a position that advances per read,
    // so the ROM's SmartPort probe sees a byte with bit 6 clear.
    logic [23:0] fbit;
    wire [31:0] fbit_scaled = fbit * 24'd25;

    // ---- the data register -----------------------------------------------------
    logic [7:0] latch;              // the completed nibble
    logic       latch_valid;        // ...not yet read (latch mode)
    logic       half_gone;          // half a nibble time since it completed
    // The byte a data read returns: the held nibble, or the next shifting in.
    wire [7:0]  slot_val  = usable ? nxt : lfsr[7:0];
    wire [7:0]  partial   = slot_val >> (4'd8 - {1'b0, bits_in});
    wire        held      = mode[0] ? latch_valid : !half_gone;
    wire [7:0]  data_byte = apple35_sel ? (held ? latch : partial)
                                        : fbit_scaled[18:11];   // no 5.25" drive: a varying byte

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
    // The head after this access.
    wire [6:0] track_next = do_step ? track_stepped : track35;
    wire       side_next  = sel_lower ? 1'b0 : sel_upper ? 1'b1 : side35;
    wire       head_moves = ({track_next, side_next} != head_qtr);

    logic ins_prev;
    wire  ins_edge = drv_inserted && !ins_prev;
    wire  ej_edge  = !drv_inserted && ins_prev;
    // A new track is wanted from the host.
    wire  want = disk_in && (head_moves || ins_edge ||
                 (stale && !seek_owed && (xs == X_IDLE) && (retry_clks == 22'd0)));
    wire  filled = chunk_done && (chunks_total != 4'd0) &&
                   ((chunks_r | (16'd1 << fill_chunk)) == ((16'd1 << chunks_total) - 16'd1));

    always_ff @(posedge clk) begin
        if (rst) begin
            stale       <= 1'b1;
            seq         <= 8'd0;
            buf_qtr     <= 8'd0;
            nibbles     <= 14'd9694;
            chunks_r    <= 16'd0;
            chunks_total <= 4'd0;
            seek_owed   <= 1'b0;
            read_stale  <= 1'b0;
            retry_clks  <= 22'd0;
            us_pre      <= 7'd0;
            fill_us     <= 16'd0;
            ins_prev    <= 1'b0;
            stepped     <= 1'b0;
            seeks       <= 8'd0;
            late        <= 8'd0;
            fill_max    <= 16'd0;
        end else begin
            ins_prev <= drv_inserted;
            if (stale && retry_clks != 22'd0) retry_clks <= retry_clks - 22'd1;
            us_pre <= (us_pre == 7'd99) ? 7'd0 : us_pre + 7'd1;
            if (stale && (us_pre == 7'd99) && fill_us != 16'hFFFF) fill_us <= fill_us + 16'd1;

            if (head_moves || ins_edge || ej_edge) stale <= 1'b1;
            if (head_moves || ins_edge) buf_qtr <= {track_next, side_next};
            if (do_step) stepped <= 1'b1;
            if (want) begin
                seek_owed  <= 1'b1;
                seq        <= seq + 8'd1;
                chunks_r   <= 16'd0;
                chunks_total <= 4'd0;
                retry_clks <= 22'(FILL_RETRY_CLKS);
                fill_us    <= 16'd0;
                read_stale <= 1'b0;
                seeks      <= seeks + 8'd1;
            end
            if (seek_sent) seek_owed <= 1'b0;

            // The track arriving.
            if (fill_w1) begin
                chunks_total <= pay_data[27:24];
                nibbles      <= pay_data[13:0];
            end
            if (chunk_done) chunks_r <= chunks_r | (16'd1 << fill_chunk);
            if (filled) begin
                stale   <= 1'b0;
                stepped <= 1'b0;
                if (read_stale && late != 8'hFF) late <= late + 8'd1;
                if (fill_us > fill_max) fill_max <= fill_us;
            end
            if (data_read && stale && apple35_sel && disk_in) read_stale <= 1'b1;
            if (late_clr) late <= 8'd0;
            if (fill_clr) fill_max <= 16'd0;
        end
    end

    // ---- the platter, per tick ----------------------------------------------------
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
                    if (nib_acc + 8'd5 >= {1'b0, nib_period[7:1]}) half_gone <= 1'b1;
                end
            end
            // Read once: the nibble is spent.
            if (data_read && apple35_sel && latch_valid) latch_valid <= 1'b0;
        end
    end

    // ---- the switches and the drive, per access -------------------------------
    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            mode <= 5'd0;
            phases <= 4'd0;
            motor_on <= 1'b0;
            motor_off_pend <= 1'b0;
            motor_off_ticks <= 22'd0;
            step_dir35 <= 1'b0; motor35 <= 1'b0; track35 <= 7'd0; side35 <= 1'b0;
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

    // The reset line the phases can assert is decoded but drives nothing.
    wire _unused = &{1'b0, iwm_reset, a_lane_qq,
                     op_wdata[7:5], fbit_scaled[31:19], fbit_scaled[10:0], 1'b0};
endmodule
