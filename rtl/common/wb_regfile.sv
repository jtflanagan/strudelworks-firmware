`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// wb_regfile - the card's control registers, as a Wishbone B4 slave.
//
// WHY A SECOND WISHBONE AND NOT THE DDR3 ONE.  The DDR3 bus is 128 bits wide and
// its address is a BURST INDEX, not a byte address - one Wishbone word is one
// DDR3 burst (see docs/DDR3_USAGE.md).  That shape is right for bulk memory and
// wrong for control registers, which want 32 bits and a byte address.  So this
// is a separate 32-bit Wishbone instance rather than a decode off the DDR3 bus:
// same protocol, different geometry, and neither distorts the other.
//
// They stay independently addressable because they are in disjoint regions of
// the host-visible 32-bit address space:
//
//   0x0000_0000 .. 0x0FFF_FFFF   DDR3    (2^24 bursts x 16 bytes = 256 MB)
//   0x8000_0000 .. 0x8000_FFFF   registers
//
// so one address bit tells them apart and neither has to know the other exists.
//
// Registers are 32 bits, word aligned.  A read of an unimplemented address
// returns zero and acks; a write to a read-only or unimplemented address is
// accepted and discarded.  Neither errs, deliberately: the host discovers what
// exists by reading it, and an ERR on this bus would have to be plumbed all the
// way back through the message layer to say something the value already says.
//
// TIMING: single-cycle ack, never stalls.  A register file that made the host
// wait would be measuring nothing but itself.
//////////////////////////////////////////////////////////////////////////////////
module wb_regfile #(
    // THE MINIMUM (the user, 2026-09-19, docs/CORE_REFACTOR_65C02.md rung 2):
    // the 65C02 card builds the register file with only what the host needs
    // to bring the machine up and run it - the stamps, every control word,
    // the hold and start words, the link's and the DDR3's status - and every
    // counter, census, statistic and debug word reads ZERO.  Their shadows,
    // their read arms and, upstream, the counters that fed them fall out of
    // the netlist.  What comes back in is decided later, word by word.
    // MINIMAL = 1: the 65C02 card's register file (docs/CORE_REFACTOR_65C02.md
    // rung 2): every counter, census, stat and debug word reads 0 EXCEPT the
    // accelerator's own family (ACCEL_FAST..ACCEL_FAST_KBD, CORE_CYC/BUS_CYC),
    // which is the instrument every hardware measurement is read from - the
    // host's PLAIN ratio and its on-screen figure went blank without it
    // (2026-09-19, the first a2 bitstream on hardware).
    parameter bit MINIMAL = 1'b0,
    // log2 of the page cache's pages (SETS x WAYS x 256 bytes), for
    // MEM_CTRL's readback: the host renders the cache's size from it.
    parameter integer MEM_PAGES_LOG2 = 10,
    // Stamped by build/build.sh through build.tcl's -generic.  Zero means the
    // bitstream was built without a stamp - an interactive GUI build - and the
    // host is expected to say "unstamped" rather than render it as a date.
    parameter integer BUILD_DATE = 0,   // YYYYMMDD
    parameter integer BUILD_TIME = 0,   // HHMMSS

    // Top half of the byte address that selects this block.  The full 32-bit
    // address arrives here and the region is decoded HERE rather than upstream,
    // so that an access outside it still acks: a decode that simply withheld
    // ack would hang the bridge waiting for a reply that is never coming, and
    // the host would see a dead link rather than a bad address.
    parameter [15:0] REGION = 16'h8000,

    // 1 only in a bitstream whose top can actually assert DMA' and drive the
    // Apple bus.  The register below exists in EVERY build so the host reads it
    // the same way everywhere; this is how the host tells a snooper from a
    // master, and it is what stops a snoop build ever latching itself into
    // "the soft CPU is driving" when nothing in it can drive.
    parameter bit CAN_MASTER = 1'b0,
    // WHICH MACHINE THIS BITSTREAM IS (docs/GS.md rung 4).  Read back in
    // CPU_SOURCE bit 17 so the host can refuse a `machine = iigs` config on
    // a IIe bitstream, and the other way round, instead of running a machine
    // whose ROM and whose map disagree about what it is - which looks like a
    // dead screen and nothing else.
    parameter bit GS = 1'b0
) (
    input  wire            clk,
    input  wire            rst,

    // Synchronised RES', ACTIVE LOW, from apple_bus_read.
    input  wire            apple_res_sync,

    // Which CPU owns the bus.  A master top drives DMA' and the address/data
    // enables from this; see docs/BUS_MASTER.md.
    output wire            cpu_source_active,

    // Which slot the on-card Mockingboard answers as; 0 keeps it out of the
    // machine entirely.  Latched the same way CPU_SOURCE is - see below.
    // mb_phasor_active: the card in that slot is a Phasor rather than a
    // Mockingboard (rtl/mockingboard.sv), latched with the slot.
    output wire [2:0]      mb_slot_active,
    output wire            mb_phasor_active,

    // The boot hold (rtl/boot_hold.sv).  arm is a level the host sets;
    // release is a one-cycle pulse per write of the release bit; held comes
    // back from the hold itself, for the readback.  A watching top ties held
    // to 0 and leaves the rest unconnected.
    output wire            boot_arm,
    output logic           boot_release,
    input  wire            boot_held,
    // ...and which door the hold in progress came in by (rtl/boot_hold.sv):
    // 1 for the runtime menu's, 0 for the boot's.  Read back beside `held`,
    // and it decides whether a release re-latches the slots.
    input  wire            hold_runtime,

    // The runtime menu's door (rtl/boot_hold.sv, docs/RUNTIME_MENU.md):
    // watch for the hotkey, which key, and the host's own knock - a
    // one-cycle pulse per write of the trigger bit.  A watching top leaves
    // them unconnected.
    output logic           menu_en,
    output logic [6:0]     menu_hotkey,
    output logic           menu_trigger,

    // The hard disk (rtl/hd_card.sv).  The slot is latched at RES' like the
    // Mockingboard's; the rest is status coming back for the readback.  A
    // watching top ties the inputs to 0 and leaves the output unconnected.
    output wire [2:0]      hd_slot_active,
    input  wire            hd_rom_loaded,
    input  wire            hd_busy,
    input  wire [7:0]      hd_execs,

    // The floppy (rtl/floppy_card.sv, docs/FLOPPY.md).  The slot latches
    // like the disk's; what is IN each drive is live, because the runtime
    // menu changes a disk under a running program; the rest is the
    // controller's state coming back for the readback.  A watching top ties
    // the inputs to 0 and leaves the outputs unconnected.
    output wire [2:0]      fd_slot_active,
    input  wire            fd_rom_loaded,
    input  wire [7:0]      fd_seeks,
    output logic [1:0]     fd_inserted,
    output logic [1:0]     fd_wp,
    output logic [25:0]    fd_nibbles,      // [12:0] drive 1, [25:13] drive 2
    output logic [11:0]    fd_tracks,       // [5:0] drive 1, [11:6] drive 2
    output logic [1:0]     fd_flush,        // pulses
    input  wire [1:0]      fd_stale,
    input  wire [1:0]      fd_dirty,
    input  wire [13:0]     fd_phase,        // [6:0] drive 1, [13:7] drive 2
    input  wire [3:0]      fd_ctl,          // {q7, q6, drive_sel, motor}
    input  wire [7:0]      fd_late,
    input  wire [15:0]     fd_fill_max,
    output logic           fd_late_clr,     // pulses
    output logic           fd_fill_clr,

    // The 3.5" drive on the IWM (rtl/gs_iwm.sv, docs/IWM35.md): what is in
    // it is live, as the Disk II's drives are; the rest is its readback.  A
    // watching top ties the inputs to 0 and leaves the outputs unconnected.
    output logic           fd35_inserted,
    output logic           fd35_wp,
    input  wire            fd35_stale,
    input  wire [6:0]      fd35_track,
    input  wire            fd35_side,
    input  wire            fd35_motor35,
    input  wire            fd35_motor,
    input  wire [7:0]      fd35_ctl,        // {phases, q7, q6, drive_sel, apple35_sel}
    input  wire [7:0]      fd35_seeks,
    input  wire [7:0]      fd35_late,
    input  wire [31:0]     fd35_wstat,
    input  wire [15:0]     fd35_fill_max,
    output logic           fd35_late_clr,   // pulses
    output logic           fd35_fill_clr,

    // The VidHD (rtl/vidhd_card.sv, docs/VIDHD.md): its slot latched like
    // the floppy's, and whether its ROM has landed, for the readback.  A
    // watching top ties the input to 0 and leaves the output unconnected.
    output wire [2:0]      vidhd_slot_active,
    input  wire            vidhd_rom_loaded,
    // The mouse (rtl/mouse_card.sv, docs/MOUSE.md): its slot latched like
    // the VidHD's, yielding to all four of the others; MOUSE_STAT reads
    // the card's position and the rest for diagnosis.
    output wire [2:0]      mouse_slot_active,
    input  wire            mouse_rom_loaded,
    input  wire            mouse_irq,
    input  wire [3:0]      mouse_mode,
    input  wire [1:0]      mouse_buttons,
    input  wire [7:0]      mouse_moves,
    input  wire [15:0]     mouse_x,
    input  wire [15:0]     mouse_y,
    // The Uthernet II (rtl/uthernet2_card.sv, docs/UTHERNET2.md): its slot
    // latched like the mouse's, yielding to all five of the others; the
    // card's counters for U2_SLOT and socket 0's two numbers for U2_STAT.
    output wire [2:0]      u2_slot_active,
    input  wire [3:0]      u2_sock_open,
    input  wire            u2_cmd_dropped,
    input  wire [7:0]      u2_cmds,
    input  wire [7:0]      u2_rx_chunks,
    input  wire [15:0]     u2_s0_rsr,
    // The printer card (rtl/printer_card.sv, docs/PRINTER.md): its slot
    // latched like the Uthernet II's, yielding to all six of the others.
    output wire [2:0]      printer_slot_active,
    input  wire            printer_rom_loaded,
    input  wire [7:0]      printer_writes,
    input  wire [15:0]     u2_s0_fsr,
    // The No-Slot Clock (rtl/no_slot_clock.sv, docs/NSC.md): its lever,
    // and its state and the host's time for NSC_CTRL / NSC_TIME / NSC_DATE.
    output wire            nsc_enable,
    // RING_CTRL[0]: engage the DDR3 ring (rtl/tx_ring.sv's boot lane)
    output wire            ring_engage,
    input  wire            nsc_time_loaded,
    input  wire            nsc_ring_en,
    input  wire            nsc_wr_en,
    input  wire [5:0]      nsc_cmp_idx,
    input  wire [5:0]      nsc_ring_idx,
    input  wire [7:0]      nsc_unlocks,
    input  wire [63:0]     nsc_now,

    // Keyboard injection (rtl/kbd_inject.sv).  press and drop are one-cycle
    // pulses per write of their bits, press_key the key that write carried;
    // lock and notify are levels the host holds.  The flags and the counts
    // come back for the readback: kbd_flags is {touched, seen, strobe},
    // kbd_counts is {replaced, flushed, taken, pressed} - the notice's
    // payload word, and the two registers slice it.  A watching top ties
    // the inputs to 0 and leaves the outputs unconnected.
    output logic           kbd_press,
    output logic [6:0]     kbd_press_key,
    output logic           kbd_drop,
    output logic           kbd_lock,
    output logic           kbd_notify,
    input  wire [2:0]      kbd_flags,
    input  wire [31:0]     kbd_counts,

    // The pushbuttons (rtl/pb_inject.sv): the host's word per button out,
    // the hardware's level back for the readback.
    output logic [5:0]     pb_override,
    input  wire [2:0]      pb_hw,

    // The VBL lock (rtl/vbl_lock.sv, docs/VBL.md): start and probe are
    // one-cycle pulses per write of their bits, notify and probe_addr
    // levels; the rest is the detector's state coming back for the
    // readback.  A watching top ties the inputs to 0.
    output logic           vbl_start,
    output logic           vbl_probe,
    output logic           vbl_notify,
    output logic [15:0]    vbl_probe_addr,
    input  wire [3:0]      vbl_state,
    input  wire            vbl_locked,
    input  wire            vbl_pal,
    input  wire            vbl_busy,
    input  wire [3:0]      vbl_err,
    input  wire [31:0]     vbl_stat,
    input  wire [31:0]     vbl_pos,

    // The memory image and its page cache (rtl/page_cache.sv, rtl/page_client.sv,
    // docs/MEMORY.md): MEM_CTRL's serve bits out as levels and its W1 bits as
    // pulses; the shadow's switches, the counters and the state back for the
    // readback.  A watching top ties the inputs to 0 and leaves the outputs
    // unconnected.
    output logic           mem_serve,       // all-or-nothing serve enable
    output logic           mem_cnt_clr,     // pulses
    output logic           mem_inval,
    input  wire [11:0]     mem_sw,
    input  wire [7:0]      mem_rw_bank,     // the RamWorks bank register
    input  wire            mem_image_ready,
    input  wire            mem_invalidating,
    input  wire            mem_rom_loaded,
    input  wire [7:0]      mem_late_fills,
    input  wire [7:0]      mem_fifo_drops,
    input  wire [31:0]     mem_fills,       // pages filled from the DDR3
    input  wire [31:0]     mem_flushes,     // ...and dirty ones written back
    input  wire [31:0]     mem_declines,    // line requests a page was not resident for
    input  wire            mem_rom_busy,    // the ROM load is draining: the host waits
    input  wire [31:0]     mem_rom_sum,     // the sum of every chunk's first landing (CS2)
    input  wire [7:0]      mem_rom_over,    // ...and chunks it had to drop
    // ABSOLUTE chunks drained whole: the card's extended ROM ($E2-$EE), which
    // the base ROM's `rom_ok` says nothing about (docs/GS_CONTROL_PANEL.md).
    input  wire [7:0]      mem_rom_xland,
    input  wire [31:0]     gs_adb_stat,     // GS_ADB_STAT, the ADB micro's mouse path (rtl/gs_adb.sv)
    input  wire [31:0]     gs_clock_stat,   // GS_CLOCK_STAT, the clock chip's state (rtl/gs_clock.sv stat)
    // PANEL_STAT: the host's replies to our 65816 panel, carried by the HD
    // card's DMA write (docs/GS_CONTROL_PANEL.md R4).  [7:0] blocks written,
    // [15:8] messages dropped because a disk command was in flight.
    input  wire [3:0]      panel_dmas,
    input  wire [3:0]      panel_drops,
    input  wire [31:0]     cnt_core_cyc,    // ACCEL_CORE_CYC (master_top): the plain ratio's numerator
    input  wire [31:0]     cnt_bus_cyc,     // ACCEL_BUS_CYC: ...and its denominator
    // THE DEBUG PAIR (docs/GS.md rung 6).  DBG_SEL picks a counter or a state
    // snapshot out of the fronts, the page cache and the dispatcher; DBG_VAL
    // reads it.  [5:4] the module (0 iline, 1 dline, 2 the page cache, 3 the
    // dispatcher and the top), [3:0] the item - rtl/master_top.sv's mux.
    input  wire [31:0]     dbg_val,
    output logic [7:0]     dbg_sel,
    // THE SHADOW DUPLICATE'S DROPS (the IIgs's $C035; docs/GS.md rung 3e).
    // The map emits a shadowed write's duplicate one clock behind the write
    // itself, one deep - and a drop is a write the Mega II banks never got,
    // which is a byte missing from the picture and from nothing else, so
    // nothing else would ever report it.  A bench asserts this is zero;
    // hardware has to be able to say so too.  Always zero at GS = 0.
    input  wire [7:0]      mem_shd_drops,
    input  wire [31:0]     mem_hits,
    input  wire [31:0]     mem_misses,
    input  wire [31:0]     mem_mismatch,
    input  wire [31:0]     mem_served,
    input  wire [31:0]     mem_last,
    input  wire [31:0]     mem_diverted,
    input  wire            mem_intc8rom,    // the MMU shadow's INTC8ROM latch

    // The accelerated core (rtl/accel_seq.sv, docs/ACCELERATION.md):
    // ACCEL_CTRL's levels and its pulse out, the sequencer's status and
    // counters back.  A watching top ties the inputs to 0 and leaves the
    // outputs unconnected.
    output logic [1:0]     accel_mode,
    output logic           accel_swint_dis, // [28]: no internalized keyboard, dummies at $0000
    output logic           accel_game_dis,  // [27]: no internalized game port, dummies at $C000 only
    output logic           accel_l1_dis, // [29]: the fronts bypassed - the core takes the
                                             // dispatcher's byte on both streams and neither
                                             // front retires (a diagnosis level, IIgs only)
    // The game port's samples, for GAME_STAT (rtl/game_port.sv).
    input  wire [2:0]      game_pb,
    input  wire            game_pb_ok,
    input  wire            game_pdl_ok,
    input  wire [11:0]     game_pdl0,
    input  wire [11:0]     game_pdl1,
    input  wire [11:0]     game_pdl2,
    input  wire [11:0]     game_pdl3,
    input  wire [7:0]      game_meas,
    output logic [15:0]    accel_target,
    output logic           accel_cnt_clr,   // pulses
    input  wire [31:0]     accel_stat,
    input  wire [31:0]     accel_fast,
    input  wire [31:0]     accel_bus,
    input  wire [31:0]     accel_cycles,
    input  wire [31:0]     accel_wait,
    input  wire [31:0]     accel_turbo,   // the front's one-clock ops (rtl/iline.sv)
    input  wire [31:0]     accel_dline,   // the data front's one-clock ops, reads and writes (rtl/dline.sv)
    input  wire [31:0]     accel_maps,    // map changes (rtl/apple_mmu.sv's map_changed)
    input  wire [31:0]     accel_ddrop,   // lines a map change took out of service (rtl/dline.sv)
    input  wire [31:0]     accel_drevive, // ...and lines a later one put back
    input  wire [31:0]     accel_idrop,   // the same pair for the instruction front
    input  wire [31:0]     accel_irevive,
    input  wire            accel_cen_v,   // the census (rtl/fast_census.sv, below): a retired dispatcher op...
    input  wire [2:0]      accel_cen_sel, // ...and its bucket

    // The floating-bus simulator (rtl/fb_sim.sv, docs/FLOATING_BUS.md):
    // FB_CTRL's serve level and its clear pulse, FB_PEEK's address; the mode
    // bits, the counters and the peeked byte back.  A watching top ties the
    // inputs to 0 and leaves the outputs unconnected.
    output logic           fb_serve,
    output logic           fb_cnt_clr,      // pulses
    output logic [14:0]    fb_peek_addr,
    input  wire [6:0]      fb_mode,
    input  wire [31:0]     fb_compared,
    input  wire [31:0]     fb_mismatch,
    input  wire [31:0]     fb_last,
    input  wire [31:0]     fb_last2,
    input  wire [31:0]     fb_other,
    input  wire [7:0]      fb_peek_data,

    // Programmatic Ctrl-Reset.  Held low while pulsing; the master top turns
    // this into an open-drain drive of the Apple's RES' line, exactly as it
    // drives DMA'.  A snoop build ties CAN_MASTER low, so this never asserts
    // and its pin stays an input.  See docs/BUS_MASTER.md.
    output wire            res_drive,
    // The start hold (rtl/start_hold.sv, docs/CLEAN_START.md CS1): pending,
    // its causes and the count of holds, for START_HELD in card_link.
    output wire            start_pending,
    output wire            start_cause_card,
    output wire            start_cause_res,
    output wire [7:0]      start_count,

    // Wishbone B4 classic, 32-bit.
    // RING_STATUS, straight from tx_ring: the DDR3 ring's occupancy in
    // lines, whether it is full, and whether the DDR3 has calibrated at all.
    input  wire [31:0]     ring_status,
    // LINK_STAT, from card_link: the card's own view of the link - the UART
    // status line's facts the host could not see over USB3 (phi0 ticking,
    // capture enabled, the link's last reset), so the UART is needed only
    // when no register answers at all.
    input  wire [31:0]     link_stat,
    // DDR3_DBG1..3, UberDDR3's debug words through rtl/ddr3_wrapper.sv: the
    // calibration FSM's state and taps, the sticky restart counters, the DQS
    // indices - readable whether or not the DDR3 calibrated (docs/UBERDDR3.md).
    input  wire [31:0]     ddr3_dbg1,
    input  wire [31:0]     ddr3_dbg2,
    input  wire [31:0]     ddr3_dbg3,
    input  wire [31:0]     ddr3_dbg4,
    // DDR3_EYE0/1: the read data eye of byte lane 0 and 1, one bit per DQ
    // IDELAY tap, measured by the controller after every calibration.
    input  wire [31:0]     ddr3_eye0,
    input  wire [31:0]     ddr3_eye1,
    // The sound (docs/AUDIO.md): AUDIO_CTRL's bits as levels - the stream
    // on, the AYs clocked in real time - the NCO increment, and the
    // sampler's counters back for AUDIO_STAT.
    output wire            audio_on,
    output wire            audio_realtime,
    output wire [31:0]     audio_rate,
    input  wire [31:0]     audio_stat,
    // THE REGISTER CUT's hold (below, "the register cut"): while high the
    // shadows every read-only readback is read through stop following their
    // sources, so a sweep of the map reads ONE instant.  The telemetry
    // sender raises it for its sweep and nobody else reads meanwhile; a top
    // without one ties it low.
    input  wire            snap_hold,
    // TELEMETRY (rtl/telem_tx.sv, docs/TELEMETRY.md): TELEM_CTRL's enable out,
    // the sender's counts back, and RES' as THIS file's flop holds it - the
    // sender's release detector taps the flop rather than put another load
    // on the synchroniser's net, which the core's reset hangs from.
    output wire            telem_on,
    input  wire [23:0]     telem_stat,      // {sent, drops, epoch}
    output wire            apple_res_q,
    input  wire            wb_cyc,
    input  wire            wb_stb,
    input  wire            wb_we,
    input  wire [31:0]     wb_adr,     // full byte address
    input  wire [31:0]     wb_dat_w,
    input  wire [3:0]      wb_sel,
    output logic           wb_ack,
    output wire            wb_stall,
    output logic [31:0]    wb_dat_r
);

    // Word index within the region: the low two bits are byte lanes and are not
    // decoded, so a misaligned address reads the word containing it rather than
    // erring - the same forgiving treatment as an unknown address.
    wire        in_region = (wb_adr[31:16] == REGION);
    wire [13:0] word      = wb_adr[15:2];

    // ---- the map ------------------------------------------------------------
    // Adding a register is one localparam and one case arm.  Keep the numbering
    // dense and never reuse a retired number: a host built against an older map
    // reading a recycled address gets a plausible wrong answer, which is worse
    // than the zero it would get from a hole.
    localparam [13:0] R_BUILD_DATE = 'd0;   // 0x8000_0000, RO
    localparam [13:0] R_BUILD_TIME = 'd1;   // 0x8000_0004, RO
    localparam [13:0] R_CPU_SOURCE = 'd2;   // 0x8000_0008, RW in bit 0
    localparam [13:0] R_MB_SLOT    = 'd3;   // 0x8000_000C, RW in bits 2:0
    localparam [13:0] R_BOOT_HOLD  = 'd4;   // 0x8000_0010, RW bit 0, W1 bit 16
    localparam [13:0] R_HD_SLOT    = 'd5;   // 0x8000_0014, RW in bits 2:0
    localparam [13:0] R_RESET      = 'd6;   // 0x8000_0018, W1 bit 0 pulses RES'
    localparam [13:0] R_START      = 'd86;  // 0x8000_0158, the start hold; W1 bit 0 releases
    localparam [13:0] R_ROM_SUM    = 'd87;  // 0x8000_015C, RO, the ROM's sum of first landings
    localparam [13:0] R_PANEL_STAT      = 'd88; // 0x8000_0160, RO the panel's DMA: {drops, dmas}
    localparam [13:0] R_FD35_WSTAT      = 'd89; // 0x8000_0164, RO the 3.5" write path
    localparam [13:0] R_TELEM_CTRL      = 'd90; // 0x8000_0168, RW bit 0: the telemetry message
    // THE WIDE COUNTERS (docs/TELEMETRY.md layout 2): 32-bit totals kept here
    // of the narrow event counts that can wrap inside a second - so a sample
    // a second apart never loses a wrap.  Each follows its source a clock
    // behind, adding (now - before) mod 2^n; cleared with the source, by the
    // card's reset alone.
    localparam [13:0] R_WIDE_U2_CMDS    = 'd91; // 0x8000_016C, RO U2_SLOT's cmds, 32 bits
    localparam [13:0] R_WIDE_U2_RX      = 'd92; // 0x8000_0170, RO U2_SLOT's rx chunks
    localparam [13:0] R_WIDE_PRN_WRITES = 'd93; // 0x8000_0174, RO PRINTER_SLOT's writes
    localparam [13:0] R_WIDE_HD_EXECS   = 'd94; // 0x8000_0178, RO HD_SLOT's execs
    localparam [13:0] R_WIDE_PANEL_DMAS = 'd95; // 0x8000_017C, RO PANEL_STAT's dmas
    localparam [13:0] R_WIDE_AUDIO_SENT = 'd96; // 0x8000_0180, RO AUDIO_STAT's samples sent
    localparam [13:0] R_KBD_INJECT = 'd7;   // 0x8000_001C, W bits 6:0, W1 bits 7-8
    localparam [13:0] R_BUTTONS    = 'd8;   // 0x8000_0020, RW bits 5:0
    localparam [13:0] R_RING_STATUS = 'd9;  // 0x8000_0024, RO
    localparam [13:0] R_KBD_CTRL   = 'd10;  // 0x8000_0028, RW bits 1:0
    localparam [13:0] R_MENU_HOLD  = 'd11;  // 0x8000_002C, RW bits 7:0, W1 bit 8
    localparam [13:0] R_VBL_CTRL   = 'd12;  // 0x8000_0030, W1 bits 1:0, RW bit 2, RW bits 31:16
    localparam [13:0] R_VBL_STAT   = 'd13;  // 0x8000_0034, RO
    localparam [13:0] R_VBL_POS    = 'd14;  // 0x8000_0038, RO
    localparam [13:0] R_FD_SLOT    = 'd15;  // 0x8000_003C, RW in bits 2:0
    localparam [13:0] R_FD_DRIVE1  = 'd16;  // 0x8000_0040, RW bits 21:0, W1 bit 22
    localparam [13:0] R_FD_DRIVE2  = 'd17;  // 0x8000_0044, the same
    localparam [13:0] R_FD_STAT    = 'd18;  // 0x8000_0048, W1 bits 1:0
    localparam [13:0] R_MEM_CTRL   = 'd19;  // 0x8000_004C, RW bits 2:0, W1 bits 9:8
    localparam [13:0] R_MEM_STAT   = 'd20;  // 0x8000_0050, RO
    localparam [13:0] R_MEM_HITS   = 'd21;  // 0x8000_0054, RO
    localparam [13:0] R_MEM_MISSES = 'd22;  // 0x8000_0058, RO
    localparam [13:0] R_MEM_MISMATCH = 'd23; // 0x8000_005C, RO
    localparam [13:0] R_MEM_SERVED = 'd24;  // 0x8000_0060, RO
    localparam [13:0] R_MEM_LAST   = 'd25;  // 0x8000_0064, RO
    localparam [13:0] R_MEM_DIVERTED = 'd26; // 0x8000_0068, RO
    localparam [13:0] R_VIDHD_SLOT = 'd27;  // 0x8000_006C, RW in bits 2:0
    localparam [13:0] R_FB_CTRL    = 'd28;  // 0x8000_0070, RW bit 0, W1 bit 8
    localparam [13:0] R_FB_COMPARED = 'd29; // 0x8000_0074, RO
    localparam [13:0] R_FB_MISMATCH = 'd30; // 0x8000_0078, RO
    localparam [13:0] R_FB_LAST    = 'd31;  // 0x8000_007C, RO
    localparam [13:0] R_FB_LAST2   = 'd32;  // 0x8000_0080, RO
    localparam [13:0] R_FB_OTHER   = 'd33;  // 0x8000_0084, RO
    localparam [13:0] R_FB_PEEK    = 'd34;  // 0x8000_0088, RW bits 14:0
    localparam [13:0] R_ACCEL_CTRL = 'd35;  // 0x8000_008C, RW bits 1:0, 23:8, 24; W1 bit 31
    localparam [13:0] R_ACCEL_STAT = 'd36;  // 0x8000_0090, RO
    localparam [13:0] R_ACCEL_FAST = 'd37;  // 0x8000_0094, RO
    localparam [13:0] R_ACCEL_BUS  = 'd38;  // 0x8000_0098, RO
    localparam [13:0] R_ACCEL_CYCLES = 'd39; // 0x8000_009C, RO
    localparam [13:0] R_ACCEL_WAIT = 'd40;  // 0x8000_00A0, RO
    localparam [13:0] R_ACCEL_TURBO = 'd41; // 0x8000_00A4, RO
    localparam [13:0] R_ACCEL_DLINE = 'd42; // 0x8000_00A8, RO
    localparam [13:0] R_ACCEL_FAST_I = 'd43; // 0x8000_00AC, RO
    localparam [13:0] R_ACCEL_FAST_DRAM = 'd44; // 0x8000_00B0, RO
    localparam [13:0] R_ACCEL_FAST_DLC = 'd45; // 0x8000_00B4, RO
    localparam [13:0] R_ACCEL_FAST_DROM = 'd46; // 0x8000_00B8, RO
    localparam [13:0] R_ACCEL_FAST_DCX = 'd47; // 0x8000_00BC, RO
    localparam [13:0] R_ACCEL_FAST_WR = 'd48; // 0x8000_00C0, RO
    localparam [13:0] R_ACCEL_FAST_KBD = 'd49; // 0x8000_00C4, RO
    localparam [13:0] R_GAME_STAT      = 'd50; // 0x8000_00C8, RO
    localparam [13:0] R_GAME_STAT2     = 'd51; // 0x8000_00CC, RO
    localparam [13:0] R_MOUSE_SLOT     = 'd52; // 0x8000_00D0, RW in bits 2:0
    localparam [13:0] R_MOUSE_STAT     = 'd53; // 0x8000_00D4, RO
    localparam [13:0] R_NSC_CTRL       = 'd54; // 0x8000_00D8, RW bit 0
    localparam [13:0] R_RING_CTRL      = 'd98; // 0x8000_0188, RW bit 0: engage the DDR3 ring (REQ_65C02.md 1.10)
    localparam [13:0] R_NSC_TIME       = 'd55; // 0x8000_00DC, RO
    localparam [13:0] R_NSC_DATE       = 'd56; // 0x8000_00E0, RO
    localparam [13:0] R_U2_SLOT        = 'd57; // 0x8000_00E4, RW in bits 2:0
    localparam [13:0] R_U2_STAT        = 'd58; // 0x8000_00E8, RO
    localparam [13:0] R_LINK_STAT      = 'd59; // 0x8000_00EC, RO
    localparam [13:0] R_AUDIO_CTRL     = 'd60; // 0x8000_00F0, RW bits 1:0 (docs/AUDIO.md)
    localparam [13:0] R_AUDIO_RATE     = 'd61; // 0x8000_00F4, RW
    localparam [13:0] R_AUDIO_STAT     = 'd62; // 0x8000_00F8, RO
    localparam [13:0] R_PRINTER_SLOT   = 'd63; // 0x8000_00FC, RW in bits 2:0
    // The memory rethink's census (docs/PAGE_CACHE.md).  'd65-'d68 are
    // reserved for the fronts' drop/revive counters, 'd69.. for the physical
    // page cache's; a word an older bitstream does not implement reads zero.
    localparam [13:0] R_ACCEL_MAPS      = 'd64; // 0x8000_0100, RO
    localparam [13:0] R_ACCEL_IDROP     = 'd65; // 0x8000_0104, RO
    localparam [13:0] R_ACCEL_IREVIVE   = 'd66; // 0x8000_0108, RO
    localparam [13:0] R_ACCEL_DDROP     = 'd67; // 0x8000_010C, RO
    localparam [13:0] R_ACCEL_DREVIVE   = 'd68; // 0x8000_0110, RO
    localparam [13:0] R_MEM_FILLS       = 'd69; // 0x8000_0114, RO
    localparam [13:0] R_MEM_FLUSHES     = 'd70; // 0x8000_0118, RO
    localparam [13:0] R_MEM_DECLINES    = 'd71; // 0x8000_011C, RO
    localparam [13:0] R_MEM_ROM         = 'd72; // 0x8000_0120, RO
    localparam [13:0] R_GS_ADB          = 'd73; // 0x8000_0124, RO (rtl/gs_adb.sv dbg_stat)
    localparam [13:0] R_ACCEL_CORE_CYC  = 'd74; // 0x8000_0128, RO core cycles (vbeam's ticks)
    localparam [13:0] R_ACCEL_BUS_CYC   = 'd75; // 0x8000_012C, RO raw bus cycles
    localparam [13:0] R_DBG_SEL         = 'd76; // 0x8000_0130, RW the debug pair's select
    localparam [13:0] R_DBG_VAL         = 'd77; // 0x8000_0134, RO ...and its value
    localparam [13:0] R_FD35_DRIVE      = 'd78; // 0x8000_0138, RW bits 1:0: the 3.5" drive
    localparam [13:0] R_FD35_STAT       = 'd79; // 0x8000_013C, W1 bits 1:0
    localparam [13:0] R_DDR3_DBG1       = 'd80; // 0x8000_0140, RO UberDDR3 o_debug1 (calibration state, lane, taps, max state)
    localparam [13:0] R_DDR3_DBG2       = 'd81; // 0x8000_0144, RO UberDDR3 o_debug2 (sticky restart counters)
    localparam [13:0] R_DDR3_DBG3       = 'd82; // 0x8000_0148, RO UberDDR3 o_debug3 (DQS indices)
    localparam [13:0] R_DDR3_DBG4       = 'd97; // 0x8000_0184, RO UberDDR3 o_debug4 (the CK phase the write leveling parked at)
    localparam [13:0] R_DDR3_EYE0       = 'd83; // 0x8000_014C, RO lane 0's read data eye, one bit per DQ IDELAY tap
    localparam [13:0] R_DDR3_EYE1       = 'd84; // 0x8000_0150, RO lane 1's
    localparam [13:0] R_GS_CLOCK        = 'd85; // 0x8000_0154, RO the IIgs clock chip (rtl/gs_clock.sv stat)

    // ---- the register cut ---------------------------------------------------
    // EVERY READ-ONLY READBACK IS READ THROUGH A SHADOW FLOP (the user,
    // 2026-09-17).  The counters and status words below come from all over
    // the design - the fronts, the page cache, the sequencer, the drives -
    // and read live they ended at the ninety-way read mux: a debug read
    // setting the clock, which this file's mux has done twice
    // (rtl/master_top.sv's dbg_val_q says how).  Behind a shadow a source ends
    // at a bare D pin, and the mux starts from flops that sit beside it.  A
    // read is one clock older, which is what a snapshot wants to be.
    //
    // WHAT THE HOST WROTE IS NOT SHADOWED.  The RW fields are this file's own
    // flops already, so there is nothing to cut, and a write's reply goes on
    // showing them exactly as it did.
    //
    // snap_hold STOPS THE SHADOWS, all of them at one edge: a master that
    // holds the bus and sweeps the map then reads one instant of the whole
    // card, however long the sweep takes - the census beside the total it
    // sums to, the numerator beside its denominator.  The shadows are data,
    // not control: no reset (they follow their sources from the first clock).
    //
    // The `_s` names are declared here, ahead of the readback words that use
    // them; the flops themselves are at the foot of the file, below everything
    // they copy.
    logic        cpu_src_active_s;
    logic [7:0]  cpu_src_latches_s;
    logic [2:0]  mb_slot_active_s;
    logic        mb_phasor_active_s;
    logic [7:0]  boot_holds_s;
    logic        boot_held_s, hold_runtime_s;
    logic [7:0]  menu_count_s;
    logic [2:0]  hd_slot_active_s;
    logic        hd_rom_loaded_s, hd_busy_s;
    logic [7:0]  hd_execs_s;
    logic [2:0]  fd_slot_active_s;
    logic        fd_rom_loaded_s;
    logic [7:0]  fd_seeks_s;
    logic [1:0]  fd_stale_s, fd_dirty_s;
    logic [13:0] fd_phase_s;
    logic [3:0]  fd_ctl_s;
    logic [7:0]  fd_late_s;
    logic [15:0] fd_fill_max_s;
    logic        fd35_stale_s, fd35_side_s, fd35_motor35_s, fd35_motor_s;
    logic [6:0]  fd35_track_s;
    logic [7:0]  fd35_ctl_s, fd35_seeks_s, fd35_late_s;
    logic [31:0] fd35_wstat_s;
    logic [15:0] fd35_fill_max_s;
    logic [2:0]  vidhd_slot_active_s;
    logic        vidhd_rom_loaded_s;
    logic [2:0]  mouse_slot_active_s;
    logic        mouse_rom_loaded_s, mouse_irq_s;
    logic [3:0]  mouse_mode_s;
    logic [1:0]  mouse_buttons_s;
    logic [7:0]  mouse_moves_s;
    logic [15:0] mouse_x_s, mouse_y_s;
    logic [2:0]  u2_slot_active_s;
    logic [3:0]  u2_sock_open_s;
    logic        u2_cmd_dropped_s;
    logic [7:0]  u2_cmds_s, u2_rx_chunks_s;
    logic [15:0] u2_s0_rsr_s, u2_s0_fsr_s;
    logic [2:0]  printer_slot_active_s;
    logic        printer_rom_loaded_s;
    logic [7:0]  printer_writes_s;
    logic        nsc_time_loaded_s, nsc_ring_en_s, nsc_wr_en_s;
    logic [5:0]  nsc_cmp_idx_s, nsc_ring_idx_s;
    logic [7:0]  nsc_unlocks_s;
    logic [63:0] nsc_now_s;
    logic [2:0]  kbd_flags_s;
    logic [31:0] kbd_counts_s;
    logic [2:0]  pb_hw_s;
    logic [3:0]  vbl_state_s, vbl_err_s;
    logic        vbl_locked_s, vbl_pal_s, vbl_busy_s;
    logic [31:0] vbl_stat_s, vbl_pos_s;
    logic [11:0] mem_sw_s;
    logic [7:0]  mem_rw_bank_s;
    logic        mem_image_ready_s, mem_invalidating_s, mem_rom_loaded_s, mem_intc8rom_s;
    logic [7:0]  mem_late_fills_s, mem_fifo_drops_s;
    logic [31:0] mem_fills_s, mem_flushes_s, mem_declines_s;
    logic        mem_rom_busy_s;
    logic [31:0] mem_rom_sum_s;
    logic [7:0]  mem_rom_over_s, mem_rom_xland_s, mem_shd_drops_s;
    logic [31:0] gs_adb_stat_s, gs_clock_stat_s;
    logic [3:0]  panel_dmas_s, panel_drops_s;
    logic [31:0] cnt_core_cyc_s, cnt_bus_cyc_s;
    logic [31:0] dbg_val_s;
    logic [31:0] mem_hits_s, mem_misses_s, mem_mismatch_s, mem_served_s, mem_last_s,
                 mem_diverted_s;
    logic [2:0]  game_pb_s;
    logic        game_pb_ok_s, game_pdl_ok_s;
    logic [11:0] game_pdl0_s, game_pdl1_s, game_pdl2_s, game_pdl3_s;
    logic [7:0]  game_meas_s;
    logic [31:0] accel_stat_s, accel_fast_s, accel_bus_s, accel_cycles_s, accel_wait_s,
                 accel_turbo_s, accel_dline_s, accel_maps_s, accel_ddrop_s, accel_drevive_s,
                 accel_idrop_s, accel_irevive_s;
    logic [31:0] accel_fast_i_s, accel_fast_dram_s, accel_fast_dlc_s, accel_fast_drom_s,
                 accel_fast_dcx_s, accel_fast_wr_s, accel_fast_kbd_s;
    logic [6:0]  fb_mode_s;
    logic [31:0] fb_compared_s, fb_mismatch_s, fb_last_s, fb_last2_s, fb_other_s;
    logic [7:0]  fb_peek_data_s;
    logic        res_pulsing_s;
    logic [7:0]  res_pulses_s;
    logic        start_pending_s, start_cause_card_s, start_cause_res_s;
    logic [7:0]  start_count_s;
    logic [23:0] telem_stat_s;
    logic [31:0] wide_u2_cmds_s, wide_u2_rx_s, wide_prn_writes_s, wide_hd_execs_s,
                 wide_panel_dmas_s, wide_audio_sent_s;
    logic [31:0] ddr3_dbg4_s;
    logic [31:0] ring_status_s, link_stat_s, ddr3_dbg1_s, ddr3_dbg2_s, ddr3_dbg3_s,
                 ddr3_eye0_s, ddr3_eye1_s, audio_stat_s;

    // ---- CPU_SOURCE ---------------------------------------------------------
    //
    //   [0]      desired   RW   0 = the native 6502 (default), 1 = the soft core
    //   [8]      active    RO   what was latched at the last RES' assertion
    //   [16]     capable   RO   this bitstream can actually master the bus
    //   [31:24]  latches   RO   RES' assertions seen, wrapping
    //
    // WHY IT LATCHES ON RES' AND NOT ON THE WRITE.  Handing the bus over is a
    // transition with no good moment in the middle of a running machine: the
    // real CPU is mid-instruction, the soft core is not where the real one was,
    // and whatever mess the DMA' transition makes lands in software's lap.
    //
    // A reset has no such lap to land in.  The Apple's own RESET is held for a
    // long time by the motherboard - far longer than the changeover - and
    // everything after it starts from the vector, so a switch made anywhere
    // inside that window is invisible by construction.  So the write only ever
    // sets an INTENTION, and the next reset is what acts on it.
    //
    // The falling edge is the assertion, RES' being active low.  Latching on
    // the edge rather than on the level keeps it to exactly one changeover per
    // reset however long the reset is held, and however much the line bounces -
    // which it does, being a switch with nothing debouncing it (see DERISK).
    //
    // `latches` is what lets the host tell whether its write has taken effect
    // yet: write desired, read back, and if the count has not moved then no
    // reset has happened and `active` is still the old answer.  Without it the
    // host cannot distinguish "not reset yet" from "reset and ignored".
    logic       cpu_src_desired;
    logic       cpu_src_active;
    logic [7:0] cpu_src_latches;
    logic       res_prev;

    // Falling edge of an active-low line is the assertion.
    wire res_assert = res_prev && !apple_res_sync;
    // ...and its rising edge the release.  What latches at a RES' latches at
    // BOTH (docs/CLEAN_START.md CS1): the start hold drives RES' low from the
    // card's reset, before the host has written what it wants, so a value
    // written during the host's checklist has to be taken as the hold lets go.
    wire res_release = !res_prev && apple_res_sync;

    assign cpu_source_active = cpu_src_active;
    assign apple_res_q       = res_prev;

    always_ff @(posedge clk) begin
        if (rst) begin
            cpu_src_desired <= 1'b0;      // the native CPU keeps the bus
            cpu_src_active  <= 1'b0;
            cpu_src_latches <= 8'd0;
            res_prev        <= 1'b1;      // idle high: no phantom assert at rst
        end else begin
            res_prev <= apple_res_sync;
            if (res_assert || res_release) begin
                // Forced to 0 when this bitstream cannot drive.  The readback
                // then tells the truth - desired reads back as written, active
                // stays 0, and `capable` says why - rather than a snoop build
                // reporting itself as the machine's CPU.
                cpu_src_active  <= CAN_MASTER ? cpu_src_desired : 1'b0;
            end
            // Counted once per reset, at its assertion.
            if (res_assert) cpu_src_latches <= cpu_src_latches + 8'd1;
            if (wr_cpu_source) cpu_src_desired <= wb_dat_w[0];
        end
    end

    wire [31:0] cpu_source_rd = {cpu_src_latches_s, 6'd0, GS, CAN_MASTER,
                                 7'd0, cpu_src_active_s, 7'd0, cpu_src_desired};

    // ---- MB_SLOT ------------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the Mockingboard answers as; 0 = off
    //   [3]      phasor    RW   ...and as a Phasor rather than a Mockingboard
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [11]     phasor    RO   ...and whether it was a Phasor then
    //
    // The same reset-latched contract as CPU_SOURCE, for the same reason
    // scaled down: the slot scan happens at boot, and a card that appears (or
    // moves) in the middle of a running machine is a card the software has
    // already decided about.  A reset is when the decision is re-made, so a
    // reset is when the answer changes.  Gated by CAN_MASTER because the
    // Mockingboard can only put a byte on the bus from a mastering build; in
    // a snoop build `desired` reads back as written and `active` stays 0,
    // which is the register telling the truth rather than erring.
    logic [2:0] mb_slot_desired;
    logic [2:0] mb_slot_active_q;
    logic       mb_phasor_desired;
    logic       mb_phasor_active_q;

    assign mb_slot_active   = mb_slot_active_q;
    assign mb_phasor_active = mb_phasor_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mb_slot_desired <= 3'd0;      // no Mockingboard until asked for
            mb_slot_active_q <= 3'd0;
            mb_phasor_desired <= 1'b0;
            mb_phasor_active_q <= 1'b0;
        end else begin
            // A reset assertion is the ordinary latch point; a boot-hold
            // RELEASE is the second one, so that a menu shown during a hold
            // can enable or move the Mockingboard for the very boot it is
            // about to let go.  See BOOT_HOLD's boot_relatch below and
            // docs/BOOT_MENU.md.  The write only ever sets `desired`; both
            // edges copy it into `active`.
            if (res_assert || res_release || boot_relatch) begin
                mb_slot_active_q   <= CAN_MASTER ? mb_slot_desired : 3'd0;
                mb_phasor_active_q <= CAN_MASTER ? mb_phasor_desired : 1'b0;
            end
            if (wr_mb_slot) begin
                mb_slot_desired   <= wb_dat_w[2:0];
                mb_phasor_desired <= wb_dat_w[3];
            end
        end
    end

    wire [31:0] mb_slot_rd = {20'd0, mb_phasor_active_s, mb_slot_active_s,
                              4'd0, mb_phasor_desired, mb_slot_desired};

    // ---- BOOT_HOLD ----------------------------------------------------------
    //
    //   [0]      arm       RW   hold the soft core at its reset vector, at the
    //                           next reset and every one after, until cleared
    //   [8]      held      RO   the core is held now
    //   [9]      runtime   RO   ...by the runtime menu's door, not the boot's
    //   [16]     release   W1   let a held core go, whichever door; reads as 0
    //   [31:24]  holds     RO   times the hold has engaged, either door, wrapping
    //
    // NOT reset-latched, unlike its neighbours, and deliberately: `arm` is the
    // standing intention "stop at the next boot", which is exactly what a
    // level that persists across resets expresses.  The hold itself engages
    // at a point the core defines - the first opcode fetch after reset - and
    // rtl/boot_hold.sv is where that is recognised; this register only carries
    // the host's wishes in and the state back out.  See docs/BOOT_MENU.md.
    // The same hold has a second door, MENU_HOLD below, and the same release
    // lets go of either; `runtime` says which is in progress, for a host
    // that attached to a hold it did not see engage.
    //
    // `holds` is the counterpart of CPU_SOURCE's `latches`: it lets a host
    // that missed a CPU_HOLD notice - or attached after it - tell a hold that
    // happened from one that did not.  The release bit reads as zero because
    // it is an action, not a state; the state it acts on is `held`.
    logic       boot_arm_q;
    logic [7:0] boot_holds;
    logic       boot_held_prev;

    assign boot_arm = boot_arm_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            boot_arm_q     <= 1'b0;       // boot straight through until asked
            boot_holds     <= 8'd0;
            boot_held_prev <= 1'b0;
            boot_release   <= 1'b0;
        end else begin
            boot_held_prev <= boot_held;
            if (boot_held && !boot_held_prev) boot_holds <= boot_holds + 8'd1;
            if (wr_boot_hold) boot_arm_q <= wb_dat_w[0];
            // One pulse per write that set the bit, however long the host's
            // message took to arrive.  The hold consumes it at a cycle end.
            boot_release <= wr_boot_hold && wb_dat_w[16];
        end
    end

    wire [31:0] boot_hold_rd = {boot_holds_s, 14'd0, hold_runtime_s, boot_held_s, 7'd0, boot_arm_q};

    // ---- MENU_HOLD ----------------------------------------------------------
    //
    //   [0]      enable    RW   watch for the hotkey on the program's reads
    //   [7:1]    hotkey    RW   the key that opens the menu; $1E (Ctrl-6 on a
    //                           IIe) at the card's reset
    //   [8]      trigger   W1   open the menu now, as the hotkey would; reads
    //                           as 0
    //   [31:24]  menus     RO   times the runtime door has opened, wrapping
    //
    // The runtime menu's door into the hold BOOT_HOLD arms for a boot (see
    // docs/RUNTIME_MENU.md).  The key is eaten on the card - the program
    // never sees it - and the hold engages at the program's next opcode
    // fetch; BOOT_HOLD's release lets it go, and the program continues from
    // that fetch.  `enable` is a level like `arm`, and the same reasoning
    // applies: the host's standing wish, and a RES' does not change it.  It
    // is the card's reset - the watchdog's included - that clears it, so a
    // host that has gone leaves no door open that nobody would answer.
    // `trigger` is the host's own knock: the control socket's `menu`, a
    // scripted test, a run with the Apple's keyboard locked.  Not gated by
    // CAN_MASTER: the pulse simply goes nowhere in a watching build.
    logic [7:0] menu_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            menu_en      <= 1'b0;
            menu_hotkey  <= 7'h1E;
            menu_trigger <= 1'b0;
            menu_count   <= 8'd0;
        end else begin
            if (boot_held && !boot_held_prev && hold_runtime) menu_count <= menu_count + 8'd1;
            menu_trigger <= wr_menu_hold && wb_dat_w[8];
            if (wr_menu_hold) begin
                menu_en     <= wb_dat_w[0];
                menu_hotkey <= wb_dat_w[7:1];
            end
        end
    end

    wire [31:0] menu_hold_rd = {menu_count_s, 16'd0, menu_hotkey, menu_en};

    // ---- HD_SLOT ------------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the hard disk answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 256-byte slot ROM has been loaded (HD_ROM)
    //   [17]     busy      RO   a command is outstanding: the port reads busy
    //   [31:24]  execs     RO   EXECUTE reads taken, wrapping
    //
    // MB_SLOT's contract again, and one more rule: the two slots may not
    // coincide.  Both peripherals claim read cycles in their slot's ranges,
    // and two claimants for one cycle would both drive the bus.  The disk
    // yields - it is the newer of the two - and `active` says so, latching 0
    // when the Mockingboard has the same slot asked for.  The host checks
    // the readback rather than assuming.  See docs/HARDDISK.md.
    logic [2:0] hd_slot_desired;
    logic [2:0] hd_slot_active_q;

    assign hd_slot_active = hd_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            hd_slot_desired  <= 3'd0;     // no hard disk until asked for
            hd_slot_active_q <= 3'd0;
        end else begin
            // Same two latch points as MB_SLOT, and the same clash rule at
            // each: the disk yields the Mockingboard's slot.  See BOOT_MENU.md.
            if (res_assert || res_release || boot_relatch) begin
                hd_slot_active_q <= (CAN_MASTER && hd_slot_desired != mb_slot_desired)
                                    ? hd_slot_desired : 3'd0;
            end
            if (wr_hd_slot) hd_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] hd_slot_rd = {hd_execs_s, 6'd0, hd_busy_s, hd_rom_loaded_s,
                              5'd0, hd_slot_active_s, 5'd0, hd_slot_desired};

    // ---- FD_SLOT ------------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the floppy controller answers as;
    //                           0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 256-byte boot ROM has been loaded (FD_ROM)
    //   [31:24]  seeks     RO   head movements the host was asked to fill,
    //                           wrapping
    //
    // HD_SLOT's contract, and the clash rule is now three-way: the floppy is
    // the newest of the three and yields to both the others, latching 0 when
    // either has the same slot asked for.  See docs/FLOPPY.md.
    logic [2:0] fd_slot_desired;
    logic [2:0] fd_slot_active_q;

    assign fd_slot_active = fd_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            fd_slot_desired  <= 3'd0;     // no floppy until asked for
            fd_slot_active_q <= 3'd0;
        end else begin
            if (res_assert || res_release || boot_relatch) begin
                fd_slot_active_q <= (CAN_MASTER && fd_slot_desired != mb_slot_desired &&
                                     fd_slot_desired != hd_slot_desired)
                                    ? fd_slot_desired : 3'd0;
            end
            if (wr_fd_slot) fd_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] fd_slot_rd = {fd_seeks_s, 7'd0, fd_rom_loaded_s,
                              5'd0, fd_slot_active_s, 5'd0, fd_slot_desired};

    // ---- VIDHD_SLOT ---------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the VidHD answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 256-byte slot ROM has been loaded
    //                           (VIDHD_ROM)
    //
    // FD_SLOT's contract, and the clash rule is four-way now: the VidHD is
    // the newest and yields to all three of the others, latching 0 when any
    // has the same slot asked for.  See docs/VIDHD.md.
    logic [2:0] vidhd_slot_desired;
    logic [2:0] vidhd_slot_active_q;

    assign vidhd_slot_active = vidhd_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            vidhd_slot_desired  <= 3'd0;   // no VidHD until asked for
            vidhd_slot_active_q <= 3'd0;
        end else begin
            if (res_assert || res_release || boot_relatch) begin
                vidhd_slot_active_q <= (CAN_MASTER &&
                                        vidhd_slot_desired != mb_slot_desired &&
                                        vidhd_slot_desired != hd_slot_desired &&
                                        vidhd_slot_desired != fd_slot_desired)
                                       ? vidhd_slot_desired : 3'd0;
            end
            if (wr_vidhd_slot) vidhd_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] vidhd_slot_rd = {8'd0, 7'd0, vidhd_rom_loaded_s,
                                 5'd0, vidhd_slot_active_s, 5'd0, vidhd_slot_desired};

    // ---- MOUSE_SLOT ---------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the mouse card answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 2 KB firmware ROM has been loaded (MOUSE_ROM)
    //   [17]     irq       RO   the card's interrupt line is asserted
    //   [19:18]  buttons   RO   the buttons as the host holds them
    //   [23:20]  mode      RO   the mode byte SETMOUSE left
    //   [31:24]  moves     RO   MOUSE_MOVE messages applied, wrapping
    //
    // VIDHD_SLOT's contract, the clash rule five-way: the mouse is the newest
    // and yields to all four of the others.  See docs/MOUSE.md.
    logic [2:0] mouse_slot_desired;
    logic [2:0] mouse_slot_active_q;

    assign mouse_slot_active = mouse_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mouse_slot_desired  <= 3'd0;   // no mouse until asked for
            mouse_slot_active_q <= 3'd0;
        end else begin
            if (res_assert || res_release || boot_relatch) begin
                mouse_slot_active_q <= (CAN_MASTER &&
                                        mouse_slot_desired != mb_slot_desired &&
                                        mouse_slot_desired != hd_slot_desired &&
                                        mouse_slot_desired != fd_slot_desired &&
                                        mouse_slot_desired != vidhd_slot_desired)
                                       ? mouse_slot_desired : 3'd0;
            end
            if (wr_mouse_slot) mouse_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] mouse_slot_rd = {mouse_moves_s, mouse_mode_s, mouse_buttons_s, mouse_irq_s, mouse_rom_loaded_s,
                                 5'd0, mouse_slot_active_s, 5'd0, mouse_slot_desired};
    // MOUSE_STAT: {y[15:0], x[15:0]}, the position as the card holds it.
    wire [31:0] mouse_stat_rd = {mouse_y_s, mouse_x_s};

    // ---- U2_SLOT ------------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the Uthernet II answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [11]     dropped   RO   a command was dropped (the card's queue overflowed)
    //   [15:12]  open      RO   the four sockets' Sn_SR != 0
    //   [23:16]  cmds      RO   U2_CMD messages sent, wrapping
    //   [31:24]  rx        RO   U2_RX chunks landed, wrapping
    //
    // MOUSE_SLOT's contract, and the clash rule with a first exception: the
    // Uthernet II is the newest and yields to the Mockingboard, the disk, the
    // floppy and the mouse - but NOT to the VidHD.  The VidHD is a slot ROM
    // page ($Cn00-$CnFF) and nothing else; the Uthernet II is DEVICE SELECT'
    // ($C0n0-$C0nF) and nothing else; the two ranges are disjoint, so the two
    // cards share a slot without a byte in common - and slot 3 is where both
    // live by convention.  See docs/UTHERNET2.md.
    logic [2:0] u2_slot_desired;
    logic [2:0] u2_slot_active_q;

    assign u2_slot_active = u2_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            u2_slot_desired  <= 3'd0;   // no card until asked for
            u2_slot_active_q <= 3'd0;
        end else begin
            if (res_assert || res_release || boot_relatch) begin
                u2_slot_active_q <= (CAN_MASTER &&
                                     u2_slot_desired != mb_slot_desired &&
                                     u2_slot_desired != hd_slot_desired &&
                                     u2_slot_desired != fd_slot_desired &&
                                     u2_slot_desired != mouse_slot_desired)
                                    ? u2_slot_desired : 3'd0;
            end
            if (wr_u2_slot) u2_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] u2_slot_rd = {u2_rx_chunks_s, u2_cmds_s, u2_sock_open_s, u2_cmd_dropped_s,
                              u2_slot_active_s, 5'd0, u2_slot_desired};
    // U2_STAT: {Sn_RX_RSR, Sn_TX_FSR} of socket 0.
    wire [31:0] u2_stat_rd = {u2_s0_rsr_s, u2_s0_fsr_s};

    // ---- PRINTER_SLOT -------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the printer card answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 256-byte slot ROM has been loaded (PRINTER_ROM)
    //   [31:24]  writes    RO   $C0n0 writes the card saw, wrapping
    //
    // U2_SLOT's contract; the printer is the newest and yields to all six
    // of the others (its ROM page and its device-select range both, so no
    // sharing).  See docs/PRINTER.md.
    logic [2:0] printer_slot_desired;
    logic [2:0] printer_slot_active_q;

    assign printer_slot_active = printer_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            printer_slot_desired  <= 3'd0;   // no card until asked for
            printer_slot_active_q <= 3'd0;
        end else begin
            if (res_assert || res_release || boot_relatch) begin
                printer_slot_active_q <= (CAN_MASTER &&
                                          printer_slot_desired != mb_slot_desired &&
                                          printer_slot_desired != hd_slot_desired &&
                                          printer_slot_desired != fd_slot_desired &&
                                          printer_slot_desired != vidhd_slot_desired &&
                                          printer_slot_desired != mouse_slot_desired &&
                                          printer_slot_desired != u2_slot_desired)
                                         ? printer_slot_desired : 3'd0;
            end
            if (wr_printer_slot) printer_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] printer_slot_rd = {printer_writes_s, 7'd0, printer_rom_loaded_s,
                                   5'd0, printer_slot_active_s, 5'd0, printer_slot_desired};

    // ---- NSC_CTRL -----------------------------------------------------------
    //
    //   [0]      enable    RW   the No-Slot Clock listens; 1 at reset - it
    //                           answers nothing until the host has sent a time
    //   [1]      loaded    RO   a time has arrived (NSC_TIME messages)
    //   [2]      ring      RO   the clock register is being read out
    //   [3]      wr        RO   writes are enabled (no key mismatch pending)
    //   [13:8]   cmp       RO   the comparison register's bit index
    //   [21:16]  idx       RO   the clock register's bit index
    //   [31:24]  unlocks   RO   times the key matched and the register filled
    //
    // NSC_TIME: the host's time, low half - {hour, minute, second, centisecond}
    // as BCD bytes, the centisecond lowest; NSC_DATE the high half - {year,
    // month, date, day of week}.  docs/NSC.md.
    // THE RING'S ENGAGE (docs/REQ_65C02.md 1.10): clear out of reset, so a card
    // that has just come up answers over USB3 with no DDR3 behind it; the host
    // sets it once it has read the DDR3 calibrated and before BUS_ENABLE.
    logic ring_engage_q;
    always_ff @(posedge clk) begin
        if (rst)               ring_engage_q <= 1'b0;
        else if (wr_ring_ctrl) ring_engage_q <= wb_dat_w[0];
    end
    assign ring_engage = ring_engage_q;

    logic nsc_enable_q;
    always_ff @(posedge clk) begin
        if (rst)              nsc_enable_q <= 1'b1;
        else if (wr_nsc_ctrl) nsc_enable_q <= wb_dat_w[0];
    end
    assign nsc_enable = nsc_enable_q;
    wire [31:0] nsc_ctrl_rd = {nsc_unlocks_s, 2'd0, nsc_ring_idx_s, 2'd0, nsc_cmp_idx_s,
                               4'd0, nsc_wr_en_s, nsc_ring_en_s, nsc_time_loaded_s, nsc_enable_q};

    // ---- AUDIO_CTRL / AUDIO_RATE / AUDIO_STAT -------------------------------
    // AUDIO_CTRL: [0] the sample stream on (silent until asked), [1] the AYs
    // clocked by the real bus's phi0 rather than the core's clock; readback
    // adds [16] = the stream on, as the sampler sees it.  AUDIO_RATE: the
    // sampler's NCO increment, rate_hz * 2^32 / 1e8, 44 100 Hz at reset.
    // AUDIO_STAT: rtl/audio_tx.sv's word.  docs/AUDIO.md.
    logic [1:0]  audio_ctrl_q;
    logic [31:0] audio_rate_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            audio_ctrl_q <= 2'd0;
            audio_rate_q <= 32'd1894081;
        end else begin
            if (wr_audio_ctrl) audio_ctrl_q <= wb_dat_w[1:0];
            if (wr_audio_rate) audio_rate_q <= wb_dat_w;
        end
    end
    assign audio_on       = audio_ctrl_q[0];
    assign audio_realtime = audio_ctrl_q[1];
    assign audio_rate     = audio_rate_q;
    wire [31:0] audio_ctrl_rd = {15'd0, audio_ctrl_q[0], 14'd0, audio_ctrl_q};

    // ---- TELEM_CTRL -----------------------------------------------------------
    //
    //   [0]      enable    RW   send a TELEMETRY message a second (docs/TELEMETRY.md)
    //   [15:8]   epoch     RO   RES' releases the sender has seen, wrapping
    //   [23:16]  drops     RO   samples skipped: the last message was still going out
    //   [31:24]  sent      RO   messages sent, wrapping
    //
    // Silent until asked (docs/PROTOCOL.md): clear at the card's reset - the
    // watchdog's included - so a host that has gone is not talked at.  A host
    // that wants a run's baseline sets it BEFORE it releases the start hold.
    // A bitstream older than this reads 0 here and goes on reading 0 after
    // the write, which is how a host knows to keep polling.
    logic telem_on_q;
    always_ff @(posedge clk) begin
        if (rst)                telem_on_q <= 1'b0;
        else if (wr_telem_ctrl) telem_on_q <= wb_dat_w[0];
    end
    assign telem_on = telem_on_q;
    wire [31:0] telem_ctrl_rd = {telem_stat_s, 7'd0, telem_on_q};

    // ---- the wide counters (R_WIDE_*) ---------------------------------------
    // (now - before) mod 2^n a clock, into 32 bits.  A narrow count moves by
    // at most a few a clock, so the difference is never ambiguous.
    logic [7:0]  wu2c_p, wu2r_p, wprn_p, whd_p;
    logic [3:0]  wpan_p;
    logic [15:0] wau_p;
    logic [31:0] wide_u2_cmds, wide_u2_rx, wide_prn_writes, wide_hd_execs, wide_panel_dmas,
                 wide_audio_sent;
    always_ff @(posedge clk) begin
        if (rst) begin
            wu2c_p <= 8'd0; wu2r_p <= 8'd0; wprn_p <= 8'd0; whd_p <= 8'd0; wpan_p <= 4'd0;
            wau_p  <= 16'd0;
            wide_u2_cmds <= 32'd0; wide_u2_rx <= 32'd0; wide_prn_writes <= 32'd0;
            wide_hd_execs <= 32'd0; wide_panel_dmas <= 32'd0; wide_audio_sent <= 32'd0;
        end else begin
            wu2c_p <= u2_cmds;        wide_u2_cmds    <= wide_u2_cmds    + {24'd0, u2_cmds - wu2c_p};
            wu2r_p <= u2_rx_chunks;   wide_u2_rx      <= wide_u2_rx      + {24'd0, u2_rx_chunks - wu2r_p};
            wprn_p <= printer_writes; wide_prn_writes <= wide_prn_writes + {24'd0, printer_writes - wprn_p};
            whd_p  <= hd_execs;       wide_hd_execs   <= wide_hd_execs   + {24'd0, hd_execs - whd_p};
            wpan_p <= panel_dmas;     wide_panel_dmas <= wide_panel_dmas + {28'd0, panel_dmas - wpan_p};
            wau_p  <= audio_stat[15:0];
            wide_audio_sent <= wide_audio_sent + {16'd0, audio_stat[15:0] - wau_p};
        end
    end

    // ---- FD_DRIVE1 / FD_DRIVE2 ----------------------------------------------
    //
    //   [0]      inserted  RW   a disk is in the drive
    //   [1]      wp        RW   ...and it is write-protected
    //   [15:3]   nibbles   RW   nibbles per track: 6384 for a sector image,
    //                           6656 for a .nib
    //   [21:16]  tracks    RW   tracks in the image, 35 or 40
    //   [22]     flush     W1   send the buffer to the host now if it was
    //                           written; reads as 0
    //   [23]     stale     RO   the buffer is not the track under the head yet
    //   [24]     dirty     RO   the buffer has been written to
    //   [31:25]  phase     RO   where the head is, in half tracks
    //
    // NOT reset-latched, on purpose: a disk goes in and out of a running
    // machine, and the runtime menu is where that happens.  An insertion is
    // the 0 -> 1 edge of `inserted`; to change the disk, eject first.  The
    // card's reset clears the drives, as it does the keyboard; a RES' does
    // not, as it does not on a real drive.
    always_ff @(posedge clk) begin
        if (rst) begin
            fd_inserted <= 2'd0;
            fd_wp       <= 2'd0;
            fd_nibbles  <= 26'd0;
            fd_tracks   <= 12'd0;
            fd_flush    <= 2'd0;
        end else begin
            fd_flush <= {wr_fd_drive2 && wb_dat_w[22], wr_fd_drive1 && wb_dat_w[22]};
            if (wr_fd_drive1) begin
                fd_inserted[0]    <= wb_dat_w[0];
                fd_wp[0]          <= wb_dat_w[1];
                fd_nibbles[12:0]  <= wb_dat_w[15:3];
                fd_tracks[5:0]    <= wb_dat_w[21:16];
            end
            if (wr_fd_drive2) begin
                fd_inserted[1]    <= wb_dat_w[0];
                fd_wp[1]          <= wb_dat_w[1];
                fd_nibbles[25:13] <= wb_dat_w[15:3];
                fd_tracks[11:6]   <= wb_dat_w[21:16];
            end
        end
    end

    wire [31:0] fd_drive1_rd = {fd_phase_s[6:0], fd_dirty_s[0], fd_stale_s[0], 1'b0,
                                fd_tracks[5:0], fd_nibbles[12:0], 1'b0, fd_wp[0], fd_inserted[0]};
    wire [31:0] fd_drive2_rd = {fd_phase_s[13:7], fd_dirty_s[1], fd_stale_s[1], 1'b0,
                                fd_tracks[11:6], fd_nibbles[25:13], 1'b0, fd_wp[1], fd_inserted[1]};

    // ---- FD_STAT ------------------------------------------------------------
    //
    //   [0]      motor     RO   the motor switch is on
    //   [1]      drive     RO   which drive is selected, 0 or 1
    //   [2]      q6        RO   the sequencer's load/shift switch
    //   [3]      q7        RO   ...and its read/write switch
    //   [15:8]   late      RO   fills that landed after the machine had read;
    //                           W1 bit 0 clears it
    //   [31:16]  fill_max  RO   the longest fill, head movement to seventh
    //                           chunk, in bus cycles; W1 bit 1 clears it
    //
    // The two numbers docs/FLOPPY.md's latency budget is checked against.
    always_ff @(posedge clk) begin
        if (rst) begin
            fd_late_clr <= 1'b0;
            fd_fill_clr <= 1'b0;
        end else begin
            fd_late_clr <= wr_fd_stat && wb_dat_w[0];
            fd_fill_clr <= wr_fd_stat && wb_dat_w[1];
        end
    end

    // ---- FD35_DRIVE / FD35_STAT ---------------------------------------------
    //
    // FD35_DRIVE, the 3.5" drive on the IWM, live like FD_DRIVE1:
    //   [0]      inserted  RW   a disk is in the drive (its 0 -> 1 edge is the
    //                           insertion; eject first to change a disk)
    //   [1]      wp        RW   ...and it is write-protected
    //   [8]      stale     RO   the buffer is not the track under the head yet
    //   [15:9]   track     RO   the head's track, 0-79
    //   [16]     side      RO   ...and side
    //   [17]     motor35   RO   the drive's motor
    //   [18]     motor     RO   the IWM's ENABLE
    //   [31:24]  seeks     RO   head movements the card asked to have filled
    // FD35_STAT:
    //   [7:0]    late      RO   fills that landed after the machine had read;
    //                           W1 bit 0 clears
    //   [15:8]   ctl       RO   {phases, q7, q6, drive_sel, apple35_sel}
    //   [31:16]  fill_max  RO   the longest fill, seek to last chunk, in
    //                           MICROSECONDS; W1 bit 1 clears
    always_ff @(posedge clk) begin
        if (rst) begin
            fd35_inserted <= 1'b0;
            fd35_wp       <= 1'b0;
            fd35_late_clr <= 1'b0;
            fd35_fill_clr <= 1'b0;
        end else begin
            if (wr_fd35_drive) begin
                fd35_inserted <= wb_dat_w[0];
                fd35_wp       <= wb_dat_w[1];
            end
            fd35_late_clr <= wr_fd35_stat && wb_dat_w[0];
            fd35_fill_clr <= wr_fd35_stat && wb_dat_w[1];
        end
    end
    wire [31:0] fd35_drive_rd = {fd35_seeks_s, 5'd0, fd35_motor_s, fd35_motor35_s, fd35_side_s,
                                 fd35_track_s, fd35_stale_s, 6'd0, fd35_wp, fd35_inserted};
    wire [31:0] fd35_stat_rd  = {fd35_fill_max_s, fd35_ctl_s, fd35_late_s};

    wire [31:0] fd_stat_rd = {fd_fill_max_s, fd_late_s, 4'd0, fd_ctl_s};

    // ---- MEM_CTRL -----------------------------------------------------------
    //
    //   [0]      serve      RW   all-or-nothing: answer every RAM, LC and ROM
    //                               read from the image, or none of them
    //   [8]      cnt_clr    W1   clear the counters
    //   [9]      inval      W1   invalidate every cache line
    //   [23:16]  bank       RO   the RamWorks bank register, as the shadow
    //                           holds it (rtl/apple_mmu.sv); 0 after RES'
    //   [27:24]  sets       RO   log2 of the cache's sets
    //
    // A level, card-reset only and never latched on RES': serving can be
    // flipped under a running machine, because with it clear the core takes
    // the bus's byte exactly as it did before the cache existed, and with it
    // set the cache is already tracking every write.  There is no partial
    // mode - mirroring some classes but not others has no use.  Nothing here
    // clears the image: it persists like the machine's RAM.
    //
    // AT GS = 1 SERVING IS TIED ON, reads and writes, from the card's reset
    // and through every write (the user, 2026-09-15).  The board sits in a
    // //e, whose bus cannot carry the IIgs's 24-bit address space: a GS read
    // or write of RAM on that bus is nonsense either way, and a host that
    // turned serving off ran the machine off the IIe's memory.  Revisit when
    // the card can sit in a IIgs.
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_serve   <= GS;
            mem_cnt_clr <= 1'b0;
            mem_inval   <= 1'b0;
        end else begin
            if (wr_mem_ctrl) mem_serve <= GS || wb_dat_w[0];
            mem_cnt_clr <= wr_mem_ctrl && wb_dat_w[8];
            mem_inval   <= wr_mem_ctrl && wb_dat_w[9];
        end
    end

    wire [31:0] mem_ctrl_rd = {4'd0, 4'(MEM_PAGES_LOG2), mem_rw_bank_s, 15'd0, mem_serve};

    // ---- MEM_STAT -----------------------------------------------------------
    //
    //   [11:0]   switches   RO   the MMU shadow: {prewrite, wren, lc_ramrd,
    //                           bank2, slotc3rom, intcxrom, hires, page2,
    //                           altzp, ramwrt, ramrd, store80}
    //   [12]     image_ready RO  the DDR3 is calibrated
    //   [13]     intc8rom   RO   the shadow's INTC8ROM latch (the CX class)
    //   [14]     invalidating RO
    //   [15]     rom_loaded RO   every MEM_ROM chunk has landed
    //   [23:16]  late_fills RO   fills that landed after their cycle: must be 0
    //   [31:24]  fifo_drops RO   requests the DDR3 client could not take: must be 0
    //
    // MEM_ROM (a word of its own) carries the ROM load's flow control: the
    // loader turns a MEM_ROM chunk into 512 physical writes and the host must
    // not send the next chunk until they have drained.
    wire [31:0] mem_stat_rd = {mem_fifo_drops_s, mem_late_fills_s, mem_rom_loaded_s,
                               mem_invalidating_s, mem_intc8rom_s, mem_image_ready_s, mem_sw_s};
    wire [31:0] mem_rom_rd  = {mem_shd_drops_s, mem_rom_xland_s, mem_rom_over_s, 7'd0, mem_rom_busy_s};

    // ---- ACCEL_CTRL ---------------------------------------------------------
    // (ACCEL_STAT, read straight through from the sequencer: [0] accelerating,
    // [1] held by the governor, [3] bus_owns, [7:4] state, [15:8] merge
    // overflows, [23:16] retries, [24] the reset sequence still on the bus.)
    //
    //   [1:0]    mode       RW   0 off - the core locked to the bus, the old
    //                           machine to the clock; 1 reads served on the
    //                           card, every write on the bus; 2 reads and
    //                           writes on the card
    //   [23:8]   target     RW   ops per bus cycle, 8.8 fixed point; 0 = as
    //                           fast as the card can
    //   [31]     cnt_clr    W1   clear the ACCEL_* counters
    //
    // Levels, like MEM_CTRL's: safe under a running machine, with the one
    // rule docs/ACCELERATION.md states - leaving mode 2 for a state where
    // the core reads the machine's RAM (mode 0, serving off) executes the
    // stale memory the machine holds; the host enforces it.
    //
    // AT GS = 1 THE MODE IS TIED TO 2 (the user, 2026-09-15: "mode 2, 100%
    // of the time").  Mode 0 hands the 65816 to the bus and mode 1 its
    // writes, and the bus is a //e's: swhost's exit wrote mode 0 under a
    // running GS and it ran off into a LoRes screen and a speaker buzz
    // (docs/GS_CONTROL_PANEL.md, test D).  The target and the disable bits
    // stay the host's.
    always_ff @(posedge clk) begin
        if (rst) begin
            accel_mode    <= GS ? 2'd2 : 2'd0;
            accel_target  <= 16'd0;
            accel_cnt_clr <= 1'b0;
            accel_swint_dis <= 1'b0;
            accel_game_dis  <= 1'b0;
            accel_l1_dis <= 1'b0;
        end else begin
            if (wr_accel_ctrl) begin
                accel_mode    <= GS ? 2'd2 : wb_dat_w[1:0];
                accel_target  <= wb_dat_w[23:8];
                accel_swint_dis <= wb_dat_w[28];
                accel_game_dis  <= wb_dat_w[27];
                accel_l1_dis <= wb_dat_w[29];
            end
            accel_cnt_clr <= wr_accel_ctrl && wb_dat_w[31];
        end
    end

    //   [28]     swint_dis  RW   1 = the keyboard is not internalized and the
    //                           dummy parks at $0000: every $C00x read rides
    //                           the bus, as before the closed regime
    //   [27]     game_dis   RW   1 = the game port is not internalized: the
    //                           dummies stay at $C000 and every $C06x/$C07x
    //                           access rides the bus (rtl/game_port.sv)
    // The fast-op census counts here, beside the registers it is read through.
    wire [31:0] accel_fast_i, accel_fast_dram, accel_fast_dlc, accel_fast_drom,
                accel_fast_dcx, accel_fast_wr, accel_fast_kbd;
    fast_census u_census (
        .clk (clk), .rst (rst), .clr (accel_cnt_clr),
        .v (accel_cen_v), .sel (accel_cen_sel),
        .fast_i (accel_fast_i), .fast_dram (accel_fast_dram), .fast_dlc (accel_fast_dlc),
        .fast_drom (accel_fast_drom), .fast_dcx (accel_fast_dcx), .fast_wr (accel_fast_wr),
        .fast_kbd (accel_fast_kbd)
    );
    wire [31:0] accel_ctrl_rd = {2'd0, accel_l1_dis, accel_swint_dis, accel_game_dis, 3'd0, accel_target, 6'd0, accel_mode};

    // ---- GAME_STAT ----------------------------------------------------------
    // The game port as the dummy loop last sampled it (rtl/game_port.sv):
    //   GAME_STAT   [2:0] the buttons' levels PB0..PB2; [3] pb_ok; [4] pdl_ok;
    //               [19:8] paddle 0's sample, bus cycles; [31:20] paddle 1's
    //   GAME_STAT2  [11:0] paddle 2's; [23:12] paddle 3's; [31:24] measurements, wrapping
    wire [31:0] game_stat_rd  = {game_pdl1_s, game_pdl0_s, 3'd0, game_pdl_ok_s, game_pb_ok_s, game_pb_s};
    wire [31:0] game_stat2_rd = {game_meas_s, game_pdl3_s, game_pdl2_s};

    // ---- FB_CTRL ------------------------------------------------------------
    //
    //   [0]      serve      RW   answer every floating-bus read the core makes
    //                            with the simulator's byte instead of the bus's
    //   [8]      cnt_clr    W1   clear the counters
    //   [16]     locked     RO   the scanner counter is set (VBL_CTRL's)
    //   [17]     text       RO   the video switches as the MMU shadow holds
    //   [18]     mixed      RO   them - what the prediction is built from
    //   [19]     hires      RO
    //   [20]     page2      RO   PAGE2 as displayed: PAGE2 && !80STORE
    //   [21]     col80      RO
    //   [22]     store80    RO
    //
    // A level, like MEM_CTRL's serve: safe under a running machine, because
    // the monitor was already comparing every floating read, and card-reset
    // only.  The simulator itself needs no enabling - the side copy follows
    // every write and the monitor runs from the lock on.  FB_COMPARED,
    // FB_MISMATCH, FB_LAST, FB_LAST2 and FB_OTHER read straight through from
    // rtl/fb_sim.sv; FB_PEEK's address is a level and its data the copy's
    // byte there.  docs/FLOATING_BUS.md.
    always_ff @(posedge clk) begin
        if (rst) begin
            fb_serve     <= 1'b0;
            fb_cnt_clr   <= 1'b0;
            fb_peek_addr <= 15'd0;
        end else begin
            if (wr_fb_ctrl) fb_serve <= wb_dat_w[0];
            fb_cnt_clr <= wr_fb_ctrl && wb_dat_w[8];
            if (wr_fb_peek) fb_peek_addr <= wb_dat_w[14:0];
        end
    end

    wire [31:0] fb_ctrl_rd = {9'd0, fb_mode_s, 15'd0, fb_serve};

    // ---- FB_PEEK ------------------------------------------------------------
    //
    //   [14:0]   addr       RW   [14] 0 = the text copy, [10:0] from $0400;
    //                            1 = the hi-res copy, [13:0] from $2000
    //   [23:16]  data       RO   the copy's byte there
    wire [31:0] fb_peek_rd = {8'd0, fb_peek_data_s, 1'b0, fb_peek_addr};

    // ---- RESET --------------------------------------------------------------
    //
    //   [0]      pulse     W1   assert the Apple's RES' low for a while
    //   [31:16]  cycles    W    duration in 256-cycle units; 0 = the default
    //   [0]      pulsing   RO   the pulse is asserting now
    //   [31:24]  pulses    RO   pulses issued, wrapping
    //
    // A physical Ctrl-Reset pulls the bus RES' line - a wired-OR, open-drain
    // line - low for as long as the key is held.  This does the same from the
    // host: the master top drives the line low while `res_drive` is high and
    // releases it to Hi-Z otherwise.  Everything a real reset does then
    // follows, because the reader samples our own driven low back as
    // `apple_res_sync` - the soft core resets, and CPU_SOURCE / MB_SLOT /
    // HD_SLOT re-latch on the assertion, same as any reset.
    //
    // The counter lives in this always-on clock domain, NOT the one RES'
    // resets, so the pulse it is generating cannot cut itself short.  Only a
    // CAN_MASTER build may drive; a snooper's pin is an input.
    //
    // ~20 us default (2000 cycles at 100 MHz): far longer than the soft core's
    // seven-cycle reset needs, and short enough to be imperceptible.  A caller
    // that wants the machine visibly held passes a bigger count.
    localparam integer RES_DEFAULT = 2000;
    logic [23:0] res_cnt;
    logic [7:0]  res_pulses;
    wire  res_pulsing = (res_cnt != 24'd0);
    // The host's pulse, or the start hold for as long as it is pending.
    wire   start_hold_drive;
    assign res_drive = CAN_MASTER && (res_pulsing || start_hold_drive);

    always_ff @(posedge clk) begin
        if (rst) begin
            res_cnt    <= 24'd0;
            res_pulses <= 8'd0;
        end else if (wr_reset && wb_dat_w[0] && !res_pulsing) begin
            res_cnt    <= (wb_dat_w[31:16] != 16'd0) ? {wb_dat_w[31:16], 8'd0}
                                                     : RES_DEFAULT[23:0];
            res_pulses <= res_pulses + 8'd1;
        end else if (res_pulsing) begin
            res_cnt <= res_cnt - 24'd1;
        end
    end

    wire [31:0] reset_rd = {res_pulses_s, 23'd0, res_pulsing_s};

    // ---- START --------------------------------------------------------------
    //
    //   [0]      pending    RO   the machine is held for the host's checklist;
    //                            W1 releases it (docs/CLEAN_START.md CS1)
    //   [1]      cause_card RO   held by the card's own reset (power-on, a load,
    //                            the link's reset or its watchdog)
    //   [2]      cause_res  RO   held by a RES' the hold did not cause
    //   [31:24]  count      RO   holds since the card's reset
    //
    // While pending, RES' is driven low: the whole machine waits.  The cause
    // bits clear on the release.  See rtl/start_hold.sv.
    start_hold #(.CAN_MASTER (CAN_MASTER)) u_start_hold (
        .clk            (clk),
        .rst            (rst),
        .apple_res_sync (apple_res_sync),
        .release_w1     (wr_start && wb_dat_w[0]),
        .pending        (start_pending),
        .cause_card     (start_cause_card),
        .cause_res      (start_cause_res),
        .count          (start_count),
        .hold_drive     (start_hold_drive)
    );
    wire [31:0] start_rd = {start_count_s, 21'd0, start_cause_res_s, start_cause_card_s, start_pending_s};

    // ---- KBD_INJECT ---------------------------------------------------------
    //
    //   [6:0]    key       W    the key, taken when press is set
    //   [7]      press     W1   put key on the keyboard, strobe set, replacing
    //                           an unconsumed one; reads as 0
    //   [8]      drop      W1   clear the strobe without a $C010; reads as 0
    //   [16]     strobe    RO   a key is waiting that the machine has not taken
    //   [17]     seen      RO   ...and a $C00x read has returned it
    //   [31:24]  pressed   RO   presses, wrapping
    //
    // The machine's keyboard has one latch and one strobe, and so does this:
    // a press is a keypress, it always lands, and the newest wins.  Typing a
    // string at the machine's pace is the host's job - press, wait for the
    // press to be resolved, press the next - and KBD_CTRL and the KBD_EVENT
    // notice are how it learns that.  The reply to the press itself is the
    // acknowledgement that it arrived, showing the state BEFORE it: the
    // press's own number is the `pressed` it reads plus one, and `strobe`
    // says whether it landed on a key still waiting.  Nothing here is
    // reset-latched: a key is for the program running now, and
    // rtl/kbd_inject.sv drops it if a reset comes first.  Not gated by
    // CAN_MASTER - the pulses simply go nowhere in a watching build, and the
    // readback there says strobe=0, which is the truth.
    always_ff @(posedge clk) begin
        if (rst) begin
            kbd_press     <= 1'b0;
            kbd_press_key <= 7'd0;
            kbd_drop      <= 1'b0;
        end else begin
            kbd_press     <= wr_kbd_inject && wb_dat_w[7];
            kbd_drop      <= wr_kbd_inject && wb_dat_w[8];
            if (wr_kbd_inject) kbd_press_key <= wb_dat_w[6:0];
        end
    end

    wire [31:0] kbd_inject_rd = {kbd_counts_s[7:0], 6'd0, kbd_flags_s[1:0], 16'd0};

    // ---- KBD_CTRL -----------------------------------------------------------
    //
    //   [0]      lock      RW   suppress the machine's own keyboard: the core
    //                           reads the injected keys and nothing else
    //   [1]      notify    RW   send a KBD_EVENT notice on every resolution
    //   [7]      touched   RO   a real key arrived while locked; cleared when
    //                           lock is next set
    //   [15:8]   taken     RO   presses resolved: read, then strobed
    //   [23:16]  flushed   RO   presses resolved: strobed unread
    //   [31:24]  replaced  RO   presses resolved: pressed over
    //
    // A press is resolved by exactly one of taken, flushed, replaced, or a
    // drop (the register's, or a RES'), which is not counted: it is
    // pressed - strobe - the three above.  The host that presses one key and
    // waits reads "resolved" as pressed - strobe, and its press is done when
    // that reaches the number the ack gave it.  `notify` is the host asking
    // to be told unasked - the silent-until-asked rule, docs/PROTOCOL.md -
    // and the notice carries the same words these two registers do.
    //
    // Both levels are the host's standing intention and survive a RES', as
    // BUTTONS does: a test that resets the machine wants its lock kept.
    // The card's reset - the watchdog's included - clears them, so a host
    // that has gone leaves no keyboard locked behind it.
    always_ff @(posedge clk) begin
        if (rst) begin
            kbd_lock   <= 1'b0;
            kbd_notify <= 1'b0;
        end else if (wr_kbd_ctrl) begin
            kbd_lock   <= wb_dat_w[0];
            kbd_notify <= wb_dat_w[1];
        end
    end

    wire [31:0] kbd_ctrl_rd = {kbd_counts_s[31:8], kbd_flags_s[2], 5'd0,
                               kbd_notify, kbd_lock};

    // ---- BUTTONS ------------------------------------------------------------
    //
    //   [1:0]    pb0       RW   Open-Apple:    00 hardware, 01 up, 10 down
    //   [3:2]    pb1       RW   Closed-Apple:  the same
    //   [5:4]    pb2       RW   PB2 ($C063):   the same
    //   [18:16]  hw        RO   bit 7 as the bus said it, last read of each
    //
    // A level the host holds, not an event: the machine reads a button now,
    // so there is nothing to consume.  Down then hardware is a press.  Not
    // reset-latched, and NOT dropped by RES' (rtl/pb_inject.sv says why:
    // Open-Apple-Ctrl-Reset is what Open-Apple is for).  11 is read as
    // down; the host never writes it.
    always_ff @(posedge clk) begin
        if (rst) begin
            pb_override <= 6'd0;          // hardware, all three
        end else if (wr_buttons) begin
            pb_override <= wb_dat_w[5:0];
        end
    end

    wire [31:0] buttons_rd = {13'd0, pb_hw_s, 10'd0, pb_override};

    // ---- VBL_CTRL / VBL_STAT / VBL_POS ------------------------------------
    //
    //   VBL_CTRL
    //   [0]      start      W1   run the detection: needs the boot hold; reads 0
    //   [1]      probe      W1   read probe_addr every cycle for one frame;
    //                            needs the lock and the boot hold; reads 0
    //   [2]      notify     RW   mark the frame origin in the capture stream
    //   [7:4]    state      RO   the detector's state (rtl/vbl_lock.sv)
    //   [8]      locked     RO   the counter is set
    //   [9]      pal        RO   312 lines, not 262
    //   [10]     busy       RO   a detection or a probe is running
    //   [15:12]  err        RO   the last run's result; 0 is success
    //   [31:16]  probe_addr RW   what a probe reads; $C019 (the //e's VBL')
    //                            at the card's reset
    //   VBL_STAT [15:0] mismatches in the last verify pass, [31:16] the slip
    //   VBL_POS  [14:0] the cycle within the frame, [23:16] frames, [31:24] locks
    //
    // The counter is the card's, not the machine's: RES' does not reset the
    // scanner and so does not reset this.  `notify` is the host asking to be
    // told - the silent-until-asked rule - and clears with the card, the
    // watchdog's included, like KBD_CTRL's.  See docs/VBL.md.
    always_ff @(posedge clk) begin
        if (rst) begin
            vbl_start      <= 1'b0;
            vbl_probe      <= 1'b0;
            vbl_notify     <= 1'b0;
            vbl_probe_addr <= 16'hC019;
        end else begin
            vbl_start <= wr_vbl_ctrl && wb_dat_w[0];
            vbl_probe <= wr_vbl_ctrl && wb_dat_w[1];
            if (wr_vbl_ctrl) begin
                vbl_notify     <= wb_dat_w[2];
                vbl_probe_addr <= wb_dat_w[31:16];
            end
        end
    end

    wire [31:0] vbl_ctrl_rd = {vbl_probe_addr, vbl_err_s, 1'b0, vbl_busy_s, vbl_pal_s, vbl_locked_s,
                               vbl_state_s, 1'b0, vbl_notify, 2'b00};

    assign wb_stall = 1'b0;

    wire access = wb_cyc && wb_stb;

    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack   <= 1'b0;
            wb_dat_r <= 32'd0;
        end else begin
            // One ack per strobe, and only ever one cycle wide.
            wb_ack <= access && !wb_ack;

            if (access && !wb_ack) begin
                if (!in_region) begin
                    wb_dat_r <= 32'd0;
                end else begin
                    case (word)
                        R_BUILD_DATE: wb_dat_r <= BUILD_DATE[31:0];
                        R_BUILD_TIME: wb_dat_r <= BUILD_TIME[31:0];
                        R_CPU_SOURCE: wb_dat_r <= cpu_source_rd;
                        R_MB_SLOT:    wb_dat_r <= mb_slot_rd;
                        R_BOOT_HOLD:  wb_dat_r <= boot_hold_rd;
                        R_HD_SLOT:    wb_dat_r <= hd_slot_rd;
                        R_RESET:      wb_dat_r <= reset_rd;
                        R_START:      wb_dat_r <= start_rd;
                        R_ROM_SUM:    wb_dat_r <= mem_rom_sum_s;
                        R_KBD_INJECT: wb_dat_r <= kbd_inject_rd;
                        R_BUTTONS:    wb_dat_r <= buttons_rd;
                        R_RING_STATUS: wb_dat_r <= ring_status_s;
                        R_KBD_CTRL:   wb_dat_r <= kbd_ctrl_rd;
                        R_MENU_HOLD:  wb_dat_r <= menu_hold_rd;
                        R_VBL_CTRL:   wb_dat_r <= vbl_ctrl_rd;
                        R_VBL_STAT:   wb_dat_r <= vbl_stat_s;
                        R_VBL_POS:    wb_dat_r <= vbl_pos_s;
                        R_FD_SLOT:    wb_dat_r <= fd_slot_rd;
                        R_FD_DRIVE1:  wb_dat_r <= fd_drive1_rd;
                        R_FD_DRIVE2:  wb_dat_r <= fd_drive2_rd;
                        R_FD_STAT:    wb_dat_r <= fd_stat_rd;
                        R_MEM_CTRL:   wb_dat_r <= mem_ctrl_rd;
                        R_MEM_STAT:   wb_dat_r <= mem_stat_rd;
                        R_MEM_HITS:   wb_dat_r <= MINIMAL ? 32'd0 : (mem_hits_s);
                        R_MEM_MISSES: wb_dat_r <= MINIMAL ? 32'd0 : (mem_misses_s);
                        R_MEM_MISMATCH: wb_dat_r <= MINIMAL ? 32'd0 : (mem_mismatch_s);
                        R_MEM_SERVED: wb_dat_r <= MINIMAL ? 32'd0 : (mem_served_s);
                        R_MEM_LAST:   wb_dat_r <= MINIMAL ? 32'd0 : (mem_last_s);
                        R_MEM_DIVERTED: wb_dat_r <= MINIMAL ? 32'd0 : (mem_diverted_s);
                        R_VIDHD_SLOT: wb_dat_r <= vidhd_slot_rd;
                        R_MOUSE_SLOT: wb_dat_r <= mouse_slot_rd;
                        R_MOUSE_STAT: wb_dat_r <= MINIMAL ? 32'd0 : (mouse_stat_rd);
                        R_NSC_CTRL:   wb_dat_r <= nsc_ctrl_rd;
                        R_RING_CTRL:  wb_dat_r <= {31'd0, ring_engage_q};
                        R_NSC_TIME:   wb_dat_r <= MINIMAL ? 32'd0 : (nsc_now_s[31:0]);
                        R_NSC_DATE:   wb_dat_r <= MINIMAL ? 32'd0 : (nsc_now_s[63:32]);
                        R_U2_SLOT:    wb_dat_r <= u2_slot_rd;
                        R_PRINTER_SLOT: wb_dat_r <= printer_slot_rd;
                        R_U2_STAT:    wb_dat_r <= MINIMAL ? 32'd0 : (u2_stat_rd);
                        R_LINK_STAT:  wb_dat_r <= link_stat_s;
                        R_AUDIO_CTRL: wb_dat_r <= audio_ctrl_rd;
                        R_AUDIO_RATE: wb_dat_r <= audio_rate_q;
                        R_AUDIO_STAT: wb_dat_r <= MINIMAL ? 32'd0 : (audio_stat_s);
                        R_FB_CTRL:    wb_dat_r <= fb_ctrl_rd;
                        R_FB_COMPARED: wb_dat_r <= MINIMAL ? 32'd0 : (fb_compared_s);
                        R_FB_MISMATCH: wb_dat_r <= MINIMAL ? 32'd0 : (fb_mismatch_s);
                        R_FB_LAST:    wb_dat_r <= MINIMAL ? 32'd0 : (fb_last_s);
                        R_FB_LAST2:   wb_dat_r <= MINIMAL ? 32'd0 : (fb_last2_s);
                        R_FB_OTHER:   wb_dat_r <= MINIMAL ? 32'd0 : (fb_other_s);
                        R_FB_PEEK:    wb_dat_r <= MINIMAL ? 32'd0 : (fb_peek_rd);
                        R_ACCEL_CTRL: wb_dat_r <= accel_ctrl_rd;
                        R_ACCEL_STAT: wb_dat_r <= accel_stat_s;
                        R_ACCEL_FAST: wb_dat_r <= accel_fast_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_BUS:  wb_dat_r <= accel_bus_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_CYCLES: wb_dat_r <= accel_cycles_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_WAIT: wb_dat_r <= accel_wait_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_TURBO: wb_dat_r <= accel_turbo_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_DLINE: wb_dat_r <= accel_dline_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_MAPS: wb_dat_r <= accel_maps_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_IDROP: wb_dat_r <= accel_idrop_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_IREVIVE: wb_dat_r <= accel_irevive_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_DDROP: wb_dat_r <= accel_ddrop_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_DREVIVE: wb_dat_r <= accel_drevive_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_MEM_FILLS:    wb_dat_r <= MINIMAL ? 32'd0 : (mem_fills_s);
                        R_MEM_FLUSHES:  wb_dat_r <= MINIMAL ? 32'd0 : (mem_flushes_s);
                        R_MEM_DECLINES: wb_dat_r <= MINIMAL ? 32'd0 : (mem_declines_s);
                        R_MEM_ROM:      wb_dat_r <= mem_rom_rd;
                        R_GS_ADB:       wb_dat_r <= MINIMAL ? 32'd0 : (gs_adb_stat_s);
                        R_ACCEL_CORE_CYC: wb_dat_r <= cnt_core_cyc_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_BUS_CYC:  wb_dat_r <= cnt_bus_cyc_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_DBG_SEL:        wb_dat_r <= MINIMAL ? 32'd0 : ({24'd0, dbg_sel});
                        R_DBG_VAL:        wb_dat_r <= MINIMAL ? 32'd0 : (dbg_val_s);
                        R_FD35_DRIVE:     wb_dat_r <= MINIMAL ? 32'd0 : (fd35_drive_rd);
                        R_FD35_STAT:      wb_dat_r <= MINIMAL ? 32'd0 : (fd35_stat_rd);
                        R_DDR3_DBG1:      wb_dat_r <= ddr3_dbg1_s;
                        R_DDR3_DBG2:      wb_dat_r <= ddr3_dbg2_s;
                        R_DDR3_DBG3:      wb_dat_r <= ddr3_dbg3_s;
                        R_DDR3_DBG4:      wb_dat_r <= ddr3_dbg4_s;
                        R_DDR3_EYE0:      wb_dat_r <= ddr3_eye0_s;
                        R_DDR3_EYE1:      wb_dat_r <= ddr3_eye1_s;
                        R_GS_CLOCK:       wb_dat_r <= MINIMAL ? 32'd0 : (gs_clock_stat_s);
                        R_PANEL_STAT:     wb_dat_r <= MINIMAL ? 32'd0 : ({24'd0, panel_drops_s, panel_dmas_s});
                        R_FD35_WSTAT:     wb_dat_r <= MINIMAL ? 32'd0 : (fd35_wstat_s);
                        R_TELEM_CTRL:     wb_dat_r <= telem_ctrl_rd;
                        R_WIDE_U2_CMDS:    wb_dat_r <= MINIMAL ? 32'd0 : (wide_u2_cmds_s);
                        R_WIDE_U2_RX:      wb_dat_r <= MINIMAL ? 32'd0 : (wide_u2_rx_s);
                        R_WIDE_PRN_WRITES: wb_dat_r <= MINIMAL ? 32'd0 : (wide_prn_writes_s);
                        R_WIDE_HD_EXECS:   wb_dat_r <= MINIMAL ? 32'd0 : (wide_hd_execs_s);
                        R_WIDE_PANEL_DMAS: wb_dat_r <= MINIMAL ? 32'd0 : (wide_panel_dmas_s);
                        R_WIDE_AUDIO_SENT: wb_dat_r <= MINIMAL ? 32'd0 : (wide_audio_sent_s);
                        R_ACCEL_FAST_I: wb_dat_r <= accel_fast_i_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_FAST_DRAM: wb_dat_r <= accel_fast_dram_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_FAST_DLC: wb_dat_r <= accel_fast_dlc_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_FAST_DROM: wb_dat_r <= accel_fast_drom_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_FAST_DCX: wb_dat_r <= accel_fast_dcx_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_FAST_WR: wb_dat_r <= accel_fast_wr_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_ACCEL_FAST_KBD: wb_dat_r <= accel_fast_kbd_s;   // the accelerator's instrument: kept under MINIMAL (2026-09-19)
                        R_GAME_STAT:      wb_dat_r <= MINIMAL ? 32'd0 : (game_stat_rd);
                        R_GAME_STAT2:     wb_dat_r <= MINIMAL ? 32'd0 : (game_stat2_rd);
                        default:      wb_dat_r <= 32'd0;
                    endcase
                end
            end
        end
    end

    // Writes.  One strobe per access, on the same edge the read uses, so a
    // write and its ack are the same single cycle a read is.  A write to a
    // read-only or unimplemented address lands nowhere and still acks, which is
    // the same forgiveness the read side gives an unknown address.
    //
    // wb_sel is not honoured: this file is whole-words-only by construction
    // (reg_bridge ties it to 4'hF), and a byte-enabled control register would
    // be a lie about what the host can express.
    wire wr_cpu_source = access && !wb_ack && in_region && wb_we &&
                         (word == R_CPU_SOURCE);
    wire wr_mb_slot    = access && !wb_ack && in_region && wb_we &&
                         (word == R_MB_SLOT);
    wire wr_boot_hold  = access && !wb_ack && in_region && wb_we &&
                         (word == R_BOOT_HOLD);
    wire wr_hd_slot    = access && !wb_ack && in_region && wb_we &&
                         (word == R_HD_SLOT);
    wire wr_reset      = access && !wb_ack && in_region && wb_we &&
                         (word == R_RESET);
    wire wr_start      = access && !wb_ack && in_region && wb_we &&
                         (word == R_START);
    wire wr_kbd_inject = access && !wb_ack && in_region && wb_we &&
                         (word == R_KBD_INJECT);
    wire wr_buttons    = access && !wb_ack && in_region && wb_we &&
                         (word == R_BUTTONS);
    wire wr_kbd_ctrl   = access && !wb_ack && in_region && wb_we &&
                         (word == R_KBD_CTRL);
    wire wr_menu_hold  = access && !wb_ack && in_region && wb_we &&
                         (word == R_MENU_HOLD);
    wire wr_vbl_ctrl   = access && !wb_ack && in_region && wb_we &&
                         (word == R_VBL_CTRL);
    wire wr_fd_slot    = access && !wb_ack && in_region && wb_we &&
                         (word == R_FD_SLOT);
    wire wr_fd_drive1  = access && !wb_ack && in_region && wb_we &&
                         (word == R_FD_DRIVE1);
    wire wr_fd_drive2  = access && !wb_ack && in_region && wb_we &&
                         (word == R_FD_DRIVE2);
    wire wr_fd_stat    = access && !wb_ack && in_region && wb_we &&
                         (word == R_FD_STAT);
    wire wr_fd35_drive = !MINIMAL && access && !wb_ack && in_region && wb_we &&
                         (word == R_FD35_DRIVE);
    wire wr_fd35_stat  = !MINIMAL && access && !wb_ack && in_region && wb_we &&
                         (word == R_FD35_STAT);
    wire wr_mem_ctrl   = access && !wb_ack && in_region && wb_we &&
                         (word == R_MEM_CTRL);
    wire wr_vidhd_slot = access && !wb_ack && in_region && wb_we &&
                         (word == R_VIDHD_SLOT);
    wire wr_mouse_slot = access && !wb_ack && in_region && wb_we &&
                         (word == R_MOUSE_SLOT);
    wire wr_nsc_ctrl   = access && !wb_ack && in_region && wb_we &&
                         (word == R_NSC_CTRL);
    wire wr_ring_ctrl  = access && !wb_ack && in_region && wb_we &&
                         (word == R_RING_CTRL);
    wire wr_audio_ctrl = access && !wb_ack && in_region && wb_we &&
                         (word == R_AUDIO_CTRL);
    wire wr_audio_rate = access && !wb_ack && in_region && wb_we &&
                         (word == R_AUDIO_RATE);
    wire wr_u2_slot    = access && !wb_ack && in_region && wb_we &&
                         (word == R_U2_SLOT);
    wire wr_printer_slot = access && !wb_ack && in_region && wb_we &&
                         (word == R_PRINTER_SLOT);
    wire wr_fb_ctrl    = access && !wb_ack && in_region && wb_we &&
                         (word == R_FB_CTRL);
    wire wr_fb_peek    = !MINIMAL && access && !wb_ack && in_region && wb_we &&
                         (word == R_FB_PEEK);
    wire wr_accel_ctrl = access && !wb_ack && in_region && wb_we &&
                         (word == R_ACCEL_CTRL);
    wire wr_dbg_sel    = !MINIMAL && access && !wb_ack && in_region && wb_we &&
                         (word == R_DBG_SEL);
    wire wr_telem_ctrl = access && !wb_ack && in_region && wb_we &&
                         (word == R_TELEM_CTRL);
    always_ff @(posedge clk) begin
        if (rst)            dbg_sel <= 8'd0;
        else if (wr_dbg_sel) dbg_sel <= wb_dat_w[7:0];
    end

    // A boot-hold RELEASE re-latches MB_SLOT, HD_SLOT, FD_SLOT and VIDHD_SLOT above, so the menu's
    // choices reach the boot it releases into.  Same qualification as the
    // release pulse itself; CPU_SOURCE deliberately does NOT re-latch here -
    // switching the driving CPU mid-hold is the one changeover BOOT_MENU.md
    // keeps to a reset.  A release from the RUNTIME hold re-latches nothing:
    // the program it resumes has already decided about its slots, and a card
    // that moved under it would be the mid-run changeover this file exists
    // to prevent.
    wire boot_relatch  = wr_boot_hold && wb_dat_w[16] && !hold_runtime;

    // ---- the register cut's flops -------------------------------------------
    // (Declared and explained at the head of the file, "the register cut".)
    // One edge for all of them, and one enable: what snap_hold holds is one
    // instant of the whole card.  DBG_VAL alone follows THROUGH the hold: the
    // telemetry sweep reads the debug space through it while the hold is up,
    // item by item, and what the hold freezes is the words behind the
    // debug mux (rtl/master_top.sv), not the mux's output.
    always_ff @(posedge clk) dbg_val_s <= dbg_val;
    always_ff @(posedge clk) begin
        if (!snap_hold) begin
            cpu_src_active_s      <= cpu_src_active;
            cpu_src_latches_s     <= cpu_src_latches;
            mb_slot_active_s      <= mb_slot_active_q;
            mb_phasor_active_s    <= mb_phasor_active_q;
            boot_holds_s          <= boot_holds;
            boot_held_s           <= boot_held;
            hold_runtime_s        <= hold_runtime;
            menu_count_s          <= menu_count;
            hd_slot_active_s      <= hd_slot_active_q;
            hd_rom_loaded_s       <= hd_rom_loaded;
            hd_busy_s             <= hd_busy;
            hd_execs_s            <= hd_execs;
            fd_slot_active_s      <= fd_slot_active_q;
            fd_rom_loaded_s       <= fd_rom_loaded;
            fd_seeks_s            <= fd_seeks;
            fd_stale_s            <= fd_stale;
            fd_dirty_s            <= fd_dirty;
            fd_phase_s            <= fd_phase;
            fd_ctl_s              <= fd_ctl;
            fd_late_s             <= fd_late;
            fd_fill_max_s         <= fd_fill_max;
            fd35_stale_s          <= fd35_stale;
            fd35_side_s           <= fd35_side;
            fd35_motor35_s        <= fd35_motor35;
            fd35_motor_s          <= fd35_motor;
            fd35_track_s          <= fd35_track;
            fd35_ctl_s            <= fd35_ctl;
            fd35_seeks_s          <= fd35_seeks;
            fd35_late_s           <= fd35_late;
            fd35_wstat_s          <= fd35_wstat;
            fd35_fill_max_s       <= fd35_fill_max;
            vidhd_slot_active_s   <= vidhd_slot_active_q;
            vidhd_rom_loaded_s    <= vidhd_rom_loaded;
            mouse_slot_active_s   <= mouse_slot_active_q;
            mouse_rom_loaded_s    <= mouse_rom_loaded;
            mouse_irq_s           <= mouse_irq;
            mouse_mode_s          <= mouse_mode;
            mouse_buttons_s       <= mouse_buttons;
            mouse_moves_s         <= mouse_moves;
            mouse_x_s             <= mouse_x;
            mouse_y_s             <= mouse_y;
            u2_slot_active_s      <= u2_slot_active_q;
            u2_sock_open_s        <= u2_sock_open;
            u2_cmd_dropped_s      <= u2_cmd_dropped;
            u2_cmds_s             <= u2_cmds;
            u2_rx_chunks_s        <= u2_rx_chunks;
            u2_s0_rsr_s           <= u2_s0_rsr;
            u2_s0_fsr_s           <= u2_s0_fsr;
            printer_slot_active_s <= printer_slot_active_q;
            printer_rom_loaded_s  <= printer_rom_loaded;
            printer_writes_s      <= printer_writes;
            nsc_time_loaded_s     <= nsc_time_loaded;
            nsc_ring_en_s         <= nsc_ring_en;
            nsc_wr_en_s           <= nsc_wr_en;
            nsc_cmp_idx_s         <= nsc_cmp_idx;
            nsc_ring_idx_s        <= nsc_ring_idx;
            nsc_unlocks_s         <= nsc_unlocks;
            nsc_now_s             <= nsc_now;
            kbd_flags_s           <= kbd_flags;
            kbd_counts_s          <= kbd_counts;
            pb_hw_s               <= pb_hw;
            vbl_state_s           <= vbl_state;
            vbl_err_s             <= vbl_err;
            vbl_locked_s          <= vbl_locked;
            vbl_pal_s             <= vbl_pal;
            vbl_busy_s            <= vbl_busy;
            vbl_stat_s            <= vbl_stat;
            vbl_pos_s             <= vbl_pos;
            mem_sw_s              <= mem_sw;
            mem_rw_bank_s         <= mem_rw_bank;
            mem_image_ready_s     <= mem_image_ready;
            mem_invalidating_s    <= mem_invalidating;
            mem_rom_loaded_s      <= mem_rom_loaded;
            mem_intc8rom_s        <= mem_intc8rom;
            mem_late_fills_s      <= mem_late_fills;
            mem_fifo_drops_s      <= mem_fifo_drops;
            mem_fills_s           <= mem_fills;
            mem_flushes_s         <= mem_flushes;
            mem_declines_s        <= mem_declines;
            mem_rom_busy_s        <= mem_rom_busy;
            mem_rom_sum_s         <= mem_rom_sum;
            mem_rom_over_s        <= mem_rom_over;
            mem_rom_xland_s       <= mem_rom_xland;
            mem_shd_drops_s       <= mem_shd_drops;
            gs_adb_stat_s         <= gs_adb_stat;
            gs_clock_stat_s       <= gs_clock_stat;
            panel_dmas_s          <= panel_dmas;
            panel_drops_s         <= panel_drops;
            cnt_core_cyc_s        <= cnt_core_cyc;
            cnt_bus_cyc_s         <= cnt_bus_cyc;
            mem_hits_s            <= mem_hits;
            mem_misses_s          <= mem_misses;
            mem_mismatch_s        <= mem_mismatch;
            mem_served_s          <= mem_served;
            mem_last_s            <= mem_last;
            mem_diverted_s        <= mem_diverted;
            game_pb_s             <= game_pb;
            game_pb_ok_s          <= game_pb_ok;
            game_pdl_ok_s         <= game_pdl_ok;
            game_pdl0_s           <= game_pdl0;
            game_pdl1_s           <= game_pdl1;
            game_pdl2_s           <= game_pdl2;
            game_pdl3_s           <= game_pdl3;
            game_meas_s           <= game_meas;
            accel_stat_s          <= accel_stat;
            accel_fast_s          <= accel_fast;
            accel_bus_s           <= accel_bus;
            accel_cycles_s        <= accel_cycles;
            accel_wait_s          <= accel_wait;
            accel_turbo_s         <= accel_turbo;
            accel_dline_s         <= accel_dline;
            accel_maps_s          <= accel_maps;
            accel_ddrop_s         <= accel_ddrop;
            accel_drevive_s       <= accel_drevive;
            accel_idrop_s         <= accel_idrop;
            accel_irevive_s       <= accel_irevive;
            accel_fast_i_s        <= accel_fast_i;
            accel_fast_dram_s     <= accel_fast_dram;
            accel_fast_dlc_s      <= accel_fast_dlc;
            accel_fast_drom_s     <= accel_fast_drom;
            accel_fast_dcx_s      <= accel_fast_dcx;
            accel_fast_wr_s       <= accel_fast_wr;
            accel_fast_kbd_s      <= accel_fast_kbd;
            fb_mode_s             <= fb_mode;
            fb_compared_s         <= fb_compared;
            fb_mismatch_s         <= fb_mismatch;
            fb_last_s             <= fb_last;
            fb_last2_s            <= fb_last2;
            fb_other_s            <= fb_other;
            fb_peek_data_s        <= fb_peek_data;
            res_pulsing_s         <= res_pulsing;
            res_pulses_s          <= res_pulses;
            start_pending_s       <= start_pending;
            start_cause_card_s    <= start_cause_card;
            start_cause_res_s     <= start_cause_res;
            start_count_s         <= start_count;
            telem_stat_s          <= telem_stat;
            wide_u2_cmds_s        <= wide_u2_cmds;
            wide_u2_rx_s          <= wide_u2_rx;
            wide_prn_writes_s     <= wide_prn_writes;
            wide_hd_execs_s       <= wide_hd_execs;
            wide_panel_dmas_s     <= wide_panel_dmas;
            wide_audio_sent_s     <= wide_audio_sent;
            ring_status_s         <= ring_status;
            link_stat_s           <= link_stat;
            ddr3_dbg1_s           <= ddr3_dbg1;
            ddr3_dbg2_s           <= ddr3_dbg2;
            ddr3_dbg3_s           <= ddr3_dbg3;
            ddr3_dbg4_s           <= ddr3_dbg4;
            ddr3_eye0_s           <= ddr3_eye0;
            ddr3_eye1_s           <= ddr3_eye1;
            audio_stat_s          <= audio_stat;
        end
    end

    // wb_adr[1:0] are byte lanes within a word and are deliberately not decoded.
    wire _unused_ok = &{1'b0, wb_dat_w[31:1], wb_sel, wb_adr[1:0], 1'b0};

endmodule
