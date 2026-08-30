`timescale 1ps / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mem_ddr3_tb - the memory client in wb_arb's priority slot against the real
// UberDDR3 and the Micron model, with the TX ring streaming beside it.
//
// mem_cache_tb proves the cache against a memory that keeps the controller's
// rules; this proves the rules hold on the controller itself, for the three
// things only it can show:
//
//   - a byte written and the line fetched right behind it come back written,
//     because accepted requests are performed in order;
//   - a fill's answer arrives inside the bus cycle even when it pre-empts a
//     ring batch mid-flight - the number the whole realtime budget rests on;
//   - refreshes land only where refresh_ok put them: in the idle tail of a
//     bus cycle, never in front of a fill.
//
// Ops arrive as the cache would send them, one per 98-clock bus cycle,
// scored against a software image; the ring runs tx_ring_ddr3_tb's stream
// underneath, word-exact.  The model's own density (8 Gb) so it raises no
// tRFC complaints; a refresh is then ~42 clocks rather than the Au's 23, which
// only makes the window check stricter.
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
    localparam integer PH_REF_LO = 30, PH_REF_HI = 60;

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
    wire refresh_ok, rot_ok, mem_idle, image_ready;

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
        .REFRESH_GATE          (1)
    ) u_ddr3 (
        .i_controller_clk (i_controller_clk),
        .i_ddr3_clk       (i_ddr3_clk),
        .i_ref_clk        (i_ref_clk),
        .i_ddr3_clk_90    (i_ddr3_clk_90),
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
        .i_refresh_ok       (refresh_ok),
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

    // ---- the memory client, driven as the cache would ------------------------------
    reg         op_present = 1'b0, master_active = 1'b0;
    reg         mq_valid = 1'b0, mq_kind = 1'b0;
    reg  [1:0]  mq_id = 2'd0;
    reg  [19:0] mq_line = 20'd0;
    reg  [3:0]  mq_byte = 4'd0;
    reg  [7:0]  mq_data = 8'd0;
    wire        mq_ready, mr_valid;
    wire [1:0]  mr_id;
    wire [127:0] mr_data;

    mem_client #(.PH_REF_LO (PH_REF_LO), .PH_REF_HI (PH_REF_HI)) u_mem (
        .clk (clk), .rst (rst), .calib_complete (o_calib_complete),
        .master_active (master_active), .op_present (op_present),
        .accel (1'b0),
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id), .mq_line (mq_line),
        .mq_byte (mq_byte), .mq_data (mq_data), .mq_ready (mq_ready),
        .dq_valid (1'b0), .dq_line (20'd0), .dq_be (16'd0), .dq_data (128'd0), .dq_ready (),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data),
        .req (c_req[2]), .gnt (c_gnt[2]), .cyc (c_cyc[2]), .stb (c_stb[2]),
        .we (c_we[2]), .addr (c_addr[3*WB_ADDR_BITS-1:2*WB_ADDR_BITS]),
        .data (c_data[383:256]), .sel (c_sel[47:32]),
        .stall (c_stall[2]), .ack (c_ack[2]), .rdata (c_rdata),
        .refresh_ok (refresh_ok), .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

    // The software image: the first 256 lines, written before they are read.
    localparam integer NL = 256;
    reg [7:0]  img [0:NL*16-1];
    integer    fills = 0, fill_bad = 0, fill_max = 0, fill_late = 0, fill_sum = 0;
    integer    fill_t0 = 0, fill_pending = 0;
    reg  [1:0] fill_id_exp = 2'd0;
    integer    fill_line = 0;
    integer    phase = 0;
    integer    k;
    always @(posedge clk) begin
        if (op_present) phase <= 0; else phase <= phase + 1;
        if (mr_valid) begin
            if (!fill_pending || mr_id !== fill_id_exp) begin
                $display("FAIL: an unexpected fill (id %0d)", mr_id); errors = errors + 1;
            end else begin
                fills = fills + 1;
                fill_pending = 0;
                if (phase - fill_t0 > fill_max) fill_max = phase - fill_t0;
                fill_sum = fill_sum + (phase - fill_t0);
                if (phase > 90) fill_late = fill_late + 1;
                for (k = 0; k < 16; k = k + 1)
                    if (mr_data[8*k +: 8] !== img[fill_line*16 + k]) fill_bad = fill_bad + 1;
            end
        end
    end

    // Refreshes on the DDR3 command bus, and where in the bus cycle they fell.
    integer refs = 0, refs_outside = 0, refs_timed = 0;
    always @(posedge o_ddr3_clk_p[0]) begin
        if (ck_en[0] && !cs_n[0] && !ras_n && !cas_n && we_n) begin
            refs = refs + 1;
            if (master_active) begin
                refs_timed = refs_timed + 1;
                if (phase < PH_REF_LO || phase > 95) begin
                    refs_outside = refs_outside + 1;
                    if (refs_outside <= 5) $display("    refresh at phase %0d", phase);
                end
            end
        end
    end

    task push(input kind, input [19:0] line, input [3:0] b, input [7:0] d);
        begin
            @(negedge clk);
            while (!mq_ready) @(negedge clk);
            mq_valid <= 1'b1; mq_kind <= kind; mq_line <= line; mq_byte <= b; mq_data <= d;
            if (kind) begin
                mq_id <= fill_id_exp + 2'd1; fill_id_exp = fill_id_exp + 2'd1;
                fill_pending = 1; fill_t0 = phase + 1; fill_line = line;
            end else begin
                img[line*16 + b] = d;
            end
            @(negedge clk);
            mq_valid <= 1'b0;
        end
    endtask

    // ---- stimulus ---------------------------------------------------------------
    integer c, n, r, line, b;
    initial begin
        $display("mem_ddr3_tb: the memory client on UberDDR3, the ring streaming beside it");
        gen_stream;
        for (n = 0; n < NL*16; n = n + 1) img[n] = 8'h00;

        i_rst_n = 0;
        repeat (10) @(posedge clk);
        i_rst_n = 1;
        rst = 0;
        $display("  waiting for calibration...");
        wait (o_calib_complete === 1'b1);
        $display("  calibrated at %0t", $time);
        if (!image_ready) begin $display("FAIL: image_ready did not follow calibration"); errors = errors + 1; end
        // Nothing clears the DDR3, so write every line the run will read before
        // reading any: a fill of an unwritten line is X in the model.
        master_active = 1'b1;
        for (n = 0; n < NL; n = n + 1) begin
            @(negedge clk); op_present <= 1'b1; @(negedge clk); op_present <= 1'b0;
            for (b = 0; b < 16; b = b + 1) push(1'b0, n[19:0], b[3:0], 8'h00);
            repeat (40) @(negedge clk);
        end
        repeat (200) @(negedge clk);

        // ---- 1. a write, then its line: the order holds ------------------------
        gate = 1'b1; out_take = 1'b1;
        @(negedge clk); op_present <= 1'b1; @(negedge clk); op_present <= 1'b0;
        push(1'b0, 20'd17, 4'd5, 8'hA7);
        push(1'b1, 20'd17, 4'd5, 8'h00);
        repeat (CYC - 6) @(negedge clk);
        if (fills != 1 || fill_bad != 0) begin
            $display("FAIL: write-then-fill: %0d fills, %0d bad bytes", fills, fill_bad);
            errors = errors + 1;
        end else $display("  ok: a byte written and its line fetched right behind it come back written");

        // ---- 2. random cycles: writes and fills against the image, batches beneath --
        for (n = 0; n < NCYC; n = n + 1) begin
            @(negedge clk); op_present <= 1'b1; @(negedge clk); op_present <= 1'b0;
            r = $urandom % 100;
            line = (r < 70) ? ($urandom % 8) : ($urandom % NL);
            b = $urandom % 16;
            if (r < 45)      push(1'b0, line[19:0], b[3:0], 8'($urandom));
            else if (r < 85) push(1'b1, line[19:0], b[3:0], 8'h00);
            gate     = ($urandom % 100) < 70;
            out_take = ($urandom % 100) < 60;
            repeat (CYC - 4) @(negedge clk);
        end
        $display("  %0d fills: mean %0d clocks from request to line, max %0d",
                 fills, fill_sum / (fills > 0 ? fills : 1), fill_max);
        if (fill_bad != 0) begin $display("FAIL: %0d fill bytes differ from the image", fill_bad); errors = errors + 1; end
        else $display("  ok: every fill matches the image");
        if (fill_late != 0 || fill_max > 80) begin
            $display("FAIL: %0d fills after clock 90, max %0d", fill_late, fill_max); errors = errors + 1;
        end else $display("  ok: every fill landed inside its bus cycle, %0d clocks at worst", fill_max);
        if (refs_timed < NCYC / 12) begin
            $display("FAIL: only %0d refreshes over %0d cycles", refs_timed, NCYC); errors = errors + 1;
        end else if (refs_outside != 0) begin
            $display("FAIL: %0d of %0d refreshes outside the window", refs_outside, refs_timed); errors = errors + 1;
        end else $display("  ok: %0d refreshes, every one inside the cycle's idle tail", refs_timed);
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
