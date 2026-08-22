`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// synth_bus_events - stand-in Apple bus traffic, for a card that is not in an
// Apple II.
//
// Emits events shaped exactly like the real ones (see the field map below, ported
// from AppleTini v5 bus_event_manager.sv) at a settable rate, defaulting to the
// ~1.023 MHz Phi0 of a legacy machine.
//
// The point is not to look plausible, it is to be CHECKABLE.  A 24-bit sequence
// number is spread across the address and data fields, so the host can prove a
// dump is complete rather than merely non-empty - the same reasoning as the
// counter in ft601_top, where throughput alone certified nothing and the sequence
// check was what distinguished a working link from a fast broken one.
//
// It stays in the design once the real apple_bus_wrapper is ported: a self-test
// with known-good content is the only way to tell a suspect capture from a
// suspect capturer.
//
//   [15:0]  addr        seq[15:0]
//   [19:16] ctl         {m2b0, m2sel, res, rw} - here a fixed pattern
//   [27:20] data        seq[23:16]
//   [31:28] tag         0xF, as the v5 format
//////////////////////////////////////////////////////////////////////////////////

module synth_bus_events #(
    // Clocks between events.  98 at 100 MHz is ~1.02 MHz, a legacy Apple II Phi0.
    // A IIgs would be 36 (~2.8 MHz).
    parameter integer PERIOD = 98
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,

    output logic [31:0] ev_data,
    output logic        ev_valid
);

    localparam integer W = $clog2(PERIOD + 1);

    logic [W-1:0]  tick = '0;
    logic [23:0]   seq  = 24'd0;

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            tick     <= '0;
            seq      <= 24'd0;
            ev_valid <= 1'b0;
        end else begin
            ev_valid <= 1'b0;
            if (tick == PERIOD[W-1:0] - 1'b1) begin
                tick     <= '0;
                seq      <= seq + 24'd1;
                ev_valid <= 1'b1;
                // rw toggles with the sequence so the control nibble is not
                // constant; the rest is fixed, which is what a decoder would see
                // on a machine doing something repetitive.
                ev_data  <= {4'hf, seq[23:16], 3'b010, seq[0], seq[15:0]};
            end else begin
                tick <= tick + 1'b1;
            end
        end
    end

endmodule
