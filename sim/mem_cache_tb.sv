`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mem_cache_tb - the cache, its DDR3 client and the ROM, against a Wishbone
// memory that behaves like the DDR3 does: acks in order, ten-odd clocks late,
// stalling now and then, and pausing for a refresh every so often.
//
// Ops arrive the way apple_mmu delivers them, one per 98-clock bus cycle, over
// a small address space with a hot set of lines so the cache both hits and
// misses.  A reference model keeps the image, the machine's own RAM (the bus's
// byte at op_commit), and a copy of the cache's tags with the same tree-PLRU,
// so every hit, every miss and every served byte is predicted before the DUT
// answers.  A streaming client shares the port through wb_arb's rotation, so
// the fills are pre-empting batches the whole time.
//
// Directed cases after the random run: a fill that lands too late is dropped
// and counted; an invalidate empties the cache and the serve bits are
// honoured through it; the monitor sees a byte the machine disagrees on; the
// ROM answers only once it has all its chunks; nothing is ever dropped on
// the way to the DDR3.
//////////////////////////////////////////////////////////////////////////////////
module mem_cache_tb;
    parameter integer SETS = 512;
    parameter integer NOPS = 6000;

    localparam integer CYC = 98;                 // clocks per bus cycle
    localparam integer T_CHECK = 88;             // where the driver would latch din
    localparam integer T_COMMIT = 91;
    localparam [1:0] CLS_BUS = 2'd0, CLS_RAM = 2'd1, CLS_LC = 2'd2, CLS_ROM = 2'd3;
    localparam integer IW = $clog2(SETS);
    localparam integer TW = 20 - IW;

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
    logic [23:0] cl_pa = 24'd0;
    logic        cl_rw = 1'b1, cl_wr_image = 1'b0;
    logic [15:0] op_addr = 16'd0;
    logic [7:0]  op_wdata = 8'd0;
    logic        op_present = 1'b0, op_commit = 1'b0;
    logic [7:0]  data_sync = 8'd0;
    logic [13:0] rom_addr = 14'd0;
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
    wire        mq_valid, mq_kind, mq_ready, mr_valid;
    wire [1:0]  mq_id, mr_id;
    wire [19:0] mq_line;
    wire [3:0]  mq_byte;
    wire [7:0]  mq_data;
    wire [127:0] mr_data;
    wire [7:0]  rom_byte;
    wire        rom_loaded;

    apple_rom u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .rd_en (cl_valid), .rd_addr (rom_addr), .rd_data (rom_byte),
        .rom_loaded (rom_loaded)
    );

    mem_cache #(.SETS (SETS)) u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_pa (cl_pa), .cl_rw (cl_rw),
        .cl_wr_image (cl_wr_image), .op_addr (op_addr), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit), .op_divert (1'b0), .data_sync (data_sync),
        .rom_byte (rom_byte), .rom_loaded (rom_loaded),
        .sub_en (sub_en), .sub_data (sub_data),
        .serve (serve), .inval (inval), .cnt_clr (cnt_clr), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (), .late_fills (late_fills), .fifo_drops (fifo_drops),
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data)
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

    mem_client u_client (
        .clk (clk), .rst (rst), .calib_complete (calib_complete),
        .master_active (master_active), .op_present (op_present),
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data),
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
    integer      d_started_bad = 0;      // batches that began outside rot_ok
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
                if (c_gnt[0] && !d_left[5] && d_left == 6'd0) begin d_req <= 1'b0; d_stb <= 1'b0; end
                if (d_stb && !c_stall[0]) begin
                    d_issued <= d_issued + 1;
                    d_left <= d_left - 6'd1;
                    if (d_left == 6'd1) begin d_stb <= 1'b0; d_req <= 1'b0; d_batches <= d_batches + 1; end
                end
            end
            if (c_ack[0]) d_acked <= d_acked + 1;
        end
    end
    // A batch starts the clock the grant lands: rot_ok must have been high then.
    logic held_q = 0;
    always @(posedge clk) begin
        held_q <= u_arb.held;
        if (u_arb.held && !held_q && !rot_ok_q) d_started_bad <= d_started_bad + 1;
    end
    logic rot_ok_q = 0;
    always @(posedge clk) rot_ok_q <= rot_ok;

    // ---- the Wishbone memory stub -----------------------------------------------------
    // Image banks 0-7 (512 KB): the machine's two, and room for a RamWorks
    // bank above them.  Bank 7 of the DDR3 (the ring) is ignored.
    localparam integer IMG = 8 * 65536;
    logic [7:0] smem [0:IMG-1];
    integer     s_lat = 12;              // clocks from accept to ack
    integer     s_stall_every = 0;       // 0 = never
    integer     s_pause = 0;             // clocks of stall left: a refresh's worth
    integer     s_cnt = 0;
    logic       s_stall;
    assign wb_stall = s_stall || (s_pause != 0);
    always @(posedge clk) begin
        s_cnt <= s_cnt + 1;
        s_stall <= (s_stall_every != 0) && ((s_cnt % s_stall_every) < 3);
        if (s_pause != 0) s_pause <= s_pause - 1;
    end
    // In-order delay line of acks: {valid, aux, data}
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
    logic [7:0] ref_mem [0:IMG-1];       // the image as it should be
    logic [7:0] rom_img [0:16383];
    logic       m_valid [0:SETS-1][0:3];
    logic [TW-1:0] m_tag [0:SETS-1][0:3];
    logic [2:0] m_plru [0:SETS-1];
    integer e_hits = 0, e_misses = 0, e_served = 0, e_mismatch = 0;

    function automatic [1:0] pv(input [2:0] b);
        pv = b[0] ? (b[2] ? 2'd3 : 2'd2) : (b[1] ? 2'd1 : 2'd0);
    endfunction
    function automatic [2:0] pt(input [2:0] b, input [1:0] w);
        pt = b; pt[0] = ~w[1];
        if (!w[1]) pt[1] = ~w[0]; else pt[2] = ~w[0];
    endfunction

    // Returns 1 on a hit; installs on a read miss; touches on a hit.
    function automatic bit model_access(input [23:0] pa, input bit is_read, input bit allowed);
        integer s, w, h;
        logic [TW-1:0] t;
        begin
            s = pa[IW+3:4]; t = pa[23:IW+4]; h = -1;
            for (w = 0; w < 4; w = w + 1) if (m_valid[s][w] && m_tag[s][w] == t) h = w;
            if (h >= 0) begin
                if (allowed) m_plru[s] = pt(m_plru[s], h[1:0]);
                model_access = 1'b1;
            end else begin
                if (is_read && allowed) begin
                    w = pv(m_plru[s]);
                    m_valid[s][w] = 1'b1; m_tag[s][w] = t;
                    m_plru[s] = pt(m_plru[s], w[1:0]);
                end
                model_access = 1'b0;
            end
        end
    endfunction

    task model_invalidate;
        integer s, w;
        begin
            for (s = 0; s < SETS; s = s + 1) begin
                m_plru[s] = 3'd0;
                for (w = 0; w < 4; w = w + 1) m_valid[s][w] = 1'b0;
            end
        end
    endtask

    // ---- one bus cycle --------------------------------------------------------------------
    // Presents an op, checks the answer where the driver would latch it, and
    // commits with the machine's byte.
    logic [7:0] bus_byte;
    task do_op(input [1:0] cls, input [23:0] pa, input bit rw, input [7:0] wdata,
               input [13:0] ra, input bit wr_image, input bit check);
        bit exp_sub, hit, may;
        logic [7:0] exp_data;
        integer t;
        begin
            @(negedge clk);
            op_present <= 1'b1; op_addr <= pa[15:0]; op_wdata <= wdata;
            @(negedge clk);
            op_present <= 1'b0;
            cl_valid <= 1'b1; cl_cls <= cls; cl_pa <= pa; cl_rw <= rw;
            cl_wr_image <= wr_image; rom_addr <= ra;
            may = image_ready && !invalidating;
            @(negedge clk);
            cl_valid <= 1'b0;

            // What should happen.
            exp_sub = 1'b0; exp_data = 8'hxx;
            if (rw && (cls == CLS_RAM || cls == CLS_LC)) begin
                hit = model_access(pa, 1'b1, may);
                if (hit) e_hits = e_hits + 1; else e_misses = e_misses + 1;
                if (may && serve) begin
                    exp_sub = 1'b1; exp_data = ref_mem[pa[18:0]];
                end
            end else if (rw && cls == CLS_ROM) begin
                if (rom_loaded && serve) begin exp_sub = 1'b1; exp_data = rom_img[ra]; end
            end else if (!rw && wr_image) begin
                hit = model_access(pa, 1'b0, may);
                ref_mem[pa[18:0]] = wdata;
            end
            if (exp_sub) e_served = e_served + 1;

            // The machine's own RAM answers the bus; for ROM the ROM does.
            bus_byte = rw ? ((cls == CLS_ROM) ? rom_img[ra] :
                             (cls == CLS_BUS) ? 8'h5A : ref_mem[pa[18:0]]) : wdata;

            for (t = 3; t < T_CHECK; t = t + 1) @(negedge clk);
            if (check) begin
                if (sub_en !== exp_sub)
                    fail($sformatf("op cls=%0d pa=%06x rw=%0d: sub_en %0d, expected %0d", cls, pa, rw, sub_en, exp_sub));
                else if (exp_sub && sub_data !== exp_data)
                    fail($sformatf("op cls=%0d pa=%06x: served %02x, expected %02x", cls, pa, sub_data, exp_data));
            end
            data_sync <= bus_byte;
            for (t = T_CHECK; t < T_COMMIT; t = t + 1) @(negedge clk);
            op_commit <= 1'b1;
            @(negedge clk);
            op_commit <= 1'b0;
            for (t = T_COMMIT + 1; t < CYC; t = t + 1) @(negedge clk);
        end
    endtask

    // The image in the stub must equal the reference after the writes drain.
    task check_image(input string what);
        integer a, bad;
        begin
            bad = 0;
            for (a = 0; a < IMG; a = a + 1) if (smem[a] !== ref_mem[a]) bad = bad + 1;
            if (bad != 0) fail($sformatf("%0s: %0d image bytes differ from the reference", what, bad));
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
    logic [23:0] hot [0:NHOT-1];
    integer n, r, a, c;
    logic [23:0] pa;
    logic [1:0]  cls;
    bit          rw;
    integer      lf0, saved_served;

    initial begin
        for (a = 0; a < IMG; a = a + 1) begin smem[a] = 8'h00; ref_mem[a] = 8'h00; end
        for (a = 0; a < 16384; a = a + 1) rom_img[a] = $urandom;
        for (n = 0; n < NHOT; n = n + 1) hot[n] = {7'd0, 1'($urandom), 16'($urandom)};
        model_invalidate();

        repeat (5) @(negedge clk);
        rst <= 1'b0;
        repeat (5) @(negedge clk);

        // ---- 1. the image is ready when the DDR3 is ---------------------------
        if (image_ready) fail("image_ready before calibration");
        calib_complete <= 1'b1;
        @(negedge clk);
        if (!image_ready) fail("image_ready did not follow calib_complete");
        else if (s_writes != 0) fail("something wrote the image before any op");
        else ok("the image is ready as soon as the DDR3 is calibrated, and nothing clears it");
        while (invalidating) @(negedge clk);

        // ---- 2. the ROM ------------------------------------------------------------
        do_op(CLS_ROM, 24'h00D123, 1'b1, 8'h00, 14'h1123, 1'b0, 1'b1);
        if (rom_loaded) fail("rom_loaded before any chunk");
        for (c = 0; c < 32; c = c + 1) begin
            send_chunk((c * 7) % 32);          // out of order, like the link might
            if (c < 31 && rom_loaded) fail("rom_loaded before every chunk");
        end
        if (!rom_loaded) fail("rom_loaded not raised after 32 chunks");
        else ok("the ROM loads from 32 chunks, in any order, and not before");
        for (n = 0; n < 40; n = n + 1) begin
            a = $urandom % 16384;
            do_op(CLS_ROM, {8'd0, 2'b11, 14'(a)}, 1'b1, 8'h00, 14'(a), 1'b0, 1'b1);
        end
        ok("ROM reads are served from the ROM's own block RAM");

        // ---- 3. random traffic, the dummy streaming under it ----------------------
        d_on <= 1'b1;
        s_stall_every <= 37;
        for (n = 0; n < NOPS; n = n + 1) begin
            r = $urandom % 100;
            if (r < 75) pa = hot[$urandom % NHOT] + {20'd0, 4'($urandom)};
            else pa = {7'd0, 1'($urandom), 16'($urandom)};
            if (r < 10) cls = CLS_BUS;
            else if (r < 20) cls = CLS_ROM;
            else cls = pa[16] ? CLS_LC : CLS_RAM;
            if (cls == CLS_RAM && pa[15:12] == 4'hC) pa[15:12] = 4'h3;   // keep the image's hole clear
            rw = (cls == CLS_BUS || cls == CLS_ROM) ? 1'b1 : ($urandom % 100 < 65);
            if (n % 500 == 250) s_pause = 23;            // a refresh's worth of stall
            if (n == NOPS / 2) serve <= 3'b101;          // LC off for a while
            if (n == NOPS / 2 + 400) serve <= 3'b111;
            do_op(cls, pa, rw, 8'($urandom), pa[13:0], (cls == CLS_RAM || cls == CLS_LC) && !rw, 1'b1);
        end
        if (errors == 0) ok($sformatf("%0d random ops served as the model predicts, LC off and on", NOPS));
        if (hits != e_hits || misses != e_misses)
            fail($sformatf("hits/misses %0d/%0d, model %0d/%0d", hits, misses, e_hits, e_misses));
        else ok($sformatf("hit/miss counters match a tree-PLRU model: %0d hits, %0d misses", hits, misses));
        if (served != e_served) fail($sformatf("served %0d, model %0d", served, e_served));
        else ok("served counts every substituted byte");
        if (mismatches != 0) fail($sformatf("%0d mismatches with a coherent machine", mismatches));
        else ok("the monitor sees no mismatch while the machine agrees");
        if (late_fills != 0) fail($sformatf("%0d late fills", late_fills));
        if (fifo_drops != 0) fail($sformatf("%0d requests dropped", fifo_drops));
        repeat (300) @(negedge clk);
        check_image("every write reached the image in the DDR3");
        if (d_batches < 20) fail($sformatf("the streaming client only ran %0d batches", d_batches));
        else if (d_started_bad != 0) fail($sformatf("%0d batches began outside rot_ok", d_started_bad));
        else ok($sformatf("%0d streaming batches ran under the fills, every one begun inside rot_ok", d_batches));
        if (d_issued != d_acked) fail("streaming client lost acks");
        else ok("every streaming burst was acknowledged through the pre-emptions");
        d_on <= 1'b0;
        s_stall_every <= 0;
        repeat (200) @(negedge clk);

        // ---- 4. a late fill -------------------------------------------------------
        pa = {7'd0, 1'b0, 16'h7A10};
        s_lat = 140; lf0 = late_fills; saved_served = served;
        do_op(CLS_RAM, pa, 1'b1, 8'h00, 14'd0, 1'b0, 1'b0);   // its fill lands after the next op
        if (sub_en) fail("a fill that had not landed was served");
        if (served != saved_served) fail("served counted a late fill");
        s_lat = 12;
        e_served = served;                                     // the model served it; the DUT rightly did not
        do_op(CLS_BUS, 24'h00C000, 1'b1, 8'h00, 14'd0, 1'b0, 1'b1);
        if (late_fills != lf0 + 1) fail($sformatf("late_fills %0d, expected %0d", late_fills, lf0 + 1));
        else ok("a fill landing after the next op is dropped and counted");
        // The model installed the line; the DUT did not.  Re-sync by reading it.
        model_invalidate();
        inval <= 1'b1; @(negedge clk); inval <= 1'b0;
        if (!invalidating) fail("inval did not start a walk");
        do_op(CLS_RAM, pa, 1'b1, 8'h00, 14'd0, 1'b0, 1'b1);   // during the walk: no fill, no serve
        while (invalidating) @(negedge clk);
        ok("an invalidate walk runs, and an op during it is answered by the bus");
        e_hits = hits; e_misses = misses;                      // the walk's op is not modelled
        for (n = 0; n < 200; n = n + 1) begin
            pa = hot[$urandom % NHOT] + {20'd0, 4'($urandom)};
            if (pa[15:12] == 4'hC) pa[15:12] = 4'h3;
            do_op(pa[16] ? CLS_LC : CLS_RAM, pa, 1'b1, 8'h00, 14'd0, 1'b0, 1'b1);
        end
        if (hits != e_hits || misses != e_misses) fail("counters diverged after the invalidate");
        else ok("after the invalidate every hot line is fetched again, then hits");

        // ---- 5. the monitor ---------------------------------------------------------
        pa = hot[0]; if (pa[15:12] == 4'hC) pa[15:12] = 4'h3;
        do_op(pa[16] ? CLS_LC : CLS_RAM, pa, 1'b0, 8'h5C, 14'd0, 1'b1, 1'b1);
        ref_mem[pa[18:0]] = 8'hA3;                              // the machine disagrees
        do_op(pa[16] ? CLS_LC : CLS_RAM, pa, 1'b1, 8'h00, 14'd0, 1'b0, 1'b0);
        ref_mem[pa[18:0]] = 8'h5C;
        if (mismatches != 1) fail($sformatf("mismatches %0d after one disagreement", mismatches));
        else if (last_mismatch !== {pa[15:0], 8'h5C, 8'hA3})
            fail($sformatf("last_mismatch %08x", last_mismatch));
        else ok("the monitor counts a byte the machine disagrees on and names it");
        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);
        if (hits != 0 || mismatches != 0 || late_fills != 0) fail("cnt_clr left a counter set");
        else ok("cnt_clr clears the counters");

        // ---- 5b. a RamWorks bank: served from the image, never compared ---------
        // Image bank 5 is memory the machine does not have; its bus byte is
        // whatever its one auxiliary bank holds, and means nothing here.
        pa = 24'h051234;
        do_op(CLS_RAM, pa, 1'b0, 8'h77, 14'd0, 1'b1, 1'b1);
        ref_mem[pa[18:0]] = 8'h00;                              // the machine's bus says otherwise
        do_op(CLS_RAM, pa, 1'b1, 8'h00, 14'd0, 1'b0, 1'b0);     // a miss: the fill answers
        if (!sub_en || sub_data !== 8'h77) fail($sformatf("bank 5: served %0d/%02x, expected the image's 77", sub_en, sub_data));
        else if (mismatches != 0) fail("the monitor compared a RamWorks bank with the machine's bus");
        else ok("a RamWorks bank is served from the image and never compared with the bus");
        ref_mem[pa[18:0]] = 8'h77;
        do_op(CLS_RAM, pa, 1'b1, 8'h00, 14'd0, 1'b0, 1'b1);     // and hits
        if (mismatches != 0) fail("a hit in a RamWorks bank was compared");
        cnt_clr <= 1'b1; @(negedge clk); cnt_clr <= 1'b0; @(negedge clk);   // section 6 starts from zero

        // ---- 6. serve off entirely: nothing substituted, everything still tracked ----
        serve <= 1'b0; e_served = 0;
        for (n = 0; n < 100; n = n + 1) begin
            pa = hot[$urandom % NHOT] + {20'd0, 4'($urandom)};
            if (pa[15:12] == 4'hC) pa[15:12] = 4'h3;
            rw = ($urandom % 2);
            do_op(pa[16] ? CLS_LC : CLS_RAM, pa, rw, 8'($urandom), 14'd0, !rw, 1'b1);
        end
        if (served != 0) fail("served with every serve bit clear");
        repeat (200) @(negedge clk);
        check_image("with serving off, writes still reach the image");

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    initial begin
        #(CYC * 10 * (NOPS + 2000) * 2);
        $display("FAIL: timeout");
        $finish;
    end
endmodule
