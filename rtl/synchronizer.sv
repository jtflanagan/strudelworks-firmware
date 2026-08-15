`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// synchronizer - bring an asynchronous input into this clock domain.
//
// Ported from AppleTini v5 synchronizer.v, with the reset changed from blocking
// to non-blocking assignment.  ASYNC_REG keeps the flops in one slice and tells
// the tools not to retime through them, which is what makes the MTBF argument
// hold rather than merely look right in RTL.
//
// The output register is a third stage: `in` -> sync_regs[0] -> sync_regs[1] ->
// out.  That is deliberate and matches v5, whose sampling taps are counted in
// cycles from a phi0 edge - changing the depth would shift every tap.
//////////////////////////////////////////////////////////////////////////////////

module synchronizer #(
    parameter integer SYNC_STAGES = 2,
    parameter integer WIDTH       = 1
) (
    input  wire              clk,
    input  wire              rst,
    input  wire  [WIDTH-1:0] in,
    output logic [WIDTH-1:0] out
);

    (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] sync_regs [SYNC_STAGES];

    integer i;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < SYNC_STAGES; i = i + 1) begin
                sync_regs[i] <= {WIDTH{1'b0}};
            end
            out <= {WIDTH{1'b0}};
        end else begin
            sync_regs[0] <= in;
            for (i = 1; i < SYNC_STAGES; i = i + 1) begin
                sync_regs[i] <= sync_regs[i-1];
            end
            out <= sync_regs[SYNC_STAGES-1];
        end
    end

endmodule
