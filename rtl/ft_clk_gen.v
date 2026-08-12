`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft_clk_gen - the two phases of the FT601's 100 MHz FIFO clock.
//
// BASELINE VERSION.  Deliberately the simplest thing that works, and the
// configuration in which the link measured byte-perfect at 335 MB/s.  Hardening
// (clock-loss detection, MMCM recovery) goes on top of this in later commits,
// ONE change at a time with an integrity run between each.  An earlier attempt
// landed several at once and regressed the link to a reproducible 1/3 word
// duplication rate that a long bisect could not even attribute - at unchanged
// throughput, so only the sequence check saw it.
//
// Separate from clk_gen.v because this is a different clock SOURCE: clk_gen runs
// off the Au's own 100 MHz oscillator (clk_pin, N14), while this runs off the
// clock the FT601 drives back at us (ft_clk, D4).  The two are unrelated, hence
// the set_clock_groups -asynchronous in constr/ft601.xdc.
//
// Why two phases rather than one clock:
//
//   Signals FROM the FT601 are sampled on the ft_clk rising edge - easy.
//   Signals TO the FT601 must be STABLE at that same rising edge - not easy,
//   because a register clocked on the rising edge only starts changing then.
//
// So outbound registers are clocked 180 degrees away, giving the combinational
// logic a half period to settle before the FT601 looks.  That is the whole
// reason this module exists, and it is the fix v5 arrived at: the earlier
// single-clock ft600_fifo in v5_1_3 does not do this, and the later ft601_test
// project does.  We port the later one.
//
// MMCME2_BASE rather than clk_wiz, for the reason build.tcl gives: no .xci in
// this project, so a fresh clone builds with nothing to regenerate.
//
// NOTE ON ft_clk NOT BEING FREE-RUNNING.  The FT601 drives this clock only once
// it is out of reset with its PLL up, so it is absent at power-on.  An MMCM whose
// RST is released before its reference exists is not guaranteed to lock, and
// MMCME2_BASE cannot report that having happened - CLKINSTOPPED exists only on
// MMCME2_ADV.  In practice it locks here.  Making that guaranteed is exactly the
// hardening deferred to a later commit.
//
//   VCO = 100 MHz * 10 / 1 = 1000 MHz  (inside the Artix-7 -2 range)
//   ft_clk_pos = 1000/10 = 100 MHz @   0 deg  -> sample inbound, run the FSM
//   ft_clk_neg = 1000/10 = 100 MHz @ 180 deg  -> launch outbound
//////////////////////////////////////////////////////////////////////////////////

module ft_clk_gen #(
    parameter real    CLKIN_PERIOD_NS = 10.000,  // 100 MHz FT601 CLKOUT
    parameter real    MULT            = 10.000,  // -> VCO 1000 MHz
    parameter integer DIV_IN          = 1,
    parameter integer DIV_OUT         = 10,      // -> 100 MHz
    // Launch phase for outbound signals, relative to the FT601's sampling edge
    // at 0 deg.  180 deg: data changes on ft_clk's falling edge, so transitions
    // land midway between the chip's sampling edges.
    //
    // This is NOT a timing tuning knob, and must not be used as one.  Closing
    // the interface is the job of the I/O delay constraints in constr/ft601.xdc,
    // which state the chip's real setup/hold requirement and let the tools
    // account for clock insertion delay, buffer delay, skew, jitter and PVT -
    // every one of which they model better than hand arithmetic does.
    //
    // Two attempts at deriving this analytically (248 deg from the chip's timing
    // window alone; then 58 deg after adding output-buffer delay) were both
    // wrong, each accounting for some delay terms while silently dropping
    // others - most obviously the clock's own launch delay.  If the interface
    // does not close, fix the constraints or the RTL, not this number.
    parameter real    NEG_PHASE       = 180.000
) (
    input  wire ft_clk_pin,  // straight off the pin; absent until the chip runs
    input  wire ref_clk,     // ALWAYS running - the Au oscillator domain
    input  wire rst,         // active high, asynchronous
    output wire ft_clk_pos,  // 0 deg
    output wire ft_clk_neg,  // 180 deg
    output wire locked,
    // DIAGNOSIS ONLY.  How many times the clock has been lost AFTER having once
    // been good.  Nothing acts on this - it does not touch the MMCM's reset and
    // cannot perturb the link.  It exists because a dropped ft_clk is otherwise
    // completely invisible from outside the chip, which is what made this board's
    // historical flakiness impossible to characterise.
    //
    // Loss before the first lock is NOT counted: at every power-on the FT601 is
    // still in reset and not clocking yet, which is normal and says nothing.
    output reg [7:0] unlocks
);

    wire ft_clk_buf;
    wire clkfb, clkfb_buf;
    wire pos_raw, neg_raw;

    // ---- lock-loss counter, in the always-running reference domain ----------
    reg [1:0] lock_sync   = 2'b00;
    reg       have_locked = 1'b0;
    reg       locked_prev = 1'b0;

    always @(posedge ref_clk) lock_sync <= {lock_sync[0], locked};
    wire locked_s = lock_sync[1];

    always @(posedge ref_clk) begin
        if (rst) begin
            unlocks     <= 8'd0;
            have_locked <= 1'b0;
            locked_prev <= 1'b0;
        end else begin
            locked_prev <= locked_s;
            if (locked_s) have_locked <= 1'b1;
            if (have_locked && locked_prev && !locked_s && unlocks != 8'hFF) begin
                unlocks <= unlocks + 8'd1;
            end
        end
    end

    IBUF ibuf_ft_clk (.I(ft_clk_pin), .O(ft_clk_buf));

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (CLKIN_PERIOD_NS),
        .DIVCLK_DIVIDE      (DIV_IN),
        .CLKFBOUT_MULT_F    (MULT),
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (DIV_OUT),
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT1_DIVIDE     (DIV_OUT),
        .CLKOUT1_PHASE      (NEG_PHASE),
        .CLKOUT1_DUTY_CYCLE (0.500),
        .STARTUP_WAIT       ("FALSE")
    ) mmcm (
        .CLKIN1   (ft_clk_buf),
        .CLKFBIN  (clkfb_buf),
        .CLKFBOUT (clkfb),
        .CLKFBOUTB(),
        .CLKOUT0  (pos_raw),
        .CLKOUT0B (),
        .CLKOUT1  (neg_raw),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (rst)
    );

    BUFG bufg_fb  (.I(clkfb),   .O(clkfb_buf));
    BUFG bufg_pos (.I(pos_raw), .O(ft_clk_pos));
    BUFG bufg_neg (.I(neg_raw), .O(ft_clk_neg));

endmodule
