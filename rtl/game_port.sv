`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// game_port - the game port in the dummies: the pushbuttons and the paddles
// sampled by the driver's idle cycles, served to the accelerated core.
//
// THE KEYBOARD'S ARRANGEMENT, WIDENED (rtl/kbd_inject.sv; docs/ACCELERATION.md
// "The keyboard in the dummies").  In the closed regime the driver's dummy
// cycles read the real machine instead of $0000, and what they bring back
// feeds latches the program's own reads are served from.  Step 2 parked
// every dummy at $C000.  This module turns that into a LOOP: every other
// dummy is still the keyboard's - a key must not wait - and the dummies
// between visit the game port in turn: the three pushbuttons ($C061-$C063,
// bit 7 a level), or, while a paddle measurement is running, the four paddle
// timers ($C064-$C067).  The driver takes the address for its next dummy
// from park_addr here; a dummy is a SAMPLE, and none of the read-side state
// of anything moves on one.
//
// THE PADDLES ARE THE TRICKY PART.  A paddle is a one-shot timer (a 558):
// any access to $C070-$C07F triggers all four, and each timer's bit 7 then
// stays high for a time proportional to the paddle's resistance - eleven
// cycles a unit, 0 to ~2800 cycles - and falls.  PREAD strobes and counts
// loop iterations until the bit falls.  So this module MEASURES: it strobes
// through a dummy read of $C070, then counts real bus cycles and probes the
// four timers in turn on the loop's odd slots until each has fallen (or a
// timeout has), and the count at the fall - the midpoint of the last probe
// that saw it high and the first that saw it low - is that paddle's sample.
// Then it RESTS for a while before the next strobe: a 558 that is
// retriggered while timing ignores the trigger, and the capacitor wants its
// time to settle after the fall; a measurement every few thousand cycles is
// a few hundred samples a second, far beyond any game's need.
//
// ON THE CORE'S SIDE the port is emulated at the core's pace from the
// samples.  An internalized access of $C07x - a read served on the card, or
// a write that rode the bus (the RamWorks bank register lives among them,
// so writes are not internalized) - starts a virtual timer per paddle:
// running for as many CORE cycles as the sample counted bus cycles, which
// are the same unit, a 6502 cycle.  A read of $C064-$C067 served on the
// card returns bit 7 = the virtual timer still running; a read of $C061-
// $C063 returns the sampled button, under the host's override (the BUTTONS
// register, rtl/pb_inject.sv - a level the host may force either way).  The
// low seven bits are the keyboard latch's, as the status page's are (the
// machine's are the floating bus's, which fb_sim does not model for $C06x;
// no program reads them).  So a
// PREAD at ninety times speed sees a timer that falls after the same number
// of its own cycles as the real one did, and reads the paddle the machine
// has - without a bus cycle for the strobe or any of the probes, which at
// two bus cycles each had made a joystick game's input loop a slow one.
//
// A strobe the program makes on the BUS (a $C07x write) also starts the
// virtual timers, so the two arrangements never disagree; it retriggers the
// real ones too, which at worst spoils the measurement in flight - the next
// one repairs it.
//
// GATES.  pb_ok says every button has been sampled since the loop began;
// pdl_ok that one measurement has completed.  Until then the program's
// reads ride the bus, as before.  The buttons are resampled from scratch
// when the loop restarts (a hold parks the dummies at $0000 and the user may
// have pressed one meanwhile); the paddle samples are kept across it - a
// stale paddle for a millisecond is nothing, and a hold is exactly when the
// program is not reading it.  The card's reset clears everything.
//
// TIMING is the keyboard latch's: data_sync is the bus's byte at T_DIN, the
// clock before op_commit, and data_q holds it at the commit.
//////////////////////////////////////////////////////////////////////////////////
module game_port #(
    parameter [11:0] REST    = 12'd1024,   // bus cycles between a measurement's end and the next strobe
    parameter [11:0] TIMEOUT = 12'd4000    // a timer that has not fallen by then is taken to be at this
) (
    input  wire        clk,
    input  wire        rst,             // the card's reset
    input  wire        master_active,   // 1 while the card is the CPU

    // The loop is on: the closed regime, the chicken bit clear, the core not
    // held (master_top's sw_int).  Off, park_addr is $C000 - the keyboard's
    // arrangement alone - and nothing here samples.
    input  wire        park,

    // The presented op, as kbd_inject sees it.
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire        op_commit,
    input  wire        op_dummy,
    input  wire [7:0]  data_sync,
    input  wire        bus_tick,        // one per bus cycle

    // Where the driver's NEXT dummy reads (rtl/apple_bus_write.sv park_addr).
    output logic [15:0] park_addr,

    // ---- the serve --------------------------------------------------------
    output logic       pb_ok,           // the three buttons have been sampled
    output logic       pdl_ok,          // a measurement has completed
    input  wire [5:0]  pb_sel,          // the host's overrides, BUTTONS's word
    // The core's clock: one per core cycle (a fast op's retire or a bus
    // op of the core's own - what the floppy and the beam keep time by).
    input  wire        core_tick,
    // One clock: a $C07x access the core made - internalized (the synthetic
    // commit) or on the bus (a write) - starts the virtual timers.
    input  wire        strobe,
    // The registered op's address, and the low seven bits its byte should
    // carry (the floating bus's); int_byte is the answer for $C061-$C067.
    input  wire [15:0] u_addr,
    input  wire [6:0]  low_bits,
    output wire [7:0]  int_byte,

    // Read back: the levels and the samples, for the host's report.
    output logic [2:0]  pb_level,
    output logic [11:0] pdl0, pdl1, pdl2, pdl3,
    output logic [7:0]  measurements
);

    // ---- the loop -----------------------------------------------------------
    // odd: this dummy is the game port's, not the keyboard's.  pb_n: the
    // button next in turn; pdl_n: the paddle next in turn.
    logic       odd;
    logic [1:0] pb_n;
    logic [1:0] pdl_n;
    typedef enum logic [1:0] { M_REST, M_STROBE, M_RUN } mstate_t;
    mstate_t    ms;
    logic [11:0] rest_cnt, run_cnt;
    logic [3:0]  done;
    logic [11:0] last_hi [4];
    logic [11:0] sample  [4];
    logic [7:0]  data_q;
    logic [2:0]  pb_seen;

    // The address of the next dummy, from the state: registered, so the
    // driver's cone sees a flop.
    always_ff @(posedge clk) begin
        if (rst || !park)         park_addr <= 16'hC000;
        else if (!odd)            park_addr <= 16'hC000;
        else if (ms == M_STROBE)  park_addr <= 16'hC070;
        else if (ms == M_RUN)     park_addr <= {14'h3019, pdl_n};              // $C064 + n
        else                      park_addr <= {14'h3018, 2'd1} + {14'd0, pb_n}; // $C061 + n
    end

    wire commit     = op_commit && master_active;
    wire dummy_smp  = commit && op_dummy && park && op_rw && (op_addr[15:8] == 8'hC0);
    wire [3:0] lo   = op_addr[3:0];
    wire is_pb      = (op_addr[7:4] == 4'h6) && (lo[3:2] == 2'b00) && (lo[1:0] != 2'b00);
    wire is_pdl     = (op_addr[7:4] == 4'h6) && (lo[3:2] == 2'b01);
    wire is_trig    = (op_addr[7:4] == 4'h7);
    wire [1:0] pb_i  = lo[1:0] - 2'd1;
    wire [1:0] pdl_i = lo[1:0];

    always_ff @(posedge clk) begin
        data_q <= data_sync;
        if (rst) begin
            odd <= 1'b0; pb_n <= 2'd0; pdl_n <= 2'd0;
            ms <= M_REST; rest_cnt <= 12'd0; run_cnt <= 12'd0; done <= 4'd0;
            pb_seen <= 3'd0; pb_ok <= 1'b0; pdl_ok <= 1'b0; measurements <= 8'd0;
            pb_level <= 3'd0;
            for (int p = 0; p < 4; p++) begin sample[p] <= TIMEOUT; last_hi[p] <= 12'd0; end
        end else if (!park) begin
            // The loop restarts from the keyboard with the buttons unknown;
            // the paddle samples stand.
            odd <= 1'b0; pb_n <= 2'd0; pdl_n <= 2'd0;
            ms <= M_REST; rest_cnt <= 12'd0; done <= 4'd0;
            pb_seen <= 3'd0; pb_ok <= 1'b0;
        end else begin
            // ---- the measurement's clock: every bus cycle ----------------
            if (bus_tick) begin
                case (ms)
                    M_REST: begin
                        if (rest_cnt == REST) ms <= M_STROBE;
                        else rest_cnt <= rest_cnt + 12'd1;
                    end
                    M_RUN: begin
                        run_cnt <= run_cnt + 12'd1;
                        if ((&done) || (run_cnt == TIMEOUT)) begin
                            for (int p = 0; p < 4; p++) if (!done[p]) sample[p] <= TIMEOUT;
                            ms <= M_REST; rest_cnt <= 12'd0;
                            pdl_ok <= 1'b1;
                            measurements <= measurements + 8'd1;
                        end
                    end
                    default: ;
                endcase
            end
            // ---- the samples, at a dummy's commit ------------------------
            if (dummy_smp) begin
                odd <= !odd;
                if (is_pb) begin
                    pb_level[pb_i] <= data_q[7];
                    pb_seen[pb_i]  <= 1'b1;
                    if ((pb_seen | (3'd1 << pb_i)) == 3'b111) pb_ok <= 1'b1;
                    pb_n <= (pb_n == 2'd2) ? 2'd0 : pb_n + 2'd1;
                end
                if (is_pdl) begin
                    pdl_n <= pdl_n + 2'd1;
                    if (ms == M_RUN && !done[pdl_i]) begin
                        if (data_q[7]) last_hi[pdl_i] <= run_cnt;
                        else begin
                            // The midpoint, in a width the sum fits.
                            sample[pdl_i] <= 12'(({1'b0, last_hi[pdl_i]} + {1'b0, run_cnt}) >> 1);
                            done[pdl_i]   <= 1'b1;
                        end
                    end
                end
                if (is_trig && ms == M_STROBE) begin
                    // The real timers are running from this cycle.
                    ms <= M_RUN; run_cnt <= 12'd0; done <= 4'd0;
                    for (int p = 0; p < 4; p++) last_hi[p] <= 12'd0;
                end
            end
        end
    end

    assign pdl0 = sample[0];
    assign pdl1 = sample[1];
    assign pdl2 = sample[2];
    assign pdl3 = sample[3];

    // ---- the core's side: the virtual timers --------------------------------
    // A strobe starts every timer that is not running (a 558 retriggered
    // while timing ignores it, as AppleWin's JoyResetPosition has it); each
    // runs for its sample's count of core cycles.  A sample of zero never
    // runs: the paddle at its stop reads low at once, as PREAD expects.
    logic [11:0] elapsed [4];
    logic [3:0]  running;
    always_ff @(posedge clk) begin
        if (rst) begin
            running <= 4'd0;
            for (int p = 0; p < 4; p++) elapsed[p] <= 12'd0;
        end else begin
            for (int p = 0; p < 4; p++) begin
                if (running[p] && core_tick) begin
                    if (elapsed[p] + 12'd1 >= sample[p]) running[p] <= 1'b0;
                    else elapsed[p] <= elapsed[p] + 12'd1;
                end
                if (strobe && !running[p]) begin
                    elapsed[p] <= 12'd0;
                    running[p] <= (sample[p] != 12'd0);
                end
            end
        end
    end

    // The answer for the registered op: a button under its override, a
    // timer's state; nothing for $C060 or $C068-$C06F (never served).
    wire [1:0] ui   = u_addr[1:0];
    wire [1:0] upb  = ui - 2'd1;
    wire [1:0] want = pb_sel[upb * 2 +: 2];
    wire pb_bit  = (want == 2'b10) ? 1'b1 : (want == 2'b01) ? 1'b0 : pb_level[upb];
    wire bit7    = u_addr[2] ? running[ui] : pb_bit;
    assign int_byte = {bit7, low_bits};

endmodule
