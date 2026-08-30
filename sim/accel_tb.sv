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
// and a runtime knock; a reset; an invalidate under the running program; the
// floppy's slow zone.  Throughout: every dummy is the parked $0000 read, no
// fast op is BUS class, every BUS-class op rode exactly one bus cycle, two
// consecutive BUS ops rode consecutive cycles, no request was dropped.
//////////////////////////////////////////////////////////////////////////////////
module accel_tb #(parameter UCODE = "cpu65c02_ucode.hex",
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
    wire        sub_en   = mem_sub_en && bus_owns;
    wire [7:0]  sub_data = mem_sub_data;
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
    wire        cpu_rw, cpu_sync, cpu_cyc_en;
    wire [7:0]  cpu_dout, cpu_din;
    cpu65c02 #(.UCODE_FILE (UCODE)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .din (cpu_din),
        .irq_n (1'b1), .nmi_n (1'b1), .sync (cpu_sync), .halted ()
    );

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

    accel_seq u_seq (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .master_active (master_active),
        .mode (mode), .target (target), .cnt_clr (cnt_clr),
        .mem_serve (serve), .mem_image_ready (mem_image_ready), .mem_invalidating (mem_invalidating),
        .q_cls (q_cls),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
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
        .fast_ops (fast_ops), .bus_ops (bus_ops), .cycles (cycles), .wait_clocks (wait_clocks),
        .retries (retries)
    );

    apple_bus_write #(.T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT), .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)) u_write (
        .clk (clk), .rst (rst), .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active),
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
        .cpu_sync (cpu_sync),
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

    // A slot-5 card ROM on the pins, the way the hard disk holds one: every
    // slot is BUS class, so the core reads it over the bus in every mode.
    localparam [2:0] HD_SLOT = 3'd5;
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
        .q_addr (nxt_addr), .q_divert (q_divert), .q_rw (cpu_rw), .q_cls (q_cls)
    );
    apple_rom u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .rd_en (cl_valid), .rd_addr (cl_rom_addr), .rd_data (rom_byte_int), .rom_loaded (rom_loaded)
    );
    mem_cache u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_pa (cl_pa), .cl_rw (cl_rw),
        .cl_wr_image (cl_wr_image), .op_addr (u_addr), .op_wdata (u_wdata),
        .op_present (u_present), .op_commit (u_commit), .op_divert (u_divert), .data_sync (data_sync),
        .rom_byte (rom_byte), .rom_loaded (1'b1),
        .sub_en (mem_sub_en), .sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .serve (serve), .inval (inval), .cnt_clr (1'b0), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (diverted), .late_fills (late_fills), .fifo_drops (fifo_drops),
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data)
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
    mem_client u_client (
        .clk (clk), .rst (rst), .calib_complete (1'b1),
        .master_active (master_active), .op_present (op_present),
        .accel (accel_on),
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data),
        .req (c_req[1]), .gnt (c_gnt[1]), .cyc (c_cyc[1]), .stb (c_stb[1]),
        .we (c_we[1]), .addr (c_addr[47:24]), .data (c_data[255:128]), .sel (c_sel[31:16]),
        .stall (c_stall[1]), .ack (c_ack[1]), .rdata (c_rdata),
        .refresh_ok (refresh_ok), .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

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
    // What the core must read at `a`, from the reference: everything but $C0xx.
    function automatic [7:0] exp_read(input [15:0] a);
        begin
            if (a[15:12] == 4'hC) exp_read = cx_byte(a);
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
                data_pin <= (addr_drive[7:4] == 4'h0 || addr_drive[7:4] == 4'h1) ? 8'h00 : FLOAT;
                if (addr_drive[7:4] == 4'h5) begin
                    if (addr_drive[3:1] == 3'd2) m_page2 <= addr_drive[0];
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

    // ---- the running checks --------------------------------------------------------
    integer reads = 0, reads_bad = 0, fast_reads = 0, bus_reads = 0, ovr_cycles = 0;
    integer dummies = 0, dummies_bad = 0, pin_ram_writes = 0;
    integer fast_bus_cls = 0, bus_bus_cls = 0, u_core_ops = 0, cx_fast = 0, cx_bus = 0, cx_slot_fast = 0;
    integer merge_gaps = 0, presents = 0, last_bus_present = -1, last_was_bus = 0;
    integer check_gaps = 0, drv_cycen = 0, seq_cycen = 0, mode0_bad = 0, bus_ram_reads = 0;
    reg [7:0] pass_count = 8'd0;
    reg       failed = 1'b0;
    reg       u_bus_q = 1'b0, u_bus_q2 = 1'b0;   // this unified op came off the bus
    reg       dma_last_ok = 1'b0;

    always @(posedge clk) begin
        u_bus_q  <= op_present && !op_dummy;
        u_bus_q2 <= u_bus_q;
    end

    // Bus ops: at the data phase, against the machine ($C0xx) or the reference.
    always @(posedge clk) if (u_commit) begin
        if (u_ovr) ovr_cycles = ovr_cycles + 1;
        if (u_ovr && u_addr == 16'h210F) dma_last_ok = 1'b1;
        if (u_rw) begin
            reads = reads + 1; bus_reads = bus_reads + 1;
            // ...except the reset sequence's, which ride the bus by rule, and
            // mode 0's, where everything does.
            if ((cl_cls == 2'd1 || cl_cls == 2'd2) && !u_ovr && !u_seq.reset_seq && mode != 2'd0)
                bus_ram_reads = bus_ram_reads + 1;
            if (cl_cls == 2'd0 && u_addr[15:8] == 8'hC0) begin
                if (cpu_din !== mach_byte && !u_ovr) begin
                    reads_bad = reads_bad + 1;
                    if (reads_bad <= 5) $display("    bus read $%04X: core got %02x, the machine said %02x", u_addr, cpu_din, mach_byte);
                end
            end else if (!u_ovr && cpu_din !== exp_read(u_addr)) begin
                reads_bad = reads_bad + 1;
                if (reads_bad <= 5) $display("    bus read $%04X: core got %02x, the reference says %02x (machine %02x, cls %0d)",
                                             u_addr, cpu_din, exp_read(u_addr), mach_byte, cl_cls);
            end
            if (u_addr[15:12] == 4'hC && u_addr[11:8] != 4'd0 && !u_ovr) cx_bus = cx_bus + 1;
        end
    end
    // Fast ops: on the clock the core takes the byte, against the reference.
    always @(posedge clk) if (fev_valid) begin
        if (fev_rw) begin
            reads = reads + 1; fast_reads = fast_reads + 1;
            if (fev_data !== exp_read(fev_addr)) begin
                reads_bad = reads_bad + 1;
                if (reads_bad <= 5) $display("    fast read $%04X: core got %02x, the reference says %02x", fev_addr, fev_data, exp_read(fev_addr));
            end
            if (fev_addr[15:12] == 4'hC) begin
                cx_fast = cx_fast + 1;
                // A slot's page, or $C800+ without the internal ROM: never fast.
                if (!fev_addr[11] && !(m_intcx || (fev_addr[11:8] == 4'd3 && !m_slotc3))) cx_slot_fast = cx_slot_fast + 1;
                if ( fev_addr[11] && !(m_intcx || m_intc8)) cx_slot_fast = cx_slot_fast + 1;
            end
        end
    end
    // The stream's bookkeeping: passes, the failure flag, classes, merging.
    always @(posedge clk) begin
        if (u_present && !u_rw) begin
            if (u_addr == 16'h0300) begin
                pass_count = u_wdata;
                $display("    pass %0d at %0t (%0d reads: %0d fast, %0d bus)", u_wdata, $time, reads, fast_reads, bus_reads);
            end
            if (u_addr == 16'h03FF && u_wdata == 8'hFF) failed = 1'b1;
        end
        if (u_present && !u_ovr) begin
            u_core_ops = u_core_ops + 1;
            if (u_bus_q) begin
                if (check_gaps && last_was_bus && presents - last_bus_present != 1) merge_gaps = merge_gaps + 1;
                last_bus_present = presents; last_was_bus = 1;
            end else last_was_bus = 0;
        end
        if (op_present) begin
            presents = presents + 1;
            if (op_dummy) dummies = dummies + 1;
        end
        if (cl_valid && cl_cls == 2'd0 && !u_ovr) begin
            if (u_bus_q2) bus_bus_cls = bus_bus_cls + 1; else fast_bus_cls = fast_bus_cls + 1;
        end
        if (since_fall == BUS_AT && driving) begin
            if (op_dummy && !(addr_drive == 16'h0000 && rw_drive)) dummies_bad = dummies_bad + 1;
            if (!rw_drive && data_oe && addr_drive[15:12] != 4'hC && !op_ovr) pin_ram_writes = pin_ram_writes + 1;
        end
        if (drv_cyc_done) drv_cycen = drv_cycen + 1;
        if (cpu_cyc_en)   seq_cycen = seq_cycen + 1;
        // (The driver's parked state before its first present reads as a
        // dummy; that is the takeover, not mode 0.)
        if (mode == 2'd0 && presents > 1 && (op_dummy || fev_valid || (cpu_cyc_en != drv_cyc_done))) mode0_bad = mode0_bad + 1;
    end

    always @(posedge clk) if (now % 2_000_000 == 1_999_999)
        $display("    ...%0d clocks, %0d reads (%0d fast), fast_ops %0d bus_ops %0d cycles %0d, state %0d",
                 now + 1, reads, fast_reads, fast_ops, bus_ops, cycles, seq_state);

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
        end
    endtask

    task wait_passes(input integer n, input string what);
        integer c;
        begin
            c = 0;
            while (pass_count < n && !failed && c < 8_000_000) begin @(posedge clk); c = c + 1; end
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

    // A DMA of the disk's shape: n override writes to $2100+, each presented
    // exactly once - stepped, as hd_card steps, on the driver saying it took it.
    task dma(input integer n);
        integer idx;
        begin
            idx = 0;
            @(negedge clk);
            tb_ovr_en <= 1'b1; tb_ovr_rw <= 1'b0; tb_ovr_addr <= 16'h2100; tb_ovr_wdata <= 8'h80;
            while (idx < n) begin
                @(posedge clk);
                if (op_present && op_ovr && op_addr == tb_ovr_addr && !op_rw) begin
                    idx = idx + 1;
                    @(negedge clk);
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
            @(posedge clk);
            while (!(op_present && op_ovr && op_addr == 16'h03FE)) @(posedge clk);
            @(negedge clk); tb_ovr_en <= 1'b0;
        end
    endtask

    task check_image(input string what);
        integer a, b, bad;
        begin
            bad = 0;
            for (a = 0; a < 16'hC000; a = a + 1) begin
                if (smem[a] !== ref_main[a]) bad = bad + 1;
                for (b = 0; b < NRW; b = b + 1)
                    if (smem[(b + 1) * 65536 + a] !== ref_aux[b * 65536 + a]) bad = bad + 1;
            end
            for (a = 0; a < 16384; a = a + 1) begin
                if (smem[17'h0C000 + a] !== ref_lc[a]) bad = bad + 1;
                for (b = 0; b < NRW; b = b + 1)
                    if (smem[(b + 1) * 65536 + 16'hC000 + a] !== ref_lcaux[b * 16384 + a]) bad = bad + 1;
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
            got = real'(fast_ops + bus_ops) / real'(cycles);
            if (cycles == 0) fail($sformatf("%0s: no bus cycles counted", what));
            else if (got < want * 0.95 || got > want * 1.05)
                fail($sformatf("%0s: %0d ops over %0d cycles = %.2f per cycle, wanted %.2f", what, fast_ops + bus_ops, cycles, got, want));
            else ok($sformatf("%0s: %.2f ops per bus cycle (wanted %.2f; %0d fast, %0d bus over %0d cycles)",
                              what, got, want, fast_ops, bus_ops, cycles));
        end
    endtask

    task common_checks(input string what);
        begin
            if (reads_bad != 0) fail($sformatf("%0s: %0d reads disagreed with the reference", what, reads_bad));
            else ok($sformatf("%0s: %0d reads (%0d fast), every one the reference's byte", what, reads, fast_reads));
            if (dummies_bad != 0) fail($sformatf("%0s: %0d dummy cycles were not the parked $0000 read", what, dummies_bad));
            if (fast_bus_cls != 0) fail($sformatf("%0s: %0d BUS-class ops were served fast", what, fast_bus_cls));
            if (late_fills != 0 || fifo_drops != 0) fail($sformatf("%0s: late fills %0d, drops %0d", what, late_fills, fifo_drops));
            if (mismatches != 0) fail($sformatf("%0s: the monitor counted %0d mismatches (last %08x)", what, mismatches, last_mismatch));
            if (u_core_ops != fast_ops + bus_ops + ovr_cycles - ovr_cycles) ;  // counted below
            reads_bad = 0;
        end
    endtask

    // ---- the run -------------------------------------------------------------------------
    reg [7:0] prog [0:4095];
    integer a, c, n0, n1, r0, resets, gaps0, fast0;
    initial begin
        $readmemh(PROG, prog);
        for (a = 0; a < 65536; a = a + 1) begin main_ram[a] = 8'h00; phys_aux[a] = 8'h00; ref_main[a] = 8'h00; end
        for (a = 0; a < NRW * 65536; a = a + 1) ref_aux[a] = 8'h00;
        for (a = 0; a < 16384; a = a + 1) begin lc_main[a] = 8'h00; phys_lcaux[a] = 8'h00; ref_lc[a] = 8'h00; end
        for (a = 0; a < NRW * 16384; a = a + 1) ref_lcaux[a] = 8'h00;
        for (a = 0; a < IMG; a = a + 1) smem[a] = 8'h00;
        for (a = 0; a < 12288; a = a + 1) rom_img[a] = $urandom;
        for (a = 0; a < 4096; a = a + 1) rom_img[12288 + a] = prog[a];
        for (a = 0; a < 256; a = a + 1) hd_rom[a] = $urandom;
        rom_img[16'h1000] = 8'hC7;
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
        if (fast_ops == 0 || dummies == 0) fail("mode 1: no fast ops or no dummies");
        else ok($sformatf("mode 1: %0d fast ops, %0d bus ops, %0d bus cycles, %0d dummies", fast_ops, bus_ops, cycles, dummies));
        check_ratio(real'(fast_ops + bus_ops) / real'(cycles), "mode 1 measured");
        if (fast_ops + bus_ops < 3 * cycles) fail("mode 1: less than 3x");
        else ok($sformatf("mode 1: %.1fx", real'(fast_ops + bus_ops) / real'(cycles)));
        if (phys_diff(1) != 0) fail("mode 1: the machine's memory differs from the reference - a write missed the bus");
        else ok("mode 1: every write reached the machine; its memory equals the reference");
        if (merge_gaps != 0) fail($sformatf("mode 1: %0d consecutive bus ops did not ride consecutive cycles", merge_gaps));
        else ok("mode 1: consecutive bus ops rode consecutive cycles");
        if (cx_fast == 0) fail("mode 1: no internal-ROM read of $C100-$CFFF was served fast");
        else ok($sformatf("mode 1: %0d internal-ROM reads of $C100-$CFFF served from the card, every one the model's byte", cx_fast));
        if (cx_slot_fast != 0) fail($sformatf("mode 1: %0d slot reads were served fast", cx_slot_fast));
        else ok("mode 1: every slot read - the slot-5 ROM, the empty slots - rode the bus");
        check_image("mode 1: the image equals the reference");

        // ---- 3. mode 2: reads and writes on the card ------------------------------------
        clear_counters(); pin_ram_writes = 0; dummies = 0; cx_fast = 0;
        n0 = pass_count; check_gaps = 1; merge_gaps = 0;
        @(negedge clk); mode <= 2'd2;
        wait_passes(n0 + 3, "mode 2, unlimited");
        repeat (3 * CYCLE) @(negedge clk);
        check_gaps = 0;
        common_checks("mode 2");
        if (pin_ram_writes != 0) fail($sformatf("mode 2: %0d RAM writes reached the pins", pin_ram_writes));
        else ok("mode 2: no RAM write reached the pins");
        if (fast_ops + bus_ops < 6 * cycles) fail($sformatf("mode 2: only %.1fx", real'(fast_ops + bus_ops) / real'(cycles)));
        else ok($sformatf("mode 2: %.1fx (%0d fast, %0d bus over %0d cycles)", real'(fast_ops + bus_ops) / real'(cycles), fast_ops, bus_ops, cycles));
        if (merge_gaps != 0) fail($sformatf("mode 2: %0d consecutive bus ops did not ride consecutive cycles", merge_gaps));
        else ok("mode 2: consecutive bus ops rode consecutive cycles");
        if (phys_diff(0) == 0) fail("mode 2: the machine's memory still equals the reference - writes went out");
        else ok("mode 2: the machine's memory is stale, as it must be");
        check_image("mode 2: the image equals the reference");

        // ---- 4. the governor ------------------------------------------------------------
        clear_counters();
        @(negedge clk); target <= 16'h0400;     // 4.0
        n0 = pass_count;
        wait_passes(n0 + 3, "mode 2 at 4.0");
        check_ratio(4.0, "governor at 4.0");
        clear_counters();
        @(negedge clk); target <= 16'h0100;     // 1.0
        n0 = pass_count;
        wait_passes(n0 + 2, "mode 2 at 1.0");
        check_ratio(1.0, "governor at 1.0");
        @(negedge clk); target <= 16'd0;
        common_checks("the governor");

        // ---- 5. a DMA, in mode 2 ---------------------------------------------------------
        ovr_cycles = 0; dma_last_ok = 1'b0;
        dma(16);
        repeat (4 * CYCLE) @(negedge clk);
        if (ovr_cycles != 16) fail($sformatf("%0d override cycles, expected 16", ovr_cycles));
        else if (smem[17'h2100] !== 8'h80 || smem[17'h210F] !== 8'h8F || main_ram[16'h2100] !== 8'h80 || ref_main[16'h210F] !== 8'h8F)
            fail("the DMA's writes did not reach the image, the machine and the reference alike");
        else if (!dma_last_ok) fail("the DMA's last byte did not commit under its own address");
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
        fast0 = fast_ops;
        repeat (3 * CYCLE) @(negedge clk);
        if (fast_ops != fast0) fail("the core moved while held");
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
        @(posedge clk);
        while (!(op_present && op_ovr && op_addr == 16'hC007)) @(posedge clk);
        @(negedge clk); tb_ovr_en <= 1'b0;
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

        // ---- 8. an invalidate under the running program ------------------------------------------
        // Landed on a fast op in flight, so the cache decides it without a
        // byte and the sequencer has to decide it again; the 512 clocks after
        // are a wait, not a trip to the bus (in mode 2 the bus's RAM is stale).
        r0 = retries; n1 = bus_ram_reads; c = 0;
        while (retries == r0 && c < 8) begin
            @(posedge clk);
            while (!(u_seq.st == u_seq.S_FAST && u_seq.fast_rw && !decided)) @(posedge clk);
            @(negedge clk); inval <= 1'b1; @(negedge clk); inval <= 1'b0;
            repeat (600) @(negedge clk);
            c = c + 1;
        end
        n0 = pass_count;
        wait_passes(n0 + 2, "through an invalidate");
        if (bus_ram_reads != n1) fail($sformatf("%0d RAM reads went to the stale bus through the invalidate", bus_ram_reads - n1));
        else ok("through the invalidate no RAM read went to the bus: the core waited");
        if (retries == r0) fail("no fast op was retried through the invalidate");
        else ok($sformatf("%0d fast ops the cache declined were decided again, and read right", retries - r0));
        if (reads_bad != 0) fail($sformatf("through the invalidate: %0d reads disagreed", reads_bad)); reads_bad = 0;

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
        if (reads_bad != 0) fail($sformatf("the end: %0d reads disagreed with the reference", reads_bad));
        else ok($sformatf("the end: %0d reads (%0d fast), every one the reference's byte", reads, fast_reads));
        if (dummies_bad != 0 || fast_bus_cls != 0 || late_fills != 0 || fifo_drops != 0)
            fail("the end: a bad dummy, a fast BUS-class op, a late fill or a drop");
        if (u_core_ops != fast_ops + bus_ops + seq_cycen - seq_cycen) ;  // informational

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

endmodule
