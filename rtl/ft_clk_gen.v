`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft_clk_gen - the two phases of the FT601's 100 MHz FIFO clock, with a lock
// watchdog so a clock that stops and restarts recovers by itself.
//
// Separate from clk_gen.v because this is a different clock SOURCE: clk_gen runs
// off the Au's own 100 MHz oscillator (clk_pin, N14), while this runs off the
// clock the FT601 drives back at us (ft_clk, D4).  The two are unrelated, hence
// the set_clock_groups -asynchronous in constr/ft601.xdc.
//
// Why two phases:
//
//   Signals FROM the FT601 are sampled on the ft_clk rising edge - easy.
//   Signals TO the FT601 must be STABLE at that same rising edge - not easy,
//   because a register clocked on the rising edge only starts changing then.
//
// So outbound registers are clocked 180 degrees away, giving the combinational
// logic a half period to settle before the FT601 looks.
//
// WHY THE WATCHDOG.  ft_clk is not free-running.  The FT601 drives it only once
// it is out of reset with its PLL up, so it is absent at power-on, absent
// whenever the chip is reset, and can stop again later.  An MMCM must be held in
// reset until its reference is stable; one whose RST was released before the
// reference existed may simply never lock.  MMCME2_BASE cannot tell us that
// happened - CLKINSTOPPED exists only on MMCME2_ADV - so nothing would notice
// and nothing would recover.
//
// Rather than detect the clock directly, watch the outcome: if LOCKED has been
// low for longer than a lock could plausibly take, kick RST and try again,
// forever.  That covers "reference arrived late", "reference went away and came
// back" and "MMCM came up in a bad state" with one mechanism and no extra clock
// domain.  While the reference really is absent it just retries harmlessly.
//
// retries counts the kicks.  It is the number worth looking at when the board
// has been flaky: a non-zero, growing count is proof the FT601's clock is
// dropping out, which is otherwise invisible from outside.
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
    // Phase at which outbound registers launch, relative to the FT601's own
    // sampling edge at 0 deg.  Launching at 180 leaves half a period (5 ns) for
    // data to settle before the chip looks.
    //
    // This is the design's real timing knob, and it is NOT comfortably centred.
    // A duplicated word - the chip reading the same value twice - is the
    // signature of data arriving AFTER the sampling edge, so the chip latches
    // the previous one.  Launching earlier buys settling time.  Sweep this if
    // the link duplicates, and see docs/DERISK.md for the measured window.
    parameter real    NEG_PHASE       = 180.000,
    // How long LOCKED must stay low before the watchdog intervenes.
    //
    // Set FAR longer than a lock takes (an MMCM locks in well under a
    // millisecond) because intervening is not free: resetting the MMCM glitches
    // ft_clk_pos/neg, and doing that while the link is streaming corrupts data
    // in flight.  Measured the hard way - at 1 ms this fired often enough to put
    // 336k sequence breaks into an otherwise byte-perfect 335 MB/s stream.
    //
    // The watchdog exists for the case where the clock is GONE and would never
    // come back on its own.  It is not a lock-quality improver, and it must stay
    // out of the way of a working link.
    parameter integer LOCK_TIMEOUT    = 5_000_000,  // 50 ms at 100 MHz
    parameter integer RST_CYCLES      = 64,         // MMCM RST needs >= 5 ns
    // 0 = never touch the MMCM (counters still work).  Bisect switch: see
    // the WATCHDOG_ENABLE branch below.
    parameter integer WATCHDOG_ENABLE = 0
) (
    input  wire ft_clk_pin,  // straight off the pin; may be absent
    input  wire ref_clk,     // ALWAYS running - the Au oscillator domain
    input  wire rst,         // active high, asynchronous
    output wire ft_clk_pos,  // 0 deg
    output wire ft_clk_neg,  // 180 deg
    output wire locked,
    // Diagnosis, not intervention: how many times the clock has been LOST after
    // having once been good.  Counts every unlock event whether or not the
    // watchdog had to act, and ignores the startup period before the first lock
    // (where being unlocked is simply normal).  This is the number that answers
    // "did the FT601's clock drop out?" without perturbing anything.
    output reg [7:0] unlocks,
    output reg [7:0] kicks    // times the watchdog actually reset the MMCM
);

    wire ft_clk_buf;
    wire clkfb, clkfb_buf;
    wire pos_raw, neg_raw;
    wire mmcm_locked;

    assign locked = mmcm_locked;

    // ---- lock watchdog, in the always-running reference domain --------------
    reg        mmcm_rst    = (WATCHDOG_ENABLE != 0);
    reg [22:0] wd_cnt      = 23'd0;
    reg [1:0]  lock_sync   = 2'b00;
    reg        have_locked = 1'b0;   // has it EVER locked since reset?
    reg        locked_prev = 1'b0;

    always @(posedge ref_clk) lock_sync <= {lock_sync[0], mmcm_locked};
    wire locked_s = lock_sync[1];

    always @(posedge ref_clk) begin
        if (rst) begin
            mmcm_rst    <= (WATCHDOG_ENABLE != 0);
            wd_cnt      <= 23'd0;
            kicks       <= 8'd0;
            unlocks     <= 8'd0;
            have_locked <= 1'b0;
            locked_prev <= 1'b0;
        end else begin
            locked_prev <= locked_s;
            if (locked_s) have_locked <= 1'b1;

            // Count losing lock, but only once we had it.  Before the first
            // lock, "not locked" just means the FT601 has not started clocking
            // yet, which is the normal state at every power-on and says nothing
            // about reliability.
            if (have_locked && locked_prev && !locked_s && unlocks != 8'hFF) begin
                unlocks <= unlocks + 8'd1;
            end

            if (WATCHDOG_ENABLE == 0) begin
                // Bisect switch.  With the watchdog disabled this module behaves
                // exactly as the byte-perfect build did - MMCM RST driven only by
                // the module reset - while still counting unlock events, so the
                // diagnosis stays available even when the intervention does not.
                mmcm_rst <= 1'b0;
                wd_cnt   <= 23'd0;
            end else if (mmcm_rst) begin
                if (wd_cnt >= RST_CYCLES[22:0]) begin
                    mmcm_rst <= 1'b0;
                    wd_cnt   <= 23'd0;
                end else begin
                    wd_cnt <= wd_cnt + 23'd1;
                end
            end else if (locked_s || have_locked) begin
                // Locked, or has been locked at some point.  Do nothing, ever.
                //
                // The watchdog's job is ACQUIRING the first lock when the
                // reference shows up late - that is the failure this module
                // exists to fix.  Once the MMCM has proved it can lock to this
                // reference, resetting it again is all cost and no benefit: it
                // re-locks at a different sampling phase relative to the FT601,
                // and the FT601 then samples the write bus at the wrong instant.
                //
                // That is not theoretical.  Kicking a working link produced a
                // steady ~34% duplicated words - the same value arriving twice -
                // in a stream that was byte-perfect before and after.  Throughput
                // was unchanged at 335 MB/s, so it was invisible to every metric
                // except the sequence check.
                //
                // If the reference disappears later, plls_locked drops and the
                // fabric resets cleanly; when it returns the MMCM re-locks by
                // itself, having already demonstrated it can.
                wd_cnt <= 23'd0;
            end else begin
                // Never locked yet.  Keep kicking until the reference appears.
                if (wd_cnt >= LOCK_TIMEOUT[22:0]) begin
                    mmcm_rst <= 1'b1;
                    wd_cnt   <= 23'd0;
                    if (kicks != 8'hFF) kicks <= kicks + 8'd1;
                end else begin
                    wd_cnt <= wd_cnt + 23'd1;
                end
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
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (mmcm_rst)
    );

    BUFG bufg_fb  (.I(clkfb),   .O(clkfb_buf));
    BUFG bufg_pos (.I(pos_raw), .O(ft_clk_pos));
    BUFG bufg_neg (.I(neg_raw), .O(ft_clk_neg));

endmodule
