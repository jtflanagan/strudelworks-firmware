`timescale 1ps / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mem_ddr3_tb - the page client in wb_arb's priority slot against the real
// UberDDR3 and the Micron model, with the TX ring streaming beside it.
//
// page_cache_tb proves the cache against a memory that keeps the controller's
// rules; this proves the rules hold on the controller itself, for the three
// things only it can show:
//
//   - a page written and fetched right behind it comes back written, because
//     accepted requests are performed in order - the fill-behind-flush order
//     the write-back design rests on;
//   - a sixteen-beat fill streams PIPELINED, critical line first, and the
//     whole fill-plus-flush transaction is over inside the bus cycle even
//     when it pre-empts a ring batch mid-flight - the numbers the realtime
//     budget rests on (docs/PAGE_CACHE.md);
//   - refresh keeps happening, on the controller's own tREFI timer (the
//     refresh gate that held it to the cycle's idle tail was removed
//     2026-09-14), wherever the timer puts it - and the bench TOLERATES it:
//     a transaction that met no refresh must fit its bus cycle; one that a
//     refresh landed inside is allowed the controller's refresh hold on top
//     (REF_COST below), and both worst cases are reported.  Refresh is the
//     controller's own business now, and a test that assumed it away was
//     wrong (the user, 2026-09-17).  Data is never excused: every fill must
//     match the image whatever refresh did.
//
// Transactions arrive as the page engine sends them, one per 98-clock bus
// cycle, scored against a software image; the ring runs tx_ring_ddr3_tb's
// stream underneath, word-exact.  The model's own density (8 Gb) so it raises no
// tRFC complaints; a refresh is then ~42 clocks rather than the Au's 23.
//////////////////////////////////////////////////////////////////////////////////
module mem_ddr3_tb;

`include "sim_defines.vh"
`ifdef den8192Mb
    `include "8192Mb_ddr3_parameters.vh"
`else
    ERROR: expected den8192Mb from sim_defines.vh
`endif

    localparam CONTROLLER_CLK_PERIOD = 10_000;  // ps
    localparam DDR3_CLK_PERIOD       =  2_500;  // ps
    localparam BYTE_LANES            = 2;
    localparam ODELAY_SUPPORTED      = 0;
    localparam AUX_WIDTH             = 4;
    localparam SDRAM_CAPACITY        = 5;       // 8 Gb, matches the model

    localparam WB_DATA_BITS = 8*BYTE_LANES*4*2;                 // 128
    localparam WB_SEL_BITS  = WB_DATA_BITS/8;                   // 16
    localparam WB_ADDR_BITS = ROW_BITS + COL_BITS + BA_BITS - 3;

    localparam integer N_WORDS = 3000;
    localparam integer CYC = 98;
    localparam integer NCYC = 1200;
    // Where the removed refresh gate's window began, kept only to report how
    // many of the controller's own refreshes now fall outside it.
    localparam integer PH_REF_LO = 30;
    // What one refresh costs a transaction it lands inside: the controller
    // holds the bus for its tRFC at SDRAM_CAPACITY 5 (8 Gb: 350 ns = 35
    // clocks), the precharge before it (tRP ~2 clocks) and the command
    // pipeline either side.  Measured ~42 clocks on this model (the header);
    // the real part's tRFC is 160 ns, so on the card the cost is ~23.
    localparam integer REF_COST   = 42;
    localparam integer DEADLINE   = 92;   // the whole transaction, no refresh (docs/PAGE_CACHE.md)
    localparam integer FIRST_MAX  = 60;   // the critical line, no refresh

    // ---- clocks and reset ------------------------------------------------
    reg i_controller_clk = 1, i_ddr3_clk = 1, i_ref_clk = 1, i_ddr3_clk_90 = 1;
    reg i_rst_n = 0;

    always #(CONTROLLER_CLK_PERIOD/2) i_controller_clk = !i_controller_clk;
    always #(DDR3_CLK_PERIOD/2)       i_ddr3_clk       = !i_ddr3_clk;
    always #2500                      i_ref_clk        = !i_ref_clk;
    initial begin
        #(DDR3_CLK_PERIOD/4);
        forever #(DDR3_CLK_PERIOD/2) i_ddr3_clk_90 = !i_ddr3_clk_90;
    end

    // ---- the CK pin's own clock, and the MMCM's fine phase shift ------------
    // CK_PHASE_SHIFT (UBERDDR3.md rung 2) gives the CK OSERDES a clock of its
    // own that the controller can walk in fine steps.  Here it is a clock like
    // the others whose phase moves by CK_PS_STEP_PS every PSEN, exactly as
    // MMCME2_ADV's fine phase shift does: one half period is lengthened or
    // shortened by the step, which IS the shift.  PSDONE comes back a dozen
    // controller clocks later, as the hardware's does.
    localparam real CK_PS_STEP_PS = 14.88;   // 1/56 of the 1200 MHz VCO period
