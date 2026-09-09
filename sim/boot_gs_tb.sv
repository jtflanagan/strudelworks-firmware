`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// boot_gs_tb - the IIgs ROM booting on the card, in simulation.
//
// The GS sibling of sim/boot_tb.sv, and deliberately a much smaller machine.
// boot_tb boots a real operating system off a real .hdv and checks every byte
// the core reads against a reference memory it keeps in program order; this
// bench has a better oracle than any reference it could keep, because KEGS has
// already executed the same ROM instruction for instruction
// (tools/kegs/README.md).  So there is no reference memory here, no host
// model and no disk: there is the ROM, the card's memory path, the soft
// 65816 - and a trace, compared against KEGS's by tools/trace_diff816.py.
//
// WHAT IS IN IT.  cpu65816 on rtl/accel_seq.sv's dispatcher (GS = 1: no
// fronts, docs/GS.md rung 3), rtl/apple_mmu.sv with GS = 1 and its 24-bit op
// path, rtl/rom_loader.sv carrying 512 chunks of ROM 3 to physical bank $FC,
// rtl/page_cache.sv, rtl/page_client.sv and a DDR3 stub behind them, and
// rtl/apple_bus_write.sv driving a IIe backplane that answers nothing.
//
// WHAT IS NOT IN IT YET, and why the trace is expected to diverge.  The IIgs
// chipset - the VGC registers, the ADB micro, the clock and battery RAM, the
// interrupt controller, the IWM and SCC stubs - is rung 3b's `gs_io.sv`.
// Until it exists, every $C0xx access is BUS class and rides a real bus cycle
// to a backplane that returns FLOAT_BYTE, so the ROM's first read of a
// register that matters is where this bench parts company with KEGS.  THAT
// INDEX IS THE MEASUREMENT: it is printed as `divergence at instruction N`,
// and rung 3b's job is to move it.  The bench therefore does not FAIL on a
// divergence - it reports one - and fails only on the things that would mean
// the machine itself is wrong: the ROM not loading, the core not reaching the
// reset vector's target, a cache mismatch, a dropped duplicate, an address
// outside the image.
//
// THE TRACE, one twenty-byte record per instruction, in KEGS's own shape so
// the two decode with the same code:
//     w0 {dbr[7:0], pbr[7:0], pc[15:0]}    w1 {op[7:0], 24'd0}
//     w2 {psr[15:0] (bit 8 = E), a[15:0]}  w3 {x[15:0], y[15:0]}
//     w4 {s[15:0], d[15:0]}
// The registers are the ones the instruction LEFT BEHIND, which is what KEGS
// logs: a record is emitted at the fetch of the NEXT instruction, when the
// previous one's last writeback has landed and the new opcode is on din.
//////////////////////////////////////////////////////////////////////////////////
module boot_gs_tb #(parameter UCODE  = "cpu65816_ucode.hex",
                    parameter UCODE0 = "cpu65816_ucode0.hex",
                    parameter USEQ0  = "cpu65816_useq0.hex",
                    parameter ROMF   = "gsrom.hex",     // 256K ROM 3, xxd -p -c1
                    parameter TRACEF = "boot_gs.trc",
                    parameter integer ROM_CHUNKS = 512,
                    parameter integer MODE = 2,
                    parameter integer TARGET = 0,
                    parameter integer MAX_INSTRS = 200000,
                    parameter integer MAX_CLKS = 400000000,
                    parameter integer PHI0_HIGH = 49,
                    // What the IIe backplane puts on the data pins when
                    // nothing drives them.  KEGS's unclaimed I/O reads return
                    // the floating bus; until gs_io answers, a constant is
                    // both honest and repeatable.
                    parameter [7:0] FLOAT_BYTE = 8'h00,
                    // Seconds since 1904-01-01; see the gs_io wiring below.
                    parameter [31:0] SEED_TIME = 32'd3871713600);

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
    integer bus_cycles = 0;
    always @(posedge clk) if (fall) bus_cycles = bus_cycles + 1;
    // The IIgs frame is the IIe's: 262 lines x 65 cycles = 17030 bus cycles at
    // 59.92 Hz (docs/GS.md).  One pulse per frame is the interrupt
    // controller's whole clock; on the card it comes from rtl/vbeam.sv, which
    // counts the machine's own cycles so an accelerated program sees the same
    // number of VBLs per program-second.
    reg frame_tick = 1'b0;
    always @(posedge clk)
        frame_tick <= fall && (bus_cycles % 17030 == 17029);

    // ---- the backplane, the reader and the driver --------------------------------
    reg  res_n = 1'b1;
    wire cpu_rst = rst || !res_n;
    reg  master_active = 1'b1;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, driving, drv_sync;
    wire [7:0]  data_drive;
    wire        phi0_sync, res_sync, bus_tick;
    wire [7:0]  data_sync;
    wire        mem_sub_en, bus_owns, core_valid;
    wire [7:0]  mem_sub_data;
    // The card's byte reaches the reader only for a bus op it answered.
    wire        sub_en   = mem_sub_en && bus_owns;
    wire [7:0]  sub_data = mem_sub_data;
    // The IIe on the pins: it holds no memory this machine uses and no card
    // this machine talks to, so it answers every read with the same byte.
    wire [7:0]  data_pin = data_oe ? data_drive : FLOAT_BYTE;

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

    // ---- the core ---------------------------------------------------------------
    wire [23:0] cpu_a24;
    wire [15:0] cpu_addr = cpu_a24[15:0];
    wire [7:0]  cpu_bank = cpu_a24[23:16];
    wire        cpu_rw, cpu_sync, cpu_cyc_en;
    wire        cpu_vda, cpu_vpa, cpu_vpb, cpu_emu, cpu_halted;
    wire [7:0]  cpu_dout, cpu_din;
    // The census's "this cycle is an instruction fetch" is the 65816's VPA.
    wire        cpu_cyc_is_i = cpu_vpa;

    cpu65816 #(.UCODE_FILE (UCODE), .UCODE0_FILE (UCODE0), .USEQ0_FILE (USEQ0)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_a24), .rw (cpu_rw), .dout (cpu_dout), .din (cpu_din),
        // The chipset's one interrupt line, active low into the core.
        .irq_n (!gsio_irq), .nmi_n (1'b1),
        .sync (cpu_sync), .vda (cpu_vda), .vpa (cpu_vpa), .vpb (cpu_vpb),
        .emu (cpu_emu), .halted (cpu_halted)
    );

    // ---- the dispatcher ----------------------------------------------------------
    reg  [1:0]  mode = 2'd0;
    reg  [15:0] target = 16'd0;
    reg         serve = 1'b0;
    wire        u_present, u_commit, u_rw, u_sync, u_ovr, u_divert;
    wire [15:0] u_addr;
    wire [7:0]  u_bank, u_wdata;
    wire        fev_valid, fev_rw, fev_sync;
    wire [15:0] fev_addr;
    wire [7:0]  fev_bank, fev_data;
    wire        accel_on, decided, busy;
    wire [1:0]  q_cls;
    wire [3:0]  seq_state;
    wire [31:0] fast_ops, bus_ops, cycles, wait_clocks, accel_maps, turbo_ops;
    wire [7:0]  retries;
    wire        mem_image_ready, mem_invalidating;
    wire        q_swi_mmu, q_swi_quiet, q_slot, swi_commit, sl_win, seq_slot_q;
    wire [7:0]  mmu_swi_stat;
    // The chipset's face (rtl/gs_io.sv, docs/GS.md rung 3b): what it claims
    // joins the dispatcher's internalized-op question, and its byte joins the
    // internalized read's answer.  apple_mmu's own swi is OFF on this build
    // (swi_on tied low), so the two never both claim.
    wire [7:0]  gs_shadow_w, gs_cyareg_w, gs_sltrom_w, gs_state_w;
    wire        gsio_claim, gsio_u_claim;
    wire [7:0]  gsio_byte;
    wire        gsio_irq;
    wire        q_swi = q_swi_mmu || gsio_claim;
    // The byte mux follows the REGISTERED op, exactly as master_top's does.
    wire [7:0]  swi_byte = gsio_u_claim ? gsio_byte : mmu_swi_stat;
    wire        map_changed, map_settling;

    // The fronts are OFF on the GS build (docs/GS.md rung 6 turns them on):
    // everything the core does goes through the dispatcher, so every retire
    // is the dispatcher's and the front-side books are tied still.
    accel_seq #(.GS (1'b1)) u_seq (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .master_active (master_active),
        .mode (mode), .target (target), .cnt_clr (1'b0),
        .q_swi (q_swi), .q_swi_quiet (q_swi_quiet), .swi_byte (swi_byte),
        .swi_commit (swi_commit), .fast_tick (), .fev_quiet (),
        .q_slot (q_slot), .slot_q_o (seq_slot_q), .sl_win (sl_win),
        .stall (1'b0),
        .mem_serve (serve), .mem_image_ready (mem_image_ready), .mem_invalidating (mem_invalidating),
        .q_cls (q_cls),
        .cpu_addr (cpu_addr), .cpu_bank (cpu_bank), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .cyc_is_i (cpu_cyc_is_i),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .turbo_en (), .turbo_ok (),
        .turbo_commit (1'b0), .d_commit (1'b0), .turbo_claim (1'b0),
        .turbo_wr (), .d_pending (1'b0),
        .op_present (op_present), .op_commit (op_commit), .op_dummy (op_dummy), .op_ovr (op_ovr),
        .op_divert (op_divert), .op_sync (drv_sync), .op_addr (op_addr), .op_rw (op_rw),
        .op_wdata (op_wdata), .cyc_done (drv_cyc_done), .drv_din (drv_din),
        .op_inflight (op_inflight), .ovr_en (1'b0),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .mem_sub_en (mem_sub_en), .mem_sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mq_valid (1'b0),
        .bus_tick (bus_tick),
        .u_present (u_present), .u_commit (u_commit), .u_addr (u_addr), .u_bank (u_bank),
        .u_rw (u_rw), .u_wdata (u_wdata), .u_sync (u_sync), .u_ovr (u_ovr), .u_divert (u_divert),
        .fev_valid (fev_valid), .fev_addr (fev_addr), .fev_bank (fev_bank), .fev_rw (fev_rw),
        .fev_data (fev_data), .fev_sync (fev_sync),
        .accel_on (accel_on), .held_governor (), .state_o (seq_state), .reset_seq_o (),
        .fast_ops (fast_ops), .map_changed (map_changed), .map_settling (map_settling),
        .maps (accel_maps), .cen_v (), .cen_sel (), .turbo_ops (turbo_ops), .bus_ops (bus_ops),
        .cycles (cycles), .wait_clocks (wait_clocks), .retries (retries)
    );

    apple_bus_write #(.T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT), .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)) u_write (
        .clk (clk), .rst (rst), .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active), .park_kbd (1'b0), .park_addr (16'h0000),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync),
        .drv_sync (drv_sync), .cyc_en (drv_cyc_done), .cpu_din (drv_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (1'b0), .slot_rd_data (8'd0),
        .din_sub_en (sub_en), .din_sub_data (sub_data),
        .ovr_en (1'b0), .ovr_addr (16'd0), .ovr_rw (1'b1), .ovr_wdata (8'd0),
        .op_ovr (op_ovr), .op_dummy (op_dummy), .op_inflight (op_inflight),
        .nxt_addr (nxt_addr), .divert (serve && q_divert), .op_divert (op_divert),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the memory path, on the unified stream ----------------------------------
    wire        cl_valid, cl_rw, cl_wr_image, cl_aux, cl_posted, cl_sh, intc8rom;
    wire [1:0]  cl_cls;
    wire [7:0]  cl_bank, cl_wdata, shd_drops;
    wire [15:0] cl_off, pf_off, cl_ppn_w, pf_ppn_w;
    wire [11:0] sw_state;
    wire [7:0]  rw_bank, rwb_p1_w;
    wire        rom_loaded, invalidating, image_ready, refresh_ok, rot_ok, mem_idle;
    wire [31:0] hits, misses, served, mismatches, last_mismatch, diverted;
    wire [7:0]  late_fills, fifo_drops;
    reg         msg_valid = 1'b0, pay_valid = 1'b0;
    reg  [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    reg  [31:0] pay_data = 32'd0;
    wire        pq_busy, pq_valid, pq_we, pq_ready, pr_valid;
    wire [19:0] pq_line;
    wire [127:0] pq_wdata, pr_data;
    wire        pw_take_w, pw_ready_w;
    wire [15:0] p_ppn_w, d_ppn_w;
    wire [3:0]  p_reg_w, d_reg_w;
    wire        p_fold_w, p_fs_w, d_fold_w;
    wire [1:0]  p_cls;
    wire        p_aux_w;
    wire [15:0] p_off_w;
    wire [1:0]  dcls_w;
    wire        daux_w;
    wire [15:0] doff_w;
    wire [103:0] rt_rd_flat;
    assign mem_image_ready = image_ready;
    assign mem_invalidating = invalidating;

    apple_mmu #(.GS (1'b1)) u_mmu (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_bank (u_bank), .op_addr (u_addr), .op_rw (u_rw), .op_wdata (u_wdata),
        .op_present (u_present), .op_commit (u_commit),
        .rom_ok (rom_loaded),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .intc8rom (intc8rom),
        .cl_posted (cl_posted), .cl_sh (cl_sh), .shd_drops (shd_drops), .cl_wdata (cl_wdata),
        .pw_valid (rl_pw_valid), .pw_ppn (rl_pw_ppn), .pw_off (rl_pw_off),
        .pw_data (rl_pw_data), .pw_ready (pw_ready_w), .pw_take (pw_take_w),
        .pf_off (pf_off),
        .sw_state (sw_state), .vid_sw (), .rw_bank (rw_bank),
        .gs_shadow_o (gs_shadow_w), .gs_cyareg_o (gs_cyareg_w),
        .gs_sltrom_o (gs_sltrom_w), .gs_state_o (gs_state_w),
        .q_addr ({cpu_bank, nxt_addr}), .q_divert (q_divert), .q_rw (cpu_rw), .q_cls (q_cls),
        // Nothing is internalized on the GS build yet: $C0xx is BUS class and
        // rides a real cycle until rtl/gs_io.sv answers it (rung 3b).
        .swi_on (1'b0), .swi_kbd_ok (1'b0), .swi_fb_ok (1'b0),
        .swi_vbl_ok (1'b0), .swi_vbl_bar (1'b1), .swi_kbd_low (7'd0),
        .swi_pb_ok (1'b0), .swi_pdl_ok (1'b0),
        .swi_hd_slot (3'd0), .swi_fd_slot (3'd0), .swi_mb_slot (3'd0),
        .swi_mouse_slot (3'd0), .swi_u2_slot (3'd0), .swi_prn_slot (3'd0),
        .q_nsc (), .q_slot (q_slot), .q_swi (q_swi_mmu), .q_swi_quiet (q_swi_quiet),
        .swi_stat_byte (mmu_swi_stat),
        .p_addr (24'd0), .p_cls (p_cls), .p_aux (p_aux_w), .p_off (p_off_w),
        .d_addr (24'd0), .d_rw (1'b1), .d_cls (dcls_w), .d_aux (daux_w), .d_off (doff_w),
        .map_changed (map_changed),
        .cl_ppn (cl_ppn_w), .pf_ppn (pf_ppn_w),
        .p_ppn (p_ppn_w), .p_reg (p_reg_w), .p_fold (p_fold_w), .p_fs (p_fs_w),
        .d_ppn (d_ppn_w), .d_reg (d_reg_w), .d_fold (d_fold_w),
        .map_settling (map_settling), .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1_w)
    );

    // ---- the IIgs chipset on $C0xx ------------------------------------------------
    // One instance, two claims: `claim` off the LIVE address for the
    // dispatcher's decision, and `u_claim` off the REGISTERED op for the byte
    // mux (rtl/gs_io.sv, "the two faces of an op").
    gs_io u_gsio (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .q_addr ({cpu_bank, nxt_addr}), .q_rw (cpu_rw), .claim (gsio_claim),
        .u_bank (u_bank), .u_addr (u_addr), .u_rw (u_rw), .u_wdata (u_wdata),
        .u_commit (swi_commit),
        .gs_shadow (gs_shadow_w), .gs_cyareg (gs_cyareg_w),
        .gs_sltrom (gs_sltrom_w), .gs_state (gs_state_w),
        // PINNED TO KEGS's OWN CLOCK.  tools/kegs/trace_rom.sh runs the
        // reference with -pintime 3871713600 (2026-09-08 12:00:00 since
        // 1904) so its trace is the same every run; the card must believe the
        // same seconds or the two disagree about a byte the ROM checksums.
        .seed_time (SEED_TIME), .border (),
        .frame_tick (frame_tick),
        .u_claim (gsio_u_claim), .rd_byte (gsio_byte), .irq (gsio_irq)
    );

    // ROM 3 is 512 chunks of 512 bytes landing at physical bank $FC page $00.
    wire        rl_pw_valid;
    wire [15:0] rl_pw_ppn;
    wire [7:0]  rl_pw_off, rl_pw_data;
    wire        rom_busy;
    wire [7:0]  rom_overruns;
    rom_loader #(.N_CHUNKS (ROM_CHUNKS), .ROM_PPN0 (16'hFC00)) u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .op_present (u_present), .image_ready (image_ready),
        .pw_valid (rl_pw_valid), .pw_ppn (rl_pw_ppn), .pw_off (rl_pw_off),
        .pw_data (rl_pw_data), .pw_take (pw_take_w),
        .busy (rom_busy), .overruns (rom_overruns), .rom_ok (rom_loaded)
    );

    page_cache u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_ppn (cl_ppn_w), .cl_off (cl_off[7:0]),
        .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_wdata (cl_wdata), .cl_posted (cl_posted),
        .pw_pending (1'b0), .pw_ready (pw_ready_w),
        .pf_ppn (pf_ppn_w), .pf_off (pf_off[7:0]),
        .pw_take (pw_take_w), .pw_ppn (rl_pw_ppn), .pw_off (rl_pw_off),
        .op_addr (u_addr),
        .op_present (u_present), .op_commit (u_commit), .op_divert (u_divert), .data_sync (data_sync),
        .sub_en (mem_sub_en), .sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mw_stb (), .mw_addr (), .mw_byte (),
        .il_req (1'b0), .il_ppn (16'd0), .il_line (4'd0), .il_src (1'b0),
        .il_ack (), .il_done (), .il_ok (), .il_row (),
        .serve (serve), .inval (1'b0), .cnt_clr (1'b0), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (diverted), .late_fills (late_fills),
        .fifo_drops (fifo_drops),
        .mem_fills (mem_fills), .mem_flushes (mem_flushes), .mem_declines (mem_declines),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data)
    );
    wire [31:0] mem_fills, mem_flushes, mem_declines;

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

    // ---- the DDR3 stub: the whole 16 MB, in order, twelve clocks late -------------
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
    integer     ddr_range_bad = 0;
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

    // ---- the trace ---------------------------------------------------------------
    // One record per instruction, emitted at the NEXT instruction's fetch so
    // the registers are the ones this instruction left (see the header).
    reg boot_go = 1'b0, have_prev = 1'b0;
    reg [7:0]  pv_pbr = 8'd0, pv_op = 8'd0;
    reg [15:0] pv_pc = 16'd0;
    integer tf, trace_instrs = 0;
    initial tf = $fopen(TRACEF, "wb");

    wire [15:0] cpu_psr = {7'd0, u_cpu.f_e,
                           u_cpu.f_n, u_cpu.f_v, u_cpu.f_m, u_cpu.f_x,
                           u_cpu.f_d, u_cpu.f_i, u_cpu.f_z, u_cpu.f_c};
    // The opcode is on din at the edge that ends the fetch cycle.
    wire fetch_now = boot_go && !cpu_rst && cpu_cyc_en && cpu_sync;

    always @(posedge clk) if (fetch_now) begin
        if (have_prev) begin
            $fwrite(tf, "%u%u%u%u%u",
                    {u_cpu.dbr, pv_pbr, pv_pc},
                    {pv_op, 24'd0},
                    {cpu_psr, u_cpu.a},
                    {u_cpu.x, u_cpu.y},
                    {u_cpu.s, u_cpu.d});
            trace_instrs = trace_instrs + 1;
        end
        pv_pbr <= cpu_bank; pv_pc <= cpu_addr; pv_op <= cpu_din;
        have_prev <= 1'b1;
    end

    // ---- the I/O census: what the ROM asks the chipset for -------------------------
    // Every $C0xx the ROM touches, counted by address and direction, with the
    // instruction number of the FIRST touch.  This is rung 3b's work list in
    // the ROM's own order (docs/GS.md): a register with an early first touch
    // and a large count is one the machine is waiting on.
    integer io_rd [0:255];
    integer io_wr [0:255];
    integer io_first [0:255];
    integer ic;
    initial for (ic = 0; ic < 256; ic = ic + 1) begin
        io_rd[ic] = 0; io_wr[ic] = 0; io_first[ic] = -1;
    end
    // A IIgs sees I/O at $C0xx in a pair bank only, which is the rule the map
    // applies; the census counts what the map would call I/O.
    wire io_touch = boot_go && u_present && (u_addr[15:8] == 8'hC0) &&
                    ((u_bank == 8'h00) || (u_bank == 8'h01) ||
                     (u_bank == 8'hE0) || (u_bank == 8'hE1));
    always @(posedge clk) if (io_touch) begin
        if (u_rw) io_rd[u_addr[7:0]] = io_rd[u_addr[7:0]] + 1;
        else      io_wr[u_addr[7:0]] = io_wr[u_addr[7:0]] + 1;
        if (io_first[u_addr[7:0]] < 0) io_first[u_addr[7:0]] = trace_instrs;
    end
    task dump_io_census;
        integer k, touched;
        begin
            touched = 0;
            $display("    ---- the $C0xx census: addr, reads, writes, first touch ----");
            for (k = 0; k < 256; k = k + 1)
                if (io_rd[k] != 0 || io_wr[k] != 0) begin
                    touched = touched + 1;
                    $display("      $C0%02X  r %-9d w %-9d first @ %0d", k,
                             io_rd[k], io_wr[k], io_first[k]);
                end
            $display("    %0d distinct $C0xx addresses touched", touched);
        end
    endtask

    // ---- the engine's overruns, named ---------------------------------------------
    // late_fills is "an op missed while the fill engine was busy, and was not
    // served" - which for a write means the byte is gone.  boot_tb asserts it
    // is zero; this bench does too, and prints the op that was blocked and
    // what the engine was doing, because on the GS there is a producer the
    // IIe never had: the SHADOW DUPLICATE, which starts a fill of its own one
    // clock behind its op and is outside the dispatcher's `busy` gate.
    reg [7:0] lf_q = 8'd0, fd_q = 8'd0;
    always @(posedge clk) begin
        lf_q <= late_fills; fd_q <= fifo_drops;
        if (late_fills != lf_q)
            $display("    LATE FILL #%0d at %0d clocks: blocked op ppn $%04X off $%02X rw %0d posted %0d; engine state %0d on ppn $%04X",
                     late_fills, now, u_cache.s_ppn, u_cache.s_off, u_cache.s_rw,
                     u_cache.s_posted, u_cache.state, u_cache.e_ppn);
        if (fifo_drops != fd_q)
            $display("    FIFO DROP #%0d at %0d clocks", fifo_drops, now);
    end

    // ---- the heartbeat -----------------------------------------------------------
    reg [23:0] last_sync = 24'd0;
    always @(posedge clk) if (cpu_cyc_en && cpu_sync) last_sync <= cpu_a24;
    always @(posedge clk) if (now % 2_000_000 == 1_999_999)
        $display("    ...%0d clocks, %0d bus cycles, %0d instructions, PC~$%02X/%04X, fast %0d bus %0d, fills %0d",
                 now + 1, bus_cycles, trace_instrs, last_sync[23:16], last_sync[15:0],
                 fast_ops, bus_ops, mem_fills);

    // ---- ROM loading -------------------------------------------------------------
    reg [7:0] rom_img [0:262143];
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
            while (rom_busy) @(negedge clk);
        end
    endtask

    // ---- the run -----------------------------------------------------------------
    integer a, c;
    initial begin
        $readmemh(ROMF, rom_img);
        for (a = 0; a < IMG; a = a + 1) smem[a] = 8'h00;

        $display("boot_gs_tb: GS=1 MODE %0d TARGET %04x ROM %0d chunks, max %0d instructions / %0d clocks",
                 MODE, TARGET, ROM_CHUNKS, MAX_INSTRS, MAX_CLKS);

        repeat (5) @(negedge clk);
        rst <= 1'b0;
        @(negedge clk);
        for (c = 0; c < ROM_CHUNKS; c = c + 1) send_chunk(c);
        if (!rom_loaded) fail("the IIgs ROM did not load");
        else ok($sformatf("the IIgs ROM loaded: %0d chunks into bank $FC", ROM_CHUNKS));
        if (rom_overruns != 0)
            fail($sformatf("%0d ROM chunks were dropped: the load outran the seam", rom_overruns));

        serve <= 1'b1;
        mode <= 2'(MODE);
        target <= 16'(TARGET);

        res_n <= 1'b0;
        repeat (5 * CYCLE) @(negedge clk);
        res_n <= 1'b1;
        boot_go <= 1'b1;
        $display("boot_gs_tb: reset released, the ROM runs");

        while (now < MAX_CLKS && trace_instrs < MAX_INSTRS) @(posedge clk);
        $fflush(tf);

        $display("boot_gs_tb: done at %0d clocks / %0d bus cycles / %0d instructions",
                 now, bus_cycles, trace_instrs);
        $display("    counters: fast_ops %0d bus_ops %0d cycles %0d maps %0d retries %0d",
                 fast_ops, bus_ops, cycles, accel_maps, retries);
        $display("    cache: hits %0d misses %0d fills %0d flushes %0d declines %0d late %0d drops %0d",
                 hits, misses, mem_fills, mem_flushes, mem_declines, late_fills, fifo_drops);
        $display("    last PC $%02X/%04X", last_sync[23:16], last_sync[15:0]);
        dump_io_census();

        // The machine itself, not the ROM's opinion of it.
        if (trace_instrs == 0) fail("the core executed nothing");
        else ok($sformatf("%0d instructions executed and traced", trace_instrs));
        if (mismatches != 0)
            fail($sformatf("the cache's monitor counted %0d mismatches (last %08x)", mismatches, last_mismatch));
        if (late_fills != 0 || fifo_drops != 0)
            fail($sformatf("late fills %0d, drops %0d", late_fills, fifo_drops));
        if (shd_drops != 0)
            fail($sformatf("%0d shadow duplicates were dropped", shd_drops));
        if (ddr_range_bad != 0)
            fail($sformatf("%0d DDR3 addresses outside the image", ddr_range_bad));
        if (cpu_halted) fail("the core executed STP");

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $fclose(tf);
        $finish;
    end
endmodule
