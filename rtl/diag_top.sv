`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// diag_top - minimal bring-up diagnostic.  NO DDR3.
//
// Exists to answer one question that au_top structurally cannot: after an
// openFPGALoader SRAM load, is the design RUNNING and merely failing DDR3
// calibration, or is it HELD IN RESET?
//
// In au_top those two look identical - led = 0x01 is both the "calibration in
// progress" indicator and the reset value of calib_complete, and the UART is
// gated on calib_complete either way.  So a stuck single LED proves nothing.
//
// This design removes the ambiguity by depending on nothing but configuration,
// the MMCM, and the fabric clock:
//
//   led[0]   = MMCM locked (steady on if the clock tree came up)
//   led[7:1] = free-running counter, visibly sweeping
//   UART     = prints unconditionally, once every ~500 ms, 115200 8N1
//
// Reading the result after `openFPGALoader -b alchitry_au diag_top.bit`:
//
//   blinking + UART  -> load, clocking and fabric are all fine, so the au_top
//                       failure is specific to DDR3 calibration
//   led[0] on, no blink -> MMCM locks but the fabric clock is not running
//   nothing at all   -> configured but held in reset, or not configured
//
// Deliberately does NOT instantiate ddr3_wrapper, so constr/ddr3.xdc must be
// left out of this build (its ports do not exist here).  build/build.sh --diag
// handles that.
//////////////////////////////////////////////////////////////////////////////////

module diag_top (
    input  wire       clk_pin,
    input  wire       rst_n,
    output wire [7:0] led,
    input  wire       usb_rx,
    output wire       usb_tx
);

    wire unused_rx = usb_rx;

    wire clk_ctrl, clk_ddr3, clk_ddr3_90, clk_ref, clk_locked;

    // Same clock generator au_top uses, so a failure here implicates the same
    // MMCM configuration rather than a different one.
    clk_gen u_clk (
        .clk_in      (clk_pin),
        .rst         (~rst_n),
        .clk_ctrl    (clk_ctrl),
        .clk_ddr3    (clk_ddr3),
        .clk_ddr3_90 (clk_ddr3_90),
        .clk_ref     (clk_ref),
        .locked      (clk_locked)
    );

    reg [1:0] rst_sync;
    always @(posedge clk_ctrl or negedge clk_locked) begin
        if (!clk_locked) rst_sync <= 2'b00;
        else             rst_sync <= {rst_sync[0], rst_n};
    end
    wire rst = ~rst_sync[1];

    // ---- visible heartbeat -------------------------------------------------
    // At 100 MHz, bit 25 toggles about every 0.34 s.
    reg [31:0] beat;
    always @(posedge clk_ctrl) begin
        if (rst) beat <= 32'd0;
        else     beat <= beat + 1'b1;
    end

    assign led = {beat[31:25], clk_locked};

    // ---- unconditional UART ------------------------------------------------
    // No calibration gate, no dependency on anything but the clock.
    localparam integer TICK = 50_000_000;   // ~0.5 s at 100 MHz

    localparam integer LEN = 26;
    localparam [LEN*8-1:0] MSG =
        "strudelworks diag alive\015\n";

    reg [31:0] tick;
    reg [7:0]  idx;
    reg        sending;
    reg [7:0]  tx_data;
    reg        tx_valid;
    wire       tx_ready;

    always @(posedge clk_ctrl) begin
        if (rst) begin
            tick <= 32'd0; idx <= 8'd0; sending <= 1'b0;
            tx_valid <= 1'b0; tx_data <= 8'd0;
        end else if (!sending) begin
            tx_valid <= 1'b0;
            if (tick >= TICK - 1) begin
                tick    <= 32'd0;
                idx     <= 8'd0;
                sending <= 1'b1;
            end else begin
                tick <= tick + 1'b1;
            end
        end else if (!tx_valid) begin
            if (idx >= LEN[7:0]) begin
                sending <= 1'b0;
            end else begin
                tx_data  <= MSG[(LEN-1-idx)*8 +: 8];
                tx_valid <= 1'b1;
            end
        end else if (tx_ready) begin
            tx_valid <= 1'b0;
            idx      <= idx + 1'b1;
        end
    end

    uart_tx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_uart (
        .clk(clk_ctrl), .rst(rst),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx(usb_tx)
    );

endmodule
