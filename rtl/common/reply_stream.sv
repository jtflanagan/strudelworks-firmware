`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// reply_stream - a register reply, offered to msg_arb as a stream.
//
// reg_bridge forms a reply as two words held on a level, rsp_valid, until
// rsp_take acknowledges them; msg_arb wants a message a word at a time on a
// valid/take port.  This is the three-word adapter between the two: header,
// address, data.
//
// The guard on rsp_take is the one tx_arb carried.  rsp_take is registered,
// so for the one cycle it is high the bridge has not yet seen it and
// rsp_valid is still asserted - which looks exactly like a fresh reply.
// Without the guard every reply goes out twice, and the host reads the
// duplicate as the answer to whatever it asks next.
//////////////////////////////////////////////////////////////////////////////////
module reply_stream #(
    parameter [7:0] T_REG_VALUE = 8'h16
) (
    input  wire        clk,
    input  wire        rst,

    // FROM reg_bridge.  rsp_valid is held until rsp_take.
    input  wire [31:0] rsp_addr,
    input  wire [31:0] rsp_data,
    input  wire        rsp_valid,
    output logic       rsp_take,

    // TO msg_arb.
    output wire [31:0] word,
    output wire        valid,
    input  wire        take
);

    logic [1:0] idx = 2'd0;      // 0 = header, 1 = address, 2 = data

    assign valid = rsp_valid && !rsp_take;
    assign word  = (idx == 2'd0) ? {16'd0, T_REG_VALUE, 8'd2} :
                   (idx == 2'd1) ? rsp_addr : rsp_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            idx      <= 2'd0;
            rsp_take <= 1'b0;
        end else begin
            rsp_take <= 1'b0;
            if (valid && take) begin
                if (idx == 2'd2) begin
                    idx      <= 2'd0;
                    rsp_take <= 1'b1;
                end else begin
                    idx <= idx + 2'd1;
                end
            end
        end
    end

endmodule
