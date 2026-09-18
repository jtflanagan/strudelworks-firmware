`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// telem_tx - the card's registers to the host, once a second (docs/TELEMETRY.md).
//
// One message a second, type TELEMETRY:
//
//   header   {free = {drops[7:0], layout[7:0]}, T_TELEMETRY, len = 3 + TELEM_N}
//   w0       {epoch[7:0], flags[7:0], 16'd0}
//   w1       seq          seconds since the Apple's RES' let go; 0 IS the baseline
//   w2       microseconds since the card's reset, at the sweep's start (wraps, 71 min)
//   w3..     the registers of rtl/telem_map.vh, in its order - and, in layout 2,
//            the debug space's items, each read through DBG_VAL with the
//            sender's own selector on the top's muxes (rtl/card_link.sv) and
//            the host's put back after.  The host's DBG_SEL/DBG_VAL pair
//            cannot see it: the bridge is stalled for the whole sweep, and
//            twenty-two register reads follow the last item, so the host's
//            selection has re-registered long before the bridge is let go.
//
// flags  [0] RES' was low at the sweep (the machine is held: a start, a reset)
//        [1] this baseline is LATE: the release came while a message was still
//            going out, and the sample waited for it
//
// THE FIRST SAMPLE OF A RUN IS TAKEN AS RES' LETS GO (the user, 2026-09-17).
// Most of the card's counters are not cleared by RES', so that sample is the
// zero the run is read against; and the divider restarts there, so sample k is
// k seconds into the run, whatever the card was doing before.  `epoch` counts
// the releases: a host that sees it move has a new run and a new baseline.
//
// RES' BOUNCES (rtl/wb_regfile.sv, rtl/start_hold.sv): the line rises through
// an RC and a slow edge through a synchroniser reads as a burst of edges.  A
// release here is RES' high for DEBOUNCE clocks after having been low for
// DEBOUNCE clocks, and a new low stretch is not believed for 2^MASK_LOG2 clocks
// after one - start_hold's two numbers, for start_hold's reason.  One reset,
// one epoch.
//
// A SAMPLE IS ONE INSTANT.  The sweep takes the register file's front door
// (rtl/reg_front.sv) for itself, raises the register cut's hold
// (rtl/wb_regfile.sv snap_hold) so that every read-only readback stops moving,
// reads the map into a FIFO, and lets both go: about 260 clocks.  The host's
// bridge waits that long at most, and no write of the host's can land inside a
// sample.  What is in the FIFO is then offered to the message bus through the
// reader audio_tx uses.
//
// NOTHING HERE IS CUT SHORT.  The reader is reset by the card's reset and by
// nothing else - not by `enable`, not by a release: a reader that stopped in
// the middle of a message would leave rtl/msg_master.sv holding CYC with no
// more words to send, and every port behind it would wait for ever.  `enable`
// and the release decide whether the NEXT sweep starts.  A release that finds a
// sweep or a message in progress lets it finish - it says truthfully which
// epoch it was taken in - and the baseline follows it, flagged late.
//
// A TICK THAT FINDS THE LAST MESSAGE STILL GOING OUT IS SKIPPED and counted;
// `seq` still advances, so the host sees the gap in the numbers.  That is a
// link that is down or drowning, not a busy one: a message is 89 words a second.
//
// SILENT UNTIL ASKED (docs/PROTOCOL.md): `enable` is TELEM_CTRL[0], clear at
// the card's reset.  The host sets it BEFORE it releases the start hold, or the
// baseline goes unsent.
//////////////////////////////////////////////////////////////////////////////////
module telem_tx #(
    parameter integer TICK_CYCLES = 100_000_000,   // one second of clk
    parameter integer US_CYCLES   = 100,           // one microsecond of clk
    parameter integer DEBOUNCE    = 16,
    parameter integer MASK_LOG2   = 20,
    // The watchdog (see "the watchdog" below): how long a sweep may hold the
    // card still before it is abandoned, and how long the door is left for an
    // outstanding read to ack after that.  A whole sweep is tens of
    // microseconds when the front is answering.
    parameter integer WDOG_CLKS   = 1_000_000,     // 10 ms at 100 MHz
    parameter integer WDOG_GRACE  = 10_000         // 100 us
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,         // TELEM_CTRL[0]
    input  wire        apple_res_q,    // RES', active low, a flop of the register file's

    // THE DEBUG SELECTOR (layout 2): the host's, from the register file, and
    // what reaches the top's muxes - the sender's own for the debug items of
    // its sweep, the host's otherwise.  Registered here, so a bench sees it.
    input  wire [7:0]  dbg_sel_host,
    output logic [7:0] dbg_sel,

    // THE SWEEP: rtl/reg_front.sv's telemetry port, and the register cut's hold.
    output logic       t_req,
    input  wire        t_gnt,
    output logic       t_stb,
    // The map's ROM (rtl/telem_map.vh) is 85 entries: LUTs, not the block RAM
    // Vivado reached for (`gs_telem1` spent a RAMB18 on it; block RAM is this
    // design's scarce resource, LUTs are not).
    (* rom_style = "distributed" *)
    output logic [15:0] t_off,
    input  wire        t_ack,
    input  wire [31:0] t_dat,          // the register file's wb_dat_r
    output logic       snap_hold,

    // TO msg_master
    output wire [31:0] word,
    output wire        valid,
    input  wire        take,

    // TELEM_CTRL's read-only half: {sent[7:0], drops[7:0], epoch[7:0]}
    output wire [23:0] stat
);

    `include "telem_map.vh"

    localparam [7:0]   T_TELEMETRY = 8'h39;
    localparam integer N_STAMP     = 3;
    localparam integer LEN         = N_STAMP + TELEM_N;
    localparam integer DEPTH       = 256;
    localparam integer CW          = $clog2(DEPTH + 1);

    // ---- the release ---------------------------------------------------------
    localparam integer DW = $clog2(DEBOUNCE + 1);
    logic [DW-1:0]      low_cnt, high_cnt;
    logic               was_low;        // a believed low stretch, not yet released
    logic [MASK_LOG2:0] mask_cnt;
    logic               released;       // one clock
    wire                res_low_now = !apple_res_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            low_cnt  <= '0;
            high_cnt <= '0;
            // The card's reset IS a held machine: the start hold is pulling
            // RES' down already, and its release is the first run's start.
            was_low  <= 1'b1;
            mask_cnt <= '0;
            released <= 1'b0;
        end else begin
            released <= 1'b0;
            if (mask_cnt != '0) mask_cnt <= mask_cnt - 1'b1;

            if (res_low_now) begin
                high_cnt <= '0;
                if (low_cnt != DW'(DEBOUNCE)) low_cnt <= low_cnt + 1'b1;
                else if (mask_cnt == '0)      was_low <= 1'b1;
            end else begin
                low_cnt <= '0;
                if (high_cnt != DW'(DEBOUNCE)) high_cnt <= high_cnt + 1'b1;
                else if (was_low) begin
                    was_low  <= 1'b0;
                    released <= 1'b1;
                    mask_cnt <= {1'b1, {MASK_LOG2{1'b0}}};
                end
            end
        end
    end

    // ---- the time base ----------------------------------------------------------
    localparam integer TW = $clog2(TICK_CYCLES);
    localparam integer UW = $clog2(US_CYCLES);
    logic [TW-1:0] tick_cnt;
    logic          tick;                // one clock, once a second from the release
    logic [7:0]    epoch;
    logic [31:0]   seq;
    logic [UW-1:0] us_pre;
    logic [31:0]   us;

    always_ff @(posedge clk) begin
        if (rst) begin
            tick_cnt <= '0;
            tick     <= 1'b0;
            epoch    <= 8'd0;
            seq      <= 32'd0;
            us_pre   <= '0;
            us       <= 32'd0;
        end else begin
            tick <= 1'b0;
            if (released) begin
                tick_cnt <= '0;
                epoch    <= epoch + 8'd1;
                seq      <= 32'd0;
            end else if (tick_cnt == TW'(TICK_CYCLES - 1)) begin
                tick_cnt <= '0;
                tick     <= 1'b1;
                seq      <= seq + 32'd1;
            end else begin
                tick_cnt <= tick_cnt + 1'b1;
            end

            if (us_pre == UW'(US_CYCLES - 1)) begin
                us_pre <= '0;
                us     <= us + 32'd1;
            end else begin
                us_pre <= us_pre + 1'b1;
            end
        end
    end

    // ---- the sweep ---------------------------------------------------------------
    typedef enum logic [2:0] {
        W_IDLE,      // nothing owed, or waiting for the last message to finish
        W_DOOR,      // t_req up, waiting for the front
        W_STAMP,     // the hold is up; the three stamp words go into the FIFO
        W_READ,      // a strobe - or, for a debug item, the selector goes out
        W_SETTLE,    // ...and three clocks for the item to reach DBG_VAL's shadow
        W_WAIT,      // ...and its ack
        W_DONE,      // everything is in: let the front and the hold go
        W_ABORT      // the watchdog gave up: the hold is down, let the rest go
    } wstate_t;
    wstate_t wstate = W_IDLE;

    logic        want;                  // a sample is owed
    logic        want_base;             // ...and it is a baseline
    logic        late;                  // the owed baseline had to wait
    logic [7:0]  drops;
    logic [7:0]  idx;
    logic [1:0]  stamp_i;
    logic [1:0]  settle;
    logic        dbg_mine;              // the selector is the sender's
    wire  [23:0] ent = telem_ent(idx);
    wire         ent_dbg = (ent[15:0] == TELEM_DBG_OFF);
    logic [31:0] stamp0, stamp1, stamp2;
    logic [31:0] fifo_din;
    logic        fifo_wr;
    logic        msg_go;                // one clock: a whole sample is in the FIFO

    wire         fifo_empty;
    wire         reader_idle;
    wire         clear = reader_idle && fifo_empty;   // the last message is wholly gone

    // ---- the watchdog --------------------------------------------------------
    // A sweep raises snap_hold - every read-only register's shadow stops moving,
    // so that one sample is one instant of the card - and holds the debug door
    // while it reads the map.  If a read never acks, both stay up and the CARD
    // IS WEDGED: every read-only register reads back what it held when the hold
    // went up, the host is blind, and a swhost restart does not clear it because
    // only the card's own reset does.  That happened on 2026-09-18, and the
    // suspect is a saturated USB3 pipe - full capture with an untargeted core,
    // which docs/ACCELERATION.md now caps for the same reason.
    //
    // The user's standing rule is that the card never wedges, so the sweep is
    // bounded.  WDOG_CLKS after it leaves W_IDLE it gives up: the HOLD DROPS
    // FIRST, because that is what unfreezes the card, and the door goes once the
    // outstanding read has acked or WDOG_GRACE has passed (a front that never
    // acks is already broken; keeping the door shut behind it is worse than
    // letting it go).  The words already in the FIFO are drained, and the sample
    // is counted as a drop - which is what it is, and the host sees it in the
    // next message's header.  `want` is cleared so the next attempt waits for
    // the next tick rather than looping on a link that is still busy; a baseline
    // that was abandoned is re-owed, and marked late.
    localparam integer WDW = $clog2(WDOG_CLKS + 1);
    logic [WDW-1:0] wdog;
    logic           sweep_base;     // the sample under way is a baseline

    always_ff @(posedge clk) begin
        if (rst) begin
            wstate    <= W_IDLE;
            want      <= 1'b0;
            want_base <= 1'b0;
            late      <= 1'b0;
            drops     <= 8'd0;
            idx       <= 8'd0;
            stamp_i   <= 2'd0;
            t_req     <= 1'b0;
            t_stb     <= 1'b0;
            t_off     <= 16'd0;
            snap_hold <= 1'b0;
            fifo_wr   <= 1'b0;
            msg_go    <= 1'b0;
            settle    <= 2'd0;
            dbg_mine  <= 1'b0;
            dbg_sel   <= 8'd0;
            wdog      <= '0;
            sweep_base <= 1'b0;
        end else begin
            // The selector: the sender's while it holds the door and is on a
            // debug item, the host's otherwise - and never the sender's
            // before the door is its own, or a bridge read in flight would
            // be torn.
            dbg_sel <= (dbg_mine && t_gnt) ? ent[23:16] : dbg_sel_host;
            t_stb   <= 1'b0;
            fifo_wr <= 1'b0;
            msg_go  <= 1'b0;

            // What is owed.  A release owes a baseline whatever else is going
            // on; a tick owes a sample unless one is already owed or under way,
            // and then it is a drop.  Nothing is owed to a host that has not
            // asked.
            if (!enable) begin
                want      <= 1'b0;
                want_base <= 1'b0;
                late      <= 1'b0;
            end else begin
                if (released) begin
                    want      <= 1'b1;
                    want_base <= 1'b1;
                    late      <= (wstate != W_IDLE) || !clear;
                end else if (tick) begin
                    if (want || wstate != W_IDLE || !clear) drops <= drops + 8'd1;
                    else                                     want  <= 1'b1;
                end
            end

            // The watchdog's clock: it runs whenever a sweep is under way.
            if (wstate == W_IDLE) wdog <= '0;
            else if (wdog != WDW'(WDOG_CLKS)) wdog <= wdog + 1'b1;

            if (wstate != W_IDLE && wstate != W_ABORT && wdog == WDW'(WDOG_CLKS)) begin
                // Give up.  The hold first: that is what has the card still.
                snap_hold <= 1'b0;
                dbg_mine  <= 1'b0;
                t_stb     <= 1'b0;
                drops     <= drops + 8'd1;
                want      <= 1'b0;             // the next tick owes the next one
                want_base <= sweep_base;       // a lost baseline is still owed
                late      <= sweep_base;
                wdog      <= '0;               // ...and times the grace
                wstate    <= W_ABORT;
            end else
            case (wstate)
                W_IDLE: if (want && enable && clear) begin
                    t_req  <= 1'b1;
                    wstate <= W_DOOR;
                end

                W_ABORT: begin
                    // The hold is already down and the FIFO is draining below.
                    // Let the door go when the read we were waiting on acks, or
                    // when the grace is up.
                    if (t_ack || wdog == WDW'(WDOG_GRACE)) t_req <= 1'b0;
                    if (!t_req && fifo_empty) wstate <= W_IDLE;
                end

                W_DOOR: if (t_gnt) begin
                    // The door is ours: stop the shadows, and say when.  The
                    // stamp is of THIS clock, the one the hold is raised in.
                    snap_hold <= 1'b1;
                    stamp0    <= {epoch, 6'd0, late && want_base, res_low_now, 16'd0};
                    stamp1    <= want_base ? 32'd0 : seq;
                    stamp2    <= us;
                    want      <= released;        // a release THIS clock is still owed
                    want_base <= released;
                    late      <= released;
                    stamp_i    <= 2'd0;
                    idx        <= 8'd0;
                    sweep_base <= want_base;   // for the watchdog, if this one is abandoned
                    wstate     <= W_STAMP;
                end

                W_STAMP: begin
                    fifo_din <= (stamp_i == 2'd0) ? stamp0 :
                                (stamp_i == 2'd1) ? stamp1 : stamp2;
                    fifo_wr  <= 1'b1;
                    stamp_i  <= stamp_i + 2'd1;
                    if (stamp_i == 2'd2) wstate <= W_READ;
                end

                W_READ: begin
                    t_off  <= ent[15:0];
                    if (ent_dbg) begin
                        // The selector goes out this clock (dbg_sel above);
                        // the top's muxes are one clock behind it, DBG_VAL's
                        // shadow one more, the strobe's own registered front
                        // and read a third: three clocks of settling.
                        dbg_mine <= 1'b1;
                        settle   <= 2'd3;
                        wstate   <= W_SETTLE;
                    end else begin
                        dbg_mine <= 1'b0;
                        t_stb    <= 1'b1;
                        wstate   <= W_WAIT;
                    end
                end

                W_SETTLE: begin
                    settle <= settle - 2'd1;
                    if (settle == 2'd1) begin
                        t_stb  <= 1'b1;
                        wstate <= W_WAIT;
                    end
                end

                W_WAIT: if (t_ack) begin
                    fifo_din <= t_dat;
                    fifo_wr  <= 1'b1;
                    idx      <= idx + 8'd1;
                    wstate   <= (idx == 8'(TELEM_N - 1)) ? W_DONE : W_READ;
                end

                // Nothing is outstanding here, which is the only place the
                // front may be let go (rtl/reg_front.sv).
                W_DONE: begin
                    t_req     <= 1'b0;
                    snap_hold <= 1'b0;
                    dbg_mine  <= 1'b0;
                    msg_go    <= 1'b1;
                    wstate    <= W_IDLE;
                end

                default: wstate <= W_IDLE;
            endcase
        end
    end

    // ---- the FIFO ------------------------------------------------------------------
    wire [31:0]   fifo_dout;
    wire          fifo_full;
    wire [CW-1:0] fifo_count;
    logic         fifo_rd;

    sync_fifo #(.WIDTH (32), .DEPTH (DEPTH)) u_fifo (
        .clk   (clk),
        .rst   (rst),
        .din   (fifo_din),
        .wr_en (fifo_wr),
        .full  (fifo_full),
        .dout  (fifo_dout),
        .rd_en (fifo_rd),
        .empty (fifo_empty),
        .count (fifo_count)
    );

    // ---- the reader: one message at a time (rtl/audio_tx.sv's) ---------------------
    logic       in_hdr = 1'b0, in_body = 1'b0;
    logic       owed = 1'b0;            // a sample is in the FIFO, its header not yet offered
    logic [7:0] left = 8'd0;
    logic [7:0] sent = 8'd0;
    logic [7:0] hdr_drops;

    wire [31:0] hdr = {hdr_drops, TELEM_LAYOUT, T_TELEMETRY, 8'(LEN)};

    assign reader_idle = !in_hdr && !in_body && !owed && !msg_go;
    assign word    = in_hdr ? hdr : fifo_dout;
    assign valid   = in_hdr || (in_body && !fifo_empty);
    // The reader's, or the watchdog's drain of an abandoned sample.
    assign fifo_rd = (in_body && take) || (wstate == W_ABORT && !fifo_empty);

    always_ff @(posedge clk) begin
        if (rst) begin
            in_hdr  <= 1'b0;
            in_body <= 1'b0;
            owed    <= 1'b0;
            left    <= 8'd0;
            sent    <= 8'd0;
        end else begin
            if (msg_go) owed <= 1'b1;
            if (!in_hdr && !in_body) begin
                if (owed) begin
                    owed      <= 1'b0;
                    in_hdr    <= 1'b1;
                    hdr_drops <= drops;
                end
            end else if (in_hdr) begin
                if (take) begin
                    in_hdr  <= 1'b0;
                    in_body <= 1'b1;
                    left    <= 8'(LEN);
                end
            end else if (take) begin
                left <= left - 8'd1;
                if (left == 8'd1) begin
                    in_body <= 1'b0;
                    sent    <= sent + 8'd1;
                end
            end
        end
    end

    assign stat = {sent, drops, epoch};

    wire _unused_ok = &{1'b0, fifo_full, fifo_count, 1'b0};

endmodule
