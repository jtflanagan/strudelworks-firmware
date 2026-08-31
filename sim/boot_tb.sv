`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// boot_tb - a real boot, in simulation: the machine of accel_tb (a 128K IIe
// with a language card on the pins), the REAL 16K IIe ROM, and hd_card in
// slot 7 with the testbench playing the host - mirroring strudelworks-host
// src/hd_card.cpp (itself AppleWin's Harddisk.cpp) - serving blocks out of a
// real .hdv image.  Reset releases, the Autostart ROM scans the slots, finds
// the SmartPort controller, and the image boots, under whatever acceleration
// MODE/TARGET name.
//
// WHY.  The accel battery proves phases; it does not boot ProDOS.  The first
// D$ bit failed on hardware on exactly this path (docs/DCACHE_PLAN.md, the
// 2026-08-31 mark), so this bench is the reference: the same boot the
// hardware makes, with accel_tb's program-order reference memory checking
// every byte the core reads, and a per-op trace written to a file so two
// checkouts' runs can be diffed op by op for the first divergence.
//
// THE TRACE.  Every clock the core retires (cpu_cyc_en), two 32-bit words go
// to TRACEF via $fwrite("%u%u"): {clk32} and {flags8, data8, addr16}, flags
// bit0 = rw, bit1 = sync, bit2 = d_commit, bit3 = turbo_commit.  Bits 2-3
// are diagnostic; a cross-checkout diff compares addr/rw/data/sync only.
//
// THE HOST MODEL.  Register writes and EXECUTE reads are mirrored off the
// driver's op stream, exactly as the host decodes them from the capture
// stream; commands run against the .hdv (read into himg at t0) and answer
// with HD_DONE/HD_FETCH pushed through the real ft601_msg_rx, HOST_DELAY
// clocks after their EXECUTE.  A block write DMAs out through HD_FETCH and
// the tb decodes the HD_DATA message off the real msg_arb path.
//////////////////////////////////////////////////////////////////////////////////
module boot_tb #(parameter UCODE = "cpu65c02_ucode.hex",
                 parameter ROMF = "rom.hex",            // 16K IIe ROM, xxd -p
                 parameter HDROMF = "hdrom.hex",        // 256B slot ROM
                 parameter HDVF = "hdv.hex",            // the image, xxd -p
                 parameter TRACEF = "boot.trc",
                 parameter integer HDV_BLOCKS = 2880,
                 parameter integer MODE = 2,
                 parameter integer TARGET = 0,          // ACCEL target, 8.8
                 parameter integer DCACHE_DIS = 0,
                 parameter integer DRAIN_DIS = 0,
                 parameter integer TURBO_DIS = 0,
                 parameter integer CAMD = 1,
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
    wire        sub_en   = mem_sub_en && bus_owns;
    wire [7:0]  sub_data = mem_sub_data;
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
    wire        cpu_rw, cpu_sync, cpu_cyc_en;
    wire [7:0]  cpu_dout, cpu_din;
    wire        cpu_cyc_is_i;
    wire [15:0] cpu_i_pred, cpu_i_addr, cpu_i_steer;
    cpu65c02 #(.UCODE_FILE (UCODE)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .din (cpu_din),
        .irq_n (1'b1), .nmi_n (1'b1), .sync (cpu_sync), .halted (),
        .cyc_is_i (cpu_cyc_is_i), .i_addr (cpu_i_addr), .i_pred (cpu_i_pred),
        .i_steer (cpu_i_steer), .d_addr (), .d_rw (), .d_dout ()
    );

    // ACCEL_CTRL, as the host's configuration would set it.
    reg  [1:0]  mode = 2'd0;
    reg  [15:0] target = 16'd0;
    reg         cnt_clr = 1'b0;
    reg         serve = 1'b0, inval = 1'b0;
    reg         dcache_dis = (DCACHE_DIS != 0);
    reg         turbo_dis  = (TURBO_DIS != 0);

    // The overrides: the boot hold's and the hard disk's, muxed as in
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

    wire        accel_cyc_en, turbo_ok_seq, l1_claim, turbo_commit, turbo_sync;
    // turbo_dis withholds the sequencer's permission, as master_top does.
    wire        turbo_ok = turbo_ok_seq && !turbo_dis;
    wire [7:0]  accel_din, turbo_data;
    wire [15:0] turbo_addr;
    wire [31:0] turbo_ops;
    wire [127:0] mem_sub_line;
    wire         mem_sub_line_ok;
    wire        rom_r2_en;
    wire [11:0] rom_r2_addr;
    wire [31:0] rom_r2_data;
    wire [7:0]  tlb_t_page;
    wire        tlb_r_ok, tlb_w_ok, map_changed;
    wire [16:0] tlb_r_ppage, tlb_w_ppage;

    accel_seq u_seq (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .master_active (master_active),
        .mode (mode), .target (target), .cnt_clr (cnt_clr),
        .mem_serve (serve), .mem_image_ready (mem_image_ready), .mem_invalidating (mem_invalidating),
        .q_cls (q_cls),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync),
        .cyc_en (accel_cyc_en), .cpu_din (accel_din),
        .op_present (op_present), .op_commit (op_commit), .op_dummy (op_dummy), .op_ovr (op_ovr),
        .op_divert (op_divert), .op_sync (drv_sync), .op_addr (op_addr), .op_rw (op_rw),
        .op_wdata (op_wdata), .cyc_done (drv_cyc_done), .drv_din (drv_din),
        .op_inflight (op_inflight), .ovr_en (ovr_en), .ovr_hold (boot_ovr_en),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .mem_sub_en (mem_sub_en), .mem_sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mq_valid (mq_valid_w),
        .bus_tick (bus_tick),
        .l1_claim (l1_claim), .ext_cyc_en (turbo_commit || d_commit),
        .turbo_commit (turbo_commit), .turbo_addr (turbo_addr),
        .turbo_data (turbo_data), .turbo_sync (turbo_sync),
        .turbo_ok (turbo_ok_seq),
        .d_claim (d_claim), .d_commit (d_commit),
        .dev_addr (dev_addr), .dev_rw (dev_rw), .dev_data (dev_data),
        .dev_sync (dev_sync), .d_ok (d_ok), .d_ok_w (d_ok_w),
        .op_tick (), .fev_room (fev_room),
        .u_present (u_present), .u_commit (u_commit), .u_addr (u_addr), .u_rw (u_rw),
        .u_wdata (u_wdata), .u_sync (u_sync), .u_ovr (u_ovr), .u_divert (u_divert),
        .fev_valid (fev_valid), .fev_addr (fev_addr), .fev_rw (fev_rw), .fev_data (fev_data),
        .fev_sync (fev_sync),
        .accel_on (accel_on), .held_governor (), .state_o (seq_state), .reset_seq_o (),
        .fast_ops (fast_ops), .bus_ops (bus_ops), .cycles (cycles), .wait_clocks (wait_clocks),
        .retries (retries), .turbo_ops (turbo_ops)
    );

    l1_front u_l1 (
        .clk (clk), .rst (rst),
        .i_addr (cpu_i_addr), .cpu_sync (cpu_sync),
        .cyc_is_i (cpu_cyc_is_i), .i_steer (cpu_i_steer),
        .cyc_en (l1_cyc_en), .cpu_din (l1_din),
        .accel_cyc_en (accel_cyc_en), .accel_din (accel_din),
        .turbo_ok (turbo_ok), .l1_claim (l1_claim),
        .turbo_commit (turbo_commit), .turbo_addr (turbo_addr),
        .turbo_data (turbo_data), .turbo_sync (turbo_sync),
        .t_page (tlb_t_page), .t_r_ok (tlb_r_ok), .t_r_ppage (tlb_r_ppage),
        .t_w_ok (tlb_w_ok), .t_w_ppage (tlb_w_ppage), .map_changed (map_changed),
        .sub_line (mem_sub_line), .sub_line_ok (mem_sub_line_ok),
        .rom_r2_en (rom_r2_en), .rom_r2_addr (rom_r2_addr), .rom_r2_data (rom_r2_data),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_pa (cl_pa),
        .dsn_en (dsn_en), .dsn_pa (dsn_pa),
        .snoop2_en (hd_snoop2_en), .snoop2_pa (hd_snoop2_pa), .snoop2_take (hd_snoop2_take),
        .mem_invalidating (mem_invalidating), .rom_ok (rom_loaded)
    );

    // The D front and its write-back lines, as in master_top.
    wire        l1_cyc_en, d_hit, d_claim, d_commit, d_ok, d_ok_w;
    wire [7:0]  l1_din, d_byte;
    wire [15:0] dev_addr;
    wire        dev_rw, dev_sync;
    wire [7:0]  dev_data;
    wire [7:0]  t3_page;
    wire        t3_r_ok, t3_w_ok;
    wire [16:0] t3_r_ppage, t3_w_ppage;
    wire        dsn_en;
    wire [23:0] dsn_pa;
    wire [7:0]  dsn_data;
    wire        aw_en, aw_ok;
    wire [23:0] aw_pa;
    wire [7:0]  aw_data;
    wire        wq_valid, wq_ready, winv_en, winv_rdy, inv_rdy;
    wire [19:0] wq_line;
    wire [15:0] wq_be;
    wire [127:0] wq_data;
    wire [23:0] winv_pa;
    wire [3:0]  wb_dirty;
    wire [79:0] wb_lines_flat;
    wire [31:0] wb_flushes, d_ops;
    wire [31:0] zs_vld_w;
    assign cpu_cyc_en = l1_cyc_en || d_hit;
    assign cpu_din    = d_hit ? d_byte : l1_din;

    d_front #(.CAM_D (CAMD != 0)) u_d (
        .clk (clk), .rst (rst),
        .cyc_is_i (cpu_cyc_is_i), .cpu_addr (cpu_addr), .cpu_rw (cpu_rw),
        .cpu_dout (cpu_dout), .cpu_sync (cpu_sync), .g_cyc_en (cpu_cyc_en),
        .d_hit (d_hit), .d_byte (d_byte),
        .d_ok (d_ok), .d_ok_w (d_ok_w),
        .run_rd ((mode != 2'd0) && master_active && serve && !u_seq.reset_seq),
        .run_w  ((mode == 2'd2) && master_active && serve && !u_seq.reset_seq),
        .d_claim (d_claim),
        .d_commit (d_commit), .dev_addr (dev_addr), .dev_rw (dev_rw),
        .dev_data (dev_data), .dev_sync (dev_sync),
        .d_dis (dcache_dis),
        .t3_page (t3_page), .t3_r_ok (t3_r_ok), .t3_r_ppage (t3_r_ppage),
        .t3_w_ok (t3_w_ok), .t3_w_ppage (t3_w_ppage), .map_changed (map_changed),
        .sw_altzp (sw_state[3]),
        .fev_room (fev_room),
        .accel_cyc_en (accel_cyc_en),
        .sub_line (mem_sub_line), .sub_line_ok (mem_sub_line_ok),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image),
        .cl_pa (cl_pa), .cl_wdata (u_wdata),
        .snoop2_en (hd_snoop2_en), .snoop2_pa (hd_snoop2_pa),
        .dsn_en (dsn_en), .dsn_pa (dsn_pa), .dsn_data (dsn_data),
        .aw_en (aw_en), .aw_pa (aw_pa), .aw_data (aw_data), .aw_ok (aw_ok),
        .mem_invalidating (mem_invalidating),
        .hold_lvl (ovr_en),
        .zs_vld_o (zs_vld_w),
        .cnt_clr (cnt_clr), .d_ops (d_ops)
    );

    wb_lines u_wb (
        .clk (clk), .rst (rst),
        .aw_en (aw_en), .aw_pa (aw_pa), .aw_data (aw_data), .aw_ok (aw_ok),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image),
        .cl_pa (cl_pa),
        .snoop2_en (hd_snoop2_en), .snoop2_pa (hd_snoop2_pa),
        .ovr_flush (ovr_en), .mem_invalidating (mem_invalidating),
        .wq_valid (wq_valid), .wq_line (wq_line), .wq_be (wq_be),
        .wq_data (wq_data), .wq_ready (wq_ready),
        .winv_en (winv_en), .winv_pa (winv_pa), .winv_rdy (winv_rdy),
        .wb_dirty (wb_dirty), .wb_lines_flat (wb_lines_flat),
        .flushes (wb_flushes)
    );
    // The shared ports' arbitration: hd_card's drain first on both, the wb
    // flush behind it - master_top's exact muxes.
    wire dq_ready_w;
    assign winv_rdy = inv_rdy && !hd_inv_en;
    assign wq_ready = dq_ready_w && !hd_dq_valid;

    // The event merge, real: fast words and the drain's line words in, the
    // one-per-three-clock drain out, fev_room the write-stall's credit.
    wire fev_room;
    wire [7:0] merge_overflows;
    event_merge #(.DEPTH (16)) u_merge (
        .clk (clk), .rst (rst), .enable (1'b1),
        .bus_valid (1'b0), .bus_data (32'd0), .bus_mark (1'b0),
        .bus_mark_free (16'd0), .bus_dummy (1'b0),
        .fast_valid (fev_valid), .fast_addr (fev_addr), .fast_rw (fev_rw),
        .fast_data (fev_data), .fast_sync (fev_sync),
        .vbl_level (1'b0), .res_level (1'b1),
        .out_valid (), .out_data (), .out_mark (), .out_mark_free (),
        .out_dummy (),
        .overflows (merge_overflows), .fev_room (fev_room),
        .dma_word (hd_dma_ev_word), .dma_valid (hd_dma_ev_valid), .dma_take (hd_dma_ev_take)
    );

    apple_bus_write #(.T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT), .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)) u_write (
        .clk (clk), .rst (rst), .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync),
        .drv_sync (drv_sync), .cyc_en (drv_cyc_done), .cpu_din (drv_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (hd_rd_claim), .slot_rd_data (hd_rd_data),
        .din_sub_en (sub_en), .din_sub_data (sub_data),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw), .ovr_wdata (ovr_wdata),
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
        .cpu_sync (cpu_sync), .aux_sync ((turbo_commit && turbo_sync) || (d_commit && dev_sync)),
        .op_present (u_present), .op_commit (u_commit), .op_sync (u_sync), .op_ovr (u_ovr),
        .op_addr (u_addr), .op_rw (u_rw), .din (drv_din),
        .ovr_en (boot_ovr_en), .ovr_addr (boot_ovr_addr), .held (held), .runtime (hold_runtime)
    );

    // ---- the memory path, on the unified stream ---------------------------------------
    wire        cl_valid, cl_rw, cl_wr_image, intc8rom;
    wire [1:0]  cl_cls;
    wire [23:0] cl_pa;
    wire [13:0] cl_rom_addr;
    wire [11:0] sw_state;
    wire [7:0]  rw_bank;
    wire [7:0]  rom_byte_int;
    wire        rom_loaded, invalidating, image_ready, refresh_ok, rot_ok, mem_idle;
    wire [31:0] hits, misses, served, mismatches, last_mismatch, diverted;
    wire [7:0]  late_fills, fifo_drops;
    reg         msg_valid = 1'b0, pay_valid = 1'b0;
    reg  [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    reg  [31:0] pay_data = 32'd0;
    wire        mq_valid, mq_kind, mq_ready, mr_valid;
    wire [1:0]  mq_id, mr_id;
    wire [19:0] mq_line;
    wire [3:0]  mq_byte;
    wire [7:0]  mq_data;
    wire [127:0] mr_data;
    assign mq_valid_w = mq_valid;
    assign mem_image_ready = image_ready;
    assign mem_invalidating = invalidating;

    localparam [2:0] HD_SLOT = 3'd7;
    reg  [7:0] hd_rom [0:255];
    wire [7:0] rom_byte = rom_byte_int;

    apple_mmu u_mmu (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (u_addr), .op_rw (u_rw), .op_wdata (u_wdata),
        .op_present (u_present), .op_commit (u_commit),
        .rom_ok (rom_loaded),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_pa (cl_pa), .cl_rom_addr (cl_rom_addr),
        .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .intc8rom (intc8rom),
        .sw_state (sw_state), .vid_sw (), .rw_bank (rw_bank),
        .q_addr (nxt_addr), .q_divert (q_divert), .q_rw (cpu_rw), .q_cls (q_cls),
        .t_page (tlb_t_page), .t_r_ok (tlb_r_ok), .t_r_ppage (tlb_r_ppage),
        .t_w_ok (tlb_w_ok), .t_w_ppage (tlb_w_ppage),
        .t2_page (hd_t2_page), .t2_w_ok (hd_t2_w_ok), .t2_w_ppage (hd_t2_w_ppage),
        .t3_page (t3_page), .t3_r_ok (t3_r_ok), .t3_r_ppage (t3_r_ppage),
        .t3_w_ok (t3_w_ok), .t3_w_ppage (t3_w_ppage),
        .map_changed (map_changed)
    );
    apple_rom u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .rd_en (cl_valid), .rd_addr (cl_rom_addr), .rd_data (rom_byte_int),
        .r2_en (rom_r2_en), .r2_addr (rom_r2_addr), .r2_data (rom_r2_data),
        .rom_loaded (rom_loaded)
    );
    mem_cache u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_pa (cl_pa), .cl_rw (cl_rw),
        .cl_wr_image (cl_wr_image), .op_addr (u_addr), .op_wdata (u_wdata),
        .op_present (u_present), .op_commit (u_commit), .op_divert (u_divert), .data_sync (data_sync),
        .rom_byte (rom_byte), .rom_loaded (1'b1),
        .sub_en (mem_sub_en), .sub_data (mem_sub_data),
        .sub_line (mem_sub_line), .sub_line_ok (mem_sub_line_ok),
        .decided (decided), .busy (busy),
        .serve (serve), .inval (inval), .cnt_clr (1'b0), .image_ready (image_ready),
        .inv_line_en (hd_inv_en || winv_en),
        .inv_line_pa (hd_inv_en ? hd_inv_pa : winv_pa),
        .inv_line_rdy (inv_rdy),
        .wb_dirty (wb_dirty), .wb_lines_flat (wb_lines_flat),
        .zs_vld (zs_vld_w),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (diverted), .late_fills (late_fills), .fifo_drops (fifo_drops),
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data)
    );
    wire hd_inv_rdy = inv_rdy;

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
    mem_client u_client (
        .clk (clk), .rst (rst), .calib_complete (1'b1),
        .master_active (master_active), .op_present (op_present),
        .accel (accel_on),
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .dq_valid (hd_dq_valid || wq_valid),
        .dq_line (hd_dq_valid ? hd_dq_line : wq_line),
        .dq_be (hd_dq_valid ? hd_dq_be : wq_be),
        .dq_data (hd_dq_valid ? hd_dq_data : wq_data),
        .dq_ready (dq_ready_w),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data),
        .req (c_req[1]), .gnt (c_gnt[1]), .cyc (c_cyc[1]), .stb (c_stb[1]),
        .we (c_we[1]), .addr (c_addr[47:24]), .data (c_data[255:128]), .sel (c_sel[31:16]),
        .stall (c_stall[1]), .ack (c_ack[1]), .rdata (c_rdata),
        .refresh_ok (refresh_ok), .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );
    wire hd_dq_ready = dq_ready_w;

    // ---- the hard disk: the real card, slot 7 ------------------------------------
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
    wire        hd_tx_valid, hd_tx_take;
    wire        hd_rom_loaded, hd_busy;
    wire [7:0]  hd_execs;
    wire        hd_rd_claim;
    wire [7:0]  hd_rd_data;
    wire        hd_dq_valid, hd_inv_en, hd_snoop2_en, hd_snoop2_take;
    wire [19:0] hd_dq_line;
    wire [15:0] hd_dq_be;
    wire [127:0] hd_dq_data;
    wire [23:0] hd_inv_pa, hd_snoop2_pa;
    wire [7:0]  hd_t2_page;
    wire        hd_t2_w_ok;
    wire [16:0] hd_t2_w_ppage;
    wire [31:0] hd_dma_ev_word;
    wire        hd_dma_ev_valid, hd_dma_ev_take;
    wire        hd_fast_dma = accel_on && (mode == 2'd2) && serve && (DRAIN_DIS == 0);

    hd_card u_hd (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .res_sync (res_sync),
        .master_active (master_active), .slot_assign (HD_SLOT),
        .op_addr (op_addr), .op_rw (op_rw), .op_present (op_present),
        .op_commit (op_commit), .op_ovr (op_ovr), .din (drv_din),
        .ovr_en (hd_ovr_en), .ovr_addr (hd_ovr_addr), .ovr_rw (hd_ovr_rw),
        .ovr_wdata (hd_ovr_wdata),
        .rd_claim (hd_rd_claim), .rd_data (hd_rd_data),
        .msg_valid (hmsg_valid), .msg_type (hmsg_type), .msg_free (hmsg_free),
        .msg_len (hmsg_len), .pay_data (hpay_data), .pay_valid (hpay_valid),
        .tx_word (hd_tx_word), .tx_valid (hd_tx_valid), .tx_take (hd_tx_take),
        .fast_dma (hd_fast_dma), .map_changed (map_changed), .ev_enabled (1'b1),
        .dq_valid (hd_dq_valid), .dq_line (hd_dq_line), .dq_be (hd_dq_be),
        .dq_data (hd_dq_data), .dq_ready (hd_dq_ready),
        .inv_line_en (hd_inv_en), .inv_line_pa (hd_inv_pa), .inv_line_rdy (hd_inv_rdy),
        .snoop2_en (hd_snoop2_en), .snoop2_pa (hd_snoop2_pa), .snoop2_take (hd_snoop2_take),
        .t2_page (hd_t2_page), .t2_w_ok (hd_t2_w_ok), .t2_w_ppage (hd_t2_w_ppage),
        .fb2_we (), .fb2_addr (), .fb2_data (), .fb2_ready (1'b1),
        .dma_ev_word (hd_dma_ev_word), .dma_ev_valid (hd_dma_ev_valid),
        .dma_ev_take (hd_dma_ev_take),
        .rom_loaded (hd_rom_loaded), .busy (hd_busy), .execs (hd_execs)
    );

    // Card -> host (HD_DATA), through the real message master; the tb plays
    // the slave and never stalls.
    wire        mm_cyc, mm_stb, mm_we, mm_stall, mm_ack;
    wire [31:0] mm_adr, mm_dat;
    wire [3:0]  mm_sel;
    reg         mm_ack_r = 1'b0;
    msg_master u_m_hd (
        .clk (clk), .rst (rst), .word (hd_tx_word), .valid (hd_tx_valid), .take (hd_tx_take),
        .cyc (mm_cyc), .stb (mm_stb), .we (mm_we), .adr (mm_adr),
        .dat (mm_dat), .sel (mm_sel), .stall (1'b0), .ack (mm_ack_r)
    );
    always @(posedge clk) mm_ack_r <= !rst && mm_cyc && mm_stb;
    reg [31:0] out_mem [0:1023];
    integer    out_n = 0;
    always @(posedge clk) if (mm_cyc && mm_stb) begin
        out_mem[out_n % 1024] = mm_dat;
        out_n = out_n + 1;
    end

    // ---- the DDR3 stub: the image, in order, twelve clocks late ---------------------
    localparam integer NRW = 4;
    localparam integer IMG = (NRW + 1) * 65536;
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

    function automatic [7:0] cx_byte(input [15:0] a);
        logic [3:0] page;
        begin
            page = a[11:8];
            if (page[3])                                     cx_byte = (m_intcx || m_intc8) ? rom_img[a - 16'hC000] : FLOAT;
            else if (m_intcx || (page == 4'd3 && !m_slotc3)) cx_byte = rom_img[a - 16'hC000];
            else if (page[2:0] == HD_SLOT && page != 4'd0)   cx_byte = hd_rom[a[7:0]];
            else                                             cx_byte = FLOAT;
        end
    endfunction
    function automatic [7:0] exp_read(input [15:0] a);
        begin
            if (a[15:12] == 4'hC) exp_read = cx_byte(a);
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

    // The reference, from the unified stream, and from the D front's events.
    always @(posedge clk) if (u_present) begin
        if (u_addr[15:8] == 8'hC3 && !m_intcx && !m_slotc3) m_intc8 <= 1'b1;
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
    always @(posedge clk) if (fev_valid && !fev_rw && fev_addr[15:12] != 4'hC) begin
        if (fev_addr >= 16'hD000) begin
            if (m_wren) begin
                if (m_altzp) ref_lcaux[m_bank * 16384 + m_lcidx(fev_addr)] <= fev_data;
                else         ref_lc[m_lcidx(fev_addr)] <= fev_data;
            end
        end else if (m_aux(fev_addr, 1'b0)) ref_aux[m_bank * 65536 + fev_addr] <= fev_data;
        else                                ref_main[fev_addr] <= fev_data;
    end

    // ---- the running checks ---------------------------------------------------------
    integer reads = 0, reads_bad = 0, fast_reads = 0, bus_reads = 0;
    always @(posedge clk) if (u_commit) begin
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
    always @(posedge clk) if (fev_valid && fev_rw) begin
        reads = reads + 1; fast_reads = fast_reads + 1;
        if (fev_data !== exp_read(fev_addr)) begin
            reads_bad = reads_bad + 1;
            if (reads_bad <= 20) $display("[%0t] BAD fast read $%04X: core got %02x, the reference says %02x",
                                          $time, fev_addr, fev_data, exp_read(fev_addr));
        end
    end

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
            hm_unit_num = {1'b0, HD_SLOT, 4'd0};        // slot << 4
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

    // The command queue an EXECUTE snapshots into.
    localparam integer QN = 64;
    reg [7:0]  q_cmd [0:QN-1];
    reg [7:0]  q_unum [0:QN-1];
    integer    q_unit [0:QN-1];
    reg [7:0]  q_sc [0:QN-1];
    reg [15:0] q_mem [0:QN-1];
    reg [23:0] q_disk [0:QN-1];
    integer    q_at [0:QN-1];
    integer    qw = 0, qr = 0;
    integer    host_execs = 0, host_reads = 0, host_writes = 0, host_statuses = 0;

    task automatic hm_io_read0;
        integer u, r;
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
                    hm_cmd = (hm_cmd & 8'h80) ? CMD_SP_BUSY : CMD_BLK_STATUS;
                    hm_fifo = 0;
                end
                qw = qw + 1;
            end
        end
    endtask

    // The mirror taps the driver's stream, as the real host taps the capture.
    always @(posedge clk) begin
        if (op_present && !op_ovr && !op_rw && op_addr[15:4] == {8'hC0, 4'h8 + HD_SLOT})
            hm_io_write(op_addr[3:0], op_wdata);
        if (op_commit && !op_ovr && op_rw && op_addr[15:4] == {8'hC0, 4'h8 + HD_SLOT})
            if (op_addr[3:0] == 4'h0) hm_io_read0();
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

    // Building and pushing an answer.
    reg [7:0] ans [0:1023];              // data bytes of the completion
    integer   ans_n;
    task automatic push_done(input [7:0] status, input [15:0] addr, input [15:0] size16);
        integer k;
        reg [31:0] w;
        begin
            // Whatever data rides this completion - a block, a status list -
            // lands in the machine by DMA, so the reference follows it here,
            // through the write view of the switches as they stand.
            for (k = 0; k < ans_n; k = k + 1) ref_apply(16'(addr + k), ans[k]);
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
    // its EXECUTE, in order.  A write fetches through HD_DATA first.
    task automatic host_serve_one;
        integer u, r, k, e, base, hdr_at, scan0;
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
                end else if ((cmd == CMD_SP_READ || cmd == CMD_SP_WRITE) && diskblock > 24'h0FFFFF) begin
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
                                // (push_done applies the block to the reference)
                            end
                            hm_uerr[r] = err;
                            push_done(status_byte(err), memblock, size16);
                        end
                        CMD_BLK_WRITE, CMD_SP_WRITE: begin
                            if (diskblock >= HDV_BLOCKS || dma_hits_io(memblock, 512)) begin
                                hm_uerr[r] = ERR_IO;
                                push_done(status_byte(ERR_IO), 16'd0, size16);
                            end else begin
                                // HD_FETCH, then decode the HD_DATA reply off
                                // the real message path.
                                scan0 = out_n;
                                push_word(hdr(T_HD_FETCH, 8'd1, 16'd0));
                                push_word({16'd512, memblock});
                                hdr_at = -1; e = 0;
                                while (hdr_at < 0 && e < 4_000_000) begin
                                    @(posedge clk); e = e + 1;
                                    for (k = scan0; k < out_n; k = k + 1)
                                        if (out_mem[k % 1024] == {16'd512, T_HD_DATA, 8'd128}) hdr_at = k;
                                    if (hdr_at >= 0 && out_n < hdr_at + 129) hdr_at = -1;
                                end
                                if (hdr_at < 0) begin
                                    fail("host: no HD_DATA for a block write");
                                    push_done(status_byte(ERR_IO), 16'd0, size16);
                                end else begin
                                    base = diskblock * 512;
                                    for (k = 0; k < 512; k = k + 1)
                                        himg[base + k] = out_mem[(hdr_at + 1 + k / 4) % 1024] >> (8 * (k % 4));
                                    hd_blocks_written = hd_blocks_written + 1;
                                    host_writes = host_writes + 1;
                                    push_done(status_byte(ERR_OK), 16'd0, size16);
                                end
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

    // A drained block updates the reference the moment the answer is pushed:
    // the card holds the port busy until the last byte lands, and nothing
    // reads the buffer before then.
    task automatic ref_apply(input [15:0] a, input [7:0] d);
        begin
            if (a[15:12] == 4'hC) ;
            else if (a >= 16'hD000) begin
                if (m_wren) begin
                    if (m_altzp) ref_lcaux[m_bank * 16384 + m_lcidx(a)] = d;
                    else         ref_lc[m_lcidx(a)] = d;
                end
            end else if (m_aux(a, 1'b0)) ref_aux[m_bank * 65536 + a] = d;
            else                         ref_main[a] = d;
        end
    endtask

    initial begin : host_pump
        forever begin
            @(posedge clk);
            if (qr < qw && (now - q_at[qr % QN]) >= HOST_DELAY) host_serve_one();
        end
    end

    // ---- the trace --------------------------------------------------------------------
    integer tf, trace_ops = 0;
    initial tf = $fopen(TRACEF, "wb");
    always @(posedge clk) if (cpu_cyc_en) begin
        $fwrite(tf, "%u%u", now,
                {4'd0, turbo_commit, d_commit, cpu_sync, cpu_rw,
                 cpu_rw ? cpu_din : cpu_dout, cpu_addr});
        trace_ops = trace_ops + 1;
    end

    // ---- the heartbeat, and the screen ------------------------------------------------
    reg [15:0] last_sync = 16'd0;
    always @(posedge clk) if (cpu_cyc_en && cpu_sync) last_sync <= cpu_addr;
    always @(posedge clk) if (now % 10_000_000 == 9_999_999)
        $display("    ...%0d clocks, %0d bus cycles, %0d ops (%0d fast, %0d bus reads), PC~$%04X, execs %0d, blocks r%0d w%0d, bad %0d, mism %0d, aovf %0d",
                 now + 1, bus_cycles, trace_ops, fast_reads, bus_reads, last_sync,
                 host_execs, hd_blocks_read, hd_blocks_written, reads_bad, mismatches, merge_overflows);

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
        m_reset();
        hm_clear();

        $display("boot_tb: MODE %0d TARGET %04x DCACHE_DIS %0d DRAIN_DIS %0d TURBO_DIS %0d CAMD %0d PHI0_HIGH %0d",
                 MODE, TARGET, DCACHE_DIS, DRAIN_DIS, TURBO_DIS, CAMD, PHI0_HIGH);
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
        $display("boot_tb: reset released, booting");

        while (now < MAX_CLKS && bus_cycles < MAX_CYCLES) @(posedge clk);

        $display("boot_tb: done at %0d clocks / %0d bus cycles", now, bus_cycles);
        $display("    %0d ops traced; %0d execs (%0d blocks read, %0d written, %0d statuses)",
                 trace_ops, host_execs, hd_blocks_read, hd_blocks_written, host_statuses);
        $display("    reads %0d (%0d fast); reads_bad %0d; monitor mismatches %0d (last %08x)",
                 reads, fast_reads, reads_bad, mismatches, last_mismatch);
        $display("    late_fills %0d drops %0d merge_overflows %0d wb_flushes %0d d_ops %0d ddr_range_bad %0d",
                 late_fills, fifo_drops, merge_overflows, wb_flushes, d_ops, ddr_range_bad);
        dump_screen();
        if (reads_bad != 0) fail("reads disagreed with the reference");
        if (merge_overflows != 0) fail("the event merge dropped words");
        if (hd_blocks_read == 0) fail("no block was ever read - the image did not boot");
        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $fclose(tf);
        $finish;
    end

endmodule
