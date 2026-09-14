`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_io - the IIgs chipset's face on $C0xx, on the card.
//
// WHAT IT IS FOR.  On the IIe every $C0xx the card does not hold is BUS class
// and rides a real bus cycle to the motherboard, which answers it.  A IIgs in
// this machine has no motherboard to ask: the ADB micro, the clock, the VGC,
// the interrupt controller and the rest are not on the IIe's board and never
// were.  So the card answers them itself, and this is where.
//
// IT REUSES THE PATH THAT ALREADY EXISTS, rather than adding a class.
// docs/GS.md's plan called for a new CLS_IO and a three-bit class; but the
// card already has a path for "a $C0xx op the card answers itself" - the
// INTERNALIZED op of docs/CXXX.md, which rides S_FAST like any fast op,
// takes its byte from `swi_byte`, and retires with a SYNTHETIC COMMIT on the
// unified stream.  That is exactly the shape this needs, it is proven on
// hardware, and it costs no widening: `claim` joins the dispatcher's `q_swi`
// and `rd_byte` joins the `swi_byte` mux.  The class stays two bits.
//
// THE TWO FACES OF AN OP, and why there are two address ports.  `q_addr` is
// the LIVE address the dispatcher is deciding on, so `claim` must be
// combinational on it - the decision is taken the clock after the op appears
// and cannot wait.  `op_lo` is the REGISTERED op, stable from the dispatch
// through the synthetic commit, so the byte and every side effect hang off
// that.  Getting these the wrong way round would answer one op with another's
// byte.
//
// WHAT IT CLAIMS TODAY: the ADB micro at $C025-$C027, and nothing else.  This
// is deliberate.  Rung 3b grows the claim one register at a time, measuring
// `boot_gs_tb`'s divergence index against the KEGS trace after each, because
// an address claimed and answered WRONGLY is worse than one left to the bus:
// the bus at least returns a consistent floating byte.  The census the bench
// prints (`the $C0xx census`) is the work list, in the ROM's own order.
//
// WHAT STAYS ON THE BUS BY POLICY, not by omission (docs/GS.md, "The real IIe
// board in GS mode"): $C063-$C067 and $C070, the game port, which is REAL
// hardware this machine has; $C058-$C05F, the annunciators; and any $Cnxx
// belonging to a physical card in a slot.  Those must never be claimed here.
//
// THE ONE EXCEPTION IS $C061 AND $C062, THE APPLE KEYS (docs/GS.md rung 4's
// gate).  On a IIgs they are the ADB keyboard's Command and Option OR the
// game port's buttons 0 and 1 - KEGS moremem.c:1311, `adb_is_cmd_key_down()
// || g_paddle_buttons & 1` - and the ROM reads them after a reset to decide
// on the self-test and the cold boot.  Left to the bus, only the IIe
// keyboard's Apple keys ever reached them: the Pi keyboard's Command and
// Option stopped at $C025, and the host's button override (rtl/pb_inject.sv,
// stood down at GS = 1) reached nothing.  Answered here, bit 7 is the host's
// override if it holds one, else the ADB micro's Command/Option level - which
// already carries the IIe keyboard's real Apple keys, sampled by the walk
// (rtl/gs_kbd_a2.sv's live_mods) - so a joystick's buttons 0 and 1 are the
// walk's samples too, at its rate.  The low seven bits read zero, as IOR().
//////////////////////////////////////////////////////////////////////////////////
module gs_io #(
    // The ADB micro's keymap (tools/gen_adb_keymap.py), passed down so a
    // bench can name its own copy.
    parameter adb_keymap = "adb_keymap.hex"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,       // synchronised RES', ACTIVE LOW

    // The LIVE query: would this module answer an op at q_addr?  Answered
    // combinationally, for rtl/accel_seq.sv's decision.
    input  wire [23:0] q_addr,
    input  wire        q_rw,
    output wire        claim,

    // The REGISTERED op, and its retire on the unified stream.
    input  wire [7:0]  u_bank,
    input  wire [15:0] u_addr,
    input  wire        u_rw,
    input  wire [7:0]  u_wdata,
    input  wire        u_commit,       // the synthetic commit: one per op

    // The IIgs's registers, held by rtl/apple_mmu.sv because the map is what
    // they steer, and read back here because $C0xx is this module's window.
    input  wire [7:0]  gs_shadow,      // $C035
    input  wire [7:0]  gs_cyareg,      // $C036
    input  wire [7:0]  gs_sltrom,      // $C02D
    input  wire [7:0]  gs_state,       // $C068, composed from the switches
    // apple_mmu's status-page byte for the REGISTERED op: the switch this
    // $C01x address reports, in bit 7, over the keyboard latch's low bits.
    input  wire [7:0]  stat_byte,
    // ...and the switches it is made of, bit n for $C01n, with the keyboard
    // latch's low bits: the status page for ANY address, for fr_vec below.
    input  wire [15:0] stat_bits,
    input  wire [6:0]  kbd_low,
    // The video scanner is in vertical blanking.  On the card this is
    // rtl/vbeam.sv's; in the bench it is the frame counter's.
    input  wire        vbl,
    // THE SCAN-LINE INTERRUPT (KEGS sim65816.c check_scan_line_int): the
    // beam's line and column from rtl/vbeam.sv, and the page cache's write
    // tap for any bank, watched for the SCBs at $E1/9D00-9DC7.  A line whose
    // SCB has bit 6 set raises the VGC's scan-line interrupt at the START of
    // that line (KEGS: g_last_vbl_dfcyc + 65*line) while Super Hi-Res is on.
    // QuickDraw II redraws the cursor from this interrupt; without it the
    // arrow sat at (0,0) while the ROM's position variables tracked the
    // mouse exactly (docs/GS.md, the night of 2026-09-10/11).
    input  wire [8:0]  scan_v,
    input  wire [6:0]  scan_h,
    input  wire        mw_stb,         // a byte landed in the image, any bank
    input  wire [7:0]  mw_bank,
    input  wire [15:0] mw_addr,
    input  wire [7:0]  mw_byte,

    // Seconds since 1904-01-01, for the clock chip.  The host's, or the
    // bench's pinned value (rtl/gs_clock.sv).
    input  wire [31:0] seed_time,
    // The border colour the VGC paints, $C034[3:0].
    output wire [3:0]  border,

    // The byte a read of the registered op would take, and whether this
    // module is the one that owns that op at all - the select for the caller's
    // internalized-read mux, which follows the REGISTERED op just as the byte
    // does (rtl/master_top.sv, "swi_byte").
    output wire        u_claim,
    output logic [7:0] rd_byte,
    // THE FAST READS (docs/LONG_DATA.md rung 3): every register in
    // gs_iopage.vh's set, as its read would compose it now, eight bits each in
    // gs_fr_sel's order.  The data front serves a read of one of them itself,
    // from a copy master_top registers once.
    output wire [247:0] fr_vec,

    // Host -> card messages as ft601_msg_rx decodes them, for the battery
    // RAM the host ships down to gs_clock (docs/GS.md, "The battery RAM the
    // host ships").  Nothing else in here wants them yet.
    // THE IIe's OWN KEYBOARD (rtl/gs_kbd_a2.sv), passed through to the ADB
    // micro beside the host's ADB_KEY: the events the reverse keymap made,
    // and the real Apple keys as a level for $C025.
    input  wire        loc_valid,
    input  wire [6:0]  loc_code,
    input  wire        loc_up,
    input  wire [7:0]  loc_mods,
    input  wire [7:0]  live_mods,
    // The host's BUTTONS overrides, two bits a button, PB0 in [1:0]: 00 the
    // hardware's, 01 up, 10 down (rtl/pb_inject.sv holds the same word).
    input  wire [5:0]  pb_sel,

    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    // MOUSE_MOVE's buttons ride in the header's spare field; the ADB micro
    // needs them, so the field comes down with the rest.
    input  wire [15:0] msg_free,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,
    output wire        bram_ok,

    // One pulse per video frame, in the machine's own time (rtl/vbeam.sv):
    // the interrupt controller's only clock.
    input  wire        frame_tick,
    // One pulse a sixtieth of a WALL second: the ADB micro's own clock, for
    // its auto-repeat.  The two are the same rate at 1x and part company
    // under acceleration - rtl/gs_adb.sv says why the micro must not follow
    // the beam.
    input  wire        wall_tick,
    // The keyboard read the data front serves itself (rtl/gs_adb.sv).
    input  wire        c000_ext,
    output wire [7:0]  c000_byte,

    // The Ensoniq's mix, signed, for rtl/audio_sampler.sv to box-average the
    // way it already does the AYs.
    output wire signed [20:0] doc_l,
    output wire signed [20:0] doc_r,

    // The one interrupt line into the core.
    output wire        irq,
    // GS_ADB_STAT for the host (rtl/gs_adb.sv).
    output wire [31:0] adb_stat,

    // THE 3.5" DRIVE ON THE IWM (rtl/gs_iwm.sv, docs/IWM35.md): the core's
    // tick for its platter, its FD35_SEEK out to the link, what the host
    // says is in it, and its readback for FD35_DRIVE / FD35_STAT.
    input  wire        core_tick,
    output wire [31:0] fd35_word,
    output wire        fd35_valid,
    input  wire        fd35_take,
    input  wire        fd35_inserted,
    input  wire        fd35_wp,
    input  wire        fd35_late_clr,
    input  wire        fd35_fill_clr,
    output wire        fd35_stale,
    output wire [6:0]  fd35_track,
    output wire        fd35_side,
    output wire        fd35_motor35,
    output wire        fd35_motor,
    output wire [7:0]  fd35_ctl,
    output wire [7:0]  fd35_seeks,
    output wire [7:0]  fd35_late,
    output wire [15:0] fd35_fill_max,
    output wire        fd35_stall,
    // THE 5.25" DRIVES ON THE IWM: FD_DRIVE1/2, the Disk II's registers,
    // [0] drive 1 and [1] drive 2 - and their readback.  On a IIgs the Disk
    // II card is not built (rtl/master_top.sv g_no_fd).
    input  wire [1:0]  fd525_inserted,
    input  wire [1:0]  fd525_wp,
    input  wire [25:0] fd525_nibbles,
    input  wire [11:0] fd525_tracks,
    output wire [1:0]  fd525_stale,
    output wire [13:0] fd525_phase
);

    // A IIgs sees I/O at $C0xx in a PAIR bank only - $00/$01 and the Mega
    // II's $E0/$E1 - which is the rule rtl/apple_mmu.sv applies to the
    // switches, and the same rule has to hold here or bank $02's $C0xx would
    // be answered by the chipset instead of being the plain RAM it is.
    function automatic pair_bank(input [7:0] bk);
        pair_bank = (bk == 8'h00) || (bk == 8'h01) || (bk == 8'hE0) || (bk == 8'hE1);
    endfunction
    // ...BUT IN $00/$01 ONLY WHILE SHADOW BIT 6 IS CLEAR (docs/LONG_DATA.md
    // rung 3).  With it set the fast pair's $C0xx is RAM - apple_mmu classifies
    // it so - and this module claimed it anyway: the dispatcher took this
    // module's byte over the RAM's, and a write ran the register's side effect
    // (a $00/C047 write cleared the timer interrupts).  The rule now lives in
    // one place, shared with the data front and checked against the map's
    // oracle in sim/mmu_xlate_gs_tb.sv.
    `include "gs_iopage.vh"

    // ---- what this module answers -------------------------------------------
    // One function, asked of the live address for the claim and of the
    // registered one for the effect, so the two can never drift apart.
    function automatic mine(input [7:0] lo);
        mine = (lo == 8'h00) || (lo == 8'h10)                     // the keyboard
            || (lo == 8'h21) || (lo == 8'h22) || (lo == 8'h23)    // the VGC
            || (lo == 8'h24) || (lo == 8'h25) || (lo == 8'h26) || (lo == 8'h27)  // ADB
            || (lo == 8'h29) || (lo == 8'h2A) || (lo == 8'h2B) || (lo == 8'h2C)  // the VGC
            || (lo[7:4] == 4'h1 && lo != 8'h10)                    // $C011-$C01F, the status page
            || (lo == 8'h2D)                                       // SLOTROMSEL
            || (lo == 8'h2E) || (lo == 8'h2F)                      // VERTCNT, HORIZCNT
            // $C030 IS THE SPEAKER, AND IT MUST NOT REACH THE BACKPLANE.
            // A IIgs's speaker is the card's and the host's, but the machine
            // this card lives in decodes $C030-$C03F for ITS OWN speaker -
            // partially, as real Apple II hardware does - so any one of those
            // addresses riding a real cycle clicks the motherboard's speaker
            // audibly.  Every other address in the range is already claimed
            // below (the clock, SHADOW, CYAREG, the SCC, the sound GLU), so
            // claiming this one closes the range: nothing in $C03x is ever
            // presented to the bus again.  The card's own speaker model still
            // sees it - it watches the fast event, not the backplane
            // (rtl/speaker.sv) - so the sound still reaches the host.
            || (lo == 8'h30)                                       // the speaker
            || (lo == 8'h31) || (lo == 8'h32)                      // DISKREG, SCANINT
            || (lo == 8'h33) || (lo == 8'h34)                      // the clock and battery RAM
            || (lo == 8'h35) || (lo == 8'h36) || (lo == 8'h37)     // SHADOW, CYAREG, $C037
            || (lo[7:2] == 6'b001110)                              // $C038-$C03B, the SCC
            || (lo[7:2] == 6'b001111)                              // $C03C-$C03F, the sound GLU
            || (lo == 8'h41) || (lo == 8'h46) || (lo == 8'h47)     // the interrupt controller
            || (lo == 8'h61) || (lo == 8'h62)                      // the Apple keys (see the header)
            || (lo == 8'h68) || (lo == 8'h69)                      // STATEREG, and a reserved zero
            || (lo[7:4] == 4'hE);                                   // $C0E0-$C0EF, the IWM
    endfunction

    wire q_io = gs_is_io(q_addr[23:16], gs_shadow[6]) && (q_addr[15:8] == 8'hC0);
    assign claim = q_io && mine(q_addr[7:0]);

    wire u_io = gs_is_io(u_bank, gs_shadow[6]) && (u_addr[15:8] == 8'hC0);
    wire u_mine = u_io && mine(u_addr[7:0]);
    assign u_claim = u_mine;
    // The op retired AND it was ours.  u_commit fires for every internalized
    // op, so the decode is repeated here rather than trusted.
    wire act = u_commit && u_mine;

    wire [7:0] adb_c025, adb_c027;
    wire [7:0] adb_rd;
    wire       adb_irq_data, adb_irq_mouse;
    wire [7:0] adb_cnt_cmds, adb_cnt_unknown;

    gs_adb #(.KEYMAP (adb_keymap)) u_adb (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (u_addr[7:0]), .op_rw (u_rw), .op_wdata (u_wdata), .act (act),
        .rd_byte (adb_rd),
        // The keys, from the host (docs/GS.md, ADB_KEY) and from the IIe's
        // own keyboard; the micro holds the keymap and $C025's modifiers, as
        // a real one does.
        .wall_tick (wall_tick),
        .c000_ext (c000_ext), .c000_byte (c000_byte),
        .loc_valid (loc_valid), .loc_code (loc_code),
        .loc_up (loc_up), .loc_mods (loc_mods), .live_mods (live_mods),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .c025_rd (adb_c025),
        .c027_o (adb_c027),
        .irq_data (adb_irq_data), .irq_mouse (adb_irq_mouse),
        .cnt_cmds (adb_cnt_cmds), .cnt_unknown (adb_cnt_unknown),
        .dbg_stat (adb_stat)
    );

    // The map's registers read straight back.  $C037 reads zero on a IIgs
    // (KEGS moremem.c:1122) and is claimed rather than left to the bus so the
    // ROM's 309 reads of it get that zero from the machine that owns the
    // address, not from a floating backplane that happens to agree.
    //
    // NOTE THE WRITES STILL LAND IN apple_mmu, not here: $C02D, $C035, $C036
    // and $C068 are written on the classified op's commit, and the synthetic
    // commit an internalized op retires with IS that commit (accel_seq's
    // u_commit is the driver's OR swi_commit).  Claiming them here changes
    // where the BYTE comes from and nothing about where the write goes.
    always_comb begin
        case (u_addr[7:0])
            // $C019 IS THE IIgs's WAY ROUND: bit 7 is set WHILE IN VBL, where
            // the IIe's is set while NOT (KEGS moremem.c:1044, which inverts
            // it for the IIe alone).  Getting this backwards is not subtle -
            // the ROM waits at $FF/A5F1 for the bit to rise and then fall,
            // and a constant of either polarity hangs it.
            8'h19:   rd_byte = {vbl, stat_byte[6:0]};
            8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17, 8'h18,
            8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F:
                     rd_byte = stat_byte;
            8'h21:   rd_byte = {c021_mono, 7'd0};
            8'h22:   rd_byte = c022_color;
            8'h23,
            8'h41,
            8'h46,
            8'h47:   rd_byte = intc_rd;
            8'h29:   rd_byte = c029_newvideo;
            8'h2A:   rd_byte = 8'h00;   // reads zero on a IIgs (moremem.c:1086)
            8'h2B:   rd_byte = c02b_langsel;
            8'h2C:   rd_byte = 8'h00;   // the character-ROM test port, out of test mode
            8'h2D:   rd_byte = gs_sltrom;
            // THE VIDEO COUNTERS (KEGS moremem.c read_vid_counters): the
            // vertical counter is $100 + the display line, $FA-$FF for the
            // last six lines of the frame; $C02E is its bits 8:1 and $C02F
            // its bit 0 over the horizontal count, which is 0 at the start
            // of a line and $40-$7F across it.  The ROM's self-test times
            // its speed test between two changes of $C02E (docs/GS.md rung
            // 4's gate); left to the bus these were the IIe's floating
            // byte, and the count came out at one.
            8'h2E:   rd_byte = vid_cnt[8:1];
            8'h2F:   rd_byte = {vid_cnt[0], (scan_h == 7'd0) ? 7'd0 : ((scan_h + 7'h3F) & 7'h7F)};
            // Reading $C030 toggles the speaker and returns the floating
            // bus.  Zero, which is what the backplane returned for it before
            // it was claimed - so the bench's comparison against KEGS is
            // unmoved by the claim.
            8'h30:   rd_byte = 8'h00;
            8'h31:   rd_byte = c031_diskreg;
            8'h32:   rd_byte = 8'h00;   // SCANINT reads zero (moremem.c:1112)
            8'h33,
            8'h34:   rd_byte = clk_rd;
            8'h35:   rd_byte = gs_shadow;
            8'h36:   rd_byte = gs_cyareg;
            8'h37:   rd_byte = 8'h00;
            8'h38:   rd_byte = scc_reg_rd;
            8'h39:   rd_byte = scc_reg_rd;
            8'h3A,
            8'h3B:   rd_byte = 8'h00;   // the SCC's data ports: nothing received
            8'h3C, 8'h3D, 8'h3E, 8'h3F: rd_byte = doc_rd;
            // The Apple keys: the host's override, else Command/Option as
            // the ADB micro shows them (the IIe keyboard's real keys merged
            // in at that read).  IOR(): bit 7 alone.
            8'h61:   rd_byte = {(pb_sel[1:0] == 2'b00) ? adb_c025[7] : pb_sel[1], 7'd0};
            8'h62:   rd_byte = {(pb_sel[3:2] == 2'b00) ? adb_c025[6] : pb_sel[3], 7'd0};
            8'h68:   rd_byte = gs_state;
            8'h69:   rd_byte = 8'h00;   // reserved, reads zero (moremem.c:1328)
            8'hE0, 8'hE1, 8'hE2, 8'hE3, 8'hE4, 8'hE5, 8'hE6, 8'hE7,
            8'hE8, 8'hE9, 8'hEA, 8'hEB, 8'hEC, 8'hED, 8'hEE, 8'hEF:
                     rd_byte = iwm_rd;
            default: rd_byte = adb_rd;
        endcase
    end
    wire [8:0] vid_cnt = (scan_v < 9'd256) ? {1'b1, scan_v[7:0]} : (9'h0FA + {6'd0, scan_v[2:0]});

    // ---- the VGC's latches, the SCC and IWM stubs, the sound GLU face -------
    // These are registers and nothing else: what the ROM writes it reads back,
    // and the HOST acts on the writes it sees in the stream (docs/GS.md: the
    // video is drawn on the Pi).  Each is named with the KEGS case it comes
    // from.
    logic       c021_mono;          // $C021 bit 7: monochrome
    logic [7:0] c022_color;         // $C022: text colour in 7:4, background in 3:0
    // $C029: bit 7 SHR, bit 6 linearise, bit 5 bandwidth, bit 0 reads back.
    // SHR IS BIT 7 ALONE (KEGS defcomm.h: BIT_ALL_STAT_SUPER_HIRES = 7);
    // bit 6 is stored so a program can read it and changes no picture, which
    // is why KEGS consults g_c029_val_some nowhere but the readback.
    logic [7:0] c029_newvideo;
    logic [7:0] c02b_langsel;       // $C02B: language and NTSC/PAL
    logic [7:0] c031_diskreg;       // $C031: bit 7 APPLE35SEL, bit 6 drive select
    logic [7:0] scc_ptr;            // the SCC's write-register pointer, per channel-pair

    // The SCC's reset values, from KEGS scc.c's scc_read_reg (line 655) and
    // scc_reset: RR0 is $60 with CTS and the transmit buffer empty, plus $08
    // when DCD is asserted - and DCD IS PER CHANNEL, `1 - i`, so channel A
    // has carrier and channel B does not (scc.c:128).  RR1 reads $07, "all
    // sent"; RR15 reads $F8 after a reset.  Everything else is zero.  The ROM
    // reads RR0 and wants a believable answer or its port scan does not end.
    // $C039 is CHANNEL A and $C038 is CHANNEL B (moremem.c: scc_write_reg's
    // port argument is 0 for $C039 and 1 for $C038).
    wire scc_chan_a = (u_addr[7:0] == 8'h39) || (u_addr[7:0] == 8'h3B);
    wire [7:0] scc_rr0 = 8'h60 | 8'h04 | (scc_chan_a ? 8'h08 : 8'h00);
    wire [7:0] scc_reg_rd = (scc_ptr == 8'd0)  ? scc_rr0
                          : (scc_ptr == 8'd1)  ? 8'h07
                          : (scc_ptr == 8'd15) ? 8'hF8
                                               : 8'h00;

    wire [7:0] clk_rd;
    wire [7:0] clk_cnt_strobes, clk_cnt_bad;
    gs_clock u_clock (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (u_addr[7:0]), .op_rw (u_rw), .op_wdata (u_wdata), .act (act),
        .rd_byte (clk_rd), .seed_time (seed_time), .border (border),
        // The host's battery RAM image, straight through (docs/GS.md).
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid), .bram_ok (bram_ok),
        .cnt_strobes (clk_cnt_strobes), .cnt_bad (clk_cnt_bad)
    );

    // ---- the IWM: the 3.5" drive and the two 5.25" drives (docs/IWM35.md) ----
    wire [7:0] iwm_rd, iwm_cnt_mode_wr;
    gs_iwm u_iwm (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (u_addr[7:0]), .op_rw (u_rw), .op_wdata (u_wdata), .act (act),
        .rd_byte (iwm_rd), .apple35_sel (c031_diskreg[6]), .c031_ctrl (c031_diskreg[7]),
        // The platters turn in the core's cycles alone: a nibble every 44.8
        // for the 3.5" drive and every 32 for a 5.25", whatever $C036 asks.
        .tick (core_tick),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .tx_word (fd35_word), .tx_valid (fd35_valid), .tx_take (fd35_take),
        .drv_inserted (fd35_inserted), .drv_wp (fd35_wp),
        .late_clr (fd35_late_clr), .fill_clr (fd35_fill_clr),
        .stale_o (fd35_stale), .track_o (fd35_track), .side_o (fd35_side),
        .motor35_o (fd35_motor35), .motor_o (fd35_motor), .ctl_o (fd35_ctl),
        .seeks (fd35_seeks), .late (fd35_late), .fill_max (fd35_fill_max),
        .d5_inserted (fd525_inserted), .d5_wp (fd525_wp),
        .d5_nibbles (fd525_nibbles), .d5_tracks (fd525_tracks),
        .d5_stale_o (fd525_stale), .d5_phase_o (fd525_phase),
        .stall_o (fd35_stall),
        .cnt_mode_wr (iwm_cnt_mode_wr)
    );

    // ---- the Ensoniq (docs/GS.md rung 7) ------------------------------------
    // The four registers at $C03C-$C03F were a FACE until this: latches that
    // read back what the ROM wrote, with a data port answering $00.  That is
    // what put "Unclaimed Sound Interrupt" on the screen - register $E0's bit
    // 7 CLEAR means an interrupt is pending, so a face answering zero claims
    // oscillator 0 is interrupting for ever.  rtl/gs_doc.sv is the chip.
    wire [7:0] doc_rd;
    wire       doc_irq;
    // Diagnostics a bench reads through the hierarchy; named rather than left
    // empty so the lint stays quiet about the pins.
    wire [7:0] doc_cnt_ends, doc_cnt_irqs;
    gs_doc u_doc (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (u_addr[7:0]), .op_rw (u_rw), .op_wdata (u_wdata), .act (act),
        .rd_byte (doc_rd),
        .snd_l (doc_l), .snd_r (doc_r),
        .irq (doc_irq),
        .cnt_ends (doc_cnt_ends), .cnt_irqs (doc_cnt_irqs)
    );

    // ---- the scan-line interrupt's trigger ---------------------------------
    // One bit per SCB: bit 6 of the byte as it lands at $E1/9D00 + line,
    // from a direct bank-$E1 write or the map's shadow duplicate of a bank-
    // $01 one - both land through the page cache, so one tap sees both.
    logic [199:0] scb_int;
    wire scb_hit = mw_stb && (mw_bank == 8'hE1) && (mw_addr[15:8] == 8'h9D) &&
                   (mw_addr[7:0] < 8'd200);
    // The start of a line: the column returning to zero.  scan_v/scan_h step
    // once per core cycle and hold for many clocks, so the edge is detected.
    logic [6:0] scan_h_q;
    logic       line_start;
    logic [7:0] line_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            scb_int <= 200'd0;
            scan_h_q <= 7'd0; line_start <= 1'b0; line_q <= 8'd0;
        end else begin
            if (scb_hit) scb_int[mw_addr[7:0]] <= mw_byte[6];
            scan_h_q   <= scan_h;
            line_start <= (scan_h == 7'd0) && (scan_h_q != 7'd0) && (scan_v < 9'd200);
            line_q     <= scan_v[7:0];
        end
    end
    // A registered pulse, so the 200:1 select is not in gs_intc's cone.
    logic irq_scan_q;
    always_ff @(posedge clk)
        irq_scan_q <= !rst && line_start && c029_newvideo[7] && scb_int[line_q];

    // ---- the interrupt controller -------------------------------------------
    wire [7:0] intc_rd, intc_c023, intc_c041;
    gs_intc u_intc (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (u_addr[7:0]), .op_rw (u_rw), .op_wdata (u_wdata), .act (act),
        .rd_byte (intc_rd), .frame_tick (frame_tick),
        .irq_adb (adb_irq_data || adb_irq_mouse), .irq_scan (irq_scan_q),
        .irq_doc (doc_irq),
        .irq (irq),
        .c023_o (intc_c023), .c041_o (intc_c041)
    );

    // ---- the fast reads (docs/LONG_DATA.md rung 3) ----------------------------
    // The same composition rd_byte makes above, for every address in the set
    // at once - checked against rd_byte on every internalized read below, so
    // the two cannot drift.
    logic [247:0] fr_vec_w;
    always_comb begin
        fr_vec_w = '0;
        for (int n = 1; n < 16; n = n + 1)
            fr_vec_w[8*(n-1) +: 8] = {(n == 9) ? vbl : stat_bits[n], kbd_low};
        fr_vec_w[8*15 +: 8] = {c021_mono, 7'd0};
        fr_vec_w[8*16 +: 8] = c022_color;
        fr_vec_w[8*17 +: 8] = intc_c023;
        fr_vec_w[8*18 +: 8] = adb_c025;
        fr_vec_w[8*19 +: 8] = adb_c027;
        fr_vec_w[8*20 +: 8] = c029_newvideo;
        fr_vec_w[8*21 +: 8] = c02b_langsel;
        fr_vec_w[8*22 +: 8] = gs_sltrom;
        fr_vec_w[8*23 +: 8] = vid_cnt[8:1];
        fr_vec_w[8*24 +: 8] = {vid_cnt[0], (scan_h == 7'd0) ? 7'd0 : ((scan_h + 7'h3F) & 7'h7F)};
        fr_vec_w[8*25 +: 8] = gs_shadow;
        fr_vec_w[8*26 +: 8] = gs_cyareg;
        fr_vec_w[8*27 +: 8] = intc_c041;
        fr_vec_w[8*28 +: 8] = {(pb_sel[1:0] == 2'b00) ? adb_c025[7] : pb_sel[1], 7'd0};
        fr_vec_w[8*29 +: 8] = {(pb_sel[3:2] == 2'b00) ? adb_c025[6] : pb_sel[3], 7'd0};
        fr_vec_w[8*30 +: 8] = gs_state;
    end
    assign fr_vec = fr_vec_w;
`ifndef SYNTHESIS
    wire [5:0] u_fr = gs_fr_sel(u_addr[7:0]);
    always @(posedge clk)
        if (!rst && act && u_rw && u_fr[5] && fr_vec_w[8*u_fr[4:0] +: 8] !== rd_byte)
            $error("gs_io: fast-read byte for $%02x/%04x is %02x, the read mux says %02x",
                   u_bank, u_addr, fr_vec_w[8*u_fr[4:0] +: 8], rd_byte);
