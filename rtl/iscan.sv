`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// iscan - the instruction front's branch scanner.  docs/ISTREAM.md.
//
// Lives inside rtl/iline.sv.  Walks instruction boundaries forward from the
// program's last opcode fetch through the two held lines, one instruction per
// clock (three for a branch, four for a JMP/JSR - the operand bytes each take
// a read, and the target's math-and-decision takes a granted beat of its own,
// S_TGT below), using the 65C02's length table.  For every branch, JMP or JSR it
// finds, it names the target's line so the front can prefetch it into the
// retention CAM - the line stands ready before the branch is taken.  It
// follows unconditional flow (JMP abs, BRA, JSR) and falls through
// conditional branches, so it walks roughly the path the core will; RTS, RTI,
// BRK and the indirect jumps end the trail, and the next opcode fetch anchors
// a new one.
//
// THE SCANNER CANNOT BE WRONG, ONLY WASTEFUL.  Its only outputs are prefetch
// wants - classified, filtered and snooped by the fill engine like any other
// fill - and the loop bit.  A misdecoded stream (entering mid-instruction, or
// self-modifying code rewriting bytes mid-scan) derails the walk and at worst
// prefetches a line nobody needs; the line's BYTES are still fetched fresh
// and snooped from then on, so nothing stale can ever be served.  That is why
// there is no SMC hazard tracking here: a write that invalidates a scanned
// byte invalidates the LINES that hold it (the slots' and the CAM's snoops),
// never the scan's conclusions.
//
// THE SPLIT POINTER.  The walk only ever reads within 16-byte lines, so the
// pointer lives as {ptr_hi, ptr_lo} - line tag and offset - and the walk beat
// does 4-bit arithmetic only: a carry out of ptr_lo means "the next line",
// answered from state registered a beat ahead (ptr_hi_p1, and the cur_in*/
// nxt_in* slot memberships) instead of live 16-bit adds and 12-bit tag
// compares.  The shadows self-heal every beat from registers; the one
// crossing a step can cause leaves ptr_lo <= 2 (max instruction length 3), so
// the next carry-consuming event needs ptr_lo >= 13 and is >= 4 beats away -
// the memberships are never consumed stale.  vtag/v churn (rotation, snoop
// kills, invalidation) can leave a membership one beat stale: one garbage
// byte walked, a derailed trail at worst - wasteful, never wrong.
//
// THE LOOP BIT.  A transfer found FROM one held line INTO the other is the
// shape of a loop held whole in the pair.  iline uses it to suppress the
// crossing's rotation, pinning the pair so the backward branch stays the
// one-stall-beat within-pair case instead of a refetch per iteration.
//
// THE ANCHOR.  Every program-stream opcode fetch offers its address.  The
// scanner takes it when it has nothing (idle, or its trail left the held
// window) or when execution diverged from the trail - the pointer no longer
// within a short reach ahead of the program counter.  The divergence verdict
// is a beat old (diverged_q - the 16-bit subtract runs register-to-register,
// off the walk's cone), which costs one extra re-anchor beat per genuine
// divergence and nothing else; the idle-restart term stays live.  A tight
// loop re-anchors every iteration and rescans; the last-issued filter keeps
// that from hammering the engine with wants it has already made.
//////////////////////////////////////////////////////////////////////////////////
module iscan (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,        // turbo serving: the front's lines are live

    // The anchor: a program-stream opcode fetch completing this clock.
    input  wire        anchor_v,
    input  wire [15:0] anchor_addr,

    // The window: a byte of either held line, through iline's mux.  The
    // scanner resolves WHICH line itself (its registered memberships), so the
    // seam is just a slot bit and an offset; iline only muxes ldata.
    output wire        rd_slot,
    output wire [3:0]  rd_off,
    input  wire [7:0]  rd_byte,

    // The slots' tags: the loop bit and the already-held filter.
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

    // ---- the 65C02's lengths, and the transfers the scan acts on ------------
    localparam [2:0] C_SEQ = 3'd0,   // continue at ptr + len
                     C_REL = 3'd1,   // conditional branch: target ptr+2+rel
                     C_BRA = 3'd2,   // BRA: the target, and the scan follows
                     C_ABS = 3'd3,   // JMP/JSR abs: the target, followed
                     C_END = 3'd4;   // RTS/RTI/BRK/JMP(ind): the trail ends

    // {class, length}.  No Rockwell bit ops (the core is a 65SC02): rows
    // x7/xF are one-byte NOPs.  A wrong length only derails the walk.
    function automatic [4:0] opdec(input [7:0] op);
        logic [2:0] c;
        logic [1:0] l;
        begin
            c = C_SEQ; l = 2'd1;
            case (op[3:0])
                4'h0: case (op)
                    8'h00:               begin c = C_END; l = 2'd1; end  // BRK
                    8'h20:               begin c = C_ABS; l = 2'd3; end  // JSR
                    8'h40, 8'h60:        begin c = C_END; l = 2'd1; end  // RTI, RTS
                    8'h80:               begin c = C_BRA; l = 2'd2; end  // BRA
                    8'hA0, 8'hC0, 8'hE0: l = 2'd2;                       // LDY/CPY/CPX #
                    default:             begin c = C_REL; l = 2'd2; end  // BPL..BEQ
                endcase
                4'h1, 4'h2, 4'h4, 4'h5, 4'h6: l = 2'd2;   // (zp) modes, zp, imm
                4'h3, 4'h7, 4'h8, 4'hA, 4'hB, 4'hF: l = 2'd1;
                4'h9: l = op[4] ? 2'd3 : 2'd2;            // abs,Y / immediate
                4'hC: if (op == 8'h4C)                begin c = C_ABS; l = 2'd3; end
                      else if (op == 8'h6C || op == 8'h7C) begin c = C_END; l = 2'd3; end
                      else                            l = 2'd3;
                4'hD, 4'hE: l = 2'd3;
                default: ;
            endcase
            opdec = {c, l};
        end
    endfunction

    // ---- the walk ------------------------------------------------------------
    // S_TGT is the beat the scanner GRANTS ITSELF.  The depth audit's crown
    // path was one beat doing four arithmetic events in series: the window
    // address add, the held-line tag compare and byte serve, the target add on
    // the byte just served, and the tag compares gating the want.  The scanner
    // has no cycle contract - it can only be wasteful, never wrong - so unlike
    // the core, which had to find the ISA's granted cycles, the scan simply
    // takes one: the operand beats end at registers (o1_q/o2_q), and S_TGT
    // computes the target, runs the filters and raises the want from those
    // registers alone.  One extra beat per TRANSFER found, never per byte
    // walked, so the sequential walk still outruns the turbo core.
    //
    // The 16-bit relative add below is S_TGT's alone and register-fed.  If it
    // ever tops the depth audit, the relief is the part's own: split the add
    // byte-wise and take a fix-up beat only when it crosses a 256-byte page -
    // the exact case a real taken branch spends an extra cycle on, so the
    // scan cannot fall behind an event the core itself pays for.
    localparam [2:0] S_IDLE = 3'd0, S_OP = 3'd1, S_O1 = 3'd2, S_O2 = 3'd3,
                     S_TGT = 3'd4;
    logic [2:0]  st;
    logic [11:0] ptr_hi;              // the walk line's tag (old ptr[15:4])
    logic [3:0]  ptr_lo;              // the offset within it (old ptr[3:0])
    logic [11:0] ptr_hi_p1;           // shadow: ptr_hi + 1, the next line
    logic        cur_in0, cur_in1;    // slot n holds line ptr_hi
    logic        nxt_in0, nxt_in1;    // slot n holds line ptr_hi_p1
    logic        diverged_q;          // last beat's divergence verdict
    logic [2:0]  cls_q;               // the transfer being decoded across beats
    logic [7:0]  o1_q;                // relative offset, or the abs target's low
    logic [7:0]  o2_q;                // the absolute target's high byte

    // The window read: a 4-bit add, and the carry picks the next line's
    // registered answers.  At most one crossing per step (3 < 16), so the
    // 5-bit sum is always enough.
    wire [1:0] rd_inc  = (st == S_O2) ? 2'd2 : (st == S_O1) ? 2'd1 : 2'd0;
    wire [4:0] rd_sum  = {1'b0, ptr_lo} + {3'b0, rd_inc};
    wire       rin0    = rd_sum[4] ? nxt_in0 : cur_in0;
    wire       rin1    = rd_sum[4] ? nxt_in1 : cur_in1;
    wire       rd_held = rin0 || rin1;
    assign rd_slot = !rin0;           // slot-0 priority, as the old serve mux
    assign rd_off  = rd_sum[3:0];

    wire [4:0] dec     = opdec(rd_byte);
    wire [2:0] dec_cls = dec[4:2];
    wire [1:0] dec_len = dec[1:0];

    // The step adds: 4-bit, carry answered from the shadows.  S_O1's write is
    // +2 (its read was +1): the fall-through advance, as before.
    wire [4:0] step_sum = {1'b0, ptr_lo} + {3'b0, dec_len};
    wire [4:0] plus2    = {1'b0, ptr_lo} + 5'd2;

    // The target, from registers only.  A relative's ptr already advanced to
    // the fall-through in S_O1, so the target is ptr + the signed offset; an
    // absolute's is a plain concatenation, no arithmetic at all.
    wire [15:0] tgt        = (cls_q == C_ABS) ? {o2_q, o1_q}
                                              : {ptr_hi, ptr_lo} + {{8{o1_q[7]}}, o1_q};
    wire [11:0] tgt_tag    = tgt[15:4];
    wire [11:0] tgt_tag_p1 = tgt_tag + 12'd1;

    wire tgt_held0 = v0 && (tgt_tag == vtag0);
    wire tgt_held1 = v1 && (tgt_tag == vtag1);
    // Pages a prefetch must never touch: the engine would refuse them too,
    // but the filter is a clock and an engine slot saved.
    wire tgt_excl  = (tgt_tag[11:4] == 8'hC0) || (tgt_tag[11:4] == 8'hC3) ||
                     (tgt_tag == 12'hCFF);

    // The transfer's OWN line, captured when it is first decoded - the loop
    // bit must name the line the branch LIVES in, and by S_TGT a relative's
    // ptr has already moved to the fall-through, which for an opcode in a
    // line's last two bytes is the NEXT line.  The capture reads the
    // registered memberships, so it costs the decision beat nothing.
    logic src0, src1;

    wire issuing = (st == S_TGT);

    // The last target issued: a tight loop rescans every iteration, and this
    // keeps it from re-asking for the line every time.  Cleared with the
    // trail, so a genuinely new context asks fresh.
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
            cls_q <= C_SEQ; o1_q <= 8'd0; o2_q <= 8'd0;
            sw_tag <= 12'd0; last_tag <= 12'd0; lb_slot <= 1'b0;
            src0 <= 1'b0; src1 <= 1'b0;
        end else begin
            if (sw_taken) sw_v <= 1'b0;

            // The shadows, first: every beat recomputes them from registers -
            // 12-bit compares and the 16-bit divergence subtract, all OUT of
            // the walk's cone.  This is the self-heal path for vtag/v churn
            // and for the beat after a crossing; the writes below override
            // (last assignment wins) wherever they know better.
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
                    end else if (cls_q == C_ABS) begin
                        o1_q <= rd_byte; st <= S_O2;
                    end else begin
                        // The offset lands in a register; the fall-through
                        // advance happens now so S_TGT's add is ptr + offset
                        // for BOTH the conditional (which continues here) and
                        // BRA (which loads the sum).
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
                    end else begin
                        o2_q <= rd_byte; st <= S_TGT;
                    end
                end
                // The granted beat: registers in, want out.  No window read
                // happens here, so rd_held has no say - the operand beats
                // already vouched for the bytes.  A followed transfer loads
                // the whole split-pointer set from register-fed values.
                S_TGT: begin
                    if (cls_q != C_REL) begin     // BRA and JMP/JSR followed
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

            // The anchor, last: a restart beats the step above.  The whole
            // split set loads in-beat - anchor to S_OP is back-to-back, so
            // the memberships must be exact for the very next read; the
            // compares mirror iline's own hit cones off the same pc.
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
