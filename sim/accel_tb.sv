`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// accel_tb - the core faster than the bus, on the whole memory path.
//
// sim/mem_integ_tb.sv's machine - a 128K IIe with a language card on the pins,
// a reference RamWorks kept from the ops, a DDR3 stub twelve clocks late -
// with rtl/accel_seq.sv between the real core and the real driver, and the
// boot hold beside it.  The program is sim/accel.s: mem_integ.s plus a walk
// through $C100-$CFFF.
//
// WHAT IS THE TRUTH HERE.  A fast op never reaches the pins, so the machine
// cannot say what its byte should have been.  The testbench keeps its own
// memory in PROGRAM ORDER from the unified op stream - every write, fast or
// bus or override, through its own copy of the IIe's switches - and every read
// the core takes, fast or bus, must equal that: for RAM and the language card
// the reference, for a ROM the file, for $C0xx the byte the machine drove.
// The pins are checked separately: what the machine's own memory holds is
// what mode 1 must keep equal to the reference and mode 2 must not touch.
//
// The phases: mode 0 (must be the old machine: no dummy, no fast op, every
// cyc_en the driver's); mode 1 unlimited; mode 2 unlimited; mode 2 at 4.0 and
// at 1.0 ops per cycle; a DMA's overrides in mode 2; the boot hold at a reset
// and a runtime knock; a reset (the invalidate phase is gone with the page
// cache - see phase 8's note).  Throughout: every dummy is the parked $0000 read, no
// fast op is BUS class, every BUS-class op rode exactly one bus cycle, two
// consecutive BUS ops rode consecutive cycles, no request was dropped.
//////////////////////////////////////////////////////////////////////////////////
module accel_tb #(parameter integer SWINT = 1,
                  parameter UCODE = "cpu65c02_ucode.hex",
                  parameter PROG = "accel.hex",
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
    wire [15:0] op_addr, nxt_addr, op_wdata_w;
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
    // The 65C02 has no bank: the IIe's unified stream is bank zero, which is
    // what a 24-bit map is asked when a IIe asks it (docs/GS.md rung 3).
    wire [7:0]  cpu_bank = 8'd0;
    wire        cpu_rw, cpu_sync, cpu_cyc_en, cpu_cyc_is_i;
    wire [15:0] cpu_pc_addr;
    wire [7:0]  cpu_dout, cpu_din, i_din_w, cpu_p_flags;
    wire [15:0] cpu_d_pred;
    wire        cpu_d_pred_v, cpu_d_pred_rw;
    wire [7:0]  d_din_w;
    // The interrupt line: pulled low by a jittered timer whenever the program
    // has armed it (a write of nonzero to IRQARM = $03FB), released when the
    // ISR acks (a write to ISRA = $03FA).  This puts a Mockingboard-shaped
    // timer IRQ across the accelerated data stream in phase 9 - the one
    // dimension no sim exercised, and where the hardware lock lives.
    reg irq_n_tb = 1'b1;
    wire        prog_wr;
    wire [15:0] prog_waddr;
    wire [7:0]  prog_wdata;
    cpu65c02 #(.UCODE_FILE (UCODE)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .i_din (i_din_w), .d_din (d_din_w),
        .cyc_is_i (cpu_cyc_is_i), .i_addr (), .pc_addr (cpu_pc_addr), .i_pred (), .d_addr (), .d_rw (), .d_dout (),
        .d_pred (cpu_d_pred), .d_pred_v (cpu_d_pred_v), .d_pred_rw (cpu_d_pred_rw),
        .p_flags (cpu_p_flags),
        .irq_n (irq_n_tb), .nmi_n (1'b1), .sync (cpu_sync), .halted ()
    );

    // The IRQ timer, counted in BUS CYCLES so it scales with machine time
    // the way a Mockingboard's 6522 timer does - a period in clocks would
    // drown mode 0 (98 clocks a cycle) in back-to-back ISRs.  A 16-bit LFSR
    // jitters the period so interrupts land on a spread of instruction- and
    // cycle-phases rather than one beat the program could dodge.
    reg         irq_armed = 1'b0;
    reg [15:0]  irq_lfsr = 16'hACE1;
    integer     irq_wait = 80;
    integer     irq_cyc = 0, irq_count = 0, irq_acks = 0;
    always @(posedge clk) begin
        // Arm/disarm and ack ride the unified stream, program order.  A
        // disarm also releases the line, so a fire still pending when the
        // program masks does not hold IRQ' low forever.
        // A write reaches the testbench on the unified stream (a bus op,
        // the dispatcher's) or as the data front's event (a posted write,
        // rtl/dline.sv rung 3) - never both.
        if (prog_wr && prog_waddr == 16'h03FB) begin
            irq_armed <= (prog_wdata != 8'd0);
            if (prog_wdata == 8'd0) irq_n_tb <= 1'b1;
        end
        if (prog_wr && prog_waddr == 16'h03FA) begin
            irq_n_tb <= 1'b1;                       // the ISR acked: release
            irq_acks <= irq_acks + 1;
        end
        if (cpu_rst) begin
            irq_n_tb <= 1'b1; irq_cyc <= 0;
        end else if (fall) begin
            irq_lfsr <= {irq_lfsr[14:0], irq_lfsr[15] ^ irq_lfsr[13] ^ irq_lfsr[12] ^ irq_lfsr[10]};
            if (irq_armed && irq_n_tb) begin
                if (irq_cyc >= irq_wait) begin
                    irq_n_tb <= 1'b0;               // fire: level low until ack
                    irq_count <= irq_count + 1;
                    irq_cyc <= 0;
                    irq_wait <= 40 + (irq_lfsr % 80);   // 40..119 bus cycles, jittered
                end else irq_cyc <= irq_cyc + 1;
            end
        end
    end

    // ACCEL_CTRL, as the testbench drives it.
    reg  [1:0]  mode = 2'd0;
    reg  [15:0] target = 16'd0;
    reg         cnt_clr = 1'b0;
    reg         serve = 1'b0, inval = 1'b0;

    // The overrides: the testbench's DMA and the boot hold.
    reg         tb_ovr_en = 1'b0, tb_ovr_rw = 1'b1;
    reg  [15:0] tb_ovr_addr = 16'd0;
    reg  [7:0]  tb_ovr_wdata = 8'd0;
    wire        boot_ovr_en, held, hold_runtime;
    wire [15:0] boot_ovr_addr;
    wire        ovr_en    = tb_ovr_en | boot_ovr_en;
    wire [15:0] ovr_addr  = tb_ovr_en ? tb_ovr_addr : boot_ovr_addr;
    wire        ovr_rw    = tb_ovr_en ? tb_ovr_rw : 1'b1;
    wire [7:0]  ovr_wdata = tb_ovr_wdata;

    wire        u_present, u_commit, u_rw, u_sync, u_ovr, u_divert;
    wire [15:0] u_addr;
    wire [7:0]  u_bank;
    wire [7:0]  u_wdata;
    wire        fev_valid, fev_rw, fev_sync;
    wire [15:0] fev_addr;
    wire [7:0]  fev_bank;
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
    // L1-D between L1-I and the core, as in a2_top.
    wire        l1i_cyc_en, d_commit_w, d_claim_w, dline_tick, dev_valid, dev_rw;
    wire        d_pending_w, turbo_wr, dq_rw_w, cl_posted;
    wire        pw_valid_w, pw_take_w, pw_ready_w, ws_valid_w;
    wire [7:0]  pw_data_w, cl_wdata;
    wire [15:0] ws_ppn_w;
    wire [7:0]  ws_off8_w;
    // The physical seam (docs/MEMORY_REFACTOR.md, rung 2).
    wire [15:0] pw_ppn_w, cl_ppn_w, d_ppn_w, p_ppn_w, pf_ppn_w;
    wire [7:0]  pw_off_w, rwb_p1_w;
    wire [3:0]  d_reg_w, p_reg_w;
    wire        d_fold_w, p_fold_w, p_fs_w, map_settling;
    wire        d_sh_w;
    wire         op_row_v_w;
    wire         seq_mem_served_w;
    wire [127:0] op_row_w;
    wire [15:0]  op_row_ppn_w;
    wire [103:0] rt_rd_flat;   // NREG * RT_W = 13 * 8 (it was 70 bits: regions 9-12 never revalidated here)
    wire [15:0] dev_addr;
    wire [7:0]  dev_data;
    wire [23:0] dq_addr_w;
    wire [15:0] doff_w;
    wire [1:0]  dcls_w;
    wire        daux_w;
    wire [15:0] tev_addr;
    wire [7:0]  tev_data;
    wire [31:0] turbo_ops;
    wire [1:0]  p_cls;
    wire        p_aux_w, map_changed;
    wire [31:0] accel_maps;   // ACCEL_MAPS: map changes, the revalidation's denominator
    wire [23:0] p_addr_w;
    wire [15:0] p_off_w;
    wire         il_ack, il_done, il_ok;      // the line port: unused since rung 5
    wire [127:0] il_row;
    // L1-D's seams to the TLB and the shared direct way read (rung 5).
    wire        lb_hit_w, fj_v_w, fj_fold_w, fj_ack_w;
    wire [7:0]  lb_vpage_w, fj_vpage_w;
    wire [15:0] lb_ppn_w, fj_ppn_w;
    wire [6-1:0] lb_set_w, fj_set_w, dr_set_d, dr_set_i;
    wire [3-1:0]  lb_way_w, fj_way_w, dr_way_d, dr_way_i;
    wire [3:0]  fj_reg_w, dr_line_d, dr_line_i;
    wire        dr_req_d, dr_req_i, dr_ack_d, dr_ack_i, dr_done_d, dr_done_i;
    // The TLB's and the direct way read's seams (rung 4).
    wire        la_hit_w, fi_v_w, fi_busy_w, fi_fold_w, kill_v_w;
    wire [7:0]  la_vpage_w, fi_vpage_w;
    wire [15:0] la_ppn_w, fi_ppn_w, kill_ppn_w, op_place_ppn_w;
    wire [6-1:0] la_set_w, fi_set_w, op_place_set_w, evict_set_w, ref_set_w, dr_set_w;
    wire [3-1:0]  la_way_w, fi_way_w, op_place_way_w, evict_way_w, ref_way_w, dr_way_w;
    wire [3:0]  fi_reg_w, dr_line_w;
    wire        op_place_v_w, evict_v_w, ref_v_w, ref_on_w, dr_req_w, dr_ack_w, dr_done_w;
    wire [127:0] dr_row_w;
    wire [31:0] tlb_fills_w, tlb_deaths_w;

    // ---- the keyboard in the dummies, as master_top gates it -----------------
    // SWINT = 0 is the chicken bit: dummies park at $0000, $C00x rides the bus.
    reg  swint_dis = (SWINT == 0);
    wire sw_int = accel_on && (mode == 2'd2) && serve && !swint_dis && !held;
    wire        swi_commit, kbd_int_ok;
    wire [7:0]  kbd_int_byte;
    wire        kbd_int_rd = swi_commit && u_rw && (u_addr[15:4] == 12'hC00);
    // ...and the rest of the internalized reads (docs/CXXX.md), as
    // master_top wires them.  No fb_sim here: the machine's floating byte
    // is the model's constant (FLOAT, 8'hA5), and $C019 stays on the bus
    // (no VBL lock in this bench).
    wire        q_swi, q_swi_quiet;
    wire [7:0]  mmu_swi_stat;
    wire [6:0]  kbd_int_low;
    wire [7:0]  swi_byte = (u_addr[7:4] == 4'h0) ? kbd_int_byte
                         : (u_addr[7:4] == 4'h1) ? mmu_swi_stat
                         : (u_addr[7:4] == 4'h6) ? game_int_byte
                         : 8'hA5;
    // ---- the game port in the dummies, as master_top wires it ----------------
    // The loop rides the same level as the keyboard's (no chicken bit of its
    // own here); the core's clock is every tick the beam keeps time by; a
    // $C07x access of the core's own - served, or a write on the bus - is
    // the strobe for the virtual timers.  The low bits of a served byte are
    // the model's floating constant, as fb_sim's would be.
    wire        seq_fast_tick;
    wire [15:0] game_park_addr;
    wire        game_pb_ok, game_pdl_ok;
    wire [7:0]  game_int_byte;
    wire [2:0]  game_pb;
    wire [11:0] game_pdl0, game_pdl1, game_pdl2, game_pdl3;
    wire [7:0]  game_meas;
    wire        game_strobe = (swi_commit && (u_addr[15:4] == 12'hC07)) ||
                              (op_commit && !op_dummy && !op_ovr && !op_rw && (op_addr[15:4] == 12'hC07));
    game_port u_game (
        .clk (clk), .rst (rst), .master_active (master_active),
        .park (sw_int),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit), .op_dummy (op_dummy),
        .data_sync (data_sync), .bus_tick (bus_tick),
        .park_addr (game_park_addr),
        .pb_ok (game_pb_ok), .pdl_ok (game_pdl_ok), .pb_sel (6'd0),
        .core_tick (seq_fast_tick || turbo_tick || dline_tick || (bus_tick && !op_dummy && !op_ovr)),
        .strobe (game_strobe), .u_addr (u_addr), .low_bits (7'h25),
        .int_byte (game_int_byte),
        .pb_level (game_pb), .pdl0 (game_pdl0), .pdl1 (game_pdl1), .pdl2 (game_pdl2), .pdl3 (game_pdl3),
        .measurements (game_meas)
    );
    reg        kb_press = 1'b0, kb_drop = 1'b0, kb_lock = 1'b0;
    reg [6:0]  kb_key = 7'd0;
    wire       kb_strobe, kb_seen, kb_touched, kb_changed, kb_hot;
    wire [7:0] kb_pressed, kb_taken, kb_flushed, kb_replaced;
    wire [6:0] kb_resolved;
    kbd_inject u_kbdi (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .park_kbd (sw_int), .op_dummy (op_dummy),
        .int_rd (kbd_int_rd), .int_ok (kbd_int_ok),
        .int_byte (kbd_int_byte), .int_low (kbd_int_low),
        .press (kb_press), .press_key (kb_key), .drop (kb_drop), .lock (kb_lock),
        .hotkey_en (1'b0), .hotkey (7'd0), .held (held),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .data_sync (data_sync),
        .sub_en (kbd_sub_en), .sub_data (kbd_sub_data),
        .strobe (kb_strobe), .seen (kb_seen), .touched (kb_touched),
        .pressed (kb_pressed), .taken (kb_taken), .flushed (kb_flushed),
        .replaced (kb_replaced), .resolved_key (kb_resolved),
        .changed (kb_changed), .hotkey_hit (kb_hot)
    );

    // The census's counters, as the register file keeps them.
    wire        cen_v;
    wire [2:0]  cen_sel;
    wire [31:0] cs_i, cs_dram, cs_dlc, cs_drom, cs_dcx, cs_wr, cs_kbd;
    fast_census u_census (
        .clk (clk), .rst (rst), .clr (cnt_clr), .v (cen_v), .sel (cen_sel),
        .fast_i (cs_i), .fast_dram (cs_dram), .fast_dlc (cs_dlc), .fast_drom (cs_drom),
        .fast_dcx (cs_dcx), .fast_wr (cs_wr), .fast_kbd (cs_kbd)
    );

    accel_seq u_seq (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .master_active (master_active),
        .mode (mode), .target (target), .cnt_clr (cnt_clr),
        .q_swi (q_swi), .q_swi_quiet (q_swi_quiet), .swi_byte (swi_byte), .swi_commit (swi_commit), .fast_tick (seq_fast_tick), .mem_served (seq_mem_served_w), .fev_quiet (),
        .q_slot (1'b0), .slot_q_o (), .sl_win (),
        .stall (1'b0),
        .mem_serve (serve), .mem_image_ready (mem_image_ready), .mem_invalidating (mem_invalidating),
        .q_cls (q_cls),
        .cpu_addr (cpu_addr), .cpu_bank (cpu_bank), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync), .cyc_is_i (cpu_cyc_is_i),
        .cyc_int (1'b0),   // a 65C02 has no internal cycle: rtl/accel_seq.sv
        .cyc_en (seq_cyc_en), .cpu_din (cpu_din),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok),
        .turbo_commit (turbo_commit), .d_commit (d_commit_w),
        .turbo_claim (turbo_claim | d_claim_w),
        .turbo_wr (turbo_wr), .d_pending (d_pending_w),
        .op_present (op_present), .op_commit (op_commit), .op_dummy (op_dummy), .op_ovr (op_ovr),
        .op_divert (op_divert), .op_sync (drv_sync), .op_addr (op_addr), .op_rw (op_rw),
        .op_wdata (op_wdata), .cyc_done (drv_cyc_done), .drv_din (drv_din),
        .op_inflight (op_inflight), .ovr_en (ovr_en), .ovr_bank (8'd0),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .mem_sub_en (mem_sub_en), .mem_sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mq_valid (mq_valid_w),
        .bus_tick (bus_tick),
        .u_present (u_present), .u_commit (u_commit), .u_addr (u_addr), .u_bank (u_bank), .u_rw (u_rw),
        .u_wdata (u_wdata), .u_sync (u_sync), .u_ovr (u_ovr), .u_divert (u_divert),
        .fev_valid (fev_valid), .fev_addr (fev_addr), .fev_bank (fev_bank), .fev_rw (fev_rw), .fev_data (fev_data),
        .fev_sync (fev_sync),
        .accel_on (accel_on), .held_governor (), .state_o (seq_state), .reset_seq_o (),
        .fast_ops (fast_ops), .map_changed (map_changed), .map_settling (map_settling), .maps (accel_maps), .cen_v (cen_v), .cen_sel (cen_sel), .turbo_ops (turbo_ops), .bus_ops (bus_ops),
        .cycles (cycles), .wait_clocks (wait_clocks),
        .retries (retries),
        .l1_dis (1'b0)
    );

    // ---- L1-I -----------------------------------------------------------------
    // Two line buffers filled by DIRECT WAY READS of the page cache through
    // the TLB (rtl/a2/l1i.sv, rtl/a2/tlb.sv, docs/L1_RETHINK.md): a fetch
    // that lands in them retires in one clock.
    l1i #(.SIDX (6), .LEV (3)) u_l1i (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .pc_addr (cpu_pc_addr), .cpu_rw (cpu_rw), .cpu_sync (cpu_sync),
        .cyc_is_i (cpu_cyc_is_i), .p_flags (cpu_p_flags),
        .cyc_en (l1i_cyc_en), .i_din (i_din_w),
        .accel_cyc_en (seq_cyc_en), .accel_din (cpu_din),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok), .claim (turbo_claim),
        .turbo_commit (turbo_commit), .turbo_sync (turbo_sync), .tick_q (turbo_tick),
        .tev_valid (tev_valid), .tev_addr (tev_addr), .tev_data (tev_data), .tev_sync (tev_sync),
        .ev_room (1'b1),
        .p_addr (p_addr_w), .p_ppn (p_ppn_w), .p_reg (p_reg_w), .p_fold (p_fold_w), .p_fs (p_fs_w),
        .map_changed (map_changed), .map_settling (map_settling), .intc8rom (intc8rom),
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
        .serve (serve), .inval (inval),
        .dbg_sel (4'd0), .dbg_val (), .fill_busy ()
    );
    // The TLB: eight pages, each naming the set and way L2 holds it in.
    tlb #(.SIDX (6), .LEV (3), .N (8)) u_tlb (
        .clk (clk), .rst (rst), .serve (serve), .inval (inval),
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

    // L1-D, chained after L1-I exactly as in a2_top: its cyc_en is the
    // core's, its byte is d_din, its books ride the sequencer's d_commit, and
    // the line port is its alone.
    // ---- L1-D -----------------------------------------------------------------
    // The shadow, the last row and the last byte at one clock; every other
    // read a TLB hit serves from the page cache's row at three clocks
    // (rtl/a2/l1d.sv).  Its cyc_en is the core's, its byte is d_din, its
    // books ride the sequencer's d_commit.
    l1d #(.SIDX (6), .LEV (3)) u_l1d (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .d_pred (cpu_d_pred[15:0]), .d_pred_v (cpu_d_pred_v), .d_pred_rw (cpu_d_pred_rw),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cyc_is_i (cpu_cyc_is_i),
        .il_cyc_en (l1i_cyc_en), .seq_cyc_en (seq_cyc_en), .accel_din (cpu_din), .i_din (i_din_w),
        .cyc_en (cpu_cyc_en), .d_din (d_din_w),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok), .wr_en (turbo_wr),
        .d_commit (d_commit_w), .claim (d_claim_w), .tick_q (dline_tick), .pending (d_pending_w),
        .dev_valid (dev_valid), .dev_addr (dev_addr), .dev_data (dev_data), .dev_rw (dev_rw),
        .ev_room (1'b1), .ev_room_w (ev_room_w_tb),
        .altzp (sw_state[3]),
        .dq_addr (dq_addr_w), .dq_rw (dq_rw_w), .d_cls (dcls_w),
        .d_ppn (d_ppn_w), .d_reg (d_reg_w), .d_fold (d_fold_w),
        .rw_bank (rw_bank), .map_changed (map_changed), .map_settling (map_settling),
        .lb_vpage (lb_vpage_w), .lb_hit (lb_hit_w), .lb_ppn (lb_ppn_w), .lb_set (lb_set_w), .lb_way (lb_way_w),
        .fj_v (fj_v_w), .fj_vpage (fj_vpage_w), .fj_ppn (fj_ppn_w), .fj_set (fj_set_w), .fj_way (fj_way_w),
        .fj_reg (fj_reg_w), .fj_fold (fj_fold_w), .fj_ack (fj_ack_w),
        .op_take (seq_mem_served_w), .op_row_v (op_row_v_w), .op_row (op_row_w), .op_row_ppn (op_row_ppn_w),
        .op_place_v (op_place_v_w), .op_place_ppn (op_place_ppn_w),
        .op_place_set (op_place_set_w), .op_place_way (op_place_way_w),
        .dr_req (dr_req_d), .dr_set (dr_set_d), .dr_way (dr_way_d), .dr_line (dr_line_d),
        .dr_ack (dr_ack_d), .dr_done (dr_done_d), .dr_row (dr_row_w),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_posted (cl_posted),
        .cl_ppn (cl_ppn_w), .cl_off (cl_off), .wdata (cl_wdata),
        .pw_valid (pw_valid_w), .pw_ppn (pw_ppn_w), .pw_off (pw_off_w),
        .pw_data (pw_data_w), .pw_take (pw_take_w && pw_valid_w),
        .ws_valid (ws_valid_w), .ws_ppn (ws_ppn_w), .ws_off8 (ws_off8_w),
        .inval (inval),
        .dbg_sel (4'd0), .dbg_val (), .fill_busy (),
        .cnt_clr (cnt_clr), .cnt_serves (), .cnt_l2_serves (), .cnt_tlb_fills ()
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
    always_ff @(posedge clk) dr_src_sr <= rst ? 2'd0 : {dr_src_sr[0], dr_req_d};
    assign dr_done_d = dr_done_w &&  dr_src_sr[1];
    assign dr_done_i = dr_done_w && !dr_src_sr[1];

    assign prog_wr    = (u_present && !u_rw) || (dev_valid && !dev_rw);
    assign prog_waddr = u_present ? u_addr  : dev_addr;
    assign prog_wdata = u_present ? u_wdata : dev_data;

    // ---- the event merge, as an observer (rtl/event_merge.sv) ---------------
    // The producers' ev_room stays tied high, so every one-clock READ still
    // emits its event and the reference checks it.  The merge sees the
    // stream the card would carry - reads shed at its input by its own
    // fast_room, exactly as the fronts shed at the source - and hands the
    // data front its write-room level, so a posted write retires under the
    // real merge's dynamics.  A write's word must never be the one that
    // overflows: counted below through the merge's own verdict.  room_rand
    // withholds the write room at random on top, for the wait path.
    wire        mg_room, mg_room_w, mg_out_valid;
    wire [63:0] mg_out_data;
    wire [7:0]  mg_overflows;
    wire        mg_fast_valid = fev_valid || (tev_valid && mg_room) ||
                                (dev_valid && (!dev_rw || mg_room));
    wire        mg_fast_rw    = fev_valid ? fev_rw : tev_valid ? 1'b1 : dev_rw;
    reg         room_rand = 1'b0;
    reg [15:0]  room_lfsr = 16'h5EED;
    always @(posedge clk) room_lfsr <= {room_lfsr[14:0], room_lfsr[15] ^ room_lfsr[13] ^ room_lfsr[12] ^ room_lfsr[10]};
    wire        ev_room_w_tb = mg_room_w && (!room_rand || room_lfsr[3]);
    event_merge #(.DEPTH (8)) u_merge (
        .clk (clk), .rst (rst), .enable (1'b1),
        .bus_valid (bus_tick), .bus_data (64'd0), .bus_mark (1'b0), .bus_mark_free (16'd0), .bus_dummy (1'b0),
        .fast_valid (mg_fast_valid), .fast_addr (fev_valid ? fev_addr : tev_valid ? tev_addr : dev_addr),
        .fast_bank (fev_valid ? fev_bank : 8'd0),
        .fast_rw (mg_fast_rw), .fast_data (8'd0), .fast_sync (1'b0), .fast_mark (1'b0), .fast_mark_free (16'd0),
        .fast_quiet (1'b0), .vbl_level (1'b0), .res_level (1'b0), .sparse (1'b0), .virt (1'b0),
        .out_valid (mg_out_valid), .out_data (mg_out_data), .out_mark (), .out_mark_free (), .out_dummy (),
        .out_drop (), .out_carrier (),
        .overflows (mg_overflows), .fast_room (mg_room), .fast_room_w (mg_room_w)
    );
    integer mg_write_in = 0, mg_write_out = 0, mg_write_drops = 0;
    always @(posedge clk) begin
        if (u_merge.want_fast && !mg_fast_rw) begin
            mg_write_in = mg_write_in + 1;
            if (!u_merge.fast_fits) mg_write_drops = mg_write_drops + 1;
        end
        if (mg_out_valid && mg_out_data[31:28] == 4'hC && !mg_out_data[16]) mg_write_out = mg_write_out + 1;
    end

    apple_bus_write #(.T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT), .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)) u_write (
        .clk (clk), .rst (rst), .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active), .park_kbd (sw_int), .park_addr (game_park_addr),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync),
        .drv_sync (drv_sync), .cyc_en (drv_cyc_done), .cpu_din (drv_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (1'b0), .slot_rd_data (8'h00),
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
    wire        rom_loaded, invalidating, image_ready, rot_ok, mem_idle;
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

    // A slot-5 card ROM on the pins, the way the hard disk holds one: every
    // slot is BUS class, so the core reads it over the bus in every mode.
    localparam [2:0] HD_SLOT = 3'd5;
    reg  [7:0] hd_rom [0:255];

    // The map's shadow duplicate, as its own entrant into the cache
    // (docs/GS.md rung 3e).
    wire        shd_take_w;
    wire [15:0] shd_ppn_w;
    wire [7:0]  shd_off_w;
    apple_mmu u_mmu (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_bank (u_bank), .op_addr (u_addr), .op_rw (u_rw), .op_wdata (u_wdata),
        .op_present (u_present), .op_commit (u_commit),
        .rom_ok (rom_loaded),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .intc8rom (intc8rom),
        .cl_posted (cl_posted), .cl_wdata (cl_wdata),
        .pw_valid (pw_any_valid), .pw_ppn (pw_any_ppn), .pw_off (pw_any_off),
        .pw_data (pw_any_data), .pw_ready (pw_ready_w), .pw_take (pw_take_w),
        .shd_take_o (shd_take_w), .shd_ppn_o (shd_ppn_w), .shd_off_o (shd_off_w),
        .pf_off (pf_off),
        .sw_state (sw_state), .vid_sw (), .rw_bank (rw_bank),
        .gs_shadow_o (), .gs_cyareg_o (), .gs_sltrom_o (), .gs_state_o (),
        .q_addr ({8'd0, nxt_addr}), .q_divert (q_divert), .q_rw (cpu_rw), .q_cls (q_cls),
        .swi_on (sw_int), .swi_kbd_ok (kbd_int_ok), .swi_fb_ok (1'b1),
        .swi_vbl_ok (1'b0), .swi_vbl_bar (1'b1), .swi_kbd_low (kbd_int_low),
        .swi_pb_ok (game_pb_ok), .swi_pdl_ok (game_pdl_ok),
        .swi_hd_slot (3'd0), .swi_fd_slot (3'd0), .swi_mb_slot (3'd0), .swi_mouse_slot (3'd0), .swi_u2_slot (3'd0), .swi_prn_slot (3'd0), .q_nsc (), .q_slot (),
        .q_swi (q_swi), .q_swi_quiet (q_swi_quiet), .swi_stat_byte (mmu_swi_stat),
        .p_addr (p_addr_w), .p_cls (p_cls), .p_aux (p_aux_w), .p_off (p_off_w),
        .d_addr (dq_addr_w), .d_rw (dq_rw_w),
        .d_cls (dcls_w), .d_aux (daux_w), .d_off (doff_w),
        .map_changed (map_changed),
        // the physical space (docs/PAGE_CACHE.md); no consumer here yet
        .cl_ppn (cl_ppn_w), .pf_ppn (pf_ppn_w),
        .p_ppn (p_ppn_w), .p_reg (p_reg_w), .p_fold (p_fold_w), .p_fs (p_fs_w),
        .d_ppn (d_ppn_w), .d_reg (d_reg_w), .d_fold (d_fold_w), .d_sh (d_sh_w),
        .map_settling (map_settling), .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1_w),
        .core_dbr (8'd0), .core_pbr (8'd0)
    );
    rom_loader u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .op_present (u_present), .image_ready (image_ready),
        .pw_valid (rl_pw_valid), .pw_ppn (rl_pw_ppn), .pw_off (rl_pw_off),
        .pw_data (rl_pw_data), .pw_take (pw_take_w && !pw_valid_w),
        .busy (rom_busy), .overruns (rom_overruns), .rom_ok (rom_loaded)
    );
    wire        rl_pw_valid;
    wire [15:0] rl_pw_ppn;
    wire [7:0]  rl_pw_off, rl_pw_data;
    wire        rom_busy;
    wire [7:0]  rom_overruns;
    wire        pw_any_valid = pw_valid_w || rl_pw_valid;
    wire [15:0] pw_any_ppn   = pw_valid_w ? pw_ppn_w  : rl_pw_ppn;
    wire [7:0]  pw_any_off   = pw_valid_w ? pw_off_w  : rl_pw_off;
    wire [7:0]  pw_any_data  = pw_valid_w ? pw_data_w : rl_pw_data;
    // The card's geometry (rtl/a2/a2_top.sv MEM_SETS x MEM_WAYS): the IIe's
    // 576 pages do not fit 384 ways, so this bench evicts, as the card does.
    page_cache #(.SETS (64), .WAYS (6)) u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_ppn (cl_ppn_w), .cl_off (cl_off[7:0]),
        .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_wdata (cl_wdata), .cl_posted (cl_posted),
        .pw_pending (d_pending_w), .pw_ready (pw_ready_w),
        .pf_ppn (pf_ppn_w), .pf_off (pf_off[7:0]),
        .pw_take (pw_take_w), .pw_ppn (pw_any_ppn), .pw_off (pw_any_off),
        .shd_take (shd_take_w), .shd_ppn (shd_ppn_w), .shd_off (shd_off_w),
        .op_addr (u_addr),
        .op_present (u_present), .op_commit (u_commit), .op_divert (u_divert), .data_sync (data_sync),
        .sub_en (mem_sub_en), .sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .op_row_v (op_row_v_w), .op_row (op_row_w), .op_row_ppn (op_row_ppn_w),
        .mw_stb (), .mw_addr (), .mw_byte (), .mwx_stb (), .mw_bank (),
        .il_req (1'b0), .il_ppn (16'd0), .il_line (4'd0), .il_src (1'b1),
        .il_ack (il_ack), .il_done (il_done), .il_ok (il_ok), .il_row (il_row),
        .serve (serve), .inval (inval), .cnt_clr (1'b0), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (diverted), .late_fills (late_fills), .fifo_drops (fifo_drops),
        .mem_fills (), .mem_flushes (), .mem_declines (),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .ref_v (ref_v_w), .ref_set (ref_set_w), .ref_way (ref_way_w), .ref_on (ref_on_w),
        .evict_v (evict_v_w), .evict_set (evict_set_w), .evict_way (evict_way_w),
        .op_place_v (op_place_v_w), .op_place_ppn (op_place_ppn_w), .op_place_set (op_place_set_w), .op_place_way (op_place_way_w),
        .dr_req (dr_req_w), .dr_set (dr_set_w), .dr_way (dr_way_w), .dr_line (dr_line_w),
        .dr_ack (dr_ack_w), .dr_done (dr_done_w), .dr_row (dr_row_w),
        .dbg_sel (4'd0), .dbg_val ()
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
        .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

    // ---- the DDR3 stub: the aux region, in order, twelve clocks late ----------------
    // RamWorks banks 0-3, and nothing else: main memory lives in the card's
    // block RAM and the DDR3 never sees it (docs/PAGE_CACHE.md).
    localparam integer NRW = 4;
    // Every bank now: main is physical bank 0, the machine's auxiliary bank
    // 1, RamWorks bank k is k+1 and the ROM is $FF, so the stub backs the
    // whole 16 MB rather than the RamWorks banks alone.
    localparam integer IMG = 16 * 1024 * 1024;
    reg [7:0] smem [0:IMG-1];
    localparam integer DL = 64;
    reg [127:0] dl_d [0:DL-1];
    reg [3:0]   dl_aux [0:DL-1];
    integer     dl_time [0:DL-1];
    integer     dl_wp = 0, dl_rp = 0, now = 0, s_cnt = 0;
    reg         wb_ack_r = 0, s_stall = 0;
    reg [127:0] wb_rdata_r = 0;
    reg [3:0]   wb_aux_r = 0;
    assign wb_ack = wb_ack_r; assign wb_rdata = wb_rdata_r; assign wb_rdata_aux = wb_aux_r;
    assign wb_stall = s_stall;
    function automatic [23:0] wb_to_byte(input [23:0] a);
        wb_to_byte = {{a[22:10], a[6:0]}, 4'd0};    // {ppn, line} * 16
    endfunction
    integer i;
    always @(posedge clk) begin
        now <= now + 1;
        s_cnt <= s_cnt + 1;
        s_stall <= ((s_cnt % 41) < 2);
        wb_ack_r <= 1'b0;
        if (wb_cyc && wb_stb && !wb_stall) begin
            if (wb_addr[9:7] != 3'd0 || wb_addr[23])
                fail($sformatf("DDR3 address outside the image: %06x", wb_addr));
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
    reg m_text, m_mixed, m_col80, m_altchar;
    reg m_bank2, m_lcrd, m_wren, m_pre;
    reg m_intcx, m_slotc3, m_intc8;
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
            m_bank = 0;
        end
    endtask

    // The floating bus, for a $Cxxx nothing answers.
    localparam [7:0] FLOAT = 8'hA5;
    // What $C100-$CFFF reads, on the machine as this testbench models it.
    function automatic [7:0] cx_byte(input [15:0] a);
        logic [3:0] page;
        begin
            page = a[11:8];
            if (page[3])                                   cx_byte = (m_intcx || m_intc8) ? rom_img[a - 16'hC000] : FLOAT;
            else if (m_intcx || (page == 4'd3 && !m_slotc3)) cx_byte = rom_img[a - 16'hC000];
            else if (page[2:0] == HD_SLOT)                 cx_byte = hd_rom[a[7:0]];
            else                                           cx_byte = FLOAT;
        end
    endfunction
    // The bench's own keyboard model, independent of kbd_inject: the tb
    // drives the presses, the machine's keyboard is silent (the pins answer
    // $00), so the truth is one strobe and one latch tracked here.
    reg       tb_kstrobe = 1'b0;
    reg [6:0] tb_kkey = 7'd0, tb_klast = 7'd0;
    always @(posedge clk) begin
        // A retired read of $C00x hands the key over.
        if ((kbd_int_rd || (u_commit && !swi_commit && u_rw && !u_ovr && (u_addr[15:4] == 12'hC00)))
            && tb_kstrobe) tb_klast <= tb_kkey;
        if ((u_commit && !swi_commit && (u_addr == 16'hC010)) ||
            (u_commit && !swi_commit && !u_rw && (u_addr[15:4] == 12'hC01)) || kb_drop)
            tb_kstrobe <= 1'b0;
        if (kb_press) begin
            tb_kkey <= kb_key;
            tb_kstrobe <= 1'b1;
        end
        if (cpu_rst) tb_kstrobe <= 1'b0;
    end
    // What a $C00x read must return, on the card or off it: the injected
    // key while its strobe stands, else the latch with the strobe clear.
    function automatic [7:0] c0_exp(input [15:0] a);
        c0_exp = tb_kstrobe ? {1'b1, tb_kkey} : {1'b0, tb_klast};
    endfunction
    // The machine's status page: bit 7 from its own switches over the
    // keyboard latch's low bits, as the IOU serves them.  The pins answer
    // with it and the card's shadow must agree ($C019 has no VBL here).
    function automatic [7:0] c0_pin_stat(input [3:0] lo);
        reg b;
        begin
            case (lo)
                4'h1: b = m_bank2;   4'h2: b = m_lcrd;    4'h3: b = m_ramrd;
                4'h4: b = m_ramwrt;  4'h5: b = m_intcx;   4'h6: b = m_altzp;
                4'h7: b = m_slotc3;  4'h8: b = m_store80; 4'hA: b = m_text;
                4'hB: b = m_mixed;   4'hC: b = m_page2;   4'hD: b = m_hires;
                4'hE: b = m_altchar; 4'hF: b = m_col80;
                default: b = 1'b0;
            endcase
            c0_pin_stat = {b, tb_kstrobe ? tb_kkey : tb_klast};
        end
    endfunction

    // The machine's game port: the three pushbuttons as the bench holds
    // them, and four 558 timers - any access to $C07x, read or write, on
    // the PINS triggers every timer that is not running, and a timer runs
    // eleven bus cycles a unit of its paddle's position (AppleWin's
    // 2816/255).  tb_cyc counts the bus's cycles.
    reg  [2:0]   tb_pb = 3'b000;
    reg  [7:0]   tb_pos [4];
    reg  [31:0]  tb_pdl_end [4];
    reg  [31:0]  tb_cyc = 0;
    initial begin
        tb_pos[0] = 8'd40; tb_pos[1] = 8'd200; tb_pos[2] = 8'd0; tb_pos[3] = 8'd255;
        for (int p = 0; p < 4; p++) tb_pdl_end[p] = 0;
    end
    function automatic pdl_active(input [1:0] p);
        pdl_active = (tb_cyc <= tb_pdl_end[p]);
    endfunction
    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        tb_cyc <= tb_cyc + 1;
        if (addr_drive[15:4] == 12'hC07) begin
            for (int p = 0; p < 4; p++)
                if (!(tb_cyc <= tb_pdl_end[p])) tb_pdl_end[p] <= tb_cyc + 11 * tb_pos[p];
        end
    end
    // ...and what a read of the port returns on the pins.
    function automatic [7:0] c06_pin(input [3:0] lo);
        if (lo[3:2] == 2'b00 && lo[1:0] != 2'b00) c06_pin = {tb_pb[lo[1:0] - 2'd1], FLOAT[6:0]};
        else if (lo[3:2] == 2'b01)                c06_pin = {pdl_active(lo[1:0]), FLOAT[6:0]};
        else                                       c06_pin = FLOAT;
    endfunction

    // What the core must read at `a`, from the reference: everything but
    // $C01x-$C0FF (the machine's), the keyboard from the model above.
    function automatic [7:0] exp_read(input [15:0] a);
        begin
            if (a[15:4] == 12'hC00) exp_read = c0_exp(a);
            else if (a[15:4] == 12'hC01) exp_read = c0_pin_stat(a[3:0]);
            else if (a[15:4] == 12'hC06) exp_read = c06_pin(a[3:0]);
            else if (a[15:12] == 4'hC) exp_read = cx_byte(a);
            else if (a >= 16'hD000) begin
                if (m_lcrd) exp_read = m_altzp ? ref_lcaux[m_bank * 16384 + m_lcidx(a)] : ref_lc[m_lcidx(a)];
                else        exp_read = rom_img[a - 16'hC000];
            end else exp_read = m_aux(a, 1'b1) ? ref_aux[m_bank * 65536 + a] : ref_main[a];
        end
    endfunction

    // THE MACHINE'S MMU RESETS ON THE BUS SEQUENCE, NOT ON RES'.  The IIe's
    // MMU infers a reset from three reads on the stack page followed by the
    // vector fetch reads of $FFFC and $FFFD, and only then puts its switches
    // back.  So the model's switches go back when the PINS show that - a
    // reset sequence the card served from its own memory leaves them where
    // the last program put them, which is what happened on hardware.  The
    // card's own shadow resets on RES', as the card's MMU should.
    integer m_stack_run = 0;        // consecutive $01xx reads seen on the pins
    reg     m_saw_fffc = 1'b0;
    integer m_mmu_resets = 0;
    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        if (rw_drive && addr_drive[15:8] == 8'h01) m_stack_run <= m_stack_run + 1;
        else if (rw_drive && addr_drive == 16'hFFFC && m_stack_run >= 3) begin m_saw_fffc <= 1'b1; m_stack_run <= 0; end
        else if (rw_drive && addr_drive == 16'hFFFD && m_saw_fffc) begin
            m_saw_fffc <= 1'b0; m_mmu_resets <= m_mmu_resets + 1;
            m_store80 <= 0; m_ramrd <= 0; m_ramwrt <= 0; m_altzp <= 0; m_page2 <= 0; m_hires <= 0;
            m_text <= 1; m_mixed <= 0; m_col80 <= 0; m_altchar <= 0;
            m_bank2 <= 1; m_lcrd <= 0; m_wren <= 1; m_pre <= 0;
            m_intcx <= 0; m_slotc3 <= 0; m_intc8 <= 0;
            m_bank <= 0;
        end else begin m_stack_run <= 0; m_saw_fffc <= 1'b0; end
    end

    // The pins: the machine answers a read, takes a write, moves its switches.
    reg [7:0] mach_byte = 8'h00;
    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        if (rw_drive) begin
            if (addr_drive[15:8] == 8'hC0) begin
                data_pin <= (addr_drive[7:4] == 4'h0) ? 8'h00
                          : (addr_drive[7:4] == 4'h1) ? c0_pin_stat(addr_drive[3:0])
                          : (addr_drive[7:4] == 4'h6) ? c06_pin(addr_drive[3:0])
                          : FLOAT;
                if (addr_drive[7:4] == 4'h5) begin
                    if (addr_drive[3:1] == 3'd2) m_page2 <= addr_drive[0];
                    if (addr_drive[3:1] == 3'd0) m_text  <= addr_drive[0];
                    if (addr_drive[3:1] == 3'd1) m_mixed <= addr_drive[0];
                    if (addr_drive[3:1] == 3'd3) m_hires <= addr_drive[0];
                end
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
                        3'd6: m_col80   <= addr_drive[0];
                        3'd7: m_altchar <= addr_drive[0];
                        3'd1: m_ramrd   <= addr_drive[0];
                        3'd2: m_ramwrt  <= addr_drive[0];
                        3'd3: m_intcx   <= addr_drive[0];
                        3'd4: m_altzp   <= addr_drive[0];
                        3'd5: m_slotc3  <= addr_drive[0];
                        default: ;
                    endcase
                end
                if (addr_drive[7:4] == 4'h5) begin
                    if (addr_drive[3:1] == 3'd2) m_page2 <= addr_drive[0];
                    if (addr_drive[3:1] == 3'd0) m_text  <= addr_drive[0];
                    if (addr_drive[3:1] == 3'd1) m_mixed <= addr_drive[0];
                    if (addr_drive[3:1] == 3'd3) m_hires <= addr_drive[0];
                end
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

    // The reference, from the unified stream: every write in program order,
    // and the INTC8ROM latch from every $C3xx and $CFFF access, fast or not.
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

    // ---- the running checks --------------------------------------------------------
    integer reads = 0, reads_bad = 0, fast_reads = 0, bus_reads = 0, ovr_cycles = 0;
    integer dummies = 0, dummies_bad = 0, pin_ram_writes = 0;
    // The internalized keyboard: served reads, and reads that should have
    // been served but rode the bus (decoded as accel_seq decodes them).
    integer swi_ops = 0, swi_bus_trips = 0, swi_sw_ops = 0, swi_quiet_ops = 0;
    integer swi_game_ops = 0, swi_pdl_strobes = 0, pin_game = 0;

    // The internalized switch WRITES (docs/CXXX.md, "The switch writes"):
    // served, quiet, and the ones that must never be - INTCXROM/SLOTC3ROM.
    // pin_sw_writes counts memory-switch writes that reached the pins while
    // the closed regime stood (must be 0); pin_cx_writes the INTCXROM/
    // SLOTC3ROM writes that did (must not be 0: the motherboard sees them).
    integer swi_wr_ops = 0, swi_wr_quiet = 0, swi_cx_bad = 0, pin_sw_writes = 0, pin_cx_writes = 0;
    // The speaker (docs/CXXX.md "The speaker"): accesses served, and accesses
    // that reached the pins under the closed regime (must be 0).
    integer swi_spk_ops = 0, pin_spk = 0;
    always @(posedge clk) begin
        if (swi_commit) swi_ops = swi_ops + 1;
        if (swi_commit && u_addr[15:4] == 12'hC03) swi_spk_ops = swi_spk_ops + 1;
        if (swi_commit && u_rw && u_addr[15:4] == 12'hC06) swi_game_ops = swi_game_ops + 1;
        if (swi_commit && u_rw && u_addr[15:4] == 12'hC07) swi_pdl_strobes = swi_pdl_strobes + 1;
        if (swi_commit && u_rw && u_addr[7:4] != 4'h0) swi_sw_ops = swi_sw_ops + 1;
        if (swi_commit && u_rw && u_seq.quiet_q) swi_quiet_ops = swi_quiet_ops + 1;
        if (swi_commit && !u_rw) swi_wr_ops = swi_wr_ops + 1;
        if (swi_commit && !u_rw && u_seq.quiet_q) swi_wr_quiet = swi_wr_quiet + 1;
        if (swi_commit && !u_rw && u_addr[7:4] == 4'h0 && (u_addr[3:1] == 3'd3 || u_addr[3:1] == 3'd5))
            swi_cx_bad = swi_cx_bad + 1;
        if (op_present && !op_dummy && !op_ovr && sw_int && op_rw &&
            (op_addr[15:4] == 12'hC00) && kbd_int_ok && !u_seq.reset_seq) begin
            swi_bus_trips = swi_bus_trips + 1;
            if (swi_bus_trips <= 5)
                $display("[%0t] keyboard read on the bus with the latch full: $%04X", $time, op_addr);
        end
    end
    // The machine's side of a synthetic commit: an internalized read or
    // write of a switch moves the model's switches as the pins would have -
    // a write's data is irrelevant, the address is the switch; the language
    // card's A0 = 1 on a WRITE clears prewrite and leaves the enable alone.
    // INTCXROM/SLOTC3ROM never come this way (swi_cx_bad counts it if one does).
    // ...and only for the I/O page: an on-card slot's ROM page ($C78x, say)
    // retires with a synthetic commit too, and its low byte is no switch.
    always @(posedge clk) if (swi_commit && u_addr[15:8] == 8'hC0) begin
        if (!u_rw && u_addr[7:4] == 4'h0) begin
            case (u_addr[3:1])
                3'd0: m_store80 <= u_addr[0];
                3'd1: m_ramrd   <= u_addr[0];
                3'd2: m_ramwrt  <= u_addr[0];
                3'd4: m_altzp   <= u_addr[0];
                3'd6: m_col80   <= u_addr[0];
                3'd7: m_altchar <= u_addr[0];
                default: ;
            endcase
        end
        if (u_addr[7:4] == 4'h5) begin
            if (u_addr[3:1] == 3'd0) m_text  <= u_addr[0];
            if (u_addr[3:1] == 3'd1) m_mixed <= u_addr[0];
            if (u_addr[3:1] == 3'd2) m_page2 <= u_addr[0];
            if (u_addr[3:1] == 3'd3) m_hires <= u_addr[0];
        end
        if (u_addr[7:4] == 4'h8) begin
            m_bank2 <= !u_addr[3];
            m_lcrd  <= (u_addr[1] == u_addr[0]);
            if (!u_addr[0]) begin m_wren <= 0; m_pre <= 0; end
            else if (u_rw) begin if (m_pre) m_wren <= 1; m_pre <= 1; end
            else m_pre <= 0;
        end
    end
    integer fast_bus_cls = 0, bus_bus_cls = 0, u_core_ops = 0, cx_fast = 0, cx_bus = 0, cx_slot_fast = 0;
    integer merge_gaps = 0, presents = 0, last_bus_present = -1, last_was_bus = 0;
    integer check_gaps = 0, drv_cycen = 0, seq_cycen = 0, mode0_bad = 0, bus_ram_reads = 0;
    reg [7:0] pass_count = 8'd0;
    reg       failed = 1'b0;
    reg       u_bus_q = 1'b0, u_bus_q2 = 1'b0;   // this unified op came off the bus
    integer   dma_last_hits = 0;

    always @(posedge clk) begin
        u_bus_q  <= op_present && !op_dummy;
        u_bus_q2 <= u_bus_q;
    end

    // Bus ops: at the data phase, against the machine ($C0xx) or the reference.
    // A SYNTHETIC commit is an internalized keyboard read's - it never rode
    // the bus, the core is ops ahead, and its byte was checked on the fev
    // path - so the bus-side compare skips it.
    always @(posedge clk) if (u_commit && !swi_commit) begin
        if (u_ovr) ovr_cycles = ovr_cycles + 1;
        if (u_ovr && u_addr == 16'h210F) dma_last_hits = dma_last_hits + 1;
        if (u_rw) begin
            reads = reads + 1; bus_reads = bus_reads + 1;
            // ...except the reset sequence's, which ride the bus by rule, and
            // mode 0's, where everything does.
            if ((cl_cls == 2'd1 || cl_cls == 2'd2) && !u_ovr && !u_seq.reset_seq && mode != 2'd0)
                bus_ram_reads = bus_ram_reads + 1;
            if (cl_cls == 2'd0 && u_addr[15:8] == 8'hC0) begin
                if (cpu_din !== mach_byte && !u_ovr &&
                    !(u_addr[15:4] == 12'hC00) && !(u_addr == 16'hC010)) begin
                    reads_bad = reads_bad + 1;
                    if (reads_bad <= 5) $display("    bus read $%04X: core got %02x, the machine said %02x", u_addr, cpu_din, mach_byte);
                end
            end else if (!u_ovr && cpu_din !== exp_read(u_addr) && !(u_addr[15:2] == 14'h3019)) begin
                reads_bad = reads_bad + 1;
                if (reads_bad <= 5) $display("    bus read $%04X: core got %02x, the reference says %02x (machine %02x, cls %0d)",
                                             u_addr, cpu_din, exp_read(u_addr), mach_byte, cl_cls);
            end
            if (u_addr[15:12] == 4'hC && u_addr[11:8] != 4'd0 && !u_ovr) cx_bus = cx_bus + 1;
        end
    end
    // Fast ops: on the clock the core takes the byte, against the reference.
    // fast_c3 / turbo_c3: page $C3's fetches by path - the latch's food
    // rides the sequencer, the rest the front, once it is set.
    integer fast_c3 = 0, turbo_c3 = 0, turbo_c3_0 = 0;
    always @(posedge clk) if (fev_valid) begin
        if (fev_rw) begin
            reads = reads + 1; fast_reads = fast_reads + 1;
            if (fev_addr[15:8] == 8'hC3) fast_c3 = fast_c3 + 1;
            // A served game-port read is the loop's sample, a few dummies
            // behind the pins - a level the bench just moved shows late,
            // and a paddle's bit is the virtual timer's in the core's time:
            // the program's own results are what check_game holds to.
            if (fev_data !== exp_read(fev_addr) && !(fev_addr[15:3] == 13'h180C)) begin
                reads_bad = reads_bad + 1;
                if (reads_bad <= 5) $display("    fast read $%04X: core got %02x, the reference says %02x", fev_addr, fev_data, exp_read(fev_addr));
            end
            if (fev_addr[15:12] == 4'hC && fev_addr[11:8] != 4'd0) begin
                cx_fast = cx_fast + 1;
                // A slot's page, or $C800+ without the internal ROM: never fast.
                if (!fev_addr[11] && !(m_intcx || (fev_addr[11:8] == 4'd3 && !m_slotc3))) cx_slot_fast = cx_slot_fast + 1;
                if ( fev_addr[11] && !(m_intcx || m_intc8)) cx_slot_fast = cx_slot_fast + 1;
            end
        end
    end
    // The front's one-clock ops, by the same rules: every byte the
    // reference's, never a slot's page, never the $CFFx line, never page
    // $C3 while the model's latch is clear (the latch's food rides the
    // sequencer, by rule; the model clears at PRESENT of $CFFF, the card
    // at its commit, so this is the stricter of the two).
    integer turbo_reads = 0, turbo_bad = 0, turbo_excl_bad = 0;
    always @(posedge clk) if (tev_valid) begin
        reads = reads + 1; turbo_reads = turbo_reads + 1;
        if (tev_data !== exp_read(tev_addr)) begin
            turbo_bad = turbo_bad + 1; reads_bad = reads_bad + 1;
            if (reads_bad <= 5) $display("    turbo read $%04X: core got %02x, the reference says %02x", tev_addr, tev_data, exp_read(tev_addr));
        end
        if (tev_addr[15:12] == 4'hC) begin
            if (tev_addr[15:8] == 8'hC3) turbo_c3 = turbo_c3 + 1;
            if ((tev_addr[15:8] == 8'hC3 && !m_intc8) || tev_addr[15:4] == 12'hCFF) turbo_excl_bad = turbo_excl_bad + 1;
            if (tev_addr[11:8] == 4'd0) turbo_excl_bad = turbo_excl_bad + 1;
            if (!tev_addr[11] && tev_addr[11:8] != 4'd0 &&
                !(m_intcx || (tev_addr[11:8] == 4'd3 && !m_slotc3))) turbo_excl_bad = turbo_excl_bad + 1;
            if ( tev_addr[11] && !(m_intcx || m_intc8)) turbo_excl_bad = turbo_excl_bad + 1;
        end
    end
    // The data front's one-clock reads: every byte the reference's, and never
    // $Cxxx - the shadow, the CAM and the last byte serve RAM and LC classes
    // only, and no LC virtual address is in $Cxxx.
    // ...and its one-clock writes: counted, and every one must come back
    // round through the classified stage as it drains (cl_posted).
    integer dline_reads = 0, dline_bad = 0, dline_writes = 0, drained = 0;
    always @(posedge clk) if (dev_valid) begin
        if (dev_rw) begin
            reads = reads + 1; dline_reads = dline_reads + 1;
            if (dev_data !== exp_read(dev_addr)) begin
                dline_bad = dline_bad + 1; reads_bad = reads_bad + 1;
                if (reads_bad <= 5) $display("    L1-D read $%04X: core got %02x, the reference says %02x", dev_addr, dev_data, exp_read(dev_addr));
                if (reads_bad <= 5) $display("      (served by: sh %0d lb %0d lr %0d l2 %0d; lr_v %0d lr_addr %03X lr_ppn %04X; cst %0d)",
                                             u_l1d.sh_hit_q_dbg, u_l1d.lby_hit_q_dbg, u_l1d.lr_hit_q_dbg, u_l1d.l2_hit_q_dbg,
                                             u_l1d.lr_v, u_l1d.lr_addr, u_l1d.lr_ppn, u_l1d.cst);
            end
        end else dline_writes = dline_writes + 1;
        if (dev_addr[15:12] == 4'hC) dline_bad = dline_bad + 1;
    end
    // The posted seam has TWO producers now: the data front's retired writes
    // and the ROM load's 16384 (rtl/rom_loader.sv).  Only the front's are the
    // front's, and the ROM's are the only ones that land in bank $FF.
    integer rom_drained = 0;
    always @(posedge clk) if (cl_valid && cl_posted) begin
        if (cl_ppn_w[15:8] == 8'hFF) rom_drained = rom_drained + 1;
        else                         drained     = drained + 1;
    end
    // The stream's bookkeeping: passes, the failure flag, classes, merging.
    always @(posedge clk) begin
        if (prog_wr) begin
            if (prog_waddr == 16'h0300) begin
                pass_count = prog_wdata;
                $display("    pass %0d at %0t (%0d reads: %0d fast, %0d bus)", prog_wdata, $time, reads, fast_reads, bus_reads);
            end
            if (prog_waddr == 16'h03FF && prog_wdata == 8'hFF) failed = 1'b1;
        end
        if (u_present && !u_ovr) begin
            u_core_ops = u_core_ops + 1;
            if (u_bus_q) begin
                if (check_gaps && last_was_bus && presents - last_bus_present != 1) merge_gaps = merge_gaps + 1;
                last_bus_present = presents; last_was_bus = 1;
            end else last_was_bus = 0;
        end
        // A turbo op between two bus ops breaks their adjacency exactly as
        // an on-stream fast op does: they were not consecutive.
        if (turbo_commit) last_was_bus = 0;
        if (op_present) begin
            presents = presents + 1;
            if (op_dummy) dummies = dummies + 1;
        end
        if (cl_valid && cl_cls == 2'd0 && !u_ovr) begin
            if (u_bus_q2) bus_bus_cls = bus_bus_cls + 1;
            else if (!u_seq.swi_q) fast_bus_cls = fast_bus_cls + 1;
        end
        if (since_fall == BUS_AT && driving) begin
            if (op_dummy && !(rw_drive && (sw_int ? (addr_drive == 16'hC000 || addr_drive == 16'hC070 ||
                                                     (addr_drive[15:4] == 12'hC06 && addr_drive[3] == 1'b0 && addr_drive[2:0] != 3'd0))
                                                  : addr_drive == 16'h0000)))
                dummies_bad = dummies_bad + 1;
            // The program's own game-port accesses on the pins under the
            // closed regime, once the port is being served.
            if (!op_dummy && !op_ovr && sw_int && game_pb_ok && game_pdl_ok && !u_seq.reset_seq &&
                (addr_drive[15:4] == 12'hC06 || (rw_drive && addr_drive[15:4] == 12'hC07)))
                pin_game = pin_game + 1;
            if (!rw_drive && data_oe && addr_drive[15:12] != 4'hC && !op_ovr) pin_ram_writes = pin_ram_writes + 1;
            // A switch write on the pins under the closed regime: the two
            // Cx-ROM switches must be there, the memory switches must not.
            if (!op_dummy && !op_ovr && sw_int && !u_seq.reset_seq && addr_drive[15:4] == 12'hC03)
                pin_spk = pin_spk + 1;
            if (!rw_drive && data_oe && !op_ovr && sw_int && !u_seq.reset_seq && addr_drive[15:8] == 8'hC0) begin
                if (addr_drive[7:4] == 4'h0 && (addr_drive[3:1] == 3'd3 || addr_drive[3:1] == 3'd5))
                    pin_cx_writes = pin_cx_writes + 1;
                else if (addr_drive[7:4] == 4'h0 || (addr_drive[7:4] == 4'h5 && !addr_drive[3]) || addr_drive[7:4] == 4'h8)
                    pin_sw_writes = pin_sw_writes + 1;
            end
        end
        if (drv_cyc_done) drv_cycen = drv_cycen + 1;
        if (cpu_cyc_en)   seq_cycen = seq_cycen + 1;
        // (The driver's parked state before its first present reads as a
        // dummy; that is the takeover, not mode 0.)
        if (mode == 2'd0 && presents > 1 && (op_dummy || fev_valid || (cpu_cyc_en != drv_cyc_done))) mode0_bad = mode0_bad + 1;
    end

    always @(posedge clk) if (now % 2_000_000 == 1_999_999)
        $display("    ...%0d clocks, %0d reads (%0d fast), fast_ops %0d turbo %0d bus_ops %0d cycles %0d, state %0d, pc $%04X is_i %b exp $%04X lhit %b claim %b tok %b vwant %b%b v %b%b fst %0d mm %0d last %08x",
                 now + 1, reads, fast_reads, fast_ops, turbo_ops, bus_ops, cycles, seq_state,
                 cpu_addr, cpu_cyc_is_i, u_l1i.exp_q, u_l1i.lhit_q, turbo_claim, turbo_ok,
                 u_l1i.ew_v, u_l1i.dr_req, u_l1i.v[0], u_l1i.v[1], u_l1i.fst,
                 mismatches, last_mismatch);

    // ---- helpers -----------------------------------------------------------------------
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
            // The loader turns each chunk into 512 physical writes and the
            // seam takes one every four clocks, so the host - and this bench -
            // waits for `busy` to fall before sending the next.  A chunk that
            // arrives under a drain is dropped whole (rtl/rom_loader.sv).
            while (rom_busy) @(negedge clk);
        end
    endtask

    task wait_passes(input integer n, input string what);
        integer c;
        begin
            c = 0;
            while (pass_count < n && !failed && c < 120_000_000) begin @(posedge clk); c = c + 1; end
            if (failed) fail($sformatf("%0s: the program raised its failure flag at pass %0d", what, pass_count));
            else if (pass_count < n) fail($sformatf("%0s: only %0d passes before the timeout", what, pass_count));
            else ok($sformatf("%0s: %0d passes of the program", what, n));
            // The pass write is seen at its present; let it reach the pins.
            repeat (2 * CYCLE) @(negedge clk);
        end
    endtask

    task clear_counters;
        begin
            @(negedge clk); cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0;
        end
    endtask

    // The program's game-port phase (sim/accel.s 5f) stored the three
    // buttons at $0320-$0322 and PREAD's count for each paddle at $0324-
    // $0327: the levels exactly, the counts within two of the positions.
    task check_game(input string what, input bit timed);
        integer d;
        begin
            for (int b = 0; b < 3; b++) begin
                if (ref_main[16'h0320 + b][7] !== tb_pb[b])
                    fail($sformatf("%0s: button %0d read as %b, wanted %b", what, b, ref_main[16'h0320 + b][7], tb_pb[b]));
            end
            ok($sformatf("%0s: the three buttons read as the machine holds them (%b)", what, tb_pb));
            // Mode 1 is the case the port's serving exists to cure: the
            // paddle reads ride the bus at two cycles each while the loop
            // around them runs fast, so PREAD counts more loops per unit
            // than eleven cycles' worth and reads high.  Only the stopped
            // paddle is exact there.
            // PADDLE 3 IS NOT CHECKED: it is not connected on the machine
            // (the user, 2026-09-08), so PREAD's count for it measures an
            // unconnected input and asserting on it tests nothing.  The card
            // reads it saturated on hardware - `pdl ... 4000 4000` - and the
            // reading drifted with every rung of the memory rethink while
            // paddles 0/1/2 stayed exact, which is the signature of a
            // measurement with nothing behind it.  The three that ARE
            // connected are checked to +/-2 and hold there exactly.
            for (int p = 0; p < 3; p++) begin
                d = int'(ref_main[16'h0324 + p]) - int'(tb_pos[p]);
                if ((timed || tb_pos[p] == 8'd0) && (d > 2 || d < -2))
                    fail($sformatf("%0s: paddle %0d read as %0d, wanted %0d", what, p, ref_main[16'h0324 + p], tb_pos[p]));
            end
            ok($sformatf("%0s: PREAD's counts %0d %0d %0d for paddles at %0d %0d %0d (3 unconnected, read %0d)%0s", what,
                         ref_main[16'h0324], ref_main[16'h0325], ref_main[16'h0326],
                         tb_pos[0], tb_pos[1], tb_pos[2], ref_main[16'h0327],
                         timed ? "" : " (the bus's reads under a fast loop: inflated, as expected)"));
        end
    endtask

    // A DMA of the disk's shape: n override writes to $2100+, each presented
    // exactly once - stepped, as hd_card steps, on the driver saying it took it.
    task dma(input integer n);
        integer idx;
        begin
            idx = 0;
            @(negedge clk);
            tb_ovr_en <= 1'b1; tb_ovr_rw <= 1'b0; tb_ovr_addr <= 16'h2100; tb_ovr_wdata <= 8'h80;
            // Sampled at negedge, where the posedge's updates have settled:
            // a posedge sample here races the design's non-blocking updates,
            // and the two simulators order that race differently.
            while (idx < n) begin
                @(negedge clk);
                if (op_present && op_ovr && op_addr == tb_ovr_addr && !op_rw) begin
                    idx = idx + 1;
                    if (idx < n) begin tb_ovr_addr <= 16'h2100 + idx; tb_ovr_wdata <= 8'h80 + idx; end
                    else tb_ovr_en <= 1'b0;
                end
            end
        end
    endtask

    task set_rwflag;      // the program's "the card is serving" flag, by DMA
        begin
            @(negedge clk);
            tb_ovr_en <= 1'b1; tb_ovr_rw <= 1'b0; tb_ovr_addr <= 16'h03FE; tb_ovr_wdata <= 8'h01;
            @(negedge clk);
            while (!(op_present && op_ovr && op_addr == 16'h03FE)) @(negedge clk);
            tb_ovr_en <= 1'b0;
        end
    endtask

    // THE CARD'S BYTE AT A PHYSICAL ADDRESS.  No bank is privileged now:
    // hash the page to its set, scan the set's ways for a valid tag, and read
    // the way that holds it - else the page is not resident and the DDR3 has
    // it.  A generate instance cannot be indexed by a variable, so the eight
    // ways are named; the geometry sweep lives in sim/page_cache_tb.sv.
    localparam integer MEM_SETS = 64, MEM_WAYS = 6;   // the card's (u_cache above)
    localparam integer SIDX = $clog2(MEM_SETS);
    function automatic [7:0] card_byte(input [15:0] ppn, input [7:0] off);
        int st, w, hit;
        logic [127:0] row;
        begin
            st  = int'(ppn[SIDX-1:0] ^ ppn[2*SIDX-1 -: SIDX]);
            hit = -1;
            for (w = 0; w < MEM_WAYS; w = w + 1)
                if (u_cache.dir[w][st][17] && u_cache.dir[w][st][15:0] == ppn) hit = w;
            row = 128'd0;
            case (hit)
                0: row = u_cache.g_way[0].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                1: row = u_cache.g_way[1].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                2: row = u_cache.g_way[2].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                3: row = u_cache.g_way[3].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                4: row = u_cache.g_way[4].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                5: row = u_cache.g_way[5].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                default: ;
            endcase
            card_byte = (hit >= 0) ? row[8 * off[3:0] +: 8] : smem[{ppn, off}];
        end
    endfunction
    function automatic [7:0] card_main(input [15:0] off);
        card_main = card_byte({8'd0, off[15:8]}, off[7:0]);
    endfunction
    function automatic [7:0] card_aux(input [7:0] b, input [15:0] off);
        card_aux = card_byte({b + 8'd1, off[15:8]}, off[7:0]);
    endfunction

    task check_image(input string what);
        integer a, b, bad;
        begin
            // The machine keeps running while this task samples in zero sim
            // time, and a write is in the reference at u_present but in the
            // bank only at P3: wait for the write pipeline to drain, or a
            // mid-flight write reads as a one-byte mismatch.
            @(negedge clk);
            while (busy || u_cache.wl_v || d_pending_w || rom_busy) @(negedge clk);
            bad = 0;
            for (a = 0; a < 16'hC000; a = a + 1) begin
                if (card_main(16'(a)) !== ref_main[a]) bad = bad + 1;
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
    // The machine's memory against the reference: equal when every write went
    // out on the pins, main and the one auxiliary bank (RamWorks bank 0).
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

    task check_ratio(input real want, input string what);
        real got;
        begin
            // Every op the governor charged: the dispatcher's, the instruction
            // front's, and the data front's - the last counted by the front
            // itself (rtl/dline.sv), charged through d_commit.
            got = real'(fast_ops + bus_ops + turbo_ops + u_l1d.cnt_serves) / real'(cycles);
            if (cycles == 0) fail($sformatf("%0s: no bus cycles counted", what));
            else if (got < want * 0.95 || got > want * 1.05)
                fail($sformatf("%0s: %0d ops over %0d cycles = %.2f per cycle, wanted %.2f", what, fast_ops + bus_ops + turbo_ops + u_l1d.cnt_serves, cycles, got, want));
            else ok($sformatf("%0s: %.2f ops per bus cycle (wanted %.2f; %0d turbo, %0d fast, %0d dline, %0d bus over %0d cycles)",
                              what, got, want, turbo_ops, fast_ops, u_l1d.cnt_serves, bus_ops, cycles));
        end
    endtask

    task common_checks(input string what);
        begin
            if (reads_bad != 0) fail($sformatf("%0s: %0d reads disagreed with the reference (%0d of them turbo)", what, reads_bad, turbo_bad));
            else ok($sformatf("%0s: %0d reads (%0d turbo, %0d fast, %0d dline), every one the reference's byte", what, reads, turbo_reads, fast_reads, dline_reads));
            if (turbo_excl_bad != 0) fail($sformatf("%0s: %0d one-clock ops broke the $Cxxx rules", what, turbo_excl_bad));
            if (dummies_bad != 0) fail($sformatf("%0s: %0d dummy cycles were not the parked read", what, dummies_bad));
            if (fast_bus_cls != 0) fail($sformatf("%0s: %0d BUS-class ops were served fast", what, fast_bus_cls));
            // The census: seven exclusive buckets that sum to ACCEL_FAST.
            if (cs_i + cs_dram + cs_dlc + cs_drom +
                cs_dcx + cs_wr + cs_kbd != fast_ops)
                fail($sformatf("%0s: the fast-op census (%0d I, %0d RAM, %0d LC, %0d ROM, %0d CX, %0d WR, %0d KBD) does not sum to %0d fast ops",
                               what, cs_i, cs_dram, cs_dlc, cs_drom, cs_dcx, cs_wr, cs_kbd, fast_ops));
            else ok($sformatf("%0s: fast-op census %0d I, %0d RAM, %0d LC, %0d ROM, %0d CX, %0d WR, %0d KBD = %0d",
                              what, cs_i, cs_dram, cs_dlc, cs_drom, cs_dcx, cs_wr, cs_kbd, fast_ops));
            if (late_fills != 0 || fifo_drops != 0) fail($sformatf("%0s: late fills %0d, drops %0d", what, late_fills, fifo_drops));
            if (mismatches != 0) fail($sformatf("%0s: the monitor counted %0d mismatches (last %08x)", what, mismatches, last_mismatch));
            if (u_core_ops != fast_ops + bus_ops + ovr_cycles - ovr_cycles) ;  // counted below
            reads_bad = 0;
        end
    endtask

    // ---- the run -------------------------------------------------------------------------
    reg [7:0] prog [0:4095];
    integer a, c, n0, n1, r0, resets, gaps0, fast0;
    integer bp_prom0, bp_pin0, bp_scan0, bp_fill0, bp_serv0, bp_tgt0, bp_slow0;
    // The TLB across a map change: the clock after its revalidation, does any
    // entry still stand?
    integer tlb_revals = 0, tlb_reval_alive = 0;
    logic   tlb_rq_d = 1'b0;
    always @(posedge clk) begin
        tlb_rq_d <= u_tlb.reval_q;
        if (tlb_rq_d) begin
            tlb_revals = tlb_revals + 1;
            if (u_tlb.e_v[0] || u_tlb.e_v[1] || u_tlb.e_v[2] || u_tlb.e_v[3] ||
                u_tlb.e_v[4] || u_tlb.e_v[5] || u_tlb.e_v[6] || u_tlb.e_v[7])
                tlb_reval_alive = tlb_reval_alive + 1;
        end
    end
    initial begin
        $readmemh(PROG, prog);
        for (a = 0; a < 65536; a = a + 1) begin main_ram[a] = 8'h00; phys_aux[a] = 8'h00; ref_main[a] = 8'h00; end
        for (a = 0; a < NRW * 65536; a = a + 1) ref_aux[a] = 8'h00;
        for (a = 0; a < 16384; a = a + 1) begin lc_main[a] = 8'h00; phys_lcaux[a] = 8'h00; ref_lc[a] = 8'h00; end
        for (a = 0; a < NRW * 16384; a = a + 1) ref_lcaux[a] = 8'h00;
        for (a = 0; a < IMG; a = a + 1) smem[a] = 8'h00;
        // The cache's ways need no priming: every page is filled from the
        // DDR3 before it is read, and the stub is zeroed above.
        for (a = 0; a < 12288; a = a + 1) rom_img[a] = $urandom;
        for (a = 0; a < 4096; a = a + 1) rom_img[12288 + a] = prog[a];
        for (a = 0; a < 256; a = a + 1) hd_rom[a] = $urandom;
        rom_img[16'h1000] = 8'hC7;
        // Page $C3's residents, for cxtest (sim/accel.s): the 80-column
        // firmware's own shape at $C372 (LDX $CFFF / RTS - the clear, then
        // an RTS the front must not serve), a one-line loop at $C380
        // (LDX #16 / DEX / BNE / RTS), and a loop across two lines at
        // $C39A-$C3A5 (LDX #8 / NOP x6 / DEX / BNE / RTS) for the crossing.
        rom_img[16'h0372] = 8'hAE; rom_img[16'h0373] = 8'hFF; rom_img[16'h0374] = 8'hCF;
        rom_img[16'h0375] = 8'h60;
        rom_img[16'h0380] = 8'hA2; rom_img[16'h0381] = 8'h10; rom_img[16'h0382] = 8'hCA;
        rom_img[16'h0383] = 8'hD0; rom_img[16'h0384] = 8'hFD; rom_img[16'h0385] = 8'h60;
        rom_img[16'h039A] = 8'hA2; rom_img[16'h039B] = 8'h08;
        for (a = 16'h039C; a <= 16'h03A1; a = a + 1) rom_img[a] = 8'hEA;
        rom_img[16'h03A2] = 8'hCA; rom_img[16'h03A3] = 8'hD0; rom_img[16'h03A4] = 8'hF7;
        rom_img[16'h03A5] = 8'h60;
        m_reset();
        resets = 0;

        $display("accel_tb: PHI0_HIGH = %0d (cyc_en to the next present: %0d clocks)", PHI0_HIGH, PHI0_HIGH - 47 + T_PRESENT + 1);
        repeat (5) @(negedge clk);
        rst <= 1'b0;
        @(negedge clk);
        for (c = 0; c < 32; c = c + 1) send_chunk(c);
        if (!rom_loaded) fail("the ROM did not load");
        serve <= 1'b1;

        // The machine comes out of reset; the core with it.  The model's
        // switches are NOT reset here: its MMU waits for the sequence on the
        // pins (above), as the machine's does.  The power-on state was set
        // by m_reset() at the start.
        res_n <= 1'b0;
        repeat (5 * CYCLE) @(negedge clk);
        res_n <= 1'b1;

        // ---- 1. mode 0: the old machine, to the clock ----------------------------------
        set_rwflag();
        wait_passes(2, "mode 0, serving");
        common_checks("mode 0");
        if (mode0_bad != 0) fail($sformatf("mode 0: %0d clocks with a dummy, a fast op or a cyc_en not the driver's", mode0_bad));
        else ok("mode 0: no dummy, no fast op, every cyc_en the driver's");
        if (cx_bus == 0) fail("mode 0: the program never read $C100-$CFFF on the bus");
        else ok($sformatf("mode 0: %0d reads of $C100-$CFFF rode the bus and matched the model", cx_bus));
        check_game("mode 0", 1'b1);
        if (phys_diff(1) != 0) fail("mode 0: the machine's memory differs from the reference");
        else ok("mode 0: the machine's memory equals the reference");

        // ---- 2. mode 1: reads on the card, writes on the bus ----------------------------
        clear_counters(); bus_ram_reads = 0;
        n0 = pass_count; check_gaps = 1; merge_gaps = 0;
        @(negedge clk); mode <= 2'd1;
        wait_passes(n0 + 3, "mode 1, unlimited");
        @(negedge clk); mode <= 2'd0; check_gaps = 0;
        repeat (3 * CYCLE) @(negedge clk);
        common_checks("mode 1");
        if (fast_ops + turbo_ops == 0 || dummies == 0) fail("mode 1: no fast ops or no dummies");
        else ok($sformatf("mode 1: %0d fast ops, %0d bus ops, %0d bus cycles, %0d dummies", fast_ops, bus_ops, cycles, dummies));
        check_ratio(real'(fast_ops + bus_ops + turbo_ops + u_l1d.cnt_serves) / real'(cycles), "mode 1 measured");
        if (fast_ops + bus_ops + turbo_ops + u_l1d.cnt_serves < 3 * cycles) fail("mode 1: less than 3x");
        else ok($sformatf("mode 1: %.1fx", real'(fast_ops + bus_ops + turbo_ops + u_l1d.cnt_serves) / real'(cycles)));
        if (turbo_ops == 0) fail("mode 1: no fetch was served in one clock");
        else ok($sformatf("mode 1: %0d fetches served in one clock by the line front", turbo_ops));
        if (phys_diff(1) != 0) fail("mode 1: the machine's memory differs from the reference - a write missed the bus");
        else ok("mode 1: every write reached the machine; its memory equals the reference");
        if (dline_writes != 0) fail($sformatf("mode 1: %0d writes retired on the data front", dline_writes));
        else ok("mode 1: no write retired on the data front - writes stay on the bus by mode");
        if (merge_gaps != 0) fail($sformatf("mode 1: %0d consecutive bus ops did not ride consecutive cycles", merge_gaps));
        else ok("mode 1: consecutive bus ops rode consecutive cycles");
        if (cx_fast == 0) fail("mode 1: no internal-ROM read of $C100-$CFFF was served fast");
        else ok($sformatf("mode 1: %0d internal-ROM reads of $C100-$CFFF served from the card, every one the model's byte", cx_fast));
        check_game("mode 1", 1'b0);
        if (cx_slot_fast != 0) fail($sformatf("mode 1: %0d slot reads were served fast", cx_slot_fast));
        else ok("mode 1: every slot read - the slot-5 ROM, the empty slots - rode the bus");
        if (swi_ops != 0) fail("mode 1: a keyboard read or switch op was served on the card outside the closed regime");
        else ok("mode 1: every keyboard read rode the bus (the regime is mode 2's)");
        if (turbo_c3 == 0) fail("mode 1: no $C3xx fetch was served in one clock");
        else ok($sformatf("mode 1: %0d $C3xx fetches served in one clock once INTC8ROM was set (%0d rode the sequencer: the latch's food)", turbo_c3, fast_c3));
        check_image("mode 1: the image equals the reference");

        // ---- 3. mode 2: reads and writes on the card ------------------------------------
        clear_counters(); pin_ram_writes = 0; dummies = 0; cx_fast = 0;
        pin_sw_writes = 0; pin_cx_writes = 0; swi_wr_ops = 0; swi_wr_quiet = 0; swi_spk_ops = 0; pin_spk = 0;
        n0 = pass_count; check_gaps = 1; merge_gaps = 0;
        bp_prom0 = u_tlb.cnt_fills;        bp_pin0  = u_l1i.cnt_prefetch;
        bp_scan0 = u_l1i.cnt_tlb_waits;    bp_fill0 = u_l1i.cnt_fills;
        bp_serv0 = u_l1i.cnt_kills;        bp_tgt0 = u_l1i.cnt_tgt_serves;
        bp_slow0 = u_l1i.cnt_slow_i; turbo_c3_0 = turbo_c3;
        tlb_revals = 0; tlb_reval_alive = 0;
        @(negedge clk); mode <= 2'd2;
        wait_passes(n0 + 3, "mode 2, unlimited");
        repeat (3 * CYCLE) @(negedge clk);
        check_gaps = 0;
        common_checks("mode 2");
        if (pin_ram_writes != 0) fail($sformatf("mode 2: %0d RAM writes reached the pins", pin_ram_writes));
        else ok("mode 2: no RAM write reached the pins");
        if (fast_ops + bus_ops + turbo_ops + u_l1d.cnt_serves < 6 * cycles) fail($sformatf("mode 2: only %.1fx", real'(fast_ops + bus_ops + turbo_ops + u_l1d.cnt_serves) / real'(cycles)));
        else ok($sformatf("mode 2: %.1fx (%0d turbo, %0d fast, %0d dline, %0d bus over %0d cycles)", real'(fast_ops + bus_ops + turbo_ops + u_l1d.cnt_serves) / real'(cycles), turbo_ops, fast_ops, u_l1d.cnt_serves, bus_ops, cycles));
        if (turbo_ops == 0) fail("mode 2: no fetch was served in one clock");
        else ok($sformatf("mode 2: %0d fetches served in one clock by the line front", turbo_ops));
        if (turbo_c3 == turbo_c3_0) fail("mode 2: no $C3xx fetch was served in one clock");
        else ok($sformatf("mode 2: %0d $C3xx fetches served in one clock once INTC8ROM was set", turbo_c3 - turbo_c3_0));
        // ---- 3b. the keyboard in the dummies --------------------------------
        if (swi_ops == 0) fail("mode 2: no keyboard read was served on the card");
        else ok($sformatf("mode 2: %0d keyboard reads served from the parked-dummy latch", swi_ops));
        if (swi_sw_ops == 0) fail("mode 2: no status/floating read was served on the card");
        else ok($sformatf("mode 2: %0d switch reads served on the card, %0d of them quiet (no word)", swi_sw_ops, swi_quiet_ops));
        if (swi_bus_trips != 0) fail($sformatf("mode 2: %0d keyboard reads rode the bus with the latch full", swi_bus_trips));
        else ok("mode 2: no keyboard read rode the bus once the latch had filled");
        // ---- 3c. the switch writes in the closed regime ------------------------
        if (swi_wr_ops == 0) fail("mode 2: no switch write was served on the card");
        else ok($sformatf("mode 2: %0d switch writes served on the card, %0d of them quiet (no word)", swi_wr_ops, swi_wr_quiet));
        if (pin_sw_writes != 0) fail($sformatf("mode 2: %0d memory-switch writes reached the pins in the closed regime", pin_sw_writes));
        else ok("mode 2: no memory-switch write reached the pins in the closed regime");
        if (pin_cx_writes == 0) fail("mode 2: no INTCXROM/SLOTC3ROM write reached the pins - the motherboard must see them");
        else ok($sformatf("mode 2: %0d INTCXROM/SLOTC3ROM writes rode the bus, as they must", pin_cx_writes));
        if (swi_cx_bad != 0) fail($sformatf("mode 2: %0d INTCXROM/SLOTC3ROM writes were served on the card", swi_cx_bad));
        else ok("mode 2: no INTCXROM/SLOTC3ROM write was served on the card");
        // ---- 3d. the speaker in the closed regime ------------------------------
        if (swi_spk_ops == 0) fail("mode 2: no speaker access was served on the card");
        else ok($sformatf("mode 2: %0d speaker accesses served on the card", swi_spk_ops));
        if (pin_spk != 0) fail($sformatf("mode 2: %0d speaker accesses reached the pins in the closed regime", pin_spk));
        else ok("mode 2: no speaker access reached the pins in the closed regime");
        // ---- 3e. the game port in the dummies (docs/CXXX.md "The game port") ---
        // The loop has been strobing and probing since the regime came on;
        // once two measurements stand and the buttons are sampled, a pass
        // of the program reads the port entirely on the card - the strobe
        // as a served read, the timers as virtual ones - and stores what
        // PREAD counted.  The bench moves a button and a paddle first, so
        // the samples proven are ones taken by the loop, not the reset's.
        tb_pb <= 3'b101; tb_pos[1] <= 8'd120;
        c = 0;
        while ((game_meas < 8'd2 || !game_pb_ok) && c < 30_000_000) begin @(posedge clk); c = c + 1; end
        if (game_meas < 8'd2) fail("mode 2: the dummy loop completed no paddle measurement");
        else ok($sformatf("mode 2: the dummy loop completed %0d paddle measurements; samples %0d %0d %0d %0d bus cycles",
                          game_meas, game_pdl0, game_pdl1, game_pdl2, game_pdl3));
        if (!game_pb_ok) fail("mode 2: the dummy loop never sampled the three buttons");
        else ok($sformatf("mode 2: the buttons sampled by the loop read %b", game_pb));
        n0 = swi_game_ops; c = swi_pdl_strobes; pin_game = 0;
        wait_passes(pass_count + 2, "mode 2, the game port served");
        check_game("mode 2", 1'b1);
        if (swi_game_ops == n0) fail("mode 2: no button or paddle read was served on the card");
        else ok($sformatf("mode 2: %0d button and paddle reads served on the card", swi_game_ops - n0));
        if (swi_pdl_strobes == c) fail("mode 2: no paddle strobe was served on the card");
        else ok($sformatf("mode 2: %0d paddle strobes served on the card, the virtual timers started", swi_pdl_strobes - c));
        if (pin_game != 0) fail($sformatf("mode 2: %0d game-port accesses of the program's reached the pins with the port served", pin_game));
        else ok("mode 2: no game-port access of the program's reached the pins with the port served");
        // An injected key crosses the internal path end to end: pressed
        // here, served to the program's poll from the card, taken with the
        // $C010 that rides the bus, and the byte the program stored is
        // {1, $41}.
        n0 = kb_taken;
        @(negedge clk); kb_press <= 1'b1; kb_key <= 7'h41;
        @(negedge clk); kb_press <= 1'b0;
        c = 0;
        while (kb_taken == n0 && c < 3_000_000) begin @(posedge clk); c = c + 1; end
        if (kb_taken == n0) fail("the injected key was never taken through the internal path");
        else ok("an injected key served on the card was taken, its $C010 on the bus");
        repeat (4 * CYCLE) @(negedge clk);
        if (ref_main[16'h0310] !== 8'hC1)
            fail($sformatf("the program stored $%02x for the injected key, wanted $C1", ref_main[16'h0310]));
        else ok("...and the program read {1, $41} off the card");
        $display("    L1-I: %0d line fills (%0d prefetches), %0d TLB fills, %0d TLB waits, %0d kills, %0d zero-stall branches, %0d unservable, %0d slow ifetches",
                 u_l1i.cnt_fills, u_l1i.cnt_prefetch, u_tlb.cnt_fills, u_l1i.cnt_tlb_waits,
                 u_l1i.cnt_kills, u_l1i.cnt_tgt_serves, u_l1i.cnt_unserv, u_l1i.cnt_slow_i);
        // Every mechanism of the new L1-I must have fired in this phase -
        // sim/accel.s's bptest is built to make each one unavoidable.
        if (u_l1i.cnt_fills == bp_fill0) fail("mode 2: L1-I never filled a line by a direct way read");
        else ok($sformatf("mode 2: %0d lines filled by direct way reads of the page cache", u_l1i.cnt_fills - bp_fill0));
        if (u_tlb.cnt_fills == bp_prom0) fail("mode 2: the TLB never learned a page");
        else ok($sformatf("mode 2: %0d TLB fills from the dispatcher's placement report", u_tlb.cnt_fills - bp_prom0));
        if (u_l1i.cnt_prefetch == bp_pin0) fail("mode 2: the next line was never prefetched");
        else ok($sformatf("mode 2: %0d next-line prefetches", u_l1i.cnt_prefetch - bp_pin0));
        if (u_l1i.cnt_kills == bp_serv0) fail("mode 2: no line buffer was ever killed by a write (smctest writes into the running line)");
        else ok($sformatf("mode 2: %0d line buffers killed by a write, an eviction or a TLB replacement", u_l1i.cnt_kills - bp_serv0));
        if (u_l1i.cnt_tgt_serves == bp_tgt0) fail("mode 2: no taken branch ever served with zero stall");
        else ok($sformatf("mode 2: %0d taken branches served with ZERO stall (resolved at the operand)", u_l1i.cnt_tgt_serves - bp_tgt0));
        $display("    mode 2 ifetch: %0d turbo, %0d slow - %.1f%% of the instruction stream at one clock",
                 turbo_ops, u_l1i.cnt_slow_i - bp_slow0,
                 100.0 * real'(turbo_ops) / real'(turbo_ops + (u_l1i.cnt_slow_i - bp_slow0)));
        // The data front: the shadow owns zp/stack, the CAM RAM/LC reads
        // beyond it, the last byte the CMOS dummy re-reads.  sim/accel.s
        // lives in zero page and walks absolute memory like any 6502
        // program, so a server that never fires is a wiring failure, not a
        // workload property.
        if (u_l1d.cnt_serves < 100)
            fail($sformatf("mode 2: L1-D served only %0d reads", u_l1d.cnt_serves));
        else ok($sformatf("mode 2: %0d data reads served by L1-D (%0d line claims, %0d splices)",
                          u_l1d.cnt_serves, u_l1d.cnt_claims, u_l1d.cnt_splices));
        // ---- the three-clock read (rung 5) --------------------------------
        // Every read outside the shadow's estate that the one-clock servers
        // do not hold is served from the page cache's row through the TLB;
        // sim/accel.s walks absolute memory, so the path must fire, its
        // launches must mostly land, and the data side must have taught the
        // TLB pages of its own.
        $display("    L1-D three-clock reads: %0d served, %0d launched, %0d abandoned; %0d TLB fills from the data side",
                 u_l1d.cnt_l2_serves, u_l1d.cnt_l2_launch, u_l1d.cnt_l2_abort, u_l1d.cnt_tlb_fills);
        if (u_l1d.cnt_l2_serves == 0)
            fail("mode 2: no read was ever served from the page cache's row through the TLB");
        else ok($sformatf("mode 2: %0d reads served at three clocks from the page cache's row (%0d launches, %0d abandoned)",
                          u_l1d.cnt_l2_serves, u_l1d.cnt_l2_launch, u_l1d.cnt_l2_abort));
        if (u_l1d.cnt_tlb_fills == 0)
            fail("mode 2: the data side never filled a TLB entry");
        else ok($sformatf("mode 2: %0d TLB entries filled from the data side", u_l1d.cnt_tlb_fills));
        // ...and the TLB's (rung 4): revaltest's loop runs from ROM across
        // sixteen RAMRD flips, and ROM pages live in a region RAMRD does not
        // touch - so the TLB must keep a live entry through every one of them.
        $display("    TLB revalidation: %0d map changes, %0d left a live entry",
                 tlb_revals, tlb_reval_alive);
        if (tlb_reval_alive == 0)
            fail("mode 2: the TLB never kept an entry across a map change - it is still flushing");
        else ok($sformatf("mode 2: the TLB kept a live entry across %0d of %0d map changes",
                          tlb_reval_alive, tlb_revals));
        if (u_l1d.cnt_lr_serves == 0)
            fail("mode 2: the last row never served a read");
        else ok($sformatf("mode 2: %0d reads served from the last row", u_l1d.cnt_lr_serves));
        if (u_l1d.cnt_lb_serves == 0)
            fail("mode 2: the last-byte register never served a dummy re-read");
        else ok($sformatf("mode 2: %0d dummy re-reads served from the last byte", u_l1d.cnt_lb_serves));
        if (dline_bad != 0) fail($sformatf("mode 2: %0d dline serves wrong or out of bounds", dline_bad));
        // Rung 3: writes at one clock.  sim/accel.s's wrtest pushes deeper
        // than the posted FIFO and reads fresh lines straight back; the
        // program's own stores go through the shadow and the CAM all the
        // time.  Every posted write drains through the classified stage
        // exactly once, and its event is never the one the merge drops.
        if (u_l1d.cnt_posts == 0) fail("mode 2: no write retired in one clock on the data front");
        else ok($sformatf("mode 2: %0d writes retired in one clock by the data front (%0d clocks waited for room, %0d aux misses at the drain)",
                          u_l1d.cnt_posts, u_l1d.cnt_post_waits, u_cache.cnt_posted_miss));
        if (u_cache.cnt_posted_miss == 0) fail("mode 2: no posted write ever raised the aux page engine at its drain");
        else ok($sformatf("mode 2: %0d posted writes drained through the aux miss engine", u_cache.cnt_posted_miss));
        if (merge_gaps != 0) fail($sformatf("mode 2: %0d consecutive bus ops did not ride consecutive cycles", merge_gaps));
        else ok("mode 2: consecutive bus ops rode consecutive cycles");
        if (phys_diff(0) == 0) fail("mode 2: the machine's memory still equals the reference - writes went out");
        else ok("mode 2: the machine's memory is stale, as it must be");
        check_image("mode 2: the image equals the reference");

        // ---- 4. the governor, with the merge's write room withheld at random -----------
        // A write that cannot emit its event waits, claiming the dispatcher;
        // it never falls to the dispatcher and never loses its event.
        clear_counters();
        @(negedge clk); target <= 16'h0400; room_rand <= 1'b1;     // 4.0
        n0 = pass_count;
        wait_passes(n0 + 3, "mode 2 at 4.0");
        check_ratio(4.0, "governor at 4.0");
        clear_counters();
        @(negedge clk); target <= 16'h0100;     // 1.0
        n0 = pass_count;
        wait_passes(n0 + 2, "mode 2 at 1.0");
        check_ratio(1.0, "governor at 1.0");
        @(negedge clk); target <= 16'd0; room_rand <= 1'b0;
        common_checks("the governor");
        if (u_l1d.cnt_post_waits == 0) fail("the governor: the merge's room was withheld and no write ever waited");
        else ok($sformatf("the governor: writes waited %0d clocks for the merge's room and retired on the front all the same (%0d)",
                          u_l1d.cnt_post_waits, u_l1d.cnt_posts));

        // ---- 5. a DMA, in mode 2 ---------------------------------------------------------
        ovr_cycles = 0; dma_last_hits = 0;
        dma(16);
        repeat (4 * CYCLE) @(negedge clk);
        if (ovr_cycles != 16) fail($sformatf("%0d override cycles, expected 16", ovr_cycles));
        else if (card_main(16'h2100) !== 8'h80 || card_main(16'h210F) !== 8'h8F || main_ram[16'h2100] !== 8'h80 || ref_main[16'h210F] !== 8'h8F)
            fail("the DMA's writes did not reach the image, the machine and the reference alike");
        else if (dma_last_hits == 0) fail("the DMA's last byte did not commit under its own address");
        else ok("a DMA through the override path, under acceleration: 16 cycles, every byte landed, the last one's commit its own");
        n0 = pass_count;
        wait_passes(n0 + 2, "mode 2 after the DMA");
        common_checks("after the DMA");

        // ---- 6. the boot hold, armed across a reset; a runtime knock -------------------------
        @(negedge clk); arm <= 1'b1;
        res_n <= 1'b0;
        repeat (5 * CYCLE) @(negedge clk);
        resets = resets + 1;
        res_n <= 1'b1;
        c = 0;
        while (!held && c < 20 * CYCLE) begin @(posedge clk); c = c + 1; end
        if (!held) fail("the armed boot hold did not engage after a reset");
        else begin
            ok("the armed boot hold engaged at the post-reset fetch, with the core accelerating");
            repeat (4 * CYCLE) @(negedge clk);
            if (u_seq.st != u_seq.S_HELD) fail($sformatf("held, but the sequencer is in state %0d", seq_state));
            else ok("...and the sequencer is holding the bus for it");
        end
        fast0 = fast_ops + turbo_ops;
        repeat (3 * CYCLE) @(negedge clk);
        if (fast_ops + turbo_ops != fast0) fail("the core moved while held");
        else ok("the core did not move while held");
        @(negedge clk); arm <= 1'b0; release_req <= 1'b1; @(negedge clk); release_req <= 1'b0;
        c = 0;
        while (held && c < 20 * CYCLE) begin @(posedge clk); c = c + 1; end
        if (held) fail("the hold did not release");
        pass_count = 0;
        wait_passes(2, "after the boot hold, accelerating");
        // The runtime door.
        @(negedge clk); menu_trigger <= 1'b1; @(negedge clk); menu_trigger <= 1'b0;
        c = 0;
        while (!held && c < 20 * CYCLE) begin @(posedge clk); c = c + 1; end
        if (!held || !hold_runtime) fail("the runtime knock did not hold the core at a fetch");
        else ok("a runtime knock holds the accelerating core at its next fetch");
        repeat (3 * CYCLE) @(negedge clk);
        @(negedge clk); release_req <= 1'b1; @(negedge clk); release_req <= 1'b0;
        n0 = pass_count;
        wait_passes(n0 + 2, "after the runtime hold");
        common_checks("the holds");

        // ---- 7. a reset under it -------------------------------------------------------------
        // First leave INTCXROM set, through the override path as the last
        // program on the machine would have: the reset must put it back on
        // the machine, or the program's $C500 read finds the internal ROM
        // where the model expects the slot's - the failure seen on hardware.
        @(negedge clk);
        tb_ovr_en <= 1'b1; tb_ovr_rw <= 1'b0; tb_ovr_addr <= 16'hC007; tb_ovr_wdata <= 8'h00;
        @(negedge clk);
        while (!(op_present && op_ovr && op_addr == 16'hC007)) @(negedge clk);
        tb_ovr_en <= 1'b0;
        repeat (2 * CYCLE) @(negedge clk);
        if (!m_intcx) fail("INTCXROM was not set on the machine before the reset");
        n1 = m_mmu_resets;
        res_n <= 1'b0;
        repeat (5 * CYCLE) @(negedge clk);
        resets = resets + 1;
        res_n <= 1'b1;
        pass_count = 0;
        wait_passes(2, "after a reset, still accelerating");
        if (m_mmu_resets != n1 + 1) fail($sformatf("the machine's MMU saw %0d reset sequences on the pins, expected one", m_mmu_resets - n1));
        else ok("the reset sequence rode the bus: three stack reads, then $FFFC and $FFFD, and the machine's MMU reset");
        if (m_intcx) fail("INTCXROM is still set on the machine after the reset");
        else ok("...so INTCXROM is clear on the machine again, and the slot ROM answers");
        if (late_fills > resets) fail($sformatf("late fills %0d over %0d resets", late_fills, resets));
        else ok($sformatf("late fills %0d, no more than the %0d resets", late_fills, resets));
        if (reads_bad != 0) fail($sformatf("after the reset: %0d reads disagreed", reads_bad)); reads_bad = 0;
        check_image("the image equals the reference after the reset");

        // ---- 8. (gone) an invalidate under the running program ------------------------------------
        // The old cache walked its tags for 512 clocks and declined ops
        // meanwhile, so an invalidate mid-fast-op forced the sequencer's
        // retry path.  The page cache's invalidate is ONE clock, cannot land
        // inside an op (the tags are latched at P1 and the sequencer
        // serializes), only touches the aux tags (main is authoritative and
        // survives), and DISCARDS resident RamWorks pages - a debug lever,
        // not an operation the running machine uses (rtl/page_cache.sv;
        // mem_integ_tb ties it off).  Nothing to prove here any more; the
        // retry path itself still exists for any decision the cache answers
        // without a byte.

        // ---- 9. the end --------------------------------------------------------------------------
        repeat (40 * CYCLE) @(negedge clk);
        n0 = pass_count;
        wait_passes(n0 + 1, "the end");
        // In mode 2 no RAM read ever rides the bus - there is nothing that
        // sends one there - so the monitor, which compares only bus reads,
        // has nothing to count.
        // At most the op the driver had already latched when a mode was
        // switched on under it: once per switch into an accelerated mode.
        if (bus_ram_reads > 2) fail($sformatf("%0d RAM reads rode the bus in modes 1 and 2", bus_ram_reads));
        else ok($sformatf("no RAM read rode the bus while accelerating beyond the %0d in flight at the mode switches: a read the card holds is fast", bus_ram_reads));
        if (mismatches != 0) fail($sformatf("the monitor counted %0d mismatches", mismatches));
        else ok("the monitor saw nothing to disagree with");
        if (irq_acks < 100) fail($sformatf("only %0d interrupts were serviced - the storm did not run", irq_acks));
        else ok($sformatf("%0d interrupts raised, %0d serviced across the data-front storm", irq_count, irq_acks));
        if (reads_bad != 0) fail($sformatf("the end: %0d reads disagreed with the reference", reads_bad));
        else ok($sformatf("the end: %0d reads (%0d fast), every one the reference's byte", reads, fast_reads));
        if (dummies_bad != 0 || fast_bus_cls != 0 || late_fills != 0 || fifo_drops != 0)
            fail("the end: a bad dummy, a fast BUS-class op, a late fill or a drop");
        // The program is still running as these are sampled: up to the posted
        // FIFO's depth plus the drain pipeline may be between retire and
        // drain, and up to the merge's depth between push and pop.
        if (drained > dline_writes || dline_writes - drained > 8)
            fail($sformatf("the end: %0d writes retired on the front, %0d drained through the classified stage", dline_writes, drained));
        else ok($sformatf("the end: every one of the %0d posted writes drained through the classified stage exactly once, beside the ROM's %0d", dline_writes, rom_drained));
        if (mg_write_drops != 0 || mg_write_out > mg_write_in || mg_write_in - mg_write_out > 8)
            fail($sformatf("the end: the merge took %0d write words, dropped %0d, delivered %0d", mg_write_in, mg_write_drops, mg_write_out));
        else ok($sformatf("the end: the merge took %0d write words and dropped none (%0d overflows of any kind)", mg_write_in, mg_overflows));
        if (u_core_ops != fast_ops + bus_ops + seq_cycen - seq_cycen) ;  // informational

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

endmodule
