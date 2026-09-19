`timescale 1ps / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// tx_ring_ddr3_tb - the ring and its arbiter against the real UberDDR3 and the
// Micron DDR3 model, at the strudelworks clock configuration.
//
// tx_ring_tb proves the ring against a memory that keeps the controller's
// rules; this proves the rules were the right ones.  The same stream check,
// word for word with padding allowed only at boundaries, after waiting out
// calibration.  Nothing about refresh is measured here - latency_tb does that
// - so the model's own density is used and it raises no tRFC complaints.
//
// The harness - clocks, controller parameters, device hookup - is latency_tb's.
//////////////////////////////////////////////////////////////////////////////////
module tx_ring_ddr3_tb;

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

    localparam integer N_WORDS = 6000;

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
        .SDRAM_CAPACITY        (SDRAM_CAPACITY)
    ) u_ddr3 (
        .i_controller_clk (i_controller_clk),
        .i_ddr3_clk       (i_ddr3_clk),
        .i_ref_clk        (i_ref_clk),
        .i_ddr3_clk_90    (i_ddr3_clk_90),
        .i_ddr3_clk_ck    (i_ddr3_clk),   // CK_PHASE_SHIFT off: CK on the same clock as ever
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

    // ---- the ring and its arbiter -------------------------------------------
    wire [1:0]   c_req, c_gnt, c_cyc, c_stb, c_stall, c_ack;
    wire [1:0]   c_we = 2'b10;
    wire [2*WB_ADDR_BITS-1:0] c_addr;
    wire [255:0] c_data;
    wire [127:0] c_rdata;
    wire [31:0]  status;

    wb_arb #(.N (2), .ADDR_BITS (WB_ADDR_BITS)) u_arb (
        .clk (clk), .rst (rst), .rot_ok (1'b1),
        .c_req (c_req), .c_gnt (c_gnt), .c_cyc (c_cyc), .c_stb (c_stb),
        .c_we (c_we), .c_addr (c_addr), .c_data (c_data),
        .c_sel ({16'hFFFF, 16'hFFFF}),
        .c_stall (c_stall), .c_ack (c_ack), .c_rdata (c_rdata),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_addr (wb_addr), .wb_data (wb_data), .wb_sel (wb_sel),
        .wb_aux (wb_aux), .wb_stall (o_wb_stall), .wb_ack (o_wb_ack),
        .wb_rdata (o_wb_data), .wb_rdata_aux (o_aux)
    );
    assign c_data[127:0] = 128'd0;

    // The stream source and sink.
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

    tx_ring #(.ADDR_BITS (WB_ADDR_BITS)) dut (
        .clk (clk), .rst (rst), .calib_complete (o_calib_complete), .engage (1'b1),
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

    // ---- the checker ----------------------------------------------------------
    integer ei = 0, left = 0, out_n = 0, pads = 0, errs_seen = 0;
    always @(posedge clk) begin
        if (o_wb_err) begin
            errs_seen = errs_seen + 1;
        end
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

    // ---- stimulus ---------------------------------------------------------------
    integer c;
    initial begin
        $display("tx_ring_ddr3_tb: the ring on UberDDR3, %0d-bit addresses", WB_ADDR_BITS);
        gen_stream;
        $display("  %0d words in the stream", total);

        i_rst_n = 0;
        repeat (10) @(posedge clk);
        i_rst_n = 1;
        rst = 0;
        $display("  waiting for calibration...");
        wait (o_calib_complete === 1'b1);
        $display("  calibrated at %0t", $time);

        // Random gaps and back pressure, then everything open.
        c = 0;
        while (si < 4000 && c < 400000) begin
            @(negedge clk);
            c = c + 1;
            gate     = ($urandom % 100) < 70;
            out_take = ($urandom % 100) < 60;
        end
        // Then sparse traffic, so message tails wait out the flush and the
        // padded lines go through the real controller too.
        // One word every 150 cycles: every message tail waits out the flush.
        c = 0;
        while (ei < 4300 && c < 400000) begin
            @(negedge clk);
            c = c + 1;
            gate     = (c % 150) == 0;
            out_take = 1'b1;
        end
        if (pads == 0) begin
            $display("FAIL: sparse traffic produced no padding");
            errors = errors + 1;
        end
        gate = 1'b1; out_take = 1'b1;
        c = 0;
        while ((ei < total || status[21:0] != 0 || out_valid) && c < 100000) begin
            @(negedge clk);
            c = c + 1;
        end

        if (ei != total) begin
            $display("FAIL: %0d of %0d words delivered", ei, total);
            errors = errors + 1;
        end else $display("  ok: %0d words word-exact through the DDR3, %0d padding words", total, pads);
        if (status[21:0] != 0) begin
            $display("FAIL: ring not empty at the end (status %08x)", status);
            errors = errors + 1;
        end
        if (errs_seen != 0) begin
            $display("FAIL: the controller raised o_wb_err %0d time(s)", errs_seen);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