`endif

    // ---- the latches above, written on the op's commit -----------------------
    // The DOC's data port is the one with behaviour: a read returns the
    // PREVIOUS fetch and starts a new one (KEGS doc_read_c03d, "one-access
    // read delay"), and both a read and a write step the pointer when the
    // control register's auto-increment bit is set.  There is no DOC behind it
    // yet - the oscillators and their 64 KB are rung 7 - so a fetch returns
    // zero; what the ROM's boot needs is the FACE.
    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            c021_mono <= 1'b0;
            c022_color <= 8'hF0;        // white on black, the ROM's own default
            // KEGS's own power-on: g_c029_val_some = 0x41 (moremem.c:53), so
            // LINEARISE IS SET AT RESET and bit 0 with it.  This was $01 -
            // linearise clear - which is not what a IIgs comes up as.
            c029_newvideo <= 8'h41;
            c02b_langsel <= 8'h00;
            c031_diskreg <= 8'h00;
            scc_ptr <= 8'd0;
        end else if (act) begin
            if (!u_rw) begin
                case (u_addr[7:0])
                    8'h21: c021_mono <= u_wdata[7];
                    8'h22: c022_color <= u_wdata;
                    // $C029 NEWVIDEO, as KEGS keeps it (moremem.c:1085,1616).
                    // KEGS splits the register: bits 6 and 0 are stored
                    // (`g_c029_val_some = val & 0x41`) and bits 7 and 5 go to
                    // the video state (`new_tmp = val & 0xa0`), and the READ
                    // recombines them - so the byte a program reads back is
                    // `val & 0xE1`.  This masked with $A0 and forced bit 0,
                    // which DISCARDED BIT 6: a program that turned linear
                    // addressing on and read it back was told it had not.
                    8'h29: c029_newvideo <= u_wdata & 8'hE1;
                    8'h2B: c02b_langsel <= u_wdata;
                    8'h31: c031_diskreg <= u_wdata & 8'hC0;
                    // The SCC's write-register pointer protocol: a write to
                    // the command port selects a register, and the write
                    // after it goes there and returns the pointer to 0.
                    8'h38, 8'h39: scc_ptr <= (scc_ptr == 8'd0) ? (u_wdata & 8'h0F) : 8'd0;
                    default: ;
                endcase
            end else begin
                case (u_addr[7:0])
                    // A read of the command port returns the pointer to 0 too.
                    8'h38, 8'h39: scc_ptr <= 8'd0;
                    default: ;
                endcase
            end
        end
    end

    // q_rw is not consulted yet: every address claimed here answers both a
    // read and a write.  It is a port because the registers that do not -
    // the write-only strobes, and $C02E/$C02F which read the beam and ignore
    // a write - arrive with the VGC.
    wire _unused_q_rw = q_rw;

endmodule
