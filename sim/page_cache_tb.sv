`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// page_cache_tb - the two banks, their page engine, the DDR3 client and the
// ROM, against a Wishbone memory that behaves like the DDR3 does: acks in
// order, ten-odd clocks late, stalling now and then, pausing for a refresh's
// worth, and a streaming client sharing the port through wb_arb's rotation.
//
// Ops arrive the way apple_mmu delivers them, one per 98-clock bus cycle.  A
// reference model keeps main memory, a shadow of the aux bank's block RAM,
// the per-page tags, and the DDR3's aux region, so every served byte, every
// eviction's flush and every fill is predicted before the DUT answers.  The
// checks the old mem_cache_tb could not make are the point here:
//
//   - main memory and unbanked aux NEVER touch the DDR3: the stub counts
//     zero reads and zero writes under pure 128K traffic;
//   - a hit's byte stands THREE clocks after op_present, not six;
//   - a RamWorks round trip - write in bank 0, switch, write, switch back -
//     returns every byte through the evict/flush/fill machinery, and the
//     stub's memory equals the model's DDR3 image afterwards;
//   - a fill that lands after the next op has been presented serves nothing
//     (the transaction still completes for the page's sake), and an aux op
//     while the engine is busy is counted and untouched - late_fills is the
//     overrun counter and reads zero in every healthy run;
//   - main is served even while the engine is busy on an aux page.
//////////////////////////////////////////////////////////////////////////////////
module page_cache_tb;
    parameter integer NOPS = 4000;

    localparam integer CYC = 98;              // clocks per bus cycle
    localparam integer T_FAST = 5;            // a hit's byte must stand by here
    localparam integer T_CHECK = 88;          // where the driver would latch din
    localparam integer T_COMMIT = 91;
    localparam [1:0] CLS_BUS = 2'd0, CLS_RAM = 2'd1, CLS_LC = 2'd2, CLS_ROM = 2'd3;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    integer errors = 0, checks = 0;
    task fail(input string why);
        begin errors = errors + 1; $display("FAIL: %0s", why); end
    endtask
    task ok(input string what);
        begin checks = checks + 1; $display("ok: %0s", what); end
    endtask

    // ---- the DUT's inputs ----------------------------------------------------
    logic        cl_valid = 1'b0;
    logic [1:0]  cl_cls = CLS_BUS;
    logic        cl_aux = 1'b0;
    logic [7:0]  cl_bank = 8'd0;
    logic [15:0] cl_off = 16'd0, pf_off = 16'd0;
    logic        cl_rw = 1'b1, cl_wr_image = 1'b0;
    logic [15:0] op_addr = 16'd0;
    logic [7:0]  op_wdata = 8'd0;
    logic        op_present = 1'b0, op_commit = 1'b0;
    logic [7:0]  data_sync = 8'd0;
    logic        serve = 1'b1;
    logic        inval = 1'b0, cnt_clr = 1'b0;
    logic        master_active = 1'b1;
    logic        calib_complete = 1'b0;

    // messages to the ROM
    logic        msg_valid = 1'b0, pay_valid = 1'b0;
    logic [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    logic [31:0] pay_data = 32'd0;

    // ---- the DUT --------------------------------------------------------------------
    wire        sub_en;
    wire [7:0]  sub_data;
    wire        invalidating;
    wire [31:0] hits, misses, served, mismatches, last_mismatch;
    wire [7:0]  late_fills, fifo_drops;
    wire        pq_busy, pq_valid, pq_we, pq_ready, pr_valid;
    wire [19:0] pq_line;
    wire [127:0] pq_wdata, pr_data;
    wire [7:0]  rom_byte;
    wire        rom_loaded;

    apple_rom u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .rd_en (op_present), .rd_addr (op_addr[13:0]), .rd_data (rom_byte),
        .rom_loaded (rom_loaded)
    );

    page_cache u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux),
        .cl_bank (cl_bank), .cl_off (cl_off), .cl_rw (cl_rw),
        .cl_wr_image (cl_wr_image), .pf_off (pf_off),
        .op_addr (op_addr), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit), .op_divert (1'b0),
        .data_sync (data_sync),
        .rom_byte (rom_byte), .rom_loaded (rom_loaded),
        .sub_en (sub_en), .sub_data (sub_data),
        .fb_addr (16'd0), .fb_byte (),
        .serve (serve), .inval (inval), .cnt_clr (cnt_clr), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (), .late_fills (late_fills),
        .fifo_drops (fifo_drops),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data)
    );

    // Two arbiter clients: 0 the streaming dummy, 1 the memory (priority).
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
    wire         refresh_ok, rot_ok, mem_idle, image_ready;

    wb_arb #(.N (2), .HAS_PRIO (1'b1)) u_arb (
        .clk (clk), .rst (rst), .rot_ok (rot_ok),
        .c_req (c_req), .c_gnt (c_gnt), .c_cyc (c_cyc), .c_stb (c_stb),
        .c_we (c_we), .c_addr (c_addr), .c_data (c_data), .c_sel (c_sel),
        .c_stall (c_stall), .c_ack (c_ack), .c_rdata (c_rdata),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we), .wb_addr (wb_addr),
        .wb_data (wb_data), .wb_sel (wb_sel), .wb_aux (wb_aux),
        .wb_stall (wb_stall), .wb_ack (wb_ack), .wb_rdata (wb_rdata),
        .wb_rdata_aux (wb_rdata_aux)
    );

    page_client u_client (
        .clk (clk), .rst (rst), .calib_complete (calib_complete),
        .master_active (master_active), .op_present (op_present),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .req (c_req[1]), .gnt (c_gnt[1]), .cyc (c_cyc[1]), .stb (c_stb[1]),
        .we (c_we[1]), .addr (c_addr[47:24]), .data (c_data[255:128]),
        .sel (c_sel[31:16]), .stall (c_stall[1]), .ack (c_ack[1]), .rdata (c_rdata),
        .refresh_ok (refresh_ok), .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

    // ---- the streaming dummy: batches of 32 writes to bank 7, whenever it may -----
    logic        d_req = 1'b0, d_stb = 1'b0;
    logic [5:0]  d_left = 6'd0;
    integer      d_issued = 0, d_acked = 0, d_batches = 0;
    integer      d_started_bad = 0;
    logic        d_on = 1'b0;
    assign c_req[0] = d_req;
    assign c_cyc[0] = d_req || (d_issued != d_acked);
    assign c_stb[0] = d_stb;
    assign c_we[0]  = 1'b1;
    assign c_addr[23:0] = {14'd0, 3'd7, 7'(d_issued)};
    assign c_data[127:0] = {4{32'hD0D0_0000 | d_issued}};
    assign c_sel[15:0] = 16'hFFFF;
    always @(posedge clk) begin
        if (rst) begin d_req <= 0; d_stb <= 0; d_left <= 0; end
        else begin
            if (!d_req && d_on) begin d_req <= 1'b1; d_left <= 6'd32; d_stb <= 1'b1; end
            else if (d_req) begin
                if (d_stb && !c_stall[0]) begin
                    d_issued <= d_issued + 1;
                    d_left <= d_left - 6'd1;
                    if (d_left == 6'd1) begin d_stb <= 1'b0; d_req <= 1'b0; d_batches <= d_batches + 1; end
                end
            end
            if (c_ack[0]) d_acked <= d_acked + 1;
        end
    end
    logic held_q = 0, rot_ok_q = 0;
    always @(posedge clk) begin
        held_q <= u_arb.held;
        rot_ok_q <= rot_ok;
        if (u_arb.held && !held_q && !rot_ok_q) d_started_bad <= d_started_bad + 1;
    end

    // ---- the Wishbone memory stub -----------------------------------------------------
    // The DDR3's aux region, banks 0-7 (512 KB).  Bank 7 of the DDR3 itself
    // (the ring's) is ignored.
    localparam integer IMG = 8 * 65536;
    logic [7:0] smem [0:IMG-1];
    integer     s_lat = 12;
    integer     s_stall_every = 0;
    integer     s_pause = 0;
    integer     s_cnt = 0;
    logic       s_stall;
    assign wb_stall = s_stall || (s_pause != 0);
    always @(posedge clk) begin
        s_cnt <= s_cnt + 1;
        s_stall <= (s_stall_every != 0) && ((s_cnt % s_stall_every) < 3);
        if (s_pause != 0) s_pause <= s_pause - 1;
    end
    localparam integer DL = 160;
    logic          dl_v [0:DL-1];
    logic [3:0]    dl_aux [0:DL-1];
    logic [127:0]  dl_d [0:DL-1];
    integer        dl_wp = 0, dl_rp = 0;
    integer        dl_time [0:DL-1];
    integer        now = 0;
    integer        s_writes = 0, s_reads = 0;
    logic          wb_ack_r = 0;
    logic [127:0]  wb_rdata_r = 0;
    logic [3:0]    wb_aux_r = 0;
    assign wb_ack = wb_ack_r;
    assign wb_rdata = wb_rdata_r;
    assign wb_rdata_aux = wb_aux_r;
    function automatic [18:0] wb_to_byte(input [23:0] a);
        wb_to_byte = {a[22:10], a[6:0]} << 4;      // line * 16, banks 0-7 only
    endfunction
    integer i;
    always @(posedge clk) begin
        now <= now + 1;
        wb_ack_r <= 1'b0;
        if (wb_cyc && wb_stb && !wb_stall) begin
            if (wb_addr[9:7] == 3'd0 && wb_addr[23] == 1'b0 && wb_addr[22:10] < 13'd256) begin
                if (wb_we) begin
                    for (i = 0; i < 16; i = i + 1)
                        if (wb_sel[i]) smem[wb_to_byte(wb_addr) + i] <= wb_data[8*i +: 8];
                    s_writes <= s_writes + 1;
                    dl_d[dl_wp % DL] <= 128'd0;
                end else begin
                    for (i = 0; i < 16; i = i + 1)
                        dl_d[dl_wp % DL][8*i +: 8] <= smem[wb_to_byte(wb_addr) + i];
                    s_reads <= s_reads + 1;
                end
            end else begin
                dl_d[dl_wp % DL] <= 128'hBAD;
            end
            dl_aux[dl_wp % DL] <= wb_aux;
            dl_time[dl_wp % DL] <= now + s_lat;
            dl_wp <= dl_wp + 1;
        end
        if (dl_rp != dl_wp && now >= dl_time[dl_rp % DL] && !wb_ack_r) begin
            wb_ack_r   <= 1'b1;
            wb_rdata_r <= dl_d[dl_rp % DL];
            wb_aux_r   <= dl_aux[dl_rp % DL];
            dl_rp      <= dl_rp + 1;
        end
    end

    // ---- the reference model -------------------------------------------------------
    logic [7:0] ref_main [0:65535];      // main memory: the main bank's truth
    logic [7:0] aux_shadow [0:65535];    // what the aux bank's block RAM holds
    logic [7:0] mach_aux [0:65535];      // the machine's one auxiliary bank
    logic [7:0] ddr [0:IMG-1];           // the DDR3 aux region as it should be
    logic [7:0] rom_img [0:16383];
    logic       m_vld [0:255];
    logic       m_dty [0:255];
    logic [7:0] m_bank [0:255];
    integer e_hits = 0, e_misses = 0, e_served = 0;

    task model_invalidate;
        integer p;
        begin
            for (p = 0; p < 256; p = p + 1) begin
                m_vld[p] = 1'b0; m_dty[p] = 1'b0;
            end
        end
    endtask

    // The aux side of an access: claims, hits, and the evict/fill on a miss.
    // Mirrors what the engine must do; the served byte afterwards is
    // aux_shadow[off].
    task model_aux(input [7:0] bank, input [15:0] off, input bit is_read,
                   input [7:0] wdata, input bit may);
        integer p, k;
        begin
            p = off[15:8];
            if (m_vld[p] && m_bank[p] == bank) begin
                if (is_read) e_hits = e_hits + 1;   // hits count reads, as mem_cache did
                if (!is_read) begin aux_shadow[off] = wdata; m_dty[p] = 1'b1; end
            end else if (!m_vld[p]) begin
                e_misses = e_misses + 1;
                m_vld[p] = 1'b1; m_bank[p] = bank; m_dty[p] = !is_read;
                if (!is_read) aux_shadow[off] = wdata;
            end else begin
                e_misses = e_misses + 1;
                if (may) begin
                    if (m_dty[p])
                        for (k = 0; k < 256; k = k + 1)
                            ddr[{m_bank[p], off[15:8], 8'(k)}] = aux_shadow[{off[15:8], 8'(k)}];
                    for (k = 0; k < 256; k = k + 1)
                        aux_shadow[{off[15:8], 8'(k)}] = ddr[{bank, off[15:8], 8'(k)}];
                    m_bank[p] = bank; m_dty[p] = !is_read;
                    if (!is_read) aux_shadow[off] = wdata;
                end
            end
        end
    endtask

    // ---- one bus cycle --------------------------------------------------------------------
    logic [7:0] bus_byte;
    task do_op(input [1:0] cls, input bit aux, input [7:0] bank, input [15:0] off,
               input bit rw, input [7:0] wdata, input bit wr_image, input bit check);
        bit exp_sub, exp_fast, blocked, may;
        logic [7:0] exp_data;
        integer t;
        begin
            @(negedge clk);
            op_present <= 1'b1; op_addr <= off; op_wdata <= wdata; pf_off <= off;
            @(negedge clk);
            op_present <= 1'b0;
            cl_valid <= 1'b1; cl_cls <= cls; cl_aux <= aux; cl_bank <= bank;
            cl_off <= off; cl_rw <= rw; cl_wr_image <= wr_image;
            may = image_ready;
            blocked = aux && (cls == CLS_RAM || cls == CLS_LC) && pq_busy;
            @(negedge clk);
            cl_valid <= 1'b0;

            // What should happen.
            exp_sub = 1'b0; exp_fast = 1'b0; exp_data = 8'hxx;
            if (blocked) begin
                // The engine owns the aux side: counted, untouched.
            end else if (rw && (cls == CLS_RAM || cls == CLS_LC)) begin
                if (aux) begin
                    model_aux(bank, off, 1'b1, 8'h00, may);
                    if (serve && (may || m_vld[off[15:8]])) begin
                        exp_sub = 1'b1; exp_data = aux_shadow[off];
                    end
                end else begin
                    e_hits = e_hits + 1;
                    if (serve) begin exp_sub = 1'b1; exp_data = ref_main[off]; exp_fast = 1'b1; end
                end
            end else if (rw && cls == CLS_ROM) begin
                if (rom_loaded && serve) begin
                    exp_sub = 1'b1; exp_data = rom_img[off[13:0]]; exp_fast = 1'b1;
                end
            end else if (!rw && wr_image) begin
                if (aux) begin
                    model_aux(bank, off, 1'b0, wdata, may);
                    if (bank == 8'd0) mach_aux[off] = wdata;   // bank 0 is on the pins
                end else begin
                    ref_main[off] = wdata;
                end
            end
            if (exp_sub) e_served = e_served + 1;

            // The machine's own RAM answers the bus; for ROM the ROM does.
            bus_byte = rw ? ((cls == CLS_ROM) ? rom_img[off[13:0]] :
                             (cls == CLS_BUS) ? 8'h5A :
                             aux ? mach_aux[off] : ref_main[off]) : wdata;

            // A hit, a claim, main, the ROM: the byte stands by T_FAST.
            for (t = 3; t < T_FAST; t = t + 1) @(negedge clk);
            if (check && exp_fast) begin
                if (sub_en !== 1'b1)
                    fail($sformatf("op cls=%0d off=%04x: no fast serve by clock %0d", cls, off, T_FAST));
                else if (sub_data !== exp_data)
                    fail($sformatf("op cls=%0d off=%04x: fast served %02x, expected %02x", cls, off, sub_data, exp_data));
            end
            for (t = T_FAST; t < T_CHECK; t = t + 1) @(negedge clk);
            if (check) begin
                if (sub_en !== exp_sub)
                    fail($sformatf("op cls=%0d aux=%0d bank=%0d off=%04x rw=%0d: sub_en %0d, expected %0d",
                                   cls, aux, bank, off, rw, sub_en, exp_sub));
                else if (exp_sub && sub_data !== exp_data)
                    fail($sformatf("op cls=%0d aux=%0d bank=%0d off=%04x: served %02x, expected %02x",
                                   cls, aux, bank, off, sub_data, exp_data));
            end
            data_sync <= bus_byte;
            for (t = T_CHECK; t < T_COMMIT; t = t + 1) @(negedge clk);
            op_commit <= 1'b1;
            @(negedge clk);
            op_commit <= 1'b0;
            for (t = T_COMMIT + 1; t < CYC; t = t + 1) @(negedge clk);
        end
    endtask

    // The stub's memory must equal the model's DDR3 region once idle.
    task check_ddr(input string what);
        integer a, bad;
        begin
            bad = 0;
            for (a = 0; a < IMG; a = a + 1) if (smem[a] !== ddr[a]) bad = bad + 1;
            if (bad != 0) fail($sformatf("%0s: %0d DDR3 bytes differ from the model", what, bad));
            else ok(what);
        end
    endtask

    // ---- the ROM load ---------------------------------------------------------------------
    task send_chunk(input integer c);
        integer k;
        begin
            @(negedge clk);
            msg_valid <= 1'b1; msg_type <= 8'h22; msg_len <= 8'd129;
            @(negedge clk);
            msg_valid <= 1'b0;
            pay_valid <= 1'b1; pay_data <= c;
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

    // ---- the run --------------------------------------------------------------------------
    localparam integer NHOT = 24;
    logic [15:0] hot [0:NHOT-1];
    integer n, r, a, c, lf0;
    logic [15:0] off;
    logic [7:0]  bank;
    logic [1:0]  cls;
    bit          rw, aux;

    initial begin
        for (a = 0; a < IMG; a = a + 1) begin smem[a] = 8'h00; ddr[a] = 8'h00; end
        for (a = 0; a < 65536; a = a + 1) begin
            ref_main[a] = 8'h00; aux_shadow[a] = 8'h00; mach_aux[a] = 8'h00;
            u_cache.u_main.mem[a[15:4]] = 128'd0;      // the banks power up known
            u_cache.u_aux.mem[a[15:4]]  = 128'd0;      // so garbage is modelled garbage
        end
        for (a = 0; a < 16384; a = a + 1) rom_img[a] = $urandom;
        for (n = 0; n < NHOT; n = n + 1) hot[n] = 16'($urandom);
        model_invalidate();

        repeat (5) @(negedge clk);
        rst <= 1'b0;
        repeat (5) @(negedge clk);

        // ---- 1. the image is ready when the DDR3 is ---------------------------
        if (image_ready) fail("image_ready before calibration");
        calib_complete <= 1'b1;
        @(negedge clk);
        if (!image_ready) fail("image_ready did not follow calib_complete");
        else if (s_writes != 0) fail("something wrote the DDR3 before any op");
        else ok("the image is ready as soon as the DDR3 is calibrated");

        // ---- 2. the ROM ------------------------------------------------------------
        do_op(CLS_ROM, 1'b0, 8'd0, 16'h3123, 1'b1, 8'h00, 1'b0, 1'b1);
        if (rom_loaded) fail("rom_loaded before any chunk");
        for (c = 0; c < 32; c = c + 1) begin
            send_chunk((c * 7) % 32);
            if (c < 31 && rom_loaded) fail("rom_loaded before every chunk");
        end
        if (!rom_loaded) fail("rom_loaded not raised after 32 chunks");
        else ok("the ROM loads from 32 chunks, in any order, and not before");
        for (n = 0; n < 40; n = n + 1) begin
            a = $urandom % 16384;
            do_op(CLS_ROM, 1'b0, 8'd0, 16'(a), 1'b1, 8'h00, 1'b0, 1'b1);
        end
        ok("ROM reads are served from the ROM's own block RAM, by the fast check");

        // ---- 3. a 128K machine never touches the DDR3 -------------------------
        for (n = 0; n < 800; n = n + 1) begin
            off = (n % 3 == 0) ? hot[$urandom % NHOT] : 16'($urandom);
            aux = ($urandom % 3 == 0);
            rw  = ($urandom % 100 < 40);
            cls = (off[15:12] >= 4'hD) ? CLS_LC : CLS_RAM;
            if (off[15:12] == 4'hC) off[15:12] = 4'h3;
            do_op(cls, aux, 8'd0, off, rw, 8'($urandom), !rw, 1'b1);
        end
        if (s_reads != 0 || s_writes != 0)
            fail($sformatf("128K traffic reached the DDR3: %0d reads, %0d writes", s_reads, s_writes));
        else ok("800 main and unbanked-aux ops, served and written, and the DDR3 never touched");
        if (late_fills != 0) fail($sformatf("%0d overruns with no engine work", late_fills));

        // ---- 4. the RamWorks round trip ---------------------------------------
        do_op(CLS_RAM, 1'b1, 8'd0, 16'h1234, 1'b0, 8'hAA, 1'b1, 1'b1);
        do_op(CLS_RAM, 1'b1, 8'd2, 16'h1234, 1'b1, 8'h00, 1'b0, 1'b1);   // evict 0, fill 2
        do_op(CLS_RAM, 1'b1, 8'd2, 16'h1234, 1'b0, 8'h55, 1'b1, 1'b1);
        do_op(CLS_RAM, 1'b1, 8'd0, 16'h1234, 1'b1, 8'h00, 1'b0, 1'b1);   // back: the AA returns
        do_op(CLS_RAM, 1'b1, 8'd2, 16'h1234, 1'b1, 8'h00, 1'b0, 1'b1);   // and the 55
        if (errors == 0) ok("a RamWorks round trip returns every byte through evict, flush and fill");
        repeat (300) @(negedge clk);
        check_ddr("the flushes left the DDR3 exactly as the model has it");

        // ---- 5. random traffic, the dummy streaming under it ----------------------
        d_on <= 1'b1;
        s_stall_every <= 37;
        for (n = 0; n < NOPS; n = n + 1) begin
            r = $urandom % 100;
            off = (r < 70) ? (hot[$urandom % NHOT] & 16'hFFF0) + 16'($urandom % 16)
                           : 16'($urandom);
            if (r < 10) cls = CLS_BUS;
            else if (r < 18) cls = CLS_ROM;
            else cls = (off[15:12] >= 4'hD) ? CLS_LC : CLS_RAM;
            if (off[15:12] == 4'hC) off[15:12] = 4'h3;
            aux  = ($urandom % 2 == 0);
            bank = 8'($urandom % 4);
            rw = (cls == CLS_BUS || cls == CLS_ROM) ? 1'b1 : ($urandom % 100 < 60);
            if (n % 500 == 250) s_pause = 23;
            if (n == NOPS / 2) serve <= 1'b0;
            if (n == NOPS / 2 + 400) serve <= 1'b1;
            do_op(cls, aux, bank, off, rw, 8'($urandom),
                  (cls == CLS_RAM || cls == CLS_LC) && !rw, 1'b1);
        end
        if (errors == 0) ok($sformatf("%0d random ops over four banks served as the model predicts, serve off and on", NOPS));
        if (hits != e_hits || misses != e_misses)
            fail($sformatf("hits/misses %0d/%0d, model %0d/%0d", hits, misses, e_hits, e_misses));
        else ok($sformatf("hit/miss counters match the model: %0d hits, %0d misses", hits, misses));
        if (served != e_served) fail($sformatf("served %0d, model %0d", served, e_served));
        else ok("served counts every substituted byte");
        if (mismatches != 0) fail($sformatf("%0d mismatches with a coherent machine", mismatches));
        else ok("the monitor sees no mismatch while the machine agrees");
        if (late_fills != 0) fail($sformatf("%0d overruns at Apple speed", late_fills));
        else ok("the engine was idle before every op: no overruns");
        if (fifo_drops != 0) fail($sformatf("%0d drops", fifo_drops));
        repeat (400) @(negedge clk);
        check_ddr("after the run the DDR3 equals the model's image");
        if (d_batches < 20) fail($sformatf("the streaming client only ran %0d batches", d_batches));
        else if (d_started_bad != 0) fail($sformatf("%0d batches began outside rot_ok", d_started_bad));
        else ok($sformatf("%0d streaming batches ran under the engine, every one begun inside rot_ok", d_batches));
        if (d_issued != d_acked) fail("streaming client lost acks");
        else ok("every streaming burst was acknowledged through the pre-emptions");
        d_on <= 1'b0;
        s_stall_every <= 0;
        repeat (200) @(negedge clk);

        // ---- 6. a fill past its op serves nothing; main rides through ---------
        // Pin the page's residency first so the next access is a certain miss.
        do_op(CLS_RAM, 1'b1, 8'd1, {8'hA7, 8'h10}, 1'b0, 8'h11, 1'b1, 1'b1);
        s_lat = 200; lf0 = late_fills;
        // A miss whose critical line lands two ops later.
        do_op(CLS_RAM, 1'b1, 8'd3, {8'hA7, 8'h10}, 1'b1, 8'h00, 1'b0, 1'b0);
        if (sub_en) fail("a fill that had not landed was served");
        e_served = e_served - 1;             // the model served it; the DUT rightly did not
        // The engine is still busy: a main op is served regardless...
        do_op(CLS_RAM, 1'b0, 8'd0, hot[1], 1'b1, 8'h00, 1'b0, 1'b1);
        // ...and an aux op is counted and untouched.
        do_op(CLS_RAM, 1'b1, 8'd0, hot[2], 1'b1, 8'h00, 1'b0, 1'b0);
        s_lat = 12;
        while (pq_busy) @(negedge clk);
        repeat (50) @(negedge clk);
        if (late_fills != lf0 + 1)
            fail($sformatf("late_fills %0d, expected %0d", late_fills, lf0 + 1));
        else ok("a slow fill serves nothing, main rides through, the blocked aux op is counted");
        e_hits = hits; e_misses = misses;    // re-sync: the blocked op was not modelled

        // ---- 7. the monitor ---------------------------------------------------------
        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);
        off = hot[0]; if (off[15:12] == 4'hC) off[15:12] = 4'h3;
        do_op((off[15:12] >= 4'hD) ? CLS_LC : CLS_RAM, 1'b0, 8'd0, off, 1'b0, 8'h5C, 1'b1, 1'b1);
        ref_main[off] = 8'hA3;                              // the machine disagrees
        do_op((off[15:12] >= 4'hD) ? CLS_LC : CLS_RAM, 1'b0, 8'd0, off, 1'b1, 8'h00, 1'b0, 1'b0);
        ref_main[off] = 8'h5C;
        if (mismatches != 1) fail($sformatf("mismatches %0d after one disagreement", mismatches));
        else if (last_mismatch !== {off, 8'h5C, 8'hA3})
            fail($sformatf("last_mismatch %08x", last_mismatch));
        else ok("the monitor counts a byte the machine disagrees on and names it");

        // ---- 7b. a RamWorks bank is never compared ----------------------------
        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);
        do_op(CLS_RAM, 1'b1, 8'd3, 16'h5678, 1'b0, 8'h77, 1'b1, 1'b1);
        do_op(CLS_RAM, 1'b1, 8'd3, 16'h5678, 1'b1, 8'h00, 1'b0, 1'b1);   // bus byte is mach_aux's: no compare
        if (mismatches != 0) fail("the monitor compared a RamWorks bank with the machine's bus");
        else ok("a RamWorks bank is served from the card and never compared with the bus");

        // ---- 8. the invalidate ------------------------------------------------------
        inval <= 1'b1; @(negedge clk); inval <= 1'b0; @(negedge clk);
        model_invalidate();
        if (invalidating) fail("invalidating: the walk is gone, one clock is the whole of it");
        // A read of a page that was resident is now a claim: same bytes, no fill.
        r = s_reads;
        do_op(CLS_RAM, 1'b1, 8'd0, hot[3], 1'b1, 8'h00, 1'b0, 1'b1);
        if (s_reads != r) fail("a claim after the invalidate went to the DDR3");
        else ok("an invalidate is one clock; a claimed page serves its bytes with no fill");

        // ---- 9. counters clear ------------------------------------------------------
        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);
        if (hits != 0 || mismatches != 0 || late_fills != 0) fail("cnt_clr left a counter set");
        else ok("cnt_clr clears the counters");

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    initial begin
        #(CYC * 10 * (NOPS + 3000) * 2);
        $display("FAIL: timeout");
        $finish;
    end
endmodule