`ifdef SW_CK_PHASE_SHIFT
    localparam CK_PHASE_SHIFT = 1;
`else
    localparam CK_PHASE_SHIFT = 0;
`endif
    reg  i_ddr3_clk_ck = 1;
    wire ck_ps_en, ck_ps_incdec;
    reg  ck_ps_done = 0;
    real ck_ps_want = 0.0, ck_ps_have = 0.0;   // the phase asked for and applied, ps
    integer ck_ps_extra = 0;
    integer ck_ps_shifts = 0;
    always begin
        ck_ps_extra = $rtoi(ck_ps_want - ck_ps_have);   // whole ps this half period
        ck_ps_have  = ck_ps_have + ck_ps_extra;
        #(DDR3_CLK_PERIOD/2 + ck_ps_extra) i_ddr3_clk_ck = !i_ddr3_clk_ck;
    end
    always @(posedge i_controller_clk) begin
        ck_ps_done <= 1'b0;
        if (ck_ps_en) begin
            ck_ps_want  = ck_ps_want + (ck_ps_incdec ? CK_PS_STEP_PS : -CK_PS_STEP_PS);
            ck_ps_shifts = ck_ps_shifts + 1;
            repeat (12) @(posedge i_controller_clk);
            ck_ps_done <= 1'b1;
        end
    end

    wire clk = i_controller_clk;
    reg  rst = 1;
    integer errors = 0;

    // ---- the port ----------------------------------------------------------
    wire                    wb_cyc, wb_stb, wb_we;
    wire [WB_ADDR_BITS-1:0] wb_addr;
    wire [WB_DATA_BITS-1:0] wb_data;
    wire [WB_SEL_BITS-1:0]  wb_sel;
    wire [AUX_WIDTH-1:0]    wb_aux;
    wire                    o_wb_stall, o_wb_ack, o_wb_err;
    wire [WB_DATA_BITS-1:0] o_wb_data;
    wire [AUX_WIDTH-1:0]    o_aux;
    wire                    o_calib_complete;

    wire [0:0] ck_en, cs_n, odt, o_ddr3_clk_p, o_ddr3_clk_n;
    wire ras_n, cas_n, we_n, reset_n;
    wire [ROW_BITS-1:0] addr;
    wire [BA_BITS-1:0]  ba_addr;
    wire [BYTE_LANES-1:0] ddr3_dm;
    wire [(8*BYTE_LANES)-1:0] dq;
    wire [BYTE_LANES-1:0] dqs, dqs_n;
    wire rot_ok, mem_idle, image_ready;

    ddr3_top #(
        .CONTROLLER_CLK_PERIOD (CONTROLLER_CLK_PERIOD),
        .DDR3_CLK_PERIOD       (DDR3_CLK_PERIOD),
        .ROW_BITS              (ROW_BITS),
        .COL_BITS              (COL_BITS),
        .BA_BITS               (BA_BITS),
        .BYTE_LANES            (BYTE_LANES),
        .AUX_WIDTH             (AUX_WIDTH),
        .MICRON_SIM            (1),
        .ODELAY_SUPPORTED      (ODELAY_SUPPORTED),
        .SECOND_WISHBONE       (0),
        .ECC_ENABLE            (0),
        .WB_ERROR              (0),
        .BIST_MODE             (0),
        .SELF_REFRESH          (0),
        .DUAL_RANK_DIMM        (0),
        .DLL_OFF               (0),
        .SPEED_BIN             (3),
        .SDRAM_CAPACITY        (SDRAM_CAPACITY),
        .CK_PHASE_SHIFT        (CK_PHASE_SHIFT)
    ) u_ddr3 (
        .i_controller_clk (i_controller_clk),
        .i_ddr3_clk       (i_ddr3_clk),
        .i_ref_clk        (i_ref_clk),
        .i_ddr3_clk_90    (i_ddr3_clk_90),
        .i_ddr3_clk_ck    (i_ddr3_clk_ck),
        .o_ck_ps_en       (ck_ps_en),
        .o_ck_ps_incdec   (ck_ps_incdec),
        .i_ck_ps_done     (ck_ps_done),
        .i_rst_n          (i_rst_n),
        .i_wb_cyc  (wb_cyc),
        .i_wb_stb  (wb_stb),
        .i_wb_we   (wb_we),
        .i_wb_addr (wb_addr),
        .i_wb_data (wb_data),
        .i_wb_sel  (wb_sel),
        .i_aux     (wb_aux),
        .o_wb_stall(o_wb_stall),
        .o_wb_ack  (o_wb_ack),
        .o_wb_err  (o_wb_err),
        .o_wb_data (o_wb_data),
        .o_aux     (o_aux),
        .i_wb2_cyc (1'b0), .i_wb2_stb (1'b0), .i_wb2_we (1'b0),
        .i_wb2_addr(7'b0), .i_wb2_data(32'b0), .i_wb2_sel(4'b0),
        .o_wb2_stall(), .o_wb2_ack(), .o_wb2_data(),
        .o_ddr3_clk_p  (o_ddr3_clk_p),
        .o_ddr3_clk_n  (o_ddr3_clk_n),
        .o_ddr3_cke    (ck_en),
        .o_ddr3_cs_n   (cs_n),
        .o_ddr3_odt    (odt),
        .o_ddr3_ras_n  (ras_n),
        .o_ddr3_cas_n  (cas_n),
        .o_ddr3_we_n   (we_n),
        .o_ddr3_reset_n(reset_n),
        .o_ddr3_addr   (addr),
        .o_ddr3_ba_addr(ba_addr),
        .io_ddr3_dq    (dq),
        .io_ddr3_dqs   (dqs),
        .io_ddr3_dqs_n (dqs_n),
        .o_ddr3_dm     (ddr3_dm),
        .o_calib_complete   (o_calib_complete),
        .o_debug1           (),
        .i_user_self_refresh(1'b0),
        .uart_tx            ()
    );

    ddr3 #(.DLL_OFF(0)) ddr3_dev (
        .rst_n  (reset_n),
        .ck     (o_ddr3_clk_p[0]),
        .ck_n   (o_ddr3_clk_n[0]),
        .cke    (ck_en[0]),
        .cs_n   (cs_n[0]),
        .ras_n  (ras_n),
        .cas_n  (cas_n),
        .we_n   (we_n),
        .dm_tdqs(ddr3_dm),
        .ba     (ba_addr),
        .addr   (addr),
        .dq     (dq),
        .dqs    (dqs),
        .dqs_n  (dqs_n),
        .tdqs_n (),
        .odt    (odt[0])
    );

    // ---- the arbiter: the ring's two clients and the memory's --------------
    wire [2:0]   c_req, c_gnt, c_cyc, c_stb, c_we, c_stall, c_ack;
    wire [3*WB_ADDR_BITS-1:0] c_addr;
    wire [383:0] c_data;
    wire [47:0]  c_sel;
    wire [127:0] c_rdata;
    wire [31:0]  status;

    wb_arb #(.N (3), .ADDR_BITS (WB_ADDR_BITS), .HAS_PRIO (1'b1)) u_arb (
        .clk (clk), .rst (rst), .rot_ok (rot_ok),
        .c_req (c_req), .c_gnt (c_gnt), .c_cyc (c_cyc), .c_stb (c_stb),
        .c_we (c_we), .c_addr (c_addr), .c_data (c_data),
        .c_sel (c_sel),
        .c_stall (c_stall), .c_ack (c_ack), .c_rdata (c_rdata),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_addr (wb_addr), .wb_data (wb_data), .wb_sel (wb_sel),
        .wb_aux (wb_aux), .wb_stall (o_wb_stall), .wb_ack (o_wb_ack),
        .wb_rdata (o_wb_data), .wb_rdata_aux (o_aux)
    );
    assign c_we[1:0] = 2'b10;
    assign c_data[127:0] = 128'd0;
    assign c_sel[31:0] = {16'hFFFF, 16'hFFFF};

    // ---- the ring, as tx_ring_ddr3_tb runs it -----------------------------------
    reg [31:0] stream [0:N_WORDS+300];
    integer    total = 0;
    integer    si = 0;
    reg        gate = 1'b0;
    wire       in_valid = (si < total) && gate;
    wire [31:0] in_word = in_valid ? stream[si] : 32'hDEAD_BEEF;
    wire       in_take;
    wire        m_cyc, m_stb, m_we, m_stall, m_ack;
    wire [31:0] m_adr, m_dat;
    wire [3:0]  m_sel;
    msg_master u_m (
        .clk (clk), .rst (rst), .word (in_word), .valid (in_valid), .take (in_take),
        .cyc (m_cyc), .stb (m_stb), .we (m_we), .adr (m_adr), .dat (m_dat), .sel (m_sel),
        .stall (m_stall), .ack (m_ack)
    );
    reg        out_take = 1'b0;
    wire [31:0] out_word;
    wire       out_valid;

    tx_ring #(.ADDR_BITS (WB_ADDR_BITS), .BATCH (32)) u_ring (
        .clk (clk), .rst (rst), .calib_complete (o_calib_complete),
        .s_cyc (m_cyc), .s_stb (m_stb), .s_we (m_we), .s_adr (m_adr),
        .s_dat (m_dat), .s_sel (m_sel), .s_stall (m_stall), .s_ack (m_ack),
        .out_word (out_word), .out_valid (out_valid), .out_take (out_take),
        .rd_req (c_req[0]), .rd_gnt (c_gnt[0]), .rd_cyc (c_cyc[0]),
        .rd_stb (c_stb[0]), .rd_addr (c_addr[WB_ADDR_BITS-1:0]),
        .rd_stall (c_stall[0]), .rd_ack (c_ack[0]), .rd_data (c_rdata),
        .wr_req (c_req[1]), .wr_gnt (c_gnt[1]), .wr_cyc (c_cyc[1]),
        .wr_stb (c_stb[1]), .wr_addr (c_addr[2*WB_ADDR_BITS-1:WB_ADDR_BITS]),
        .wr_data (c_data[255:128]),
        .wr_stall (c_stall[1]), .wr_ack (c_ack[1]),
        .status (status)
    );

    task gen_stream;
        integer m, k, len, t;
        begin
            m = 0;
            while (total < N_WORDS) begin
                case ($urandom % 4)
                    0:       len = 255;
                    1:       len = $urandom % 256;
                    2:       len = 0;
                    default: len = $urandom % 8;
                endcase
                t = 32 + (m % 7);
                stream[total] = {m[15:0], t[7:0], len[7:0]};
                total = total + 1;
                for (k = 0; k < len; k = k + 1) begin
                    stream[total] = {4'h1, m[15:0], k[11:0]};
                    total = total + 1;
                end
                m = m + 1;
            end
        end
    endtask

    integer ei = 0, left = 0, out_n = 0, pads = 0, errs_seen = 0;
    always @(posedge clk) begin
        if (o_wb_err) errs_seen = errs_seen + 1;
        if (!rst && out_valid && out_take) begin
            out_n = out_n + 1;
            if (out_word == 32'h0000_0000) begin
                pads = pads + 1;
                if (left != 0) begin
                    $display("FAIL: padding inside a message, word %0d", out_n);
                    errors = errors + 1;
                end
            end else begin
                if (out_word !== stream[ei]) begin
                    if (errors < 10)
                        $display("FAIL: out word %0d = %08x, expected stream[%0d] = %08x",
                                 out_n, out_word, ei, stream[ei]);
                    errors = errors + 1;
                end
                if (left == 0) left = out_word[7:0];
                else           left = left - 1;
                ei = ei + 1;
            end
        end
    end
    always @(posedge clk) if (in_valid && in_take) si <= si + 1;

    // ---- the page client, driven as the page engine drives it ------------------
    // Two banks of eight pages: the whole space this run touches, written
    // before it is read (nothing clears the DDR3; an unwritten line is X in
    // the model).
    localparam integer NPG = 8;
    reg         op_present = 1'b0, master_active = 1'b0;
    reg         pq_busy_r = 1'b0, pq_valid_r = 1'b0, pq_we_r = 1'b0;
    reg  [19:0] pq_line_r = 20'd0;
    reg  [127:0] pq_wdata_r = 128'd0;
    wire        pq_ready, pr_valid;
    wire [127:0] pr_data;

    page_client u_mem (
        .clk (clk), .rst (rst), .calib_complete (o_calib_complete),
        .master_active (master_active), .op_present (op_present),
        .pq_busy (pq_busy_r), .pq_valid (pq_valid_r), .pq_we (pq_we_r),
        .pq_line (pq_line_r), .pq_wdata (pq_wdata_r), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .req (c_req[2]), .gnt (c_gnt[2]), .cyc (c_cyc[2]), .stb (c_stb[2]),
        .we (c_we[2]), .addr (c_addr[3*WB_ADDR_BITS-1:2*WB_ADDR_BITS]),
        .data (c_data[383:256]), .sel (c_sel[47:32]),
        .stall (c_stall[2]), .ack (c_ack[2]), .rdata (c_rdata),
        .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

    // A beat is accepted at the posedge where pq_valid met pq_ready; the
    // driver advances at the negedge after, exactly as the engine's registered
    // stream does.
    reg acc_q = 1'b0;
    always @(posedge clk) acc_q <= pq_valid_r && pq_ready;

    // The software image: 2 banks x NPG pages.
    reg [7:0]  img [0:2*NPG*256-1];
    reg [7:0]  img_prev [0:2*NPG*256-1];        // what each byte held before its latest write
    time       wr_t0 [0:2*NPG-1], wr_t1 [0:2*NPG-1];  // when each page's latest write burst was issued (first/last beat)
    time       ref_t [0:2];                     // the last three refreshes
    function automatic integer img_ix(input [7:0] bank, input [7:0] page,
                                      input [3:0] line, input integer b);
        img_ix = {bank[0], page[2:0], line, 4'(b)};
    endfunction

    // Read-burst scoring: responses arrive in request order, critical-first.
    integer    fill_bad = 0, resp_n = 0;
    reg  [7:0] r_bank = 0, r_page = 0;
    reg  [3:0] r_crit = 0;
    reg        r_score = 1'b0;
    integer    phase = 0;
    integer    t_start = 0, lat_first = 0, lat1_sum = 0, lat1_max = 0, xacts = 0;
    integer    refs_at_start = 0;
    // The worst cases kept apart: transactions no refresh touched, and those
    // one landed inside (the critical line and the whole transaction).
    integer    lat1_max_ref = 0, tot_max_ref = 0, xacts_ref = 0, tot_t_ref = 0;
    integer    k;
    reg [3:0]  r_idx;
    always @(posedge clk) begin
        if (op_present) phase <= 0; else phase <= phase + 1;
        if (pr_valid && r_score) begin
            r_idx = r_crit + 4'(resp_n);
            for (k = 0; k < 16; k = k + 1)
                if (pr_data[8*k +: 8] !== img[img_ix(r_bank, r_page, r_idx, k)]) begin
                    fill_bad = fill_bad + 1;
                    // The first few, with what the byte held before its latest write
                    // and when that write went out against the last refreshes: a
                    // "got = prev" line is a write that never landed.
                    if (fill_bad <= 4 || (k == 0 && fill_bad <= 64)) $display("    MISMATCH t=%0t phase=%0d bank=%0d page=%0d line=%0d byte=%0d got=%02x exp=%02x prev=%02x refreshes in this xact %0d; page written %0t..%0t, last refreshes %0t %0t %0t",
                        $time, phase, r_bank, r_page, r_idx, k, pr_data[8*k +: 8], img[img_ix(r_bank, r_page, r_idx, k)], img_prev[img_ix(r_bank, r_page, r_idx, k)], refs - refs_at_start,
                        wr_t0[{r_bank[0], r_page[2:0]}], wr_t1[{r_bank[0], r_page[2:0]}], ref_t[0], ref_t[1], ref_t[2]);
                end
            if (resp_n == 0) begin
                lat_first = phase - t_start;
                lat1_sum  = lat1_sum + lat_first;
                if (refs != refs_at_start) begin
                    if (lat_first > lat1_max_ref) lat1_max_ref = lat_first;
                end else begin
                    if (lat_first > lat1_max) lat1_max = lat_first;
                end
                xacts = xacts + 1;
            end
            resp_n = resp_n + 1;
        end
    end

    // Sixteen pipelined beats: reads of {bank,page} critical-first, or writes
    // of fresh random data (the image updated as each beat is issued - the
    // controller performs accepted requests in order, so a read behind them
    // sees them).
    task beats(input we, input [7:0] bank, input [7:0] page, input [3:0] first);
        integer n, b;
        reg [3:0] idx;
        reg [127:0] w;
        begin
            n = 0; idx = first;
            if (!we) begin
                r_bank = bank; r_page = page; r_crit = first;
                resp_n = 0; r_score = 1'b1; t_start = phase; refs_at_start = refs;
            end
            pq_we_r <= we;
            pq_line_r <= {bank, page, idx};
            if (we) begin
                wr_t0[{bank[0], page[2:0]}] = $time;
                for (b = 0; b < 16; b = b + 1) begin
                    w[8*b +: 8] = 8'($urandom);
                    img_prev[img_ix(bank, page, idx, b)] = img[img_ix(bank, page, idx, b)];
                    img[img_ix(bank, page, idx, b)] = w[8*b +: 8];
                end
                pq_wdata_r <= w;
            end
            pq_valid_r <= 1'b1;
            while (n < 16) begin
                @(negedge clk);
                if (acc_q) begin
                    n = n + 1;
                    idx = first + 4'(n);
                    if (n < 16) begin
                        pq_line_r <= {bank, page, idx};
                        if (we) begin
                            wr_t1[{bank[0], page[2:0]}] = $time;
                            for (b = 0; b < 16; b = b + 1) begin
                                w[8*b +: 8] = 8'($urandom);
                                img_prev[img_ix(bank, page, idx, b)] = img[img_ix(bank, page, idx, b)];
                                img[img_ix(bank, page, idx, b)] = w[8*b +: 8];
                            end
                            pq_wdata_r <= w;
                        end
                    end else begin
                        pq_valid_r <= 1'b0;
                    end
                end
            end
        end
    endtask

    // Wait for a read burst's sixteen responses.
    task drain_reads;
        begin
            while (resp_n < 16) @(negedge clk);
            r_score = 1'b0;
        end
    endtask

    // Refreshes on the DDR3 command bus, and where in the bus cycle they fell.
    integer refs = 0, refs_outside = 0, refs_timed = 0;
    always @(posedge o_ddr3_clk_p[0]) begin
        if (ck_en[0] && !cs_n[0] && !ras_n && !cas_n && we_n) begin
            refs = refs + 1;
            ref_t[2] = ref_t[1]; ref_t[1] = ref_t[0]; ref_t[0] = $time;
            if (master_active) begin
                refs_timed = refs_timed + 1;
                if (phase < PH_REF_LO || phase > 95) begin
                    refs_outside = refs_outside + 1;
                    if (refs_outside <= 5) $display("    refresh at phase %0d", phase);
                end
            end
        end
    end

    // ---- stimulus ---------------------------------------------------------------
    integer c, n, r, pg, bk, tot_max = 0, tot_t = 0;
    initial begin
        $display("mem_ddr3_tb: the page client on UberDDR3, the ring streaming beside it");
        gen_stream;

        i_rst_n = 0;
        repeat (10) @(posedge clk);
        i_rst_n = 1;
        rst = 0;
        $display("  waiting for calibration...");
        wait (o_calib_complete === 1'b1);
        $display("  calibrated at %0t", $time);
        if (!image_ready) begin $display("FAIL: image_ready did not follow calibration"); errors = errors + 1; end
        // Nothing clears the DDR3, so write every page the run will read
        // before reading any: a fill of an unwritten line is X in the model.
        master_active = 1'b1;
        for (n = 0; n < 2 * NPG; n = n + 1) begin
            @(negedge clk); op_present <= 1'b1; @(negedge clk); op_present <= 1'b0;
            pq_busy_r <= 1'b1;
            beats(1'b1, 8'(n / NPG), 8'(n % NPG), 4'd0);
            pq_busy_r <= 1'b0;
            repeat (60) @(negedge clk);
        end
        repeat (200) @(negedge clk);

        // ---- 1. a page written and fetched right behind it comes back written --
        gate = 1'b1; out_take = 1'b1;
        @(negedge clk); op_present <= 1'b1; @(negedge clk); op_present <= 1'b0;
        pq_busy_r <= 1'b1;
        beats(1'b1, 8'd0, 8'd3, 4'd0);
        beats(1'b0, 8'd0, 8'd3, 4'd5);
        drain_reads;
        pq_busy_r <= 1'b0;
        while (phase < CYC - 2) @(negedge clk);
        if (fill_bad != 0) begin
            $display("FAIL: write-then-fill: %0d bad bytes", fill_bad);
            errors = errors + 1;
        end else $display("  ok: a page written and fetched right behind it comes back written");

        // ---- 2. random cycles: the engine's shape, batches beneath ----------------
        // Most cycles carry a miss transaction - a sixteen-beat fill,
        // critical-first, then the victim's sixteen-beat flush behind it,
        // exactly as rtl/page_cache.sv drives it - and the whole thing must
        // be over well inside the bus cycle.
        for (n = 0; n < NCYC; n = n + 1) begin
            @(negedge clk); op_present <= 1'b1; @(negedge clk); op_present <= 1'b0;
            r = $urandom % 100;
            if (r < 70) begin
                repeat (4) @(negedge clk);        // the decision's clocks
                pq_busy_r <= 1'b1;
                bk = $urandom % 2; pg = $urandom % NPG;
                beats(1'b0, 8'(bk), 8'(pg), 4'($urandom));
                drain_reads;
                if (r < 42)                       // a dirty victim: flush behind
                    beats(1'b1, 8'(1 - bk), 8'(pg), 4'd0);
                pq_busy_r <= 1'b0;
                if (refs != refs_at_start) begin
                    xacts_ref = xacts_ref + 1;
                    if (phase > tot_max_ref) tot_max_ref = phase;
                    if (phase > DEADLINE + (refs - refs_at_start) * REF_COST) begin
                        tot_t_ref = tot_t_ref + 1;
                        if (tot_t_ref <= 4) $display("    LATE with refresh: xact %0d ended at phase %0d, %s, %0d refresh(es) inside", n, phase, (r < 42) ? "fill+flush" : "fill only", refs - refs_at_start);
                    end
                end else begin
                    if (phase > tot_max) tot_max = phase;
                    if (phase > DEADLINE) begin
                        tot_t = tot_t + 1;
                        if (tot_t <= 4) $display("    LATE: xact %0d ended at phase %0d, %s, no refresh", n, phase, (r < 42) ? "fill+flush" : "fill only");
                    end
                end
            end
            gate     = ($urandom % 100) < 70;
            out_take = ($urandom % 100) < 60;
            while (phase < CYC - 2) @(negedge clk);
        end
        $display("  %0d transactions: first line mean %0d clocks after the burst began; no refresh: first line max %0d, whole max %0d; a refresh inside (%0d of them): first line max %0d, whole max %0d (allowed %0d + %0d a refresh)",
                 xacts, lat1_sum / (xacts > 0 ? xacts : 1), lat1_max, tot_max, xacts_ref, lat1_max_ref, tot_max_ref, DEADLINE, REF_COST);
        if (fill_bad != 0) begin $display("FAIL: %0d fill bytes differ from the image", fill_bad); errors = errors + 1; end
        else $display("  ok: every fill matches the image, critical-first, through the flushes");
        if (lat1_max > FIRST_MAX || tot_t != 0) begin
            $display("FAIL: without a refresh, first line max %0d, %0d transactions past clock %0d", lat1_max, tot_t, DEADLINE);
            errors = errors + 1;
        end else $display("  ok: every refresh-free transaction inside its bus cycle, the critical line %0d clocks at worst", lat1_max);
        if (lat1_max_ref > FIRST_MAX + REF_COST || tot_t_ref != 0) begin
            $display("FAIL: with a refresh inside, first line max %0d, %0d transactions past their refresh-extended deadline", lat1_max_ref, tot_t_ref);
            errors = errors + 1;
        end else $display("  ok: every refresh-hit transaction inside its extended deadline, the critical line %0d clocks at worst", lat1_max_ref);
        // Refresh is the controller's own timer: it lands wherever tREFI
        // expires, and the check is only that it keeps happening (the gate
        // that held it to the idle tail was removed 2026-09-14).
        if (refs_timed == 0) begin
            $display("FAIL: no refreshes over %0d cycles", NCYC); errors = errors + 1;
        end else $display("  ok: %0d refreshes on the controller's own timer, %0d of them outside the old idle-tail window", refs_timed, refs_outside);
        master_active = 1'b0;

        // ---- 3. drain the ring's stream ---------------------------------------------
        gate = 1'b1; out_take = 1'b1;
        c = 0;
        while ((ei < total || status[21:0] != 0 || out_valid) && c < 200000) begin
            @(negedge clk);
            c = c + 1;
        end
        if (ei != total) begin
            $display("FAIL: %0d of %0d ring words delivered", ei, total);
            errors = errors + 1;
        end else $display("  ok: %0d ring words word-exact through the DDR3 under the fills", total);
        if (errs_seen != 0) begin
            $display("FAIL: the controller raised o_wb_err %0d time(s)", errs_seen);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
