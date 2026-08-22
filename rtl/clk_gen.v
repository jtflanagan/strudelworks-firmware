`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// clk_gen - all clocks for the strudelworks design, from the Au's 100 MHz osc.
//
// Written as a direct MMCME2_BASE instantiation rather than a clk_wiz IP core so
// the whole project builds from plain source with no .xci to regenerate.  That is
// the same reason we are not using MIG, applied consistently.
//
// Default: VCO = 100 MHz * 12 / 1 = 1200 MHz
//   clk_ctrl      1200/12 = 100    MHz  -> UberDDR3 i_controller_clk
//   clk_ddr3      1200/3  = 400    MHz  -> UberDDR3 i_ddr3_clk      (DDR3-800)
//   clk_ddr3_90   1200/3  = 400    MHz @ 90 deg -> i_ddr3_clk_90
//   clk_ref       1200/6  = 200    MHz  -> i_ref_clk (IDELAYCTRL, must be 200)
//
// 400 MHz / DDR3-800 is what the v5 MIG build ran on this exact board, so it is
// the target.  If UberDDR3 calibration will not close on it - plausible, because
// bank 15 is an HR bank with no ODELAYE2 and the Arty-S7 reference design for
// this core runs at 333 MHz - drop to the DDR3-667 fallback by overriding the
// parameters below:
//
//   VCO 1000 MHz: MULT=10, DIV_CTRL=12, DIV_DDR3=3, DIV_REF=5
//     -> 83.33 MHz controller / 333.33 MHz DDR3 / 200 MHz ref
//   and set CONTROLLER_CLK_PERIOD=12_000, DDR3_CLK_PERIOD=3_000 to match.
//
// i_ref_clk MUST stay at 200 MHz in either case - IDELAYCTRL tap calibration is
// specified only at 200 MHz.
//////////////////////////////////////////////////////////////////////////////////

module clk_gen #(
    parameter real CLKIN_PERIOD_NS = 10.000,  // 100 MHz Au oscillator
    parameter real MULT            = 12.000,  // -> VCO 1200 MHz
    parameter integer DIV_IN       = 1,
    parameter integer DIV_CTRL     = 12,      // 100 MHz
    parameter integer DIV_DDR3     = 3,       // 400 MHz
    parameter integer DIV_REF      = 6,       // 200 MHz
    parameter real DDR3_90_PHASE   = 90.000
) (
    input  wire clk_in,      // 100 MHz, straight off the pin
    input  wire rst,         // active high, asynchronous
    output wire clk_ctrl,    // controller / user domain
    output wire clk_ddr3,    // DDR3 PHY serdes clock
    output wire clk_ddr3_90, // same, 90 deg shifted (needed when ODELAY absent)
    output wire clk_ref,     // 200 MHz IDELAYCTRL reference
    output wire locked
);

    wire clk_in_buf;
    wire clkfb, clkfb_buf;
    wire clk_ctrl_raw, clk_ddr3_raw, clk_ddr3_90_raw, clk_ref_raw;

    IBUF ibuf_clk (.I(clk_in), .O(clk_in_buf));

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (CLKIN_PERIOD_NS),
        .DIVCLK_DIVIDE      (DIV_IN),
        .CLKFBOUT_MULT_F    (MULT),
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (DIV_CTRL),
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT1_DIVIDE     (DIV_DDR3),
        .CLKOUT1_PHASE      (0.000),
        .CLKOUT1_DUTY_CYCLE (0.500),
        .CLKOUT2_DIVIDE     (DIV_DDR3),
        .CLKOUT2_PHASE      (DDR3_90_PHASE),
        .CLKOUT2_DUTY_CYCLE (0.500),
        .CLKOUT3_DIVIDE     (DIV_REF),
        .CLKOUT3_PHASE      (0.000),
        .CLKOUT3_DUTY_CYCLE (0.500),
        .STARTUP_WAIT       ("FALSE")
    ) mmcm (
        .CLKIN1   (clk_in_buf),
        .CLKFBIN  (clkfb_buf),
        .CLKFBOUT (clkfb),
        .CLKFBOUTB(),
        .CLKOUT0  (clk_ctrl_raw),
        .CLKOUT0B (),
        .CLKOUT1  (clk_ddr3_raw),
        .CLKOUT1B (),
        .CLKOUT2  (clk_ddr3_90_raw),
        .CLKOUT2B (),
        .CLKOUT3  (clk_ref_raw),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (rst)
    );

    BUFG bufg_fb   (.I(clkfb),           .O(clkfb_buf));
    BUFG bufg_ctrl (.I(clk_ctrl_raw),    .O(clk_ctrl));
    BUFG bufg_ddr3 (.I(clk_ddr3_raw),    .O(clk_ddr3));
    BUFG bufg_d90  (.I(clk_ddr3_90_raw), .O(clk_ddr3_90));
    BUFG bufg_ref  (.I(clk_ref_raw),     .O(clk_ref));

endmodule
