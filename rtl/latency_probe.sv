`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// latency_probe - measure UberDDR3 read latency, in controller clocks.
//
// This module IS the derisk experiment.  The whole reason for preferring
// UberDDR3 over MIG is the claim that trading throughput for latency is possible;
// this measures the latency actually delivered on this board before any of the
// Apple II logic is written on top of it.
//
// What is measured, and why it is measured this way:
//
//   t_wait = cycles from raising stb to the request being accepted (!stall)
//   t_data = cycles from acceptance to ack
//   t_total = t_wait + t_data
//
// t_total is the number that matters.  The Apple II gives a fixed budget - about
// 490 ns of the ~978 ns 1.023 MHz cycle - between the address being valid and the
// data being needed, and it cannot be extended.  A controller that answers in 8
// cycles normally but stalls for 20 during a refresh has a worst case of 28, and
// the worst case is the spec.  Measuring only post-acceptance latency would hide
// exactly the refresh interference this project exists to control.
//
// Two access patterns run alternately:
//
//   SEQ - index increments by 1.  The low bits of the Wishbone address are the
//         column, so this walks within an open row: page hits, best case.
//   RND - index from an LFSR, so row and bank change nearly every access: an
//         ACTIVATE (and usually a PRECHARGE) before every read.  This is what a
//         real Apple II access stream looks like.
//
// Reads are issued one at a time, never pipelined.  Unloaded latency is the
// question; queueing more requests would measure throughput instead.
//
// Display: led = {mode, max_total[6:0]}, alternating about twice a second.
//   led[7] = 0 -> SEQ worst case, led[7] = 1 -> RND worst case.
//   led[6:0] saturates at 127.
// data_error latches high if any read returns the wrong pattern, and is shown by
// driving all 8 LEDs on solid.
//////////////////////////////////////////////////////////////////////////////////

module latency_probe #(
    parameter INDEX_BITS = 16,   // size of the region written and then read back
    parameter ADDR_BITS  = 24,
    parameter DATA_BITS  = 128,
    parameter SEL_BITS   = 16,
    parameter AUX_WIDTH  = 4,
    parameter DISPLAY_DIV = 25_000_000,  // ~0.25 s at 100 MHz

    // Bus emulation, for milestone 2.  With GATE_EMULATE = 1 the probe inserts an
    // idle gap before every access - standing in for a bus cycle served from the
    // line buffer, during which DDR3 is free - and raises refresh_ok for the first
    // part of it, inviting the controller to take its refresh there.
    //
    // IDLE_CLKS = 35 is one IIgs bus cycle (357 ns at 100 MHz).  GATE_ASSERT_CLKS
    // must leave room for the whole refresh sequence (PRE_REFRESH + tRP + tRFC,
    // about 23 clocks on this 2 Gb part) to finish inside the gap, or the refresh
    // overruns into the next access - see docs/DERISK.md.
    parameter GATE_EMULATE     = 1,
    parameter IDLE_CLKS        = 35,
    parameter GATE_ASSERT_CLKS = 6
) (
    input  wire clk,
    input  wire rst,             // synchronous, active high
    input  wire calib_complete,

    // Wishbone master
    output reg                  wb_cyc,
    output reg                  wb_stb,
    output reg                  wb_we,
    output reg  [ADDR_BITS-1:0] wb_addr,
    output reg  [DATA_BITS-1:0] wb_data,
    output wire [SEL_BITS-1:0]  wb_sel,
    output wire [AUX_WIDTH-1:0] wb_aux,
    input  wire                 wb_stall,
    input  wire                 wb_ack,
    input  wire [DATA_BITS-1:0] wb_rdata,

    // Results
    output reg  [15:0] seq_max_total,
    output reg  [15:0] seq_min_total,
    output reg  [15:0] rnd_max_total,
    output reg  [15:0] rnd_min_total,
    output reg  [15:0] last_wait,
    output reg  [15:0] last_data,
    output reg         data_error,
    output wire [7:0]  led,

    // ---- windowed statistics, for the UART report ------------------------
    // The cumulative maxima above are what the LEDs show, and they saturate at
    // the refresh-collision worst case within a second or two - which is the
    // number that matters, but it hides everything else.  These are per-WINDOW
    // instead: one window is 2**16 accesses of one pattern, snapshotted when the
    // window ends.  A window is a power of two on purpose, so the mean is a shift
    // rather than a divide.
    output reg  [31:0] win_count,
    output reg  [15:0] seq_min_w,
    output reg  [31:0] seq_mean_x10,
    output reg  [15:0] seq_max_w,
    output reg  [31:0] seq_gt_gs,
    output reg  [31:0] seq_gt_leg,
    output reg  [15:0] rnd_min_w,
    output reg  [31:0] rnd_mean_x10,
    output reg  [15:0] rnd_max_w,
    output reg  [31:0] rnd_gt_gs,
    output reg  [31:0] rnd_gt_leg,
    output reg  [31:0] err_count,

    // High when the controller may take a refresh now (GATE_EMULATE only).
    output reg         refresh_ok
);

    localparam [2:0] S_IDLE      = 3'd0,
                     S_FILL      = 3'd1,
                     S_FILL_DRAIN= 3'd2,
                     S_REQ       = 3'd3,
                     S_WAIT_ACK  = 3'd4,
                     S_NEXT      = 3'd5,
                     S_GAP       = 3'd6;

    reg [2:0] state;
    reg       mode;                       // 0 = SEQ, 1 = RND
    reg [INDEX_BITS-1:0] fill_idx;
    reg [INDEX_BITS-1:0] fill_acks;
    reg [INDEX_BITS-1:0] seq_idx;
    reg [INDEX_BITS-1:0] lfsr;
    reg [INDEX_BITS-1:0] cur_idx;
    reg [15:0] pass_count;

    // Accumulators for the window in progress.  Contributions to w_sum are capped
    // so the running total cannot overflow: 2**16 * 1023 * 10 still fits in 32
    // bits, and nothing legitimate comes near 1023 cycles anyway.
    localparam integer WINDOW_BITS = 16;

    // The IIgs window is ~180 ns and the legacy window ~490 ns; at a 10 ns
    // controller clock that is 18 and 49 cycles.  Same thresholds the testbench
    // uses, so the UART report and the simulation report are directly comparable.
    localparam [15:0] GS_BUDGET_CYCLES     = 16'd18;
    localparam [15:0] LEGACY_BUDGET_CYCLES = 16'd49;

    reg [15:0] w_min, w_max;
    reg [31:0] w_sum, w_gt_gs, w_gt_leg;

    wire [15:0] t_total  = t_wait + t_data;
    wire [15:0] t_capped = (t_total > 16'd1023) ? 16'd1023 : t_total;

    // Includes the sample being retired this cycle, because w_sum is only updated
    // at the end of this same always block - without it the mean would be a
    // 65535-sample sum divided by 65536.
    wire [39:0] sum_x10  = ({8'd0, w_sum} + {24'd0, t_capped}) * 40'd10;
    // sum_x10 is 40 bits, so the shifted result is bits [39:WINDOW_BITS] - 24 bits
    // here, zero-extended.  Writing it as [WINDOW_BITS +: 32] selects [47:16],
    // which is out of range: iverilog silently zero-extends, Vivado rejects it.
    // Worst case is 2**16 * 1023 * 10 = 670e6, so 24 bits after the shift is
    // ample (max mean_x10 = 10230, i.e. 1023.0 cycles).
    wire [31:0] mean_x10 = {8'd0, sum_x10[39:WINDOW_BITS]};
    reg [15:0] t_wait, t_data;
    reg [15:0] gap_cnt;

    assign wb_sel = {SEL_BITS{1'b1}};
    assign wb_aux = {AUX_WIDTH{1'b0}};

    // Pattern is a pure function of the index, so a readback mismatch localises
    // itself: the returned word says which address it really came from.
    function [DATA_BITS-1:0] pattern(input [INDEX_BITS-1:0] idx);
        integer w;
        begin
            for (w = 0; w < DATA_BITS/32; w = w + 1)
                pattern[w*32 +: 32] = {{(32-INDEX_BITS){1'b0}}, idx} ^ (32'h5A5A_0000 + w);
        end
    endfunction

    // Maximal-length Galois LFSR.  16-bit tap set 0xB400.
    function [INDEX_BITS-1:0] lfsr_next(input [INDEX_BITS-1:0] v);
        begin
            lfsr_next = v[0] ? ((v >> 1) ^ {{(INDEX_BITS-16){1'b0}}, 16'hB400})
                             : (v >> 1);
        end
    endfunction

    wire accepted = wb_stb && !wb_stall;

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            mode          <= 1'b0;
            wb_cyc        <= 1'b0;
            wb_stb        <= 1'b0;
            wb_we         <= 1'b0;
            wb_addr       <= {ADDR_BITS{1'b0}};
            wb_data       <= {DATA_BITS{1'b0}};
            fill_idx      <= {INDEX_BITS{1'b0}};
            fill_acks     <= {INDEX_BITS{1'b0}};
            seq_idx       <= {INDEX_BITS{1'b0}};
            lfsr          <= {{(INDEX_BITS-1){1'b0}}, 1'b1};
            cur_idx       <= {INDEX_BITS{1'b0}};
            pass_count    <= 16'd0;
            t_wait        <= 16'd0;
            t_data        <= 16'd0;
            seq_max_total <= 16'd0;
            seq_min_total <= 16'hFFFF;
            rnd_max_total <= 16'd0;
            rnd_min_total <= 16'hFFFF;
            last_wait     <= 16'd0;
            last_data     <= 16'd0;
            data_error    <= 1'b0;
            refresh_ok    <= 1'b0;
            gap_cnt       <= 16'd0;
            w_min         <= 16'hFFFF;
            w_max         <= 16'd0;
            w_sum         <= 32'd0;
            w_gt_gs       <= 32'd0;
            w_gt_leg      <= 32'd0;
            win_count     <= 32'd0;
            seq_min_w     <= 16'd0;
            seq_mean_x10  <= 32'd0;
            seq_max_w     <= 16'd0;
            seq_gt_gs     <= 32'd0;
            seq_gt_leg    <= 32'd0;
            rnd_min_w     <= 16'd0;
            rnd_mean_x10  <= 32'd0;
            rnd_max_w     <= 16'd0;
            rnd_gt_gs     <= 32'd0;
            rnd_gt_leg    <= 32'd0;
            err_count     <= 32'd0;
        end else begin
            case (state)

                // Hold off until the controller says calibration (and, if
                // BIST_MODE != 0, its own self-test) has finished.  Requests
                // before that are not accepted.
                S_IDLE: begin
                    wb_cyc <= 1'b0;
                    wb_stb <= 1'b0;
                    if (calib_complete) begin
                        state    <= S_FILL;
                        wb_cyc   <= 1'b1;
                        wb_stb   <= 1'b1;
                        wb_we    <= 1'b1;
                        wb_addr  <= {{(ADDR_BITS-INDEX_BITS){1'b0}}, {INDEX_BITS{1'b0}}};
                        wb_data  <= pattern({INDEX_BITS{1'b0}});
                        fill_idx <= {INDEX_BITS{1'b0}};
                        fill_acks<= {INDEX_BITS{1'b0}};
                    end
                end

                // Streaming write of the whole test region.  This one IS
                // pipelined - it is just setup, not a measurement.
                S_FILL: begin
                    if (wb_ack) fill_acks <= fill_acks + 1'b1;
                    if (accepted) begin
                        if (&fill_idx) begin
                            wb_stb <= 1'b0;
                            state  <= S_FILL_DRAIN;
                        end else begin
                            fill_idx <= fill_idx + 1'b1;
                            wb_addr  <= {{(ADDR_BITS-INDEX_BITS){1'b0}}, (fill_idx + 1'b1)};
                            wb_data  <= pattern(fill_idx + 1'b1);
                        end
                    end
                end

                // Every write must retire before the read passes start, or a
                // read could overtake the write to the same address.
                S_FILL_DRAIN: begin
                    if (wb_ack) fill_acks <= fill_acks + 1'b1;
                    // fill_acks wraps to 0 on the last of the 2**INDEX_BITS acks.
                    if (wb_ack && (&fill_acks)) begin
                        state   <= GATE_EMULATE ? S_GAP : S_REQ;
                        gap_cnt <= 16'd0;
                        mode    <= 1'b0;
                        seq_idx <= {INDEX_BITS{1'b0}};
                        cur_idx <= {INDEX_BITS{1'b0}};
                    end
                end

                // Raise stb and start the clock.  t_wait counts the stall.
                S_REQ: begin
                    wb_cyc  <= 1'b1;
                    wb_stb  <= 1'b1;
                    wb_we   <= 1'b0;
                    wb_addr <= {{(ADDR_BITS-INDEX_BITS){1'b0}}, cur_idx};
                    if (wb_stb) begin
                        if (accepted) begin
                            wb_stb <= 1'b0;
                            t_data <= 16'd1;
                            state  <= S_WAIT_ACK;
                        end else begin
                            t_wait <= t_wait + 1'b1;
                        end
                    end else begin
                        // First cycle of this request: stb goes up now, so the
                        // stall on this edge is not yet ours to count.
                        t_wait <= 16'd0;
                    end
                end

                S_WAIT_ACK: begin
                    if (wb_ack) begin
                        if (wb_rdata != pattern(cur_idx)) begin
                            data_error <= 1'b1;
                            err_count  <= err_count + 1'b1;
                        end
                        last_wait <= t_wait;
                        last_data <= t_data;
                        state     <= S_NEXT;
                    end else begin
                        t_data <= t_data + 1'b1;
                    end
                end

                S_NEXT: begin
                    // t_total for the access that just completed.
                    if (mode == 1'b0) begin
                        if ((t_wait + t_data) > seq_max_total)
                            seq_max_total <= t_wait + t_data;
                        if ((t_wait + t_data) < seq_min_total)
                            seq_min_total <= t_wait + t_data;
                    end else begin
                        if ((t_wait + t_data) > rnd_max_total)
                            rnd_max_total <= t_wait + t_data;
                        if ((t_wait + t_data) < rnd_min_total)
                            rnd_min_total <= t_wait + t_data;
                    end

                    // A pass is 2**INDEX_BITS accesses, then swap pattern.  Both
                    // maxima are cumulative and never cleared: a refresh
                    // collision is rare (one per 7.8 us of DDR3 time) and the
                    // point is to catch it, so the worst case must persist.
                    // Window accumulation for the UART report.
                    if (t_total < w_min) w_min <= t_total;
                    if (t_total > w_max) w_max <= t_total;
                    w_sum <= w_sum + {16'd0, t_capped};
                    if (t_total > GS_BUDGET_CYCLES)     w_gt_gs  <= w_gt_gs  + 1'b1;
                    if (t_total > LEGACY_BUDGET_CYCLES) w_gt_leg <= w_gt_leg + 1'b1;

                    // End of window: snapshot for the pattern that just finished,
                    // then start the next window clean.  mode flips below, so the
                    // window belongs to the CURRENT mode, not the next one.
                    if (&pass_count) begin
                        if (mode == 1'b0) begin
                            seq_min_w    <= (t_total < w_min) ? t_total : w_min;
                            seq_max_w    <= (t_total > w_max) ? t_total : w_max;
                            seq_mean_x10 <= mean_x10;
                            seq_gt_gs    <= w_gt_gs;
                            seq_gt_leg   <= w_gt_leg;
                        end else begin
                            rnd_min_w    <= (t_total < w_min) ? t_total : w_min;
                            rnd_max_w    <= (t_total > w_max) ? t_total : w_max;
                            rnd_mean_x10 <= mean_x10;
                            rnd_gt_gs    <= w_gt_gs;
                            rnd_gt_leg   <= w_gt_leg;
                        end
                        w_min     <= 16'hFFFF;
                        w_max     <= 16'd0;
                        w_sum     <= 32'd0;
                        w_gt_gs   <= 32'd0;
                        w_gt_leg  <= 32'd0;
                        win_count <= win_count + 1'b1;
                    end

                    pass_count <= pass_count + 1'b1;
                    seq_idx    <= seq_idx + 1'b1;
                    lfsr       <= lfsr_next(lfsr);
                    if (&pass_count) mode <= ~mode;
                    cur_idx <= (mode ^ (&pass_count)) ? lfsr_next(lfsr)
                                                      : (seq_idx + 1'b1);
                    gap_cnt <= 16'd0;
                    state   <= GATE_EMULATE ? S_GAP : S_REQ;
                end

                // An idle bus cycle: nothing is asked of the DDR3, and for the
                // first GATE_ASSERT_CLKS of it the controller is invited to take
                // a refresh.  refresh_ok drops well before the gap ends so the
                // refresh completes inside it rather than stalling the next read.
                S_GAP: begin
                    wb_stb     <= 1'b0;
                    refresh_ok <= (gap_cnt < GATE_ASSERT_CLKS[15:0]);
                    if (gap_cnt >= IDLE_CLKS[15:0] - 16'd1) begin
                        gap_cnt    <= 16'd0;
                        refresh_ok <= 1'b0;
                        state      <= S_REQ;
                    end else begin
                        gap_cnt <= gap_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- display ----------------------------------------------------------
    reg [31:0] disp_div;
    reg        disp_sel;

    always @(posedge clk) begin
        if (rst) begin
            disp_div <= 32'd0;
            disp_sel <= 1'b0;
        end else if (disp_div >= DISPLAY_DIV - 1) begin
            disp_div <= 32'd0;
            disp_sel <= ~disp_sel;
        end else begin
            disp_div <= disp_div + 1'b1;
        end
    end

    wire [15:0] shown = disp_sel ? rnd_max_total : seq_max_total;
    wire [6:0]  shown_sat = (shown > 16'd127) ? 7'd127 : shown[6:0];

    assign led = data_error      ? 8'hFF :
                 !calib_complete ? 8'h01 : {disp_sel, shown_sat};

endmodule
