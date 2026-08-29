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

    // The top's event stream, already in the wire format - and, with an
    // event, the mark that says it is a frame origin (rtl/vbl_lock.sv):
    // the capture cuts its message there and sends the VBL_MARK notice
    // between.  A watching top ties the mark to 0.
    input  wire [31:0] real_data,
    input  wire        real_valid,
    input  wire        real_mark,
    input  wire [15:0] real_mark_free,
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
    input  wire        hold_runtime,

    // The runtime menu's door into the same hold (docs/RUNTIME_MENU.md):
    // MENU_HOLD's enable, hotkey and the host's knock, for the top's
    // kbd_inject and boot_hold.  A watching top leaves them
    // unconnected and ties hold_runtime to 0.
    output wire        menu_en,
    output wire [6:0]  menu_hotkey,
    output wire        menu_trigger,

    // The hard disk's slot (rtl/hd_card.sv), latched on the RES' edge like
    // the Mockingboard's, and its status back for the HD_SLOT readback.  A
    // watching top ties the inputs to 0.
    output wire [2:0]  hd_slot_active,
    input  wire        hd_rom_loaded,
    input  wire        hd_busy,
    input  wire [7:0]  hd_execs,

    // The floppy (rtl/floppy_card.sv): its slot latched like the disk's,
    // the drives' contents live from FD_DRIVE1/2, and the controller's
    // state back for the readback.  A watching top ties the inputs to 0.
    output wire [2:0]  fd_slot_active,
    input  wire        fd_rom_loaded,
    input  wire [7:0]  fd_seeks,
    output wire [1:0]  fd_inserted,
    output wire [1:0]  fd_wp,
    output wire [25:0] fd_nibbles,
    output wire [11:0] fd_tracks,
    output wire [1:0]  fd_flush,
    input  wire [1:0]  fd_stale,
    input  wire [1:0]  fd_dirty,
    input  wire [13:0] fd_phase,
    input  wire [3:0]  fd_ctl,
    input  wire [7:0]  fd_late,
    input  wire [15:0] fd_fill_max,
    output wire        fd_late_clr,
    output wire        fd_fill_clr,

    // Keyboard injection (rtl/kbd_inject.sv, in a mastering top): the
    // KBD_INJECT register's press and drop pulses and the key out, the
    // KBD_CTRL lock out; the flags {touched, seen, strobe}, the counts
    // {replaced, flushed, taken, pressed}, the key resolved last and the
    // `changed` pulse back - for the readback, and for the KBD_EVENT notice
    // (rtl/kbd_notice.sv).  A watching top ties the inputs to 0.
    output wire        kbd_press,
    output wire [6:0]  kbd_press_key,
    output wire        kbd_drop,
    output wire        kbd_lock,
    input  wire [2:0]  kbd_flags,
    input  wire [31:0] kbd_counts,
    input  wire [6:0]  kbd_resolved_key,
    input  wire        kbd_changed,

    // The pushbuttons (rtl/pb_inject.sv): the BUTTONS register's word out,
    // the hardware's levels back.  A watching top ties the input to 0.
    output wire [5:0]  pb_override,
    input  wire [2:0]  pb_hw,

    // The VBL lock (rtl/vbl_lock.sv): VBL_CTRL's pulses and levels out, the
    // detector's state back for the readback.  A watching top ties the
    // inputs to 0 and leaves the outputs unconnected.
    output wire        vbl_start,
    output wire        vbl_probe,
    output wire        vbl_notify,
    output wire [15:0] vbl_probe_addr,
    input  wire [3:0]  vbl_state,
    input  wire        vbl_locked,
    input  wire        vbl_pal,
    input  wire        vbl_busy,
    input  wire [3:0]  vbl_err,
    input  wire [31:0] vbl_stat,
    input  wire [31:0] vbl_pos,

    // The memory image (rtl/mem_cache.sv in a mastering top, rtl/mem_client.sv
    // here, docs/MEMORY.md): the cache's requests in and its fills out, the
    // registers' levels and pulses out, the counters and state back.  A
    // watching top ties the inputs to 0 and leaves the outputs unconnected.
    input  wire        mem_op_present,
    input  wire        mq_valid,
    input  wire        mq_kind,
    input  wire [1:0]  mq_id,
    input  wire [19:0] mq_line,
    input  wire [3:0]  mq_byte,
    input  wire [7:0]  mq_data,
    output wire        mq_ready,
    output wire        mr_valid,
    output wire [1:0]  mr_id,
    output wire [127:0] mr_data,
    output wire        mem_image_ready,
    output wire         mem_serve,
    output wire        mem_cnt_clr,
    output wire        mem_inval,
    input  wire [11:0] mem_sw,
    input  wire        mem_invalidating,
    input  wire        mem_rom_loaded,
    input  wire [7:0]  mem_late_fills,
    input  wire [7:0]  mem_fifo_drops,
    input  wire [31:0] mem_hits,
    input  wire [31:0] mem_misses,
    input  wire [31:0] mem_mismatch,
    input  wire [31:0] mem_served,
    input  wire [31:0]  mem_last,
    // The mismatch log's seam (rtl/mem_cache.sv <-> wb_regfile).

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

    // ...and a second, the floppy's (FD_SEEK, FD_DIRTY), below the disk's
    // and above the capture.  A watching top ties fd_valid low.
    input  wire [31:0] fd_word,
    input  wire        fd_valid,
    output wire        fd_take,

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
    // The FT601's RESET# needs a MILLISECOND, and it needs it at power-on and
    // after every bitstream load, not only on the host's 'R': the same pin is
    // pulsed for all of them, and the one measurement this project has (a
    // ~40 ns pulse left the chip untouched, 1 ms made it re-enumerate) says a
    // short pulse is not a shorter reset, it is no reset at all.  The 64-tick
    // (640 ns) power-on pulse this used to have was inherited from the
    // reference, where a real power-on resets the chip by its own POR anyway.
    // Here the common case is an SRAM reload with the chip still powered:
    // during configuration its bus floats, whatever the chip made of that
    // stays, and the 640 ns pulse afterwards changed none of it.  So the
    // power-on reset is the same 1 ms as the command reset.
    localparam integer CMD_RST_CYCLES = 100_000;   // 1 ms at 100 MHz
    localparam integer RST_TICKS      = CMD_RST_CYCLES;

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

    // WHY the link was last reset, and what the FT601 side looked like at that
    // instant - kept across the reset it causes, since the reset is exactly
    // what would otherwise erase the evidence.  Reported on the UART as
    // L=c (1 the host's 'R', 2 the watchdog, 4 a malformed message; the
    // latest wins) and S=xxxx: {TXE#, RXF#, skid count[1:0], FSM state[3:0],
    // link resets[7:0]}.  The chip-side signals are sampled from the FT601's
    // clock domain without a synchronizer - a snapshot, not a control path.
    // Last night's wedge read TXE#=1 with words waiting and RXF#=1 with the
    // host writing: a chip whose session engine had stopped.  This is what
    // makes the next one readable without a rebuild.
    wire [3:0] ft_dbg_state;
    wire [1:0] ft_dbg_qcount;
    reg  [2:0] link_cause  = 3'd0;
    reg  [7:0] link_resets = 8'd0;
    reg  [7:0] link_snap   = 8'd0;   // {txe, rxf, qcount, state}

    always @(posedge clk_ctrl) begin
        if (!clk_locked) begin
            link_cause  <= 3'd0;
            link_resets <= 8'd0;
            link_snap   <= 8'd0;
        end else if (link_reset_trigger && !cmd_reset) begin
            link_cause  <= {rx_frame_error, watchdog_fired, cmd_reset_strobe};
            link_resets <= link_resets + 8'd1;
            link_snap   <= {ft_txe, ft_rxf, ft_dbg_qcount, ft_dbg_state};
        end
    end

    wire cmd_reset = (cmd_rst_cnt != 17'd0);

    reg [16:0] tickcount = 17'd0;
    always @(posedge clk_ctrl) begin
        if (!clk_locked)                tickcount <= 17'd0;
        else if (tickcount < RST_TICKS) tickcount <= tickcount + 17'd1;
    end

    wire rst = ~clk_locked | (tickcount < RST_TICKS) | cmd_reset;

    assign ft_reset = ~rst;

    // The reset as the FT601's clock domain sees it.  `rst` is a clk_ctrl
    // signal, and everything clocked by the chip's CLKOUT - the controller,
    // the message layer, the async FIFOs' far sides - can only act on it while
    // that clock is running.  While RESET# is low the chip is in reset and its
    // CLKOUT is not to be relied on, so a reset that is only ever sampled
    // synchronously there may never be seen: the controller would come back
    // with the state it had, skid buffer and all, in front of a chip that has
    // just been wiped.  Asserted asynchronously, released through two flops
    // of the chip's clock, this is seen whether or not CLKOUT ran, and it
    // ends only once CLKOUT is running again.  The reference clears its
    // tickcount64_com on rst for the same purpose (pcileech_com.sv).
    // From a registered copy: an asynchronous assert wants a flop output, not
    // an OR of comparators.
    reg rst_r = 1'b1;
    always @(posedge clk_ctrl) rst_r <= rst;

    reg [1:0] rst_ft_sync = 2'b11;
    always @(posedge ft_clk_i or posedge rst_r) begin
        if (rst_r) rst_ft_sync <= 2'b11;
        else       rst_ft_sync <= {rst_ft_sync[0], 1'b0};
    end
    wire rst_ft = rst_ft_sync[1];

    // Then 16 running cycles more before the FIFOs are let go: XPM documents a
    // five-cycle minimum, and the reference holds for two after its own
    // counter restarts.
    reg [4:0] tickcount_ft = 5'd0;
    always @(posedge ft_clk_i) begin
        if (rst_ft)                     tickcount_ft <= 5'd0;
        else if (tickcount_ft != 5'd16) tickcount_ft <= tickcount_ft + 5'd1;
    end

    wire fifo_rst = rst | rst_ft | (tickcount_ft != 5'd16);

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
        // The memory client says when a bus cycle has room for a refresh:
        // the gate only ever pulls one EARLIER, so this is safe whatever it
        // does (docs/DERISK.md, milestone 2).
        .user_self_refresh (1'b0),
        .refresh_ok        (mem_refresh_ok),
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
        .rst          (rst_ft),
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
        .in_rx        (ft_in_rx),
        .dbg_state    (ft_dbg_state),
        .dbg_qcount   (ft_dbg_qcount)
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
        .rst          (rst_ft),
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
        .clk (ft_clk_i), .rst (rst_ft), .in (hb_shift_ctrl), .out (hb_shift_ft)
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
    // The synthetic source has no scanner, so no frame to mark.
    wire        ev_mark  = source_real && real_mark;

    wire        overflow;
    wire [31:0] captured;

    bus_event_capture u_capture (
        .clk        (clk_ctrl),
        .rst        (rst),
        .enable     (capture_enable),
        .status_req (status_req),
        .ev_data    (ev_data),
        .ev_valid   (ev_valid),
        .ev_mark    (ev_mark),
        .ev_mark_free (real_mark_free),
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

    // KBD_CTRL's notify: the host asking for KBD_EVENT notices.
    wire kbd_notify;
    // The memory client's scheduling outputs.
    wire mem_refresh_ok, mem_rot_ok;

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
        .hold_runtime      (hold_runtime),
        .menu_en           (menu_en),
        .menu_hotkey       (menu_hotkey),
        .menu_trigger      (menu_trigger),
        .hd_slot_active    (hd_slot_active),
        .hd_rom_loaded     (hd_rom_loaded),
        .hd_busy        (hd_busy),
        .hd_execs          (hd_execs),
        .fd_slot_active    (fd_slot_active),
        .fd_rom_loaded     (fd_rom_loaded),
        .fd_seeks          (fd_seeks),
        .fd_inserted       (fd_inserted),
        .fd_wp             (fd_wp),
        .fd_nibbles        (fd_nibbles),
        .fd_tracks         (fd_tracks),
        .fd_flush          (fd_flush),
        .fd_stale          (fd_stale),
        .fd_dirty          (fd_dirty),
        .fd_phase          (fd_phase),
        .fd_ctl            (fd_ctl),
        .fd_late           (fd_late),
        .fd_fill_max       (fd_fill_max),
        .fd_late_clr       (fd_late_clr),
        .fd_fill_clr       (fd_fill_clr),
        .kbd_press         (kbd_press),
        .kbd_press_key     (kbd_press_key),
        .kbd_drop          (kbd_drop),
        .kbd_lock          (kbd_lock),
        .kbd_notify        (kbd_notify),
        .kbd_flags         (kbd_flags),
        .kbd_counts        (kbd_counts),
        .pb_override       (pb_override),
        .pb_hw             (pb_hw),
        .vbl_start         (vbl_start),
        .vbl_probe         (vbl_probe),
        .vbl_notify        (vbl_notify),
        .vbl_probe_addr    (vbl_probe_addr),
        .vbl_state         (vbl_state),
        .vbl_locked        (vbl_locked),
        .vbl_pal           (vbl_pal),
        .vbl_busy          (vbl_busy),
        .vbl_err           (vbl_err),
        .vbl_stat          (vbl_stat),
        .vbl_pos           (vbl_pos),
        .mem_serve         (mem_serve),
        .mem_cnt_clr       (mem_cnt_clr),
        .mem_inval         (mem_inval),
        .mem_sw            (mem_sw),
        .mem_image_ready   (mem_image_ready),
        .mem_invalidating  (mem_invalidating),
        .mem_rom_loaded    (mem_rom_loaded),
        .mem_late_fills    (mem_late_fills),
        .mem_fifo_drops    (mem_fifo_drops),
        .mem_hits          (mem_hits),
        .mem_misses        (mem_misses),
        .mem_mismatch      (mem_mismatch),
        .mem_served        (mem_served),
        .mem_last          (mem_last),
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
    // The one thing the card says unasked: the hold engaged, or let go.  A
    // header-only message, free[0] = held, free[1] = by the runtime door,
    // sent on every edge of `held` - and carrying the levels as they are
    // when the word goes out, so a bounce that flips it twice while a notice
    // waits still ends with the host knowing the truth.  `runtime` moves on
    // the same edge as `held` (boot_hold), so the word never says one
    // without the other.  An edge and a take in the same cycle keep the
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

    // ---- the KBD_EVENT notice -----------------------------------------------
    // The other thing the card says unasked - and only once asked, through
    // KBD_CTRL's notify: a press was resolved, or the lock saw a real key.
    // Two words, and a level like CPU_HOLD's: the words carry the counts and
    // flags as they are when they go out, so a change while a notice waits
    // still ends with the host knowing the truth.  rtl/kbd_notice.sv.
    wire [31:0] kn_word;
    wire        kn_valid, kn_take;

    kbd_notice u_kbd_notice (
        .clk          (clk_ctrl),
        .rst          (rst),
        .changed      (kbd_changed),
        .notify       (kbd_notify),
        .flags        ({kbd_lock, kbd_flags}),
        .resolved_key (kbd_resolved_key),
        .counts       (kbd_counts),
        .word         (kn_word),
        .valid        (kn_valid),
        .take         (kn_take)
    );

    // ---- the message bus ---------------------------------------------------
    // A 32-bit Wishbone with six masters, in priority order: a register
    // reply, the CPU_HOLD notice, the KBD_EVENT notice, the top's
    // application message (the disk's), the floppy's, the capture.  Each
    // source is a stream, and msg_master makes it a master that holds CYC
    // across its message; msg_arb grants per CYC; tx_ring is the one slave.
    // Everything above the capture is rate-bounded by the host or the bus -
    // the floppy's by the machine's own head movements and writes; the
    // capture is the one continuous source and goes last.  See msg_arb for
    // why that order is load-bearing.
    localparam integer N_SRC = 6;

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

    assign ms_word[1*32 +: 32] = {14'd0, hold_runtime, boot_held, T_CPU_HOLD, 8'd0};
    assign ms_valid[1]         = note_pending;
    assign note_take           = ms_take[1];

    assign ms_word[2*32 +: 32] = kn_word;
    assign ms_valid[2]         = kn_valid;
    assign kn_take             = ms_take[2];

    assign ms_word[3*32 +: 32] = aux_word;
    assign ms_valid[3]         = aux_valid;
    assign aux_take            = ms_take[3];

    assign ms_word[4*32 +: 32] = fd_word;
    assign ms_valid[4]         = fd_valid;
    assign fd_take             = ms_take[4];

    assign ms_word[5*32 +: 32] = cap_word;
    assign ms_valid[5]         = cap_valid;
    assign cap_take            = ms_take[5];

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

    // ---- the ring, the memory image, and the port behind them ---------------
    // Three clients of wb_arb: the ring's reader at 0 and its writer at 1, in
    // the rotation; the Apple's memory at 2, the strict-priority slot above
    // it.  The ring's batches are 32 lines so one begun inside the memory
    // client's window (rot_ok) is over before the next bus cycle; see
    // rtl/mem_client.sv and wb_arb.
    wire [2:0]   c_req, c_gnt, c_cyc, c_stb, c_we, c_stall, c_ack;
    wire [71:0]  c_addr;
    wire [383:0] c_data;
    wire [47:0]  c_sel;
    wire [127:0] c_rdata;

    wb_arb #(.N (3), .HAS_PRIO (1'b1)) u_wb_arb (
        .clk (clk_ctrl), .rst (rst), .rot_ok (mem_rot_ok),
        .c_req (c_req), .c_gnt (c_gnt), .c_cyc (c_cyc), .c_stb (c_stb),
        .c_we (c_we), .c_addr (c_addr), .c_data (c_data),
        .c_sel (c_sel),
        .c_stall (c_stall), .c_ack (c_ack), .c_rdata (c_rdata),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_addr (wb_addr), .wb_data (wb_data), .wb_sel (wb_sel),
        .wb_aux (wb_aux), .wb_stall (wb_stall), .wb_ack (wb_ack),
        .wb_rdata (wb_rdata), .wb_rdata_aux (wb_rdata_aux)
    );

    assign c_we[1:0]     = 2'b10;           // the reader reads, the writer writes
    assign c_data[127:0] = 128'd0;          // the reader carries no data
    assign c_sel[31:0]   = {16'hFFFF, 16'hFFFF};

    mem_client u_mem (
        .clk            (clk_ctrl),
        .rst            (rst),
        .calib_complete (calib_complete),
        .master_active  (cpu_source_active),
        .op_present     (mem_op_present),
        .mq_valid (mq_valid), .mq_kind (mq_kind), .mq_id (mq_id),
        .mq_line (mq_line), .mq_byte (mq_byte), .mq_data (mq_data),
        .mq_ready (mq_ready),
        .mr_valid (mr_valid), .mr_id (mr_id), .mr_data (mr_data),
        .req   (c_req[2]),  .gnt (c_gnt[2]),  .cyc (c_cyc[2]),
        .stb   (c_stb[2]),  .we (c_we[2]),
        .addr  (c_addr[71:48]), .data (c_data[383:256]), .sel (c_sel[47:32]),
        .stall (c_stall[2]), .ack (c_ack[2]), .rdata (c_rdata),
        .refresh_ok  (mem_refresh_ok),
        .rot_ok      (mem_rot_ok),
        .mem_idle    (),
        .image_ready (mem_image_ready)
    );

    tx_ring #(.BATCH (32)) u_ring (
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
    // "C=xxxxxxxx E=x O=x P=x D=x T=x R=xxxxxx L=x S=xxxx" - events captured, capture
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
    // L and S are the link's last reset: its cause and the chip-side snapshot
    // taken as it fired (see link_cause above).
    localparam [7:0] CH_C = 8'h43, CH_E = 8'h45, CH_O = 8'h4F, CH_EQ = 8'h3D;
    localparam [7:0] CH_P = 8'h50, CH_D = 8'h44, CH_T = 8'h54;
    localparam [7:0] CH_SP = 8'h20, CH_CR = 8'h0D, CH_LF = 8'h0A;

    localparam [7:0] CH_R = 8'h52, CH_L = 8'h4C, CH_S = 8'h53;

    localparam [5:0] RPT_LAST = 6'd51;
    localparam [5:0] RPT_IDLE = 6'd52;

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
    reg [2:0]  rpt_cause = 3'd0;
    reg [15:0] rpt_snap  = 16'd0;

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
                rpt_cause <= link_cause;
                rpt_snap  <= {link_snap, link_resets};
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
            6'd42: nib = {1'b0, rpt_cause};
            6'd46: nib = rpt_snap[15:12];
            6'd47: nib = rpt_snap[11:8];
            6'd48: nib = rpt_snap[7:4];
            6'd49: nib = rpt_snap[3:0];
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
            6'd39: ch = CH_SP;
            6'd40: ch = CH_L;
            6'd41: ch = CH_EQ;
            6'd43: ch = CH_SP;
            6'd44: ch = CH_S;
            6'd45: ch = CH_EQ;
            6'd50: ch = CH_CR;
            6'd51: ch = CH_LF;
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
