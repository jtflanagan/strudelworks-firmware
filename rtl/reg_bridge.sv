`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// reg_bridge - REG_READ / REG_WRITE messages in, a Wishbone cycle, REG_VALUE out.
//
// Sits between ft601_msg_rx and the register Wishbone, and hands its reply to
// tx_arb rather than to the TX FIFO directly - see that module for why a reply
// cannot simply be pushed whenever it is ready.
//
// THE SHAPE OF A REQUEST.  Both request types carry their address as the first
// payload word; a write carries data as the second.  So the parser is a two-slot
// shift register gated on pay_valid, and the message boundary is msg_rx's
// business rather than this module's.
//
//   REG_READ   len=1   [addr]
//   REG_WRITE  len=2   [addr] [data]
//   REG_VALUE  len=2   [addr] [data]     <- card to host, for both
//
// A WRITE IS ACKNOWLEDGED, with the value the register holds AFTERWARDS. That
// costs one extra reply and buys the only cheap way to tell a write that landed
// from a write to a read-only or unimplemented address: the host compares what
// it asked for against what came back. Read-modify-write debugging without it
// means guessing.
//
// ONE OUTSTANDING REQUEST. A second request arriving while one is in flight is
// DROPPED, and dropped silently. The host is strictly request-response here and
// has no reason to pipeline; making this queue would add a buffer, a depth and
// an overflow policy to save a case that does not occur. If the host ever does
// pipeline, the symptom is a missing reply and not a wrong one, because every
// reply carries the address it answers.
//////////////////////////////////////////////////////////////////////////////////
module reg_bridge #(
    parameter [7:0] T_REG_READ  = 8'h14,
    parameter [7:0] T_REG_WRITE = 8'h15
) (
    input  wire        clk,
    input  wire        rst,

    // FROM ft601_msg_rx
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,

    // Register Wishbone master
    output logic        wb_cyc,
    output logic        wb_stb,
    output logic        wb_we,
    output logic [31:0] wb_adr,
    output logic [31:0] wb_dat_w,
    output wire  [3:0]  wb_sel,
    input  wire         wb_ack,
    input  wire         wb_stall,
    input  wire  [31:0] wb_dat_r,

    // TO tx_arb: a two-word reply, offered as a whole and taken when the
    // outgoing stream is between messages.
    output logic [31:0] rsp_addr,
    output logic [31:0] rsp_data,
    output logic        rsp_valid,     // held until rsp_take
    input  wire         rsp_take
);

    assign wb_sel = 4'hF;              // whole words only; see wb_regfile

    typedef enum logic [2:0] {
        S_IDLE,      // waiting for a REG_READ or REG_WRITE header
        S_ADDR,      // header seen, waiting for the address word
        S_DATA,      // write only, waiting for the data word
        S_BUS,       // driving the Wishbone cycle
        S_RSP        // reply formed, waiting for tx_arb to take it
    } state_t;

    state_t state = S_IDLE;
    logic   is_write = 1'b0;

    wire req_read  = msg_valid && (msg_type == T_REG_READ);
    wire req_write = msg_valid && (msg_type == T_REG_WRITE);

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            is_write  <= 1'b0;
            wb_cyc    <= 1'b0;
            wb_stb    <= 1'b0;
            wb_we     <= 1'b0;
            wb_adr    <= 32'd0;
            wb_dat_w  <= 32'd0;
            rsp_addr  <= 32'd0;
            rsp_data  <= 32'd0;
            rsp_valid <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    // A request arriving while a reply is still queued is
                    // dropped - see the note above. Checked here rather than by
                    // gating msg_valid, so the drop is visible in one place.
                    if ((req_read || req_write) && !rsp_valid) begin
                        is_write <= req_write;
                        state    <= S_ADDR;
                    end
                end

                S_ADDR: if (pay_valid) begin
                    wb_adr <= pay_data;
                    if (is_write) begin
                        state <= S_DATA;
                    end else begin
                        wb_cyc <= 1'b1;
                        wb_stb <= 1'b1;
                        wb_we  <= 1'b0;
                        state  <= S_BUS;
                    end
                end

                S_DATA: if (pay_valid) begin
                    wb_dat_w <= pay_data;
                    wb_cyc   <= 1'b1;
                    wb_stb   <= 1'b1;
                    wb_we    <= 1'b1;
                    state    <= S_BUS;
                end

                S_BUS: begin
                    // Drop the strobe once the slave has taken it; hold cyc
                    // until the ack. wb_regfile never stalls, but honouring it
                    // costs one condition and means this bridge is not the
                    // reason a future slave cannot.
                    if (!wb_stall) wb_stb <= 1'b0;
                    if (wb_ack) begin
                        wb_cyc    <= 1'b0;
                        wb_stb    <= 1'b0;
                        // A write replies with what the register reads back
                        // afterwards, which for a read-only address is the old
                        // value - that is the point.
                        rsp_addr  <= wb_adr;
                        rsp_data  <= wb_dat_r;
                        rsp_valid <= 1'b1;
                        state     <= S_RSP;
                    end
                end

                S_RSP: if (rsp_take) begin
                    rsp_valid <= 1'b0;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
