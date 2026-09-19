`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// bank_census - the card's copy of sim/boot_gs_tb.sv's bank census
// (docs/LONG_DATA.md rung 0): how much of real software's data traffic is of
// the OTHER bank class, and how often its bank is among the last 1, 2 or 4
// DISTINCT OTHER banks - the number that sizes the data front's bank table.
//
// Counted once per data cycle the core PREDICTED (d_pred_v), at the edge it
// moved.  An OTHER cycle into $C000-$CFFF of a pair bank ($00/$01/$E0/$E1) is
// I/O and counted apart - no line serves it.  The rest, OTHER memory, is looked
// up in a four-entry table of distinct banks, most recent first, and the
// position it was found at is counted; then it moves to the front.
//
// NOTHING HERE TAPS A LIVE CONE.  d_pred's address inherits din's timing and
// is the design's deepest path, and cyc_en is the serve decision.  The inputs
// are copies master_top ALREADY registers every clock for the debug pair -
// the clock histogram's RETIRE tap (cyc_en), top_w4_q (d_pred_v, _rw, _bcls)
// and top_w3_q (dline's registered candidate) - so this adds a load to none of
// them.  Their alignment: on the edge E the core moves, dline registers the
// candidate while h_ret and top_w4_q register the move and the prediction's
// bits; on E+1 top_w3_q registers the candidate.  So the move and the bits
// wait one clock here (stage 0) to meet it, stage 1 classifies, and the table
// is looked up and the counters stepped on the clock after - three clocks
// from the snapshot, a sample at most every clock.  The counters and the
// table clear with the ACCEL_* pulse.
//
// Debug items (DBG_SEL[7:6] = 1, the item in [3:0]):
//   0  data cycles predicted          4  OTHER memory, its bank was the last
//   1  OTHER memory reads             5  ...the second most recent
//   2  OTHER memory writes            6  ...the third or fourth
//   3  OTHER I/O                      7  ...in none of them
//   8  the table, most recent first, {tab[0], tab[1], tab[2], tab[3]}
//   9  its valid bits
// The last 1 / 2 / 4 are items 4, 4+5, 4+5+6, over items 1+2.
//////////////////////////////////////////////////////////////////////////////////
module bank_census (
    input  wire        clk,
    input  wire        rst,
    input  wire        clr,
    input  wire        moved_q,     // the core moved on the previous edge (registered cyc_en)
    input  wire        pv_q,        // d_pred_v, registered on that same edge
    input  wire        prw_q,       // d_pred_rw, likewise
    input  wire [1:0]  pcls_q,      // d_pred_bcls, likewise
    input  wire [23:0] cand_qq,     // dline's candidate, registered one edge later still
    input  wire [3:0]  sel,
    output logic [31:0] dbg
);
    localparam [1:0] BCLS_OTHER = 2'd2;

    // Stage 0: the move and the prediction's bits, one clock more.
    logic       s0_v, s0_rw;
    logic [1:0] s0_cls;
    // Stage 1: classified against the candidate.
    logic       s1_data, s1_mem, s1_io, s1_rw;
    logic [7:0] s1_bank;
    // The table: distinct banks, most recent first; valid entries are a prefix.
    logic [7:0] tab [0:3];
    logic [3:0] tv;
    logic [31:0] c_data, c_mrd, c_mwr, c_io, c_p0, c_p1, c_p23, c_miss;

    wire [7:0] b     = cand_qq[23:16];
    wire       pair  = (b == 8'h00) || (b == 8'h01) || (b == 8'hE0) || (b == 8'hE1);
    wire       io_w  = pair && (cand_qq[15:12] == 4'hC);

    wire [3:0] m;
    genvar gi;
    generate for (gi = 0; gi < 4; gi = gi + 1) begin : g_m
        assign m[gi] = tv[gi] && (tab[gi] == s1_bank);
    end endgenerate
    // The entries are distinct, so at most one matches.
    wire [2:0] pos = m[0] ? 3'd0 : m[1] ? 3'd1 : m[2] ? 3'd2 : m[3] ? 3'd3 : 3'd4;
    // To the front: entries 0..sh-1 move down one; a miss drops the last.
    wire [1:0] sh  = (pos == 3'd4) ? 2'd3 : pos[1:0];

    always_ff @(posedge clk) begin
        s0_v   <= moved_q && pv_q;
        s0_rw  <= prw_q;
        s0_cls <= pcls_q;

        s1_data <= s0_v && (s0_cls != 2'd3);
        s1_mem  <= s0_v && (s0_cls == BCLS_OTHER) && !io_w;
        s1_io   <= s0_v && (s0_cls == BCLS_OTHER) &&  io_w;
        s1_rw   <= s0_rw;
        s1_bank <= b;

        if (rst || clr) begin
            tv     <= 4'd0;
            c_data <= 32'd0; c_mrd <= 32'd0; c_mwr <= 32'd0; c_io  <= 32'd0;
            c_p0   <= 32'd0; c_p1  <= 32'd0; c_p23 <= 32'd0; c_miss <= 32'd0;
        end else begin
            if (s1_data) c_data <= c_data + 32'd1;
            if (s1_io)   c_io   <= c_io   + 32'd1;
            if (s1_mem) begin
                if (s1_rw) c_mrd <= c_mrd + 32'd1;
                else       c_mwr <= c_mwr + 32'd1;
                case (pos)
                    3'd0:       c_p0   <= c_p0   + 32'd1;
                    3'd1:       c_p1   <= c_p1   + 32'd1;
                    3'd2, 3'd3: c_p23  <= c_p23  + 32'd1;
                    default:    c_miss <= c_miss + 32'd1;
                endcase
                for (int k = 3; k > 0; k--)
                    if (k <= int'(sh)) begin
                        tab[k] <= tab[k-1];
                        tv[k]  <= tv[k-1];
                    end
                tab[0] <= s1_bank;
                tv[0]  <= 1'b1;
            end
        end
    end

    always_comb begin
        case (sel)
            4'd0:    dbg = c_data;
            4'd1:    dbg = c_mrd;
            4'd2:    dbg = c_mwr;
            4'd3:    dbg = c_io;
            4'd4:    dbg = c_p0;
            4'd5:    dbg = c_p1;
            4'd6:    dbg = c_p23;
            4'd7:    dbg = c_miss;
            4'd8:    dbg = {tab[0], tab[1], tab[2], tab[3]};
            4'd9:    dbg = {28'd0, tv};
            default: dbg = 32'd0;
        endcase
    end
endmodule
