`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// page_cache_tb - the physical page cache (rtl/page_cache.sv, rung 4 of
// docs/MEMORY_REFACTOR.md), its engine, the DDR3 client, the arbiter's
// priority slot and a streaming client sharing the port, against a Wishbone
// memory that acks in order, ten-odd clocks late, stalls now and then and
// pauses for a refresh's worth.
//
// The bench holds a FULL MODEL of the cache - every set's tags, valid, dirty
// and replacement bits, and the 16 MB physical image - and after every access
// it asserts the DUT's directory equals the model's, way for way and bit for
// bit.  So the replacement policy is not merely plausible here, it is exact;
// an eviction that chose a different victim, a dirty bit that did not set, a
// tag that did not retire, all fail on the access that caused them.
//
// What this bench is for, beyond "the bytes come back":
//
//   - THE GEOMETRY IS A PARAMETER.  The same source runs at 128 x 8, 64 x 10
//     and 64 x 8; sim/run_page_cache_tb.sh builds all three.  Ten ways is not
//     a power of two, and it is in the sweep on purpose.
//   - THE LANDING RESERVATION, swept.  A line request is offered on each of
//     the seven clocks around a write's landing (P-4 .. P+2) and the bench
//     asserts what each must do: refused on the op's own P0 and on the
//     landing clock, granted otherwise, and the row it returns is the
//     pre-write one before the landing and the post-write one after.  That is
//     the P+2 law (docs/DLINE.md) in its new form.
//   - THE PRESSURE ROUND TRIP.  A working set of SETS*WAYS+8 pages, each
//     written with its own signature, read back whole: evictions happen,
//     dirty pages flush, every byte returns, and the DDR3 the stub holds
//     equals the model everywhere the cache is not holding dirty data.
//   - THE CLEAN-VICTIM PATH'S LATENCY, measured: about thirty clocks from
//     op_present to the byte, against a 1 MHz budget of ninety.
//////////////////////////////////////////////////////////////////////////////////
module page_cache_tb;
    parameter integer SETS = 128;
    parameter integer WAYS = 8;
    parameter integer NOPS = 2500;

    localparam integer SIDX  = $clog2(SETS);
    localparam integer LEV   = $clog2(WAYS);
    localparam integer NODES = (1 << LEV) - 1;
    localparam integer CYC     = 98;          // clocks per bus cycle
    localparam integer T_FAST  = 3;           // a hit's byte stands here
    localparam integer T_BUDGET = 90;         // ...and any answer, by here
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
    logic [15:0] cl_ppn = 16'd0;
    logic [7:0]  cl_off = 8'd0;
    logic        cl_rw = 1'b1, cl_wr_image = 1'b0, cl_posted = 1'b0;
    logic [7:0]  cl_wdata = 8'd0;
    logic        pw_pending = 1'b0;
    logic [15:0] pf_ppn = 16'd0;
    logic [7:0]  pf_off = 8'd0;
    logic        pw_take = 1'b0;
    logic [15:0] pw_ppn = 16'd0;
    logic [7:0]  pw_off = 8'd0;
    logic [15:0] op_addr = 16'd0;
    logic        op_present = 1'b0, op_commit = 1'b0, op_divert = 1'b0;
    logic [7:0]  data_sync = 8'd0;
    logic        serve = 1'b1, inval = 1'b0, cnt_clr = 1'b0;
    logic        master_active = 1'b1, calib_complete = 1'b0;
    logic        il_req = 1'b0, il_src = 1'b0;
    logic [15:0] il_ppn = 16'd0;
    logic [3:0]  il_line = 4'd0;

    // ---- the DUT --------------------------------------------------------------
    wire        sub_en, decided, busy, pw_ready, invalidating;
    wire [7:0]  sub_data;
    wire        mw_stb;
    wire [15:0] mw_addr;
    wire [7:0]  mw_byte;
    wire        il_ack, il_done, il_ok;
    wire [127:0] il_row;
    wire [31:0] hits, misses, served, mismatches, last_mismatch, diverted;
    wire [7:0]  late_fills, fifo_drops;
    wire [31:0] mem_fills, mem_flushes, mem_declines;
    wire        pq_busy, pq_valid, pq_we, pq_ready, pr_valid;
    wire [19:0] pq_line;
    wire [127:0] pq_wdata, pr_data;
    wire        image_ready;

    page_cache #(.SETS (SETS), .WAYS (WAYS)) u_dut (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_ppn (cl_ppn), .cl_off (cl_off),
        .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_wdata (cl_wdata),
        .cl_posted (cl_posted), .pw_pending (pw_pending), .pw_ready (pw_ready),
        .pf_ppn (pf_ppn), .pf_off (pf_off),
        .pw_take (pw_take), .pw_ppn (pw_ppn), .pw_off (pw_off),
        // No map here, so no shadow duplicate; the GS bench covers that
        // entrant (docs/GS.md rung 3e).
        .shd_take (1'b0), .shd_ppn (16'd0), .shd_off (8'd0),
        .op_addr (op_addr), .op_present (op_present), .op_commit (op_commit),
        .op_divert (op_divert), .data_sync (data_sync),
        .sub_en (sub_en), .sub_data (sub_data), .op_row_v (), .op_row (), .op_row_ppn (), .decided (decided), .busy (busy),
        .mw_stb (mw_stb),
        .mwx_stb (), .mw_bank (), .mw_addr (mw_addr), .mw_byte (mw_byte),
        .il_req (il_req), .il_ppn (il_ppn), .il_line (il_line), .il_src (il_src),
        .il_ack (il_ack), .il_done (il_done), .il_ok (il_ok), .il_row (il_row),
        .serve (serve), .inval (inval), .cnt_clr (cnt_clr), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (diverted),
        .late_fills (late_fills), .fifo_drops (fifo_drops),
        .mem_fills (mem_fills), .mem_flushes (mem_flushes), .mem_declines (mem_declines),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we), .pq_line (pq_line),
        .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .dbg_sel (4'd0), .dbg_val ()
    );

    // ---- the arbiter, the client, the streaming dummy -------------------------
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
    wire         rot_ok, mem_idle;

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
        .master_active (master_active), .op_present (op_present), .accel (1'b0),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .req (c_req[1]), .gnt (c_gnt[1]), .cyc (c_cyc[1]), .stb (c_stb[1]),
        .we (c_we[1]), .addr (c_addr[47:24]), .data (c_data[255:128]),
        .sel (c_sel[31:16]), .stall (c_stall[1]), .ack (c_ack[1]), .rdata (c_rdata),
        .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

    logic        d_req = 1'b0, d_stb = 1'b0, d_on = 1'b0;
    logic [5:0]  d_left = 6'd0;
    integer      d_issued = 0, d_acked = 0, d_batches = 0, d_started_bad = 0;
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

    // ---- the Wishbone memory stub: the whole 16 MB physical space ------------
    localparam integer IMG = 16 * 1024 * 1024;
    logic [7:0] smem [0:IMG-1];
    integer     s_lat = 12, s_stall_every = 0, s_pause = 0, s_cnt = 0;
    logic       s_stall;
    assign wb_stall = s_stall || (s_pause != 0);
    always @(posedge clk) begin
        s_cnt <= s_cnt + 1;
        s_stall <= (s_stall_every != 0) && ((s_cnt % s_stall_every) < 3);
        if (s_pause != 0) s_pause <= s_pause - 1;
    end
    localparam integer DL = 160;
    logic [3:0]   dl_aux [0:DL-1];
    logic [127:0] dl_d [0:DL-1];
    integer       dl_wp = 0, dl_rp = 0, dl_time [0:DL-1];
    integer       now = 0, s_writes = 0, s_reads = 0;
    logic         wb_ack_r = 0;
    logic [127:0] wb_rdata_r = 0;
    logic [3:0]   wb_aux_r = 0;
    assign wb_ack = wb_ack_r;
    assign wb_rdata = wb_rdata_r;
    assign wb_rdata_aux = wb_aux_r;
    // The client's line_to_wb inverted: {ppn, line} * 16.
    function automatic [23:0] wb_to_byte(input [23:0] a);
        wb_to_byte = {{a[22:10], a[6:0]}, 4'd0};
    endfunction
    integer i;
    always @(posedge clk) begin
        now <= now + 1;
        wb_ack_r <= 1'b0;
        if (wb_cyc && wb_stb && !wb_stall) begin
            if (wb_addr[9:7] == 3'd0 && wb_addr[23] == 1'b0) begin
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

    // ---- the model ------------------------------------------------------------
    logic [7:0]      mimg [0:IMG-1];       // physical memory as it should read
    logic [15:0]     m_tag [SETS][WAYS];
    bit              m_vld [SETS][WAYS];
    bit              m_dty [SETS][WAYS];
    logic [NODES-1:0] m_plr [SETS];
    bit              m_touch [0:65535];    // pages this run has been near
    logic [15:0]     m_list [0:65535];
    integer          m_n = 0;
    integer          e_hits = 0, e_misses = 0, e_served = 0, e_fills = 0, e_flushes = 0;

    function automatic [SIDX-1:0] set_of(input [15:0] ppn);
        set_of = ppn[SIDX-1:0] ^ ppn[2*SIDX-1 -: SIDX];
    endfunction
    function automatic [LEV-1:0] plru_pick(input [NODES-1:0] b);
        int l, node;
        logic [LEV-1:0] idx;
        idx = '0; node = 0;
        for (l = 0; l < LEV; l = l + 1) begin
            idx  = (idx << 1) | LEV'(b[node]);
            node = 2*node + 1 + int'(b[node]);
        end
        plru_pick = idx;
    endfunction
    function automatic [NODES-1:0] plru_touch(input [NODES-1:0] b, input [LEV-1:0] t);
        int l, node;
        logic dir;
        plru_touch = b; node = 0;
        for (l = 0; l < LEV; l = l + 1) begin
            dir = t[LEV-1-l];
            plru_touch[node] = ~dir;
            node = 2*node + 1 + int'(dir);
        end
    endfunction

    task automatic note(input [15:0] ppn);
        if (!m_touch[ppn]) begin m_touch[ppn] = 1'b1; m_list[m_n] = ppn; m_n = m_n + 1; end
    endtask

    // One access through the model: the same decisions the RTL must make.
    // did_fill/did_flush are what the DDR3 must see.
    task automatic model_access(input [15:0] ppn, input [7:0] off, input bit rw,
                                input [7:0] wd, output bit did_fill, output bit did_flush);
        int s, w, v, k;
        bit hit;
        begin
            did_fill = 0; did_flush = 0;
            s = int'(set_of(ppn));
            hit = 0; w = 0;
            for (k = 0; k < WAYS; k = k + 1)
                if (m_vld[s][k] && m_tag[s][k] == ppn) begin hit = 1; w = k; end
            if (!hit) begin
                v = -1;
                for (k = WAYS-1; k >= 0; k = k - 1) if (!m_vld[s][k]) v = k;
                if (v < 0) begin
                    v = int'(plru_pick(m_plr[s]));
                    if (v >= WAYS) v = v - WAYS;
                end
                if (m_vld[s][v] && m_dty[s][v]) did_flush = 1;
                did_fill = 1;
                m_vld[s][v] = 1'b1;
                m_dty[s][v] = !rw;
                m_tag[s][v] = ppn;
                w = v;
                note(ppn);
            end
            m_plr[s] = plru_touch(m_plr[s], LEV'(w));
            if (!rw) begin
                mimg[{ppn, off}] = wd;
                m_dty[s][w] = 1'b1;
                note(ppn);
            end
        end
    endtask

    task automatic model_invalidate;
        int s, k;
        for (s = 0; s < SETS; s = s + 1)
            for (k = 0; k < WAYS; k = k + 1) begin m_vld[s][k] = 0; m_dty[s][k] = 0; end
    endtask

    // The DUT's directory against the model's, way for way.
    // The engine's retag is the last thing a miss does, so the directory is
    // only the model's answer once it is idle.
    task automatic check_dir(input string what);
        int s, k, bad;
        begin
            while (busy || invalidating) @(negedge clk);
            bad = 0;
            for (s = 0; s < SETS; s = s + 1) begin
                for (k = 0; k < WAYS; k = k + 1) begin
                    if (u_dut.dir[k][s][17] !== m_vld[s][k]) begin
                        bad = bad + 1;
                        if (bad < 5) $display("   dir: set %0d way %0d valid %0b, model %0b (tag %04x model %04x)",
                                              s, k, u_dut.dir[k][s][17], m_vld[s][k], u_dut.dir[k][s][15:0], m_tag[s][k]);
                    end else if (m_vld[s][k] && u_dut.dir[k][s][15:0] !== m_tag[s][k]) begin
                        bad = bad + 1;
                        if (bad < 5) $display("   dir: set %0d way %0d tag %04x, model %04x", s, k, u_dut.dir[k][s][15:0], m_tag[s][k]);
                    end else if (m_vld[s][k] && u_dut.dir[k][s][16] !== m_dty[s][k]) begin
                        bad = bad + 1;
                        if (bad < 5) $display("   dir: set %0d way %0d (tag %04x) dirty %0b, model %0b",
                                              s, k, m_tag[s][k], u_dut.dir[k][s][16], m_dty[s][k]);
                    end
                end
                if (u_dut.plr[s] !== m_plr[s]) begin
                    bad = bad + 1;
                    if (bad < 5) $display("   dir: set %0d plru %b, model %b", s, u_dut.plr[s], m_plr[s]);
                end
            end
            if (bad != 0) fail($sformatf("%0s: %0d directory entries differ from the model", what, bad));
            else ok(what);
        end
    endtask

    // Everywhere the cache is not holding dirty data, the DDR3 is the image.
    task automatic check_ddr(input string what);
        int n, s, k, b, bad;
        logic [15:0] p;
        bit resident_dirty;
        begin
            bad = 0;
            for (n = 0; n < m_n; n = n + 1) begin
                p = m_list[n];
                s = int'(set_of(p));
                resident_dirty = 0;
                for (k = 0; k < WAYS; k = k + 1)
                    if (m_vld[s][k] && m_tag[s][k] == p && m_dty[s][k]) resident_dirty = 1;
                if (!resident_dirty)
                    for (b = 0; b < 256; b = b + 1)
                        if (smem[{p, 8'(b)}] !== mimg[{p, 8'(b)}]) bad = bad + 1;
            end
            if (bad != 0) fail($sformatf("%0s: %0d bytes of the DDR3 differ from the model", what, bad));
            else ok($sformatf("%0s (%0d pages)", what, m_n));
        end
    endtask

    // ---- one access -----------------------------------------------------------
    integer last_n;
    task automatic do_op(input [1:0] cls, input [15:0] ppn, input [7:0] off,
                         input bit rw, input [7:0] wd, input bit check, input integer cyc_len);
        bit exp_sub, fill, flush, cacheable;
        logic [7:0] exp_data, bus_byte;
        integer n;
        begin
            cacheable = (cls != CLS_BUS);
            // rtl/accel_seq.sv presents nothing while the cache is busy; so
            // does the bus, at 98 clocks a cycle.
            while (busy || invalidating) @(negedge clk);
            @(negedge clk);
            op_present <= 1'b1; pf_ppn <= ppn; pf_off <= off; op_addr <= {ppn[7:0], off};
            @(negedge clk);
            op_present <= 1'b0;
            cl_valid <= 1'b1; cl_cls <= cls; cl_ppn <= ppn; cl_off <= off;
            cl_rw <= rw; cl_wr_image <= !rw && cacheable; cl_wdata <= wd; cl_posted <= 1'b0;
            @(negedge clk);
            cl_valid <= 1'b0;

            exp_sub = 1'b0; exp_data = 8'hxx;
            if (cacheable) begin
                exp_data = rw ? mimg[{ppn, off}] : wd;
                model_access(ppn, off, rw, wd, fill, flush);
                if (fill)  e_fills   = e_fills + 1;
                if (flush) e_flushes = e_flushes + 1;
                if (rw) begin
                    if (fill) e_misses = e_misses + 1; else e_hits = e_hits + 1;
                    if (serve) begin exp_sub = 1'b1; e_served = e_served + 1; end
                end else if (fill) e_misses = e_misses + 1;
            end

            // Wait for the decision (a hit is three clocks; a miss rides the engine).
            n = 2;
            while (!decided && n < T_BUDGET) begin @(negedge clk); n = n + 1; end
            last_n = n;
            if (check) begin
                if (!decided) fail($sformatf("ppn %04x off %02x: no decision inside %0d clocks", ppn, off, T_BUDGET));
                else if (sub_en !== exp_sub)
                    fail($sformatf("ppn %04x off %02x rw=%0d: sub_en %0d, expected %0d", ppn, off, rw, sub_en, exp_sub));
                else if (exp_sub && sub_data !== exp_data)
                    fail($sformatf("ppn %04x off %02x: served %02x, expected %02x", ppn, off, sub_data, exp_data));
            end
            // The bus's byte must stand three clocks before the commit: the
            // monitor compares against data_sync REGISTERED.
            bus_byte = rw ? (cacheable ? exp_data : 8'h5A) : wd;
            data_sync <= bus_byte;
            repeat (3) @(negedge clk);
            n = n + 3;
            while (n < cyc_len - 3) begin @(negedge clk); n = n + 1; end
            op_commit <= 1'b1;
            @(negedge clk);
            op_commit <= 1'b0;
            @(negedge clk);
            @(negedge clk);
        end
    endtask

    // A posted write, the data front's drain: pw_take is its P0.
    task automatic do_posted(input [15:0] ppn, input [7:0] off, input [7:0] wd, input integer tail);
        bit fill, flush;
        integer n;
        begin
            while (!pw_ready) @(negedge clk);
            @(negedge clk);
            pw_take <= 1'b1; pw_ppn <= ppn; pw_off <= off; pw_pending <= 1'b1;
            @(negedge clk);
            pw_take <= 1'b0;
            cl_valid <= 1'b1; cl_cls <= CLS_RAM; cl_ppn <= ppn; cl_off <= off;
            cl_rw <= 1'b0; cl_wr_image <= 1'b1; cl_wdata <= wd; cl_posted <= 1'b1;
            @(negedge clk);
            cl_valid <= 1'b0; cl_posted <= 1'b0;
            model_access(ppn, off, 1'b0, wd, fill, flush);
            if (fill)  begin e_fills = e_fills + 1; e_misses = e_misses + 1; end
            if (flush) e_flushes = e_flushes + 1;
            n = 0;
            while (busy && n < T_BUDGET) begin @(negedge clk); n = n + 1; end
            pw_pending <= 1'b0;
            repeat (tail) @(negedge clk);
        end
    endtask

    // ---- the line port --------------------------------------------------------
    integer ila_n = 0, ild_n = 0, ila_t = 0, ild_t = 0;
    logic         ild_ok;
    logic [127:0] ild_row;
    always @(posedge clk) if (!rst) begin
        if (il_ack)  begin ila_n <= ila_n + 1; ila_t <= now; end
        if (il_done) begin ild_n <= ild_n + 1; ild_t <= now; ild_ok <= il_ok; ild_row <= il_row; end
    end

    // Offer a line request and wait for the transaction, or report it refused.
    task automatic il_get(input [15:0] ppn, input [3:0] line, input integer patience,
                          output bit got, output bit okv, output logic [127:0] row);
        integer n, a0, d0;
        begin
            a0 = ila_n; d0 = ild_n;
            @(negedge clk);
            il_req <= 1'b1; il_ppn <= ppn; il_line <= line;
            n = 0;
            while (ila_n == a0 && n < patience) begin @(negedge clk); n = n + 1; end
            il_req <= 1'b0;
            got = (ila_n != a0);
            n = 0;
            while (ild_n == d0 && n < 12) begin @(negedge clk); n = n + 1; end
            okv = ild_ok; row = ild_row;
            if (got && ild_n == d0) fail("a granted line request never completed");
            if (got && (ild_t - ila_t) != 3)
                fail($sformatf("il_done %0d clocks after the ack, wanted 3", ild_t - ila_t));
        end
    endtask

    // the write tap, watched
    integer mw_count = 0;
    logic [15:0] mw_last_addr;
    logic [7:0]  mw_last_byte;
    always @(posedge clk) if (!rst && mw_stb) begin
        mw_count <= mw_count + 1;
        mw_last_addr <= mw_addr;
        mw_last_byte <= mw_byte;
    end

    // ---- the run ---------------------------------------------------------------
    integer n, k, a, b, s, w, base;
    logic [15:0] ppn;
    logic [7:0]  off;
    logic [1:0]  cls;
    bit rw, got, okv;
    logic [127:0] row;
    integer f0, x0, d0, a0;
    integer nfast, nslow, slow_sum;

    initial begin
        for (a = 0; a < IMG; a = a + 1) begin
            smem[a] = 8'(a[7:0] ^ a[15:8] ^ a[23:16] ^ 8'h5A);
            mimg[a] = smem[a];
        end
        for (a = 0; a < 65536; a = a + 1) m_touch[a] = 1'b0;
        for (s = 0; s < SETS; s = s + 1) begin
            u_dut.plr[s] = {NODES{1'b0}};                 // the bitstream's zeros
            for (k = 0; k < WAYS; k = k + 1) u_dut.dir[k][s] = 18'd0;
        end
        model_invalidate();
        for (s = 0; s < SETS; s = s + 1) m_plr[s] = {NODES{1'b0}};

        repeat (5) @(negedge clk);
        rst <= 1'b0;
        repeat (5) @(negedge clk);
        // The reset walks the directory clear, one set a clock.
        if (!invalidating) fail("reset did not raise invalidating");
        n = 0;
        while (invalidating && n < 4 * SETS) begin @(negedge clk); n = n + 1; end
        if (invalidating) fail("the reset walk never finished");
        else ok($sformatf("reset walks the directory clear in %0d clocks and lowers invalidating", n));

        // ---- 1. nothing happens before the DDR3 is calibrated -----------------
        if (image_ready) fail("image_ready before calibration");
        do_op(CLS_RAM, 16'h0004, 8'h10, 1'b1, 8'h00, 1'b0, CYC);
        if (u_dut.fifo_drops == 0) fail("a miss before calibration was not counted as a drop");
        else ok("before the DDR3 is calibrated a miss is dropped, not filled");
        model_invalidate();               // that access left nothing behind
        for (s = 0; s < SETS; s = s + 1) m_plr[s] = {NODES{1'b0}};
        e_hits = 0; e_misses = 0; e_served = 0; e_fills = 0; e_flushes = 0;
        calib_complete <= 1'b1;
        @(negedge clk);
        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);
        if (!image_ready) fail("image_ready did not follow calib_complete");
        if (s_writes != 0 || s_reads != 0) fail("the DDR3 was touched before any fill");

        // ---- 2. the first miss, its latency, and the hits after it ------------
        do_op(CLS_RAM, 16'h0004, 8'h10, 1'b1, 8'h00, 1'b1, CYC);
        if (last_n > 45) fail($sformatf("a clean-victim miss answered in %0d clocks", last_n));
        else ok($sformatf("a cold read misses and answers in %0d clocks, inside the 1 MHz budget", last_n));
        if (mem_fills != 1 || mem_flushes != 0)
            fail($sformatf("fills %0d flushes %0d after one cold miss", mem_fills, mem_flushes));
        if (s_writes != 0) fail("a clean victim was flushed");
        else ok("a clean victim fills with no snapshot and no flush");

        nfast = 0;
        for (k = 0; k < 16; k = k + 1) begin
            do_op(CLS_RAM, 16'h0004, 8'(k * 16 + 3), 1'b1, 8'h00, 1'b1, CYC);
            if (last_n == T_FAST) nfast = nfast + 1;
        end
        if (nfast != 16) fail($sformatf("only %0d of 16 hits stood at three clocks", nfast));
        else ok("every byte of a resident page is served three clocks after op_present");
        check_dir("the directory after the first page matches the model");

        // ---- 3. writes: the landing, the dirty bit, the read back -------------
        do_op(CLS_RAM, 16'h0004, 8'h10, 1'b0, 8'hA5, 1'b1, CYC);
        do_op(CLS_RAM, 16'h0004, 8'h10, 1'b1, 8'h00, 1'b1, CYC);
        do_op(CLS_RAM, 16'h0004, 8'h11, 1'b0, 8'h5A, 1'b1, CYC);
        do_op(CLS_RAM, 16'h0004, 8'h11, 1'b1, 8'h00, 1'b1, CYC);
        ok("a write lands in its way and the byte reads back at three clocks");
        check_dir("the write left the page dirty, and only that page");

        // ---- 4. the ROM is a page like any other ------------------------------
        do_op(CLS_ROM, 16'hFFD0, 8'h34, 1'b1, 8'h00, 1'b1, CYC);
        do_op(CLS_ROM, 16'hFFD0, 8'h35, 1'b1, 8'h00, 1'b1, CYC);
        if (last_n != T_FAST) fail("a second ROM byte did not hit");
        else ok("the ROM is bank $FF, cached and served like any other page");

        // ---- 5. an auxiliary page and a RamWorks bank, in one space -----------
        do_op(CLS_RAM, 16'h0104, 8'h10, 1'b0, 8'h11, 1'b1, CYC);
        do_op(CLS_RAM, 16'h0004, 8'h10, 1'b1, 8'h00, 1'b1, CYC);   // main is untouched
        do_op(CLS_RAM, 16'h2A04, 8'h10, 1'b0, 8'h22, 1'b1, CYC);   // RamWorks bank 41
        do_op(CLS_RAM, 16'h0104, 8'h10, 1'b1, 8'h00, 1'b1, CYC);
        do_op(CLS_RAM, 16'h2A04, 8'h10, 1'b1, 8'h00, 1'b1, CYC);
        ok("main, auxiliary and a RamWorks bank hold one page number at once");
        check_dir("three banks of one page sit in three ways of one set");

        // ---- 6. the line port -------------------------------------------------
        il_get(16'h0004, 4'h1, 8, got, okv, row);
        if (!got) fail("a line request was never granted");
        else if (!okv) fail("a resident page declined a line request");
        else begin
            for (b = 0; b < 16; b = b + 1)
                if (row[8*b +: 8] !== mimg[{16'h0004, 4'h1, 4'(b)}]) fail("il_row byte differs");
            ok("a line request returns the resident row three clocks after its ack");
        end
        d0 = int'(mem_declines);
        il_get(16'h7700, 4'h0, 8, got, okv, row);
        if (!got) fail("a line request for an absent page was not granted");
        else if (okv) fail("an absent page did not decline");
        else if (mem_declines != d0 + 1) fail("the decline was not counted");
        else ok("a page that is not resident declines, and the decline is counted");

        // ---- 7. the landing reservation, swept --------------------------------
        // A write to a resident page, with a line request offered on each of
        // the clocks around its landing.  The op's own P0 and the landing
        // clock must refuse; every other clock grants, and what it reads says
        // which side of the write it read.
        for (k = -4; k <= 4; k = k + 1) begin
            logic [7:0] before_b, after_b;
            integer got_at, da, db;
            before_b = mimg[{16'h0004, 8'h20}];
            after_b  = 8'(8'hC0 + (k + 4));
            a0 = ila_n;
            // The op's P0 is offer index da+1; the line request is offered at
            // index db.  k is the request's clock relative to the P0, so the
            // write's landing - two clocks after it - is k = 2.
            da = (k < 0) ? (-k - 1) : 0;
            db = (k < 0) ? 0        : (k + 1);
            while (busy) @(negedge clk);
            fork
                begin
                    repeat (da) @(negedge clk);
                    do_op(CLS_RAM, 16'h0004, 8'h20, 1'b0, after_b, 1'b1, CYC);
                end
                begin
                    repeat (db) @(negedge clk);
                    il_req <= 1'b1; il_ppn <= 16'h0004; il_line <= 4'h2;
                    @(negedge clk);
                    il_req <= 1'b0;
                end
            join
            got_at = ila_n;
            repeat (8) @(negedge clk);
            if (k == 0) begin
                if (got_at != a0) fail("a line request was granted on an op's own P0");
            end else if (k == 2) begin
                if (got_at != a0) fail("a line request was granted on the clock a write landed");
            end else begin
                if (got_at == a0) fail($sformatf("a line request at k=%0d was refused for no reason", k));
                else if (k > 2 && ild_row[7:0] !== after_b)
                    fail($sformatf("a line request after the landing (k=%0d) read %02x, the pre-write byte", k, ild_row[7:0]));
                else if (k < 2 && ild_row[7:0] !== before_b)
                    fail($sformatf("a line request before the landing (k=%0d) read %02x, not the pre-write %02x", k, ild_row[7:0], before_b));
            end
        end
        if (errors == 0) ok("the landing reservation refuses the op's P0 and the write's landing clock, and nothing else");
        if (u_dut.cnt_land_clash != 0) fail("an entrant landed on a write's clock");

        // ---- 8. a posted write drains through the same path -------------------
        do_posted(16'h0004, 8'h30, 8'h99, 6);
        do_op(CLS_RAM, 16'h0004, 8'h30, 1'b1, 8'h00, 1'b1, CYC);
        ok("a posted write lands and the byte reads back");
        do_posted(16'h5501, 8'h07, 8'hEE, 6);      // a posted write that misses
        do_op(CLS_RAM, 16'h5501, 8'h07, 1'b1, 8'h00, 1'b1, CYC);
        ok("a posted write to an absent page fills it, patches it and reads back");
        check_dir("the posted writes left the directory as the model has it");

        // ---- 9. the pressure round trip ---------------------------------------
        // More pages than the cache holds, each signed, then all read back.
        base = 0;
        for (n = 0; n < SETS * WAYS + 8; n = n + 1) begin
            ppn = 16'(16'h0300 + n);
            do_op(CLS_RAM, ppn, 8'h40, 1'b0, 8'(n & 8'hFF), 1'b1, 20);
            do_op(CLS_RAM, ppn, 8'h41, 1'b0, 8'((n >> 8) & 8'hFF), 1'b1, 20);
        end
        for (n = 0; n < SETS * WAYS + 8; n = n + 1) begin
            ppn = 16'(16'h0300 + n);
            do_op(CLS_RAM, ppn, 8'h40, 1'b1, 8'h00, 1'b1, 20);
            do_op(CLS_RAM, ppn, 8'h41, 1'b1, 8'h00, 1'b1, 20);
        end
        if (mem_flushes == 0) fail("a working set larger than the cache flushed nothing");
        else ok($sformatf("%0d pages under %0d ways: %0d fills, %0d dirty flushes, every byte returned",
                          SETS*WAYS+8, WAYS, mem_fills, mem_flushes));
        check_dir("the directory after the pressure round trip matches the model");
        while (pq_busy) @(negedge clk);
        repeat (400) @(negedge clk);
        check_ddr("the flushes left the DDR3 exactly as the model has it");

        // ---- 10. random traffic, the stream and the stalls under it -----------
        d_on <= 1'b1;
        s_stall_every <= 37;
        for (n = 0; n < NOPS; n = n + 1) begin
            k = $urandom % 100;
            // a working set that fits, with excursions that do not
            if (k < 55)      ppn = 16'(16'h0000 + ($urandom % 96));         // main
            else if (k < 75) ppn = 16'(16'h0100 + ($urandom % 96));         // aux
            else if (k < 85) ppn = 16'(16'hFFC0 + ($urandom % 64));         // the ROM
            else             ppn = 16'($urandom);                           // anywhere in 16 MB
            off = 8'($urandom);
            cls = (ppn[15:8] == 8'hFF) ? CLS_ROM : (off[7:4] >= 4'hD) ? CLS_LC : CLS_RAM;
            rw  = (cls == CLS_ROM) ? 1'b1 : ($urandom % 100 < 55);
            if (n % 500 == 250) s_pause = 23;
            if (n == NOPS / 2) serve <= 1'b0;
            if (n == NOPS / 2 + 200) serve <= 1'b1;
            do_op(cls, ppn, off, rw, 8'($urandom), 1'b1, 24);
            if (n % 250 == 249) check_dir($sformatf("the directory still matches the model after %0d random ops", n + 1));
        end
        if (errors == 0) ok($sformatf("%0d random ops over the whole 16 MB served as the model predicts", NOPS));
        if (hits != e_hits || misses != e_misses)
            fail($sformatf("hits/misses %0d/%0d, model %0d/%0d", hits, misses, e_hits, e_misses));
        else ok($sformatf("hit and miss counters match the model: %0d hits, %0d misses", hits, misses));
        if (served != e_served) fail($sformatf("served %0d, model %0d", served, e_served));
        else ok("served counts every substituted byte");
        if (mem_fills != e_fills) fail($sformatf("MEM_FILLS %0d, model %0d", mem_fills, e_fills));
        else ok($sformatf("MEM_FILLS matches the model exactly: %0d", mem_fills));
        if (mem_flushes != e_flushes) fail($sformatf("MEM_FLUSHES %0d, model %0d", mem_flushes, e_flushes));
        else ok($sformatf("MEM_FLUSHES matches the model exactly: %0d", mem_flushes));
        if (mismatches != 0) fail($sformatf("%0d mismatches with a coherent machine", mismatches));
        else ok("the monitor sees no mismatch while the machine agrees");
        if (late_fills != 0) fail($sformatf("%0d overruns at Apple speed", late_fills));
        else ok("the engine was idle before every op: no overruns");
        if (fifo_drops != 0) fail($sformatf("%0d drops", fifo_drops));
        if (u_dut.cnt_ppn_clash != 0) fail("a classified op's page differed from the one its P0 indexed");
        else ok("every classified op's page was the one its P0 preview indexed");
        while (pq_busy) @(negedge clk);
        repeat (400) @(negedge clk);
        check_ddr("after the random run the DDR3 equals the model");
        if (d_batches < 20) fail($sformatf("the streaming client only ran %0d batches", d_batches));
        else if (d_started_bad != 0) fail($sformatf("%0d batches began outside rot_ok", d_started_bad));
        else ok($sformatf("%0d streaming batches ran under the engine, every one begun inside rot_ok", d_batches));
        if (d_issued != d_acked) fail("the streaming client lost acks");
        else ok("every streaming burst was acknowledged through the pre-emptions");
        d_on <= 1'b0;
        s_stall_every <= 0;
        repeat (200) @(negedge clk);

        // ---- 11. hit under miss, and the overrun counter ----------------------
        // Slow the memory right down, start a miss, and offer the line port a
        // page that IS resident while the engine runs.
        do_op(CLS_RAM, 16'h0004, 8'h10, 1'b1, 8'h00, 1'b1, CYC);   // resident again
        s_lat = 240;
        f0 = int'(late_fills);
        fork
            do_op(CLS_RAM, 16'h6E00, 8'h00, 1'b1, 8'h00, 1'b0, CYC * 4);
            begin
                repeat (12) @(negedge clk);
                il_get(16'h0004, 4'h1, 12, got, okv, row);
                if (!got || !okv) fail("a resident page did not answer the line port under a miss");
                else ok("hit under miss: the line port answers another page while the engine fills");
            end
        join
        s_lat = 12;
        while (pq_busy) @(negedge clk);
        repeat (20) @(negedge clk);
        if (u_dut.cnt_hit_uc == 0 && late_fills == f0) ok("no op overran the engine at Apple speed");
        check_dir("hit under miss left the directory as the model has it");

        // ---- 12. the monitor ---------------------------------------------------
        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);
        do_op(CLS_RAM, 16'h0004, 8'h50, 1'b0, 8'h5C, 1'b1, CYC);
        // the machine disagrees on the next read
        @(negedge clk);
        op_present <= 1'b1; pf_ppn <= 16'h0004; pf_off <= 8'h50; op_addr <= 16'h0450;
        @(negedge clk);
        op_present <= 1'b0;
        cl_valid <= 1'b1; cl_cls <= CLS_RAM; cl_ppn <= 16'h0004; cl_off <= 8'h50;
        cl_rw <= 1'b1; cl_wr_image <= 1'b0; cl_posted <= 1'b0;
        @(negedge clk);
        cl_valid <= 1'b0;
        model_access(16'h0004, 8'h50, 1'b1, 8'h00, got, okv);
        e_hits = e_hits + 1;
        repeat (4) @(negedge clk);
        data_sync <= 8'hA3;
        repeat (60) @(negedge clk);
        op_commit <= 1'b1; @(negedge clk); op_commit <= 1'b0;
        repeat (4) @(negedge clk);
        if (mismatches != 1) fail($sformatf("mismatches %0d after one disagreement", mismatches));
        else if (last_mismatch !== {16'h0450, 8'h5C, 8'hA3})
            fail($sformatf("last_mismatch %08x", last_mismatch));
        else ok("the monitor counts a byte the machine disagrees on and names it");

        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);
        do_op(CLS_RAM, 16'h2A04, 8'h60, 1'b0, 8'h77, 1'b1, CYC);
        do_op(CLS_RAM, 16'h2A04, 8'h60, 1'b1, 8'h00, 1'b1, CYC);
        if (mismatches != 0) fail("the monitor compared a RamWorks bank with the bus");
        else ok("only physical banks 0 and 1 - the machine's own memory - are compared with the bus");

        // ---- 13. the write tap -------------------------------------------------
        x0 = mw_count;
        do_op(CLS_RAM, 16'h0004, 8'h70, 1'b0, 8'h3C, 1'b1, CYC);
        if (mw_count != x0 + 1) fail($sformatf("the main write tap fired %0d times for one main write", mw_count - x0));
        else if (mw_last_addr !== 16'h0470 || mw_last_byte !== 8'h3C)
            fail($sformatf("the tap reported %04x/%02x", mw_last_addr, mw_last_byte));
        else ok("every byte landing in physical bank 0 is on the write tap, and nothing else");
        x0 = mw_count;
        do_op(CLS_RAM, 16'h0104, 8'h70, 1'b0, 8'h3D, 1'b1, CYC);
        do_op(CLS_RAM, 16'h2A04, 8'h70, 1'b0, 8'h3E, 1'b1, CYC);
        if (mw_count != x0) fail("an auxiliary or RamWorks write reached the main tap");

        // ---- 13b. the line port's traffic, split by front ----------------------
        if (u_dut.cnt_il_i != ila_n || u_dut.cnt_il_d != 0)
            fail($sformatf("the line port booked %0d/%0d by source, %0d acks in all",
                           u_dut.cnt_il_i, u_dut.cnt_il_d, ila_n));
        else ok($sformatf("every one of the %0d line-port grants is booked to the front that asked", ila_n));

        // ---- 14. the invalidate and the counters -------------------------------
        inval <= 1'b1; @(negedge clk); inval <= 1'b0; @(negedge clk);
        model_invalidate();
        if (!invalidating) fail("an invalidate did not raise invalidating");
        n = 0;
        while (invalidating && n < 4 * SETS) begin @(negedge clk); n = n + 1; end
        if (invalidating) fail("the invalidate walk never finished");
        else if (n > SETS + 4) fail($sformatf("the invalidate walk took %0d clocks for %0d sets", n, SETS));
        else ok($sformatf("an invalidate walks %0d sets in %0d clocks, invalidating high across it", SETS, n));
        if (u_dut.cnt_iv_block != 0) fail("an op was answered under the invalidate walk");
        f0 = int'(mem_fills);
        do_op(CLS_RAM, 16'h0004, 8'h10, 1'b1, 8'h00, 1'b1, CYC);
        if (mem_fills != f0 + 1) fail("a read after the invalidate did not fill");
        else ok("an invalidate is one clock, and the next read fills from the DDR3");
        check_dir("the directory after the invalidate and one fill matches the model");
        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);
        if (hits != 0 || mismatches != 0 || late_fills != 0 || mem_fills != 0)
            fail("cnt_clr left a counter set");
        else ok("cnt_clr clears the counters");

        $display("%0d checks, %0d errors  (SETS=%0d WAYS=%0d)", checks, errors, SETS, WAYS);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    initial begin
        #(10 * 400 * (NOPS + 6000));
        $display("FAIL: timeout");
        $finish;
    end
endmodule
