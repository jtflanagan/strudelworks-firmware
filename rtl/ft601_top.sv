`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_top - FT601 link bring-up.  NO DDR3, no Apple bus.
//
// Streams a 32-bit incrementing counter at the host as fast as the FT601 will
// take it, and discards anything the host sends back.  A counter rather than a
// constant, because it makes both failure modes visible from the host side:
//
//   tools/ft601/ft601_probe bench --sweep   measures how fast it arrives
//   a gap in the sequence                   proves words were dropped
//   a repeat                                proves words were duplicated
//
// Throughput alone cannot tell you the link is CORRECT - a design that drops
// every other word looks fast.  Measured: 335 MB/s, sequence intact.
//
// Ceiling worth knowing: the FT601 runs a 100 MHz FIFO clock over a 32-bit bus,
// so the gateware tops out at 400 MB/s, and USB 3.0 bulk lands near 400-450.
// Those are close enough to trade places, and every FIFO stall comes off the top.
//
// ---------------------------------------------------------------------------
// RECOVERY
//
// This board has a history of wedging in ways that needed the power pulled.  Two
// mechanisms here exist to make that unnecessary, and to make it visible when it
// happens rather than leaving it a mystery:
//
//   1. ft_clk_gen runs a lock watchdog.  ft_clk is not free-running - it exists
//      only while the FT601 is out of reset with its PLL up - so it is absent at
//      power-on and can vanish later.  The watchdog kicks the MMCM until it
//      locks.  Separately it COUNTS every loss of lock after the first good
//      one - a growing count is hard proof the FT601's clock is dropping out,
//      which is otherwise completely invisible.  Counting is free; kicking is
//      not, so the watchdog waits 50 ms before intervening.  At 1 ms it fired
//      often enough to put 336k sequence breaks into a byte-perfect stream.
//
//   2. The FT601 can be reset from the host by sending 'R' on the Au's UART.
//      That path runs over the Au's own serial bridge, which is independent of
//      the FT601 - so it still works precisely when the FT601 is the thing that
//      is stuck.  RESET# is held for a full millisecond, not the few hundred
//      nanoseconds an lock-gated reset would give.
//
// Deliberately NOT automatic: nothing here resets the FT601 on a heuristic.  The
// obvious candidate - "tx FIFO full and TXE# high for a while" - is also the
// normal idle state whenever the host simply is not reading, so an automatic
// reset would fire during healthy idling and cause the very re-enumeration
// storms it was meant to prevent.  Recovery is explicit.
//
// ---------------------------------------------------------------------------
//   led[0]     clk_gen locked (Au oscillator domain)
//   led[1]     ft_clk_gen locked (FT601 is driving its clock at us)
//   led[2]     heartbeat, ~1 Hz - the user domain is running
//   led[3]     TX activity, stretched to be visible
//   led[4]     FIFO reset still busy - MUST go dark shortly after led[0]/led[1]
//   led[5]     RX activity, sticky once the host has ever sent us anything
//   led[6]     FT601 held in reset right now
//   led[7]     STICKY: ft_clk has been LOST at least once since power-on
//
// Failures worth naming, because all of them look like a healthy board:
//
//   led[1] dark        no usable clock from the FT601.  Cable, power or chip
//                      configuration, not a problem in here.
//   led[4] stuck lit   the FIFOs never finished resetting, so ui_din_full is
//                      jammed and not one word will ever be sent.
//   led[7] lit         the clock HAS dropped out at some point.  The link may
//                      look fine now; this is the evidence it was not.  M= in
//                      the UART status frame gives the count.
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

    // Same clk_gen as au_top/diag_top.  Only clk_ctrl is used; the DDR3 outputs
    // are left dangling deliberately so this build exercises the identical MMCM
    // configuration rather than a second, differently-parameterised one.
    clk_gen u_clk (
        .clk_in      (clk_pin),
        .rst         (~rst_n),
        .clk_ctrl    (clk_ctrl),
        .clk_ddr3    (clk_ddr3_unused),
        .clk_ddr3_90 (clk_ddr3_90_unused),
        .clk_ref     (clk_ref_unused),
        .locked      (clk_locked)
    );

    // ---- FT601 chip reset -------------------------------------------------
    // Driven from the Au oscillator domain ALONE.  It must never depend on
    // anything derived from ft_clk - including the ft_clk MMCM's locked flag -
    // because the chip does not drive ft_clk until it is out of reset.  Gating
    // this on that lock is a deadlock: no clock, no lock, no release, no clock.
    // The chip then drops off USB entirely until the FPGA is reprogrammed.
    //
    // clk_locked already folds in rst_n, since clk_gen takes ~rst_n as its reset.
    reg [3:0] chip_rst_sync = 4'b0000;
    always @(posedge clk_ctrl or negedge clk_locked) begin
        if (!clk_locked) chip_rst_sync <= 4'b0000;
        else             chip_rst_sync <= {chip_rst_sync[2:0], 1'b1};
    end

    wire ft_chip_rst_n = chip_rst_sync[3];

    // ---- FT601 clock ------------------------------------------------------
    wire       ft_clk_pos, ft_clk_neg, ft_locked;
    wire [7:0] ft_unlocks;

    ft_clk_gen u_ft_clk (
        .ft_clk_pin (ft_clk),
        .ref_clk    (clk_ctrl),
        .rst        (~rst_n),
        .ft_clk_pos (ft_clk_pos),
        .ft_clk_neg (ft_clk_neg),
        .locked     (ft_locked),
        .unlocks    (ft_unlocks)
    );

    // ---- fabric reset -----------------------------------------------------
    wire plls_locked = clk_locked & ft_locked;

    // Reset must be applied only once BOTH clocks are live, and held long enough
    // for each to clock the assertion through.
    //
    // This is what ft_clk not being free-running actually costs us.
    // xpm_fifo_async runs its reset across both clock domains and only lowers
    // wr_rst_busy / rd_rst_busy once each side has clocked it through.  A reset
    // asserted at configuration lands in a window where the ft_clk domain is
    // dead, so the FIFO's reset never completes, wr_rst_busy stays high forever,
    // ui_din_full is stuck, and not one word is ever written.  Nothing recovers
    // it either.  Symptom: link silent, both MMCMs locked, heartbeat running -
    // everything looks healthy and nothing moves.
    //
    // So: wait for lock, THEN hold reset with both clocks running, THEN release.
    // The counter restarts if lock is ever lost, which also gives clean recovery
    // when ft_clk stops mid-run instead of wedging.
    localparam integer RST_HOLD = 256;   // ~2.6 us, both domains

    reg [8:0] rst_cnt = 9'd0;
    reg       rst_r   = 1'b1;

    always @(posedge clk_ctrl) begin
        if (!plls_locked) begin
            rst_cnt <= 9'd0;
            rst_r   <= 1'b1;
        end else if (rst_cnt != RST_HOLD) begin
            rst_cnt <= rst_cnt + 9'd1;
            rst_r   <= 1'b1;
        end else begin
            rst_r   <= 1'b0;
        end
    end

    wire rst = rst_r;

    // ---- FT601 link -------------------------------------------------------
    wire [31:0] ui_din;
    wire        ui_din_en;
    wire        ui_din_full;
    wire [31:0] ui_dout;
    wire        ui_dout_en;
    wire        ui_dout_empty;
    wire        fifo_rst_busy;
    wire [15:0] dbg;

    // Declared here rather than beside its always block below, because the UART
    // reporter references it first and Vivado will not take a forward reference.
    reg [31:0]  tx_count = 32'd0;

    ft601_fifo u_ft (
        .clk           (clk_ctrl),
        .rst           (rst),
        .ft_clk_pos    (ft_clk_pos),
        .ft_clk_neg    (ft_clk_neg),
        .ft_data       (ft_data),
        .ft_be         (ft_be),
        .ft_rxf        (ft_rxf),
        .ft_txe        (ft_txe),
        .ft_rd         (ft_rd),
        .ft_wr         (ft_wr),
        .ft_oe         (ft_oe),
        .ft_chip_rst_n (ft_chip_rst_n),
        .ft_reset      (ft_reset),
        .ft_wakeup     (ft_wakeup),
        .ui_din        (ui_din),
        .ui_din_en     (ui_din_en),
        .ui_din_full   (ui_din_full),
        .ui_dout       (ui_dout),
        .ui_dout_en    (ui_dout_en),
        .ui_dout_empty (ui_dout_empty),
        .fifo_rst_busy (fifo_rst_busy),
        .dbg           (dbg)
    );

    wire unused_rx = usb_rx;

    // ---- status over UART -------------------------------------------------
    // Emits "S=xxxx C=xxxxxxxx M=xx F=xx" about ten times a second, 115200 8N1.
    // M is the MMCM kick count and F the FT601 reset count - the two numbers that
    // turn "it flaked out again" into something with evidence attached.
    // Decoded by build/ft601_status.sh.
    localparam [7:0] CH_S  = 8'h53, CH_C = 8'h43, CH_M = 8'h4D, CH_EQ = 8'h3D;
    localparam [7:0] CH_SP = 8'h20, CH_CR = 8'h0D, CH_LF = 8'h0A;

    localparam [4:0] RPT_LAST = 5'd23;   // last byte index
    localparam [4:0] RPT_IDLE = 5'd24;

    wire [7:0] uart_data;
    wire       uart_valid, uart_ready;

    reg [21:0] rpt_div     = 22'd0;
    reg [4:0]  rpt_idx     = RPT_IDLE;
    reg [31:0] rpt_cnt     = 32'd0;
    reg [15:0] rpt_dbg     = 16'd0;
    reg [7:0]  rpt_unlocks = 8'd0;


    always @(posedge clk_ctrl) begin
        if (!clk_locked) begin
            rpt_div <= 22'd0;
            rpt_idx <= RPT_IDLE;
        end else begin
            rpt_div <= rpt_div + 22'd1;
            if (rpt_div == 22'd0 && rpt_idx == RPT_IDLE) begin
                // Latch everything at the start of a frame so the printed values
                // all describe the same instant.
                rpt_dbg     <= dbg;
                rpt_cnt     <= tx_count;
                rpt_unlocks <= ft_unlocks;
                rpt_idx     <= 5'd0;
            end else if (uart_valid && uart_ready && rpt_idx != RPT_IDLE) begin
                if (rpt_idx == RPT_LAST) rpt_idx <= RPT_IDLE;
                else                     rpt_idx <= rpt_idx + 5'd1;
            end
        end
    end

    reg [3:0] nib;
    always @(*) begin
        case (rpt_idx)
            5'd2:  nib = rpt_dbg[15:12];
            5'd3:  nib = rpt_dbg[11:8];
            5'd4:  nib = rpt_dbg[7:4];
            5'd5:  nib = rpt_dbg[3:0];
            5'd9:  nib = rpt_cnt[31:28];
            5'd10: nib = rpt_cnt[27:24];
            5'd11: nib = rpt_cnt[23:20];
            5'd12: nib = rpt_cnt[19:16];
            5'd13: nib = rpt_cnt[15:12];
            5'd14: nib = rpt_cnt[11:8];
            5'd15: nib = rpt_cnt[7:4];
            5'd16: nib = rpt_cnt[3:0];
            5'd20: nib = rpt_unlocks[7:4];
            5'd21: nib = rpt_unlocks[3:0];
            default: nib = 4'd0;
        endcase
    end

    wire [7:0] hex = (nib < 4'd10) ? (8'h30 + {4'd0, nib})
                                   : (8'h41 + {4'd0, nib} - 8'd10);

    reg [7:0] ch;
    always @(*) begin
        case (rpt_idx)
            5'd0:  ch = CH_S;
            5'd1:  ch = CH_EQ;
            5'd6:  ch = CH_SP;
            5'd7:  ch = CH_C;
            5'd8:  ch = CH_EQ;
            5'd17: ch = CH_SP;
            5'd18: ch = CH_M;
            5'd19: ch = CH_EQ;
            5'd22: ch = CH_CR;
            5'd23: ch = CH_LF;
            default: ch = hex;
        endcase
    end

    assign uart_data  = ch;
    assign uart_valid = (rpt_idx != RPT_IDLE);

    uart_tx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_uart_tx (
        .clk      (clk_ctrl),
        .rst      (~clk_locked),
        .tx_data  (uart_data),
        .tx_valid (uart_valid),
        .tx_ready (uart_ready),
        .tx       (usb_tx)
    );

    // ---- pattern source ---------------------------------------------------
    // Push whenever there is room.  Backpressure propagates from the host all
    // the way here: the FT601 deasserts ft_txe, the FSM leaves TX, the FIFO
    // fills, ui_din_full rises and the counter simply stops.  Nothing is lost,
    // so a gap seen by the host is always a real bug and never just a stall.
    assign ui_din    = tx_count;
    assign ui_din_en = ~ui_din_full;

    always @(posedge clk_ctrl) begin
        if (rst) tx_count <= 32'd0;
        else if (ui_din_en) tx_count <= tx_count + 32'd1;
    end

    // Drain the host->FPGA direction so it cannot back up and wedge the bus
    // turnaround.  The data is discarded; this build only measures one way.
    assign ui_dout_en = ~ui_dout_empty;

    // ---- status -----------------------------------------------------------
    reg [25:0] heartbeat = 26'd0;
    always @(posedge clk_ctrl) heartbeat <= heartbeat + 26'd1;

    reg [21:0] tx_blink = 22'd0;
    always @(posedge clk_ctrl) begin
        if (rst)            tx_blink <= 22'd0;
        else if (ui_din_en) tx_blink <= 22'h3FFFFF;
        else if (|tx_blink) tx_blink <= tx_blink - 22'd1;
    end

    reg rx_seen = 1'b0;
    always @(posedge clk_ctrl) begin
        if (rst)             rx_seen <= 1'b0;
        else if (ui_dout_en) rx_seen <= 1'b1;
    end

    assign led[0] = clk_locked;
    assign led[1] = ft_locked;
    assign led[2] = heartbeat[25];
    assign led[3] = |tx_blink;
    assign led[4] = fifo_rst_busy;
    assign led[5] = rx_seen;
    assign led[6] = tx_count[24];
    assign led[7] = (ft_unlocks != 8'd0); // STICKY: ft_clk has been lost

endmodule
