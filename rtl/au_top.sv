`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// au_top - strudelworks milestone 1: DDR3 bring-up and latency measurement.
//
// Deliberately minimal.  This build answers one question - what read latency does
// UberDDR3 actually deliver on an Alchitry Au, worst case, including refresh
// interference - and nothing else.  No Apple bus, no FT601.  Both are constrained
// (constr/apple_bus.xdc, constr/ft601.xdc) but neither is in the build yet,
// because a failure here invalidates the whole approach and there is no point
// carrying the rest of the design through it.
//
// Reading the LEDs:
//   0000 0001         calibration (and BIST) still running
//   1111 1111         a read returned wrong data - stop and debug
//   0xxx xxxx         worst-case SEQ read latency, controller clocks
//   1xxx xxxx         worst-case RND read latency, controller clocks
//   (alternating about twice a second between the last two)
//
// At 100 MHz each count is 10 ns.  The Apple II budget to beat is roughly 490 ns
// from address-valid to data-needed on a 1.023 MHz machine, so about 49 counts -
// and that budget also has to cover the bus synchronisers and level shifters at
// both ends, so the real target for the memory alone is well under that.
//////////////////////////////////////////////////////////////////////////////////

module au_top (
    input  wire       clk_pin,   // 100 MHz
    input  wire       rst_n,     // board button, active low
    output wire [7:0] led,
    input  wire       usb_rx,
    output wire       usb_tx,

    // DDR3 - names match constr/ddr3.xdc
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    // [0:0] rather than scalar, deliberately: MIG named these as 1-bit vectors,
    // so constr/ddr3.xdc (a transcription of MIG's) constrains ddr3_ck_p[0] and
    // friends.  Declared scalar, those five constraints silently match nothing -
    // Vivado emits only a warning, and the DDR3 clock, CKE, CS and ODT end up
    // unconstrained and placed wherever the placer likes.  UberDDR3's own ports
    // are [DUAL_RANK_DIMM:0] as well, so this width agrees with both ends.
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_p,
    inout  wire [1:0]  ddr3_dqs_n
);

    // usb_rx is unused - the report is one-way.  Tie it into a net the tools
    // will not complain about rather than leaving the input dangling.
    wire unused_rx = usb_rx;

    wire clk_ctrl, clk_ddr3, clk_ddr3_90, clk_ref, clk_locked;

    clk_gen u_clk (
        .clk_in      (clk_pin),
        .rst         (~rst_n),
        .clk_ctrl    (clk_ctrl),
        .clk_ddr3    (clk_ddr3),
        .clk_ddr3_90 (clk_ddr3_90),
        .clk_ref     (clk_ref),
        .locked      (clk_locked)
    );

    // UberDDR3 wants a synchronous active-low reset in the controller domain.
    // Two flops off the async source, held until the MMCM locks.
    reg [1:0] rst_sync;
    always @(posedge clk_ctrl or negedge clk_locked) begin
        if (!clk_locked) rst_sync <= 2'b00;
        else             rst_sync <= {rst_sync[0], rst_n};
    end
    wire ddr3_rst_n = rst_sync[1];
    wire probe_rst  = ~rst_sync[1];

    wire         wb_cyc, wb_stb, wb_we, wb_stall, wb_ack;
    wire [23:0]  wb_addr;
    wire [127:0] wb_data, wb_rdata;
    wire [15:0]  wb_sel;
    wire [3:0]   wb_aux;
    wire         calib_complete;
    wire [31:0]  ddr3_debug;

    ddr3_wrapper u_ddr3 (
        .clk_ctrl    (clk_ctrl),
        .clk_ddr3    (clk_ddr3),
        .clk_ddr3_90 (clk_ddr3_90),
        .clk_ref     (clk_ref),
        .rst_n       (ddr3_rst_n),

        .wb_cyc      (wb_cyc),
        .wb_stb      (wb_stb),
        .wb_we       (wb_we),
        .wb_addr     (wb_addr),
        .wb_data     (wb_data),
        .wb_sel      (wb_sel),
        .wb_aux      (wb_aux),
        .wb_stall    (wb_stall),
        .wb_ack      (wb_ack),
        .wb_rdata    (wb_rdata),
        .wb_rdata_aux(),

        .calib_complete (calib_complete),
        .ddr3_debug     (ddr3_debug),
        .user_self_refresh (1'b0),
        .refresh_ok        (probe_refresh_ok),

        .ddr3_addr   (ddr3_addr),
        .ddr3_ba     (ddr3_ba),
        .ddr3_ras_n  (ddr3_ras_n),
        .ddr3_cas_n  (ddr3_cas_n),
        .ddr3_we_n   (ddr3_we_n),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p   (ddr3_ck_p),
        .ddr3_ck_n   (ddr3_ck_n),
        .ddr3_cke    (ddr3_cke),
        .ddr3_cs_n   (ddr3_cs_n),
        .ddr3_dm     (ddr3_dm),
        .ddr3_odt    (ddr3_odt),
        .ddr3_dq     (ddr3_dq),
        .ddr3_dqs_p  (ddr3_dqs_p),
        .ddr3_dqs_n  (ddr3_dqs_n)
    );

    // These are the numbers to pull out with an ILA when the LEDs say something
    // surprising - MARK_DEBUG keeps them out of the optimiser's reach.
    (* MARK_DEBUG = "TRUE" *) wire [15:0] seq_max_total;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] seq_min_total;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] rnd_max_total;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] rnd_min_total;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] last_wait;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] last_data;
    (* MARK_DEBUG = "TRUE" *) wire        data_error;

    latency_probe u_probe (
        .clk            (clk_ctrl),
        .rst            (probe_rst),
        .calib_complete (calib_complete),

        .wb_cyc   (wb_cyc),
        .wb_stb   (wb_stb),
        .wb_we    (wb_we),
        .wb_addr  (wb_addr),
        .wb_data  (wb_data),
        .wb_sel   (wb_sel),
        .wb_aux   (wb_aux),
        .wb_stall (wb_stall),
        .wb_ack   (wb_ack),
        .wb_rdata (wb_rdata),

        .seq_max_total (seq_max_total),
        .seq_min_total (seq_min_total),
        .rnd_max_total (rnd_max_total),
        .rnd_min_total (rnd_min_total),
        .last_wait     (last_wait),
        .last_data     (last_data),
        .data_error    (data_error),
        .led           (led),

        .win_count     (win_count),
        .seq_min_w     (seq_min_w),
        .seq_mean_x10  (seq_mean_x10),
        .seq_max_w     (seq_max_w),
        .seq_gt_gs     (seq_gt_gs),
        .seq_gt_leg    (seq_gt_leg),
        .rnd_min_w     (rnd_min_w),
        .rnd_mean_x10  (rnd_mean_x10),
        .rnd_max_w     (rnd_max_w),
        .rnd_gt_gs     (rnd_gt_gs),
        .rnd_gt_leg    (rnd_gt_leg),
        .err_count     (err_count),
        .refresh_ok    (probe_refresh_ok)
    );

    // ---- UART report -------------------------------------------------------
    // The LEDs can only show two cumulative maxima, which saturate at the
    // refresh-collision worst case and hide the typical figure entirely.  This
    // prints the full per-window summary once a second on the Au's own USB-serial
    // bridge: 115200 8N1, no flow control, no input needed.
    wire [31:0] win_count, seq_mean_x10, seq_gt_gs, seq_gt_leg;
    wire [31:0] rnd_mean_x10, rnd_gt_gs, rnd_gt_leg, err_count;
    wire [15:0] seq_min_w, seq_max_w, rnd_min_w, rnd_max_w;

    // Milestone 2: the probe emulates an Apple II bus cycle and tells the
    // controller when it may refresh.  Stands in for the line buffer's hit
    // signal until milestone 2b builds the real one.
    wire probe_refresh_ok;

    wire [7:0] tx_data;
    wire       tx_valid, tx_ready;

    report_tx #(
        .CLK_HZ        (100_000_000),
        .REPORT_PERIOD (100_000_000)   // 1 s
    ) u_report (
        .clk    (clk_ctrl),
        .rst    (probe_rst),
        .enable (calib_complete),

        .win_count    (win_count),
        .seq_min      (seq_min_w),
        .seq_mean_x10 (seq_mean_x10),
        .seq_max      (seq_max_w),
        .seq_gt_gs    (seq_gt_gs),
        .seq_gt_leg   (seq_gt_leg),
        .rnd_min      (rnd_min_w),
        .rnd_mean_x10 (rnd_mean_x10),
        .rnd_max      (rnd_max_w),
        .rnd_gt_gs    (rnd_gt_gs),
        .rnd_gt_leg   (rnd_gt_leg),
        .err_count    (err_count),

        .tx_data  (tx_data),
        .tx_valid (tx_valid),
        .tx_ready (tx_ready)
    );

    uart_tx #(
        .CLK_HZ (100_000_000),
        .BAUD   (115_200)
    ) u_uart (
        .clk      (clk_ctrl),
        .rst      (probe_rst),
        .tx_data  (tx_data),
        .tx_valid (tx_valid),
        .tx_ready (tx_ready),
        .tx       (usb_tx)
    );

endmodule
