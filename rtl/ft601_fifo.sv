`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_fifo - FT601 / FT245 synchronous FIFO controller.
//
// A functional port of pcileech_ft601.sv from ufrisk/pcileech-fpga (Ulf Frisk),
// which drives this chip at 100 MHz in a shipped design.  States, signal
// polarities, bus-ownership policy, queue behaviour and exit conditions all
// follow the original; only identifiers are renamed to this project's ports.
//
// Every place an earlier version of this file diverged from that structure
// produced a bug at the burst boundary - a registered TXE#, a four-state machine,
// tristate-by-default, an empty output queue, an acknowledge-based pop.  None of
// them are reintroduced.
//
// Despite the filename this module contains NO FIFO.  The reference keeps the
// clock-domain crossing outside the FT601 controller and so does this: ft601_top
// holds the async FIFOs, and everything here runs in the single ft_clk domain.
//
// Signal naming: this project's ft_rxf / ft_txe / ft_rd / ft_wr / ft_oe are the
// chip's active-low RXF# / TXE# / RD# / WR# / OE# - the same signals as the
// reference's FT601_*_N, without the suffix.
//////////////////////////////////////////////////////////////////////////////////

module ft601_fifo (
    input  wire         clk,          // the FT601's FIFO clock
    input  wire         rst,

    // TO/FROM PADS
    output wire  [3:0]  ft_be,
    inout  wire  [31:0] ft_data,
    input  wire         ft_rxf,       // RXF#
    input  wire         ft_txe,       // TXE#
    output logic        ft_oe,        // OE#
    output logic        ft_rd,        // RD#
    output logic        ft_wr,        // WR#
    output wire         ft_wakeup,    // WAKEUP#, held inactive

    // TO/FROM FIFO
    output logic [31:0] dout,
    output logic        dout_valid,
    input  wire  [31:0] din,
    input  wire         din_wr_en,
    output wire         din_req_data
);

    initial begin
        ft_oe      <= 1'b1;
        ft_rd      <= 1'b1;
        ft_wr      <= 1'b1;
        dout_valid <= 1'b0;
        dout       <= 32'h00000000;
    end

    // The reference ties SIWU# inactive and never changes it.  This board brings
    // out WAKEUP# rather than SIWU#; same treatment, and driven rather than left
    // floating.
    assign ft_wakeup = 1'b1;

    localparam [3:0] S_IDLE         = 4'h0;
    localparam [3:0] S_RX_WAIT1     = 4'h2;
    localparam [3:0] S_RX_WAIT2     = 4'h3;
    localparam [3:0] S_RX_WAIT3     = 4'h4;
    localparam [3:0] S_RX_ACTIVE    = 4'h5;
    localparam [3:0] S_RX_COOLDOWN1 = 4'h6;
    localparam [3:0] S_RX_COOLDOWN2 = 4'h7;
    localparam [3:0] S_TX_WAIT1     = 4'h8;
    localparam [3:0] S_TX_WAIT2     = 4'h9;
    localparam [3:0] S_TX_ACTIVE    = 4'ha;
    localparam [3:0] S_TX_COOLDOWN1 = 4'hb;
    localparam [3:0] S_TX_COOLDOWN2 = 4'hc;

                        logic [31:0] DATA_OUT [5];
    (* KEEP = "TRUE" *) wire         FWD;
    (* KEEP = "TRUE" *) logic        OE                  = 1'b1;
    (* KEEP = "TRUE" *) logic [3:0]  data_cooldown_count = 4'h0;
    (* KEEP = "TRUE" *) logic [2:0]  data_queue_count    = 3'h0;
    (* KEEP = "TRUE" *) logic [3:0]  state               = S_IDLE;

    // -------------------------------------------------------------------------
    // FT245 RX / DATA INPUT
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        dout_valid  <= !rst && !ft_rxf && (state == S_RX_ACTIVE);
        dout[7:0]   <= ft_data[31:24];
        dout[15:8]  <= ft_data[23:16];
        dout[23:16] <= ft_data[15:8];
        dout[31:24] <= ft_data[7:0];
    end

    // -------------------------------------------------------------------------
    // FT245 TX / DATA OUTPUT
    //
    // OE drives the bus by DEFAULT and releases it only for RX, so the bus is not
    // turned around on every transmit burst.
    // -------------------------------------------------------------------------

    assign ft_be        = OE ? 4'b1111 : 4'bzzzz;
    assign ft_data      = OE ? {DATA_OUT[0][7:0],   DATA_OUT[0][15:8],
                                DATA_OUT[0][23:16], DATA_OUT[0][31:24]} : 32'hzzzzzzzz;
    assign din_req_data = !rst && (data_queue_count == 3'h2) || (data_queue_count == 3'h3);
    assign FWD          = !rst && !ft_txe && (data_queue_count != 3'h0) && (state == S_TX_ACTIVE);

    always_ff @(posedge clk) begin
        if (rst || (data_cooldown_count == 4'hf)) begin
            data_cooldown_count <= 4'h0;
            data_queue_count    <= 3'h5;
            DATA_OUT[0]         <= 32'h66665555;
            DATA_OUT[1]         <= 32'h66665555;
            DATA_OUT[2]         <= 32'h66665555;
            DATA_OUT[3]         <= 32'h66665555;
            DATA_OUT[4]         <= 32'h66665555;
        end else begin
            data_cooldown_count <= (data_queue_count == 3'h0) ? (data_cooldown_count + 4'h1) : 4'h0;
            data_queue_count    <= data_queue_count + (din_wr_en ? 3'h1 : 3'h0) - (FWD ? 3'h1 : 3'h0);
            if (FWD) begin
                if (data_queue_count > 3'h1) DATA_OUT[0] <= DATA_OUT[1];
                if (data_queue_count > 3'h2) DATA_OUT[1] <= DATA_OUT[2];
                if (data_queue_count > 3'h3) DATA_OUT[2] <= DATA_OUT[3];
                if (data_queue_count > 3'h4) DATA_OUT[3] <= DATA_OUT[4];
            end
            if (din_wr_en) begin
                DATA_OUT[data_queue_count - (FWD ? 3'h1 : 3'h0)] <= din;
            end
        end
    end

    // -------------------------------------------------------------------------
    // FT245 main control
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        OE    <= (rst || ft_rxf || ((state != S_RX_ACTIVE)    && (state != S_RX_WAIT3) &&
                                    (state != S_RX_WAIT2)     && (state != S_RX_COOLDOWN1) &&
                                    (state != S_RX_COOLDOWN2)));
        ft_oe <= (rst || ft_rxf || ((state != S_RX_ACTIVE)    && (state != S_RX_WAIT3) &&
                                    (state != S_RX_WAIT2)));
        ft_rd <= (rst || ft_rxf || ((state != S_RX_ACTIVE)    && (state != S_RX_WAIT3)));
        ft_wr <= !(!rst && !ft_txe && ((state == S_TX_WAIT2) ||
                                       ((state == S_TX_ACTIVE) &&
                                        (din_wr_en || (data_queue_count > 3'h1)))));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                // RX is prioritised above TX when both are available.
                S_IDLE:
                    if (!ft_rxf)                                    state <= S_RX_WAIT1;
                    else if (!ft_txe && (data_queue_count > 3'h0))  state <= S_TX_WAIT1;

                // RX.  The receiver is assumed never full; if it is, data is
                // still received and lost.
                S_RX_WAIT1:     state <= ft_rxf ? S_RX_COOLDOWN1 : S_RX_WAIT2;
                S_RX_WAIT2:     state <= ft_rxf ? S_RX_COOLDOWN1 : S_RX_WAIT3;
                S_RX_WAIT3:     state <= ft_rxf ? S_RX_COOLDOWN1 : S_RX_ACTIVE;
                S_RX_ACTIVE:    state <= ft_rxf ? S_RX_COOLDOWN1 : S_RX_ACTIVE;
                S_RX_COOLDOWN1: state <= S_RX_COOLDOWN2;
                S_RX_COOLDOWN2: state <= S_IDLE;

                // TX.
                S_TX_WAIT1:     state <= ft_txe ? S_TX_COOLDOWN1 : S_TX_WAIT2;
                S_TX_WAIT2:     state <= ft_txe ? S_TX_COOLDOWN1 : S_TX_ACTIVE;
                S_TX_ACTIVE:    state <= (ft_txe || (!din_wr_en && (data_queue_count <= 3'h1)))
                                            ? S_TX_COOLDOWN1 : S_TX_ACTIVE;
                S_TX_COOLDOWN1: state <= S_TX_COOLDOWN2;
                S_TX_COOLDOWN2: state <= S_IDLE;

                default:        state <= S_IDLE;
            endcase
        end
    end

endmodule
