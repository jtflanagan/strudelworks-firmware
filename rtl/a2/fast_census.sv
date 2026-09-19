`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// fast_census - the seven counters behind ACCEL_FAST_I .. ACCEL_FAST_KBD.
//
// rtl/accel_seq.sv decides one bucket per retired dispatcher op (cen_v, cen_sel)
// and this module counts, one clock later still, from a registered copy: the
// sequencer keeps four wires and no adders, and the 224 flops with their
// carry chains live wherever the register file does - a clock region away
// from the data front's serve-byte cone, which is where the first cut's
// counters landed and cost 0.4 ns of route (docs/ACCELERATION.md, "The
// census").  The buckets are exclusive and sum to ACCEL_FAST; `clr` is the
// same W1 pulse that clears the other ACCEL_* counters.
//////////////////////////////////////////////////////////////////////////////////
module fast_census (
    input  wire        clk,
    input  wire        rst,
    input  wire        clr,
    input  wire        v,             // one clock: a dispatcher op retired
    input  wire [2:0]  sel,           // 0 I, 1 RAM, 2 LC, 3 ROM $D000+, 4 ROM $Cxxx, 5 write, 6 keyboard
    output logic [31:0] fast_i,
    output logic [31:0] fast_dram,
    output logic [31:0] fast_dlc,
    output logic [31:0] fast_drom,
    output logic [31:0] fast_dcx,
    output logic [31:0] fast_wr,
    output logic [31:0] fast_kbd
);
    logic       v_q;
    logic [2:0] sel_q;
    always_ff @(posedge clk) begin
        v_q   <= v && !rst;
        sel_q <= sel;
        if (rst || clr) begin
            fast_i <= 32'd0; fast_dram <= 32'd0; fast_dlc <= 32'd0; fast_drom <= 32'd0;
            fast_dcx <= 32'd0; fast_wr <= 32'd0; fast_kbd <= 32'd0;
        end else if (v_q) begin
            case (sel_q)
                3'd0: fast_i    <= fast_i + 32'd1;
                3'd1: fast_dram <= fast_dram + 32'd1;
                3'd2: fast_dlc  <= fast_dlc + 32'd1;
                3'd3: fast_drom <= fast_drom + 32'd1;
                3'd4: fast_dcx  <= fast_dcx + 32'd1;
                3'd5: fast_wr   <= fast_wr + 32'd1;
                default: fast_kbd <= fast_kbd + 32'd1;
            endcase
        end
    end
endmodule
