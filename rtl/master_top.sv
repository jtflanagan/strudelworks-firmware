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
// machine must see.  Every memory-side consumer - the MMU shadow, the cache,
// the floating-bus copy, the hold - watches the sequencer's unified stream of
// ops; every peripheral that decodes $Cxxx or counts bus cycles watches the
// driver, whose ops those always are.  See rtl/accel_seq.sv and
// docs/ACCELERATION.md.
//
// WHAT IS NOT HERE YET: INH, RDY and NMI.  INH would let the card override the
// machine's own memory, which is a memory-mode decision that has not been made;
// RDY is not used by the Apple II for the CPU; the slot brings out no NMI.
//////////////////////////////////////////////////////////////////////////////////
module master_top #(
    parameter integer BUILD_DATE = 0,   // YYYYMMDD
    parameter integer BUILD_TIME = 0    // HHMMSS
) (
    input  wire        clk_pin,
    input  wire        rst_n,
    output wire [7:0]  led,
    input  wire        usb_rx,
    output wire        usb_tx,

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

    // DDR3 (constr/ddr3.xdc).  The card's outgoing stream crosses it; see
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
    wire [31:0] real_data;
    wire        real_valid, phi0_live, bus_tick;
    wire        apple_res_sync, apple_irq_sync, apple_phi0_sync;
    wire [7:0]  apple_data_sync;
    wire        cpu_source_active;
    wire [2:0]  mb_slot_active, hd_slot_active;
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
    wire [2:0]  vidhd_slot_active;
    wire        vidhd_rom_loaded;
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
    wire        mem_sub_en, fb_sub_en;
    wire [7:0]  mem_sub_data, fb_sub_data;
    wire        mem_sub_bus = mem_sub_en && bus_owns;
    wire        sub_en   = kbd_sub_en | pb_sub_en | mem_sub_bus | fb_sub_en;
    wire [7:0]  sub_data = kbd_sub_en ? kbd_sub_data :
                           pb_sub_en  ? pb_sub_data  :
                           mem_sub_bus ? mem_sub_data : fb_sub_data;
    // The memory image's seam through card_link (rtl/mem_client.sv is there,
    // beside the DDR3; the MMU shadow, the ROM and the cache are here, beside
    // the core).  See docs/MEMORY.md.
    wire        mq_valid, mq_kind, mq_ready, mr_valid;
    wire [1:0]  mq_id, mr_id;
    wire [19:0] mq_line;
    wire [3:0]  mq_byte;
    wire [7:0]  mq_data;
    wire [127:0] mr_data;
    wire        mem_image_ready, mem_cnt_clr, mem_inval, mem_invalidating, mem_rom_loaded;
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
    wire        vbl_level;      // the lock's counter in blanking: bit 19 of every event
    wire [8:0]  scan_v;         // ...and where it is, for the floating-bus simulator
    wire [6:0]  scan_h;
    wire [2:0]  vid_sw;         // the MMU shadow's video switches, for the same
    wire        fb_serve, fb_cnt_clr;
    wire [14:0] fb_peek_addr;
    wire [6:0]  fb_mode;
    wire [31:0] fb_compared, fb_mismatch, fb_last, fb_last2, fb_other;
    wire [7:0]  fb_peek_data;
    // The sequencer: ACCEL_CTRL in, its stream, status and counters out.
    wire [1:0]  accel_mode;
    wire [15:0] accel_target;
    wire        accel_cnt_clr, accel_on, accel_held;
    // The diagnosis chicken bits (docs/DIAG_ACCEL_HW.md): levels off
    // ACCEL_CTRL that switch the two never-simulated-together features off
    // at runtime, so hardware can bisect a failure without a rebuild.
    wire        accel_turbo_dis, accel_drain_dis;
    wire [3:0]  seq_state;
    wire [31:0] accel_fast, accel_bus, accel_cycles, accel_wait;
    wire [7:0]  accel_retries, merge_overflows;
    wire        accel_reset_seq;
    wire        u_present, u_commit, u_rw, u_sync, u_ovr, u_divert;
    wire [15:0] u_addr;
    wire [7:0]  u_wdata;
    wire        fev_valid, fev_rw, fev_sync, fev_room;
    // The DMA line-drain engine's world (rtl/hd_card.sv, docs/HARDDISK.md):
    // stream words, the line write, the L2 invalidate, the icache snoop,
    // the page query, the shadow bytes - and the gate: the closed regime
    // only, where writes are not exposed on the bus by design.
    wire [31:0] hd_dma_ev_word;
    wire        hd_dma_ev_valid, hd_dma_ev_take;
    wire        hd_dq_valid, hd_dq_ready;
    wire [19:0] hd_dq_line;
    wire [15:0] hd_dq_be;
    wire [127:0] hd_dq_data;
    wire        hd_inv_en, hd_inv_rdy;
    wire [23:0] hd_inv_pa;
    wire        hd_snoop2_en, hd_snoop2_take;
    wire [23:0] hd_snoop2_pa;
    wire [7:0]  hd_t2_page;
    wire        hd_t2_w_ok;
    wire [16:0] hd_t2_w_ppage;
    wire        hd_fb2_we, hd_fb2_ready;
    wire [15:0] hd_fb2_addr;
    wire [7:0]  hd_fb2_data;
    wire        hd_fast_dma = accel_on && (accel_mode == 2'd2) && mem_serve &&
                              !accel_drain_dis;
    wire [15:0] fev_addr;
    wire [7:0]  fev_data;
    wire        bus_owns, core_valid, op_dummy, op_inflight, drv_cyc_done;
    wire [7:0]  drv_din;
    wire        mem_decided, mem_busy, mem_intc8rom;
    wire [1:0]  q_cls;
    wire        app_msg_valid, app_pay_valid;
    wire [7:0]  app_msg_type, app_msg_len;
    wire [15:0] app_msg_free;
    wire [31:0] app_pay_data;
    wire [31:0] aux_word;
    wire        aux_valid, aux_take;

    card_link #(
        .BUILD_DATE (BUILD_DATE),
        .BUILD_TIME (BUILD_TIME),
        .CAN_MASTER (1'b1)
    ) u_card (
        .clk_pin (clk_pin), .rst_n (rst_n), .led (led),
        .usb_rx (usb_rx), .usb_tx (usb_tx),
        .apple_clk (apple_clk), .apple_rst (apple_rst),
        .capture_on (capture_on), .capture_real (capture_real),
        .real_data (real_data), .real_valid (real_valid),
        .real_mark (vbl_mark), .real_mark_free (vbl_mark_free),
        .real_dummy (op_dummy),
        .fev_room (fev_room),
        .dma_ev_word (hd_dma_ev_word), .dma_ev_valid (hd_dma_ev_valid),
        .dma_ev_take (hd_dma_ev_take),
        .hd_dq_valid (hd_dq_valid), .hd_dq_line (hd_dq_line),
        .hd_dq_be (hd_dq_be), .hd_dq_data (hd_dq_data),
        .hd_dq_ready (hd_dq_ready),
        .fast_valid (fev_valid), .fast_addr (fev_addr), .fast_rw (fev_rw),
        .fast_data (fev_data), .fast_sync (fev_sync), .fast_vbl (vbl_level),
        .merge_overflows (merge_overflows),
        .phi0_live (phi0_live),
        .apple_res_sync (apple_res_sync),
        .cpu_source_active (cpu_source_active),
        .mb_slot_active (mb_slot_active),
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
        .vidhd_slot_active (vidhd_slot_active),
        .vidhd_rom_loaded (vidhd_rom_loaded),
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
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data),
        .mem_image_ready (mem_image_ready),
        .mem_serve (mem_serve), .mem_cnt_clr (mem_cnt_clr), .mem_inval (mem_inval),
        .mem_sw (mem_sw), .mem_rw_bank (mem_rw_bank), .mem_invalidating (mem_invalidating),
        .mem_rom_loaded (mem_rom_loaded),
        .mem_late_fills (mem_late_fills), .mem_fifo_drops (mem_fifo_drops),
        .mem_hits (mem_hits), .mem_misses (mem_misses), .mem_mismatch (mem_mismatch),
        .mem_served (mem_served), .mem_last (mem_last), .mem_diverted (mem_diverted),
        .mem_intc8rom (mem_intc8rom),
        .accel_mode (accel_mode), .accel_target (accel_target),
        .accel_turbo_dis (accel_turbo_dis), .accel_drain_dis (accel_drain_dis),
        .accel_cnt_clr (accel_cnt_clr),
        .accel_on (accel_on),
        .accel_stat ({7'd0, accel_reset_seq, accel_retries, merge_overflows, seq_state, bus_owns, 1'b0, accel_held, accel_on}),
        .accel_fast (accel_fast), .accel_bus (accel_bus),
        .accel_turbo (accel_turbo_ops),
        .accel_cycles (accel_cycles), .accel_wait (accel_wait),
        .fb_serve (fb_serve), .fb_cnt_clr (fb_cnt_clr), .fb_peek_addr (fb_peek_addr),
        .fb_mode (fb_mode), .fb_compared (fb_compared), .fb_mismatch (fb_mismatch),
        .fb_last (fb_last), .fb_last2 (fb_last2), .fb_other (fb_other),
        .fb_peek_data (fb_peek_data),
        .res_drive (res_drive),
        .app_msg_valid (app_msg_valid), .app_msg_type (app_msg_type),
        .app_msg_free (app_msg_free), .app_msg_len (app_msg_len),
        .app_pay_data (app_pay_data), .app_pay_valid (app_pay_valid),
        .aux_word (aux_word), .aux_valid (aux_valid), .aux_take (aux_take),
        .fd_word (fd_word), .fd_valid (fd_valid), .fd_take (fd_take),
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

    // ---- the core region's reset: the pipelined replica ---------------------
    // apple_rst is held for the link's 1 ms window every time it asserts
    // (card_link's RST_TICKS), so this two-flop copy is the same reset two
    // clocks later - nothing a consumer can observe across a hundred
    // thousand held clocks.  What it buys (the reset-discipline policy,
    // 2026-08-30): the accelerated neighborhood's reset is a local register
    // the tools may replicate near its loads, not the flat fanout-2393 net,
    // and the flat net stops growing.  The cards and injectors stay on
    // apple_rst - they are bus-paced, with no serve cones - and convert
    // opportunistically later.  New accelerated RTL takes rst_core, never
    // apple_rst.
    logic rst_core_p = 1'b1, rst_core = 1'b1;
    always_ff @(posedge apple_clk) begin
        rst_core_p <= apple_rst;
        rst_core   <= rst_core_p;
    end

    // ---- the soft CPU -------------------------------------------------------
    // Held in reset while the machine is, so it starts where the machine does.
    // The cards' copy stays on the flat net; the two differ only inside the
    // two-clock skew at a card reset's edges, a millisecond before anything
    // moves - the live term, the machine's RES', is common and unpiped.
    wire cpu_rst      = apple_rst || !apple_res_sync;
    wire cpu_rst_core = rst_core  || !apple_res_sync;

    wire [15:0] cpu_addr;
    wire        cpu_rw;
    wire [7:0]  cpu_dout, cpu_din;
    wire        cpu_cyc_en, cpu_sync;

    // The L1 front's world: the core's stream classification and prediction,
    // the sequencer's permission and books, the I-TLB's refill, the icache's
    // fill and snoop.  cyc_en and din now reach the core THROUGH the front
    // (rtl/l1_front.sv); the sequencer's own become accel_cyc_en/accel_din.
    wire        cpu_cyc_is_i;
    wire [15:0] cpu_i_pred, cpu_i_addr, cpu_i_steer;
    wire        accel_cyc_en;
    wire [7:0]  accel_din;
    wire        turbo_ok_seq, l1_claim, turbo_commit, turbo_sync;
    // turbo_dis simply withholds the sequencer's permission: the front then
    // never serves, every op dispatches, and the claim window still lapses
    // on its own clock.  A level off a register - nothing live in the cone.
    wire        turbo_ok = turbo_ok_seq && !accel_turbo_dis;
    wire [15:0] turbo_addr;
    wire [7:0]  turbo_data;
    wire        accel_op_tick;
    wire [31:0] accel_turbo_ops;
    wire [7:0]  tlb_t_page;
    wire        tlb_r_ok, tlb_w_ok;
    wire [16:0] tlb_r_ppage, tlb_w_ppage;
    wire        map_changed;
    wire [127:0] mem_sub_line;
    wire         mem_sub_line_ok;
    wire        rom_r2_en;
    wire [11:0] rom_r2_addr;
    wire [31:0] rom_r2_data;

    // The Mockingboard's IRQ takes the short route into the core, the same
    // route drv_sync takes out of it: a real card would pull the slot's IRQ'
    // line and this card's CPU is on the near side of that pin, so the VIA
    // interrupts are folded in here instead.  Physical cards still interrupt
    // through the pin, via apple_irq_sync, exactly as before.
    wire mb_irq;

    // cyc_en and din come from the sequencer: the driver's for a bus op, the
    // cache's for a fast one.
    cpu65c02 u_cpu (
        .clk    (apple_clk),
        .rst    (cpu_rst_core),
        .cyc_en (cpu_cyc_en),
        .addr   (cpu_addr),
        .rw     (cpu_rw),
        .dout   (cpu_dout),
        .din    (cpu_din),
        .irq_n  (apple_irq_sync && !mb_irq),
        .nmi_n  (1'b1),             // the slot brings out no NMI
        .sync   (cpu_sync),
        .halted (),                 // STP is not on the base part; see the RTL
        .cyc_is_i (cpu_cyc_is_i),
        .i_addr (cpu_i_addr),       // the PC registers: the front's loop-free
        .d_addr (),                 // lookup address
        .d_rw   (),
        .d_dout (),
        .i_pred (cpu_i_pred),
        .i_steer (cpu_i_steer)
    );

    // ---- driving ------------------------------------------------------------
    wire [15:0] addr_drive;
    wire        rw_drive;
    wire [7:0]  data_drive;
    wire        addr_rw_oe, data_oe, dma_assert, drv_sync;

    wire [15:0] op_addr;
    wire        op_rw;
    wire [7:0]  op_wdata;
    wire        op_present, op_commit, op_ovr;
    wire        mb_rd_claim, hd_rd_claim, fd_rd_claim, vidhd_rd_claim;
    wire [7:0]  mb_rd_data, hd_rd_data, fd_rd_data, vidhd_rd_data;
    wire        boot_ovr_en, hd_ovr_en, hd_ovr_rw, vbl_ovr_en, vbl_ovr_rw;
    wire [15:0] boot_ovr_addr, hd_ovr_addr, vbl_ovr_addr;
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

    wire        ovr_en    = boot_ovr_en | hd_ovr_en | vbl_ovr_en;
    wire [15:0] ovr_addr  = hd_ovr_en ? hd_ovr_addr  : vbl_ovr_en ? vbl_ovr_addr  : boot_ovr_addr;
    wire        ovr_rw    = hd_ovr_en ? hd_ovr_rw    : vbl_ovr_en ? vbl_ovr_rw    : 1'b1;
    wire [7:0]  ovr_wdata = hd_ovr_en ? hd_ovr_wdata : vbl_ovr_wdata;
    wire        slot_rd_claim = mb_rd_claim | hd_rd_claim | fd_rd_claim | vidhd_rd_claim;
    wire [7:0]  slot_rd_data  = hd_rd_claim    ? hd_rd_data    :
                                fd_rd_claim    ? fd_rd_data    :
                                vidhd_rd_claim ? vidhd_rd_data : mb_rd_data;

    apple_bus_write u_write (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .phi0_sync     (apple_phi0_sync),
        .data_sync     (apple_data_sync),
        .master_active (cpu_source_active),
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
        .slot_rd_claim (slot_rd_claim),
        .slot_rd_data  (slot_rd_data),
        .din_sub_en    (sub_en),
        .din_sub_data  (sub_data),
        .ovr_en        (ovr_en),
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
    accel_seq u_seq (
        .clk           (apple_clk),
        .rst           (rst_core),
        .cpu_rst       (cpu_rst_core),
        .master_active (cpu_source_active),
        .mode          (accel_mode),
        .target        (accel_target),
        .cnt_clr       (accel_cnt_clr),
        .mem_serve     (mem_serve),
        .mem_image_ready (mem_image_ready),
        .mem_invalidating (mem_invalidating),
        .q_cls         (q_cls),
        .cpu_addr      (cpu_addr),
        .cpu_rw        (cpu_rw),
        .cpu_dout      (cpu_dout),
        .cpu_sync      (cpu_sync),
        .cyc_en        (accel_cyc_en),
        .cpu_din       (accel_din),
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
        .ovr_hold      (boot_ovr_en),
        .bus_owns      (bus_owns),
        .core_valid    (core_valid),
        .mem_sub_en    (mem_sub_en),
        .mem_sub_data  (mem_sub_data),
        .decided       (mem_decided),
        .busy          (mem_busy),
        .mq_valid      (mq_valid),
        .bus_tick      (bus_tick),
        .l1_claim      (l1_claim),
        .ext_cyc_en    (turbo_commit),
        .turbo_commit  (turbo_commit),
        .turbo_addr    (turbo_addr),
        .turbo_data    (turbo_data),
        .turbo_sync    (turbo_sync),
        .turbo_ok      (turbo_ok_seq),
        .op_tick       (accel_op_tick),
        .fev_room      (fev_room),
        .u_present     (u_present),
        .u_commit      (u_commit),
        .u_addr        (u_addr),
        .u_rw          (u_rw),
        .u_wdata       (u_wdata),
        .u_sync        (u_sync),
        .u_ovr         (u_ovr),
        .u_divert      (u_divert),
        .fev_valid     (fev_valid),
        .fev_addr      (fev_addr),
        .fev_rw        (fev_rw),
        .fev_data      (fev_data),
        .fev_sync      (fev_sync),
        .accel_on      (accel_on),
        .held_governor (accel_held),
        .state_o       (seq_state),
        .reset_seq_o   (accel_reset_seq),
        .fast_ops      (accel_fast),
        .bus_ops       (accel_bus),
        .cycles        (accel_cycles),
        .wait_clocks   (accel_wait),
        .retries       (accel_retries),
        .turbo_ops     (accel_turbo_ops)
    );

    // ---- the L1 front -------------------------------------------------------
    // The icache and its TLB, between the core and the sequencer: a fetch
    // both know retires in one clock, and everything else falls through to
    // the sequencer exactly as before.  See rtl/l1_front.sv.
    l1_front u_l1 (
        .clk          (apple_clk),
        .rst          (rst_core),
        .i_addr       (cpu_i_addr),
        .cpu_sync     (cpu_sync),
        .cyc_is_i     (cpu_cyc_is_i),
        .i_steer      (cpu_i_steer),
        .cyc_en       (cpu_cyc_en),
        .cpu_din      (cpu_din),
        .accel_cyc_en (accel_cyc_en),
        .accel_din    (accel_din),
        .turbo_ok     (turbo_ok),
        .l1_claim     (l1_claim),
        .turbo_commit (turbo_commit),
        .turbo_addr   (turbo_addr),
        .turbo_data   (turbo_data),
        .turbo_sync   (turbo_sync),
        .t_page       (tlb_t_page),
        .t_r_ok       (tlb_r_ok),
        .t_r_ppage    (tlb_r_ppage),
        .t_w_ok       (tlb_w_ok),
        .t_w_ppage    (tlb_w_ppage),
        .map_changed  (map_changed),
        .sub_line     (mem_sub_line),
        .sub_line_ok  (mem_sub_line_ok),
        .rom_r2_en    (rom_r2_en),
        .rom_r2_addr  (rom_r2_addr),
        .rom_r2_data  (rom_r2_data),
        .cl_valid     (cl_valid),
        .cl_rw        (cl_rw),
        .cl_wr_image  (cl_wr_image),
        .cl_pa        (cl_pa),
        .snoop2_en    (hd_snoop2_en),
        .snoop2_pa    (hd_snoop2_pa),
        .snoop2_take  (hd_snoop2_take),
        .mem_invalidating (mem_invalidating),
        .rom_ok       (mem_rom_loaded)
    );

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
        .aux_sync      (turbo_commit && turbo_sync),
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
        .vbl_level     (vbl_level),
        .scan_v        (scan_v),
        .scan_h        (scan_h),
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
        .data_sync     (apple_data_sync),
        .sub_en        (pb_sub_en),
        .sub_data      (pb_sub_data),
        .hw_level      (pb_hw)
    );

    // ---- the memory image ---------------------------------------------------
    // The IIe's memory map shadowed, the ROM on the card, and the cache in
    // front of the image in the DDR3: every op the driver presents is
    // classified, and a read of RAM or ROM can be answered from here instead
    // of from the bus - through the same din substitution the keyboard uses,
    // so the capture records what the core read.  Nothing on the bus changes.
    // See docs/MEMORY.md.
    wire        cl_valid, cl_rw, cl_wr_image;
    wire [1:0]  cl_cls;
    wire [23:0] cl_pa;
    wire [13:0] cl_rom_addr;
    wire [7:0]  rom_byte;

    // The MMU shadow follows the unified stream - every op, fast or bus or
    // override - and answers two questions of the address about to be
    // presented: the driver's (divert this write?) and the sequencer's (what
    // class is this op?).
    apple_mmu u_mmu (
        .clk        (apple_clk),
        .rst        (rst_core),
        .res_sync   (apple_res_sync),
        .op_addr    (u_addr),
        .op_rw      (u_rw),
        .op_wdata   (u_wdata),
        .op_present (u_present),
        .op_commit  (u_commit),
        .rom_ok     (mem_rom_loaded),
        .cl_valid   (cl_valid),
        .cl_cls     (cl_cls),
        .cl_pa      (cl_pa),
        .cl_rom_addr (cl_rom_addr),
        .cl_rw      (cl_rw),
        .cl_wr_image (cl_wr_image),
        .intc8rom   (mem_intc8rom),
        .sw_state   (mem_sw),
        .vid_sw     (vid_sw),
        .rw_bank    (mem_rw_bank),
        .q_addr     (nxt_addr),
        .q_divert   (mmu_q_divert),
        .q_rw       (cpu_rw),
        .q_cls      (q_cls),
        .t_page     (tlb_t_page),
        .t_r_ok     (tlb_r_ok),
        .t_r_ppage  (tlb_r_ppage),
        .t_w_ok     (tlb_w_ok),
        .t_w_ppage  (tlb_w_ppage),
        .t2_page    (hd_t2_page),
        .t2_w_ok    (hd_t2_w_ok),
        .t2_w_ppage (hd_t2_w_ppage),
        .map_changed (map_changed)
    );



    apple_rom u_rom (
        .clk        (apple_clk),
        .rst        (rst_core),
        .msg_valid  (app_msg_valid),
        .msg_type   (app_msg_type),
        .msg_len    (app_msg_len),
        .pay_data   (app_pay_data),
        .pay_valid  (app_pay_valid),
        .rd_en      (cl_valid),
        .rd_addr    (cl_rom_addr),
        .rd_data    (rom_byte),
        .r2_en      (rom_r2_en),
        .r2_addr    (rom_r2_addr),
        .r2_data    (rom_r2_data),
        .rom_loaded (mem_rom_loaded)
    );

    mem_cache u_cache (
        .clk         (apple_clk),
        .rst         (rst_core),
        .cl_valid    (cl_valid),
        .cl_cls      (cl_cls),
        .cl_pa       (cl_pa),
        .cl_rw       (cl_rw),
        .cl_wr_image (cl_wr_image),
        .op_addr     (u_addr),
        .op_wdata    (u_wdata),
        .op_present  (u_present),
        .op_commit   (u_commit),
        .op_divert   (u_divert),
        .data_sync   (apple_data_sync),
        .rom_byte    (rom_byte),
        .rom_loaded  (1'b1),            // a ROM-class op always has its byte: the MMU folds the load in
        .sub_en      (mem_sub_en),
        .sub_data    (mem_sub_data),
        .sub_line    (mem_sub_line),
        .sub_line_ok (mem_sub_line_ok),
        .decided     (mem_decided),
        .busy        (mem_busy),
        .serve       (mem_serve),
        .inval       (mem_inval),
        .inv_line_en (hd_inv_en), .inv_line_pa (hd_inv_pa),
        .inv_line_rdy (hd_inv_rdy),
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
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data)
    );

    // ---- the floating bus, simulated ----------------------------------------
    // A side copy of main memory's text and hi-res pages, read at the video
    // scanner's address for the cycle in flight: the byte a floating-bus
    // read would return, without the bus.  Compared with the real byte on
    // every such read; substituted for it when FB_CTRL says so.  See
    // rtl/fb_sim.sv and docs/FLOATING_BUS.md.
    fb_sim u_fb (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .op_addr       (u_addr),
        .op_rw         (u_rw),
        .op_wdata      (u_wdata),
        .op_present    (u_present),
        .op_commit     (u_commit),
        .op_ovr        (u_ovr),
        .cl_valid      (cl_valid),
        .cl_wr_image   (cl_wr_image),
        .cl_pa         (cl_pa),
        .sw_state      (mem_sw),
        .vid_sw        (vid_sw),
        .locked        (vbl_locked),
        .scan_v        (scan_v),
        .scan_h        (scan_h),
        .pal           (vbl_pal),
        .master_active (cpu_source_active),
        .data_sync     (apple_data_sync),
        .slot_rd_claim (slot_rd_claim),
        .kbd_sub_en    (kbd_sub_en),
        .pb_sub_en     (pb_sub_en),
        .serve         (fb_serve),
        .cnt_clr       (fb_cnt_clr),
        .peek_addr     (fb_peek_addr),
        .fb2_we (hd_fb2_we), .fb2_addr (hd_fb2_addr), .fb2_data (hd_fb2_data),
        .fb2_ready (hd_fb2_ready),
        .sub_en        (fb_sub_en),
        .sub_data      (fb_sub_data),
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
    hd_card u_hd (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .cpu_rst       (cpu_rst),
        .res_sync      (apple_res_sync),
        .master_active (cpu_source_active),
        .slot_assign   (hd_slot_active),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .op_present    (op_present),
        .op_commit     (op_commit),
        .op_ovr        (op_ovr),
        .din           (drv_din),
        .ovr_en        (hd_ovr_en),
        .ovr_addr      (hd_ovr_addr),
        .ovr_rw        (hd_ovr_rw),
        .ovr_wdata     (hd_ovr_wdata),
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
        .fast_dma      (hd_fast_dma),
        .map_changed   (map_changed),
        .ev_enabled    (capture_on && capture_real),
        .dq_valid      (hd_dq_valid),
        .dq_line       (hd_dq_line),
        .dq_be         (hd_dq_be),
        .dq_data       (hd_dq_data),
        .dq_ready      (hd_dq_ready),
        .inv_line_en   (hd_inv_en),
        .inv_line_pa   (hd_inv_pa),
        .inv_line_rdy  (hd_inv_rdy),
        .snoop2_en     (hd_snoop2_en),
        .snoop2_pa     (hd_snoop2_pa),
        .snoop2_take   (hd_snoop2_take),
        .t2_page       (hd_t2_page),
        .t2_w_ok       (hd_t2_w_ok),
        .t2_w_ppage    (hd_t2_w_ppage),
        .fb2_we        (hd_fb2_we),
        .fb2_addr      (hd_fb2_addr),
        .fb2_data      (hd_fb2_data),
        .fb2_ready     (hd_fb2_ready),
        .dma_ev_word   (hd_dma_ev_word),
        .dma_ev_valid  (hd_dma_ev_valid),
        .dma_ev_take   (hd_dma_ev_take),
        .rom_loaded    (hd_rom_loaded),
        .busy          (hd_busy),
        .execs         (hd_execs)
    );

    // ---- the floppy ---------------------------------------------------------
    // A Disk II controller and two drives, with the images on the host and
    // one track of each in the card.  See rtl/floppy_card.sv.
    floppy_card u_fd (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .cpu_rst       (cpu_rst),
        .res_sync      (apple_res_sync),
        .master_active (cpu_source_active),
        .slot_assign   (fd_slot_active),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .op_wdata      (op_wdata),
        .op_present    (op_present),
        .op_commit     (op_commit),
        .op_ovr        (op_ovr),
        .op_dummy      (op_dummy),
        .fast_tick     (accel_op_tick),
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
        .drv_nibbles   (fd_nibbles),
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
        .fill_max      (fd_fill_max)
    );

    // ---- the VidHD ----------------------------------------------------------
    // A slot ROM carrying the signature software scans for; the IIgs video
    // registers it then writes go out on the bus unanswered, and the host
    // draws the picture from its mirror of auxiliary memory.  See
    // rtl/vidhd_card.sv and docs/VIDHD.md.
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

    // ---- the Mockingboard ---------------------------------------------------
    // Two VIAs answering for an empty slot; the sound itself is synthesised on
    // the host from the captured VIA writes.  See rtl/mockingboard.sv.
    mockingboard u_mb (
        .clk           (apple_clk),
        .rst           (apple_rst),
        .res_sync      (apple_res_sync),
        .master_active (cpu_source_active),
        .slot_assign   (mb_slot_active),
        .op_addr       (op_addr),
        .op_rw         (op_rw),
        .op_wdata      (op_wdata),
        .op_present    (op_present),
        .op_commit     (op_commit),
        .op_dummy      (op_dummy),
        .fast_tick     (accel_op_tick),
        .rd_claim      (mb_rd_claim),
        .rd_data       (mb_rd_data),
        .irq           (mb_irq)
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
