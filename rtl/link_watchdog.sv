`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// link_watchdog - is the host still there?
//
// Armed when a capture is enabled, disarmed on a clean stop and by reset.  While
// armed, ANY well-formed message resets it - not only heartbeats.  A host that is
// talking anyway needs to send nothing extra; the 100 ms IDLE heartbeat exists so
// that a host with nothing to say still holds the link open.
//
// Expiry means the host is gone mid-capture, which is treated as loss of sync and
// is not recoverable: the top level turns `fired` into a full FT601 reset,
// discarding unsent events and the chip's own buffers.  That is heavy on purpose.
// The clean stop (BUS_ENABLE with enable=0) exists so a normal shutdown never
// comes through here - this path is for hosts that die, not hosts that finish.
//
// Note it is NOT armed before the first capture.  A watchdog running against a
// host that has not connected yet would reset the link once a second forever.
//////////////////////////////////////////////////////////////////////////////////

module link_watchdog #(
    // 1 second at 100 MHz.
    parameter integer TIMEOUT_CYCLES = 100_000_000
) (
    input  wire  clk,
    input  wire  rst,

    input  wire  arm,          // a capture was enabled
    input  wire  disarm,       // clean stop
    input  wire  kick,         // a well-formed message arrived

    output logic armed,
    output wire  fired
);

    localparam integer W = $clog2(TIMEOUT_CYCLES + 1);

    logic [W-1:0] count = '0;

    // Expiry is a level, not a pulse: the top level feeds it into the same 1 ms
    // reset stretcher the 'R' command uses, and that stretcher wants a trigger it
    // can latch.  It self-clears because the reset it causes clears `armed`.
    assign fired = armed && (count == TIMEOUT_CYCLES[W-1:0]);

    always_ff @(posedge clk) begin
        if (rst) begin
            armed <= 1'b0;
            count <= '0;
        end else begin
            if (disarm) begin
                armed <= 1'b0;
                count <= '0;
            end else if (arm) begin
                armed <= 1'b1;
                count <= '0;               // arming is itself a kick
            end else if (!armed) begin
                count <= '0;
            end else if (kick) begin
                count <= '0;
            end else if (count != TIMEOUT_CYCLES[W-1:0]) begin
                count <= count + 1'b1;
            end
        end
    end

endmodule
