`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ssi263 - one SSI-263 speech chip's bus-visible half, on the card.
//
// The Phasor has two sockets for Silicon Systems' SSI-263 phoneme
// synthesiser (a Mockingboard C has them too).  The 6502 writes it five
// registers - duration/phoneme, inflection, rate/inflection,
// control/articulation/amplitude, filter - and the chip speaks the phoneme,
// over and over, until told another; when a phoneme finishes it raises
// A/!R, which is the interrupt every speech driver lives on, and mirrors
// it in D7, the one bit the chip drives on a read.  The split follows the
// Mockingboard's: the SOUND is the host's (strudelworks-host src/ssi263.cpp
// plays AppleWin's phoneme samples from the same writes in the stream);
// what is here is everything the bus can see - the registers' effect on
// D7 and A/!R, and above all WHEN a phoneme completes, because the
// software times that (mb-audit's SSI263 tests, Willy Byte's detection,
// every speech ISR) and a phoneme-complete that depends on host latency
// would fail them.
//
// AppleWin's SSI263.cpp is the reference throughout, and the timing IS
// AppleWin's: the chip's real duration arithmetic (the RATE register, the
// datasheet's frame period) is not modelled there - a phoneme lasts as
// long as its sample, and the samples are AppleWin's - so the host cannot
// play anything else, and the card must complete when the host's sample
// runs out.  A phoneme is therefore a length in 22050 Hz samples
// (phoneme_len below, from AppleWin's SSI263Phonemes.h; phonemes 0 and 1
// have no sample: 1 plays as 2, 0 is a silent pause as long as 2's), and
// the DUR bits set how fast it is consumed, per AppleWin's Update():
//
//   DUR 0   one sample per output sample          (100%, the datasheet's)
//   DUR 1   one, plus an extra one every fourth   (~75%)
//   DUR 2   two per output sample                 (50%)
//   DUR 3   four                                  (25%)
//   frame mode (function 1)   always four, whatever DUR says
//
// A phoneme completes when its samples are consumed; then a LEADOUT of a
// tenth of its length (AppleWin's guess, kept so the two halves agree),
// and then it plays again, unless the chip was powered down (CTL=1) in
// the meantime, in which case it parks until CTL goes low again.
//
// Output samples are 22050 per second of MACHINE time - the core's cycles,
// as the VIA timers count them (rtl/mockingboard.sv): TICK_NUM ticks per
// TICK_DEN cycles, 22050 per 1020408 (100 MHz / 98, the card's phi0).  A
// detection routine that waits a known number of cycles for D7 sees the
// same answer at 1x and at 50x, which is the whole point of virtual time.
//
// The interrupt (AppleWin's SetSpeechIRQ, and mb-audit's findings):
//   * completion sets D7 (unless powered down), whatever the mode bits say
//   * A/!R is driven only when interrupts are enabled (DR1:0 != 00 at the
//     last CTL high-to-low); it is the inverse of D7 then, high otherwise
//   * a write to register 0, 1 or 2 clears D7 (and so A/!R); so does CTL=1;
//     CTL high-to-low never touches them (it came from power-down, where
//     they were already clear); registers 4-7 and CTL=0 leave them alone
//   * CTL high-to-low sets the function and the interrupt enable from the
//     duration register AS IT STANDS, and starts its phoneme
// Where A/!R goes is the Phasor's GAL's business and the parent's: in
// Mockingboard mode to a VIA's CA1 (the primary chip's to VIA 1's, the
// secondary's to VIA 0's - a negative edge, the flag in IFR bit 1 under
// PCR bit 0 = 0), in native mode straight to the 6502's IRQ'.  Both leave
// this module as levels (ca1_n idle high, irq active high); the VIA's own
// edge detector does the rest, which is how the chip's D7 being already
// set when the mode changes to Mockingboard raises the flag there, as
// AppleWin's SetCardMode arranges by hand.
//
// RES' (the parent's reset): the SSI263AP - AppleWin's default part, and
// the one whose reset behaviour mb-audit sorts a Phasor's chips by - goes
// to power-down with its registers at their power-on values and nothing
// playing; the P variant that plays on through a reset is not modelled.
//////////////////////////////////////////////////////////////////////////////////
module ssi263 #(
    parameter integer TICK_NUM = 22050,     // output samples...
    parameter integer TICK_DEN = 1020408    // ...per this many core cycles
) (
    input  wire        clk,
    input  wire        rst,             // power-on, RES', the card disabled

    // One core cycle (the VIA's slow_clock): the sample clock counts these.
    input  wire        slow_clock,

    // A register write: strobe, register (A2-A0), byte.
    input  wire        wr_strobe,
    input  wire [2:0]  wr_reg,
    input  wire [7:0]  wr_data,

    // D7, the one bit a read returns.
    output wire        d7,
    // A/!R as a level, for a VIA's CA1: low while requesting.  Idle high.
    output wire        ar_n,

    // The sample tick, for a bench to count.
    output logic       tick
);

    // ---- the phoneme lengths ------------------------------------------------
    // AppleWin's g_nPhonemeInfo[].nLength, in samples, indexed by phoneme-2.
    function automatic logic [11:0] phoneme_len(input logic [5:0] idx);
        case (idx)
            6'd0: phoneme_len = 12'd2656;
            6'd1: phoneme_len = 12'd2636;
            6'd2: phoneme_len = 12'd2594;
            6'd3: phoneme_len = 12'd2707;
            6'd4: phoneme_len = 12'd2746;
            6'd5: phoneme_len = 12'd2630;
            6'd6: phoneme_len = 12'd2644;
            6'd7: phoneme_len = 12'd3203;
            6'd8: phoneme_len = 12'd2639;
            6'd9: phoneme_len = 12'd2709;
            6'd10: phoneme_len = 12'd2593;
            6'd11: phoneme_len = 12'd2577;
            6'd12: phoneme_len = 12'd2548;
            6'd13: phoneme_len = 12'd2705;
            6'd14: phoneme_len = 12'd2620;
            6'd15: phoneme_len = 12'd2655;
            6'd16: phoneme_len = 12'd2731;
            6'd17: phoneme_len = 12'd2639;
            6'd18: phoneme_len = 12'd2735;
            6'd19: phoneme_len = 12'd2676;
            6'd20: phoneme_len = 12'd2606;
            6'd21: phoneme_len = 12'd2633;
            6'd22: phoneme_len = 12'd2674;
            6'd23: phoneme_len = 12'd2653;
            6'd24: phoneme_len = 12'd2555;
            6'd25: phoneme_len = 12'd2578;
            6'd26: phoneme_len = 12'd2635;
            6'd27: phoneme_len = 12'd2650;
            6'd28: phoneme_len = 12'd2663;
            6'd29: phoneme_len = 12'd2595;
            6'd30: phoneme_len = 12'd2512;
            6'd31: phoneme_len = 12'd2657;
            6'd32: phoneme_len = 12'd2618;
            6'd33: phoneme_len = 12'd2609;
            6'd34: phoneme_len = 12'd1012;
            6'd35: phoneme_len = 12'd899;
            6'd36: phoneme_len = 12'd2691;
            6'd37: phoneme_len = 12'd896;
            6'd38: phoneme_len = 12'd880;
            6'd39: phoneme_len = 12'd905;
            6'd40: phoneme_len = 12'd2575;
            6'd41: phoneme_len = 12'd3199;
            6'd42: phoneme_len = 12'd2615;
            6'd43: phoneme_len = 12'd3373;
            6'd44: phoneme_len = 12'd2539;
            6'd45: phoneme_len = 12'd2618;
            6'd46: phoneme_len = 12'd2603;
            6'd47: phoneme_len = 12'd2648;
            6'd48: phoneme_len = 12'd2642;
            6'd49: phoneme_len = 12'd2600;
            6'd50: phoneme_len = 12'd2656;
            6'd51: phoneme_len = 12'd2574;
            6'd52: phoneme_len = 12'd2720;
            6'd53: phoneme_len = 12'd2661;
            6'd54: phoneme_len = 12'd2638;
            6'd55: phoneme_len = 12'd2731;
            6'd56: phoneme_len = 12'd2643;
            6'd57: phoneme_len = 12'd2594;
            6'd58: phoneme_len = 12'd2584;
            6'd59: phoneme_len = 12'd2643;
            6'd60: phoneme_len = 12'd2564;
            6'd61: phoneme_len = 12'd2582;
            default: phoneme_len = 12'd0;
        endcase
    endfunction

    // ---- registers ----------------------------------------------------------
    logic [7:0] durphon;        // DR1:0 in bits 7:6, the phoneme in 5:0
    logic       ctl;            // CTL: power-down
    logic [1:0] func;           // the function latched at CTL high-to-low
    logic       ena_ints;       // A/!R enabled, likewise
    logic       d7_q;

    // ---- the phoneme engine -------------------------------------------------
    logic        active;        // a phoneme has been started since reset
    logic        leadout;       // ...and is in its leadout
    logic [11:0] remaining;     // samples left in the phoneme
    logic [11:0] lead_len;      // the leadout's length, from the last play
    logic [11:0] lead_rem;
    logic [1:0]  mod4;          // AppleWin's m_currSampleMod4, for DUR 1

    // ---- the sample clock ---------------------------------------------------
    // acc + TICK_NUM < 2 * TICK_DEN always, so 22 bits hold the sum.
    localparam logic [21:0] NUM = 22'(TICK_NUM);
    localparam logic [21:0] DEN = 22'(TICK_DEN);
    logic [21:0] acc;
    wire  [21:0] acc_next = acc + NUM;
    always_ff @(posedge clk) begin
        if (rst) begin
            acc  <= 22'd0;
            tick <= 1'b0;
        end else if (slow_clock) begin
            if (acc_next >= DEN) begin
                acc  <= acc_next - DEN;
                tick <= 1'b1;
            end else begin
                acc  <= acc_next;
                tick <= 1'b0;
            end
        end else begin
            tick <= 1'b0;
        end
    end

    // DUR as AppleWin's Update() takes it: frame mode forces 3.
    wire [1:0] dur = (func == 2'd1) ? 2'd3 : durphon[7:6];

    // How many samples this tick consumes, and how far mod4 moves.
    logic [2:0]  consume, mod_step;
    always_comb begin
        case (dur)
            2'd0: begin consume = 3'd1; mod_step = 3'd1; end
            2'd1: begin
                // One, then the skip: after the increment mod4 reads 3 and
                // there is more to skip.
                consume  = (mod4 == 2'd2 && remaining > 12'd1) ? 3'd2 : 3'd1;
                mod_step = 3'd1;
            end
            2'd2: begin consume = 3'd2; mod_step = 3'd2; end
            default: begin consume = 3'd4; mod_step = 3'd4; end
        endcase
    end
    wire [11:0] after = (remaining > {9'd0, consume}) ? remaining - {9'd0, consume} : 12'd0;

    // Start a phoneme (AppleWin's Play).
    task automatic play(input logic [5:0] ph);
        logic [5:0]  p;
        logic [11:0] len;
        begin
            p   = (ph == 6'd1) ? 6'd2 : ph;
            len = phoneme_len((p == 6'd0) ? 6'd0 : p - 6'd2);
            active    <= 1'b1;
            leadout   <= 1'b0;
            remaining <= len;
            lead_len  <= len / 12'd10;
            mod4      <= 2'd0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            durphon   <= 8'hC0;     // typical function, phoneme 0 (AppleWin)
            ctl       <= 1'b1;      // power-down
            func      <= 2'd0;
            ena_ints  <= 1'b0;
            d7_q      <= 1'b0;
            active    <= 1'b0;
            leadout   <= 1'b0;
            remaining <= 12'd0;
            lead_len  <= 12'd0;
            lead_rem  <= 12'd0;
            mod4      <= 2'd0;
        end else begin
            // ---- one output sample of machine time ----------------------
            if (tick) begin
                if (active && !leadout && remaining != 12'd0) begin
                    remaining <= after;
                    mod4      <= mod4 + mod_step[1:0];
                    if (after == 12'd0) begin
                        // Complete: the leadout starts, D7 goes up unless
                        // the chip is powered down.
                        leadout  <= 1'b1;
                        lead_rem <= lead_len;
                        if (!ctl) d7_q <= 1'b1;
                    end
                end else if (active && leadout) begin
                    if (lead_rem != 12'd0)  lead_rem <= lead_rem - 12'd1;
                    else if (!ctl)          play(durphon[5:0]);   // again
                    else                    leadout <= 1'b0;      // park
                end
            end

            // ---- a register write, last word in the same clock ----------
            if (wr_strobe) begin
                if (wr_reg <= 3'd2) d7_q <= 1'b0;
                case (wr_reg)
                    3'd0: begin
                        durphon <= wr_data;
                        if (!ctl) play(wr_data[5:0]);
                    end
                    3'd3: begin
                        if (ctl && !wr_data[7]) begin
                            // Out of power-down: the mode from DR1:0, and
                            // the phoneme starts.
                            if (durphon[7:6] != 2'd0) begin
                                func     <= durphon[7:6];
                                ena_ints <= 1'b1;
                            end else begin
                                ena_ints <= 1'b0;
                            end
                            play(durphon[5:0]);
                        end
                        ctl <= wr_data[7];
                        if (wr_data[7]) d7_q <= 1'b0;
                    end
                    default: ;      // inflection, rate, filter: the host's
                endcase
            end
        end
    end

    assign d7   = d7_q;
    assign ar_n = !(ena_ints && d7_q);

endmodule
