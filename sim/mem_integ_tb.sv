`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mem_integ_tb - the whole memory path under the real core: the driver, the
// reader on the pins, the MMU shadow, the ROM, the cache, the DDR3 client and
// the arbiter, against a model of a 128K IIe with a language card - ONE
// auxiliary bank on the pins, as the real machine has - plus a reference
// RamWorks of four banks kept from the presented ops, which is what the card's
// image must equal.
//
// The core runs sim/mem_integ.s - RAM, the stack, every language-card state,
// RAMRD/RAMWRT/ALTZP/80STORE with PAGE2 and HIRES, and once the card serves,
// the RamWorks bank register and the banks behind it, which only the card
// has: a read of a bank the machine lacks must be the reference's byte, and
// a write to one must NOT reach the machine's auxiliary bank (the driver
// sends it out as a read - apple_bus_write.sv) - first with every serve bit
// clear (the image only tracks), then with all three set under the running
// program, the changeover the registers promise is safe.  The machine model
// answers every read on the pins as a IIe would, and that byte is the truth:
// at every read's commit the byte the core consumed must equal it, whether
// it came from the bus or from the card.  The program's own verdict - a pass
// counter, a failure flag - is the second opinion.
//
// A DMA of the hard disk's shape is injected through the override path, so
// the image is seen to follow writes the core never made.  At the end the
// image in the DDR3 stub is compared byte for byte with the machine's memory.
//////////////////////////////////////////////////////////////////////////////////
module mem_integ_tb #(parameter UCODE = "cpu65c02_ucode.hex",
                      parameter PROG = "mem_integ.hex");

    localparam integer T_PRESENT = 2, T_EMIT = 2, T_DIN = 44, T_CYCEN = 45;
    localparam integer PHI0_LOW = 49, PHI0_HIGH = 49, CYCLE = PHI0_LOW + PHI0_HIGH;
    localparam integer BUS_AT = 70;
    localparam integer PASSES_OFF = 2, PASSES_ON = 3;

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

    // ---- the reader, the core, the driver -------------------------------------------
    reg  res_n = 1'b1;
    wire cpu_rst = rst || !res_n;
    reg  master_active = 1'b1;
    reg  [7:0]  data_pin = 8'h00;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, driving, drv_sync;
    wire [7:0]  data_drive;
    wire        phi0_sync, res_sync;
    wire [7:0]  data_sync;
    wire        sub_en;
    wire [7:0]  sub_data;

    apple_bus_read u_read (
        .clk (clk), .rst (rst), .enable (1'b1),
        .apple_data_pin (data_pin), .apple_addr_pin (addr_drive), .apple_rw_pin (rw_drive),
        .apple_phi0_pin (phi0), .apple_m2sel_pin (1'b0), .apple_m2b0_pin (1'b0),
        .apple_inh_pin (1'b1), .apple_res_pin (res_n), .apple_irq_pin (1'b1),
        .apple_rdy_pin (1'b1), .apple_dma_pin (!dma_assert),
        .ev_data (), .ev_valid (), .data_tick (),
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
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .i_din (cpu_din), .d_din (cpu_din),
        .irq_n (1'b1), .nmi_n (1'b1), .sync (cpu_sync), .halted ()
    );

    wire [15:0] op_addr, nxt_addr;
    wire        op_rw, op_present, op_commit, op_ovr, op_divert, q_divert;
    wire [7:0]  op_wdata;
    reg  [2:0]  serve = 3'b000;
    reg         ovr_en = 1'b0, ovr_rw = 1'b1;
    reg  [15:0] ovr_addr = 16'd0;
    reg  [7:0]  ovr_wdata = 8'd0;

    apple_bus_write #(.T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT), .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)) u_write (
        .clk (clk), .rst (rst), .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active),
        // Without the sequencer: the bus owns every cycle, the core is always on offer.
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync),
        .drv_sync (drv_sync), .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (1'b0), .slot_rd_data (8'h00),
        .din_sub_en (sub_en), .din_sub_data (sub_data),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw), .ovr_wdata (ovr_wdata),
        .op_ovr (op_ovr),
        .nxt_addr (nxt_addr), .divert (serve[0] && q_divert), .op_divert (op_divert),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the memory path --------------------------------------------------------------
    wire        cl_valid, cl_rw, cl_wr_image, cl_aux;
    wire [1:0]  cl_cls;
    wire [7:0]  cl_bank;
    wire [15:0] cl_off, pf_off;
    wire [11:0] sw_state;
    wire [7:0]  rw_bank;
    wire [7:0]  rom_byte;
    wire        rom_loaded, invalidating, image_ready, refresh_ok, rot_ok, mem_idle;
    wire [31:0] hits, misses, served, mismatches, last_mismatch, diverted;
    wire [7:0]  late_fills, fifo_drops;
    reg         msg_valid = 1'b0, pay_valid = 1'b0;
    reg  [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    reg  [31:0] pay_data = 32'd0;
    wire        pq_busy, pq_valid, pq_we, pq_ready, pr_valid;
    wire [19:0] pq_line;
    wire [127:0] pq_wdata, pr_data;

    apple_mmu u_mmu (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .rom_ok (rom_loaded), .intc8rom (), .q_rw (1'b1), .q_cls (),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .pf_off (pf_off),
        .sw_state (sw_state), .rw_bank (rw_bank),
        .q_addr (nxt_addr), .q_divert (q_divert),
        .p_addr (16'd0), .p_cls (), .p_aux (), .p_off (), .map_changed ()
    );
    apple_rom u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .rd_en (op_present), .rd_addr (op_addr[13:0]), .rd_data (rom_byte),
        .r2_en (1'b0), .r2_addr (12'd0), .r2_data (), .r2_busy (), .rom_loaded (rom_loaded)
    );
    page_cache u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .pf_off (pf_off),
        .op_addr (op_addr), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit), .op_divert (op_divert), .data_sync (data_sync),
        .rom_byte (rom_byte), .rom_loaded (rom_loaded),
        .sub_en (sub_en), .sub_data (sub_data),
        .fb_addr (16'd0), .fb_byte (),
        .il_req (1'b0), .il_aux (1'b0), .il_bank (8'd0), .il_line (12'd0),
        .il_ack (), .il_ok (), .il_row (),
        .serve (serve[0]), .inval (1'b0), .cnt_clr (1'b0), .image_ready (image_ready),
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
    page_client u_client (
        .clk (clk), .rst (rst), .calib_complete (1'b1),
        .master_active (master_active), .op_present (op_present),
        .accel (1'b0),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .req (c_req[1]), .gnt (c_gnt[1]), .cyc (c_cyc[1]), .stb (c_stb[1]),
        .we (c_we[1]), .addr (c_addr[47:24]), .data (c_data[255:128]), .sel (c_sel[31:16]),
        .stall (c_stall[1]), .ack (c_ack[1]), .rdata (c_rdata),
        .refresh_ok (refresh_ok), .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

    // ---- the DDR3 stub: the aux region, in order, twelve clocks late ----------------
    // RamWorks banks 0-3, and nothing else: main memory lives in the card's
    // block RAM and the DDR3 never sees it (docs/PAGE_CACHE.md).
    localparam integer NRW = 4;                 // RamWorks banks the run uses
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

    // ---- the machine: a 128K IIe with a language card, on the pins -------------------
    // main_ram / phys_aux / lc_main / phys_lcaux are what the real machine
    // holds, written from the pins: ONE auxiliary bank, no bank register.
    // aux_ram / lc_aux are the REFERENCE RamWorks - what the card's image must
    // hold - written from the presented op at its data phase, bank by bank,
    // which is how a diverted write (a read on the pins) still reaches them.
    // The bank register m_bank is the reference's; the pins carry the $C073
    // write that sets it, since $Cxxx is never diverted.
    reg [7:0] main_ram  [0:65535];
    reg [7:0] phys_aux  [0:65535];
    reg [7:0] aux_ram   [0:NRW*65536-1];    // reference: RamWorks bank b at b*65536
    reg [7:0] lc_main   [0:16383];   // bank 1 D000 at 0, bank 2 D000 at 4096, E000-FFFF at 8192
    reg [7:0] phys_lcaux [0:16383];
    reg [7:0] lc_aux    [0:NRW*16384-1];    // reference, per RamWorks bank
    reg [7:0] rom_img   [0:16383];   // $C000-$FFFF
    reg m_store80, m_ramrd, m_ramwrt, m_altzp, m_page2, m_hires;
    reg m_bank2, m_lcrd, m_wren, m_pre;
    reg [7:0] m_bank;                // the reference RamWorks's bank register

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
            m_bank = 0;              // by decision: the card's and the host's rule too
        end
    endtask
    // The bank a RamWorks access reaches, as an index into aux_ram / lc_aux.
    function automatic integer m_auxidx(input [15:0] a);
        m_auxidx = m_bank * 65536 + a;
    endfunction
    function automatic integer m_lcauxidx(input [15:0] a);
        m_lcauxidx = m_bank * 16384 + m_lcidx(a);
    endfunction

    // The byte the machine returned for the op in flight: the truth.
    reg [7:0] mach_byte = 8'h00;
    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        if (rw_drive) begin
            if (addr_drive[15:8] == 8'hC0) begin
                data_pin <= 8'hA5;
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
                data_pin <= 8'hA5;
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
                        3'd4: m_altzp   <= addr_drive[0];
                        default: ;
                    endcase
                end
                if (addr_drive[7:4] == 4'h5) begin
                    if (addr_drive[3:1] == 3'd2) m_page2 <= addr_drive[0];
                    if (addr_drive[3:1] == 3'd3) m_hires <= addr_drive[0];
                end
                // $C071/$C073: the RamWorks bank register; a bank the card
                // does not have leaves it alone.
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
                // nothing there
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

    // The reference RamWorks, from the op the card presented - diverted or
    // not - at its data phase, with the switches as the pins set them.
    always @(posedge clk) if (op_commit && !op_rw && op_addr[15:12] != 4'hC) begin
        if (op_addr >= 16'hD000) begin
            if (m_wren && m_altzp) lc_aux[m_lcauxidx(op_addr)] <= op_wdata;
        end else if (m_aux(op_addr, 1'b0)) begin
            aux_ram[m_auxidx(op_addr)] <= op_wdata;
        end
    end
    // The byte the reference holds at a banked-aux offset the machine does
    // not have: what a served read there must return.  cl_off carries the LC
    // fold, so the $C000 hole IS the lc_aux index.
    function automatic [7:0] ref_byte(input [7:0] bank, input [15:0] off);
        if (off < 16'hC000) ref_byte = aux_ram[bank * 65536 + off];
        else                ref_byte = lc_aux[bank * 16384 + (off - 16'hC000)];
    endfunction

    // ---- the running checks --------------------------------------------------------
    integer reads = 0, reads_bad = 0, ovr_cycles = 0, served_reads = 0;
    integer banked_reads = 0, banked_writes = 0, pin_writes_banked = 0;
    reg [7:0] pass_count = 8'd0;
    reg       failed = 1'b0;
    always @(posedge clk) if (op_commit) begin
        if (op_ovr) ovr_cycles = ovr_cycles + 1;
        if (op_rw) begin
            reads = reads + 1;
            if (sub_en) served_reads = served_reads + 1;
            if (cl_aux && cl_bank != 8'd0 && (cl_cls == 2'd1 || cl_cls == 2'd2)) begin
                // RAM or LC in a bank the machine does not have: the
                // reference is the truth.  (cl_aux/cl_bank stand for a BUS
                // or ROM op too, whose byte comes from elsewhere.)
                banked_reads = banked_reads + 1;
                if (cpu_din !== ref_byte(cl_bank, cl_off)) begin
                    reads_bad = reads_bad + 1;
                    if (reads_bad <= 5)
                        $display("    read $%04X (bank %0d off %04x): core got %02x, the reference says %02x (sub_en %0d)",
                                 op_addr, cl_bank, cl_off, cpu_din, ref_byte(cl_bank, cl_off), sub_en);
                end
            end else if (cpu_din !== mach_byte) begin
                reads_bad = reads_bad + 1;
                if (reads_bad <= 5)
                    $display("    read $%04X: core got %02x, the machine said %02x (sub_en %0d, switches %03x)",
                             op_addr, cpu_din, mach_byte, sub_en, sw_state);
            end
        end else begin
            if (cl_aux && cl_bank != 8'd0 && (cl_cls == 2'd1 || cl_cls == 2'd2)) begin
                banked_writes = banked_writes + 1;
                if (!op_divert) pin_writes_banked = pin_writes_banked + 1;
            end
            if (op_addr == 16'h0300) begin
                pass_count = op_wdata;
                $display("    pass %0d at %0t (%0d reads so far)", op_wdata, $time, reads);
            end
            if (op_addr == 16'h03FF && op_wdata == 8'hFF) failed = 1'b1;
        end
    end

    // A heartbeat, so a stalled run is distinguishable from a slow one.
    always @(posedge clk) if (now % 1_000_000 == 999_999)
        $display("    ...%0d clocks, %0d reads, image_ready %0d, hits %0d misses %0d served %0d",
                 now + 1, reads, image_ready, hits, misses, served);

    // ---- the ROM's load -----------------------------------------------------------
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
            while (pass_count < n && !failed && c < 6_000_000) begin @(posedge clk); c = c + 1; end
            if (failed) fail($sformatf("%0s: the program raised its failure flag at pass %0d", what, pass_count));
            else if (pass_count < n) fail($sformatf("%0s: only %0d passes before the timeout", what, pass_count));
            else ok($sformatf("%0s: %0d passes of the program", what, n));
        end
    endtask

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
            bad = 0;
            for (a = 0; a < 16'hC000; a = a + 1) begin
                if (card_main(16'(a)) !== main_ram[a]) bad = bad + 1;
                for (b = 0; b < NRW; b = b + 1)
                    if (card_aux(8'(b), 16'(a)) !== aux_ram[b * 65536 + a]) bad = bad + 1;
            end
            // The LC fold: bank 1 of $D000 in the $C000 hole, the rest in place.
            for (a = 0; a < 16384; a = a + 1) begin
                if (card_main(16'hC000 + 16'(a)) !== lc_main[a]) bad = bad + 1;
                for (b = 0; b < NRW; b = b + 1)
                    if (card_aux(8'(b), 16'hC000 + 16'(a)) !== lc_aux[b * 16384 + a]) bad = bad + 1;
            end
            if (bad != 0) fail($sformatf("%0s: %0d image bytes differ from the reference", what, bad));
            else ok(what);
        end
    endtask

    // The machine's own auxiliary bank holds bank 0's writes and nobody
    // else's: the diverted writes never reached the pins.
    task check_phys(input string what);
        integer a, bad;
        begin
            bad = 0;
            for (a = 0; a < 16'hC000; a = a + 1) if (phys_aux[a] !== aux_ram[a]) bad = bad + 1;
            for (a = 0; a < 16384; a = a + 1) if (phys_lcaux[a] !== lc_aux[a]) bad = bad + 1;
            if (bad != 0) fail($sformatf("%0s: %0d bytes of the machine's auxiliary memory differ from bank 0", what, bad));
            else ok(what);
        end
    endtask

    // ---- the run -------------------------------------------------------------------------
    reg [7:0] prog [0:4095];
    integer a, c, served0, reads0, bad0, dma_idx;
    initial begin
        $readmemh(PROG, prog);
        for (a = 0; a < 65536; a = a + 1) begin main_ram[a] = 8'h00; phys_aux[a] = 8'h00; end
        for (a = 0; a < NRW * 65536; a = a + 1) aux_ram[a] = 8'h00;
        for (a = 0; a < 16384; a = a + 1) begin lc_main[a] = 8'h00; phys_lcaux[a] = 8'h00; end
        for (a = 0; a < NRW * 16384; a = a + 1) lc_aux[a] = 8'h00;
        for (a = 0; a < IMG; a = a + 1) smem[a] = 8'h00;
        for (a = 0; a < 4096; a = a + 1) begin
            u_cache.u_main.mem[a] = 128'd0;        // the banks power up known,
            u_cache.u_aux.mem[a]  = 128'd0;        // as the references do
        end
        for (a = 0; a < 12288; a = a + 1) rom_img[a] = $urandom;
        for (a = 0; a < 4096; a = a + 1) rom_img[12288 + a] = prog[a];
        rom_img[16'h1000] = 8'hC7;                 // what the program expects at ROM $D000
        m_reset();

        repeat (5) @(negedge clk);
        rst <= 1'b0;
        @(negedge clk);
        if (!image_ready) fail("no image_ready with the DDR3 calibrated");
        for (c = 0; c < 32; c = c + 1) send_chunk(c);
        if (!rom_loaded) fail("the ROM did not load");

        // The machine comes out of reset; the core with it.
        res_n <= 1'b0;
        repeat (5 * CYCLE) @(negedge clk);
        m_reset();
        res_n <= 1'b1;

        // ---- 1. tracking only -------------------------------------------------------
        wait_passes(PASSES_OFF, "serve off");
        if (served_reads != 0) fail("a byte was served with every serve bit clear");
        else ok("nothing served while the serve bits are clear");
        if (reads_bad != 0) fail($sformatf("%0d reads disagreed with the machine", reads_bad));
        else ok($sformatf("%0d reads, every one the machine's byte", reads));
        repeat (4 * CYCLE) @(negedge clk);
        check_image("the image tracked every write the program made");

        // ---- 2. the DMA, of the disk's shape: 16 writes the core never made --------
        // One override per bus cycle, changed at the falling edge so each is
        // presented exactly once - the disk does the same.
        dma_idx = 0;
        while (dma_idx <= 16) begin
            @(negedge clk);
            if (since_fall == 0) begin
                if (dma_idx < 16) begin
                    ovr_en <= 1'b1; ovr_rw <= 1'b0;
                    ovr_addr <= 16'h2100 + dma_idx; ovr_wdata <= 8'h80 + dma_idx;
                end else ovr_en <= 1'b0;
                dma_idx = dma_idx + 1;
            end
        end
        repeat (4 * CYCLE) @(negedge clk);
        if (ovr_cycles != 16) fail($sformatf("%0d override cycles, expected 16", ovr_cycles));
        else if (card_main(16'h2100) !== 8'h80 || card_main(16'h210F) !== 8'h8F || main_ram[16'h2100] !== 8'h80)
            fail("the DMA's writes did not reach the image and the machine alike");
        else ok("a DMA through the override path lands in the image as it does in the machine");

        // ---- 3. every serve bit set, under the running program ------------------------
        // Serving first, then the flag that lets the program use the RamWorks:
        // the machine has none, and only the card's image can answer for it.
        served0 = served_reads; reads0 = reads; bad0 = reads_bad;
        serve <= 3'b111;
        dma_idx = 0;
        while (dma_idx <= 1) begin
            @(negedge clk);
            if (since_fall == 0) begin
                if (dma_idx == 0) begin
                    ovr_en <= 1'b1; ovr_rw <= 1'b0; ovr_addr <= 16'h03FE; ovr_wdata <= 8'h01;
                end else ovr_en <= 1'b0;
                dma_idx = dma_idx + 1;
            end
        end
        wait_passes(PASSES_OFF + PASSES_ON, "serve on");
        if (banked_reads == 0 || banked_writes == 0)
            fail("the program never touched a RamWorks bank while serving");
        else if (pin_writes_banked != 0)
            fail($sformatf("%0d writes to a bank the machine lacks went out on the pins as writes", pin_writes_banked));
        else if (diverted != banked_writes)
            fail($sformatf("diverted counts %0d, the testbench saw %0d banked writes", diverted, banked_writes));
        else ok($sformatf("%0d reads of RamWorks banks answered from the image; every one of %0d banked writes went out as a read, and was counted",
                          banked_reads, banked_writes));
        if (reads_bad != bad0) fail($sformatf("%0d reads disagreed with the machine while serving", reads_bad - bad0));
        else ok($sformatf("%0d reads while serving, every one the machine's byte", reads - reads0));
        if (served_reads - served0 < (reads - reads0) / 2)
            fail($sformatf("only %0d of %0d reads were served", served_reads - served0, reads - reads0));
        else ok($sformatf("%0d of %0d reads were answered by the card", served_reads - served0, reads - reads0));
        if (mismatches != 0) fail($sformatf("the monitor counted %0d mismatches (last %08x)", mismatches, last_mismatch));
        else ok("the monitor saw the machine agree on every served byte");
        if (late_fills != 0 || fifo_drops != 0) fail($sformatf("late fills %0d, drops %0d", late_fills, fifo_drops));
        else ok("no fill was late and no request was dropped");
        if (hits == 0 || misses == 0) fail("no hits or no misses");
        else ok($sformatf("%0d hits, %0d misses", hits, misses));
        repeat (4 * CYCLE) @(negedge clk);
        check_image("the image still equals the reference after serving, RamWorks banks included");
        check_phys("the machine's own auxiliary bank holds only bank 0's writes");

        // ---- 4. a reset under it: the switches go back, the memory stays -----------------
        // First leave a RamWorks bank selected, through the override path as
        // the program itself never does: the reset must clear it.
        dma_idx = 0;
        while (dma_idx <= 1) begin
            @(negedge clk);
            if (since_fall == 0) begin
                if (dma_idx == 0) begin
                    ovr_en <= 1'b1; ovr_rw <= 1'b0; ovr_addr <= 16'hC073; ovr_wdata <= 8'd3;
                end else ovr_en <= 1'b0;
                dma_idx = dma_idx + 1;
            end
        end
        repeat (2 * CYCLE) @(negedge clk);
        if (rw_bank !== 8'd3 || m_bank !== 8'd3) fail($sformatf("bank register %0d (machine %0d) after a write of 3", rw_bank, m_bank));
        else ok("a write to $C073 selects RamWorks bank 3, on the card and in the machine");
        res_n <= 1'b0;
        repeat (5 * CYCLE) @(negedge clk);
        m_reset();
        if (sw_state !== 12'h500) fail($sformatf("switches after reset: %03x", sw_state));
        else ok("RES' puts the shadow's switches back to the IIe's reset state");
        if (rw_bank !== 8'd0) fail($sformatf("bank register %0d after RES'", rw_bank));
        else ok("...and the RamWorks bank register to 0, by decision");
        res_n <= 1'b1;
        pass_count = 0;
        wait_passes(2, "after a reset, still serving");
        check_image("and the image survived the reset, like RAM");
        check_phys("and the machine's auxiliary bank is still bank 0's alone");

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
