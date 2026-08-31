`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// wb_lines - four merging write-back lines between the D front and the image.
//
// A write the front serves lands here as one byte; consecutive writes into
// the same 16-byte line merge into one entry, and the entry flushes as a
// single line write - the DMA drain's own shape: a dq_* push into
// mem_client's in-order queue (which already forbids a fill passing a
// drained line) followed by an inv_line walk of the L2, whose way was never
// told about these bytes.  FOUR lines, not one, because zp/stack writes are
// half the write traffic and would otherwise flush a streaming line on
// every interleaved store (docs/DCACHE_PLAN.md, the user's design).
//
// WHO SEES STALE DATA, AND WHY IT CANNOT: the lines shadow ONLY DDR3 and
// the L2's ways - never the L1s (the front updates its own copies at
// retirement).  A read miss descending to the L2 for a line held dirty here
// is REFUSED by mem_cache (it compares against the dirty lines and declines
// to decide-serve), retried by the sequencer, and satisfied once the flush
// lands - the compare-and-stall rule.  A classified (bus-path) write to a
// byte held here PURGES that byte's enable: the bus write's own mq push is
// later in the same in-order queue, so the purge makes the flush harmless
// rather than racing it.  A drain line landing on a dirty line purges the
// whole line (the mid-DMA overlap is documented-undefined; the drain wins).
// The host's invalidate DISCARDS all lines - the host is replacing the
// image, and flushing stale bytes into it would corrupt the new truth.
//
// FLUSHES: a fifth distinct line evicts the oldest dirty one; a dirty line
// untouched for AGE_IDLE clocks flushes on its own (which is what unwinds
// mem_cache's refusal loop); an override pending (ovr_flush) drains
// everything - a DMA or a hold boundary must find the image settled.
//////////////////////////////////////////////////////////////////////////////////
module wb_lines #(
    parameter integer AGE_IDLE = 24
) (
    input  wire        clk,
    input  wire        rst,            // rst_core

    // The front's byte (registered there; aw_ok answered for its verdict).
    input  wire        aw_en,
    input  wire [23:0] aw_pa,
    input  wire [7:0]  aw_data,
    output wire        aw_ok,

    // The classified stream's purge, and the drain's.
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [23:0] cl_pa,
    input  wire        snoop2_en,
    input  wire [23:0] snoop2_pa,

    // Flush stimuli.
    input  wire        ovr_flush,      // an override wants the image settled
    input  wire        mem_invalidating,

    // The flush path: a dq push (behind the hd drain in master_top's arb),
    // then the inv_line walk (same arb).
    output logic        wq_valid,
    output logic [19:0] wq_line,
    output logic [15:0] wq_be,
    output logic [127:0] wq_data,
    input  wire         wq_ready,      // arb grant AND mem_client ready
    output logic        winv_en,
    output wire  [23:0] winv_pa,
    input  wire         winv_rdy,      // arb grant AND mem_cache ready

    // The refusal compare, for mem_cache.
    output wire [3:0]   wb_dirty,
    output wire [79:0]  wb_lines_flat,  // 4 x 20-bit line addresses

    // Sim visibility.
    output logic [31:0] flushes
);

    logic [19:0]  l_line [0:3];
    logic [15:0]  l_be   [0:3];
    logic [127:0] l_data [0:3];
    logic         l_dirty[0:3];
    logic [7:0]   l_age  [0:3];

    assign wb_dirty = {l_dirty[3], l_dirty[2], l_dirty[1], l_dirty[0]};
    assign wb_lines_flat = {l_line[3], l_line[2], l_line[1], l_line[0]};

    // ---- the flush engine ----------------------------------------------------
    // F_CAP exists for one race: a byte merging on the very edge F_IDLE
    // selects a line would be captured pre-merge (nonblocking reads the old
    // word) and then lost when the flush clears dirty.  So selection and
    // capture are two edges: once f_sel is registered the line is excluded
    // from merges (flushing), and the capture the clock after sees every
    // byte that ever landed.
    typedef enum logic [1:0] {F_IDLE, F_CAP, F_PUSH, F_INV} f_t;
    f_t f_st;
    logic [1:0] f_sel;
    assign winv_pa = {l_line[f_sel], 4'd0};

    wire flushing = (f_st != F_IDLE);

    // ---- match and allocation ------------------------------------------------
    wire [19:0] aw_line = aw_pa[23:4];
    logic [3:0] aw_m;
    logic [3:0] free_m;
    always_comb begin
        for (int i = 0; i < 4; i = i + 1) begin
            // A line mid-flush neither matches nor frees: its be/data are on
            // their way out and must not move.
            aw_m[i]   = l_dirty[i] && (l_line[i] == aw_line) &&
                        !(flushing && f_sel == 2'(i));
            free_m[i] = !l_dirty[i] && !(flushing && f_sel == 2'(i));
        end
    end
    wire aw_match = |aw_m;
    // aw_ok is a REGISTERED level: "a free line will exist next clock" -
    // the front's serve verdict may carry one flip-flop of this module, not
    // its comparator chains (the first build's worst path threaded aw_pa ->
    // these compares -> the verdict -> the D$'s steer, three modules deep).
    // Conservative on both sides: it ignores lines freed this edge, and it
    // charges this edge's own allocation.  A merging streak whose line is
    // dirty still merges - the gate only demands headroom beside it, and
    // under all-dirty pressure the flush engine is already running.
    logic aw_ok_q;
    assign aw_ok = aw_ok_q;

    wire [1:0] aw_slot = aw_m[0] ? 2'd0 : aw_m[1] ? 2'd1 :
                         aw_m[2] ? 2'd2 : aw_m[3] ? 2'd3 :
                         free_m[0] ? 2'd0 : free_m[1] ? 2'd1 :
                         free_m[2] ? 2'd2 : 2'd3;

    // ---- who flushes next ----------------------------------------------------
    // Any line at its idle age; under pressure (no free line) or an override,
    // the oldest dirty one.
    wire        pressure = !(|free_m) || ovr_flush;
    logic [1:0] old_sel;
    logic [7:0] old_age;
    logic       want_flush;
    always_comb begin
        old_sel = 2'd0; old_age = 8'd0; want_flush = 1'b0;
        for (int i = 0; i < 4; i = i + 1) begin
            if (l_dirty[i] && l_age[i] >= old_age) begin
                old_sel = 2'(i); old_age = l_age[i];
            end
            if (l_dirty[i] && (pressure || l_age[i] >= 8'(AGE_IDLE)))
                want_flush = 1'b1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk)
        if (aw_en && !aw_match && !(|free_m))
            $fatal(1, "wb_lines: a byte arrived with no line to take it");
`endif

    integer j;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (j = 0; j < 4; j = j + 1) begin
                l_line[j] <= 20'd0; l_be[j] <= 16'd0; l_data[j] <= 128'd0;
                l_dirty[j] <= 1'b0; l_age[j] <= 8'd0;
            end
            f_st <= F_IDLE; f_sel <= 2'd0;
            wq_valid <= 1'b0; wq_line <= 20'd0; wq_be <= 16'd0; wq_data <= 128'd0;
            winv_en <= 1'b0; aw_ok_q <= 1'b0;
            flushes <= 32'd0;
        end else begin
            // (free lines now, less the one this edge's byte may claim)
            aw_ok_q <= ($countones(free_m) >
                        ((aw_en && aw_ok_q && !aw_match) ? 1 : 0));
            // ---- ages --------------------------------------------------------
            for (j = 0; j < 4; j = j + 1)
                if (l_dirty[j] && l_age[j] != 8'hFF) l_age[j] <= l_age[j] + 8'd1;

            // ---- the front's byte -------------------------------------------
            if (aw_en && aw_ok) begin
                l_line[aw_slot]  <= aw_line;
                l_dirty[aw_slot] <= 1'b1;
                l_age[aw_slot]   <= 8'd0;
                l_data[aw_slot][8 * aw_pa[3:0] +: 8] <= aw_data;
                if (aw_match) l_be[aw_slot] <= l_be[aw_slot] | (16'd1 << aw_pa[3:0]);
                else          l_be[aw_slot] <= 16'd1 << aw_pa[3:0];
            end

            // ---- purges ------------------------------------------------------
            // A classified image write: that byte's enable dies (the bus
            // write's own queue entry carries the fresh byte).  The drain:
            // the whole line dies.  They apply to the lines up THROUGH
            // F_CAP (the capture then sees the result), and to the captured
            // word while its push waits (F_PUSH) - the purger's queue entry
            // may enter first, and a stale byte behind it would win.  Once
            // the push is ACCEPTED (F_INV), the entry is in the in-order
            // queue ahead of the purger's, and the queue resolves it.
            for (j = 0; j < 4; j = j + 1) begin
                if (l_dirty[j] &&
                    !((f_st == F_PUSH || f_st == F_INV) && f_sel == 2'(j))) begin
                    if (cl_valid && !cl_rw && cl_wr_image &&
                        cl_pa[23:4] == l_line[j]) begin
                        l_be[j] <= l_be[j] & ~(16'd1 << cl_pa[3:0]);
                        if ((l_be[j] & ~(16'd1 << cl_pa[3:0])) == 16'd0)
                            l_dirty[j] <= 1'b0;
                    end
                    if (snoop2_en && snoop2_pa[23:4] == l_line[j])
                        l_dirty[j] <= 1'b0;
                end
            end
            if (f_st == F_PUSH) begin
                if (cl_valid && !cl_rw && cl_wr_image && cl_pa[23:4] == wq_line)
                    wq_be <= wq_be & ~(16'd1 << cl_pa[3:0]);
                if (snoop2_en && snoop2_pa[23:4] == wq_line)
                    wq_be <= 16'd0;
            end

            // The invalidate deliberately does NOT touch the lines: a BARE
            // invalidate (the L2 walk without an image reload) leaves these
            // bytes the ONLY copy of recent writes, and they must land in
            // DDR3 - they flush by age through the walk.  A host RELOAD
            // replaces the image with the machine held, and the override's
            // flush drained everything before the hold ended, so there is
            // nothing here to corrupt the new image with.

            // ---- the flush engine --------------------------------------------
            case (f_st)
                F_IDLE: if (want_flush) begin
                    f_sel <= old_sel;
                    f_st  <= F_CAP;
                end
                F_CAP: begin
                    // The line has been excluded for a full clock: capture.
                    // A purge may have emptied it meanwhile - then there is
                    // nothing to push and the line is simply done.
                    if (!l_dirty[f_sel]) begin
                        f_st <= F_IDLE;
                    end else begin
                        f_st     <= F_PUSH;
                        wq_valid <= 1'b1;
                        wq_line  <= l_line[f_sel];
                        wq_be    <= l_be[f_sel];
                        wq_data  <= l_data[f_sel];
                    end
                end
                F_PUSH: if (wq_valid && wq_ready) begin
                    wq_valid <= 1'b0;
                    winv_en  <= 1'b1;
                    f_st     <= F_INV;
                end
                F_INV: if (winv_en && winv_rdy) begin
                    winv_en <= 1'b0;
                    l_dirty[f_sel] <= 1'b0;
                    flushes <= flushes + 32'd1;
                    f_st    <= F_IDLE;
                end
                default: f_st <= F_IDLE;
            endcase
        end
    end

endmodule
