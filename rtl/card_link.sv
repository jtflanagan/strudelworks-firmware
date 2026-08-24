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

    // bus_event_capture -> tx_arb -> tx_fifo.  The arbiter is in the middle so a
    // register reply can be slipped in between whole messages; see tx_arb.
    wire [31:0] cap_word;
    wire        cap_push;
    wire        cap_full;
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
    link_watchdog u_wd (
        .clk    (clk_ctrl),
        .rst    (rst),
        .arm    (want_enable),
        .disarm (want_disable),
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
        .tx_push    (cap_push),
        .tx_full    (cap_full),
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

    tx_arb u_tx_arb (
        .clk       (clk_ctrl),
        .rst       (rst),
        .src_data  (cap_word),
        .src_push  (cap_push),
        .src_full  (cap_full),
        .rsp_addr  (rsp_addr),
        .rsp_data  (rsp_data),
        .rsp_valid (rsp_valid),
        .rsp_take  (rsp_take),
        .tx_data   (tx_word),
        .tx_push   (tx_push),
        .tx_full   (txc_full)
    );

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
    // "C=xxxxxxxx E=x O=x P=x" - events captured, capture enabled, overflow, and
    // whether phi0 is ticking.  P is the one that answers "is this card actually
    // in a machine?", which no amount of staring at the USB side will tell you.
    // The
    // UART is the only way to see the card's own view when the FT601 link is the
    // thing under suspicion.
    localparam [7:0] CH_C = 8'h43, CH_E = 8'h45, CH_O = 8'h4F, CH_EQ = 8'h3D;
    localparam [7:0] CH_P = 8'h50;
    localparam [7:0] CH_SP = 8'h20, CH_CR = 8'h0D, CH_LF = 8'h0A;

    localparam [4:0] RPT_LAST = 5'd23;
    localparam [4:0] RPT_IDLE = 5'd24;

    wire [7:0] uart_data;
    wire       uart_valid, uart_ready;

    reg [21:0] rpt_div  = 22'd0;
    reg [4:0]  rpt_idx  = RPT_IDLE;
    reg [31:0] rpt_cnt  = 32'd0;
    reg        rpt_en   = 1'b0;
    reg        rpt_ovf  = 1'b0;
    reg        rpt_phi  = 1'b0;

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
                rpt_idx <= 5'd0;
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
            5'd13: nib = {3'b000, rpt_en};
            5'd17: nib = {3'b000, rpt_ovf};
            5'd21: nib = {3'b000, rpt_phi};
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
            5'd11: ch = CH_E;
            5'd12: ch = CH_EQ;
            5'd14: ch = CH_SP;
            5'd15: ch = CH_O;
            5'd16: ch = CH_EQ;
            5'd18: ch = CH_SP;
            5'd19: ch = CH_P;
            5'd20: ch = CH_EQ;
            5'd22: ch = CH_CR;
            5'd23: ch = CH_LF;
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
    wire unused_len = |msg_len;

    assign led[0]   = clk_locked;
    assign led[1]   = capture_enable;
    assign led[2]   = heartbeat[25];
    assign led[3]   = overflow;
    assign led[7:4] = captured[27:24];

endmodule
