`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// snoop_top - the instrument.  Watches the Apple II bus and never drives it.
//
// The Apple pins are declared INPUT here, which is the whole argument for this
// top existing separately from master_top: a snooper cannot become a participant
// by mistake, because there is nowhere for a driver to attach.  The card's own
// plumbing - link, messages, capture, registers - is card_link, shared with the
// master; only the pin directions and what sits behind them differ.
//
// CAN_MASTER is 0, so the CPU_SOURCE register can be read and written from the
// host exactly as it is in a master build, and still cannot latch itself into
// "the soft core is driving".  See docs/BUS_MASTER.md.
//////////////////////////////////////////////////////////////////////////////////
module snoop_top #(
    parameter integer BUILD_DATE = 0,   // YYYYMMDD
    parameter integer BUILD_TIME = 0    // HHMMSS
) (
    input  wire        clk_pin,
    input  wire        rst_n,
    output wire [7:0]  led,
    input  wire        usb_rx,
    output wire        usb_tx,

    // Apple II bus (constr/apple_bus.xdc).  INPUTS ONLY.
    input  wire [7:0]  apple_data_pin,
    input  wire [15:0] apple_addr_pin,
    input  wire        apple_rw_pin,
    input  wire        apple_phi0_pin,
    input  wire        apple_m2sel_pin,
    input  wire        apple_m2b0_pin,
    input  wire        apple_inh_pin,
    input  wire        apple_res_pin,
    input  wire        apple_irq_pin,
    input  wire        apple_rdy_pin,
    input  wire        apple_dma_pin,
    input  wire        tini_5v_pin,
    output wire        tini_oe_pin,
    output wire        tini_addr_dir_pin,
    output wire        tini_data_dir_pin,

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
    inout  wire [3:0]  ft_be,

    // DDR3 (constr/ddr3.xdc).  The card's outgoing stream crosses it; see
    // card_link and docs/TX_RING.md.  Names match au_top's.
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
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

    wire        apple_clk, apple_rst;
    wire        capture_on, capture_real;
    wire [31:0] real_data;
    wire        real_valid, phi0_live, apple_res_sync;

    card_link #(
        .BUILD_DATE (BUILD_DATE),
        .BUILD_TIME (BUILD_TIME),
        .CAN_MASTER (1'b0)
    ) u_card (
        .clk_pin (clk_pin), .rst_n (rst_n), .led (led),
        .usb_rx (usb_rx), .usb_tx (usb_tx),
        .apple_clk (apple_clk), .apple_rst (apple_rst),
        .capture_on (capture_on), .capture_real (capture_real),
        .real_data (real_data), .real_valid (real_valid),
        .phi0_live (phi0_live),
        .apple_res_sync (apple_res_sync),
        .cpu_source_active (),          // nothing here can act on it
        .mb_slot_active (),             // nor on this
        .boot_arm (), .boot_release (),  // nor hold a core
        .boot_held (1'b0),
        .hd_slot_active (),             // nor answer for a hard disk
        .hd_rom_loaded (1'b0), .hd_busy (1'b0), .hd_execs (8'd0),
        .kbd_press (), .kbd_press_key (), .kbd_drop (),   // nor type at it
        .kbd_lock (), .kbd_flags (3'd0), .kbd_counts (32'd0),
        .kbd_resolved_key (7'd0), .kbd_changed (1'b0),
        .pb_override (), .pb_hw (3'd0),                  // nor press a button
        .res_drive (),
        .app_msg_valid (), .app_msg_type (), .app_msg_free (),
        .app_msg_len (), .app_pay_data (), .app_pay_valid (),
        .aux_word (32'd0), .aux_valid (1'b0), .aux_take (),
        .ft_clk (ft_clk), .ft_rxf (ft_rxf), .ft_txe (ft_txe),
        .ft_rd (ft_rd), .ft_wr (ft_wr), .ft_oe (ft_oe),
        .ft_wakeup (ft_wakeup), .ft_reset (ft_reset),
        .ft_data (ft_data), .ft_be (ft_be),
        .ddr3_addr (ddr3_addr), .ddr3_ba (ddr3_ba),
        .ddr3_ras_n (ddr3_ras_n), .ddr3_cas_n (ddr3_cas_n), .ddr3_we_n (ddr3_we_n),
        .ddr3_reset_n (ddr3_reset_n), .ddr3_ck_p (ddr3_ck_p), .ddr3_ck_n (ddr3_ck_n),
        .ddr3_cke (ddr3_cke), .ddr3_cs_n (ddr3_cs_n), .ddr3_dm (ddr3_dm),
        .ddr3_odt (ddr3_odt), .ddr3_dq (ddr3_dq),
        .ddr3_dqs_p (ddr3_dqs_p), .ddr3_dqs_n (ddr3_dqs_n)
    );

    // The level shifters point Apple -> FPGA, always.  A constant, so there is
    // no state in which this board could be driving.
    assign tini_oe_pin       = tini_5v_pin;
    assign tini_addr_dir_pin = 1'b0;
    assign tini_data_dir_pin = 1'b0;

    apple_bus_read u_apple (
        .clk               (apple_clk),
        .rst               (apple_rst),
        .enable            (capture_on && capture_real),
        .apple_data_pin    (apple_data_pin),
        .apple_addr_pin    (apple_addr_pin),
        .apple_rw_pin      (apple_rw_pin),
        .apple_phi0_pin    (apple_phi0_pin),
        .apple_m2sel_pin   (apple_m2sel_pin),
        .apple_m2b0_pin    (apple_m2b0_pin),
        .apple_inh_pin     (apple_inh_pin),
        .apple_res_pin     (apple_res_pin),
        .apple_irq_pin     (apple_irq_pin),
        .apple_rdy_pin     (apple_rdy_pin),
        .apple_dma_pin     (apple_dma_pin),
        .ev_data           (real_data),
        .ev_valid          (real_valid),
        .sync_override     (1'b0),
        .sync_override_en  (1'b0),   // the instrument reports only what it saw
        .data_override     (8'h00),
        .data_override_en  (1'b0),
        .res_sync          (apple_res_sync),
        .irq_sync          (),
        .phi0_sync         (),
        .data_sync         (),
        .phi0_active       (phi0_live)
    );

endmodule
