`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// card_link - the card, minus the Apple.
//
// Everything that does not care whether this board is WATCHING the Apple bus or
// DRIVING it: the FT601 link, the message layer, the clock domain crossings, the
// event capture path, the control registers and the UART status report.
//
// It was snoop_top until there were two tops.  Splitting it out is not tidiness:
// the alternative was a second copy of five hundred lines of link plumbing, and
// a bug fixed in one copy is a bug still shipped in the other.  What is left in
// each top is only what actually differs - which way the Apple pins point, and
// whether there is a CPU behind them.
//
// THE SEAM IS NARROW ON PURPOSE.  A top hands in an event stream already in the
// wire format plus the synchronised RES'; it gets back the clock and reset to
// run its Apple hardware in, the capture gating, and the latched CPU source.
// Every decision about the link is on this side of it and every decision about
// the bus is on the other.
//
// CAN_MASTER reaches wb_regfile from here.  A watching build passes 0, and the
// CPU_SOURCE register then cannot latch itself into "the soft core is driving"
// no matter what the host writes to it.
//
// THE DDR3 IS HERE TOO.  Everything the card says to the host goes through
// 32 MB of it on the way (rtl/tx_ring.sv, docs/TX_RING.md), so the controller
// and its one Wishbone port live on this side of the seam, behind wb_arb.
// There is no path around it: a board whose DDR3 does not calibrate has no
// link, and says so on the UART - "D=0" - which is the diagnostic.
//
// The link's own design notes - the framing, the errata, the crossings - are in
// docs/PROTOCOL.md and in the modules themselves.
//////////////////////////////////////////////////////////////////////////////////

module card_link #(
    // Stamped by build/build.sh via build.tcl's -generic, and readable back over
    // the link as registers 0 and 1.  Zero means an unstamped build.
    parameter integer BUILD_DATE = 0,   // YYYYMMDD
    parameter integer BUILD_TIME = 0,   // HHMMSS

    // 1 only in a top that can actually drive the Apple bus.  Reaches
    // wb_regfile, where it is what stops a watching build from ever latching
    // itself into "the soft core is driving".
    parameter bit CAN_MASTER = 1'b0
) (
    input  wire        clk_pin,
    input  wire        rst_n,
    output wire [7:0]  led,
    input  wire        usb_rx,
    output wire        usb_tx,

    // ---- the Apple seam ----------------------------------------------------
    // No Apple pins here, and that is the point: this module is the CARD - the
    // link, the message layer, the capture path and the registers - and it is
    // identical whether the card is watching the bus or driving it.  The pins
    // belong to whichever top owns them, and only the tops differ.
    //
    // The clock and reset come back OUT so a top's Apple hardware runs in this
    // domain rather than making its own.
    output wire        apple_clk,
    output wire        apple_rst,

    // Gating for the top's reader: capture only when the host asked for it, and
    // only when it asked for the real bus rather than the synthetic generator.
    output wire        capture_on,
    output wire        capture_real,

    // The top's event stream, already in the wire format.
    input  wire [31:0] real_data,
    input  wire        real_valid,
    input  wire        phi0_live,

    // Synchronised RES', for the CPU_SOURCE latch, and what it latched.
    input  wire        apple_res_sync,
    output wire        cpu_source_active,

    // The Mockingboard's slot, latched on the same RES' edge; 0 = disabled.
    // A watching top leaves it unconnected - a snoop build cannot answer for
    // a slot, and CAN_MASTER=0 holds this at zero anyway.
    output wire [2:0]  mb_slot_active,

    // The boot hold (rtl/boot_hold.sv, in a mastering top).  arm and release
    // are the host's, from the BOOT_HOLD register; held comes back for the
    // readback and for the CPU_HOLD notice.  A watching top ties held to 0.
    output wire        boot_arm,
    output wire        boot_release,
    input  wire        boot_held,

    // The hard disk's slot (rtl/hd_card.sv), latched on the RES' edge like
    // the Mockingboard's, and its status back for the HD_SLOT readback.  A
    // watching top ties the inputs to 0.
    output wire [2:0]  hd_slot_active,
    input  wire        hd_rom_loaded,
    input  wire        hd_busy,
    input  wire [7:0]  hd_execs,

    // Keyboard injection (rtl/kbd_inject.sv, in a mastering top): the
    // KBD_INJECT register's press and drop pulses and the key out, its strobe
    // and taken count back for the readback.  A watching top ties the inputs
    // to 0.
    output wire        kbd_press,
    output wire [6:0]  kbd_press_key,
    output wire        kbd_drop,
    input  wire        kbd_strobe,
    input  wire [7:0]  kbd_taken,

    // The pushbuttons (rtl/pb_inject.sv): the BUTTONS register's word out,
    // the hardware's levels back.  A watching top ties the input to 0.
    output wire [5:0]  pb_override,
    input  wire [2:0]  pb_hw,

    // Programmatic Ctrl-Reset: drive the Apple's RES' low while high.  Only a
    // mastering top wires it to the pin; a snooper leaves it unconnected.
    output wire        res_drive,

    // ---- application messages, through the seam --------------------------
    // Host -> card: every decoded message, as ft601_msg_rx produces it, for a
    // top's peripherals to pick their own types out of.  The link layer has
    // already acted on the ones that are its business (BUS_ENABLE, the
    // register pair) and passes the stream on unfiltered.
    output wire        app_msg_valid,
    output wire [7:0]  app_msg_type,
    output wire [15:0] app_msg_free,
    output wire [7:0]  app_msg_len,
    output wire [31:0] app_pay_data,
    output wire        app_pay_valid,

    // Card -> host: a whole message a word at a time, a port of msg_arb.  A
    // top with nothing to send ties aux_valid low.
    input  wire [31:0] aux_word,
    input  wire        aux_valid,
    output wire        aux_take,

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

    // DDR3 (constr/ddr3.xdc) - names match au_top's, which match MIG's.
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

    // ---- clocks -----------------------------------------------------------
    wire clk_ctrl, clk_ddr3, clk_ddr3_90, clk_ref;
    wire clk_locked;

    clk_gen u_clk (
        .clk_in      (clk_pin),
        .rst         (~rst_n),
        .clk_ctrl    (clk_ctrl),
        .clk_ddr3    (clk_ddr3),
        .clk_ddr3_90 (clk_ddr3_90),
        .clk_ref     (clk_ref),
        .locked      (clk_locked)
    );

    wire ft_clk_i;
    ft_clk_buf u_ft_clk (.ft_clk_pin(ft_clk), .ft_clk(ft_clk_i));

    // ---- reset ------------------------------------------------------------
    localparam integer RST_TICKS      = 64;
    localparam integer CMD_RST_CYCLES = 100_000;   // 1 ms at 100 MHz

    // Three things pull the reset lever, and they are all the same lever on
    // purpose: the host's 'R' command, the watchdog expiring, and a malformed
    // message arriving.  The last two are both "we no longer agree with the host
    // about where frames begin", which is unrecoverable by design.
    //
    // 1 ms is measured, not chosen: a ~40 ns pulse left the chip untouched and
    // 1 ms made it re-enumerate.  See ft601_top for the full note.
    wire       cmd_reset_strobe;
    wire       watchdog_fired;
    wire       rx_frame_error;
    wire       link_reset_trigger = cmd_reset_strobe | watchdog_fired | rx_frame_error;

    reg [16:0] cmd_rst_cnt = 17'd0;

    always @(posedge clk_ctrl) begin
        if (!clk_locked)                    cmd_rst_cnt <= 17'd0;
        else if (link_reset_trigger)        cmd_rst_cnt <= CMD_RST_CYCLES[16:0];
        else if (cmd_rst_cnt != 17'd0)      cmd_rst_cnt <= cmd_rst_cnt - 17'd1;
    end

    wire cmd_reset = (cmd_rst_cnt != 17'd0);

    reg [7:0] tickcount = 8'd0;
    always @(posedge clk_ctrl) begin
        if (!clk_locked)                tickcount <= 8'd0;
        else if (tickcount < RST_TICKS) tickcount <= tickcount + 8'd1;
    end

    wire rst = ~clk_locked | (tickcount < RST_TICKS) | cmd_reset;

    assign ft_reset = ~rst;

    reg [4:0] tickcount_ft = 5'd0;
    always @(posedge ft_clk_i) begin
        if (tickcount_ft != 5'd16) tickcount_ft <= tickcount_ft + 5'd1;
    end

    wire fifo_rst = rst | (tickcount_ft != 5'd16);

    // ---- DDR3 ---------------------------------------------------------------
    // The controller's reset is the clock-lock reset, as in au_top, and NOT
    // the link's: a watchdog expiry or a host 'R' must not cost a
    // recalibration.  The ring's clients drain their outstanding requests
    // through the link's reset instead; see tx_ring.
    reg [1:0] ddr3_rst_sync;
    always @(posedge clk_ctrl or negedge clk_locked) begin
        if (!clk_locked) ddr3_rst_sync <= 2'b00;
        else             ddr3_rst_sync <= {ddr3_rst_sync[0], rst_n};
    end
    wire ddr3_rst_n = ddr3_rst_sync[1];

    wire         wb_cyc, wb_stb, wb_we, wb_stall, wb_ack;
    wire [23:0]  wb_addr;
    wire [127:0] wb_data, wb_rdata;
    wire [15:0]  wb_sel;
    wire [3:0]   wb_aux, wb_rdata_aux;
    wire         calib_complete;

    // BIST_MODE 0: au_top's memory test at every power-up would hold the link
    // for seconds, and the memory it tested has since done 123 million
    // accesses without an error (docs/DERISK.md).  Calibration alone is
    // milliseconds.
    ddr3_wrapper #(.BIST_MODE (0)) u_ddr3 (
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
        .wb_rdata_aux(wb_rdata_aux),
        .calib_complete (calib_complete),
        .ddr3_debug     (),
        // Refresh is the controller's own until an Apple-side client exists
        // to say when a window is free; low is upstream behaviour and safe.
        .user_self_refresh (1'b0),
        .refresh_ok        (1'b0),
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

    // ---- FT601 controller -------------------------------------------------
    wire [31:0] ft_dout;
    wire        ft_dout_valid;
    wire [31:0] ft_din;
    wire        ft_din_wr_en;
    wire        ft_din_req_data;
    wire        ft_fwd, ft_q_empty, ft_in_rx;

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
        .din_req_data (ft_din_req_data),
        .fwd          (ft_fwd),
        .q_empty      (ft_q_empty),
        .in_rx        (ft_in_rx)
    );

    // ---- FPGA -> host crossing --------------------------------------------
    localparam integer TX_FIFO_DEPTH = 4096;
    localparam integer RX_FIFO_DEPTH = 1024;

    wire [31:0] txc_dout;
    wire        txc_empty, txc_full;
    wire        txc_rd_en;
    wire [31:0] tx_word;
    wire        tx_push;
    wire        hb_sent;

    // Every source -> the message bus (msg_arb) -> tx_ring -> tx_fifo.  A
    // message is one Wishbone burst, so nothing can land inside another
    // source's; the ring is 32 MB of DDR3 the stream crosses on its way.
    // See msg_arb, msg_master, tx_ring and docs/TX_RING.md.
    wire [31:0] cap_word;
    wire        cap_valid;
    wire        cap_take;
    wire [31:0] rsp_addr, rsp_data;
    wire        rsp_valid, rsp_take;
    // Driven by the synchronizer further down, next to the control-domain
    // register it crosses from; declared here because the instantiation that
    // consumes it comes first.
    wire [3:0]  hb_shift_ft;

    ft601_msg_tx u_msg_tx (
        .clk          (ft_clk_i),
        .rst          (rst),
        .fifo_dout    (txc_dout),
        .fifo_empty   (txc_empty),
        .fifo_rd_en   (txc_rd_en),
        .din          (ft_din),
        .din_wr_en    (ft_din_wr_en),
        .din_req_data (ft_din_req_data),
        .fwd          (ft_fwd),
        .q_empty      (ft_q_empty),
        .in_rx        (ft_in_rx),
        .idle_shift   (hb_shift_ft),
        .hb_sent      (hb_sent)
    );

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE ("block"), .FIFO_WRITE_DEPTH (TX_FIFO_DEPTH),
        .WRITE_DATA_WIDTH (32),      .READ_DATA_WIDTH  (32),
        .READ_MODE ("fwft"), .FIFO_READ_LATENCY (0),
        .USE_ADV_FEATURES ("0000"), .CDC_SYNC_STAGES (2),
        .RELATED_CLOCKS (0), .ECC_MODE ("no_ecc"), .WAKEUP_TIME (0)
    ) tx_fifo (
        .rst (fifo_rst),
        .wr_clk (clk_ctrl), .wr_en (tx_push), .din (tx_word), .full (txc_full),
        .rd_clk (ft_clk_i), .rd_en (txc_rd_en), .dout (txc_dout), .empty (txc_empty),
        .sleep (1'b0), .injectdbiterr (1'b0), .injectsbiterr (1'b0),
        .almost_empty (), .almost_full (), .data_valid (), .dbiterr (), .overflow (),
        .prog_empty (), .prog_full (), .rd_data_count (), .rd_rst_busy (),
        .sbiterr (), .underflow (), .wr_ack (), .wr_data_count (), .wr_rst_busy ()
    );

    // ---- host -> FPGA crossing --------------------------------------------
    wire [31:0] rxc_dout;
    wire        rxc_empty;
    wire        rxc_rd_en;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE ("block"), .FIFO_WRITE_DEPTH (RX_FIFO_DEPTH),
        .WRITE_DATA_WIDTH (32),      .READ_DATA_WIDTH  (32),
        .READ_MODE ("fwft"), .FIFO_READ_LATENCY (0),
        .USE_ADV_FEATURES ("0000"), .CDC_SYNC_STAGES (2),
        .RELATED_CLOCKS (0), .ECC_MODE ("no_ecc"), .WAKEUP_TIME (0)
    ) rx_fifo (
        .rst (fifo_rst),
        .wr_clk (ft_clk_i), .wr_en (ft_dout_valid), .din (ft_dout), .full (),
        .rd_clk (clk_ctrl), .rd_en (rxc_rd_en), .dout (rxc_dout), .empty (rxc_empty),
        .sleep (1'b0), .injectdbiterr (1'b0), .injectsbiterr (1'b0),
        .almost_empty (), .almost_full (), .data_valid (), .dbiterr (), .overflow (),
        .prog_empty (), .prog_full (), .rd_data_count (), .rd_rst_busy (),
        .sbiterr (), .underflow (), .wr_ack (), .wr_data_count (), .wr_rst_busy ()
    );

    // ---- host -> card messages ---------------------------------------------
    localparam [7:0] T_BUS_ENABLE = 8'h11;

    wire        msg_valid;
    wire [7:0]  msg_type;
    wire [15:0] msg_free;
    wire [7:0]  msg_len;
    wire [31:0] pay_data;
    wire        pay_valid;

    ft601_msg_rx u_msg_rx (
        .clk         (clk_ctrl),
        .rst         (rst),
        .fifo_dout   (rxc_dout),
        .fifo_empty  (rxc_empty),
        .fifo_rd_en  (rxc_rd_en),
        .msg_valid   (msg_valid),
        .msg_type    (msg_type),
        .msg_free    (msg_free),
        .msg_len     (msg_len),
        .pay_data    (pay_data),
        .pay_valid   (pay_valid),
        .frame_error (rx_frame_error)
    );

    assign app_msg_valid = msg_valid;
    assign app_msg_type  = msg_type;
    assign app_msg_free  = msg_free;
    assign app_msg_len   = msg_len;
    assign app_pay_data  = pay_data;
    assign app_pay_valid = pay_valid;

    wire bus_enable_msg = msg_valid && (msg_type == T_BUS_ENABLE);
    wire want_enable    = bus_enable_msg && msg_free[0];
    wire want_disable   = bus_enable_msg && !msg_free[0];

    reg capture_enable = 1'b0;
    always @(posedge clk_ctrl) begin
        if (rst)                capture_enable <= 1'b0;
        else if (want_enable)   capture_enable <= 1'b1;
        else if (want_disable)  capture_enable <= 1'b0;
    end

    // Heartbeat period select, free[7:4], latched at enable alongside the source
    // so it cannot change mid-capture.  Zero is the built-in default, which is
    // what lets this ride in an existing message: a host that never sets it
    // sends zero and nothing changes.
    reg [3:0] hb_shift_ctrl = 4'd0;
    always @(posedge clk_ctrl) begin
        if (rst)              hb_shift_ctrl <= 4'd0;
        else if (want_enable) hb_shift_ctrl <= msg_free[7:4];
    end

    // clk_ctrl -> ft_clk.  Four bits that change once per capture and are then
    // held for the whole run, so two flops are enough: the only exposure is the
    // single transition, and the worst it can produce is one heartbeat at a
    // blended period before the value settles.
    synchronizer #(.WIDTH(4)) u_hb_shift_sync (
        .clk (ft_clk_i), .rst (rst), .in (hb_shift_ctrl), .out (hb_shift_ft)
    );

    // Source select, latched at enable so it cannot change mid-capture.
    // free[1]: 0 = synthetic, 1 = the real Apple bus.
    reg source_real = 1'b0;
    always @(posedge clk_ctrl) begin
        if (rst)              source_real <= 1'b0;
        else if (want_enable) source_real <= msg_free[1];
    end

    // Acknowledge every enable change with a status frame, so the host can see
    // the card acted rather than inferring it from the data stopping.
    reg status_req = 1'b0;
    always @(posedge clk_ctrl) status_req <= !rst && bus_enable_msg;

    // ---- watchdog -----------------------------------------------------------
    // A clean stop disarms it - but only once the ring is EMPTY.  The stop's
    // own acknowledgement is the last thing queued, so a host that reads
    // everything disarms the watchdog the moment it has; a host that says
    // stop and then walks away with megabytes unread is, to the card, a host
    // that died, and the reset that follows clears the ring for the next
    // session instead of queueing that session's capture behind the last
    // one's leftovers.  Measured: a shutdown that stalled mid-drain left
    // 1.28 M lines for the next capture to sit behind.
    wire ring_empty = (ring_status[21:0] == 22'd0);
    reg  stop_pending = 1'b0;
    always @(posedge clk_ctrl) begin
        if (rst)               stop_pending <= 1'b0;
        else if (want_enable)  stop_pending <= 1'b0;
        else if (want_disable) stop_pending <= 1'b1;
        else if (ring_empty)   stop_pending <= 1'b0;
    end
    wire wd_disarm = stop_pending && ring_empty;

    link_watchdog u_wd (
        .clk    (clk_ctrl),
        .rst    (rst),
        .arm    (want_enable),
        .disarm (wd_disarm),
        .kick   (msg_valid),        // ANY well-formed message, not only heartbeats
        .armed  (),
        .fired  (watchdog_fired)
    );

    // ---- event sources ------------------------------------------------------
    // Two, selected per capture.  The synthetic one is not scaffolding to be
    // removed: it is the only source whose content the host can verify, so it
    // stays as the way to tell a suspect capture from a suspect capturer.
    wire [31:0] synth_data;
    wire        synth_valid;

    synth_bus_events u_synth (
        .clk      (clk_ctrl),
        .rst      (rst),
        .enable   (capture_enable && !source_real),
        .ev_data  (synth_data),
        .ev_valid (synth_valid)
    );

    assign apple_clk    = clk_ctrl;
    assign apple_rst    = rst;
    assign capture_on   = capture_enable;
    assign capture_real = source_real;

    wire [31:0] ev_data  = source_real ? real_data  : synth_data;
    wire        ev_valid = source_real ? real_valid : synth_valid;

    wire        overflow;
    wire [31:0] captured;

    bus_event_capture u_capture (
        .clk        (clk_ctrl),
        .rst        (rst),
        .enable     (capture_enable),
        .status_req (status_req),
        .ev_data    (ev_data),
        .ev_valid   (ev_valid),
        .tx_data    (cap_word),
        .tx_valid   (cap_valid),
        .tx_take    (cap_take),
        .overflow   (overflow),
        .captured   (captured)
    );

    // ---- control registers --------------------------------------------------
    // A 32-bit Wishbone of its own rather than a decode off the DDR3 bus, which
    // is 128 bits wide and addressed by burst index.  See wb_regfile.
    wire        rwb_cyc, rwb_stb, rwb_we, rwb_ack, rwb_stall;
    wire [31:0] rwb_adr, rwb_dat_w, rwb_dat_r;
    wire [3:0]  rwb_sel;

    reg_bridge u_reg_bridge (
        .clk       (clk_ctrl),
        .rst       (rst),
        .msg_valid (msg_valid),
        .msg_type  (msg_type),
        .pay_data  (pay_data),
        .pay_valid (pay_valid),
        .wb_cyc    (rwb_cyc),
        .wb_stb    (rwb_stb),
        .wb_we     (rwb_we),
        .wb_adr    (rwb_adr),
        .wb_dat_w  (rwb_dat_w),
        .wb_sel    (rwb_sel),
        .wb_ack    (rwb_ack),
        .wb_stall  (rwb_stall),
        .wb_dat_r  (rwb_dat_r),
        .rsp_addr  (rsp_addr),
        .rsp_data  (rsp_data),
        .rsp_valid (rsp_valid),
        .rsp_take  (rsp_take)
    );

    wb_regfile #(
        .BUILD_DATE (BUILD_DATE),
        .BUILD_TIME (BUILD_TIME),
        .CAN_MASTER (CAN_MASTER)
    ) u_regfile (
        .clk      (clk_ctrl),
        .rst      (rst),
        .apple_res_sync    (apple_res_sync),
        .cpu_source_active (cpu_source_active),
        .mb_slot_active    (mb_slot_active),
        .boot_arm          (boot_arm),
        .boot_release      (boot_release),
        .boot_held         (boot_held),
        .hd_slot_active    (hd_slot_active),
        .hd_rom_loaded     (hd_rom_loaded),
        .hd_busy        (hd_busy),
        .hd_execs          (hd_execs),
        .kbd_press         (kbd_press),
        .kbd_press_key     (kbd_press_key),
        .kbd_drop          (kbd_drop),
        .kbd_strobe        (kbd_strobe),
        .kbd_taken         (kbd_taken),
        .pb_override       (pb_override),
        .pb_hw             (pb_hw),
        .res_drive         (res_drive),
        .ring_status       (ring_status),
        .wb_cyc   (rwb_cyc),
        .wb_stb   (rwb_stb),
        .wb_we    (rwb_we),
        .wb_adr   (rwb_adr),
        .wb_dat_w (rwb_dat_w),
        .wb_sel   (rwb_sel),
        .wb_ack   (rwb_ack),
        .wb_stall (rwb_stall),
        .wb_dat_r (rwb_dat_r)
    );

    // ---- the CPU_HOLD notice --------------------------------------------------
    // The one thing the card says unasked: the boot hold engaged, or let go.
    // A header-only message, free[0] = held, sent on every edge of `held` -
    // and carrying the level as it is when the word goes out, so a bounce
    // that flips it twice while a notice waits still ends with the host
    // knowing the truth.  An edge and a take in the same cycle keep the
    // notice pending, for the same reason.
    //
    // Gated on the capture being enabled, which is the silent-until-asked
    // rule (docs/PROTOCOL.md): a host that has not opened a capture is not
    // listening, and a notice queued for it would be the first word its
    // successor reads.  A host attaching to a hold already in progress reads
    // BOOT_HOLD instead, which is why `held` is in the register too.
    localparam [7:0] T_CPU_HOLD = 8'h17;

    reg  held_prev    = 1'b0;
    reg  note_pending = 1'b0;
    wire note_take;
    wire held_edge = (boot_held != held_prev);

    always @(posedge clk_ctrl) begin
        if (rst) begin
            held_prev    <= 1'b0;
            note_pending <= 1'b0;
        end else begin
            held_prev <= boot_held;
            if (held_edge && capture_enable) note_pending <= 1'b1;
            else if (note_take)              note_pending <= 1'b0;
        end
    end

    // ---- the message bus ---------------------------------------------------
    // A 32-bit Wishbone with four masters, in priority order: a register
    // reply, the notice, the top's application message, the capture.  Each
    // source is a stream, and msg_master makes it a master that holds CYC
    // across its message; msg_arb grants per CYC; tx_ring is the one slave.
    // Everything above the capture is rate-bounded by the host or the bus;
    // the capture is the one continuous source and goes last.  See msg_arb
    // for why that order is load-bearing.
    localparam integer N_SRC = 4;

    wire [N_SRC-1:0]    mb_cyc, mb_stb, mb_we, mb_stall, mb_ack;
    wire [N_SRC*32-1:0] mb_adr, mb_dat;
    wire [N_SRC*4-1:0]  mb_sel;
    wire [N_SRC-1:0]    ms_valid, ms_take;
    wire [N_SRC*32-1:0] ms_word;
    wire                sb_cyc, sb_stb, sb_we, sb_stall, sb_ack;
    wire [31:0]         sb_adr, sb_dat;
    wire [3:0]          sb_sel;
    wire                out_valid;
    wire [31:0]         ring_status;

    reply_stream u_reply (
        .clk       (clk_ctrl),
        .rst       (rst),
        .rsp_addr  (rsp_addr),
        .rsp_data  (rsp_data),
        .rsp_valid (rsp_valid),
        .rsp_take  (rsp_take),
        .word      (ms_word[0*32 +: 32]),
        .valid     (ms_valid[0]),
        .take      (ms_take[0])
    );

    assign ms_word[1*32 +: 32] = {15'd0, boot_held, T_CPU_HOLD, 8'd0};
    assign ms_valid[1]         = note_pending;
    assign note_take           = ms_take[1];

    assign ms_word[2*32 +: 32] = aux_word;
    assign ms_valid[2]         = aux_valid;
    assign aux_take            = ms_take[2];

    assign ms_word[3*32 +: 32] = cap_word;
    assign ms_valid[3]         = cap_valid;
    assign cap_take            = ms_take[3];

    genvar gm;
    generate
        for (gm = 0; gm < N_SRC; gm = gm + 1) begin : g_master
            msg_master u_m (
                .clk   (clk_ctrl),
                .rst   (rst),
                .word  (ms_word[gm*32 +: 32]),
                .valid (ms_valid[gm]),
                .take  (ms_take[gm]),
                .cyc   (mb_cyc[gm]),
                .stb   (mb_stb[gm]),
                .we    (mb_we[gm]),
                .adr   (mb_adr[gm*32 +: 32]),
                .dat   (mb_dat[gm*32 +: 32]),
                .sel   (mb_sel[gm*4 +: 4]),
                .stall (mb_stall[gm]),
                .ack   (mb_ack[gm])
            );
        end
    endgenerate

    msg_arb #(.N (N_SRC)) u_msg_arb (
        .clk     (clk_ctrl),
        .rst     (rst),
        .m_cyc   (mb_cyc),
        .m_stb   (mb_stb),
        .m_we    (mb_we),
        .m_adr   (mb_adr),
        .m_dat   (mb_dat),
        .m_sel   (mb_sel),
        .m_stall (mb_stall),
        .m_ack   (mb_ack),
        .s_cyc   (sb_cyc),
        .s_stb   (sb_stb),
        .s_we    (sb_we),
        .s_adr   (sb_adr),
        .s_dat   (sb_dat),
        .s_sel   (sb_sel),
        .s_stall (sb_stall),
        .s_ack   (sb_ack)
    );

    // ---- the ring, and the memory port behind it ----------------------------
    // Two clients of wb_arb: the ring's reader at 0 and its writer at 1.  The
    // Apple's memory, when it comes, goes in a strict-priority slot above
    // both; see wb_arb.
    wire [1:0]   c_req, c_gnt, c_cyc, c_stb, c_we, c_stall, c_ack;
    wire [47:0]  c_addr;
    wire [255:0] c_data;
    wire [127:0] c_rdata;

    wb_arb #(.N (2)) u_wb_arb (
        .clk (clk_ctrl), .rst (rst),
        .c_req (c_req), .c_gnt (c_gnt), .c_cyc (c_cyc), .c_stb (c_stb),
        .c_we (c_we), .c_addr (c_addr), .c_data (c_data),
        .c_sel ({16'hFFFF, 16'hFFFF}),
        .c_stall (c_stall), .c_ack (c_ack), .c_rdata (c_rdata),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_addr (wb_addr), .wb_data (wb_data), .wb_sel (wb_sel),
        .wb_aux (wb_aux), .wb_stall (wb_stall), .wb_ack (wb_ack),
        .wb_rdata (wb_rdata), .wb_rdata_aux (wb_rdata_aux)
    );

    assign c_we          = 2'b10;           // the reader reads, the writer writes
    assign c_data[127:0] = 128'd0;          // the reader carries no data

    tx_ring u_ring (
        .clk            (clk_ctrl),
        .rst            (rst),
        .calib_complete (calib_complete),
        .s_cyc          (sb_cyc),
        .s_stb          (sb_stb),
        .s_we           (sb_we),
        .s_adr          (sb_adr),
        .s_dat          (sb_dat),
        .s_sel          (sb_sel),
        .s_stall        (sb_stall),
        .s_ack          (sb_ack),
        .out_word       (tx_word),
        .out_valid      (out_valid),
        .out_take       (!txc_full),
        .rd_req   (c_req[0]),  .rd_gnt (c_gnt[0]),  .rd_cyc (c_cyc[0]),
        .rd_stb   (c_stb[0]),  .rd_addr (c_addr[23:0]),
        .rd_stall (c_stall[0]), .rd_ack (c_ack[0]), .rd_data (c_rdata),
        .wr_req   (c_req[1]),  .wr_gnt (c_gnt[1]),  .wr_cyc (c_cyc[1]),
        .wr_stb   (c_stb[1]),  .wr_addr (c_addr[47:24]), .wr_data (c_data[255:128]),
        .wr_stall (c_stall[1]), .wr_ack (c_ack[1]),
        .status   (ring_status)
    );

    assign tx_push = out_valid && !txc_full;

    // ---- host command channel ---------------------------------------------
    // 'R' resets the FT601, over the Au's own serial bridge - a separate USB
    // device, so it is reachable exactly when the FT601 is not.
    wire [7:0] urx_data;
    wire       urx_valid;

    uart_rx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_uart_rx (
        .clk (clk_ctrl), .rst (~clk_locked),
        .rx (usb_rx), .rx_data (urx_data), .rx_valid (urx_valid)
    );

    assign cmd_reset_strobe = urx_valid && (urx_data == 8'h52 || urx_data == 8'h72);

    // ---- status over UART -------------------------------------------------
    // "C=xxxxxxxx E=x O=x P=x D=x T=x R=xxxxxx" - events captured, capture
    // enabled, overflow, whether phi0 is ticking, whether the DDR3
    // calibrated, whether a message was ever torn on the bus, and the lines
    // the DDR3 ring holds right now.  R is the one number the host cannot
    // report about its own stall - it is the observer that is not stalled.  P is the one that answers
    // "is this card actually in a machine?", which no amount of staring at the
    // USB side will tell you; D answers "is there a link at all?", since every
    // word to the host crosses the DDR3 and a board that cannot calibrate has
    // nothing to say there; T is a can't-happen, reported because can't-
    // happens have to be seen to be fixed.  The UART is the only way to see
    // the card's own view when the FT601 link is the thing under suspicion.
    localparam [7:0] CH_C = 8'h43, CH_E = 8'h45, CH_O = 8'h4F, CH_EQ = 8'h3D;
    localparam [7:0] CH_P = 8'h50, CH_D = 8'h44, CH_T = 8'h54;
    localparam [7:0] CH_SP = 8'h20, CH_CR = 8'h0D, CH_LF = 8'h0A;

    localparam [7:0] CH_R = 8'h52;

    localparam [5:0] RPT_LAST = 6'd40;
    localparam [5:0] RPT_IDLE = 6'd41;

    wire [7:0] uart_data;
    wire       uart_valid, uart_ready;

    reg [21:0] rpt_div  = 22'd0;
    reg [5:0]  rpt_idx  = RPT_IDLE;
    reg [31:0] rpt_cnt  = 32'd0;
    reg        rpt_en   = 1'b0;
    reg        rpt_ovf  = 1'b0;
    reg        rpt_phi  = 1'b0;
    reg        rpt_cal  = 1'b0;
    reg        rpt_torn = 1'b0;
    reg [23:0] rpt_ring = 24'd0;

    always @(posedge clk_ctrl) begin
        if (!clk_locked) begin
            rpt_div <= 22'd0;
            rpt_idx <= RPT_IDLE;
        end else begin
            rpt_div <= rpt_div + 22'd1;
            if (rpt_div == 22'd0 && rpt_idx == RPT_IDLE) begin
                rpt_cnt <= captured;
                rpt_en  <= capture_enable;
                rpt_ovf <= overflow;
                rpt_phi <= phi0_live;
                rpt_cal <= calib_complete;
                rpt_torn <= ring_status[26];
                rpt_ring <= {2'd0, ring_status[21:0]};
                rpt_idx <= 6'd0;
            end else if (uart_valid && uart_ready && rpt_idx != RPT_IDLE) begin
                if (rpt_idx == RPT_LAST) rpt_idx <= RPT_IDLE;
                else                     rpt_idx <= rpt_idx + 6'd1;
            end
        end
    end

    reg [3:0] nib;
    always @(*) begin
        case (rpt_idx)
            6'd2:  nib = rpt_cnt[31:28];
            6'd3:  nib = rpt_cnt[27:24];
            6'd4:  nib = rpt_cnt[23:20];
            6'd5:  nib = rpt_cnt[19:16];
            6'd6:  nib = rpt_cnt[15:12];
            6'd7:  nib = rpt_cnt[11:8];
            6'd8:  nib = rpt_cnt[7:4];
            6'd9:  nib = rpt_cnt[3:0];
            6'd13: nib = {3'b000, rpt_en};
            6'd17: nib = {3'b000, rpt_ovf};
            6'd21: nib = {3'b000, rpt_phi};
            6'd25: nib = {3'b000, rpt_cal};
            6'd29: nib = {3'b000, rpt_torn};
            6'd33: nib = rpt_ring[23:20];
            6'd34: nib = rpt_ring[19:16];
            6'd35: nib = rpt_ring[15:12];
            6'd36: nib = rpt_ring[11:8];
            6'd37: nib = rpt_ring[7:4];
            6'd38: nib = rpt_ring[3:0];
            default: nib = 4'd0;
        endcase
    end

    wire [7:0] hex = (nib < 4'd10) ? (8'h30 + {4'd0, nib})
                                   : (8'h41 + {4'd0, nib} - 8'd10);

    reg [7:0] ch;
    always @(*) begin
        case (rpt_idx)
            6'd0:  ch = CH_C;
            6'd1:  ch = CH_EQ;
            6'd10: ch = CH_SP;
            6'd11: ch = CH_E;
            6'd12: ch = CH_EQ;
            6'd14: ch = CH_SP;
            6'd15: ch = CH_O;
            6'd16: ch = CH_EQ;
            6'd18: ch = CH_SP;
            6'd19: ch = CH_P;
            6'd20: ch = CH_EQ;
            6'd22: ch = CH_SP;
            6'd23: ch = CH_D;
            6'd24: ch = CH_EQ;
            6'd26: ch = CH_SP;
            6'd27: ch = CH_T;
            6'd28: ch = CH_EQ;
            6'd30: ch = CH_SP;
            6'd31: ch = CH_R;
            6'd32: ch = CH_EQ;
            6'd39: ch = CH_CR;
            6'd40: ch = CH_LF;
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

    wire unused_hb = hb_sent;

    assign led[0]   = clk_locked;
    assign led[1]   = capture_enable;
    assign led[2]   = heartbeat[25];
    assign led[3]   = overflow;
    assign led[7:4] = captured[27:24];

endmodule
