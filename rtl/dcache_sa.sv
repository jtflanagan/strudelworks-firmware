`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// dcache_sa - a small fully-associative line buffer, the D$'s little rival.
//
// The measured question (docs/DCACHE_PLAN.md): with zp/stack owned by their
// dedicated store, the residual data working set is about two pages at a
// time - does a 4KB direct-mapped cache earn its block RAM, or do N lines
// of LUTRAM hold the same hit rate?  This module answers by being PORT-
// COMPATIBLE with dcache_l1 so d_front instantiates either (CAM_D): same
// 25-bit physical tags, same fill-by-observation, same snoop, same
// three-clock serve alignment.  steer_idx/steer_tag/wr_idx are accepted
// and ignored - the CAM match IS the steering, and the write lands in the
// way the previous edge's match named.
//
// N lines, each {tag[20:0] = {rom, pa[23:4]}, valid}, data in LUTRAM.
// Every edge the CAM matches look_pa, the matched way's line loads into
// the row register, and the *_next outputs say what the verdict clock
// will find - the same contract dcache_l1's two-deep BRAM read exports,
// one stage shorter inside but held to the same clocking by the front's
// windows.  Eviction: the first invalid way, else round-robin.
//////////////////////////////////////////////////////////////////////////////////
module dcache_sa #(
    parameter integer N = 8
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         flash,

    input  wire [24:0]  look_pa,
    output wire         look_hit,
    output wire         look_ok,
    output wire         look_hit_next,
    output wire         look_ok_next,
    output wire [7:0]   look_byte,

    // Ignored: the CAM needs no steering.
    input  wire [7:0]   steer_idx,
    input  wire [12:0]  steer_tag,

    input  wire         inst_en,
    input  wire [24:0]  inst_pa,
    input  wire [127:0] inst_line,

    // wr_idx ignored: the write lands in the way the match named.
    input  wire         wr_en,
    input  wire [7:0]   wr_idx,
    input  wire [3:0]   wr_byte,
    input  wire [7:0]   wr_data,

    input  wire         snoop_en,
    input  wire [23:0]  snoop_pa
);

    localparam integer W = $clog2(N);

    logic [20:0]  tag  [0:N-1];
    logic [N-1:0] vldv;
    (* ram_style = "distributed" *) logic [127:0] data [0:N-1];

    // ---- the CAM, off registered look_pa ------------------------------------
    logic [N-1:0] mt;
    always_comb begin
        for (int g = 0; g < N; g = g + 1)
            mt[g] = vldv[g] && (tag[g] == look_pa[24:4]);
    end
    logic [W-1:0] menc;
    always_comb begin
        menc = '0;
        for (int g = N - 1; g >= 0; g = g - 1)
            if (mt[g]) menc = W'(g);
    end

    // ---- the victim ---------------------------------------------------------
    logic [W-1:0] rr;
    logic [W-1:0] vic;
    always_comb begin
        vic = rr;
        for (int g = N - 1; g >= 0; g = g - 1)
            if (!vldv[g]) vic = W'(g);
    end

    // ---- the snoop ----------------------------------------------------------
    logic [N-1:0] sn;
    always_comb begin
        for (int g = 0; g < N; g = g + 1)
            sn[g] = snoop_en && vldv[g] &&
                    (tag[g] == {1'b0, snoop_pa[23:4]});
    end

    // ---- the row in flight --------------------------------------------------
    logic [127:0] row;
    logic [W-1:0] way_q;
    logic         hit_q;

    // A writer or the snoop landing on the matched way this edge leaves the
    // loading row stale; the flash and reset kill everything.
    wire kills_now = rst || flash ||
                     (inst_en && (vic == menc || !(|mt))) ||
                     (wr_en && way_q == menc) ||
                     (|(sn & mt));

    assign look_hit      = hit_q;
    assign look_ok       = 1'b1;       // the CAM always answered: a miss is proven
    assign look_hit_next = (|mt) && !kills_now;
    assign look_ok_next  = !kills_now;
    assign look_byte     = row[8 * look_pa[3:0] +: 8];

`ifndef SYNTHESIS
    always @(posedge clk)
        if (inst_en && wr_en)
            $fatal(1, "dcache_sa: install and byte write on one clock");
`endif

    always_ff @(posedge clk) begin
        row   <= data[menc];
        way_q <= menc;
        hit_q <= (|mt) && !kills_now;

        if (wr_en)
            data[way_q][8 * wr_byte +: 8] <= wr_data;
        else if (inst_en) begin
            data[vic] <= inst_line;
            tag[vic]  <= inst_pa[24:4];
        end

        if (rst || flash) begin
            vldv <= '0;
            rr   <= '0;
        end else begin
            if (inst_en) rr <= (rr == W'(N - 1)) ? '0 : rr + 1'b1;
            vldv <= (vldv | (inst_en ? (N'(1) << vic) : '0)) & ~sn;
        end
    end

endmodule
