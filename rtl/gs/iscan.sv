`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// iscan - the 65816 card's branch scanner (docs/CORE_REFACTOR_65816.md rung 4;
// the user's design of 2026-09-19: "branch prefetch is the top lever").
//
// Lives inside rtl/gs/l1i.sv.  Walks instruction boundaries forward from the
// program's last opcode fetch through the two held line buffers, one
// instruction per clock (a beat per operand byte for a transfer, and a
// granted beat of its own for the target's math and the want, S_TGT), using
// THE 65816's LENGTHS: the immediates follow M and X (p_flags, register-
// direct from the core; both read 1 in emulation), and the long, stack-
// relative and block-move forms have their own.  For every conditional
// branch, BRA, BRL, JMP abs, JSR abs, and a JSL or JML abs-long whose bank
// is the program's own, it names the target's line so L1-I can fetch it
// BEFORE the PC arrives - the branch's bubble is the fill it would have paid.
// It follows unconditional flow and falls through conditional branches; RTS,
// RTL, RTI, BRK, COP, the indirect jumps and a transfer out of the bank end
// the trail, and the next opcode fetch anchors a new one.
//
// THE SCANNER CANNOT BE WRONG, ONLY WASTEFUL (the old scanner's law): its only
// outputs are wants, classified, filtered and snooped by the fill engine like
// any other fill, and the loop bit.  A misdecoded stream derails the walk and
// at worst prefetches a line nobody needs; the bytes served are always the
// buffers' own, snooped.  A wrong M or X (a REP/SEP mid-trail the walk has not
// executed) is the same: a derailed trail, not a wrong byte.
//
// THE SPLIT POINTER, THE SHADOWS, THE ANCHOR and THE LOOP BIT are the old
// scanner's (rtl/gs/iscan.sv before this rung, in git): 4-bit arithmetic in
// the walk beat, the next line's membership registered a beat ahead, a
// re-anchor when execution diverges from the trail, and a transfer found from
// one held line into the other pins the pair.  The maximum instruction length
// is FOUR here, so a step can leave ptr_lo <= 3 and the next carry is >= 3
// beats away: the memberships are never consumed stale.
//////////////////////////////////////////////////////////////////////////////////
module iscan (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire        intc8rom,
    input  wire        pair,          // the program bank is one of the I/O-window four
    input  wire        m_flag,        // P.M (1 = 8-bit accumulator immediates)
    input  wire        x_flag,        // P.X (1 = 8-bit index immediates)
    input  wire [7:0]  pc_bank,       // the program bank: a long transfer is followed only within it

    // The anchor: a program-stream opcode fetch completing this clock.
    input  wire        anchor_v,
    input  wire [15:0] anchor_addr,

    // The window: a byte of either held buffer, through l1i's mux.
    output wire        rd_slot,
    output wire [3:0]  rd_off,
    input  wire [7:0]  rd_byte,

    // The buffers' tags in the program bank: the loop bit and the held filter.
    input  wire        v0,
    input  wire        v1,
    input  wire [11:0] vtag0,
    input  wire [11:0] vtag1,

    // The prefetch want: one line, taken (or dropped) by the fill engine.
    output logic        sw_v,
    output logic [11:0] sw_tag,
    input  wire         sw_taken,

    // The loop bit: a transfer from lb_slot's line into the other slot's.
    output logic       lb_v,
    output logic       lb_slot
);
    // ---- the 65816's lengths, and the transfers the scan acts on ------------
    localparam [2:0] C_SEQ = 3'd0,   // continue at ptr + len
                     C_REL = 3'd1,   // conditional branch: target ptr+2+rel8
                     C_BRA = 3'd2,   // BRA: rel8, the target, and the scan follows
                     C_BRL = 3'd3,   // BRL: rel16, followed
                     C_ABS = 3'd4,   // JMP/JSR abs: the target, followed
                     C_LNG = 3'd5,   // JSL/JML abs long: followed if the bank is ours
                     C_END = 3'd6;   // RTS/RTL/RTI/BRK/COP/indirect: the trail ends

    // {class, length}: a wrong length only derails the walk.
    function automatic [5:0] opdec(input [7:0] op, input m, input x);
        logic [2:0] c;
        logic [2:0] l;
        begin
            c = C_SEQ; l = 3'd1;
            case (op[3:0])
                4'h0: case (op[7:4])
                    4'h0: begin c = C_END; l = 3'd2; end           // BRK
                    4'h2: begin c = C_ABS; l = 3'd3; end           // JSR abs
                    4'h4, 4'h6: begin c = C_END; l = 3'd1; end     // RTI, RTS
                    4'h8: begin c = C_BRA; l = 3'd2; end           // BRA
                    4'hA, 4'hC, 4'hE: l = x ? 3'd2 : 3'd3;         // LDY/CPY/CPX #
                    default: begin c = C_REL; l = 3'd2; end        // BPL..BEQ
                endcase
                4'h1: l = 3'd2;                                    // (dp),Y
                4'h2: case (op[7:4])
                    4'h0: begin c = C_END; l = 3'd2; end           // COP
                    4'h2: begin c = C_LNG; l = 3'd4; end           // JSL
                    4'h4: l = 3'd2;                                // WDM
                    4'h6: l = 3'd3;                                // PER
                    4'h8: begin c = C_BRL; l = 3'd3; end           // BRL
                    4'hA: l = x ? 3'd2 : 3'd3;                     // LDX #
                    4'hC, 4'hE: l = 3'd2;                          // REP, SEP
                    default: l = 3'd2;                             // (dp)
                endcase
                4'h3: l = 3'd2;                                    // sr,S ; (sr,S),Y
                4'h4: case (op[7:4])
                    4'h4, 4'h5: l = 3'd3;                          // MVP, MVN
                    4'hF: l = 3'd3;                                // PEA
                    default: l = 3'd2;                             // dp forms, PEI
                endcase
                4'h5, 4'h6, 4'h7: l = 3'd2;                        // dp, dp,X, [dp], [dp],Y
                4'h8: l = 3'd1;
                4'h9: l = op[4] ? 3'd3 : (m ? 3'd2 : 3'd3);        // abs,Y / A-immediate
                4'hA: l = 3'd1;
                4'hB: if (op == 8'h6B) begin c = C_END; l = 3'd1; end   // RTL
                      else l = 3'd1;
                4'hC: case (op)
                    8'h4C: begin c = C_ABS; l = 3'd3; end          // JMP abs
                    8'h5C: begin c = C_LNG; l = 3'd4; end          // JML abs long
                    8'h6C, 8'h7C, 8'hDC, 8'hFC: begin c = C_END; l = 3'd3; end   // the indirects
                    default: l = 3'd3;                             // abs
                endcase
                4'hD, 4'hE: l = 3'd3;                              // abs,X ; abs
                4'hF: l = 3'd4;                                    // abs long ; abs long,X
                default: ;
            endcase
            opdec = {c, l};
        end
    endfunction

    // ---- the walk ------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_OP = 3'd1, S_O1 = 3'd2, S_O2 = 3'd3, S_O3 = 3'd4,
                     S_TGT = 3'd5;
    logic [2:0]  st;
    logic [11:0] ptr_hi;
    logic [3:0]  ptr_lo;
    logic [11:0] ptr_hi_p1;
    logic        cur_in0, cur_in1;
    logic        nxt_in0, nxt_in1;
    logic        diverged_q;
    logic [2:0]  cls_q;
    logic [7:0]  o1_q, o2_q, o3_q;

    // The window read: a 4-bit add, the carry picking the next line's
    // registered answers.  At most one crossing per step (4 <= 16).
    wire [1:0] rd_inc  = (st == S_O3) ? 2'd3 : (st == S_O2) ? 2'd2 : (st == S_O1) ? 2'd1 : 2'd0;
    wire [4:0] rd_sum  = {1'b0, ptr_lo} + {3'b0, rd_inc};
    wire       rin0    = rd_sum[4] ? nxt_in0 : cur_in0;
    wire       rin1    = rd_sum[4] ? nxt_in1 : cur_in1;
    wire       rd_held = rin0 || rin1;
    assign rd_slot = !rin0;
    assign rd_off  = rd_sum[3:0];

    wire [5:0] dec     = opdec(rd_byte, m_flag, x_flag);
    wire [2:0] dec_cls = dec[5:3];
    wire [2:0] dec_len = dec[2:0];

    wire [4:0] step_sum = {1'b0, ptr_lo} + {2'b0, dec_len};
    wire [4:0] plus2    = {1'b0, ptr_lo} + 5'd2;
    wire [4:0] plus3    = {1'b0, ptr_lo} + 5'd3;

    // The target, from registers only: a relative's ptr already advanced to
    // the fall-through, so the target is ptr + the signed offset; an
    // absolute's is a concatenation.
    wire [15:0] tgt        = (cls_q == C_ABS || cls_q == C_LNG) ? {o2_q, o1_q} :
                             (cls_q == C_BRL) ? {ptr_hi, ptr_lo} + {o2_q, o1_q}
                                              : {ptr_hi, ptr_lo} + {{8{o1_q[7]}}, o1_q};
    wire [11:0] tgt_tag    = tgt[15:4];
    wire [11:0] tgt_tag_p1 = tgt_tag + 12'd1;
    wire        tgt_ours   = (cls_q != C_LNG) || (o3_q == pc_bank);

    wire tgt_held0 = v0 && (tgt_tag == vtag0);
    wire tgt_held1 = v1 && (tgt_tag == vtag1);
    wire tgt_excl  = pair && ((tgt_tag[11:4] == 8'hC0) ||
                              (tgt_tag[11:4] == 8'hC3 && !intc8rom) ||
                              (tgt_tag == 12'hCFF));

    logic src0, src1;
    wire issuing = (st == S_TGT) && tgt_ours;

    logic        last_v;
    logic [11:0] last_tag;

    wire [11:0] anchor_hi_p1 = anchor_addr[15:4] + 12'd1;

    always_ff @(posedge clk) begin
        lb_v <= 1'b0;
        if (rst || !enable) begin
            st <= S_IDLE; sw_v <= 1'b0; last_v <= 1'b0;
            ptr_hi <= 12'd0; ptr_lo <= 4'd0; ptr_hi_p1 <= 12'd1;
            cur_in0 <= 1'b0; cur_in1 <= 1'b0;
            nxt_in0 <= 1'b0; nxt_in1 <= 1'b0;
            diverged_q <= 1'b0;
            cls_q <= C_SEQ; o1_q <= 8'd0; o2_q <= 8'd0; o3_q <= 8'd0;
            sw_tag <= 12'd0; last_tag <= 12'd0; lb_slot <= 1'b0;
            src0 <= 1'b0; src1 <= 1'b0;
        end else begin
            if (sw_taken) sw_v <= 1'b0;

            ptr_hi_p1  <= ptr_hi + 12'd1;
            cur_in0    <= v0 && (ptr_hi    == vtag0);
            cur_in1    <= v1 && (ptr_hi    == vtag1);
            nxt_in0    <= v0 && (ptr_hi_p1 == vtag0);
            nxt_in1    <= v1 && (ptr_hi_p1 == vtag1);
            diverged_q <= ((({ptr_hi, ptr_lo} - anchor_addr) & 16'hFFC0) != 16'd0);

            case (st)
                S_IDLE: ;
                S_OP: begin
                    if (!rd_held) begin
                        st <= S_IDLE; last_v <= 1'b0;
                    end else case (dec_cls)
                        C_SEQ: begin
                            ptr_lo <= step_sum[3:0];
                            if (step_sum[4]) begin
                                ptr_hi    <= ptr_hi_p1;
                                ptr_hi_p1 <= ptr_hi_p1 + 12'd1;
                                cur_in0   <= nxt_in0;
                                cur_in1   <= nxt_in1;
                            end
                        end
                        C_END: begin st <= S_IDLE; last_v <= 1'b0; end
                        default: begin
                            cls_q <= dec_cls; st <= S_O1;
                            src0 <= cur_in0; src1 <= cur_in1;
                        end
                    endcase
                end
                S_O1: begin
                    if (!rd_held) begin
                        st <= S_IDLE; last_v <= 1'b0;
                    end else if (cls_q == C_ABS || cls_q == C_LNG || cls_q == C_BRL) begin
                        o1_q <= rd_byte; st <= S_O2;
                    end else begin
                        // rel8: the offset lands in a register; the fall-
                        // through advance happens now so S_TGT's add is
                        // ptr + offset for the conditional and BRA alike.
                        o1_q   <= rd_byte;
                        ptr_lo <= plus2[3:0];
                        if (plus2[4]) begin
                            ptr_hi    <= ptr_hi_p1;
                            ptr_hi_p1 <= ptr_hi_p1 + 12'd1;
                            cur_in0   <= nxt_in0;
                            cur_in1   <= nxt_in1;
                        end
                        st <= S_TGT;
                    end
                end
                S_O2: begin
                    if (!rd_held) begin
                        st <= S_IDLE; last_v <= 1'b0;
                    end else if (cls_q == C_LNG) begin
                        o2_q <= rd_byte; st <= S_O3;
                    end else if (cls_q == C_BRL) begin
                        // rel16: the fall-through is ptr + 3.
                        o2_q   <= rd_byte;
                        ptr_lo <= plus3[3:0];
                        if (plus3[4]) begin
                            ptr_hi    <= ptr_hi_p1;
                            ptr_hi_p1 <= ptr_hi_p1 + 12'd1;
                            cur_in0   <= nxt_in0;
                            cur_in1   <= nxt_in1;
                        end
                        st <= S_TGT;
                    end else begin
                        o2_q <= rd_byte; st <= S_TGT;
                    end
                end
                S_O3: begin
                    if (!rd_held) begin
                        st <= S_IDLE; last_v <= 1'b0;
                    end else begin
                        o3_q <= rd_byte; st <= S_TGT;
                    end
                end
                S_TGT: begin
                    if (cls_q == C_LNG && !tgt_ours) begin
                        st <= S_IDLE; last_v <= 1'b0;   // out of the bank: the trail ends
                    end else begin
                        if (cls_q != C_REL) begin      // BRA, BRL, JMP/JSR, JSL/JML followed
                            ptr_hi    <= tgt_tag;
                            ptr_lo    <= tgt[3:0];
                            ptr_hi_p1 <= tgt_tag_p1;
                            cur_in0   <= tgt_held0;
                            cur_in1   <= tgt_held1;
                            nxt_in0   <= v0 && (tgt_tag_p1 == vtag0);
                            nxt_in1   <= v1 && (tgt_tag_p1 == vtag1);
                        end
                        st <= S_OP;
                    end
                end
                default: st <= S_IDLE;
            endcase

            if (issuing) begin
                if (src0 && tgt_held1) begin lb_v <= 1'b1; lb_slot <= 1'b0; end
                if (src1 && tgt_held0) begin lb_v <= 1'b1; lb_slot <= 1'b1; end
                if (!tgt_held0 && !tgt_held1 && !tgt_excl &&
                    !(sw_v && !sw_taken) && !(last_v && tgt_tag == last_tag)) begin
                    sw_v     <= 1'b1;
                    sw_tag   <= tgt_tag;
                    last_v   <= 1'b1;
                    last_tag <= tgt_tag;
                end
            end

            if (anchor_v && (st == S_IDLE || diverged_q)) begin
                ptr_hi    <= anchor_addr[15:4];
                ptr_lo    <= anchor_addr[3:0];
                ptr_hi_p1 <= anchor_hi_p1;
                cur_in0   <= v0 && (anchor_addr[15:4] == vtag0);
                cur_in1   <= v1 && (anchor_addr[15:4] == vtag1);
                nxt_in0   <= v0 && (anchor_hi_p1 == vtag0);
                nxt_in1   <= v1 && (anchor_hi_p1 == vtag1);
                st  <= S_OP;
            end
        end
    end
endmodule
