`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_top - FT601 link bring-up.  NO DDR3, no Apple bus.
//
// Streams a 32-bit incrementing counter at the host as fast as the FT601 will
// take it, and discards anything the host sends back.  A counter rather than a
// constant, because it makes both failure modes visible from the host:
//
//   tools/ft601/ft601_probe bench --sweep   measures how fast it arrives
//   a gap in the sequence                   proves words were dropped
//   a repeat                                proves words were duplicated
//
// Throughput alone certifies nothing - every broken revision of this design still
// ran at 335 MB/s while corrupting data.  The sequence check is what distinguishes
// a working link from a fast broken one.
//
// STRUCTURE follows ufrisk/pcileech-fpga.  This module is the equivalent of their
// pcileech_com.sv: it owns the clock-domain crossing and hands the FT601
// controller a plain din/dout interface in the FT601's own clock domain.  The
// controller (ft601_fifo.sv) contains no FIFO and no CDC.
//
// RESET, also theirs (pcileech_squirrel_top.sv):
//
//   assign rst = ~user_sw2_n || ((tickcount64 < 64) ? 1'b1 : 1'b0);
//   assign ft601_rst_n = ~rst;
//
// A power-on tick counter and a button - here, a tick counter and the host's 'R'
// command.  No clock-presence gating, no lock signal, no watchdog.  The same
// reset drives the FT601's RESET# pin, so chip and fabric leave reset together.
//
// The async FIFOs need their far clock alive to complete their own reset, and
// that is handled the way the reference handles it - see fifo_rst - not by making
// the design's reset depend on the clock.
//
//   led[0]     clk_gen locked
//   led[1]     TX activity, stretched to be visible
//   led[2]     heartbeat, ~1 Hz - the user domain is running
//   led[3]     RX activity, sticky once the host has ever sent us anything
//   led[7:4]   bits 27:24 of the words-sent counter - a coarse rate display
//////////////////////////////////////////////////////////////////////////////////

module ft601_top (
    input  wire        clk_pin,
    input  wire        rst_n,
    output wire [7:0]  led,
    input  wire        usb_rx,
    output wire        usb_tx,

    // FT601 (constr/ft601.xdc)
    input  wire        ft_clk,
    input  wire        ft_rxf,
    input  wire        ft_txe,
    output wire        ft_rd,
    output wire        ft_wr,
    output wire        ft_oe,
    output wire        ft_wakeup,
    output wire        ft_reset,
    inout  wire [31:0] ft_data,
    inout  wire [3:0]  ft_be
);

    // ---- clocks -----------------------------------------------------------
    wire clk_ctrl, clk_ddr3_unused, clk_ddr3_90_unused, clk_ref_unused;
    wire clk_locked;

    clk_gen u_clk (
        .clk_in      (clk_pin),
        .rst         (~rst_n),
        .clk_ctrl    (clk_ctrl),
        .clk_ddr3    (clk_ddr3_unused),
        .clk_ddr3_90 (clk_ddr3_90_unused),
        .clk_ref     (clk_ref_unused),
        .locked      (clk_locked)
    );

    wire ft_clk_i;
    ft_clk_buf u_ft_clk (.ft_clk_pin(ft_clk), .ft_clk(ft_clk_i));

    // ---- reset ------------------------------------------------------------
    localparam integer RST_TICKS = 64;

    wire      cmd_reset;
    reg [7:0] tickcount = 8'd0;

    always @(posedge clk_ctrl) begin
        if (!clk_locked)                tickcount <= 8'd0;
        else if (tickcount < RST_TICKS) tickcount <= tickcount + 8'd1;
    end

    wire rst = ~clk_locked | (tickcount < RST_TICKS) | cmd_reset;

    // The chip's RESET# from the same signal, as the reference does.
    assign ft_reset = ~rst;

    // Async-FIFO reset, qualified by a counter in the FT601's OWN clock domain -
    // the reference's `rst | (tickcount64_com < 2)`.  That counter cannot advance
    // until ft_clk runs, so the FIFOs are held in reset until their far domain is
    // alive and released a couple of cycles later, with no clock detection
    // anywhere.  16 rather than 2 because XPM documents a 5-cycle minimum where
    // the FIFO Generator core the reference uses does not.
    reg [4:0] tickcount_ft = 5'd0;
    always @(posedge ft_clk_i) begin
        if (tickcount_ft != 5'd16) tickcount_ft <= tickcount_ft + 5'd1;
    end

    wire fifo_rst = rst | (tickcount_ft != 5'd16);

    // ---- FT601 controller -------------------------------------------------
    wire [31:0] ft_dout;
    wire        ft_dout_valid;
    wire [31:0] ft_din;
    wire        ft_din_wr_en;
    wire        ft_din_req_data;

    ft601_fifo u_ft (
        .clk          (ft_clk_i),
        .rst          (rst),
        .ft_be        (ft_be),
        .ft_data      (ft_data),
        .ft_rxf       (ft_rxf),
        .ft_txe       (ft_txe),
        .ft_oe        (ft_oe),
        .ft_rd        (ft_rd),
        .ft_wr        (ft_wr),
        .ft_wakeup    (ft_wakeup),
        .dout         (ft_dout),
        .dout_valid   (ft_dout_valid),
        .din          (ft_din),
        .din_wr_en    (ft_din_wr_en),
        .din_req_data (ft_din_req_data)
    );

    // ---- FPGA -> host crossing --------------------------------------------
    // Written in the user domain, read out in the FT601's.  The controller pulls
    // with din_req_data; a word is delivered whenever it asks and one is ready.
    wire [31:0] txc_dout;
    wire        txc_empty, txc_full;
    wire        txc_rd_en;
    wire [31:0] tx_count_w;
    wire        tx_push;

    assign txc_rd_en    = ft_din_req_data & ~txc_empty;
    assign ft_din       = txc_dout;
    assign ft_din_wr_en = txc_rd_en;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE ("block"), .FIFO_WRITE_DEPTH (1024),
        .WRITE_DATA_WIDTH (32),      .READ_DATA_WIDTH  (32),
        .READ_MODE ("fwft"), .FIFO_READ_LATENCY (0),
        .USE_ADV_FEATURES ("0000"), .CDC_SYNC_STAGES (2),
        .RELATED_CLOCKS (0), .ECC_MODE ("no_ecc"), .WAKEUP_TIME (0)
    ) tx_fifo (
        .rst (fifo_rst),
        .wr_clk (clk_ctrl), .wr_en (tx_push), .din (tx_count_w), .full (txc_full),
        .rd_clk (ft_clk_i), .rd_en (txc_rd_en), .dout (txc_dout), .empty (txc_empty),
        .sleep (1'b0), .injectdbiterr (1'b0), .injectsbiterr (1'b0),
        .almost_empty (), .almost_full (), .data_valid (), .dbiterr (), .overflow (),
        .prog_empty (), .prog_full (), .rd_data_count (), .rd_rst_busy (),
        .sbiterr (), .underflow (), .wr_ack (), .wr_data_count (), .wr_rst_busy ()
    );

    // ---- host -> FPGA crossing --------------------------------------------
    wire [31:0] rxc_dout;
    wire        rxc_empty;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE ("block"), .FIFO_WRITE_DEPTH (1024),
        .WRITE_DATA_WIDTH (32),      .READ_DATA_WIDTH  (32),
        .READ_MODE ("fwft"), .FIFO_READ_LATENCY (0),
        .USE_ADV_FEATURES ("0000"), .CDC_SYNC_STAGES (2),
        .RELATED_CLOCKS (0), .ECC_MODE ("no_ecc"), .WAKEUP_TIME (0)
    ) rx_fifo (
        .rst (fifo_rst),
        .wr_clk (ft_clk_i), .wr_en (ft_dout_valid), .din (ft_dout), .full (),
        .rd_clk (clk_ctrl), .rd_en (~rxc_empty), .dout (rxc_dout), .empty (rxc_empty),
        .sleep (1'b0), .injectdbiterr (1'b0), .injectsbiterr (1'b0),
        .almost_empty (), .almost_full (), .data_valid (), .dbiterr (), .overflow (),
        .prog_empty (), .prog_full (), .rd_data_count (), .rd_rst_busy (),
        .sbiterr (), .underflow (), .wr_ack (), .wr_data_count (), .wr_rst_busy ()
    );

    wire unused_rxc = |rxc_dout;   // drained and discarded

    // ---- pattern source ---------------------------------------------------
    reg [31:0] tx_count = 32'd0;
    assign tx_count_w = tx_count;
    assign tx_push    = ~txc_full;

    always @(posedge clk_ctrl) begin
        if (rst)          tx_count <= 32'd0;
        else if (tx_push) tx_count <= tx_count + 32'd1;
    end

    // ---- host command channel ---------------------------------------------
    // 'R' resets the FT601.  Runs over the Au's own serial bridge, a separate USB
    // device from the FT601, so it is reachable exactly when the FT601 is not.
    wire [7:0] urx_data;
    wire       urx_valid;

    uart_rx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_uart_rx (
        .clk (clk_ctrl), .rst (~clk_locked),
        .rx (usb_rx), .rx_data (urx_data), .rx_valid (urx_valid)
    );

    assign cmd_reset = urx_valid && (urx_data == 8'h52 || urx_data == 8'h72);

    reg [7:0] chip_resets = 8'd0;
    always @(posedge clk_ctrl) begin
        if (cmd_reset && chip_resets != 8'hFF) chip_resets <= chip_resets + 8'd1;
    end

    // ---- status over UART -------------------------------------------------
    // "C=xxxxxxxx F=xx" - words sent, and host-requested chip resets.  The clock
    // and FIFO-state fields are gone along with the logic that produced them.
    localparam [7:0] CH_C = 8'h43, CH_F = 8'h46, CH_EQ = 8'h3D;
    localparam [7:0] CH_SP = 8'h20, CH_CR = 8'h0D, CH_LF = 8'h0A;

    localparam [4:0] RPT_LAST = 5'd16;
    localparam [4:0] RPT_IDLE = 5'd17;

    wire [7:0] uart_data;
    wire       uart_valid, uart_ready;

    reg [21:0] rpt_div    = 22'd0;
    reg [4:0]  rpt_idx    = RPT_IDLE;
    reg [31:0] rpt_cnt    = 32'd0;
    reg [7:0]  rpt_resets = 8'd0;

    always @(posedge clk_ctrl) begin
        if (!clk_locked) begin
            rpt_div <= 22'd0;
            rpt_idx <= RPT_IDLE;
        end else begin
            rpt_div <= rpt_div + 22'd1;
            if (rpt_div == 22'd0 && rpt_idx == RPT_IDLE) begin
                rpt_cnt    <= tx_count;
                rpt_resets <= chip_resets;
                rpt_idx    <= 5'd0;
            end else if (uart_valid && uart_ready && rpt_idx != RPT_IDLE) begin
                if (rpt_idx == RPT_LAST) rpt_idx <= RPT_IDLE;
                else                     rpt_idx <= rpt_idx + 5'd1;
            end
        end
    end

    reg [3:0] nib;
    always @(*) begin
        case (rpt_idx)
            5'd2:  nib = rpt_cnt[31:28];
            5'd3:  nib = rpt_cnt[27:24];
            5'd4:  nib = rpt_cnt[23:20];
            5'd5:  nib = rpt_cnt[19:16];
            5'd6:  nib = rpt_cnt[15:12];
            5'd7:  nib = rpt_cnt[11:8];
            5'd8:  nib = rpt_cnt[7:4];
            5'd9:  nib = rpt_cnt[3:0];
            5'd13: nib = rpt_resets[7:4];
            5'd14: nib = rpt_resets[3:0];
            default: nib = 4'd0;
        endcase
    end

    wire [7:0] hex = (nib < 4'd10) ? (8'h30 + {4'd0, nib})
                                   : (8'h41 + {4'd0, nib} - 8'd10);

    reg [7:0] ch;
    always @(*) begin
        case (rpt_idx)
            5'd0:  ch = CH_C;
            5'd1:  ch = CH_EQ;
            5'd10: ch = CH_SP;
            5'd11: ch = CH_F;
            5'd12: ch = CH_EQ;
            5'd15: ch = CH_CR;
            5'd16: ch = CH_LF;
            default: ch = hex;
        endcase
    end

    assign uart_data  = ch;
    assign uart_valid = (rpt_idx != RPT_IDLE);

    uart_tx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_uart_tx (
        .clk (clk_ctrl), .rst (~clk_locked),
        .tx_data (uart_data), .tx_valid (uart_valid), .tx_ready (uart_ready), .tx (usb_tx)
    );

    // ---- status -----------------------------------------------------------
    reg [25:0] heartbeat = 26'd0;
    always @(posedge clk_ctrl) heartbeat <= heartbeat + 26'd1;

    reg [21:0] tx_blink = 22'd0;
    always @(posedge clk_ctrl) begin
        if (rst)            tx_blink <= 22'd0;
        else if (tx_push)   tx_blink <= 22'h3FFFFF;
        else if (|tx_blink) tx_blink <= tx_blink - 22'd1;
    end

    reg rx_seen = 1'b0;
    always @(posedge clk_ctrl) begin
        if (rst)             rx_seen <= 1'b0;
        else if (~rxc_empty) rx_seen <= 1'b1;
    end

    assign led[0]   = clk_locked;
    assign led[1]   = |tx_blink;
    assign led[2]   = heartbeat[25];
    assign led[3]   = rx_seen;
    assign led[7:4] = tx_count[27:24];

endmodule
