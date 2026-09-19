`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft_clk_buf - bring the FT601's FIFO clock into the fabric.  Nothing else.
//
// The reference (ufrisk/pcileech-fpga) feeds ft601_clk straight in as its
// communication-core clock: no MMCM, no phase shift, one posedge domain.  This is
// the equivalent, and the whole module.
//
// It used to also detect whether the clock was running and count dropouts, to
// gate the design's reset.  Both are gone.  The reference gates reset on nothing
// but power-on, and handles the async FIFO's need for a live far clock where it
// belongs - by qualifying that FIFO's reset with a counter clocked in the far
// domain (see ft601_top.sv).  Making reset a standing function of clock presence
// turned every normal idle - the FT601 gates CLKOUT whenever USB is idle or
// suspended - into a full datapath reset.
//////////////////////////////////////////////////////////////////////////////////

module ft_clk_buf (
    input  wire ft_clk_pin,  // straight off the pin
    output wire ft_clk       // buffered, the single FT601 clock domain
);

    wire ft_clk_ibuf;

    IBUF ibuf_ft_clk (.I(ft_clk_pin), .O(ft_clk_ibuf));
    BUFG bufg_ft_clk (.I(ft_clk_ibuf), .O(ft_clk));

endmodule
