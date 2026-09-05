`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// boot_tb - a real boot, in simulation: accel_tb's machine (a 128K IIe with a
// language card and a RamWorks on the pins), the REAL 16K IIe ROM, and
// hd_card in its slot with the testbench playing the host - mirroring
// strudelworks-host src/hd_card.cpp (itself AppleWin's Harddisk.cpp) -
// serving blocks out of a real .hdv image.  Reset releases, the Autostart
// ROM scans the slots, finds the SmartPort controller, and the image boots,
// under whatever acceleration MODE/TARGET name.
//
// WHY.  The accel battery proves phases with a DESIGNED program; a boot is
// millions of ops of unchoreographed traffic.  Both D$-era bugs of the old
// acceleration branch passed every directed test and were caught only by
// this bench's ancestor booting real images (docs/BOOT_BENCH.md).  The
// remaining dline rungs are snoop/kill/ordering machinery - exactly that
// species - so the bench exists before rung 2 goes deep.
//
// THE TRACE.  Every clock the core retires (cyc_en), two 32-bit words go to
// TRACEF via $fwrite("%u%u"): {clk32} and {flags8, data8, addr16}, flags
// bit0 = rw, bit1 = sync, bit2 = dline retire, bit3 = turbo retire,
// bit4 = dispatcher fast event, bit5 = bus cycle done.  Bits 2-5 are
// diagnostic; tools/trace_diff.py compares addr/rw/data/sync only, so two
// checkouts' runs diff to the first ARCHITECTURAL divergence.
//
// THE HOST MODEL.  Register writes and EXECUTE reads are mirrored off the
// driver's op stream, exactly as the host decodes them from the capture
// stream (src/hd_card.cpp, register for register); commands run against the
// .hdv (read into himg at t0) and answer with HD_DONE pushed through the
// real ft601_msg_rx, HOST_DELAY clocks after their EXECUTE.  Two updates
// from the config-file-era host: a block WRITE's bytes are captured from
// the reference through the read map at EXECUTE time - the real host reads
// its program-order mirror and never sends HD_FETCH (src/pipeline.cpp) -
// and an HD_DONE's bytes land in the machine by bus DMA through the
// override path, so the reference follows them through the unified stream
// like any other write, with nothing applied by hand.
//
// The card->host direction (HD_DATA) is therefore never exercised: tx_take
// is tied to tx_valid as a sink.  The event merge and the host mirror are
// not modeled either (accel_tb ties ev_room high, and so does this bench);
// rung 3's at-retire event law will want the real merge wired here.
//////////////////////////////////////////////////////////////////////////////////
module boot_tb #(parameter UCODE = "cpu65c02_ucode.hex",
                 parameter ROMF = "rom.hex",            // 16K IIe ROM, xxd -p
                 parameter HDROMF = "hdrom.hex",        // 256B slot ROM
                 parameter HDVF = "hdv.hex",            // the image, xxd -p
                 parameter TRACEF = "boot.trc",
                 parameter integer HDV_BLOCKS = 2880,
                 parameter integer MODE = 2,
                 parameter integer TARGET = 0,          // ACCEL target, 8.8
                 parameter integer HD_SLOT = 7,
                 parameter integer SWINT_DIS = 0,
                 parameter integer HOST_DELAY = 2000,   // clks, EXECUTE->answer
                 parameter integer MAX_CYCLES = 2_000_000,  // bus-cycle advances
                 parameter integer MAX_CLKS = 400_000_000,
                 parameter integer PHI0_HIGH = 49);

    localparam integer T_PRESENT = 2, T_EMIT = 2, T_DIN = 44, T_CYCEN = 45;
    localparam integer PHI0_LOW = 98 - PHI0_HIGH, CYCLE = 98;
    localparam integer BUS_AT = 70;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    integer errors = 0, checks = 0;
    task fail(input string why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask
    task ok(input string what);
        begin $display("ok: %0s", what); checks = checks + 1; end
    endtask

    // ---- phi0 -------------------------------------------------------------------
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end
    reg prev_phi0 = 0;
    wire fall = !phi0 && prev_phi0;
    integer since_fall = 0;
    always @(posedge clk) begin
        prev_phi0 <= phi0;
        if (fall) since_fall <= 0; else since_fall <= since_fall + 1;
    end
    // Bus cycles since t0, for the VBL model and the heartbeat.
    integer bus_cycles = 0;
    always @(posedge clk) if (fall) bus_cycles = bus_cycles + 1;
    // The IIe frame: 17030 cycles, VBL the last 4550.
    wire vbl_active = (bus_cycles % 17030) >= 12480;

    // ---- the reader, the core, the sequencer, the driver ------------------------
    reg  res_n = 1'b1;
    wire cpu_rst = rst || !res_n;
    reg  master_active = 1'b1;
    reg  [7:0]  data_pin = 8'h00;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, driving, drv_sync;
    wire [7:0]  data_drive;
    wire        phi0_sync, res_sync, bus_tick;
    wire [7:0]  data_sync;
    wire        mem_sub_en, bus_owns, core_valid;
    wire [7:0]  mem_sub_data;
    // The cache's byte reaches the driver and the reader only for a bus op.
    wire        kbd_sub_en;
    wire [7:0]  kbd_sub_data;
    wire        sub_en   = (mem_sub_en && bus_owns) || kbd_sub_en;
    wire [7:0]  sub_data = kbd_sub_en ? kbd_sub_data : mem_sub_data;
    wire [15:0] op_addr, nxt_addr;
    wire        op_rw, op_present, op_commit, op_ovr, op_divert, op_dummy, op_inflight, q_divert;
    wire [7:0]  op_wdata;
    wire        drv_cyc_done;
    wire [7:0]  drv_din;

    apple_bus_read u_read (
        .clk (clk), .rst (rst), .enable (1'b1),
        .apple_data_pin (data_pin), .apple_addr_pin (addr_drive), .apple_rw_pin (rw_drive),
        .apple_phi0_pin (phi0), .apple_m2sel_pin (1'b0), .apple_m2b0_pin (1'b0),
        .apple_inh_pin (1'b1), .apple_res_pin (res_n), .apple_irq_pin (1'b1),
        .apple_rdy_pin (1'b1), .apple_dma_pin (!dma_assert),
        .ev_data (), .ev_valid (), .data_tick (bus_tick),
        .sync_override (drv_sync), .sync_override_en (1'b1),
        .data_override (sub_data), .data_override_en (sub_en),
        .rw_override_en (op_divert), .wdata_override (op_wdata), .vbl_level (1'b0),
        .res_sync (res_sync), .irq_sync (), .phi0_sync (phi0_sync),
        .data_sync (data_sync), .phi0_active ()
    );

    wire [15:0] cpu_addr;
    wire        cpu_rw, cpu_sync, cpu_cyc_en, cpu_cyc_is_i;
    wire [15:0] cpu_pc_addr;
    wire [7:0]  cpu_dout, cpu_din, i_din_w, cpu_p_flags;
    wire [15:0] cpu_d_pred;
    wire        cpu_d_pred_v, cpu_d_pred_rw;
    wire [7:0]  d_din_w;
    cpu65c02 #(.UCODE_FILE (UCODE)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .i_din (i_din_w), .d_din (d_din_w),
        .cyc_is_i (cpu_cyc_is_i), .i_addr (), .pc_addr (cpu_pc_addr), .i_pred (), .d_addr (), .d_rw (), .d_dout (),
        .d_pred (cpu_d_pred), .d_pred_v (cpu_d_pred_v), .d_pred_rw (cpu_d_pred_rw),
        .p_flags (cpu_p_flags),
        .irq_n (1'b1), .nmi_n (1'b1), .sync (cpu_sync), .halted ()
    );

    // ACCEL_CTRL, as the host's configuration would set it.
    reg  [1:0]  mode = 2'd0;
    reg  [15:0] target = 16'd0;
    reg         cnt_clr = 1'b0;
    reg         serve = 1'b0, inval = 1'b0;

    // The overrides: the hard disk's and the boot hold's, muxed as in
    // master_top (hd first).
    wire        boot_ovr_en, held, hold_runtime;
    wire [15:0] boot_ovr_addr;
    wire        hd_ovr_en, hd_ovr_rw;
    wire [15:0] hd_ovr_addr;
    wire [7:0]  hd_ovr_wdata;
    wire        ovr_en    = boot_ovr_en | hd_ovr_en;
    wire [15:0] ovr_addr  = hd_ovr_en ? hd_ovr_addr : boot_ovr_addr;
    wire        ovr_rw    = hd_ovr_en ? hd_ovr_rw : 1'b1;
    wire [7:0]  ovr_wdata = hd_ovr_wdata;

    wire        u_present, u_commit, u_rw, u_sync, u_ovr, u_divert;
    wire [15:0] u_addr;
    wire [7:0]  u_wdata;
    wire        fev_valid, fev_rw, fev_sync;
    wire [15:0] fev_addr;
    wire [7:0]  fev_data;
    wire        accel_on, decided, busy, mq_valid_w;
    wire [1:0]  q_cls;
    wire [3:0]  seq_state;
    wire [31:0] fast_ops, bus_ops, cycles, wait_clocks;
    wire [7:0]  retries;
    wire        mem_image_ready, mem_invalidating;

    // The instruction front between the core and the sequencer, as in
    // master_top.
    wire        seq_cyc_en, turbo_en, turbo_ok, turbo_commit, turbo_sync, turbo_claim;
    wire        turbo_tick, tev_valid, tev_sync;
    // The data front between iline and the core, as in master_top.
    wire        iline_cyc_en, d_commit_w, d_claim_w, dline_tick, dev_valid, dev_rw;
    wire        d_pending_w, turbo_wr, dq_rw_w, cl_posted;
    wire        pw_valid_w, pw_aux_w, pw_take_w, pw_ready_w, ws_valid_w, ws_aux_w;
    wire [7:0]  pw_bank_w, pw_data_w, ws_bank_w, cl_wdata;
    wire [15:0] pw_off_w, ws_off_w;
    wire [15:0] dev_addr;
    wire [7:0]  dev_data;
    wire        dl_req_w, dl_aux_w;
    wire [7:0]  dl_bank_w;
    wire [11:0] dl_line_w;
    wire [15:0] dq_addr_w, doff_w;
    wire [1:0]  dcls_w;
    wire        daux_w;
    wire [15:0] tev_addr;
    wire [7:0]  tev_data;
    wire [31:0] turbo_ops;
    wire [1:0]  p_cls;
    wire        p_aux_w, map_changed;
    wire [15:0] p_addr_w, p_off_w;
    wire        il_req, il_aux_w, il_ack, il_ok;
    wire [7:0]  il_bank_w;
    wire [11:0] il_line_w;
    wire [127:0] il_row;
    wire        rom_r2_en, rom_r2_busy;
    wire [11:0] rom_r2_addr;
    wire [31:0] rom_r2_data;

    // ---- the keyboard in the dummies, as master_top gates it (no injection) --
    reg  swint_dis = (SWINT_DIS != 0);
    wire sw_int = accel_on && (mode == 2'd2) && serve && !swint_dis && !held;
    wire        swi_commit, kbd_int_ok;
    wire [7:0]  kbd_int_byte;
    // The on-card slot (the hard disk, docs/CXXX.md "The on-card slots"):
    // master_top's peripheral view, wired the same way here.
    wire        q_slot, seq_slot_q, sl_win, hd_exec_q;
    wire        hd_rd_claim;
    wire [7:0]  hd_rd_data;
    wire        kbd_int_rd = swi_commit && u_rw && !seq_slot_q && (u_addr[15:4] == 12'hC00);
    // ...and the rest of the internalized reads (docs/CXXX.md), as
    // master_top wires them.  No fb_sim here: the machine's floating byte
    // is the model's constant (FLOAT, 8'hA5), and $C019 stays on the bus
    // (no VBL lock in this bench).
    wire        q_swi, q_swi_quiet;
    wire [7:0]  mmu_swi_stat;
    wire [6:0]  kbd_int_low;
    wire [7:0]  swi_byte = seq_slot_q             ? hd_rd_data
                         : (u_addr[7:4] == 4'h0) ? kbd_int_byte
                         : (u_addr[7:4] == 4'h1) ? mmu_swi_stat
                         : 8'hA5;
    wire        sl_present = u_present && seq_slot_q;
    wire        sl_commit  = swi_commit && seq_slot_q;
    wire        p_present  = sl_win ? sl_present : op_present;
    wire        p_commit   = sl_win ? sl_commit  : op_commit;
    wire        p_ovr      = sl_win ? 1'b0       : op_ovr;
    wire [15:0] p_addr     = sl_win ? u_addr     : op_addr;
    wire        p_rw       = sl_win ? u_rw       : op_rw;
    wire [7:0]  p_wdata    = sl_win ? u_wdata    : op_wdata;
    reg         sl_claim_fast = 1'b0;
    always @(posedge clk) begin
        if (rst)                          sl_claim_fast <= 1'b0;
        else if (sl_present)              sl_claim_fast <= 1'b1;
        else if (op_present && !sl_win)   sl_claim_fast <= 1'b0;
    end
    wire        hd_rd_claim_bus = hd_rd_claim && !sl_claim_fast;
    kbd_inject u_kbdi (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .park_kbd (sw_int), .op_dummy (op_dummy),
        .int_rd (kbd_int_rd), .int_ok (kbd_int_ok),
        .int_byte (kbd_int_byte), .int_low (kbd_int_low),
        .press (1'b0), .press_key (7'd0), .drop (1'b0), .lock (1'b0),
        .hotkey_en (1'b0), .hotkey (7'd0), .held (held),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .data_sync (data_sync),
        .sub_en (kbd_sub_en), .sub_data (kbd_sub_data),
        .strobe (), .seen (), .touched (), .pressed (), .taken (),
        .flushed (), .replaced (), .resolved_key (), .changed (),
        .hotkey_hit ()
    );

    accel_seq u_seq (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .master_active (master_active),
        .mode (mode), .target (target), .cnt_clr (cnt_clr),
        .q_swi (q_swi), .q_swi_quiet (q_swi_quiet), .swi_byte (swi_byte), .swi_commit (swi_commit), .fast_tick (), .fev_quiet (),
        .q_slot (q_slot), .slot_q_o (seq_slot_q), .sl_win (sl_win),
        .stall (1'b0),
        .mem_serve (serve), .mem_image_ready (mem_image_ready), .mem_invalidating (mem_invalidating),
        .q_cls (q_cls),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync), .cyc_is_i (cpu_cyc_is_i),
        .cyc_en (seq_cyc_en), .cpu_din (cpu_din),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok),
        .turbo_commit (turbo_commit), .d_commit (d_commit_w),
        .turbo_claim (turbo_claim | d_claim_w),
        .turbo_wr (turbo_wr), .d_pending (d_pending_w),
        .op_present (op_present), .op_commit (op_commit), .op_dummy (op_dummy), .op_ovr (op_ovr),
        .op_divert (op_divert), .op_sync (drv_sync), .op_addr (op_addr), .op_rw (op_rw),
        .op_wdata (op_wdata), .cyc_done (drv_cyc_done), .drv_din (drv_din),
        .op_inflight (op_inflight), .ovr_en (ovr_en),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .mem_sub_en (mem_sub_en), .mem_sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mq_valid (mq_valid_w),
        .bus_tick (bus_tick),
        .u_present (u_present), .u_commit (u_commit), .u_addr (u_addr), .u_rw (u_rw),
        .u_wdata (u_wdata), .u_sync (u_sync), .u_ovr (u_ovr), .u_divert (u_divert),
        .fev_valid (fev_valid), .fev_addr (fev_addr), .fev_rw (fev_rw), .fev_data (fev_data),
        .fev_sync (fev_sync),
        .accel_on (accel_on), .held_governor (), .state_o (seq_state), .reset_seq_o (),
        .fast_ops (fast_ops), .cen_v (), .cen_sel (), .turbo_ops (turbo_ops), .bus_ops (bus_ops),
        .cycles (cycles), .wait_clocks (wait_clocks),
        .retries (retries)
    );

    iline u_iline (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .pc_addr (cpu_pc_addr), .cpu_rw (cpu_rw), .cpu_sync (cpu_sync),
        .cyc_is_i (cpu_cyc_is_i), .p_flags (cpu_p_flags),
        .cyc_en (iline_cyc_en), .i_din (i_din_w),
        .accel_cyc_en (seq_cyc_en), .accel_din (cpu_din),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok), .claim (turbo_claim),
        .turbo_commit (turbo_commit), .turbo_sync (turbo_sync),
        .tick_q (turbo_tick),
        .tev_valid (tev_valid), .tev_addr (tev_addr), .tev_data (tev_data),
        .tev_sync (tev_sync), .ev_room (1'b1),
        .p_addr (p_addr_w), .p_cls (p_cls), .p_aux (p_aux_w), .p_off (p_off_w),
        .rw_bank (rw_bank), .map_changed (map_changed), .intc8rom (intc8rom),
        .il_req (il_req), .il_aux (il_aux_w), .il_bank (il_bank_w), .il_line (il_line_w),
        .il_ack (il_ack && il_req), .il_ok (il_ok), .il_row (il_row),
        .r2_en (rom_r2_en), .r2_addr (rom_r2_addr), .r2_data (rom_r2_data), .r2_busy (rom_r2_busy),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image),
        .cl_aux (cl_aux), .cl_bank (cl_bank), .cl_off (cl_off),
        .ws_valid (ws_valid_w), .ws_aux (ws_aux_w), .ws_bank (ws_bank_w), .ws_off (ws_off_w),
        .serve (serve), .inval (inval)
    );

    // The data front, chained after the instruction front exactly as in
    // master_top.
    dline u_dline (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .d_pred (cpu_d_pred), .d_pred_v (cpu_d_pred_v), .d_pred_rw (cpu_d_pred_rw),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cyc_is_i (cpu_cyc_is_i),
        .il_cyc_en (iline_cyc_en), .accel_din (cpu_din), .i_din (i_din_w),
        .cyc_en (cpu_cyc_en), .d_din (d_din_w),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok), .wr_en (turbo_wr),
        .d_commit (d_commit_w), .claim (d_claim_w), .tick_q (dline_tick), .pending (d_pending_w),
        .dev_valid (dev_valid), .dev_addr (dev_addr), .dev_data (dev_data), .dev_rw (dev_rw),
        .ev_room (1'b1), .ev_room_w (1'b1),
        .altzp (sw_state[3]),
        .dq_addr (dq_addr_w), .dq_rw (dq_rw_w), .d_cls (dcls_w), .d_aux (daux_w), .d_off (doff_w),
        .rw_bank (rw_bank), .map_changed (map_changed),
        .dl_req (dl_req_w), .dl_aux (dl_aux_w), .dl_bank (dl_bank_w), .dl_line (dl_line_w),
        .dl_ack (il_ack && !il_req), .dl_ok (il_ok), .dl_row (il_row),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_posted (cl_posted),
        .cl_aux (cl_aux), .cl_bank (cl_bank), .cl_off (cl_off), .wdata (cl_wdata),
        .pw_valid (pw_valid_w), .pw_aux (pw_aux_w), .pw_bank (pw_bank_w), .pw_off (pw_off_w),
        .pw_data (pw_data_w), .pw_take (pw_take_w),
        .ws_valid (ws_valid_w), .ws_aux (ws_aux_w), .ws_bank (ws_bank_w), .ws_off (ws_off_w),
        .inval (inval),
        .cnt_clr (cnt_clr),
        .cnt_serves (), .cnt_claims (), .cnt_splices (),
        .cnt_cam_serves (), .cnt_lb_serves (), .cnt_posts (), .cnt_post_waits ()
    );

    apple_bus_write #(.T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT), .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)) u_write (
        .clk (clk), .rst (rst), .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active), .park_kbd (sw_int), .park_addr (16'hC000),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync),
        .drv_sync (drv_sync), .cyc_en (drv_cyc_done), .cpu_din (drv_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (hd_rd_claim_bus), .slot_rd_data (hd_rd_data),
        .din_sub_en (sub_en), .din_sub_data (sub_data),
        .ovr_en (ovr_en && !sl_win), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw), .ovr_wdata (ovr_wdata),
        .op_ovr (op_ovr), .op_dummy (op_dummy), .op_inflight (op_inflight),
        .nxt_addr (nxt_addr), .divert (serve && q_divert), .op_divert (op_divert),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    reg arm = 1'b0, release_req = 1'b0, menu_trigger = 1'b0;
    boot_hold u_hold (
        .clk (clk), .cpu_rst (cpu_rst), .master_active (master_active),
        .arm (arm), .release_req (release_req), .menu_trigger (menu_trigger), .hotkey_hit (1'b0),
        .cpu_sync (cpu_sync), .turbo_sync (turbo_sync),
        .op_present (u_present), .op_commit (u_commit), .op_sync (u_sync), .op_ovr (u_ovr),
        .op_addr (u_addr), .op_rw (u_rw), .din (drv_din),
        .ovr_en (boot_ovr_en), .ovr_addr (boot_ovr_addr), .held (held), .runtime (hold_runtime)
    );

    // ---- the memory path, on the unified stream ---------------------------------------
    wire        cl_valid, cl_rw, cl_wr_image, cl_aux, intc8rom;
    wire [1:0]  cl_cls;
    wire [7:0]  cl_bank;
    wire [15:0] cl_off, pf_off;
    wire [11:0] sw_state;
    wire [7:0]  rw_bank;
    wire [7:0]  rom_byte_int;
    wire        rom_loaded, invalidating, image_ready, refresh_ok, rot_ok, mem_idle;
    wire [31:0] hits, misses, served, mismatches, last_mismatch, diverted;
    wire [7:0]  late_fills, fifo_drops;
    reg         msg_valid = 1'b0, pay_valid = 1'b0;
    reg  [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    reg  [31:0] pay_data = 32'd0;
    wire        pq_busy, pq_valid, pq_we, pq_ready, pr_valid;
    wire [19:0] pq_line;
    wire [127:0] pq_wdata, pr_data;
    assign mq_valid_w = 1'b0;           // the page engine has no request queue: busy covers it
    assign mem_image_ready = image_ready;
    assign mem_invalidating = invalidating;

    reg  [7:0] hd_rom [0:255];
    wire [7:0] rom_byte = rom_byte_int;

    apple_mmu u_mmu (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (u_addr), .op_rw (u_rw), .op_wdata (u_wdata),
        .op_present (u_present), .op_commit (u_commit),
        .rom_ok (rom_loaded),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .intc8rom (intc8rom),
        .cl_posted (cl_posted), .cl_wdata (cl_wdata),
        .pw_valid (pw_valid_w), .pw_aux (pw_aux_w), .pw_bank (pw_bank_w), .pw_off (pw_off_w),
        .pw_data (pw_data_w), .pw_ready (pw_ready_w), .pw_take (pw_take_w),
        .pf_off (pf_off),
        .sw_state (sw_state), .vid_sw (), .rw_bank (rw_bank),
        .q_addr (nxt_addr), .q_divert (q_divert), .q_rw (cpu_rw), .q_cls (q_cls),
        .swi_on (sw_int), .swi_kbd_ok (kbd_int_ok), .swi_fb_ok (1'b1),
        .swi_vbl_ok (1'b0), .swi_vbl_bar (1'b1), .swi_kbd_low (kbd_int_low),
        .swi_pb_ok (1'b0), .swi_pdl_ok (1'b0),
        .swi_hd_slot (3'(HD_SLOT)), .swi_fd_slot (3'd0), .swi_mb_slot (3'd0), .q_slot (q_slot),
        .q_swi (q_swi), .q_swi_quiet (q_swi_quiet), .swi_stat_byte (mmu_swi_stat),
        .p_addr (p_addr_w), .p_cls (p_cls), .p_aux (p_aux_w), .p_off (p_off_w),
        .d_addr (dq_addr_w), .d_rw (dq_rw_w),
        .d_cls (dcls_w), .d_aux (daux_w), .d_off (doff_w),
        .map_changed (map_changed)
    );
    apple_rom u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .rd_en (u_present), .rd_addr (u_addr[13:0]), .rd_data (rom_byte_int),
        .r2_en (rom_r2_en), .r2_addr (rom_r2_addr), .r2_data (rom_r2_data), .r2_busy (rom_r2_busy),
        .rom_loaded (rom_loaded)
    );
    page_cache u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_posted (cl_posted),
        .pw_pending (d_pending_w), .pw_ready (pw_ready_w), .pf_off (pf_off),
        .op_addr (u_addr), .op_wdata (cl_wdata),
        .op_present (u_present), .op_commit (u_commit), .op_divert (u_divert), .data_sync (data_sync),
        .rom_byte (rom_byte), .rom_loaded (1'b1),
        .sub_en (mem_sub_en), .sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mw_stb (), .mw_addr (), .mw_byte (),
        .il_req (il_req | dl_req_w), .il_aux (il_req ? il_aux_w : dl_aux_w),
        .il_bank (il_req ? il_bank_w : dl_bank_w), .il_line (il_req ? il_line_w : dl_line_w),
        .il_ack (il_ack), .il_ok (il_ok), .il_row (il_row),
        .serve (serve), .inval (inval), .cnt_clr (1'b0), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (diverted), .late_fills (late_fills), .fifo_drops (fifo_drops),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data)
    );

    wire [1:0]   c_req, c_gnt, c_cyc, c_stb, c_we, c_stall, c_ack;
    wire [47:0]  c_addr;
    wire [255:0] c_data;
    wire [31:0]  c_sel;
    wire [127:0] c_rdata;
    wire         wb_cyc, wb_stb, wb_we, wb_stall, wb_ack;
    wire [23:0]  wb_addr;
    wire [127:0] wb_data, wb_rdata;
    wire [15:0]  wb_sel;
    wire [3:0]   wb_aux, wb_rdata_aux;
    assign c_req[0] = 1'b0; assign c_cyc[0] = 1'b0; assign c_stb[0] = 1'b0; assign c_we[0] = 1'b0;
    assign c_addr[23:0] = 24'd0; assign c_data[127:0] = 128'd0; assign c_sel[15:0] = 16'd0;

    wb_arb #(.N (2), .HAS_PRIO (1'b1)) u_arb (
        .clk (clk), .rst (rst), .rot_ok (rot_ok),
        .c_req (c_req), .c_gnt (c_gnt), .c_cyc (c_cyc), .c_stb (c_stb),
        .c_we (c_we), .c_addr (c_addr), .c_data (c_data), .c_sel (c_sel),
        .c_stall (c_stall), .c_ack (c_ack), .c_rdata (c_rdata),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we), .wb_addr (wb_addr),
        .wb_data (wb_data), .wb_sel (wb_sel), .wb_aux (wb_aux),
        .wb_stall (wb_stall), .wb_ack (wb_ack), .wb_rdata (wb_rdata), .wb_rdata_aux (wb_rdata_aux)
    );
    // The client's cycle position comes from the bus, dummies included.
    page_client u_client (
        .clk (clk), .rst (rst), .calib_complete (1'b1),
        .master_active (master_active), .op_present (op_present),
        .accel (accel_on),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .req (c_req[1]), .gnt (c_gnt[1]), .cyc (c_cyc[1]), .stb (c_stb[1]),
        .we (c_we[1]), .addr (c_addr[47:24]), .data (c_data[255:128]), .sel (c_sel[31:16]),
        .stall (c_stall[1]), .ack (c_ack[1]), .rdata (c_rdata),
        .refresh_ok (refresh_ok), .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

    // ---- the hard disk: the real card, in its slot -------------------------------
    // Host -> card words through the real receiver, as card_link feeds it.
    // The FIFO head is REGISTERED: Verilator's timing scheduler does not
    // reliably re-evaluate a combinational read of a memory a task just
    // wrote, so the head loads through a clocked stage instead (FWFT with a
    // one-clock refill; the receiver simply sees empty between words).
    reg  [31:0] rx_mem [0:4095];
    integer     rx_wr = 0, rx_rd = 0;
    reg  [31:0] rx_head = 32'd0;
    reg         rx_head_v = 1'b0;
    wire [31:0] rx_dout  = rx_head;
    wire        rx_empty = !rx_head_v;
    wire        rx_rd_en;
    always @(posedge clk) begin
        if (rst) begin
            rx_head_v <= 1'b0;
        end else if ((rx_rd_en && rx_head_v) || !rx_head_v) begin
            if (rx_rd < rx_wr) begin
                rx_head <= rx_mem[rx_rd % 4096];
                rx_head_v <= 1'b1;
                rx_rd <= rx_rd + 1;
            end else rx_head_v <= 1'b0;
        end
    end
    task automatic push_word(input [31:0] w);
        begin rx_mem[rx_wr % 4096] = w; rx_wr = rx_wr + 1; end
    endtask
    function automatic [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction
    localparam [7:0] T_HD_ROM = 8'h18, T_HD_DONE = 8'h19, T_HD_FETCH = 8'h1A, T_HD_DATA = 8'h1B;

    wire        hmsg_valid, hpay_valid, unknown_valid;
    wire [7:0]  hmsg_type, hmsg_len;
    wire [15:0] hmsg_free;
    wire [31:0] hpay_data;
    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (hmsg_valid), .msg_type (hmsg_type), .msg_free (hmsg_free),
        .msg_len (hmsg_len), .pay_data (hpay_data), .pay_valid (hpay_valid),
        .unknown_valid (unknown_valid), .unknown_type (unknown_type_w), .unknown_len ()
    );
    wire [7:0] unknown_type_w;
    integer unknowns = 0;
    always @(posedge clk) if (unknown_valid) begin
        unknowns = unknowns + 1;
        if (unknowns <= 5) $display("[%0t] msg_rx: unknown type %02x", $time, unknown_type_w);
    end

    wire [31:0] hd_tx_word;
    wire        hd_tx_valid;
    wire        hd_rom_loaded, hd_busy;
    wire [7:0]  hd_execs;

    hd_card u_hd (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .res_sync (res_sync),
        .master_active (master_active), .slot_assign (3'(HD_SLOT)),
        .op_addr (p_addr), .op_rw (p_rw), .op_present (p_present),
        .op_commit (p_commit), .op_ovr (p_ovr), .din (drv_din),
        .ovr_en (hd_ovr_en), .ovr_addr (hd_ovr_addr), .ovr_rw (hd_ovr_rw),
        .ovr_wdata (hd_ovr_wdata),
        .rd_claim (hd_rd_claim), .rd_data (hd_rd_data),
        .msg_valid (hmsg_valid), .msg_type (hmsg_type), .msg_free (hmsg_free),
        .msg_len (hmsg_len), .pay_data (hpay_data), .pay_valid (hpay_valid),
        .tx_word (hd_tx_word), .tx_valid (hd_tx_valid), .tx_take (hd_tx_valid),
        .rom_loaded (hd_rom_loaded), .busy (hd_busy), .execs (hd_execs), .exec_q (hd_exec_q)
    );

    // ---- the DDR3 stub: the aux region, in order, twelve clocks late ----------------
    // RamWorks banks 0-3, and nothing else: main memory lives in the card's
    // block RAM and the DDR3 never sees it (docs/PAGE_CACHE.md).
    localparam integer NRW = 4;
    localparam integer IMG = NRW * 65536;
    reg [7:0] smem [0:IMG-1];
    localparam integer DL = 64;
    reg [127:0] dl_d [0:DL-1];
    reg [3:0]   dl_aux [0:DL-1];
    integer     dl_time [0:DL-1];
    integer     dl_wp = 0, dl_rp = 0, now = 0, s_cnt = 0;
    reg         wb_ack_r = 0, s_stall = 0;
    reg [127:0] wb_rdata_r = 0;
    reg [3:0]   wb_aux_r = 0;
    integer     ddr_range_bad = 0;
    assign wb_ack = wb_ack_r; assign wb_rdata = wb_rdata_r; assign wb_rdata_aux = wb_aux_r;
    assign wb_stall = s_stall;
    function automatic [19:0] wb_to_byte(input [23:0] a);
        wb_to_byte = {a[22:10], a[6:0]} << 4;
    endfunction
    integer i;
    always @(posedge clk) begin
        now <= now + 1;
        s_cnt <= s_cnt + 1;
        s_stall <= ((s_cnt % 41) < 2);
        wb_ack_r <= 1'b0;
        if (wb_cyc && wb_stb && !wb_stall) begin
            if (wb_addr[9:7] != 3'd0 || wb_addr[23] || wb_addr[22:10] >= 13'(IMG / 2048))
                ddr_range_bad = ddr_range_bad + 1;
            if (wb_we) begin
                for (i = 0; i < 16; i = i + 1)
                    if (wb_sel[i]) smem[wb_to_byte(wb_addr) + i] <= wb_data[8*i +: 8];
                dl_d[dl_wp % DL] <= 128'd0;
            end else begin
                for (i = 0; i < 16; i = i + 1)
                    dl_d[dl_wp % DL][8*i +: 8] <= smem[wb_to_byte(wb_addr) + i];
            end
            dl_aux[dl_wp % DL] <= wb_aux;
            dl_time[dl_wp % DL] <= now + 12;
            dl_wp <= dl_wp + 1;
        end
        if (dl_rp != dl_wp && now >= dl_time[dl_rp % DL] && !wb_ack_r) begin
            wb_ack_r <= 1'b1; wb_rdata_r <= dl_d[dl_rp % DL]; wb_aux_r <= dl_aux[dl_rp % DL];
            dl_rp <= dl_rp + 1;
        end
    end

    // ---- the machine on the pins, and the reference in program order ----------------
    // main_ram / phys_aux / lc_main / phys_lcaux: what the real machine holds,
    // written from the pins.  ref_*: the same memory kept from the unified op
    // stream through the testbench's own switches - what the core must read.
    // The RamWorks exists only in the reference (NRW banks).
    reg [7:0] main_ram   [0:65535];
    reg [7:0] phys_aux   [0:65535];
    reg [7:0] lc_main    [0:16383];
    reg [7:0] phys_lcaux [0:16383];
    reg [7:0] ref_main   [0:65535];
    reg [7:0] ref_aux    [0:NRW*65536-1];
    reg [7:0] ref_lc     [0:16383];
    reg [7:0] ref_lcaux  [0:NRW*16384-1];
    reg [7:0] rom_img    [0:16383];
    reg m_store80, m_ramrd, m_ramwrt, m_altzp, m_page2, m_hires;
    reg m_bank2, m_lcrd, m_wren, m_pre;
    reg m_intcx, m_slotc3, m_intc8;
    reg m_text, m_mixed, m_80col, m_altchar;
    reg [7:0] m_bank;

    function automatic bit m_aux(input [15:0] a, input bit rd);
        if (a < 16'h0200) m_aux = m_altzp;
        else if (m_store80 && a[15:10] == 6'b000001) m_aux = m_page2;
        else if (m_store80 && m_hires && a[15:13] == 3'b001) m_aux = m_page2;
        else m_aux = rd ? m_ramrd : m_ramwrt;
    endfunction
    function automatic integer m_lcidx(input [15:0] a);
        if (a[15:12] == 4'hD) m_lcidx = (m_bank2 ? 4096 : 0) + a[11:0];
        else m_lcidx = 8192 + (a - 16'hE000);
    endfunction
    task m_reset;
        begin
            m_store80 = 0; m_ramrd = 0; m_ramwrt = 0; m_altzp = 0; m_page2 = 0; m_hires = 0;
            m_bank2 = 1; m_lcrd = 0; m_wren = 1; m_pre = 0;
            m_intcx = 0; m_slotc3 = 0; m_intc8 = 0;
            m_text = 1; m_mixed = 0; m_80col = 0; m_altchar = 0;
            m_bank = 0;
        end
    endtask

    localparam [7:0] FLOAT = 8'hA5;
    // What a $C0xx read returns on this machine: the keyboard (no key, ever),
    // the IIe status bits from the model's own switches, quiet buttons, and
    // the float everywhere else.  Deterministic, so two checkouts' runs see
    // identical bytes.
    function automatic [7:0] c0_read(input [7:0] lo);
        begin
            casez (lo)
                8'h0?: c0_read = 8'h00;                       // KBD: no key
                8'h10: c0_read = 8'h00;                       // KBDSTRB: AKD low
                8'h11: c0_read = {m_bank2,   7'd0};           // RDLCBNK2
                8'h12: c0_read = {m_lcrd,    7'd0};           // RDLCRAM
                8'h13: c0_read = {m_ramrd,   7'd0};
                8'h14: c0_read = {m_ramwrt,  7'd0};
                8'h15: c0_read = {m_intcx,   7'd0};
                8'h16: c0_read = {m_altzp,   7'd0};
                8'h17: c0_read = {m_slotc3,  7'd0};
                8'h18: c0_read = {m_store80, 7'd0};
                8'h19: c0_read = {!vbl_active, 7'd0};         // RDVBL: low in VBL
                8'h1A: c0_read = {m_text,    7'd0};
                8'h1B: c0_read = {m_mixed,   7'd0};
                8'h1C: c0_read = {m_page2,   7'd0};
                8'h1D: c0_read = {m_hires,   7'd0};
                8'h1E: c0_read = {m_altchar, 7'd0};
                8'h1F: c0_read = {m_80col,   7'd0};
                8'h6?: c0_read = 8'h00;                       // buttons/paddles: quiet
                8'h7?: c0_read = 8'h00;
                default: c0_read = FLOAT;
            endcase
        end
    endfunction
    // Side effects a $C0xx access has whether read or written.
    task automatic c0_touch(input [7:0] lo);
        begin
            if (lo[7:4] == 4'h5) begin
                case (lo[3:1])
                    3'd0: m_text  <= lo[0];
                    3'd1: m_mixed <= lo[0];
                    3'd2: m_page2 <= lo[0];
                    3'd3: m_hires <= lo[0];
                    default: ;
                endcase
            end
        end
    endtask

    // The machine's side of a synthetic commit: an internalized read or
    // write of a switch moves the model's switches as the pins would have
    // (docs/CXXX.md, "The switch writes"): a write's address is the
    // switch; the language card's A0 = 1 on a WRITE clears prewrite and
    // leaves the enable alone.  INTCXROM/SLOTC3ROM never come this way.
    // ...and only for the I/O page: an on-card slot's ROM page ($C78x, say)
    // retires with a synthetic commit too, and its low byte is no switch.
    always @(posedge clk) if (swi_commit && u_addr[15:8] == 8'hC0) begin
        c0_touch(u_addr[7:0]);
        if (!u_rw && u_addr[7:4] == 4'h0) begin
            case (u_addr[3:1])
                3'd0: m_store80 <= u_addr[0];
                3'd1: m_ramrd   <= u_addr[0];
                3'd2: m_ramwrt  <= u_addr[0];
                3'd4: m_altzp   <= u_addr[0];
                3'd6: m_80col   <= u_addr[0];
                3'd7: m_altchar <= u_addr[0];
                default: ;
            endcase
        end
        if (u_addr[7:4] == 4'h8) begin
            m_bank2 <= !u_addr[3];
            m_lcrd  <= (u_addr[1] == u_addr[0]);
            if (!u_addr[0]) begin m_wren <= 0; m_pre <= 0; end
            else if (u_rw) begin if (m_pre) m_wren <= 1; m_pre <= 1; end
            else m_pre <= 0;
        end
    end

    function automatic [7:0] cx_byte(input [15:0] a);
        logic [3:0] page;
        begin
            page = a[11:8];
            if (page[3])                                     cx_byte = (m_intcx || m_intc8) ? rom_img[a - 16'hC000] : FLOAT;
            else if (m_intcx || (page == 4'd3 && !m_slotc3)) cx_byte = rom_img[a - 16'hC000];
            else if (page[2:0] == 3'(HD_SLOT) && page != 4'd0) cx_byte = hd_rom[a[7:0]];
            else                                             cx_byte = FLOAT;
        end
    endfunction
    function automatic [7:0] exp_read(input [15:0] a);
        begin
            if (a[15:8] == 8'hC0) exp_read = c0_read(a[7:0]);
            else if (a[15:12] == 4'hC) exp_read = cx_byte(a);
            else if (a >= 16'hD000) begin
                if (m_lcrd) exp_read = m_altzp ? ref_lcaux[m_bank * 16384 + m_lcidx(a)] : ref_lc[m_lcidx(a)];
                else        exp_read = rom_img[a - 16'hC000];
            end else exp_read = m_aux(a, 1'b1) ? ref_aux[m_bank * 65536 + a] : ref_main[a];
        end
    endfunction

    // THE MACHINE'S MMU RESETS ON THE BUS SEQUENCE, NOT ON RES' (accel_tb's
    // model, unchanged); the IOU's video switches ride along here.
    integer m_stack_run = 0;
    reg     m_saw_fffc = 1'b0;
    integer m_mmu_resets = 0;
    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        if (rw_drive && addr_drive[15:8] == 8'h01) m_stack_run <= m_stack_run + 1;
        else if (rw_drive && addr_drive == 16'hFFFC && m_stack_run >= 3) begin m_saw_fffc <= 1'b1; m_stack_run <= 0; end
        else if (rw_drive && addr_drive == 16'hFFFD && m_saw_fffc) begin
            m_saw_fffc <= 1'b0; m_mmu_resets <= m_mmu_resets + 1;
            m_store80 <= 0; m_ramrd <= 0; m_ramwrt <= 0; m_altzp <= 0; m_page2 <= 0; m_hires <= 0;
            m_bank2 <= 1; m_lcrd <= 0; m_wren <= 1; m_pre <= 0;
            m_intcx <= 0; m_slotc3 <= 0; m_intc8 <= 0;
            m_text <= 1; m_mixed <= 0; m_80col <= 0; m_altchar <= 0;
            m_bank <= 0;
        end else begin m_stack_run <= 0; m_saw_fffc <= 1'b0; end
    end

    // The pins: the machine answers a read, takes a write, moves its switches.
    // A read the CARD claims arrives with data_oe high - the slot drives the
    // bus - and the machine's RAM stays out of it.
    reg [7:0] mach_byte = 8'h00;
    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        if (rw_drive) begin
            if (data_oe) begin
                data_pin <= data_drive;         // a slot card's claimed read
            end else if (addr_drive[15:8] == 8'hC0) begin
                data_pin <= c0_read(addr_drive[7:0]);
                c0_touch(addr_drive[7:0]);
                if (addr_drive[7:4] == 4'h8) begin
                    m_bank2 <= !addr_drive[3];
                    m_lcrd  <= (addr_drive[1] == addr_drive[0]);
                    if (!addr_drive[0]) begin m_wren <= 0; m_pre <= 0; end
                    else begin if (m_pre) m_wren <= 1; m_pre <= 1; end
                end
            end else if (addr_drive[15:12] == 4'hC) begin
                data_pin <= cx_byte(addr_drive);
            end else if (addr_drive >= 16'hD000) begin
                if (m_lcrd) data_pin <= m_altzp ? phys_lcaux[m_lcidx(addr_drive)] : lc_main[m_lcidx(addr_drive)];
                else        data_pin <= rom_img[addr_drive - 16'hC000];
            end else begin
                data_pin <= m_aux(addr_drive, 1'b1) ? phys_aux[addr_drive] : main_ram[addr_drive];
            end
        end else if (data_oe) begin
            if (addr_drive[15:8] == 8'hC0) begin
                if (addr_drive[7:4] == 4'h0) begin
                    case (addr_drive[3:1])
                        3'd0: m_store80 <= addr_drive[0];
                        3'd1: m_ramrd   <= addr_drive[0];
                        3'd2: m_ramwrt  <= addr_drive[0];
                        3'd3: m_intcx   <= addr_drive[0];
                        3'd4: m_altzp   <= addr_drive[0];
                        3'd5: m_slotc3  <= addr_drive[0];
                        3'd6: m_80col   <= addr_drive[0];
                        3'd7: m_altchar <= addr_drive[0];
                    endcase
                end
                c0_touch(addr_drive[7:0]);
                if (addr_drive[7:0] == 8'h71 || addr_drive[7:0] == 8'h73) begin
                    if (data_drive < NRW) m_bank <= data_drive;
                end
                if (addr_drive[7:4] == 4'h8) begin
                    m_bank2 <= !addr_drive[3];
                    m_lcrd  <= (addr_drive[1] == addr_drive[0]);
                    if (!addr_drive[0]) begin m_wren <= 0; m_pre <= 0; end
                    else m_pre <= 0;
                end
            end else if (addr_drive[15:12] == 4'hC) begin
            end else if (addr_drive >= 16'hD000) begin
                if (m_wren) begin
                    if (m_altzp) phys_lcaux[m_lcidx(addr_drive)] <= data_drive;
                    else         lc_main[m_lcidx(addr_drive)] <= data_drive;
                end
            end else begin
                if (m_aux(addr_drive, 1'b0)) phys_aux[addr_drive] <= data_drive;
                else                         main_ram[addr_drive] <= data_drive;
            end
            data_pin <= data_drive;
        end
    end
    always @(posedge clk) if (since_fall == BUS_AT + 1 && driving) mach_byte <= data_pin;

    // The reference, from the unified stream: every write in program order -
    // the core's, fast or bus, and the hard disk's DMA alike - and the
    // INTC8ROM latch from every $C3xx and $CFFF access.
    always @(posedge clk) if (u_present) begin
        if (u_addr[15:8] == 8'hC3 && !m_slotc3)              m_intc8 <= 1'b1;   // UTAIIe 5-28: INTCXROM does not matter
        if (u_addr == 16'hCFFF)                              m_intc8 <= 1'b0;
        if (!u_rw && u_addr[15:12] != 4'hC) begin
            if (u_addr >= 16'hD000) begin
                if (m_wren) begin
                    if (m_altzp) ref_lcaux[m_bank * 16384 + m_lcidx(u_addr)] <= u_wdata;
                    else         ref_lc[m_lcidx(u_addr)] <= u_wdata;
                end
            end else if (m_aux(u_addr, 1'b0)) ref_aux[m_bank * 65536 + u_addr] <= u_wdata;
            else                              ref_main[u_addr] <= u_wdata;
        end
    end
    // Posted writes (rtl/dline.sv, rung 3) never ride the unified stream:
    // the reference takes them from the data front's event, emitted at the
    // retire - program order, as the host's mirror will see them.
    always @(posedge clk) if (dev_valid && !dev_rw && dev_addr[15:12] != 4'hC) begin
        if (dev_addr >= 16'hD000) begin
            if (m_wren) begin
                if (m_altzp) ref_lcaux[m_bank * 16384 + m_lcidx(dev_addr)] <= dev_data;
                else         ref_lc[m_lcidx(dev_addr)] <= dev_data;
            end
        end else if (m_aux(dev_addr, 1'b0)) ref_aux[m_bank * 65536 + dev_addr] <= dev_data;
        else                                ref_main[dev_addr] <= dev_data;
    end

    // ---- the running checks ---------------------------------------------------------
    integer reads = 0, reads_bad = 0, fast_reads = 0, bus_reads = 0;
    always @(posedge clk) if (u_commit && !swi_commit) begin
        if (u_rw) begin
            reads = reads + 1; bus_reads = bus_reads + 1;
            if (cl_cls == 2'd0 && u_addr[15:8] == 8'hC0) begin
                if (cpu_din !== mach_byte && !u_ovr) begin
                    reads_bad = reads_bad + 1;
                    if (reads_bad <= 20) $display("[%0t] BAD bus read $%04X: core got %02x, the machine said %02x",
                                                  $time, u_addr, cpu_din, mach_byte);
                end
            end else if (!u_ovr && !u_seq.reset_seq && cpu_din !== exp_read(u_addr)) begin
                reads_bad = reads_bad + 1;
                if (reads_bad <= 20) $display("[%0t] BAD bus read $%04X: core got %02x, the reference says %02x (machine %02x, cls %0d)",
                                              $time, u_addr, cpu_din, exp_read(u_addr), mach_byte, cl_cls);
            end
        end
    end
    // A fast read of the hard disk's port is the card's own answer (busy, a
    // status, a size byte) - nothing in the reference models it, and the bus
    // path never checked it either (the pins carried hd_card's byte back):
    // the ROM page IS checked, through cx_byte's hd_rom.
    wire fev_hd_port = (fev_addr[15:4] == {8'hC0, 4'h8 + 4'(HD_SLOT)});
    always @(posedge clk) if (fev_valid && fev_rw) begin
        reads = reads + 1; fast_reads = fast_reads + 1;
        if (!fev_hd_port && fev_data !== exp_read(fev_addr)) begin
            reads_bad = reads_bad + 1;
            if (reads_bad <= 20) $display("[%0t] BAD fast read $%04X: core got %02x, the reference says %02x",
                                          $time, fev_addr, fev_data, exp_read(fev_addr));
        end
    end
    // The instruction front's one-clock ops, against the reference.
    integer turbo_reads = 0;
    always @(posedge clk) if (tev_valid) begin
        reads = reads + 1; turbo_reads = turbo_reads + 1;
        if (tev_data !== exp_read(tev_addr)) begin
            reads_bad = reads_bad + 1;
            if (reads_bad <= 20) $display("[%0t] BAD turbo read $%04X: core got %02x, the reference says %02x",
                                          $time, tev_addr, tev_data, exp_read(tev_addr));
        end
    end
    // The data front's one-clock reads: every byte the reference's, and never
    // $Cxxx - the shadow, the CAM and the last byte serve RAM and LC classes
    // only, and no LC virtual address is in $Cxxx.
    integer dline_reads = 0, dline_bad = 0, dline_writes = 0, drained = 0;
    always @(posedge clk) if (dev_valid) begin
        if (dev_rw) begin
            reads = reads + 1; dline_reads = dline_reads + 1;
            if (dev_data !== exp_read(dev_addr)) begin
                dline_bad = dline_bad + 1; reads_bad = reads_bad + 1;
                if (reads_bad <= 5) $display("    %0t dline read $%04X: core got %02x, the reference says %02x",
                                              $time, dev_addr, dev_data, exp_read(dev_addr));
            end
        end else dline_writes = dline_writes + 1;
        if (dev_addr[15:12] == 4'hC) dline_bad = dline_bad + 1;
    end
    always @(posedge clk) if (cl_valid && cl_posted) drained = drained + 1;

    // ---- the host, mirrored off the driver's op stream ------------------------------
    // strudelworks-host src/hd_card.cpp, register for register.
    localparam [7:0] CMD_BLK_STATUS = 8'h00, CMD_BLK_READ = 8'h01, CMD_BLK_WRITE = 8'h02,
                     CMD_BLK_FORMAT = 8'h03, CMD_SP_STATUS = 8'h80, CMD_SP_READ = 8'h81,
                     CMD_SP_WRITE = 8'h82, CMD_SP_FORMAT = 8'h83, CMD_SP_BUSY = 8'hBF;
    localparam [7:0] ERR_OK = 8'h00, ERR_BADCTL = 8'h21, ERR_IO = 8'h27,
                     ERR_NOTCONN = 8'h28, ERR_NOWRITE = 8'h2B;
    localparam integer UNIT_NONE = -1, UNIT_CTL = -2;
    localparam integer NUM_DEVICES = 1;

    reg [7:0] himg [0:HDV_BLOCKS*512-1];

    reg [7:0]  hm_cmd, hm_unit_num, hm_fifo, hm_sc;
    reg        hm_armed;
    reg [15:0] hm_memblock [0:8];       // 8 = the controller's
    reg [23:0] hm_diskblock [0:8];
    reg [7:0]  hm_uerr [0:8];
    task hm_clear;
        integer k;
        begin
            hm_cmd = 0; hm_fifo = 0; hm_sc = 0; hm_armed = 0;
            hm_unit_num = {1'b0, 3'(HD_SLOT), 4'd0};        // slot << 4
            for (k = 0; k <= 8; k = k + 1) begin
                hm_memblock[k] = 0; hm_diskblock[k] = 0; hm_uerr[k] = 0;
            end
        end
    endtask

    function automatic integer hm_resolve;
        integer slot_from_unit, offset;
        begin
            if ((hm_cmd & 8'h80) == 0) begin
                slot_from_unit = (hm_unit_num >> 4) & 7;
                offset = (slot_from_unit == HD_SLOT) ? 0 : 2;
                hm_resolve = offset + (hm_unit_num >> 7);
            end else if (hm_unit_num > 8) hm_resolve = UNIT_NONE;
            else if (hm_unit_num > NUM_DEVICES) hm_resolve = UNIT_NONE;
            else if (hm_unit_num == 0) hm_resolve = UNIT_CTL;
            else hm_resolve = hm_unit_num - 1;
        end
    endfunction
    function automatic integer hm_ridx;      // unit_regs(): 8 = controller, -1 = none
        integer u;
        begin
            u = hm_resolve();
            if (u == UNIT_NONE) hm_ridx = -1;
            else if (u == UNIT_CTL) hm_ridx = 8;
            else hm_ridx = u;
        end
    endfunction

    task automatic hm_io_write(input [7:0] idx_in, input [7:0] d_in);
        integer r, depth;
        reg [7:0] idx, d;
        begin
            idx = idx_in; d = d_in;
            if (idx >= 8'h2 && idx <= 8'hA) hm_armed = 1;
            r = -2;                                          // -2: not needed
            if (idx != 8'h2 && idx != 8'h3 &&
                !((idx == 8'h9 || idx == 8'hA) && hm_fifo < 2)) begin
                r = hm_ridx();
                if (r < 0) begin
                    depth = (idx == 8'h9) ? 6 : 7;
                    hm_fifo = (hm_fifo + 1) % depth;
                end
            end
            if (r >= -2 && r != -1) begin
            if (idx == 8'h9 || idx == 8'hA) begin
                if (idx == 8'hA && hm_fifo == 0) d = d | 8'h80;
                depth = (idx == 8'h9) ? 6 : 7;
                idx = 8'h2 + hm_fifo;
                hm_fifo = (hm_fifo + 1) % depth;
            end
            case (idx)
                8'h2: hm_cmd = d;
                8'h3: hm_unit_num = d;
                8'h4: if (r >= 0) hm_memblock[r] = {hm_memblock[r][15:8], d};
                8'h5: if (r >= 0) hm_memblock[r] = {d, hm_memblock[r][7:0]};
                8'h6: begin
                    if (hm_cmd != CMD_SP_STATUS) begin
                        if (r >= 0) hm_diskblock[r] = {hm_diskblock[r][23:8], d};
                    end else hm_sc = d;
                end
                8'h7: if (r >= 0) hm_diskblock[r] = {hm_diskblock[r][23:16], d, hm_diskblock[r][7:0]};
                8'h8: if ((hm_cmd & 8'h80) != 0 && r >= 0)
                          hm_diskblock[r] = {d, hm_diskblock[r][15:0]};
                default: ;
            endcase
            if (r >= 0 && (hm_cmd & 8'h80) == 0) hm_diskblock[r] = hm_diskblock[r] & 24'h00FFFF;
            end
        end
    endtask

    // The command queue an EXECUTE snapshots into.  A write command's block
    // is captured HERE, from the reference through the read map - the real
    // host reads its program-order mirror at the EXECUTE's place in the
    // stream (src/pipeline.cpp), and never asks the card.
    localparam integer QN = 64;
    reg [7:0]  q_cmd [0:QN-1];
    reg [7:0]  q_unum [0:QN-1];
    integer    q_unit [0:QN-1];
    reg [7:0]  q_sc [0:QN-1];
    reg [15:0] q_mem [0:QN-1];
    reg [23:0] q_disk [0:QN-1];
    integer    q_at [0:QN-1];
    reg [7:0]  q_blk [0:QN-1][0:511];
    integer    qw = 0, qr = 0;
    integer    host_execs = 0, host_reads = 0, host_writes = 0, host_statuses = 0;

    task automatic hm_io_read0;
        integer u, r, k;
        begin
            if (hm_armed) begin                             // else: a poll
                hm_armed = 0;
                host_execs = host_execs + 1;
                u = hm_resolve();
                q_cmd[qw % QN] = hm_cmd; q_unum[qw % QN] = hm_unit_num;
                q_unit[qw % QN] = u; q_sc[qw % QN] = hm_sc; q_at[qw % QN] = now;
                if (u != UNIT_NONE) begin
                    r = (u == UNIT_CTL) ? 8 : u;
                    q_mem[qw % QN] = hm_memblock[r];
                    q_disk[qw % QN] = hm_diskblock[r];
                    if (hm_cmd == CMD_BLK_WRITE || hm_cmd == CMD_SP_WRITE) begin
                        for (k = 0; k < 512; k = k + 1)
                            q_blk[qw % QN][k] = exp_read(16'(hm_memblock[r] + k));
                    end
                    hm_cmd = (hm_cmd & 8'h80) ? CMD_SP_BUSY : CMD_BLK_STATUS;
                    hm_fifo = 0;
                end
                qw = qw + 1;
            end
        end
    endtask

    // The mirror taps the peripherals' view of the stream - the driver's
    // ops, and the on-card slot ops served fast in the closed regime - as
    // the real host taps the capture (bus words and fast words alike).
    always @(posedge clk) begin
        if (p_present && !p_ovr && !p_rw && p_addr[15:4] == {8'hC0, 4'h8 + 4'(HD_SLOT)})
            hm_io_write(p_addr[3:0], p_wdata);
        if (p_commit && !p_ovr && p_rw && p_addr[15:4] == {8'hC0, 4'h8 + 4'(HD_SLOT)})
            if (p_addr[3:0] == 4'h0) hm_io_read0();
    end
    // RES' drops what the card drops.
    reg res_prev = 1'b1;
    always @(posedge clk) begin
        if (!res_sync && res_prev) begin
            hm_fifo = 0; hm_armed = 0; qr = qw;             // nothing outstanding
        end
        res_prev = res_sync;
    end

    function automatic bit dma_hits_io(input [15:0] a, input integer len);
        integer k;
        begin
            dma_hits_io = 0;
            for (k = 0; k < len; k = k + 256) begin
                if (((a + k) & 16'hF000) == 16'hC000) dma_hits_io = 1;
            end
            if (((a + len - 1) & 16'hF000) == 16'hC000) dma_hits_io = 1;
        end
    endfunction
    function automatic [7:0] status_byte(input [7:0] err);
        status_byte = (err != 0) ? {(err[5:0]), 1'b1} : 8'h00;
    endfunction

    // Building and pushing an answer.  The bytes it carries land in the
    // machine by the card's DMA - bus writes through the override path -
    // so the reference follows them through the unified stream on its own.
    reg [7:0] ans [0:1023];              // data bytes of the completion
    integer   ans_n;
    task automatic push_done(input [7:0] status, input [15:0] addr, input [15:0] size16);
        integer k;
        reg [31:0] w;
        begin
            if (ans_n == 0) push_word(hdr(T_HD_DONE, 8'd0, {8'd0, status}));
            else begin
                push_word(hdr(T_HD_DONE, 8'(2 + (ans_n + 3) / 4), {8'd0, status}));
                push_word({16'(ans_n), addr});
                push_word({16'd0, size16});
                for (k = 0; k < ans_n; k = k + 4) begin
                    w = 32'd0;
                    w[7:0]   = ans[k];
                    if (k + 1 < ans_n) w[15:8]  = ans[k+1];
                    if (k + 2 < ans_n) w[23:16] = ans[k+2];
                    if (k + 3 < ans_n) w[31:24] = ans[k+3];
                    push_word(w);
                end
            end
        end
    endtask
    task automatic id_string(input string s);
        integer k, n;
        begin
            n = s.len() > 16 ? 16 : s.len();
            ans[ans_n] = 8'(n); ans_n = ans_n + 1;
            for (k = 0; k < n; k = k + 1) begin ans[ans_n] = s[k]; ans_n = ans_n + 1; end
            for (k = n; k < 16; k = k + 1) begin ans[ans_n] = 8'h20; ans_n = ans_n + 1; end
        end
    endtask

    integer hd_blocks_read = 0, hd_blocks_written = 0;

    // The host's worker: answers each queued command HOST_DELAY clocks after
    // its EXECUTE, in order - and never while the card is still moving a
    // previous answer's bytes, as the real host spaces its HD_DONEs for
    // exactly that reason (hd_service.cpp: an unspaced one would be dropped).
    task automatic host_serve_one;
        integer u, r, k, base;
        reg [7:0] cmd, sc, err, unum;
        reg [15:0] memblock, size16;
        reg [23:0] diskblock;
        begin
            cmd = q_cmd[qr % QN]; unum = q_unum[qr % QN]; u = q_unit[qr % QN];
            sc = q_sc[qr % QN]; memblock = q_mem[qr % QN]; diskblock = q_disk[qr % QN];
            ans_n = 0;
            size16 = 16'd0;
            if (u >= 0 && u < NUM_DEVICES) size16 = 16'(HDV_BLOCKS);
            if (u == UNIT_NONE) begin
                push_done(status_byte(ERR_NOTCONN), 16'd0, 16'd0);
            end else begin
                r = (u == UNIT_CTL) ? 8 : u;
                err = ERR_OK;
                if (u >= NUM_DEVICES && u != UNIT_CTL &&
                    cmd != CMD_BLK_STATUS && cmd != CMD_SP_STATUS) begin
                    hm_uerr[r] = ERR_NOTCONN;
                    push_done(status_byte(ERR_NOTCONN), 16'd0, 16'd0);
                end else if ((cmd == CMD_SP_READ || cmd == CMD_SP_WRITE) && diskblock > 24'h7FFFFF) begin
                    hm_uerr[r] = ERR_IO;
                    push_done(status_byte(ERR_IO), 16'd0, size16);
                end else begin
                    hm_uerr[r] = ERR_OK;
                    case (cmd)
                        CMD_BLK_STATUS: begin
                            host_statuses = host_statuses + 1;
                            if (u == UNIT_CTL || u >= NUM_DEVICES) err = ERR_IO;
                            push_done(status_byte(err), 16'd0, (u >= 0 && u < NUM_DEVICES) ? size16 : 16'd0);
                            hm_uerr[r] = err;
                        end
                        CMD_SP_BUSY: push_done(status_byte(ERR_OK), 16'd0, size16);
                        CMD_SP_STATUS: begin
                            host_statuses = host_statuses + 1;
                            if (u == UNIT_CTL) begin
                                case (sc)
                                    8'h00, 8'h03: begin
                                        ans[ans_n] = 8'(NUM_DEVICES); ans_n = ans_n + 1;
                                        for (k = 0; k < 7; k = k + 1) begin ans[ans_n] = 0; ans_n = ans_n + 1; end
                                        if (sc == 8'h03) begin
                                            id_string("STRUDELWORKS SP");
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h01; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                        end
                                    end
                                    default: err = ERR_BADCTL;
                                endcase
                            end else begin
                                case (sc)
                                    8'h00, 8'h03: begin
                                        ans[ans_n] = (u < NUM_DEVICES) ? 8'hF8 : 8'hE8; ans_n = ans_n + 1;
                                        ans[ans_n] = (u < NUM_DEVICES) ? 8'(HDV_BLOCKS & 255) : 8'd0; ans_n = ans_n + 1;
                                        ans[ans_n] = (u < NUM_DEVICES) ? 8'((HDV_BLOCKS >> 8) & 255) : 8'd0; ans_n = ans_n + 1;
                                        ans[ans_n] = 8'd0; ans_n = ans_n + 1;
                                        if (sc == 8'h03) begin
                                            id_string($sformatf("STRUDELWORKS D#%0d", unum));
                                            ans[ans_n] = 8'h02; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h20; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h01; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                        end
                                    end
                                    default: err = ERR_BADCTL;
                                endcase
                            end
                            if (err == ERR_OK && dma_hits_io(memblock, ans_n)) err = ERR_BADCTL;
                            if (err != ERR_OK) ans_n = 0;
                            hm_uerr[r] = err;
                            push_done(status_byte(err), memblock, size16);
                        end
                        CMD_BLK_READ, CMD_SP_READ: begin
                            if (diskblock >= HDV_BLOCKS || dma_hits_io(memblock, 512)) begin
                                err = ERR_IO; ans_n = 0;
                            end else begin
                                base = diskblock * 512;
                                for (k = 0; k < 512; k = k + 1) begin ans[k] = himg[base + k]; end
                                ans_n = 512;
                                hd_blocks_read = hd_blocks_read + 1;
                                host_reads = host_reads + 1;
                            end
                            hm_uerr[r] = err;
                            push_done(status_byte(err), memblock, size16);
                        end
                        CMD_BLK_WRITE, CMD_SP_WRITE: begin
                            if (diskblock >= HDV_BLOCKS || dma_hits_io(memblock, 512)) begin
                                hm_uerr[r] = ERR_IO;
                                push_done(status_byte(ERR_IO), 16'd0, size16);
                            end else begin
                                // The block was captured from the mirror at
                                // the EXECUTE; it goes straight to the image.
                                base = diskblock * 512;
                                for (k = 0; k < 512; k = k + 1)
                                    himg[base + k] = q_blk[qr % QN][k];
                                hd_blocks_written = hd_blocks_written + 1;
                                host_writes = host_writes + 1;
                                push_done(status_byte(ERR_OK), 16'd0, size16);
                            end
                        end
                        CMD_BLK_FORMAT, CMD_SP_FORMAT: begin
                            for (k = 0; k < HDV_BLOCKS * 512; k = k + 1) himg[k] = 8'h00;
                            push_done(status_byte(ERR_OK), 16'd0, size16);
                        end
                        default: begin
                            hm_uerr[r] = ERR_IO;
                            push_done(status_byte(ERR_IO), 16'd0, size16);
                        end
                    endcase
                end
            end
            qr = qr + 1;
        end
    endtask

    initial begin : host_pump
        forever begin
            @(posedge clk);
            if (qr < qw && (now - q_at[qr % QN]) >= HOST_DELAY && u_hd.st == u_hd.S_IDLE)
                host_serve_one();
        end
    end

    // ---- the trace --------------------------------------------------------------------
    // The trace starts at the first SYNC after the boot reset releases: the
    // ops before it are the bench's own artifacts - the core free-running
    // against a half-loaded ROM before res_n drops, then the in-reset $0000
    // cycles, whose count and leftover bytes legitimately differ between
    // modes.  The boot proper begins at the reset vector's target, which is
    // the same op in every mode.
    reg boot_go = 1'b0, trace_arm = 1'b0;
    always @(posedge clk) if (boot_go && !cpu_rst && cpu_cyc_en && cpu_sync) trace_arm <= 1'b1;
    wire trace_now = trace_arm || (boot_go && !cpu_rst && cpu_cyc_en && cpu_sync);
    integer tf, trace_ops = 0;
    initial tf = $fopen(TRACEF, "wb");
    always @(posedge clk) if (cpu_cyc_en && trace_now) begin
        $fwrite(tf, "%u%u", now,
                {2'd0, drv_cyc_done, fev_valid, turbo_commit, d_commit_w, cpu_sync, cpu_rw,
                 cpu_rw ? (cpu_cyc_is_i ? i_din_w : d_din_w) : cpu_dout, cpu_addr});
        trace_ops = trace_ops + 1;
    end

    // ---- the heartbeat, and the screen ------------------------------------------------
    reg [15:0] last_sync = 16'd0;
    always @(posedge clk) if (cpu_cyc_en && cpu_sync) last_sync <= cpu_addr;
    always @(posedge clk) if (now % 2_000_000 == 1_999_999)
        $display("    ...%0d clocks, %0d bus cycles, %0d ops (%0d turbo, %0d fast, %0d dline, %0d bus reads), PC~$%04X, execs %0d, blocks r%0d w%0d, bad %0d, mism %0d",
                 now + 1, bus_cycles, trace_ops, turbo_reads, fast_reads, dline_reads, bus_reads,
                 last_sync, host_execs, hd_blocks_read, hd_blocks_written, reads_bad, mismatches);

    task dump_screen;
        integer r, c, base;
        reg [7:0] ch;
        string line;
        begin
            $display("    ---- text page 1 (reference memory) ----");
            for (r = 0; r < 24; r = r + 1) begin
                base = 'h400 + (r % 8) * 'h80 + (r / 8) * 'h28;
                line = "";
                for (c = 0; c < 40; c = c + 1) begin
                    ch = ref_main[base + c] & 8'h7F;
                    if (ch < 8'h20) ch = ch + 8'h40;
                    line = $sformatf("%s%c", line, ch);
                end
                $display("    |%s|", line);
            end
        end
    endtask

    // ---- the image against the reference (accel_tb's compare) -------------------------
    // The card's byte at a main offset: the main bank IS main memory.
    function automatic [7:0] card_main(input [15:0] off);
        card_main = u_cache.u_main.mem[off[15:4]][8 * off[3:0] +: 8];
    endfunction
    // The card's byte at a banked-aux offset: the aux bank if the page is
    // resident for that bank, the DDR3 stub otherwise.
    function automatic [7:0] card_aux(input [7:0] b, input [15:0] off);
        if (u_cache.vld[off[15:8]] && u_cache.tag_bank[off[15:8]] == b)
            card_aux = u_cache.u_aux.mem[off[15:4]][8 * off[3:0] +: 8];
        else
            card_aux = smem[b * 65536 + off];
    endfunction

    task check_image(input string what);
        integer a, b, bad;
        begin
            @(negedge clk);
            while (busy || u_cache.mw_en || u_cache.aw_en || d_pending_w) @(negedge clk);
            bad = 0;
            for (a = 0; a < 16'hC000; a = a + 1) begin
                if (card_main(16'(a)) !== ref_main[a]) begin
                    bad = bad + 1;
                    if (bad <= 8) $display("    IMAGE diff $%04X: image %02x, reference %02x",
                                           a, card_main(16'(a)), ref_main[a]);
                end
                for (b = 0; b < NRW; b = b + 1)
                    if (card_aux(8'(b), 16'(a)) !== ref_aux[b * 65536 + a]) bad = bad + 1;
            end
            // The LC fold: bank 1 of $D000 in the $C000 hole, the rest in place.
            for (a = 0; a < 16384; a = a + 1) begin
                if (card_main(16'hC000 + 16'(a)) !== ref_lc[a]) bad = bad + 1;
                for (b = 0; b < NRW; b = b + 1)
                    if (card_aux(8'(b), 16'hC000 + 16'(a)) !== ref_lcaux[b * 16384 + a]) bad = bad + 1;
            end
            if (bad != 0) fail($sformatf("%0s: %0d image bytes differ from the reference", what, bad));
            else ok(what);
        end
    endtask
    // The machine's memory against the reference: equal only when every
    // write went out on the pins - the mode 0 invariant.
    function automatic integer phys_diff(input bit show);
        integer a, bad;
        begin
            bad = 0;
            for (a = 0; a < 16'hC000; a = a + 1) begin
                if (main_ram[a] !== ref_main[a]) begin
                    bad = bad + 1;
                    if (show && bad <= 5) $display("    main $%04X: machine %02x, reference %02x", a, main_ram[a], ref_main[a]);
                end
                if (phys_aux[a] !== ref_aux[a]) begin
                    bad = bad + 1;
                    if (show && bad <= 5) $display("    aux $%04X: machine %02x, reference %02x", a, phys_aux[a], ref_aux[a]);
                end
            end
            for (a = 0; a < 16384; a = a + 1) begin
                if (lc_main[a] !== ref_lc[a]) begin
                    bad = bad + 1;
                    if (show && bad <= 5) $display("    lc %0d: machine %02x, reference %02x", a, lc_main[a], ref_lc[a]);
                end
                if (phys_lcaux[a] !== ref_lcaux[a]) begin
                    bad = bad + 1;
                    if (show && bad <= 5) $display("    lcaux %0d: machine %02x, reference %02x", a, phys_lcaux[a], ref_lcaux[a]);
                end
            end
            phys_diff = bad;
        end
    endfunction

    // ---- ROM loading helpers ----------------------------------------------------------
    task send_chunk(input integer c);
        integer k;
        begin
            @(negedge clk);
            msg_valid <= 1'b1; msg_type <= 8'h22; msg_len <= 8'd129;
            @(negedge clk);
            msg_valid <= 1'b0; pay_valid <= 1'b1; pay_data <= c;
            @(negedge clk);
            for (k = 0; k < 128; k = k + 1) begin
                pay_data <= {rom_img[c*512 + 4*k + 3], rom_img[c*512 + 4*k + 2],
                             rom_img[c*512 + 4*k + 1], rom_img[c*512 + 4*k]};
                @(negedge clk);
            end
            pay_valid <= 1'b0;
            @(negedge clk);
        end
    endtask

    // ---- the run ----------------------------------------------------------------------
    integer a, c;
    initial begin
        $readmemh(ROMF, rom_img);
        $readmemh(HDROMF, hd_rom);
        $readmemh(HDVF, himg);
        for (a = 0; a < 65536; a = a + 1) begin main_ram[a] = 8'h00; phys_aux[a] = 8'h00; ref_main[a] = 8'h00; end
        for (a = 0; a < NRW * 65536; a = a + 1) ref_aux[a] = 8'h00;
        for (a = 0; a < 16384; a = a + 1) begin lc_main[a] = 8'h00; phys_lcaux[a] = 8'h00; ref_lc[a] = 8'h00; end
        for (a = 0; a < NRW * 16384; a = a + 1) ref_lcaux[a] = 8'h00;
        for (a = 0; a < IMG; a = a + 1) smem[a] = 8'h00;
        for (a = 0; a < 4096; a = a + 1) begin
            u_cache.u_main.mem[a] = 128'd0;        // the banks power up known,
            u_cache.u_aux.mem[a]  = 128'd0;        // as the references do
        end
        m_reset();
        hm_clear();

        $display("boot_tb: MODE %0d TARGET %04x SLOT %0d PHI0_HIGH %0d",
                 MODE, TARGET, HD_SLOT, PHI0_HIGH);
        $display("boot_tb: hdv %0d blocks, host delay %0d clocks, max %0d bus cycles / %0d clocks",
                 HDV_BLOCKS, HOST_DELAY, MAX_CYCLES, MAX_CLKS);

        repeat (5) @(negedge clk);
        rst <= 1'b0;
        @(negedge clk);
        // The motherboard ROM, then the slot ROM, as the host loads them.
        for (c = 0; c < 32; c = c + 1) send_chunk(c);
        if (!rom_loaded) fail("the motherboard ROM did not load");
        push_word(hdr(T_HD_ROM, 8'd64, 16'd0));
        for (c = 0; c < 64; c = c + 1)
            push_word({hd_rom[4*c+3], hd_rom[4*c+2], hd_rom[4*c+1], hd_rom[4*c]});
        c = 0;
        while (!hd_rom_loaded && c < 2000) begin @(posedge clk); c = c + 1; end
        if (!hd_rom_loaded) begin
            fail("the slot ROM did not load");
            $display("    rx_wr %0d rx_rd %0d unknowns %0d", rx_wr, rx_rd, unknowns);
        end
        serve <= 1'b1;
        mode <= 2'(MODE);
        target <= 16'(TARGET);

        // The machine comes out of reset and boots.
        res_n <= 1'b0;
        repeat (5 * CYCLE) @(negedge clk);
        res_n <= 1'b1;
        boot_go <= 1'b1;
        $display("boot_tb: reset released, booting");

        while (now < MAX_CLKS && bus_cycles < MAX_CYCLES) @(posedge clk);

        $display("boot_tb: done at %0d clocks / %0d bus cycles", now, bus_cycles);
        $display("    %0d ops traced; %0d execs (%0d blocks read, %0d written, %0d statuses)",
                 trace_ops, host_execs, hd_blocks_read, hd_blocks_written, host_statuses);
        $display("    reads %0d (%0d turbo, %0d fast, %0d dline); reads_bad %0d; monitor mismatches %0d (last %08x)",
                 reads, turbo_reads, fast_reads, dline_reads, reads_bad, mismatches, last_mismatch);
        $display("    counters: fast_ops %0d turbo_ops %0d bus_ops %0d cycles %0d",
                 fast_ops, turbo_ops, bus_ops, cycles);
        $display("    dline: %0d serves (%0d CAM, %0d last-byte), %0d claims, %0d splices; %0d writes posted (%0d clocks waited, %0d aux misses at the drain, %0d drained)",
                 u_dline.cnt_serves, u_dline.cnt_cam_serves, u_dline.cnt_lb_serves,
                 u_dline.cnt_claims, u_dline.cnt_splices, u_dline.cnt_posts, u_dline.cnt_post_waits,
                 u_cache.cnt_posted_miss, drained);
        $display("    iline: %0d promotes, %0d fill retains, %0d scan prefetches, %0d pinned crossings, %0d CAM serves, %0d zero-stall branches, %0d slow ifetches",
                 u_iline.cnt_promotes, u_iline.cnt_cam_fills, u_iline.cnt_scan_fills,
                 u_iline.cnt_loop_hold, u_iline.cnt_cam_serves, u_iline.cnt_tgt_serves,
                 u_iline.cnt_slow_i);
        if (cycles != 0)
            $display("    measured: %.1f ops per bus cycle",
                     real'(fast_ops + bus_ops + turbo_ops + u_dline.cnt_serves) / real'(cycles));
        $display("    late_fills %0d drops %0d ddr_range_bad %0d", late_fills, fifo_drops, ddr_range_bad);
        dump_screen();
        // Hold the core (the runtime knock) and let everything settle before
        // the compare.
        @(negedge clk); menu_trigger <= 1'b1; @(negedge clk); menu_trigger <= 1'b0;
        c = 0;
        while (!held && c < 40 * CYCLE) begin @(posedge clk); c = c + 1; end
        if (!held) $display("    (the hold did not engage before the compare)");
        repeat (4000) @(negedge clk);
        check_image("the image equals the reference, every bank");
        if (MODE == 0) begin
            if (phys_diff(1) != 0) fail("mode 0: the machine's memory differs from the reference");
            else ok("mode 0: the machine's memory equals the reference");
        end
        if (reads_bad != 0) fail("reads disagreed with the reference");
        if (dline_bad != 0) fail($sformatf("%0d dline serves wrong or out of bounds", dline_bad));
        if (mismatches != 0) fail($sformatf("the monitor counted %0d mismatches (last %08x)", mismatches, last_mismatch));
        if (late_fills != 0 || fifo_drops != 0) fail($sformatf("late fills %0d, drops %0d", late_fills, fifo_drops));
        if (ddr_range_bad != 0) fail($sformatf("%0d DDR3 addresses outside the image", ddr_range_bad));
        if (hd_blocks_read == 0) fail("no block was ever read - the image did not boot");
        else ok($sformatf("%0d blocks read: the image booted", hd_blocks_read));
        if (MODE != 0 && u_dline.cnt_serves == 0) fail("the data front never served a zp/stack read - a wiring failure");
        if (MODE == 2 && u_dline.cnt_posts == 0) fail("mode 2: the data front never retired a write - a wiring failure");
        if (drained > dline_writes || dline_writes - drained > 8) fail($sformatf("%0d writes retired on the front, %0d drained through the classified stage", dline_writes, drained));
        else if (MODE == 2) ok($sformatf("every one of the %0d posted writes drained through the classified stage exactly once", dline_writes));
        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $fclose(tf);
        $finish;
    end

endmodule
