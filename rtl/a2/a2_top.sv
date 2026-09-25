`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// master_top - the card as the Apple II's CPU.
//
// snoop_top with three things added: a driver, a 65C02, and Apple pins that are
// inout rather than input.  Everything else is card_link, shared, so the link
// and the capture path here are the ones already closed on hardware.
//
// THE INSTRUMENT IS STILL RUNNING.  apple_bus_read is instantiated exactly as in
// the snooper and still drives nothing, so every cycle this board drives is
// captured and shipped to the host on the same path as a snoop.  That is
// unusual for a bring-up and it is the point: a driven cycle can be CHECKED
// against a capture instead of inferred, and sim/run_trace_replay.sh already
// knows how to read the result.
//
// THE HANDOVER is not decided here.  wb_regfile latches CPU_SOURCE on the
// falling edge of RES' and this top simply follows what it latched - so the
// changeover always happens inside a reset the motherboard holds for far longer
// than it takes, and never in the middle of a running machine.  Writing the
// register does nothing until then, deliberately.  See docs/BUS_MASTER.md.
//
// THE CORE IS RESET WITH THE MACHINE.  cpu65c02's rst is the card's reset OR
// the Apple's RES' being asserted, so when the //e is reset the soft core is
// too, and it comes out of reset running its own 7-cycle reset sequence -
// fetching $FFFC/$FFFD from the machine's own ROM over the bus it is driving.
//
// THE BOOT HOLD sits between the core and the driver.  When the host has
// armed it, the core is stopped at its post-reset opcode fetch and the driver
// presents keyboard reads on its behalf until the host says go; see
// rtl/boot_hold.sv and docs/BOOT_MENU.md.  Unarmed, it is a wire.
//
// THE HARD DISK sits there too.  It answers busy on its EXECUTE port until
// the host has the command's answer, and moves blocks between the Apple's
// memory and its own buffer through the same override, pausing the core for
// exactly those cycles; see rtl/hd_card.sv and docs/HARDDISK.md.  The two
// overrides cannot want the same cycle - the hold takes only the post-reset
// opcode fetch, a DMA only follows a command the running machine issued -
// and the mux below gives the hold the cycle anyway, so that if they ever
// could, the answer is defined.
//
// THE FLOPPY sits beside the disk, and takes no cycle at all: its data
// register is served from a track buffer on the card, and the host fills
// the buffer beside the read stream, never in it; see rtl/floppy_card.sv
// and docs/FLOPPY.md.
//
// KEYBOARD AND BUTTON INJECTION sit beside the core's din.  A key the host
// pressed is what the core latches on its next $C00x read, a button the host
// holds is bit 7 of its next $C061-$C063 read, and the capture records the
// same byte for that cycle - a substitution, never a drive, because the
// motherboard owns those pins; see rtl/kbd_inject.sv, rtl/pb_inject.sv and
// docs/KEYBOARD.md.  Nothing pressed, both are wires.
//
// THE VBL LOCK listens to every cycle and, during the boot hold, takes them:
// it writes a known picture into the text page, reads the floating bus on
// every cycle until it finds the scanner's frame, and counts from then on.
// Its mark on the frame-origin event goes to the capture with the event, so
// the host is told to the cycle; see rtl/vbl_lock.sv and docs/VBL.md.
//
// THE SEQUENCER sits between the core and the driver.  With ACCEL_CTRL off it
// is a wire and every cycle is the core's, exactly as before it existed; on,
// the core runs from the card's memory at a handful of clocks an op and the
// driver fills the bus with dummy cycles, merging the core in for the ops the
// machine must see.  Every memory-side consumer - the MMU shadow, the page
// cache, the floating-bus simulator, the hold - watches the sequencer's
// unified stream of ops; every peripheral that decodes $Cxxx or counts bus
// cycles watches the driver, whose ops those always are.  See
// rtl/accel_seq.sv and docs/ACCELERATION.md.
//
// WHAT IS NOT HERE YET: INH, RDY and NMI.  INH would let the card override the
// machine's own memory, which is a memory-mode decision that has not been made;
// RDY is not used by the Apple II for the CPU; the slot brings out no NMI.
//////////////////////////////////////////////////////////////////////////////////
module a2_top #(
    parameter integer BUILD_DATE = 0,   // YYYYMMDD
    parameter integer BUILD_TIME = 0,   // HHMMSS
    // The part this image is built for, as its JTAG IDCODE (build.tcl sets it from
    // the part): the flash block's BOOT_PART, and what a package's record must name
    // (docs/BOOT_LOADER.md).  The default is the Pt V2's xc7a100t.
    parameter logic [31:0] IDCODE = 32'h13631093,
    // The page cache's geometry (rtl/page_cache.sv, docs/PAGE_CACHE.md):
    // 128 x 8 pages of 256 bytes is 256 KB, and the whole IIe plus its ROM
    // occupies five of every set's eight ways.  64 x 8 is the cheap fallback
    // if the block RAM is ever wanted elsewhere; both are proven by
    // sim/run_page_cache_tb.sh's sweep.
    // THE 65C02 CARD'S L2 (docs/CORE_REFACTOR_65C02.md rung 3): 64 sets x 6
    // ways = 384 pages = 96 KB = 24 RAMB36, the Au's budget; the IIe's 576
    // pages do not all fit, so this card evicts, and the referenced-way rule
    // keeps L1's pointers safe.  128 x 8 was the Pt's.
    parameter integer MEM_SETS = 64,
    parameter integer MEM_WAYS = 6,
    // THE MACHINE (docs/GS.md rung 4).  0 = the Apple IIe this board has
    // always been: a 65C02, the two fronts, the IIe's own $Cxxx apparatus.
    // 1 = the Apple IIgs: a 65816 on the dispatcher, rtl/gs_io.sv answering
    // the chipset's registers, the map and the ROM in the 24-bit space.
    // build/build.sh --gs sets it; the plain build must stay bit-identical
    // at GS = 0, which the IIe battery is the parity check on.
    // THE MACHINE is this top: the 65C02 card (rtl/a2, docs/REQ_65C02.md).
    // GS stays a constant 0 until every conditional that names it leaves with
    // the module that owns it (docs/CORE_REFACTOR_65C02.md rung 1).
    localparam bit GS = 1'b0,
    parameter integer CK_PHASE_SHIFT = 1  // write-level the DDR3's CK (docs/UBERDDR3.md rung 2; the default since 2026-09-18)
) (
    input  wire        clk_pin,
    input  wire        rst_n,
    output wire [7:0]  led,
    input  wire        usb_rx,
    output wire        usb_tx,

    // The configuration flash after configuration (constr/<board>/flash_pins.xdc);
    // its clock is CCLK, driven through STARTUPE2 inside card_link.
    output wire        flash_cs_n,
    output wire        flash_mosi,
    input  wire        flash_miso,
    output wire        flash_wp_n,
    output wire        flash_hold_n,

    // Apple II bus (constr/apple_bus.xdc).  INOUT here - this build drives.
    inout  wire [7:0]  apple_data_pin,
    inout  wire [15:0] apple_addr_pin,
    inout  wire        apple_rw_pin,
    input  wire        apple_phi0_pin,
    input  wire        apple_m2sel_pin,
    input  wire        apple_m2b0_pin,
    input  wire        apple_inh_pin,
    inout  wire        apple_res_pin,
    input  wire        apple_irq_pin,
    input  wire        apple_rdy_pin,
    inout  wire        apple_dma_pin,
    input  wire        tini_5v_pin,
    output wire        tini_oe_pin,
    output wire        tini_addr_dir_pin,
    output wire        tini_data_dir_pin,

    // FT601 (constr/ft601.xdc)
    input  wire        ft_clk,
    input  wire        ft_rxf,
    input  wire        ft_txe,
    output wire        ft_rd,
    output wire        ft_wr,
    output wire        ft_oe,
    output wire        ft_wakeup,
    output wire        ft_reset,
    inout  wire [31:0] ft_data,
    inout  wire [3:0]  ft_be,

    // DDR3 (constr/<board>/ddr3.xdc).  The card's outgoing stream crosses it; see
    // card_link and docs/TX_RING.md.  Names match au_top's.
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_p,
    inout  wire [1:0]  ddr3_dqs_n
);

    wire        apple_clk, apple_rst;
    wire        capture_on, capture_real;
    wire [63:0] real_data;
    // THE BUS RECORD'S BANK.  apple_bus_read snoops an eight-bit bus and
    // records zero in word 0's [27:20], which is right for a IIe and was left
    // that way on the IIgs because "a bus cycle is bank zero's" - and the hard
    // disk's DMA is a bus cycle.  So every extended read into bank $7E reached
    // the host as bank-zero writes: its mirror put block 1369 at $00/BE00, and
    // block 1370's bytes at $00/C0F9-C0FA went into the host's own FIFO decode
    // as register writes, which is where GS/OS's "Error=$0028" came from
    // (docs/GS.md rung 4c, on hardware).  The bank is the presented op's: the
    // override's while the hard disk drives the bus, HELD - the last byte's
    // data sample comes after ovr_en has dropped - else the core's, which is
    // still for the length of its own bus cycle.  The fast-op word has carried
    // fev_bank since rung 4b; this is the same fix for the other half of the
    // stream.  Zero at GS = 0, so the IIe's record is the byte it always was.
    logic [7:0] ovr_bank_q = 8'd0;
    always_ff @(posedge apple_clk) if (hd_ovr_en) ovr_bank_q <= hd_ovr_bank;
    wire [7:0]  ev_bank     = GS ? (op_ovr ? ovr_bank_q : cpu_bank) : 8'd0;
    wire [63:0] real_data_b = {real_data[63:28], ev_bank, real_data[19:0]};
    // ...AND THE SPEAKER ASKS THE SAME QUESTION.  $C030 is the speaker in the
    // four I/O banks only; in bank $7E it is a byte of a GS/OS disk buffer,
    // and every block that landed over it clicked (the same night, on
    // hardware).  gs_io already decides its own claims by pair_bank(); the
    // speaker is fed the bus cycle and the fast op directly, so it is
    // qualified here.  A IIe's banks are zero: unchanged.
    function automatic io_bank_f(input [7:0] bk);
        io_bank_f = (bk == 8'h00) || (bk == 8'h01) || (bk == 8'hE0) || (bk == 8'hE1);
    endfunction
    wire real_io = !GS || io_bank_f(ev_bank);
    wire fast_io = !GS || io_bank_f(fev_valid ? fev_bank : tev_valid ? tev_bank : dev_bank);
    wire        real_valid, phi0_live, bus_tick;
    wire        apple_res_sync, apple_irq_sync, apple_phi0_sync;
    wire [7:0]  apple_data_sync;
    wire        cpu_source_active;
    wire [2:0]  mb_slot_active, hd_slot_active;
    wire        mb_phasor_active;
    wire        boot_arm, boot_release, boot_held, hold_runtime;
    wire        menu_en, menu_trigger, hotkey_hit;
    wire [6:0]  menu_hotkey;
    wire        hd_rom_loaded, hd_busy;
    wire [7:0]  hd_execs;
    wire [2:0]  fd_slot_active;
    wire        fd_rom_loaded, fd_late_clr, fd_fill_clr;
    wire [7:0]  fd_seeks, fd_late;
    wire [15:0] fd_fill_max;
    wire [1:0]  fd_inserted, fd_wp, fd_flush, fd_stale, fd_dirty;
    wire [25:0] fd_nibbles;
    wire [11:0] fd_tracks;
    wire [13:0] fd_phase;
    wire        fd_motor, fd_drive_sel, fd_q6, fd_q7;
    wire [31:0] fd_word;
    wire        fd_valid, fd_take;
    // The 3.5" drive on the IWM (rtl/gs_iwm.sv, docs/IWM35.md).
    wire [31:0] fd35_word;
    wire        fd35_valid, fd35_take;
    wire        fd35_inserted, fd35_wp, fd35_stale, fd35_side, fd35_motor35, fd35_motor;
    wire        fd35_late_clr, fd35_fill_clr, fd35_stall;
    // The 5.25" drives on the IIgs's IWM: their readback for FD_DRIVE1/2
    // (rtl/gs_iwm.sv), in place of the Disk II card's at GS = 1.
    wire [1:0]  gsio_fd525_stale, gsio_fd525_dirty;
    wire [13:0] gsio_fd525_phase;
    wire [6:0]  fd35_track;
    wire [7:0]  fd35_ctl, fd35_seeks, fd35_late;
    wire [31:0] fd35_wstat;
    wire [15:0] fd35_fill_max;
    wire [2:0]  vidhd_slot_active;
    wire        vidhd_rom_loaded;
    wire [2:0]  mouse_slot_active;
    wire        mouse_rom_loaded, mouse_irq;
    wire [3:0]  mouse_mode;
    wire [1:0]  mouse_buttons;
    wire [7:0]  mouse_moves;
    wire [15:0] mouse_x, mouse_y;
    wire [2:0]  u2_slot_active;
    wire [3:0]  u2_sock_open;
    wire        u2_cmd_dropped, u2_stall;
    wire [7:0]  u2_cmds, u2_rx_chunks;
    wire [15:0] u2_s0_rsr, u2_s0_fsr;
    wire [2:0]  printer_slot_active;
    wire        printer_rom_loaded;
    wire [7:0]  printer_writes;
    wire [31:0] u2_word;
    wire        audio_on, audio_realtime;
    wire [31:0] audio_rate, audio_stat;
    wire [31:0] au_word;
    wire        au_valid, au_take;
    wire        spk_level, spk_toggle;
    wire [39:0] mb_ay_out;
    wire        smp_valid;
    wire [15:0] smp_spk;
    wire [63:0] smp_ay;
    // The Ensoniq's stereo pair, the sample stream's fourth word.
    wire [15:0] smp_doc_l, smp_doc_r;
    wire        u2_valid, u2_take;
    wire        nsc_enable, nsc_sub, nsc_bit, nsc_time_loaded, nsc_ring_en, nsc_wr_en;
    wire [5:0]  nsc_cmp_idx, nsc_ring_idx;
    wire [7:0]  nsc_unlocks;
    wire [63:0] nsc_now;
    wire        kbd_press, kbd_drop, kbd_lock;
    wire [6:0]  kbd_press_key;
    wire        kbd_strobe, kbd_seen, kbd_touched, kbd_changed;
    wire [7:0]  kbd_pressed, kbd_taken, kbd_flushed, kbd_replaced;
    wire [6:0]  kbd_resolved_key;
    wire        kbd_sub_en, pb_sub_en;
    wire [7:0]  kbd_sub_data, pb_sub_data;
    wire [5:0]  pb_override;
    wire [2:0]  pb_hw;
    // The four substitutions answer for disjoint addresses - the keyboard
    // $C00x, the buttons $C061-3, the memory image nothing in $C000-$CFFF at
    // all, the floating-bus simulator $C020-$C05F and $C070-$C08F (and it
    // stands down for the other two by name) - so at most one asserts on any
    // cycle; the mux only has to be defined.  Each newcomer goes last so the
    // ones that were here are untouched.
    // The cache's answer reaches this mux only while the bus owns the op
    // stream: a fast op's byte goes to the core through the sequencer, and
    // must not linger into a dummy cycle's event.
    wire        bus_owns;
    wire        mem_sub_en, fb_sub_en;
    wire [7:0]  mem_sub_data, fb_sub_data;
    wire        mem_sub_bus = mem_sub_en && bus_owns;
    // THREE OF THE FOUR ARE THE IIe's (docs/GS.md rung 4).  The keyboard
    // latch, the buttons and the floating-bus simulator all answer for
    // $C0xx addresses a IIgs decodes differently - $C000 and $C010 are the
    // ADB micro's, $C019 the VGC's - and rtl/gs_io.sv answers those as an
    // INTERNALIZED op, before a bus cycle is ever presented.  A substitution
    // on top of that would be a second authority for the same byte, so the
    // three stand down at GS = 1 and only the memory image's answer remains.
    // The modules stay built and their host-side levers still work; nothing
    // reaches them, which the host holds up by not arming them.
    wire        kbd_sub_gs = kbd_sub_en && !GS;
    wire        pb_sub_gs  = pb_sub_en  && !GS;
    wire        fb_sub_gs  = fb_sub_en  && !GS;
    wire        sub_en   = kbd_sub_gs | pb_sub_gs | mem_sub_bus | fb_sub_gs;
    wire [7:0]  sub_data = kbd_sub_gs ? kbd_sub_data :
                           pb_sub_gs  ? pb_sub_data  :
                           mem_sub_bus ? mem_sub_data : fb_sub_data;
    // The memory image's seam through card_link (rtl/page_client.sv is there,
    // beside the DDR3; the MMU shadow, the ROM and the page cache are here,
    // beside the core).  See docs/PAGE_CACHE.md.
    wire        pq_busy, pq_valid, pq_we, pq_ready, pr_valid;
    wire [19:0] pq_line;
    wire [127:0] pq_wdata, pr_data;
    wire        mem_image_ready, mem_cnt_clr, mem_inval, mem_invalidating, mem_rom_loaded;
    wire [31:0] mem_fills, mem_flushes, mem_declines;
    wire        mem_serve;
    wire [11:0] mem_sw;
    wire [7:0]  mem_rw_bank;
    wire [7:0]  mem_late_fills, mem_fifo_drops;
    wire [31:0] mem_hits, mem_misses, mem_mismatch, mem_served, mem_last, mem_diverted;
    wire        res_drive;
    wire        vbl_start, vbl_probe, vbl_notify, vbl_locked, vbl_pal, vbl_busy;
    wire [15:0] vbl_probe_addr;
    wire [3:0]  vbl_state, vbl_err;
    wire [31:0] vbl_stat, vbl_pos;
    wire        vbl_mark;
    wire [15:0] vbl_mark_free;
    wire        lock_vbl_level; // the lock's counter in blanking
    wire [8:0]  lock_scan_v;
    wire [6:0]  lock_scan_h;
    // ...and the beam every consumer takes (rtl/vbeam.sv): the lock's, or
    // the virtual one under acceleration.  vbl_level is bit 19 of every
    // stream word.
    wire        vbl_level, beam_locked, beam_mark_bus, beam_mark_fast, virt, fev_quiet;
    wire [15:0] beam_mark_free;
    // The STREAM's base, for the merge's door and the filter: the virtual
    // one only on the IIe under acceleration.  The IIgs's beam runs at the
    // bus's cadence (vbeam `wall`, below), which to the host is the bus's
    // base - dummies are cycles, fast words are not, every frame is shown.
    wire        virt_base;

    // ---- the ADB micro's own clock ------------------------------------------
    // A sixtieth of a WALL second, divided off the 100 MHz clock.  The IIgs's
    // ADB micro auto-repeats a held key on a timer of its own - a separate
    // processor with a separate oscillator - and KEGS counts that timer in
    // video frames only because a KEGS frame is a sixtieth of a wall second.
    // The card's frame (vbeam, above) is NOT: under acceleration it runs in
    // the core's cycles, and on the beam's frame the micro's 750 ms delay
    // was 25 ms at thirty-fold and a tap repeated before the finger lifted
    // (2026-09-11).  The interrupt controller's timers stay on the beam,
    // which is the rule for everything the PROGRAM can measure
    // (docs/VIRTUAL_TIME.md); this tick reaches only the two modules that
    // stand for the user's hands - gs_adb's repeat and gs_kbd_a2's held-key
    // timeout.  Declared here, above every generate block, on purpose
    // (tools/check_generate_scope.py).
    localparam integer WALL_60HZ = 100_000_000 / 60;
    logic [20:0] wall_ctr  = 21'd0;
    logic        wall_tick = 1'b0;
    always_ff @(posedge apple_clk) begin
        if (wall_ctr == WALL_60HZ - 1) begin
            wall_ctr  <= 21'd0;
            wall_tick <= 1'b1;
        end else begin
            wall_ctr  <= wall_ctr + 21'd1;
            wall_tick <= 1'b0;
        end
    end
    wire [8:0]  scan_v;         // ...and where it is, for the floating-bus simulator
    wire [6:0]  scan_h;
    wire [2:0]  vid_sw;         // the MMU shadow's video switches, for the same
    wire        fb_serve, fb_cnt_clr;
    wire [14:0] fb_peek_addr;
    wire        fb_mw_stb;          // the main bank's writes as they land, for the copy
    wire        fb_mwx_stb;         // ...and ANY bank's, with the bank, for the IIgs's SCBs
    wire [7:0]  fb_mw_bank;
    wire [15:0] fb_mw_addr;
    wire [7:0]  fb_mw_byte;
    wire [6:0]  fb_mode;
    wire [31:0] fb_compared, fb_mismatch, fb_last, fb_last2, fb_other;
    wire [7:0]  fb_peek_data;
    // The sequencer: ACCEL_CTRL in, its stream, status and counters out.
    wire [1:0]  accel_mode;
    wire        accel_swint_dis, accel_game_dis, accel_l1_dis;
    // The debug pair (rtl/wb_regfile.sv DBG_SEL/DBG_VAL, docs/GS.md rung 6).
    wire [7:0]  dbg_sel;
    wire [31:0] dbg_val, il_dbg, dl_dbg, pc_dbg;
    wire [31:0] dl_dbg2 = 32'd0;   // the bank table's page: the 65816 card's
    // The register cut's hold (docs/TELEMETRY.md): while the telemetry sender
    // sweeps, the top's debug snapshot words and the clock histogram's copies
    // stand still too, so a sample's histogram sums to its own CLOCKS.
    wire        tm_snap_hold;
    // The game port in the dummies (rtl/game_port.sv).
    wire [15:0] game_park_addr;
    wire        game_pb_ok, game_pdl_ok;
    wire [7:0]  game_int_byte;
    wire [2:0]  game_pb;
    wire [11:0] game_pdl0, game_pdl1, game_pdl2, game_pdl3;
    wire [7:0]  game_meas;
    wire [15:0] accel_target;
    wire        accel_cnt_clr, accel_on, accel_held;
    wire [3:0]  seq_state;
    wire [31:0] accel_fast, accel_bus, accel_cycles, accel_wait;
    wire [7:0]  accel_retries, merge_overflows;
    wire        accel_reset_seq;
    wire        u_present, u_commit, u_rw, u_sync, u_ovr, u_divert;
    wire [15:0] u_addr;
    wire [7:0]  u_bank;
    wire [7:0]  u_wdata;
    wire        fev_valid, fev_rw, fev_sync;
    wire        fd_stall;           // the floppy's fill pending: the accelerated core waits
    wire [15:0] fev_addr;
    // The fast event's bank.  NOTHING TAKES IT ON THIS BUILD, and that is
    // right: the v6 record has the field (word 0 [27:20], docs/PROTOCOL.md)
    // but card_link's fast port is sixteen bits and a IIe's bank is always
    // zero, so the merge hardwires it.  The capture path widens at rung 3c,
    // when the host learns to classify a IIgs stream (docs/GS.md).
    wire [7:0]  fev_bank;
    wire [7:0]  fev_data;
    wire        core_valid, op_dummy, op_inflight, drv_cyc_done;
    wire [7:0]  drv_din;
    wire        mem_decided, mem_busy, mem_intc8rom;
    wire [1:0]  q_cls;
    // L1-I (rtl/a2/l1i.sv) and its seams.
    wire        seq_cyc_en, turbo_en, turbo_ok, turbo_commit, turbo_sync, turbo_claim, seq_fast_tick;
    wire        seq_mem_served;   // the dispatcher's read served by the page cache, this clock
    // L1-D, chained after L1-I (rtl/a2/l1d.sv).
    wire        l1i_cyc_en, d_commit_w, d_claim_w, dline_tick, dev_valid, dev_rw;
    wire        il_fill_busy, dl_fill_busy;   // L1's fills in flight (the clock histogram)
    // The dispatcher's read, whole, from the page cache to the data front
    // (docs/DLINE.md "the miss's read fills the line").
    wire         mem_op_row_v;
    wire [127:0] mem_op_row;
    wire [15:0]  mem_op_row_ppn;
    wire        d_pending_w, turbo_wr, dq_rw_w, ev_fast_room_w;
    wire        pw_valid_w, pw_take_w, pw_ready_w, ws_valid_w;
    wire [7:0]  pw_data_w, cl_wdata;
    // The posted write's seam is the PHYSICAL page and the byte in it now
    // (docs/MEMORY_REFACTOR.md, rung 2); the instruction front's snoop still
    // speaks the old triple until rung 3 converts it.
    wire [15:0] pw_ppn_w, ws_ppn_w;
    wire [7:0]  pw_off_w, ws_off8_w;
    wire        cl_posted;
    wire [23:0] cpu_d_pred;
    wire [15:0] dev_addr;
    wire        cpu_d_pred_v, cpu_d_pred_rw;
    // THE FRONTS ON THE IIgs (docs/GS.md rung 6): the predicted bank's class,
    // the program bank, the data bank register, the bank-write hold, and the
    // banks the two fronts' events carry.  All zero at GS = 0.
    wire [1:0]  cpu_d_pred_bcls;
    wire [7:0]  cpu_pc_bank, cpu_dbr, tev_bank, dev_bank;
    wire        cpu_bank_wr;
    wire [7:0]  d_din_w, dev_data;
    wire [23:0] dq_addr_w;
    wire [15:0] doff_w;
    wire [1:0]  dcls_w;
    wire        daux_w;
    wire        turbo_tick, tev_valid, tev_sync, ev_fast_room;
    wire [15:0] tev_addr;
    wire [7:0]  tev_data, i_din_w;
    wire [31:0] accel_turbo, accel_dline, accel_maps;
    wire [31:0] accel_ddrop, accel_drevive, accel_idrop, accel_irevive;
    wire        accel_cen_v;
    wire [2:0]  accel_cen_sel;
    wire [1:0]  p_cls;
    wire        p_aux_w, map_changed;
    wire [23:0] p_addr_w;
    wire [15:0] p_off_w;
    wire         il_ack, il_done, il_ok;      // the line port: unused on this card since rung 5
    wire [127:0] il_row;
    // L1-D's seams to the TLB and the shared direct way read (rung 5).
    wire        lb_hit_w, fj_v_w, fj_fold_w, fj_ack_w;
    wire [7:0]  lb_vpage_w, fj_vpage_w;
    wire [15:0] lb_ppn_w, fj_ppn_w;
    wire [L2_SIDX-1:0] lb_set_w, fj_set_w, dr_set_d, dr_set_i;
    wire [L2_LEV-1:0]  lb_way_w, fj_way_w, dr_way_d, dr_way_i;
    wire [3:0]  fj_reg_w, dr_line_d, dr_line_i;
    wire        dr_req_d, dr_req_i, dr_ack_d, dr_ack_i, dr_done_d, dr_done_i;
    localparam integer L2_SIDX = $clog2(MEM_SETS);
    localparam integer L2_LEV  = $clog2(MEM_WAYS);
    // The TLB's and the direct way read's seams (rung 4).
    wire        la_hit_w, fi_v_w, fi_busy_w, fi_fold_w, kill_v_w;
    wire [7:0]  la_vpage_w, fi_vpage_w;
    wire [15:0] la_ppn_w, fi_ppn_w, kill_ppn_w, op_place_ppn_w;
    wire [L2_SIDX-1:0] la_set_w, fi_set_w, op_place_set_w, evict_set_w, ref_set_w, dr_set_w;
    wire [L2_LEV-1:0]  la_way_w, fi_way_w, op_place_way_w, evict_way_w, ref_way_w, dr_way_w;
    wire [3:0]  fi_reg_w, dr_line_w;
    wire        op_place_v_w, evict_v_w, ref_v_w, ref_on_w, dr_req_w, dr_ack_w, dr_done_w;
    wire [127:0] dr_row_w;
    wire [31:0] tlb_fills_w, tlb_deaths_w;
    wire        cpu_cyc_is_i;
    wire [15:0] cpu_pc_addr;
    wire        app_msg_valid, app_pay_valid;
    wire [7:0]  app_msg_type, app_msg_len;
    wire [15:0] app_msg_free;
    wire [31:0] app_pay_data;
    wire [31:0] aux_word;
    wire        aux_valid, aux_take;

    card_link #(
        // THE REGISTER FILE AT ITS MINIMUM (docs/CORE_REFACTOR_65C02.md rung 2).
        .MINIMAL_REGS (1'b1),
        .MEM_PAGES_LOG2 ($clog2(MEM_SETS * MEM_WAYS)),
        .BUILD_DATE (BUILD_DATE),
        .BUILD_TIME (BUILD_TIME),
        .CAN_MASTER (1'b1),
        .GS (GS),
        .CK_PHASE_SHIFT (CK_PHASE_SHIFT),
        .IDCODE (IDCODE)
    ) u_card (
        .clk_pin (clk_pin), .rst_n (rst_n), .led (led),
        .usb_rx (usb_rx), .usb_tx (usb_tx),
        .flash_cs_n (flash_cs_n), .flash_mosi (flash_mosi), .flash_miso (flash_miso),
        .flash_wp_n (flash_wp_n), .flash_hold_n (flash_hold_n),
        .apple_clk (apple_clk), .apple_rst (apple_rst),
        .capture_on (capture_on), .capture_real (capture_real),
        .real_data (real_data_b), .real_valid (real_valid),
        .real_mark (beam_mark_bus), .real_mark_free (beam_mark_free),
        .real_dummy (op_dummy),
        .virt (virt_base),
        .fast_mark (beam_mark_fast), .fast_mark_free (beam_mark_free),
        .fast_quiet (fev_valid && fev_quiet),
        .fast_force (fev_force),
        // The fronts' events share the fast port: turbo_ok excludes fev's
        // clock, and an I and a D retire can never share an edge (one core,
        // one cycle), so no two of the three are ever valid together - the
        // priority here is form, not arbitration.
        .fast_valid (fev_valid || tev_valid || dev_valid),
        .fast_addr (fev_valid ? fev_addr : tev_valid ? tev_addr : dev_addr),
        // THE BANK, which had no wire to travel on until rung 4b (docs/GS.md);
        // since rung 6 the two fronts carry theirs too (zero on a IIe).
        .fast_bank (fev_valid ? fev_bank : tev_valid ? tev_bank : dev_bank),
        .fast_rw (fev_valid ? fev_rw : tev_valid ? 1'b1 : dev_rw),
        .fast_data (fev_valid ? fev_data : tev_valid ? tev_data : dev_data),
        .fast_sync (fev_valid ? fev_sync : tev_valid ? tev_sync : 1'b0),
        .fast_vbl (vbl_level),
        .merge_overflows (merge_overflows),
        .ev_fast_room (ev_fast_room),
        .ev_fast_room_w (ev_fast_room_w),
        .phi0_live (phi0_live),
        .apple_res_sync (apple_res_sync),
        .cpu_source_active (cpu_source_active),
        .mb_slot_active (mb_slot_active),
        .mb_phasor_active (mb_phasor_active),
        .boot_arm (boot_arm), .boot_release (boot_release),
        .boot_held (boot_held), .hold_runtime (hold_runtime),
        .menu_en (menu_en), .menu_hotkey (menu_hotkey),
        .menu_trigger (menu_trigger),
        .hd_slot_active (hd_slot_active),
        .hd_rom_loaded (hd_rom_loaded), .hd_busy (hd_busy),
        .hd_execs (hd_execs),
        .fd_slot_active (fd_slot_active),
        .fd_rom_loaded (fd_rom_loaded), .fd_seeks (fd_seeks),
        .fd_inserted (fd_inserted), .fd_wp (fd_wp),
        .fd_nibbles (fd_nibbles), .fd_tracks (fd_tracks), .fd_flush (fd_flush),
        .fd_stale (fd_stale), .fd_dirty (fd_dirty), .fd_phase (fd_phase),
        .fd_ctl ({fd_q7, fd_q6, fd_drive_sel, fd_motor}),
        .fd_late (fd_late), .fd_fill_max (fd_fill_max),
        .fd_late_clr (fd_late_clr), .fd_fill_clr (fd_fill_clr),
        .fd35_inserted (fd35_inserted), .fd35_wp (fd35_wp),
        .fd35_stale (fd35_stale), .fd35_track (fd35_track), .fd35_side (fd35_side),
        .fd35_motor35 (fd35_motor35), .fd35_motor (fd35_motor), .fd35_ctl (fd35_ctl),
        .fd35_seeks (fd35_seeks), .fd35_late (fd35_late), .fd35_fill_max (fd35_fill_max),
        .fd35_wstat (fd35_wstat),
        .fd35_late_clr (fd35_late_clr), .fd35_fill_clr (fd35_fill_clr),
        .vidhd_slot_active (vidhd_slot_active),
        .vidhd_rom_loaded (vidhd_rom_loaded),
        .mouse_slot_active (mouse_slot_active),
        .mouse_rom_loaded (mouse_rom_loaded),
        .mouse_irq (mouse_irq), .mouse_mode (mouse_mode), .mouse_buttons (mouse_buttons),
        .mouse_moves (mouse_moves), .mouse_x (mouse_x), .mouse_y (mouse_y),
        .u2_slot_active (u2_slot_active), .u2_sock_open (u2_sock_open),
        .u2_cmd_dropped (u2_cmd_dropped), .u2_cmds (u2_cmds), .u2_rx_chunks (u2_rx_chunks),
        .u2_s0_rsr (u2_s0_rsr), .u2_s0_fsr (u2_s0_fsr),
        .printer_slot_active (printer_slot_active), .printer_rom_loaded (printer_rom_loaded),
        .printer_writes (printer_writes),
        .nsc_enable (nsc_enable), .nsc_time_loaded (nsc_time_loaded),
        .nsc_ring_en (nsc_ring_en), .nsc_wr_en (nsc_wr_en),
        .nsc_cmp_idx (nsc_cmp_idx), .nsc_ring_idx (nsc_ring_idx),
        .nsc_unlocks (nsc_unlocks), .nsc_now (nsc_now),
        .kbd_press (kbd_press), .kbd_press_key (kbd_press_key),
        .kbd_drop (kbd_drop), .kbd_lock (kbd_lock),
        .kbd_flags ({kbd_touched, kbd_seen, kbd_strobe}),
        .kbd_counts ({kbd_replaced, kbd_flushed, kbd_taken, kbd_pressed}),
        .kbd_resolved_key (kbd_resolved_key), .kbd_changed (kbd_changed),
        .pb_override (pb_override), .pb_hw (pb_hw),
        .vbl_start (vbl_start), .vbl_probe (vbl_probe), .vbl_notify (vbl_notify),
        .vbl_probe_addr (vbl_probe_addr),
        .vbl_state (vbl_state), .vbl_locked (vbl_locked), .vbl_pal (vbl_pal),
        .vbl_busy (vbl_busy), .vbl_err (vbl_err),
        .vbl_stat (vbl_stat), .vbl_pos (vbl_pos),
        .mem_op_present (op_present),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_sel (16'hFFFF), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .mem_image_ready (mem_image_ready),
        .mem_serve (mem_serve), .mem_cnt_clr (mem_cnt_clr), .mem_inval (mem_inval),
        .mem_sw (mem_sw), .mem_rw_bank (mem_rw_bank), .mem_invalidating (mem_invalidating),
        .mem_rom_loaded (mem_rom_loaded),
        .mem_late_fills (mem_late_fills),
        .mem_fills      (mem_fills),
        .mem_flushes    (mem_flushes),
        .mem_declines   (mem_declines),
        .mem_rom_busy   (rom_busy),
        .mem_rom_sum    (rom_sum),
        .mem_rom_over   (rom_overruns), .mem_shd_drops (mem_shd_drops),
        .mem_rom_xland  (rom_xlanded),
        .panel_dmas     (hd_panel_dmas), .panel_drops (hd_panel_drops),
        .gs_adb_stat    (gsio_adb_stat),
        .gs_clock_stat  (gs_clk_stat),
        .cnt_core_cyc   (cnt_core_cyc), .cnt_bus_cyc (cnt_bus_cyc),
        .mem_fifo_drops (mem_fifo_drops),
        .mem_hits (mem_hits), .mem_misses (mem_misses), .mem_mismatch (mem_mismatch),
        .mem_served (mem_served), .mem_last (mem_last), .mem_diverted (mem_diverted),
        .mem_intc8rom (mem_intc8rom),
        .accel_mode (accel_mode), .accel_target (accel_target),
        .accel_swint_dis (accel_swint_dis),
        .accel_game_dis (accel_game_dis),
        .accel_l1_dis (accel_l1_dis),
        .dbg_sel (dbg_sel), .dbg_val (dbg_val), .snap_hold (tm_snap_hold),
        .game_pb (game_pb), .game_pb_ok (game_pb_ok), .game_pdl_ok (game_pdl_ok),
        .game_pdl0 (game_pdl0), .game_pdl1 (game_pdl1), .game_pdl2 (game_pdl2), .game_pdl3 (game_pdl3),
        .game_meas (game_meas),
        .accel_cnt_clr (accel_cnt_clr),
        .accel_on (accel_on),
        .accel_stat ({7'd0, accel_reset_seq, accel_retries, merge_overflows, seq_state, bus_owns, 1'b0, accel_held, accel_on}),
        .accel_fast (accel_fast), .accel_bus (accel_bus),
        .accel_cycles (accel_cycles), .accel_wait (accel_wait),
        .accel_turbo (accel_turbo),
        .accel_dline (accel_dline),
        .accel_maps (accel_maps),
        .accel_ddrop (accel_ddrop),
        .accel_drevive (accel_drevive),
        .accel_idrop (accel_idrop),
        .accel_irevive (accel_irevive),
        .accel_cen_v (accel_cen_v), .accel_cen_sel (accel_cen_sel),
        .fb_serve (fb_serve), .fb_cnt_clr (fb_cnt_clr), .fb_peek_addr (fb_peek_addr),
        .fb_mode (fb_mode), .fb_compared (fb_compared), .fb_mismatch (fb_mismatch),
        .fb_last (fb_last), .fb_last2 (fb_last2), .fb_other (fb_other),
        .fb_peek_data (fb_peek_data),
        .res_drive (res_drive),
        .app_msg_valid (app_msg_valid), .app_msg_type (app_msg_type),
        .app_msg_free (app_msg_free), .app_msg_len (app_msg_len),
        .app_pay_data (app_pay_data), .app_pay_valid (app_pay_valid),
        .aux_word (aux_word), .aux_valid (aux_valid), .aux_take (aux_take),
        .rl_word (rl_word), .rl_valid (rl_valid), .rl_take (rl_take),
        .start_hold_pending (start_hold_pending),
        .fd_word (fd_word), .fd_valid (fd_valid), .fd_take (fd_take),
        .fd35_word (fd35_word), .fd35_valid (fd35_valid), .fd35_take (fd35_take),
        .u2_word (u2_word), .u2_valid (u2_valid), .u2_take (u2_take),
        .au_word (au_word), .au_valid (au_valid), .au_take (au_take),
        .audio_on (audio_on), .audio_realtime (audio_realtime),
        .audio_rate (audio_rate), .audio_stat (audio_stat),
        .ft_clk (ft_clk), .ft_rxf (ft_rxf), .ft_txe (ft_txe),
        .ft_rd (ft_rd), .ft_wr (ft_wr), .ft_oe (ft_oe),
        .ft_wakeup (ft_wakeup), .ft_reset (ft_reset),
        .ft_data (ft_data), .ft_be (ft_be),
        .ddr3_addr (ddr3_addr), .ddr3_ba (ddr3_ba),
        .ddr3_ras_n (ddr3_ras_n), .ddr3_cas_n (ddr3_cas_n), .ddr3_we_n (ddr3_we_n),
        .ddr3_reset_n (ddr3_reset_n), .ddr3_ck_p (ddr3_ck_p), .ddr3_ck_n (ddr3_ck_n),
        .ddr3_cke (ddr3_cke), .ddr3_cs_n (ddr3_cs_n), .ddr3_dm (ddr3_dm),
        .ddr3_odt (ddr3_odt), .ddr3_dq (ddr3_dq),
        .ddr3_dqs_p (ddr3_dqs_p), .ddr3_dqs_n (ddr3_dqs_n)
    );

    // ---- watching, exactly as the snooper does ------------------------------
    apple_bus_read u_apple (
        .clk               (apple_clk),
        .rst               (apple_rst),
        .enable            (capture_on && capture_real),
        .apple_data_pin    (apple_data_pin),
        .apple_addr_pin    (apple_addr_pin),
        .apple_rw_pin      (apple_rw_pin),
        .apple_phi0_pin    (apple_phi0_pin),
        .apple_m2sel_pin   (apple_m2sel_pin),
        .apple_m2b0_pin    (apple_m2b0_pin),
        .apple_inh_pin     (apple_inh_pin),
        .apple_res_pin     (apple_res_pin),
        .apple_irq_pin     (apple_irq_pin),
        .apple_rdy_pin     (apple_rdy_pin),
        .apple_dma_pin     (apple_dma_pin),
        .ev_data           (real_data),
        .ev_valid          (real_valid),
        .data_tick         (bus_tick),
        .sync_override     (drv_sync),
        .sync_override_en  (cpu_source_active),
        .data_override     (sub_data),
        .data_override_en  (sub_en),
        .rw_override_en    (op_divert),
        .wdata_override    (op_wdata),
        .vbl_level         (vbl_level),
        .res_sync          (apple_res_sync),
        .irq_sync          (apple_irq_sync),
        .phi0_sync         (apple_phi0_sync),
        .data_sync         (apple_data_sync),
        .phi0_active       (phi0_live)
    );

    // DECLARED ABOVE EVERY GENERATE BLOCK THAT NAMES THEM, AND THE REASON IS
    // A HARDWARE FAULT (docs/GS.md rung 6).  The fronts are instantiated
    // inside `generate ... begin : g_l1`, and these wires used to be
    // declared below it.  Verilator resolves a forward reference to the
    // module-level wire; Vivado creates an IMPLICIT, UNDRIVEN net in the
    // generate scope (`Synth 8-3848: Net g_l1.p_fs_w ... does not have
    // driver`, seventeen of them), so on the card both fronts saw a
    // never-servable map, all-zero physical identities and a line-row
    // completion that could never arrive - and every posted write landed
    // in physical page zero.  The IIe build had carried the same warnings
    // since the generate wrapper of 2026-09-08.  Nothing below a generate
    // block may be named inside it.
    wire        cl_valid, cl_rw, cl_wr_image, cl_aux;
    wire [1:0]  cl_cls;
    wire [7:0]  cl_bank;
    wire [15:0] cl_off, pf_off;

    // The MMU shadow follows the unified stream - every op, fast or bus or
    // override - and answers two questions of the address about to be
    // presented: the driver's (divert this write?) and the sequencer's (what
    // class is this op?).
    // The physical space the memory rethink is built on (docs/PAGE_CACHE.md):
    // the classified op's page and its preview, both fronts' physical
    // identities, the packed read table and the settle window.  Nothing
    // consumes them yet - the fronts and the page cache take them in the
    // rungs that follow - but they are wired so the ports are real.
    wire [15:0] cl_ppn_w, pf_ppn_w, p_ppn_w, d_ppn_w;
    wire [3:0]  p_reg_w, d_reg_w;
    wire        p_fold_w, p_fs_w, d_fold_w, d_sh_w, map_settling;
    wire [103:0] rt_rd_flat;
    wire [7:0]  rwb_p1_w;

    // The map's shadow duplicate, as its own entrant into the cache
    // (docs/GS.md rung 3e).
    wire        shd_take_w;
    wire [15:0] shd_ppn_w;
    wire [7:0]  shd_off_w;

    // ---- the soft CPU -------------------------------------------------------
    // Held in reset while the machine is, so it starts where the machine does.
    //
    // AND ON A IIgs, UNTIL ITS ROM HAS LANDED (the user, 2026-09-15).  Out of
    // any card-level reset - power-on, a bitstream load, the link's reset or
    // its watchdog - the loader's `seen` is clear, and whatever DDR3 holds is
    // not known to be a ROM: the 65816 stays in reset until the host has
    // pushed all 512 chunks and every one has drained, then starts at its
    // reset vector.  A push over a ROM already landed (every swhost start)
    // never clears `seen`, so a running machine is not held or reset by it;
    // an Apple RES' does not reset the FPGA and is not affected.  Registered:
    // `rom_ok` is a 512-input AND and cpu_rst fans out across the board.
    // Constant zero at GS = 0.
    logic gs_rom_hold;
    always_ff @(posedge apple_clk) gs_rom_hold <= GS && (apple_rst || !mem_rom_loaded);
    wire cpu_rst = apple_rst || !apple_res_sync || gs_rom_hold;

    // WHAT THE REST OF THE BOARD SEES.  Not the core's pins: the EFFECTIVE op
    // it is presenting.  At GS = 0 the two are the same thing and every wire
    // below is the 65C02's, unchanged.  At GS = 1 they are not - see the
    // parking note in the 65816 arm - and everything downstream takes these.
    wire [15:0] cpu_addr;
    // The core's bank.  A 65C02 has none: the IIe's unified stream is bank
    // zero, which is what a 24-bit map is asked when a IIe asks it
    // (docs/GS.md rung 3).
    // ...and `cpu_bank_raw` is the core's own, before the IIgs's vector-pull
    // redirect below turns it into `cpu_bank`.
    wire [7:0]  cpu_bank, cpu_bank_raw;
    wire        core_vpb;
    wire        cpu_rw;
    wire [7:0]  cpu_dout, cpu_din, cpu_p_flags;
    wire        cpu_cyc_en, cpu_sync;
    // The 65816's "this cycle touches nothing" (VDA and VPA both low), and
    // zero on a 65C02, which has no such cycle.  The dispatcher skips it.
    wire        cyc_internal;

    // The Mockingboard's IRQ takes the short route into the core, the same
    // route drv_sync takes out of it: a real card would pull the slot's IRQ'
    // line and this card's CPU is on the near side of that pin, so the VIA
    // interrupts are folded in here instead - and the mouse card's with it.
    // Physical cards still interrupt through the pin, via apple_irq_sync,
    // exactly as before.
    wire mb_irq;
    // The IIgs chipset's one interrupt line (rtl/gs_intc.sv inside gs_io),
    // zero on the IIe build.
    wire gsio_irq;
    wire [31:0] gsio_adb_stat;     // GS_ADB_STAT, zero on a IIe
    // THE FRONTS BYPASSED (ACCEL_CTRL[29], IIgs only): the core takes the
    // dispatcher's byte on both streams and the dispatcher keeps turbo_en
    // low, so the machine runs exactly as it did before rung 6 - the A/B
    // for a fault the benches do not show (docs/GS.md rung 6).
    wire l1_bypass = GS && accel_l1_dis;

    generate if (!GS) begin : g_65c02

    assign cpu_bank_raw = 8'd0;
    assign cyc_internal = 1'b0;
    assign core_vpb     = 1'b0;

    cpu65c02 u_cpu (
        .clk    (apple_clk),
        .rst    (cpu_rst),
        .cyc_en (cpu_cyc_en),
        .addr   (cpu_addr),
        .rw     (cpu_rw),
        .dout   (cpu_dout),
        .i_din  (i_din_w),          // the instruction front's byte
        .d_din  (d_din_w),          // the data front's, or the sequencer's through it
        .cyc_is_i (cpu_cyc_is_i),
        .i_addr (),
        .i_pred (),                 // L1-I predicts for itself (rtl/a2/l1i.sv)
        .pc_addr (cpu_pc_addr),
        .d_addr (),
        .d_rw   (),
        .d_dout (),
        .d_pred (cpu_d_pred[15:0]), // L1-D's candidate (rtl/a2/l1d.sv)
        .d_pred_v (cpu_d_pred_v),
        .d_pred_rw (cpu_d_pred_rw),
        .p_flags (cpu_p_flags),     // the front resolves branches on them
        .irq_n  (apple_irq_sync && !mb_irq && !mouse_irq),
        .nmi_n  (1'b1),             // the slot brings out no NMI
        .sync   (cpu_sync),
        .halted ()                  // STP is not on the base part; see the RTL
    );
    // A 65C02 lives in bank zero: no bank class, no bank registers, no hold.
    assign cpu_d_pred[23:16] = 8'd0;
    assign cpu_d_pred_bcls   = 2'd0;
    assign cpu_pc_bank       = 8'd0;
    assign cpu_dbr           = 8'd0;
    assign cpu_bank_wr       = 1'b0;

    end endgenerate

    // THE BANK HOLD (docs/GS.md rung 6).  DBR and PBR are part of the map, so
    // a write to either is a map change - but map_changed rises one clock
    // after the write, and on the clock between, the next fetch is already
    // at the new PBR while every front's valid bit still describes the old
    // one.  The core's registered bank_wr covers exactly that clock; OR'd
    // into the settle every consumer already honours, nothing else changes.
    // Zero at GS = 0.
    wire l1_settling = map_settling || cpu_bank_wr;

    // ---- driving ------------------------------------------------------------
    wire [15:0] addr_drive;
    wire        rw_drive;
    wire [7:0]  data_drive;
    wire        addr_rw_oe, data_oe, dma_assert, drv_sync;

    wire [15:0] op_addr;
    wire        op_rw;
    wire [7:0]  op_wdata;
    wire        op_present, op_commit, op_ovr;
    wire        mb_rd_claim, hd_rd_claim, fd_rd_claim, vidhd_rd_claim, mouse_rd_claim, u2_rd_claim, prn_rd_claim;
    wire [7:0]  mb_rd_data, hd_rd_data, fd_rd_data, vidhd_rd_data, mouse_rd_data, u2_rd_data, prn_rd_data;
    wire        boot_ovr_en, hd_ovr_en, hd_ovr_rw, vbl_ovr_en, vbl_ovr_rw;
    wire [15:0] boot_ovr_addr, hd_ovr_addr, vbl_ovr_addr;
    // The override's BANK.  Only the hard disk has one - a IIgs SmartPort
    // call may put its buffer anywhere in the 16 MB space - and it is zero
    // for every call the //e's ROM can make, so the IIe build's overrides
    // are bank zero exactly as they always were.
    wire [7:0]  hd_ovr_bank;
    wire [7:0]  hd_ovr_wdata, vbl_ovr_wdata;

    // Three overrides into one driver: the hold's is always a read of its
    // keyboard address, the disk's and the VBL lock's may be writes.  THE
    // DISK'S COMES FIRST: a runtime hold can have a transfer outstanding,
    // and a transfer that waited behind a menu would time out on the card
    // and the host alike.  THE VBL LOCK'S NEXT: it runs during the boot
    // hold and must take the cycles the hold would otherwise spend on
    // keyboard reads; the disk is reset with the core at the vector, so the
    // two never meet.  Each acts only on cycles it recognises as its own,
    // so a cycle another takes costs it nothing - the core moves for none
    // of them.  Four peripherals into one claim: they answer for different
    // slots (wb_regfile refuses to latch the same one for any two), so at
    // most one claims any cycle.  The floppy and the VidHD have no override
    // at all: neither ever takes a cycle from the machine, by rule
    // (rtl/floppy_card.sv, rtl/vidhd_card.sv).
    // A write to a RamWorks bank the machine does not have goes out as a
    // read (apple_bus_write.sv): apple_mmu is asked about the address the
    // driver is about to present, and the answer counts only while the card
    // is serving - with serving off the core reads the machine's memory.
    wire        mmu_q_divert, op_divert;
    wire [15:0] nxt_addr;

    // THE VBL LOCK TAKES NO CYCLE ON THE IIgs.  It finds the IIe's beam by
    // writing a picture into the motherboard's text page and reading the
    // floating bus back; a IIgs's video is on the card, so there is nothing
    // to find and the cycles would be spent on the wrong machine's memory.
    // vbeam free-runs instead (`virt` above).
    wire        vbl_ovr_gs = vbl_ovr_en && !GS;
    wire        ovr_en    = boot_ovr_en | hd_ovr_en | vbl_ovr_gs;
    // The DRIVER's override enable waits out an on-card slot op's window
    // (accel_seq sl_win, declared below): the peripherals see the unified
    // op for that window and nothing of the driver's, so no override may
    // be presented in it - the hard disk's DMA starts a few clocks later
    // instead (docs/CXXX.md, "The on-card slots").  The dispatcher takes
    // the ungated level and holds as soon as it sees it.
    wire        sl_win;
    wire        drv_ovr_en = ovr_en && !sl_win;
    wire [15:0] ovr_addr  = hd_ovr_en ? hd_ovr_addr  : vbl_ovr_gs ? vbl_ovr_addr  : boot_ovr_addr;
    // boot_hold and the vapor lock are bank zero's by construction.
    wire [7:0]  ovr_bank  = (GS && hd_ovr_en) ? hd_ovr_bank : 8'd0;
    wire        ovr_rw    = hd_ovr_en ? hd_ovr_rw    : vbl_ovr_gs ? vbl_ovr_rw    : 1'b1;
    wire [7:0]  ovr_wdata = hd_ovr_en ? hd_ovr_wdata : vbl_ovr_wdata;
    wire        slot_rd_claim = mb_rd_claim | hd_rd_claim | fd_rd_claim | vidhd_rd_claim | mouse_rd_claim | u2_rd_claim | prn_rd_claim;
    wire [7:0]  slot_rd_data  = hd_rd_claim    ? hd_rd_data    :
                                fd_rd_claim    ? fd_rd_data    :
                                vidhd_rd_claim ? vidhd_rd_data :
                                mouse_rd_claim ? mouse_rd_data :
                                u2_rd_claim    ? u2_rd_data    :
                                prn_rd_claim   ? prn_rd_data   : mb_rd_data;

    // ---- the keyboard in the dummies (docs/ACCELERATION.md) ------------------
    // The closed regime: mode 2, serving, the chicken bit clear - and the
    // core NOT held: while a hold reads the keyboard for the host, the
    // dummies park at $0000 so no edge-kept dummy can look like a keypress
    // to the host's menus.  The driver's dummies then read $C000, every one
    // a sample into kbd_inject's latch; the sequencer serves the program's
    // $C00x reads from it (accel_seq swi_*), and int_rd applies the read's
    // bookkeeping once, at the retirement.
    // OFF ON THE IIgs BUILD (docs/GS.md rung 4).  The IIe's internalization is
    // its own $Cxxx apparatus - the keyboard latch, the status shadow, the
    // floating-bus simulator, the on-card slots - and a IIgs has none of it:
    // rtl/gs_io.sv answers the chipset's registers instead, and every other
    // $C0xx address is BUS class and rides a real cycle, which is what "Your
    // Card" means on this machine.  With it low, q_slot never fires and the
    // peripherals see the driver's op stream, as they did before docs/CXXX.md.
    wire sw_int = !GS && accel_on && (accel_mode == 2'd2) && mem_serve &&
                  !accel_swint_dis && !boot_held;
    // ...and the game port in the same dummies (rtl/game_port.sv; docs/
    // CXXX.md "The game port"): the loop that visits the buttons and the
    // paddles between the keyboard's samples, its own chicken bit on top.
    wire sw_game = sw_int && !accel_game_dis;
    // ...and, AT GS = 1, THE SAME DUMMIES CARRY THE IIe's OWN KEYBOARD
    // (rtl/gs_kbd_a2.sv, docs/GS.md).  The two builds park on $C000 for
    // opposite reasons.  On the IIe it is a SHORTCUT: the program's $C00x
    // read would have reached the IOU anyway, and the sample lets the card
    // answer it without the cycle.  On the IIgs it is the ONLY PATH: gs_io
    // claims $C000 and $C010 for the ADB micro, so the machine never asks the
    // IOU anything, and without this walk the keyboard the user is typing on
    // is not connected to the machine at all.  The chicken bit is the same
    // one - ACCEL_CTRL[28], `swint` on the host - which on this build means
    // "no real keyboard, dummies at $0000"; and the hold is excluded for the
    // same reason it is above.
    wire        gs_kbd_en = GS && !accel_swint_dis && !boot_held;
    wire [15:0] gs_park_addr;
    wire        park_kbd_sel  = GS ? gs_kbd_en : sw_int;
    wire [15:0] park_addr_sel = GS ? gs_park_addr : game_park_addr;
    // ...and the rest of the internalized ops (docs/CXXX.md, "The switch
    // reads in the closed regime", "The switch writes"): apple_mmu asks
    // q_swi of the live address; for a read the serve byte comes from
    // whichever authority owns the registered op's address - the keyboard
    // latch ($C00x), the status shadow ($C01x, $C019's bit from the lock),
    // or the floating-bus simulator ($C05x, $C08x); a write wants no byte,
    // its whole effect is the shadow's at the synthetic commit.
    wire        swi_commit, kbd_int_ok, fb_int_ok, fb_vbl_bar;
    wire        q_swi_mmu, q_swi_quiet;
    // The four registers apple_mmu owns at GS = 1 and gs_io shows, the VGC's
    // border colour, the battery RAM's landed flag, and the host's seconds.
    wire [7:0]  gs_shadow_w, gs_cyareg_w, gs_sltrom_w, gs_state_w;
    wire [3:0]  gs_border;
    wire        gs_bram_ok;
    // The clock chip's battery RAM and state, for the debug pair and
    // GS_CLOCK_STAT (rtl/gs_clock.sv).
    wire [31:0] gs_clk_dbg_word, gs_clk_stat;

    // ---- A VECTOR PULL COMES FROM THE ROM (docs/GS.md rung 4b part 8) -------
    // The 65816 forces PBR to zero for every vector fetch - rtl/cpu65816.sv
    // says so where it does it, and that is the PART's behaviour, correctly.
    // A IIgs is not a bare 65816: its FPI watches the VP' pin and takes the
    // vector from BANK $FF, the ROM, so that the machine's handlers survive
    // whatever the language card is currently showing at $00/$FFxx.  KEGS is
    // explicit about it - every vector in its instable.h is written as a full
    // 24-bit $FF/FFxx address and moremem_fix_vector_pull() masks it back
    // down to bank $00 ONLY when SHADOW[6] is set, the bit that makes
    // $C000-$FFFF in banks $00/$01 plain RAM with no I/O and no language card
    // (rtl/apple_mmu.sv, gs_flat).  So the default is the ROM and the RAM is
    // the exception, which is the opposite way round from the bare part.
    //
    // WITHOUT THIS THE MACHINE DIES ON ITS FIRST INTERRUPT once anything puts
    // the language card in RAM-read mode.  GS/OS does, early: the boot bench
    // has it at "bank1, RAM read, write enabled" by the time the SmartPort is
    // loading, so $00/$FFFE read $00 $00, the IRQ vectored to $00/0000, and
    // the machine spent the rest of the run executing zero page - ORA / SBC /
    // ADC / BRK round and round, the BRK returning through the same dead
    // vector.  It looked like a halt from the outside.
    //
    // Redirected HERE, at the one place the bank is formed, rather than
    // inside the map: the cache, the event stream and the host's mirror all
    // read the bank from this wire, and a redirect they could not see would
    // put the host's model of memory at odds with the card's.
    assign cpu_bank = (GS && core_vpb && !gs_shadow_w[6]) ? 8'hFF : cpu_bank_raw;
    // What the clock believes before the host's first GS_TIME lands: seconds
    // since 1904-01-01 for 2026-01-01 00:00:00.  The host sends the real
    // seconds before RES' is released, as it sends the battery RAM, so this
    // is only ever what a card with no host on it would show.
    wire [31:0] gs_seed_time = 32'd3849940800;
    wire [7:0]  kbd_int_byte, mmu_swi_stat;
    // THE CHIPSET'S FACE joins the dispatcher's internalized-op question
    // (rtl/gs_io.sv, "the two faces of an op"): `claim` off the LIVE address
    // the dispatcher is deciding on, `u_claim` off the REGISTERED op for the
    // byte mux.  apple_mmu's own swi is off at GS = 1, so the two never both
    // claim.  Both are zero at GS = 0 and the OR folds away.
    wire        gsio_claim, gsio_u_claim;
    wire [7:0]  gsio_byte;
    // The keyboard read at one clock on the data front (rtl/dline.sv
    // kb_hit): the ADB micro's $C000 byte, registered once here on its way
    // across the die, and the front's retire pulse back to the micro.
    // Declared above every generate block (tools/check_generate_scope.py).
    wire [7:0]  gs_c000_byte;
    // ...and the chipset's fast reads the same way (docs/LONG_DATA.md rung 3):
    // rtl/gs_io.sv's fr_vec, registered once on its way to the data front,
    // and the status page's switches it is composed from.
    wire [15:0]  mmu_stat_bits;
    wire [247:0] gsio_fr_vec;
    // The Ensoniq's mix, out of gs_io and into the audio sampler; zero on the
    // IIe build, where the DOC is not instantiated (docs/GS.md rung 7).
    wire signed [20:0] doc_l, doc_r;
    wire        q_swi = q_swi_mmu || gsio_claim;
    wire [6:0]  kbd_int_low;
    // ...and the card's own slots (docs/CXXX.md, "The on-card slots"): a
    // slot op's byte is the peripheral's registered answer, keyed FIRST -
    // a slot ROM page's low nibble would otherwise read as the keyboard's.
    wire        q_slot, seq_slot_q, q_nsc;
    wire [7:0]  swi_byte = GS ? (gsio_u_claim ? gsio_byte : mmu_swi_stat)
                         : seq_slot_q             ? slot_rd_data
                         : (u_addr[7:4] == 4'h0) ? kbd_int_byte
                         : (u_addr[7:4] == 4'h1) ? mmu_swi_stat
                         : (u_addr[7:4] == 4'h6) ? game_int_byte
                         : fb_sub_data;
    // A $C07x access of the core's own - served (the synthetic commit) or
    // a write on the bus - is the paddle strobe for the virtual timers.
    wire        game_strobe = (swi_commit && !seq_slot_q && (u_addr[15:4] == 12'hC07)) ||
                              (op_commit && !op_dummy && !op_ovr && !op_rw && (op_addr[15:4] == 12'hC07));
    // ...and L1-D's own $C000 serve (rung 6): its retire is a read of the
    // latch too, and the latch's byte crosses the die through one register.
    wire        dl_kbd_rd;
    logic [7:0] kbd_byte_q;
    always_ff @(posedge apple_clk) kbd_byte_q <= kbd_int_byte;
    wire        kbd_int_rd = (swi_commit && u_rw && !seq_slot_q && (u_addr[15:4] == 12'hC00)) || dl_kbd_rd;

    // THE PERIPHERALS' VIEW OF THE OP STREAM.  The hard disk, the floppy and
    // the Mockingboard decode the driver's op (op_*) as they always did; in
    // the closed regime an access to one of them is a fast op the driver
    // never sees, so for its window - dispatch through synthetic commit
    // (accel_seq sl_win) - they are shown the unified op instead: present
    // on the dispatch clock, address/rw/data the core's, and the synthetic
    // commit as their commit.  The driver's dummies are hidden for the
    // window (a dummy is nobody's op), and the window's commit is flagged a
    // dummy so the floppy's and the VIAs' core clocks do not tick on it -
    // fast_tick ticks them once for the op, as for every fast op.  The
    // peripheral's registered claim then answers the fast op (swi_byte);
    // it must NOT reach the driver, which drives a claimed read's byte onto
    // the bus during its data window - a leftover claim under a dummy's
    // read of $C000 would fight the IOU - so the claim is masked from the
    // dispatch until the driver's next visible present re-registers it.
    wire        sl_present = u_present && seq_slot_q;
    wire        sl_commit  = swi_commit && seq_slot_q;
    wire        p_present  = sl_win ? sl_present : op_present;
    wire        p_commit   = sl_win ? sl_commit  : op_commit;
    wire        p_dummy    = sl_win ? 1'b1       : op_dummy;
    wire        p_ovr      = sl_win ? 1'b0       : op_ovr;
    wire [15:0] p_addr     = sl_win ? u_addr     : op_addr;
    // ...and its bank: the retired op's in the slot window, the override's
    // for a DMA cycle, the core's otherwise - the core is held for the length
    // of its own bus cycle, so its bank is the presented op's.
    wire [7:0]  p_bank     = sl_win ? u_bank : (op_ovr ? ovr_bank : cpu_bank);
    wire        p_rw       = sl_win ? u_rw       : op_rw;
    wire [7:0]  p_wdata    = sl_win ? u_wdata    : op_wdata;
    logic       sl_claim_fast;
    always_ff @(posedge apple_clk) begin
        if (apple_rst)                    sl_claim_fast <= 1'b0;
        else if (sl_present)              sl_claim_fast <= 1'b1;
        else if (op_present && !sl_win)   sl_claim_fast <= 1'b0;
    end
    wire        slot_rd_claim_bus = slot_rd_claim && !sl_claim_fast;

    // The hard disk's EXECUTE and its completion must reach the host
    // through the stream even as fast reads on a sparse capture (the door
    // drops fast reads, rtl/event_merge.sv): the read that was an EXECUTE
    // (hd_card exec_q, registered at its present), and any read of the
    // port that did not answer busy ($80) - the first of those completes
    // the command on the host's side.  The busy polls, the flood, are
    // dropped as every other fast read.
    wire        hd_exec_q;
    wire        fev_hd    = fev_valid && fev_rw && (hd_slot_active != 3'd0) &&
                            (fev_addr[15:4] == {8'hC0, 1'b1, hd_slot_active});
    wire        fev_force = fev_hd && (hd_exec_q || (fev_data != 8'h80));

    apple_bus_write u_write (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .phi0_sync     (apple_phi0_sync),
        .data_sync     (apple_data_sync),
        .master_active (cpu_source_active),
        .park_kbd      (park_kbd_sel),
        .park_addr     (park_addr_sel),
        .bus_owns      (bus_owns),
        .core_valid    (core_valid),
        .cpu_addr      (cpu_addr),
        .cpu_rw        (cpu_rw),
        .cpu_dout      (cpu_dout),
        .cpu_sync      (cpu_sync),
        .cyc_en        (drv_cyc_done),
        .cpu_din       (drv_din),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .op_wdata      (op_wdata),
        .op_present    (op_present),
        .op_commit     (op_commit),
        .slot_rd_claim (slot_rd_claim_bus),
        .slot_rd_data  (slot_rd_data),
        .din_sub_en    (sub_en),
        .din_sub_data  (sub_data),
        .ovr_en        (drv_ovr_en),
        .ovr_addr      (ovr_addr),
        .ovr_rw        (ovr_rw),
        .ovr_wdata     (ovr_wdata),
        .op_ovr        (op_ovr),
        .op_dummy      (op_dummy),
        .op_inflight   (op_inflight),
        .nxt_addr      (nxt_addr),
        .divert        (mem_serve && mmu_q_divert),
        .op_divert     (op_divert),
        .addr_drive    (addr_drive),
        .rw_drive      (rw_drive),
        .data_drive    (data_drive),
        .addr_rw_oe    (addr_rw_oe),
        .data_oe       (data_oe),
        .dma_assert    (dma_assert),
        .drv_sync      (drv_sync),
        .driving       ()
    );

    // ---- the sequencer ------------------------------------------------------
    // The core's ops, decided: served from the card, or handed to the driver
    // for a bus cycle.  See rtl/accel_seq.sv.
    // The byte the core takes is the sequencer's - the bus's, a switch's or
    // the cache's - with the No-Slot Clock's bit on D0 for a read of the
    // clock (rtl/no_slot_clock.sv): one LUT on one bit, behind the clock's
    // registered verdict, whichever path served the rest of the byte.
    wire [7:0]  seq_din;
    // The No-Slot Clock's bit, and never the IIgs's: a IIgs has a clock of
    // its own at $C033/$C034 (rtl/gs_clock.sv) and no reason to look for one
    // hiding behind a slot ROM.
    assign cpu_din = (nsc_sub && !GS) ? {seq_din[7:1], nsc_bit} : seq_din;
    accel_seq u_seq (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .cpu_rst       (cpu_rst),
        .master_active (cpu_source_active),
        .mode          (accel_mode),
        .q_swi         (q_swi),
        .q_swi_quiet   (q_swi_quiet),
        .swi_byte      (swi_byte),
        .swi_commit    (swi_commit),
        .q_slot        (q_slot),
        .slot_q_o      (seq_slot_q),
        .sl_win        (sl_win),
        .fast_tick     (seq_fast_tick),
        .mem_served    (seq_mem_served),
        .fev_quiet     (fev_quiet),
        // THE IIgs's OWN SPEED SWITCH (docs/GS.md; KEGS moremem.c CYAREG).
        // $C036 bit 7 is the machine's high-speed bit and the ROM, the
        // Control Panel and every disk routine drive it: CLEAR means the
        // program believes it is on a 1 MHz Apple II and has timed its loops
        // for one, so the governor must give it exactly one op per bus cycle
        // (16'h0100 is 1.0 in the 8.8 the bucket counts in).  SET means fast,
        // and fast is whatever the host asked for in ACCEL_CTRL.  Running a
        // slow-mode program at the fast target is not "faster", it is wrong -
        // the ROM's self-test measures things.
        // EXCEPT WHEN THE HOST SAYS UNLIMITED (target 0, `accel all 0`):
        // then the slow bit yields too.  Nox on the IIgs sat at 1.1x with the
        // governor "unlimited" because ProDOS 8 clears the bit (2026-09-11);
        // unlimited is the user's explicit "as fast as it goes", and a
        // finite target still honours the machine's own switch.
        .target        (GS && !gs_cyareg_w[7] && (accel_target != 16'd0) ? 16'h0100 : accel_target),
        .cnt_clr       (accel_cnt_clr),
        .l1_dis    (l1_bypass),
        .mem_serve     (mem_serve),
        .mem_image_ready (mem_image_ready),
        .mem_invalidating (mem_invalidating),
        .q_cls         (q_cls),
        .cpu_addr      (cpu_addr),
        .cpu_bank      (cpu_bank),
        .cpu_rw        (cpu_rw),
        .cpu_dout      (cpu_dout),
        .cpu_sync      (cpu_sync),
        .cyc_is_i      (cpu_cyc_is_i),
        .cyc_en        (seq_cyc_en),
        .cpu_din       (seq_din),
        .turbo_en      (turbo_en),
        .turbo_ok      (turbo_ok),
        .turbo_commit  (turbo_commit),
        .d_commit      (d_commit_w),
        .turbo_claim   (turbo_claim | d_claim_w),
        .turbo_wr      (turbo_wr),
        .d_pending     (d_pending_w),
        .stall         (fd_stall || u2_stall || fd35_stall),
        .op_present    (op_present),
        .op_commit     (op_commit),
        .op_dummy      (op_dummy),
        .op_ovr        (op_ovr),
        .op_divert     (op_divert),
        .op_sync       (drv_sync),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .op_wdata      (op_wdata),
        .cyc_done      (drv_cyc_done),
        .drv_din       (drv_din),
        .op_inflight   (op_inflight),
        .ovr_en        (ovr_en),
        .ovr_bank      (ovr_bank),
        .bus_owns      (bus_owns),
        .core_valid    (core_valid),
        .mem_sub_en    (mem_sub_en),
        .mem_sub_data  (mem_sub_data),
        .decided       (mem_decided),
        .busy          (mem_busy),
        .mq_valid      (1'b0),          // the page engine has no request queue: busy covers it
        .bus_tick      (bus_tick),
        .u_present     (u_present),
        .u_commit      (u_commit),
        .u_addr        (u_addr),
        .u_bank        (u_bank),
        .u_rw          (u_rw),
        .u_wdata       (u_wdata),
        .u_sync        (u_sync),
        .u_ovr         (u_ovr),
        .u_divert      (u_divert),
        .fev_valid     (fev_valid),
        .fev_addr      (fev_addr),
        .fev_bank      (fev_bank),
        .fev_rw        (fev_rw),
        .fev_data      (fev_data),
        .fev_sync      (fev_sync),
        .accel_on      (accel_on),
        .held_governor (accel_held),
        .state_o       (seq_state),
        .reset_seq_o   (accel_reset_seq),
        .fast_ops      (accel_fast),
        .map_changed   (map_changed),
        .map_settling  (l1_settling),
        .maps          (accel_maps),
        .cen_v         (accel_cen_v),
        .cen_sel       (accel_cen_sel),
        .turbo_ops     (accel_turbo),
        .bus_ops       (accel_bus),
        .cycles        (accel_cycles),
        .wait_clocks   (accel_wait),
        .retries       (accel_retries)
    );

    // ---- the fronts ---------------------------------------------------------
    // BOTH ARE THE IIe BUILD'S.  On the IIgs the core rides the dispatcher
    // alone (docs/GS.md rung 6 widens them for the 24-bit space and measures
    // it), so at GS = 1 the two are not built and every seam they drive is
    // tied still below - which is also what makes room on the die for the
    // 65816 and the chipset.
    // Both fronts are built on both machines since rung 6; the generate
    // block keeps its name so the depth census's paths keep theirs.
    generate if (1) begin : g_l1

    // ---- L1-I -----------------------------------------------------------------
    // Two line buffers filled by DIRECT WAY READS of the page cache through
    // the TLB (rtl/a2/l1i.sv, rtl/a2/tlb.sv, docs/L1_RETHINK.md): a fetch
    // that lands in them retires in one clock.
    l1i #(.SIDX (L2_SIDX), .LEV (L2_LEV)) u_l1i (
        .clk (apple_clk), .rst (apple_rst), .cpu_rst (cpu_rst),
        .pc_addr (cpu_pc_addr), .cpu_rw (cpu_rw), .cpu_sync (cpu_sync),
        .cyc_is_i (cpu_cyc_is_i), .p_flags (cpu_p_flags),
        .cyc_en (l1i_cyc_en), .i_din (i_din_w),
        .accel_cyc_en (seq_cyc_en), .accel_din (cpu_din),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok), .claim (turbo_claim),
        .turbo_commit (turbo_commit), .turbo_sync (turbo_sync), .tick_q (turbo_tick),
        .tev_valid (tev_valid), .tev_addr (tev_addr), .tev_data (tev_data), .tev_sync (tev_sync),
        .ev_room (ev_fast_room),
        .p_addr (p_addr_w), .p_ppn (p_ppn_w), .p_reg (p_reg_w), .p_fold (p_fold_w), .p_fs (p_fs_w),
        .map_changed (map_changed), .map_settling (l1_settling), .intc8rom (mem_intc8rom),
        .la_vpage (la_vpage_w), .la_hit (la_hit_w), .la_ppn (la_ppn_w), .la_set (la_set_w), .la_way (la_way_w),
        .fi_v (fi_v_w), .fi_vpage (fi_vpage_w), .fi_ppn (fi_ppn_w), .fi_set (fi_set_w), .fi_way (fi_way_w),
        .fi_reg (fi_reg_w), .fi_fold (fi_fold_w), .fi_busy (fi_busy_w),
        .kill_v (kill_v_w), .kill_ppn (kill_ppn_w),
        .dr_req (dr_req_i), .dr_set (dr_set_i), .dr_way (dr_way_i), .dr_line (dr_line_i),
        .dr_ack (dr_ack_i), .dr_done (dr_done_i), .dr_row (dr_row_w),
        .op_place_v (op_place_v_w), .op_place_ppn (op_place_ppn_w),
        .op_place_set (op_place_set_w), .op_place_way (op_place_way_w),
        .evict_v (evict_v_w), .evict_set (evict_set_w), .evict_way (evict_way_w),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_ppn (cl_ppn_w), .cl_off (cl_off),
        .ws_valid (ws_valid_w), .ws_ppn (ws_ppn_w), .ws_off8 (ws_off8_w),
        .serve (mem_serve), .inval (mem_inval),
        .dbg_sel (dbg_sel[3:0]), .dbg_val (il_dbg), .fill_busy (il_fill_busy)
    );
    // The TLB: eight pages, each naming the set and way L2 holds it in.
    tlb #(.SIDX (L2_SIDX), .LEV (L2_LEV), .N (8)) u_tlb (
        .clk (apple_clk), .rst (apple_rst), .serve (mem_serve), .inval (mem_inval),
        .map_changed (map_changed), .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1_w),
        .evict_v (evict_v_w), .evict_set (evict_set_w), .evict_way (evict_way_w),
        .fi_v (fi_v_w), .fi_vpage (fi_vpage_w), .fi_ppn (fi_ppn_w), .fi_set (fi_set_w), .fi_way (fi_way_w),
        .fi_reg (fi_reg_w), .fi_fold (fi_fold_w), .fi_busy (fi_busy_w),
        .la_vpage (la_vpage_w), .la_hit (la_hit_w), .la_ppn (la_ppn_w), .la_set (la_set_w), .la_way (la_way_w),
        .fj_v (fj_v_w), .fj_vpage (fj_vpage_w), .fj_ppn (fj_ppn_w), .fj_set (fj_set_w), .fj_way (fj_way_w),
        .fj_reg (fj_reg_w), .fj_fold (fj_fold_w), .fj_ack (fj_ack_w),
        .lb_vpage (lb_vpage_w), .lb_hit (lb_hit_w), .lb_ppn (lb_ppn_w), .lb_set (lb_set_w), .lb_way (lb_way_w),
        .ref_v (ref_v_w), .ref_set (ref_set_w), .ref_way (ref_way_w), .ref_on (ref_on_w),
        .kill_v (kill_v_w), .kill_ppn (kill_ppn_w),
        .cnt_fills (tlb_fills_w), .cnt_deaths (tlb_deaths_w)
    );
    assign tev_bank      = 8'd0;
    assign dev_bank      = 8'd0;
    // ACCEL_IDROP / ACCEL_IREVIVE carry the TLB's deaths and fills now (rung 4).
    assign accel_idrop   = tlb_deaths_w;
    assign accel_irevive = tlb_fills_w;

    // ---- L1-D -----------------------------------------------------------------
    // The shadow, the last row and the last byte at one clock; every other
    // read a TLB hit serves from the page cache's row at three clocks
    // (rtl/a2/l1d.sv).  Its cyc_en is the core's, its byte is d_din, its
    // books ride the sequencer's d_commit.
    l1d #(.SIDX (L2_SIDX), .LEV (L2_LEV)) u_l1d (
        .clk (apple_clk), .rst (apple_rst), .cpu_rst (cpu_rst),
        .d_pred (cpu_d_pred[15:0]), .d_pred_v (cpu_d_pred_v), .d_pred_rw (cpu_d_pred_rw),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cyc_is_i (cpu_cyc_is_i),
        .il_cyc_en (l1i_cyc_en), .seq_cyc_en (seq_cyc_en), .accel_din (cpu_din), .i_din (i_din_w),
        .cyc_en (cpu_cyc_en), .d_din (d_din_w),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok), .wr_en (turbo_wr),
        .d_commit (d_commit_w), .claim (d_claim_w), .tick_q (dline_tick), .pending (d_pending_w),
        .dev_valid (dev_valid), .dev_addr (dev_addr), .dev_data (dev_data), .dev_rw (dev_rw),
        .ev_room (ev_fast_room), .ev_room_w (ev_fast_room_w),
        .altzp (mem_sw[3]),
        .dq_addr (dq_addr_w), .dq_rw (dq_rw_w), .d_cls (dcls_w),
        .d_ppn (d_ppn_w), .d_reg (d_reg_w), .d_fold (d_fold_w),
        .rw_bank (mem_rw_bank), .map_changed (map_changed), .map_settling (l1_settling),
        .kbd_en (sw_int && kbd_int_ok), .kbd_byte (kbd_byte_q), .swi_busy (swi_commit), .kbd_rd (dl_kbd_rd),
        .lb_vpage (lb_vpage_w), .lb_hit (lb_hit_w), .lb_ppn (lb_ppn_w), .lb_set (lb_set_w), .lb_way (lb_way_w),
        .fj_v (fj_v_w), .fj_vpage (fj_vpage_w), .fj_ppn (fj_ppn_w), .fj_set (fj_set_w), .fj_way (fj_way_w),
        .fj_reg (fj_reg_w), .fj_fold (fj_fold_w), .fj_ack (fj_ack_w),
        .op_take (seq_mem_served), .op_row_v (mem_op_row_v), .op_row (mem_op_row), .op_row_ppn (mem_op_row_ppn),
        .op_place_v (op_place_v_w), .op_place_ppn (op_place_ppn_w),
        .op_place_set (op_place_set_w), .op_place_way (op_place_way_w),
        .dr_req (dr_req_d), .dr_set (dr_set_d), .dr_way (dr_way_d), .dr_line (dr_line_d),
        .dr_ack (dr_ack_d), .dr_done (dr_done_d), .dr_row (dr_row_w),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_posted (cl_posted),
        .cl_ppn (cl_ppn_w), .cl_off (cl_off), .wdata (cl_wdata),
        .pw_valid (pw_valid_w), .pw_ppn (pw_ppn_w), .pw_off (pw_off_w),
        .pw_data (pw_data_w), .pw_take (pw_take_w && pw_valid_w),
        .ws_valid (ws_valid_w), .ws_ppn (ws_ppn_w), .ws_off8 (ws_off8_w),
        .inval (mem_inval),
        .dbg_sel (dbg_sel[3:0]), .dbg_val (dl_dbg), .fill_busy (dl_fill_busy),
        .cnt_clr (accel_cnt_clr), .cnt_serves (accel_dline), .cnt_l2_serves (accel_ddrop), .cnt_tlb_fills (accel_drevive)
    );
    // THE DIRECT WAY READ, SHARED: L1-D first (its read is the live cycle's),
    // L1-I's waits; the source rides a two-deep shift register so each side
    // sees only its own completion two clocks after its ack.
    assign dr_req_w  = dr_req_d | dr_req_i;
    assign dr_set_w  = dr_req_d ? dr_set_d  : dr_set_i;
    assign dr_way_w  = dr_req_d ? dr_way_d  : dr_way_i;
    assign dr_line_w = dr_req_d ? dr_line_d : dr_line_i;
    assign dr_ack_d  = dr_ack_w &&  dr_req_d;
    assign dr_ack_i  = dr_ack_w && !dr_req_d;
    logic [1:0] dr_src_sr;   // 1 = L1-D's
    always_ff @(posedge apple_clk) dr_src_sr <= apple_rst ? 2'd0 : {dr_src_sr[0], dr_req_d};
    assign dr_done_d = dr_done_w &&  dr_src_sr[1];
    assign dr_done_i = dr_done_w && !dr_src_sr[1];

    end endgenerate

    // The debug pair's mux: [5:4] the module, [3:0] the item; [7:6] = 1 is
    // the bank census (below the snapshot words), [7:6] = 2 the data front's
    // bank table (rtl/dline.sv dbg_val2).  Item 3/0 is
    // the dispatcher's and the fronts' live state in one word.
    // ---- WHERE THE CLOCKS GO: a histogram of every clock by what the core
    // was doing (docs/GS.md rung 6, "where the stalls are").  Each clock is
    // charged to exactly one bucket, first match wins, and the sum of the
    // buckets is the clock count itself (the last item), so the arithmetic
    // closes on the card rather than on a page.  The inputs are registered
    // once before the compare and the counters increment a clock later -
    // two flops from any cone, so the census cannot tip a path
    // (fast-op-census lesson, 2026-09-02).
    //
    //   0 RETIRE   a core cycle retired (cpu_cyc_en)
    //   1 HELD     the governor holds the core (accel_held)
    //   2 SETTLE   a map change is settling (l1_settling)
    //   3 IFILL    the instruction front has a line fill in flight
    //   4 DFILL    the data front has a line fill in flight
    //   5 SEQ_FAST the dispatcher is in S_FAST (a fast op deciding)
    //   6 SEQ_BUS  ...in S_BUS or S_HELD (a bus cycle, or an override's)
    //   7 SEQ_NULL ...in S_NULL (an internal cycle's clock)
    //   8 DEC_I    ...in S_DECIDE with an instruction fetch up, unserved
    //   9 DEC_D    ...in S_DECIDE with a data cycle up, unserved
    //  10 OTHER    none of the above (S_RST, the core in reset)
    //  11 CLOCKS   every clock
    logic        h_ret, h_held, h_settle, h_ifill, h_dfill, h_isi;
    logic [3:0]  h_seq;
    always_ff @(posedge apple_clk) begin
        h_ret    <= cpu_cyc_en;
        h_held   <= accel_held;
        h_settle <= l1_settling;
        h_ifill  <= il_fill_busy;
        h_dfill  <= dl_fill_busy;
        h_seq    <= seq_state;
        h_isi    <= cpu_cyc_is_i;
    end
    // accel_seq's state_t: 0 S_RST, 1 S_DECIDE, 2 S_FAST, 3 S_BUS, 4 S_HELD, 5 S_NULL.
    wire [11:0] h_sel_w;
    assign h_sel_w[0]  = h_ret;
    assign h_sel_w[1]  = !h_ret && h_held;
    assign h_sel_w[2]  = !h_ret && !h_held && h_settle;
    assign h_sel_w[3]  = !h_ret && !h_held && !h_settle && h_ifill;
    assign h_sel_w[4]  = !h_ret && !h_held && !h_settle && !h_ifill && h_dfill;
    assign h_sel_w[5]  = !h_ret && !h_held && !h_settle && !h_ifill && !h_dfill && (h_seq == 4'd2);
    assign h_sel_w[6]  = !h_ret && !h_held && !h_settle && !h_ifill && !h_dfill && (h_seq == 4'd3 || h_seq == 4'd4);
    assign h_sel_w[7]  = !h_ret && !h_held && !h_settle && !h_ifill && !h_dfill && (h_seq == 4'd5);
    assign h_sel_w[8]  = !h_ret && !h_held && !h_settle && !h_ifill && !h_dfill && (h_seq == 4'd1) && h_isi;
    assign h_sel_w[9]  = !h_ret && !h_held && !h_settle && !h_ifill && !h_dfill && (h_seq == 4'd1) && !h_isi;
    assign h_sel_w[10] = !h_ret && !h_held && !h_settle && !h_ifill && !h_dfill && !(h_seq inside {4'd1, 4'd2, 4'd3, 4'd4, 4'd5});
    assign h_sel_w[11] = 1'b1;
    logic [11:0] h_sel_q;
    logic [31:0] h_cnt [0:11];
    always_ff @(posedge apple_clk) begin
        h_sel_q <= h_sel_w;
        for (int hi = 0; hi < 12; hi++) begin
            if (apple_rst || accel_cnt_clr) h_cnt[hi] <= 32'd0;
            else if (h_sel_q[hi])           h_cnt[hi] <= h_cnt[hi] + 32'd1;
        end
    end

    // THE SNAPSHOT WORDS ARE REGISTERED BEFORE THE MUX.  Items 2-4 carry the
    // core's live din and its combinational prediction; muxed live into
    // dbg_val_q they were the design's deepest chains (23 levels, 9.9 ns,
    // the WNS of gs_null at +0.171 - a debug read setting the clock).  Two
    // clocks old is what a snapshot wants to be.
    logic [31:0] top_w0_q, top_w1_q, top_w2_q, top_w3_q, top_w4_q;
    // ...and the histogram behind copies of its own, so a sweep under the
    // hold reads twelve buckets of one instant; the mux reads the copies.
    logic [31:0] h_cnt_s [12];
    always_ff @(posedge apple_clk)
        if (!tm_snap_hold) for (int hs = 0; hs < 12; hs++) h_cnt_s[hs] <= h_cnt[hs];
    always_ff @(posedge apple_clk) if (!tm_snap_hold) begin
        top_w0_q <= {seq_state, turbo_en, turbo_ok, turbo_claim, d_claim_w, d_pending_w,
                     cyc_internal, map_settling, cpu_bank_wr, ev_fast_room, ev_fast_room_w,
                     mem_serve, mem_inval, mem_invalidating, cpu_cyc_is_i, cpu_rw, cpu_sync,
                     l1_bypass, accel_held, 2'd0, cpu_bank};
        top_w1_q <= {cpu_pc_bank, cpu_pc_addr, 8'd0};
        top_w2_q <= {cpu_bank, cpu_addr, cpu_dout};
        // The prediction as the data front REGISTERED it, one clock behind
        // the core's live cone: the raw d_pred net carried nineteen loads
        // for this debug word alone, on the design's deepest path
        // (docs/IWM35.md's census, family 2).  A snapshot a clock late is
        // the same snapshot.
        top_w3_q <= {cpu_dbr, dq_addr_w};
        top_w4_q <= {cpu_d_pred_bcls, cpu_d_pred_v, cpu_d_pred_rw, 4'd0, cpu_p_flags, 8'd0, cpu_din};
    end
    // ---- THE BANK CENSUS (docs/LONG_DATA.md rung 0): rtl/bank_census.sv on
    // DBG_SEL[7:6] = 1.  Fed ONLY from the snapshot registers above - h_ret,
    // top_w4_q, top_w3_q - so it adds a load to no live net; declared and
    // instantiated below them (tools/check_generate_scope.py).  The IIgs
    // build only: on the IIe the class is a constant zero.
    wire [31:0] bc_dbg;
    generate if (!GS) begin : g_no_bank_census
        assign bc_dbg = 32'd0;
    end endgenerate

    wire [31:0] top_dbg = (dbg_sel[3:0] == 4'd0) ? top_w0_q :
                          (dbg_sel[3:0] == 4'd1) ? top_w1_q :
                          (dbg_sel[3:0] == 4'd2) ? top_w2_q :
                          (dbg_sel[3:0] == 4'd3) ? top_w3_q :
                          (dbg_sel[3:0] == 4'd4) ? top_w4_q :
                          // 5..14: the clock histogram's buckets 0..9 (RETIRE first);
                          // 15: CLOCKS.  OTHER (bucket 10) is CLOCKS less the rest.
                          (dbg_sel[3:0] == 4'd15)  ? h_cnt_s[11] :
                          (dbg_sel[3:0] >= 4'd5)   ? h_cnt_s[dbg_sel[3:0] - 4'd5] :
                                                   accel_maps;
    // REGISTERED: the top word muxes the core's combinational prediction and
    // din, and unregistered it was the IIe build's binding path into the
    // register file's read mux (r6fix_iie, 22 levels at +0.000).  A debug
    // read is a snapshot; one clock old is what it wants to be.
    logic [31:0] dbg_val_q;
    always_ff @(posedge apple_clk)
        // [7:6] = 3: the IIgs clock chip's battery RAM, item k = bytes
        // 4k..4k+3 (rtl/gs_clock.sv); zero on a IIe.
        dbg_val_q <= (dbg_sel[7:6] == 2'd3) ? gs_clk_dbg_word :
                     (dbg_sel[7:6] == 2'd1) ? bc_dbg :
                     (dbg_sel[7:6] == 2'd2) ? dl_dbg2 :
                     (dbg_sel[5:4] == 2'd0) ? il_dbg :
                     (dbg_sel[5:4] == 2'd1) ? dl_dbg :
                     (dbg_sel[5:4] == 2'd2) ? pc_dbg : top_dbg;
    assign dbg_val = dbg_val_q;

    // ---- the hold: the boot menu's door and the runtime menu's -------------
    // On the unified stream: a SYNC the core fetched from the card must count
    // as a fetch, or an arm given later would hold at a random one.  Its own
    // ops are bus ops and their byte is the driver's.
    boot_hold u_hold (
        .clk           (apple_clk),
        .cpu_rst       (cpu_rst),
        .master_active (cpu_source_active),
        .arm           (boot_arm),
        .release_req   (boot_release),
        .menu_trigger  (menu_trigger),
        .hotkey_hit    (hotkey_hit),
        .cpu_sync      (cpu_sync),
        .turbo_sync    (turbo_sync),
        .op_present    (u_present),
        .op_commit     (u_commit),
        .op_sync       (u_sync),
        .op_ovr        (u_ovr),
        .op_addr       (u_addr),
        .op_rw         (u_rw),
        .din           (drv_din),
        .ovr_en        (boot_ovr_en),
        .ovr_addr      (boot_ovr_addr),
        .held          (boot_held),
        .runtime       (hold_runtime)
    );

    // ---- the VBL lock -------------------------------------------------------
    // The scanner's frame found on the floating bus during the boot hold,
    // and counted from then on.  See rtl/vbl_lock.sv.
    vbl_lock u_vbl (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .master_active (cpu_source_active),
        .held          (boot_held),
        .runtime       (hold_runtime),
        .tick          (bus_tick),
        .op_present    (op_present),
        .op_ovr        (op_ovr),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .din           (drv_din),
        .start         (vbl_start),
        .probe         (vbl_probe),
        .probe_addr    (vbl_probe_addr),
        .notify        (vbl_notify),
        .ovr_en        (vbl_ovr_en),
        .ovr_addr      (vbl_ovr_addr),
        .ovr_rw        (vbl_ovr_rw),
        .ovr_wdata     (vbl_ovr_wdata),
        .mark          (vbl_mark),
        .mark_free     (vbl_mark_free),
        .vbl_level     (lock_vbl_level),
        .scan_v        (lock_scan_v),
        .scan_h        (lock_scan_h),
        .state         (vbl_state),
        .locked        (vbl_locked),
        .pal           (vbl_pal),
        .busy          (vbl_busy),
        .err           (vbl_err),
        .mismatches    (vbl_stat[15:0]),
        .slip          (vbl_stat[31:16]),
        .pos           (vbl_pos[14:0]),
        .frames        (vbl_pos[23:16]),
        .locks         (vbl_pos[31:24])
    );
    assign vbl_pos[15] = 1'b0;

    // ---- keyboard injection -------------------------------------------------
    // The keyboard the core reads: the machine's latch and strobe, with the
    // host's key on it, substituted into the core's din and the capture on a
    // $C00x read.  See rtl/kbd_inject.sv.
    kbd_inject u_kbd (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .cpu_rst       (cpu_rst),
        .master_active (cpu_source_active),
        .park_kbd      (sw_int),
        .op_dummy      (op_dummy),
        .int_ok        (kbd_int_ok),
        .int_rd        (kbd_int_rd),
        .int_byte      (kbd_int_byte),
        .int_low       (kbd_int_low),
        .press         (kbd_press),
        .press_key     (kbd_press_key),
        .drop          (kbd_drop),
        .lock          (kbd_lock),
        .hotkey_en     (menu_en),
        .hotkey        (menu_hotkey),
        .held          (boot_held),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .op_commit     (op_commit),
        .data_sync     (apple_data_sync),
        .sub_en        (kbd_sub_en),
        .sub_data      (kbd_sub_data),
        .strobe        (kbd_strobe),
        .seen          (kbd_seen),
        .touched       (kbd_touched),
        .pressed       (kbd_pressed),
        .taken         (kbd_taken),
        .flushed       (kbd_flushed),
        .replaced      (kbd_replaced),
        .resolved_key  (kbd_resolved_key),
        .changed       (kbd_changed),
        .hotkey_hit    (hotkey_hit)
    );

    // ---- the pushbuttons ----------------------------------------------------
    // Open-Apple, Closed-Apple and PB2 as the host holds them: hardware, up
    // or down, merged into bit 7 of a $C061-$C063 read.  See rtl/pb_inject.sv.
    pb_inject u_pb (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .master_active (cpu_source_active),
        .sel           (pb_override),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .op_commit     (op_commit),
        .op_dummy      (op_dummy),
        .data_sync     (apple_data_sync),
        .sub_en        (pb_sub_en),
        .sub_data      (pb_sub_data),
        .hw_level      (pb_hw)
    );

    // ---- the game port in the dummies ---------------------------------------
    // The buttons and the paddle timers sampled by the driver's idle cycles
    // in turn with the keyboard, and served to the core from the samples -
    // the paddles as virtual timers at the core's pace.  See rtl/game_port.sv.
    game_port u_game (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .master_active (cpu_source_active),
        .park          (sw_game),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .op_commit     (op_commit),
        .op_dummy      (op_dummy),
        .data_sync     (apple_data_sync),
        .bus_tick      (bus_tick),
        .park_addr     (game_park_addr),
        .pb_ok         (game_pb_ok),
        .pdl_ok        (game_pdl_ok),
        .pb_sel        (pb_override),
        .core_tick     (seq_fast_tick || turbo_tick || dline_tick || (bus_tick && !op_dummy && !op_ovr)),
        .strobe        (game_strobe),
        .u_addr        (u_addr),
        .low_bits      (kbd_int_low),
        .int_byte      (game_int_byte),
        .pb_level      (game_pb),
        .pdl0          (game_pdl0),
        .pdl1          (game_pdl1),
        .pdl2          (game_pdl2),
        .pdl3          (game_pdl3),
        .measurements  (game_meas)
    );

    // ---- the memory image ---------------------------------------------------
    // The IIe's memory map shadowed, the ROM on the card, and the machine's
    // memory itself in two 64 KB banks of block RAM, the DDR3 backing only
    // the RamWorks banks that are not resident: every op the driver presents
    // is classified BESIDE the banks' fetch, and a read of RAM or ROM can be
    // answered from here instead of from the bus - through the same din
    // substitution the keyboard uses, so the capture records what the core
    // read.  Nothing on the bus changes.  See docs/PAGE_CACHE.md.
    apple_mmu #(.GS (GS)) u_mmu (
        .clk        (apple_clk),
        .rst        (apple_rst),
        .res_sync   (apple_res_sync),
        .op_bank    (u_bank),
        .op_addr    (u_addr),
        .op_rw      (u_rw),
        .op_wdata   (u_wdata),
        .op_present (u_present),
        .op_commit  (u_commit),
        .rom_ok     (mem_rom_loaded),
        .intc8rom   (mem_intc8rom),
        .cl_valid   (cl_valid),
        .cl_cls     (cl_cls),
        .cl_aux     (cl_aux),
        .cl_bank    (cl_bank),
        .cl_off     (cl_off),
        .cl_rw      (cl_rw),
        .cl_wr_image (cl_wr_image),
        .cl_posted  (cl_posted),
        .cl_wdata   (cl_wdata),
        .shd_drops  (mem_shd_drops),
        .pw_valid   (pw_any_valid),
        .pw_ppn     (pw_any_ppn),
        .pw_off     (pw_any_off),
        .pw_data    (pw_any_data),
        .pw_ready   (pw_ready_w),
        .pw_take    (pw_take_w),
        .shd_take_o (shd_take_w), .shd_ppn_o (shd_ppn_w), .shd_off_o (shd_off_w),
        .pf_off     (pf_off),
        .cl_ppn     (cl_ppn_w),
        .pf_ppn     (pf_ppn_w),
        .sw_state   (mem_sw),
        .vid_sw     (vid_sw),
        .rw_bank    (mem_rw_bank),
        .gs_shadow_o (gs_shadow_w), .gs_cyareg_o (gs_cyareg_w),
        .gs_sltrom_o (gs_sltrom_w), .gs_state_o (gs_state_w),
        // The driver's next address, in the physical space: the bank is the
        // core's, which is zero on this build and the 65816's on the GS
        // (docs/GS.md rung 3).  AN OVERRIDE BRINGS ITS OWN BANK - the hard
        // disk's DMA target, zero for everything else - where it used to be
        // forced to zero because nothing that drove an override had one.
        .q_addr     ({ovr_en ? ovr_bank : cpu_bank, nxt_addr}),
        .q_divert   (mmu_q_divert),
        .q_rw       (cpu_rw),
        .q_cls      (q_cls),
        .swi_on     (sw_int),
        .swi_kbd_ok (kbd_int_ok),
        .swi_fb_ok  (fb_int_ok),
        .swi_vbl_ok (beam_locked),
        .swi_vbl_bar (fb_vbl_bar),
        .swi_kbd_low (kbd_int_low),
        .swi_pb_ok  (sw_game && game_pb_ok),
        .swi_pdl_ok (sw_game && game_pdl_ok),
        .swi_hd_slot (hd_slot_active),
        .swi_fd_slot (fd_slot_active),
        .swi_mb_slot (mb_slot_active),
        .swi_mouse_slot (mouse_slot_active),
        .swi_u2_slot (u2_slot_active),
        .swi_prn_slot (printer_slot_active),
        .q_slot     (q_slot),
        .q_nsc      (q_nsc),
        .q_swi      (q_swi_mmu),
        .q_swi_quiet (q_swi_quiet),
        .swi_stat_byte (mmu_swi_stat),
        .swi_stat_bits (mmu_stat_bits),
        .p_addr     (p_addr_w),
        .p_cls      (p_cls),
        .p_aux      (p_aux_w),
        .p_off      (p_off_w),
        .p_ppn      (p_ppn_w),
        .p_reg      (p_reg_w),
        .p_fold     (p_fold_w),
        .p_fs       (p_fs_w),
        .d_addr     (dq_addr_w),
        .d_rw       (dq_rw_w),
        .d_cls      (dcls_w),
        .d_aux      (daux_w),
        .d_off      (doff_w),
        .d_ppn      (d_ppn_w),
        .d_reg      (d_reg_w),
        .d_fold     (d_fold_w),
        .d_sh       (d_sh_w),
        .map_changed (map_changed),
        .map_settling (map_settling),
        .rt_rd_flat (rt_rd_flat),
        .rwb_p1     (rwb_p1_w),
        .core_dbr   (cpu_dbr),
        .core_pbr   (cpu_pc_bank)
    );

    // ---- the IIgs chipset on $C0xx (docs/GS.md rung 3b, rung 4) -------------
    // The registers a IIgs answers on the card instead of on the backplane:
    // the ADB micro, the map's own four registers, the clock and its battery
    // RAM, the VGC, the interrupt controller, and the IWM and SCC stubs.
    // ONE INSTANCE, TWO CLAIMS - `claim` off the live address the dispatcher
    // is deciding on, `u_claim` off the registered op for the byte mux
    // (rtl/gs_io.sv, "the two faces of an op").  At GS = 0 it is not built
    // and both claims are constant zero.
    generate if (!GS) begin : g_no_gsio
    assign gs_c000_byte = 8'd0;

    assign gsio_claim   = 1'b0;
    assign gsio_u_claim = 1'b0;
    assign gsio_byte    = 8'd0;
    assign gsio_fr_vec  = '0;
    assign gsio_irq     = 1'b0;
    assign gsio_adb_stat = 32'd0;
    assign gs_border    = 4'd0;
    assign gs_bram_ok   = 1'b0;
    assign gs_clk_dbg_word = 32'd0;
    assign gs_clk_stat  = 32'd0;
    assign gs_park_addr = 16'hC000;
    // No Ensoniq on a IIe, so the sampler's DOC box averages silence and its
    // two multipliers fold away.
    assign doc_l        = 21'sd0;
    assign doc_r        = 21'sd0;
    // No IWM on a IIe: the 3.5" drive's source is silent and its readback
    // reads empty.
    assign fd35_word    = 32'd0;
    assign fd35_valid   = 1'b0;
    assign fd35_stale   = 1'b0;
    assign fd35_track   = 7'd0;
    assign fd35_side    = 1'b0;
    assign fd35_motor35 = 1'b0;
    assign fd35_motor   = 1'b0;
    assign fd35_ctl     = 8'd0;
    assign fd35_seeks   = 8'd0;
    assign fd35_late    = 8'd0;
    assign fd35_wstat   = 32'd0;
    assign fd35_fill_max = 16'd0;
    assign fd35_stall   = 1'b0;
    assign gsio_fd525_stale = 2'b11;
    assign gsio_fd525_dirty = 2'b00;
    assign gsio_fd525_phase = 14'd0;

    end endgenerate

    // The system ROM is physical bank $FF now, cached like any other memory,
    // so the host's MEM_ROM message is a producer of PHYSICAL WRITES rather
    // than the filler of a block RAM of its own (rtl/rom_loader.sv).
    // 16 KB of IIe ROM in 32 chunks at physical page $FFC0, or ROM 3's
    // 256 KB in 512 chunks at bank $FC page $00 (docs/GS.md).  The host's
    // chunk count follows the image's size, so one message loads either.
    // THE FORMAL LOAD (docs/CLEAN_START.md CS2): only while the start hold
    // holds the machine, one MEM_ROM_ACK per chunk, and the sum of every first
    // landing for the host to compare.
    rom_loader #(.N_CHUNKS (GS ? 512 : 32),
                 .ROM_PPN0 (GS ? 16'hFC00 : 16'hFFC0),
                 .REQUIRE_HOLD (1'b1),
                 // The card's extended ROM, banks $E2-$EE: a IIgs build only
                 // (docs/GS_CONTROL_PANEL.md R2).  A IIe refuses an absolute
                 // chunk outright - it has no such banks to put one in.
                 .ABS_EN (GS)) u_rom (
        .hold        (start_hold_pending),
        .ack_word    (rl_word),
        .ack_valid   (rl_valid),
        .ack_take    (rl_take),
        .rom_sum     (rom_sum),
        .clk         (apple_clk),
        .rst         (apple_rst),
        .msg_valid   (app_msg_valid),
        .msg_type    (app_msg_type),
        .msg_len     (app_msg_len),
        .pay_data    (app_pay_data),
        .pay_valid   (app_pay_valid),
        .op_present  (u_present),
        .image_ready (mem_image_ready),
        .pw_valid    (rl_pw_valid),
        .pw_ppn      (rl_pw_ppn),
        .pw_off      (rl_pw_off),
        .pw_data     (rl_pw_data),
        .pw_take     (pw_take_w && !pw_valid_w),
        .busy        (rom_busy),
        .overruns    (rom_overruns),
        .xlanded     (rom_xlanded),
        .rom_ok      (mem_rom_loaded)
    );

    // The posted-write seam has two producers: the data front's retired
    // writes, and the ROM load.  The front goes first - it holds the machine
    // up (accel_seq's d_pending) while the loader never does, and the loader
    // only ever runs before the machine does.
    wire        rl_pw_valid;
    wire [15:0] rl_pw_ppn;
    wire [7:0]  rl_pw_off, rl_pw_data;
    wire        rom_busy;
    wire [7:0]  rom_overruns;
    // Absolute chunks drained whole: the extended ROM's own count, which
    // `rom_ok` deliberately says nothing about.
    wire [7:0]  rom_xlanded;
    // The panel's DMA, out of the HD card (docs/GS_CONTROL_PANEL.md R4).
    wire [3:0]  hd_panel_dmas, hd_panel_drops;
    // CS2: the loader's acks to card_link, its sum, and the start hold back.
    wire [31:0] rl_word;
    wire        rl_valid, rl_take;
    wire [31:0] rom_sum;
    wire        start_hold_pending;
    // The shadow duplicate's drops (docs/GS.md rung 3e), read back in
    // MEM_ROM's top byte; zero at GS = 0, where there are no duplicates.
    wire [7:0]  mem_shd_drops;
    wire        pw_any_valid = pw_valid_w || rl_pw_valid;
    wire [15:0] pw_any_ppn   = pw_valid_w ? pw_ppn_w  : rl_pw_ppn;
    wire [7:0]  pw_any_off   = pw_valid_w ? pw_off_w  : rl_pw_off;
    wire [7:0]  pw_any_data  = pw_valid_w ? pw_data_w : rl_pw_data;

    page_cache #(.SETS (MEM_SETS), .WAYS (MEM_WAYS)) u_cache (
        .clk         (apple_clk),
        .rst         (apple_rst),
        .cl_valid    (cl_valid),
        .cl_cls      (cl_cls),
        .cl_ppn      (cl_ppn_w),
        .cl_off      (cl_off[7:0]),
        .cl_rw       (cl_rw),
        .cl_wr_image (cl_wr_image),
        .cl_wdata    (cl_wdata),
        .cl_posted   (cl_posted),
        .pw_pending  (d_pending_w),
        .pw_ready    (pw_ready_w),
        .pf_ppn      (pf_ppn_w),
        .pf_off      (pf_off[7:0]),
        .pw_take     (pw_take_w),
        // The map's shadow duplicate needs its own P0 (docs/GS.md rung 3e).
        .shd_take    (shd_take_w),
        .shd_ppn     (shd_ppn_w),
        .shd_off     (shd_off_w),
        .pw_ppn      (pw_any_ppn),
        .pw_off      (pw_any_off),
        .op_addr     (u_addr),
        .op_present  (u_present),
        .op_commit   (u_commit),
        .op_divert   (u_divert),
        .data_sync   (apple_data_sync),
        .sub_en      (mem_sub_en),
        .op_row_v    (mem_op_row_v), .op_row (mem_op_row), .op_row_ppn (mem_op_row_ppn),
        .sub_data    (mem_sub_data),
        .decided     (mem_decided),
        .busy        (mem_busy),
        .mw_stb      (fb_mw_stb),
        .mw_addr     (fb_mw_addr),
        .mw_byte     (fb_mw_byte),
        .mwx_stb     (fb_mwx_stb),
        .mw_bank     (fb_mw_bank),
        // The line-row port has no user on this card since rung 5: both L1
        // sides read by the direct way read below.
        .il_req      (1'b0),
        .il_ppn      (16'd0),
        .il_line     (4'd0),
        .il_src      (1'b1),
        .il_ack      (il_ack),
        .il_done     (il_done),
        .il_ok       (il_ok),
        .il_row      (il_row),
        // The TLB's references and the direct way read (rung 4).
        .ref_v (ref_v_w), .ref_set (ref_set_w), .ref_way (ref_way_w), .ref_on (ref_on_w),
        .evict_v (evict_v_w), .evict_set (evict_set_w), .evict_way (evict_way_w),
        .op_place_v (op_place_v_w), .op_place_ppn (op_place_ppn_w), .op_place_set (op_place_set_w), .op_place_way (op_place_way_w),
        .dr_req (dr_req_w), .dr_set (dr_set_w), .dr_way (dr_way_w), .dr_line (dr_line_w),
        .dr_ack (dr_ack_w), .dr_done (dr_done_w), .dr_row (dr_row_w),
        .serve       (mem_serve),
        .inval       (mem_inval),
        .dbg_sel     (dbg_sel[3:0]),
        .dbg_val     (pc_dbg),
        .cnt_clr     (mem_cnt_clr),
        .image_ready (mem_image_ready),
        .invalidating (mem_invalidating),
        .hits        (mem_hits),
        .misses      (mem_misses),
        .served      (mem_served),
        .mismatches  (mem_mismatch),
        .last_mismatch (mem_last),
        .diverted    (mem_diverted),
        .late_fills  (mem_late_fills),
        .fifo_drops  (mem_fifo_drops),
        .mem_fills   (mem_fills),
        .mem_flushes (mem_flushes),
        .mem_declines (mem_declines),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data)
    );

    // ---- the beam every consumer takes (docs/VIRTUAL_TIME.md) ---------------
    // The lock's counter while the core keeps the bus's time; a virtual
    // counter stepped once per core cycle while it does not - fb_sim's
    // position, the internalized $C019, bit 19 of every word, the frame
    // mark.  Every core cycle has a word at the merge's door (the fronts
    // wait for room, the sequencer flags its quiet reads), so the door's
    // in-order counts carry the cycles the host does not see.
    // THE IIgs's BEAM RUNS AT THE BUS's CADENCE (user decision 2026-09-11;
    // docs/GS.md "The beam on the IIgs").  The IIe's beam is found by
    // watching the motherboard's scanner through the floating bus
    // (rtl/vbl_lock.sv); a IIgs's video is the card's and the host's, and
    // there is no scanner on the backplane to lock to, so vbeam's own
    // counter runs from reset, told it is locked - and it steps on EVERY
    // bus cycle, dummies and overrides included, never on a fast tick.
    // That is what a real accelerator's VGC does: the 1 MHz bus cannot be
    // sped up, so the VBL, the scan-line interrupt, the toolbox's ticks
    // (and with them double-click) and the frames the host shows all come
    // at wall speed however fast the 65816 runs.  A program counting
    // cycles against the beam finds it slower, exactly as on the real
    // thing.  To the host that is the BUS's base, so virt_base is low.
    assign virt      = GS || (accel_on && !boot_held);
    assign virt_base = !GS && virt;
    vbeam u_beam (
        .clk            (apple_clk),
        .rst            (apple_rst),
        .virt           (virt),
        .wall           (GS),
        .real_locked    (GS ? 1'b1 : vbl_locked),
        .real_v         (GS ? 9'd0 : lock_scan_v),
        .real_h         (GS ? 7'd0 : lock_scan_h),
        .pal            (vbl_pal),
        .notify         (GS ? 1'b1 : vbl_notify),
        .real_mark      (vbl_mark),
        .real_mark_free (vbl_mark_free),
        .bus_tick       (bus_tick),
        .op_dummy       (op_dummy),
        .op_ovr         (op_ovr),
        .fast_tick      (seq_fast_tick || turbo_tick || dline_tick),
        .locked         (beam_locked),
        .scan_v         (scan_v),
        .scan_h         (scan_h),
        .vbl_level      (vbl_level),
        .mark_bus       (beam_mark_bus),
        .mark_fast      (beam_mark_fast),
        .mark_free      (beam_mark_free)
    );

    // ---- the floating bus, simulated ----------------------------------------
    // A side copy of main memory's display pages, written on the clock the
    // page cache's main bank takes each byte, read at the video scanner's
    // address for the cycle in flight: the byte a floating-bus read would
    // return, without the bus.  Compared with the real byte on every such
    // read; substituted for it when FB_CTRL says so.  See rtl/fb_sim.sv and
    // docs/FLOATING_BUS.md.
    // THE PLAIN RATIO (user, 2026-09-11).  Two counters and nothing else:
    // core cycles exactly as vbeam advances on them - a real bus cycle that
    // is the core's (not a dummy, not DMA) or a fast op's retire, both in
    // one clock counting two - over raw bus cycles.  The host divides.  The
    // classified census (turbo + dline + fast + bus over cycles) stays as
    // the breakdown, but a kind it does not count no longer bends the
    // headline number.  Cleared with the rest by ACCEL_CTRL's cnt_clr.
    logic [31:0] cnt_core_cyc = 32'd0, cnt_bus_cyc = 32'd0;
    wire         core_tick_bus  = bus_tick && !op_dummy && !op_ovr;
    wire         core_tick_fast = seq_fast_tick || turbo_tick || dline_tick;
    always_ff @(posedge apple_clk) begin
        if (apple_rst || accel_cnt_clr) begin
            cnt_core_cyc <= 32'd0; cnt_bus_cyc <= 32'd0;
        end else begin
            cnt_core_cyc <= cnt_core_cyc + {31'd0, core_tick_bus} + {31'd0, core_tick_fast};
            cnt_bus_cyc  <= cnt_bus_cyc + {31'd0, bus_tick};
        end
    end

    fb_sim u_fb (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .op_addr       (u_addr),
        .op_rw         (u_rw),
        .op_present    (u_present),
        .op_commit     (u_commit),
        .op_ovr        (u_ovr),
        .mw_stb        (fb_mw_stb),
        .mw_addr       (fb_mw_addr),
        .mw_byte       (fb_mw_byte),
        .sw_state      (mem_sw),
        .vid_sw        (vid_sw),
        .locked        (beam_locked),
        .scan_v        (scan_v),
        .scan_h        (scan_h),
        .pal           (vbl_pal),
        .master_active (cpu_source_active),
        .data_sync     (apple_data_sync),
        .slot_rd_claim (slot_rd_claim_bus),
        .kbd_sub_en    (kbd_sub_en),
        .pb_sub_en     (pb_sub_en),
        .serve         (fb_serve),
        .cnt_clr       (fb_cnt_clr),
        .peek_addr     (fb_peek_addr),
        .sub_en        (fb_sub_en),
        .sub_data      (fb_sub_data),
        .int_ok        (fb_int_ok),
        .vbl_bar       (fb_vbl_bar),
        .mode          (fb_mode),
        .compared      (fb_compared),
        .mismatches    (fb_mismatch),
        .last          (fb_last),
        .last2         (fb_last2),
        .other         (fb_other),
        .peek_data     (fb_peek_data)
    );

    // ---- the hard disk ------------------------------------------------------
    // The slot ROM and the EXECUTE port; the images and the command decode
    // are on the host.  See rtl/hd_card.sv.
    hd_card #(.GS (GS)) u_hd (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .cpu_rst       (cpu_rst),
        .res_sync      (apple_res_sync),
        .master_active (cpu_source_active),
        .slot_assign   (hd_slot_active),
        .op_addr       (p_addr),
        .op_rw         (p_rw),
        .op_present    (p_present),
        .op_commit     (p_commit),
        .op_ovr        (p_ovr),
        .op_bank       (p_bank),
        .din           (drv_din),
        .ovr_en        (hd_ovr_en),
        .ovr_addr      (hd_ovr_addr),
        .ovr_bank      (hd_ovr_bank),
        .ovr_rw        (hd_ovr_rw),
        .ovr_wdata     (hd_ovr_wdata),
        .panel_dmas    (hd_panel_dmas),
        .panel_drops   (hd_panel_drops),
        .rd_claim      (hd_rd_claim),
        .rd_data       (hd_rd_data),
        .msg_valid     (app_msg_valid),
        .msg_type      (app_msg_type),
        .msg_free      (app_msg_free),
        .msg_len       (app_msg_len),
        .pay_data      (app_pay_data),
        .pay_valid     (app_pay_valid),
        .tx_word       (aux_word),
        .tx_valid      (aux_valid),
        .tx_take       (aux_take),
        .rom_loaded    (hd_rom_loaded),
        .busy          (hd_busy),
        .execs         (hd_execs),
        .exec_q        (hd_exec_q)
    );

    // ---- the floppy ---------------------------------------------------------
    // A Disk II controller and two drives, with the images on the host and
    // one track of each in the card.  See rtl/floppy_card.sv.
    //
    // THE IIe's ONLY.  On a IIgs the 5.25" drives are the IWM's (rtl/gs_iwm.sv,
    // docs/IWM35.md): slot 6's $C0Ex IS the internal IWM, and a Disk II card
    // answering there was a clash the machine never reconciled.  So at GS = 1
    // the card is not built at all - no claim, no stall, no listener on the
    // FD_TRACK messages the IWM's 5.25" side takes instead - and its outputs
    // read as an absent card.
    generate if (!GS) begin : g_fd
        floppy_card u_fd (
            .clk           (apple_clk),
            .rst           (apple_rst),
            .cpu_rst       (cpu_rst),
            .res_sync      (apple_res_sync),
            .master_active (cpu_source_active),
            .slot_assign   (fd_slot_active),
            .op_addr       (p_addr),
            .op_rw         (p_rw),
            .op_wdata      (p_wdata),
            .op_present    (p_present),
            .op_commit     (p_commit),
            .op_ovr        (p_ovr),
            .op_dummy      (p_dummy),
            .fast_tick     (seq_fast_tick || turbo_tick || dline_tick),
            .rd_claim      (fd_rd_claim),
            .rd_data       (fd_rd_data),
            .msg_valid     (app_msg_valid),
            .msg_type      (app_msg_type),
            .msg_free      (app_msg_free),
            .msg_len       (app_msg_len),
            .pay_data      (app_pay_data),
            .pay_valid     (app_pay_valid),
            .tx_word       (fd_word),
            .tx_valid      (fd_valid),
            .tx_take       (fd_take),
            .drv_inserted  (fd_inserted),
            .drv_wp        (fd_wp),
            .drv_cell      (fd_nibbles),
            .drv_tracks    (fd_tracks),
            .drv_flush     (fd_flush),
            .late_clr      (fd_late_clr),
            .fill_clr      (fd_fill_clr),
            .rom_loaded    (fd_rom_loaded),
            .stale_o       (fd_stale),
            .dirty_o       (fd_dirty),
            .phase_o       (fd_phase),
            .motor_o       (fd_motor),
            .drive_sel_o   (fd_drive_sel),
            .q6_o          (fd_q6),
            .q7_o          (fd_q7),
            .seeks         (fd_seeks),
            .late          (fd_late),
            .fill_max      (fd_fill_max),
            .stall_o       (fd_stall)
        );
    end else begin : g_no_fd
        assign fd_rd_claim   = 1'b0;
        assign fd_rd_data    = 8'd0;
        assign fd_word       = 32'd0;
        assign fd_valid      = 1'b0;
        assign fd_stall      = 1'b0;
        assign fd_rom_loaded = 1'b0;
        // The registers' readback is the IWM's 5.25" side (rtl/gs_iwm.sv).
        assign fd_stale      = gsio_fd525_stale;
        assign fd_dirty      = gsio_fd525_dirty;
        assign fd_phase      = gsio_fd525_phase;
        assign fd_motor      = fd35_motor;
        assign fd_drive_sel  = fd35_ctl[1];
        assign fd_q6         = fd35_ctl[2];
        assign fd_q7         = fd35_ctl[3];
        assign fd_seeks      = fd35_seeks;
        assign fd_late       = fd35_late;
        assign fd_fill_max   = fd35_fill_max;
    end endgenerate

    // ---- the VidHD ----------------------------------------------------------
    // A slot ROM carrying the signature software scans for; the IIgs video
    // registers it then writes go out on the bus unanswered, and the host
    // draws the picture from its mirror of auxiliary memory.  See
    // rtl/vidhd_card.sv and docs/VIDHD.md.
    //
    // NOT BUILT ON A IIgs (user, 2026-09-15; docs/GS_CONTROL_PANEL.md).  A
    // VidHD is a card that gives a IIe the IIgs's video registers and Super
    // Hi-Res; a IIgs has a VGC and its software knows it.  The host refuses
    // the key outright at machine = iigs, so the card would never be
    // assigned a slot anyway - building it there only puts another claim
    // term in the slot read mux below, which is on the read path.
    generate if (!GS) begin : g_vidhd
        vidhd_card u_vidhd (
            .clk           (apple_clk),
            .rst           (apple_rst),
            .res_sync      (apple_res_sync),
            .master_active (cpu_source_active),
            .slot_assign   (vidhd_slot_active),
            .op_addr       (op_addr),
            .op_rw         (op_rw),
            .op_present    (op_present),
            .op_commit     (op_commit),
            .op_ovr        (op_ovr),
            .rd_claim      (vidhd_rd_claim),
            .rd_data       (vidhd_rd_data),
            .msg_valid     (app_msg_valid),
            .msg_type      (app_msg_type),
            .msg_free      (app_msg_free),
            .msg_len       (app_msg_len),
            .pay_data      (app_pay_data),
            .pay_valid     (app_pay_valid),
            .rom_loaded    (vidhd_rom_loaded)
        );
    end else begin : g_no_vidhd
        assign vidhd_rd_claim   = 1'b0;
        assign vidhd_rd_data    = 8'd0;
        assign vidhd_rom_loaded = 1'b0;
    end endgenerate

    // ---- the Mockingboard ---------------------------------------------------
    // Two VIAs answering for an empty slot, and since docs/AUDIO.md the AYs'
    // sound too, sampled below.  As a Phasor, the same two VIAs behind the
    // Phasor's mode register.  See rtl/mockingboard.sv.
    mockingboard u_mb (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .res_sync      (apple_res_sync),
        .master_active (cpu_source_active),
        .slot_assign   (mb_slot_active),
        .phasor        (mb_phasor_active),
        .op_addr       (p_addr),
        .op_rw         (p_rw),
        .op_wdata      (p_wdata),
        .op_present    (p_present),
        .op_commit     (p_commit),
        .op_dummy      (p_dummy),
        .fast_tick     (seq_fast_tick || turbo_tick || dline_tick),
        // The real-time ledger's clock and the AYs' (rtl/mockingboard.sv:
        // two sets of books).  AUDIO_CTRL[1], audio_realtime, chose the AYs'
        // time base before the split; the AYs run in real time now and the
        // bit is kept for the host's sake, inert.
        .bus_tick      (bus_tick),
        .ay_out        (mb_ay_out),
        .rd_claim      (mb_rd_claim),
        .rd_data       (mb_rd_data),
        .irq           (mb_irq)
    );

    // ---- the sound (docs/AUDIO.md) ---------------------------------------------
    // The speaker flip-flop on the same two doors the host toggled on, the
    // sampler's box average at the play rate, the frames to the host.
    speaker #(.GS (GS)) u_spk (
        .clk        (apple_clk),
        .rst        (apple_rst),
        .res_sync   (apple_res_sync),
        .real_valid (real_valid && real_io),
        .real_dummy (op_dummy),
        .real_addr  (real_data[15:0]),
        .fast_valid ((fev_valid || tev_valid || dev_valid) && fast_io),
        .fast_addr  (fev_valid ? fev_addr : tev_valid ? tev_addr : dev_addr),
        .level      (spk_level),
        .toggle     (spk_toggle)
    );

    audio_sampler u_smp (
        .clk       (apple_clk),
        .rst       (apple_rst),
        .enable    (audio_on),
        .rate_inc  (audio_rate),
        .spk       (spk_level),
        .ay_out    (mb_ay_out),
        .doc_l     (doc_l),
        .doc_r     (doc_r),
        .smp_valid (smp_valid),
        .smp_spk   (smp_spk),
        .smp_ay    (smp_ay),
        .smp_doc_l (smp_doc_l),
        .smp_doc_r (smp_doc_r)
    );

    audio_tx u_atx (
        .clk       (apple_clk),
        .rst       (apple_rst),
        .enable    (audio_on),
        .smp_valid (smp_valid),
        .smp_spk   (smp_spk),
        .smp_ay    (smp_ay),
        .smp_doc_l (smp_doc_l),
        .smp_doc_r (smp_doc_r),
        .word      (au_word),
        .valid     (au_valid),
        .take      (au_take),
        .stat      (audio_stat)
    );

    // ---- the mouse ----------------------------------------------------------
    // An AppleMouse II card: the PIA and the 68705's protocol on the card,
    // the Pi's mouse arriving as MOUSE_MOVE messages.  On the peripherals'
    // view like the Mockingboard, its interrupt on the short route.  See
    // rtl/mouse_card.sv and docs/MOUSE.md.
    mouse_card u_mouse (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .res_sync      (apple_res_sync),
        .master_active (cpu_source_active),
        .slot_assign   (mouse_slot_active),
        .op_addr       (p_addr),
        .op_rw         (p_rw),
        .op_wdata      (p_wdata),
        .op_present    (p_present),
        .op_commit     (p_commit),
        .op_dummy      (p_dummy),
        .op_ovr        (p_ovr),
        .fast_tick     (seq_fast_tick || turbo_tick || dline_tick),
        .rd_claim      (mouse_rd_claim),
        .rd_data       (mouse_rd_data),
        .msg_valid     (app_msg_valid),
        .msg_type      (app_msg_type),
        .msg_free      (app_msg_free),
        .msg_len       (app_msg_len),
        .pay_data      (app_pay_data),
        .pay_valid     (app_pay_valid),
        .irq           (mouse_irq),
        .rom_loaded    (mouse_rom_loaded),
        .pos_x         (mouse_x),
        .pos_y         (mouse_y),
        .mode_rd       (mouse_mode),
        .buttons_rd    (mouse_buttons),
        .moves_rd      (mouse_moves)
    );

    // ---- the Uthernet II ----------------------------------------------------
    // A W5100 on the card - registers, rings, the socket machine - with the
    // network on the host behind four messages.  On the peripherals' view
    // like the mouse, DEVICE SELECT only; its U2_CMD/U2_TX stream is the
    // message bus's seventh source; its stall holds the core's next op
    // while a held ring word is missing.  See rtl/uthernet2_card.sv and
    // docs/UTHERNET2.md.
    uthernet2_card u_u2 (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .res_sync      (apple_res_sync),
        .master_active (cpu_source_active),
        .slot_assign   (u2_slot_active),
        .op_addr       (p_addr),
        .op_rw         (p_rw),
        .op_wdata      (p_wdata),
        .op_present    (p_present),
        .op_commit     (p_commit),
        .op_ovr        (p_ovr),
        .rd_claim      (u2_rd_claim),
        .rd_data       (u2_rd_data),
        .msg_valid     (app_msg_valid),
        .msg_type      (app_msg_type),
        .msg_free      (app_msg_free),
        .msg_len       (app_msg_len),
        .pay_data      (app_pay_data),
        .pay_valid     (app_pay_valid),
        .tx_word       (u2_word),
        .tx_valid      (u2_valid),
        .tx_take       (u2_take),
        .stall_o       (u2_stall),
        .sock_open     (u2_sock_open),
        .cmd_dropped   (u2_cmd_dropped),
        .cmds_o        (u2_cmds),
        .rx_chunks_o   (u2_rx_chunks),
        .s0_rsr_o      (u2_s0_rsr),
        .s0_fsr_o      (u2_s0_fsr)
    );

    // ---- the printer card -----------------------------------------------------
    // A parallel printer interface's slot: the ROM page the host loads, a
    // device-select range that reads $FF, and the writes left to the stream
    // for the host's printer half.  See rtl/printer_card.sv and docs/PRINTER.md.
    printer_card u_printer (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .res_sync      (apple_res_sync),
        .master_active (cpu_source_active),
        .slot_assign   (printer_slot_active),
        .op_addr       (p_addr),
        .op_rw         (p_rw),
        .op_present    (p_present),
        .op_commit     (p_commit),
        .op_ovr        (p_ovr),
        .rd_claim      (prn_rd_claim),
        .rd_data       (prn_rd_data),
        .msg_valid     (app_msg_valid),
        .msg_type      (app_msg_type),
        .msg_free      (app_msg_free),
        .msg_len       (app_msg_len),
        .pay_data      (app_pay_data),
        .pay_valid     (app_pay_valid),
        .rom_loaded    (printer_rom_loaded),
        .writes        (printer_writes)
    );

    // ---- the No-Slot Clock --------------------------------------------------
    // A DS1216 under the CD ROM, the host's time behind it.  It listens on
    // the unified stream - the MMU's map says whether the core's address is
    // in a page the part sees - and steps at the op's commit: the driver's
    // for a bus op, the sequencer's tick for a fast one.  Its bit goes
    // into cpu_din above, never onto the bus.  See docs/NSC.md.
    no_slot_clock u_nsc (
        .clk           (apple_clk),
        .rst           (apple_rst || !cpu_source_active),
        .enable        (nsc_enable),
        .q_nsc         (q_nsc),
        .q_rw          (cpu_rw),
        .q_a2          (nxt_addr[2]),
        .ovr_en        (ovr_en),
        .u_present     (u_present),
        .u_ovr         (u_ovr),
        .u_addr_lo     (u_addr[2:0]),
        .commit        (seq_fast_tick || (op_commit && !op_dummy && !op_ovr)),
        .msg_valid     (app_msg_valid),
        .msg_type      (app_msg_type),
        .msg_len       (app_msg_len),
        .pay_data      (app_pay_data),
        .pay_valid     (app_pay_valid),
        .sub           (nsc_sub),
        .sub_bit       (nsc_bit),
        .time_loaded   (nsc_time_loaded),
        .ring_en_o     (nsc_ring_en),
        .wr_en_o       (nsc_wr_en),
        .cmp_idx_o     (nsc_cmp_idx),
        .ring_idx_o    (nsc_ring_idx),
        .unlocks_o     (nsc_unlocks),
        .now_o         (nsc_now)
    );

    // ---- the pins -----------------------------------------------------------
    // The one place in the design where anything reaches the Apple bus.
    assign apple_addr_pin = addr_rw_oe ? addr_drive : 16'hzzzz;
    assign apple_rw_pin   = addr_rw_oe ? rw_drive   : 1'bz;
    assign apple_data_pin = data_oe    ? data_drive : 8'hzz;

    // DMA' is open-drain in spirit: pulled low to take the bus, released
    // otherwise.  Never driven high - the motherboard's pull-up owns that.
    assign apple_dma_pin  = dma_assert ? 1'b0 : 1'bz;

    // RES' the same way: a wired-OR line the host can pulse low to reboot the
    // machine programmatically.  Hi-Z otherwise, so the keyboard and the
    // power-on reset still own it.  The reader samples it back as
    // apple_res_sync, so our own pulse resets the soft core and re-latches the
    // slot registers exactly as a Ctrl-Reset does.  See wb_regfile's R_RESET.
    assign apple_res_pin  = res_drive ? 1'b0 : 1'bz;

    // The shifters follow the enables, so a buffer only points at the Apple
    // while something is actually driving through it.
    assign tini_oe_pin       = tini_5v_pin;
    assign tini_addr_dir_pin = addr_rw_oe;
    assign tini_data_dir_pin = data_oe;

endmodule
