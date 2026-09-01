`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// iscan - the instruction front's branch scanner.  docs/ISTREAM.md.
//
// Lives inside rtl/iline.sv.  Walks instruction boundaries forward from the
// program's last opcode fetch through the two held lines, one instruction per
// clock (two for a branch, three for a JMP/JSR - the operand bytes each take
// a read), using the 65C02's length table.  For every branch, JMP or JSR it
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
// THE LOOP BIT.  A transfer found FROM one held line INTO the other is the
// shape of a loop held whole in the pair.  iline uses it to suppress the
// crossing's rotation, pinning the pair so the backward branch stays the
// one-stall-beat within-pair case instead of a refetch per iteration.
//
// THE ANCHOR.  Every program-stream opcode fetch offers its address.  The
// scanner takes it when it has nothing (idle, or its trail left the held
// window) or when execution diverged from the trail - the pointer no longer
// within a short reach ahead of the program counter.  A tight loop re-anchors
// every iteration and rescans; the last-issued filter keeps that from
// hammering the engine with wants it has already made.
//////////////////////////////////////////////////////////////////////////////////
module iscan (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,        // turbo serving: the front's lines are live

    // The anchor: a program-stream opcode fetch completing this clock.
    input  wire        anchor_v,
    input  wire [15:0] anchor_addr,

    // The window: a byte of either held line, through iline's mux.
    output wire [15:0] rd_addr,
    input  wire        rd_held,
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
    localparam [1:0] S_IDLE = 2'd0, S_OP = 2'd1, S_O1 = 2'd2, S_O2 = 2'd3;
    logic [1:0]  st;
    logic [15:0] ptr;
    logic [2:0]  cls_q;               // the transfer being decoded across beats
    logic [7:0]  o1_q;                // the absolute target's low byte

    assign rd_addr = (st == S_O1) ? ptr + 16'd1 :
                     (st == S_O2) ? ptr + 16'd2 : ptr;

    wire [4:0] dec     = opdec(rd_byte);
    wire [2:0] dec_cls = dec[4:2];
    wire [1:0] dec_len = dec[1:0];

    wire [15:0] rel_tgt = ptr + 16'd2 + {{8{rd_byte[7]}}, rd_byte};
    wire [15:0] abs_tgt = {rd_byte, o1_q};
    wire [15:0] tgt     = (st == S_O2) ? abs_tgt : rel_tgt;
    wire [11:0] tgt_tag = tgt[15:4];

    wire tgt_held0 = v0 && (tgt_tag == vtag0);
    wire tgt_held1 = v1 && (tgt_tag == vtag1);
    wire ptr_in0   = v0 && (ptr[15:4] == vtag0);
    wire ptr_in1   = v1 && (ptr[15:4] == vtag1);
    // Pages a prefetch must never touch: the engine would refuse them too,
    // but the filter is a clock and an engine slot saved.
    wire tgt_excl  = (tgt_tag[11:4] == 8'hC0) || (tgt_tag[11:4] == 8'hC3) ||
                     (tgt_tag == 12'hCFF);

    // The target is known at S_O1 for a relative, S_O2 for an absolute.
    wire issuing = rd_held && ((st == S_O1 && cls_q != C_ABS) || (st == S_O2));

    // The last target issued: a tight loop rescans every iteration, and this
    // keeps it from re-asking for the line every time.  Cleared with the
    // trail, so a genuinely new context asks fresh.
    logic        last_v;
    logic [11:0] last_tag;

    // Execution's reach: the anchor restarts the trail unless the pointer is
    // within 64 bytes ahead of it.
    wire [15:0] adiff = ptr - anchor_addr;
    wire diverged = (adiff[15:6] != 10'd0);

    always_ff @(posedge clk) begin
        lb_v <= 1'b0;
        if (rst || !enable) begin
            st <= S_IDLE; sw_v <= 1'b0; last_v <= 1'b0;
            ptr <= 16'd0; cls_q <= C_SEQ; o1_q <= 8'd0;
            sw_tag <= 12'd0; last_tag <= 12'd0; lb_slot <= 1'b0;
        end else begin
            if (sw_taken) sw_v <= 1'b0;

            case (st)
                S_IDLE: ;
                S_OP: begin
                    if (!rd_held) begin
                        st <= S_IDLE; last_v <= 1'b0;
                    end else case (dec_cls)
                        C_SEQ: ptr <= ptr + {14'd0, dec_len};
                        C_END: begin st <= S_IDLE; last_v <= 1'b0; end
                        default: begin cls_q <= dec_cls; st <= S_O1; end
                    endcase
                end
                S_O1: begin
                    if (!rd_held) begin
                        st <= S_IDLE; last_v <= 1'b0;
                    end else if (cls_q == C_ABS) begin
                        o1_q <= rd_byte; st <= S_O2;
                    end else begin
                        ptr <= (cls_q == C_BRA) ? rel_tgt : ptr + 16'd2;
                        st  <= S_OP;
                    end
                end
                S_O2: begin
                    if (!rd_held) begin
                        st <= S_IDLE; last_v <= 1'b0;
                    end else begin
                        ptr <= abs_tgt;   // JMP and JSR both followed
                        st  <= S_OP;
                    end
                end
                default: st <= S_IDLE;
            endcase

            if (issuing) begin
                if (ptr_in0 && tgt_held1) begin lb_v <= 1'b1; lb_slot <= 1'b0; end
                if (ptr_in1 && tgt_held0) begin lb_v <= 1'b1; lb_slot <= 1'b1; end
                if (!tgt_held0 && !tgt_held1 && !tgt_excl &&
                    !(sw_v && !sw_taken) && !(last_v && tgt_tag == last_tag)) begin
                    sw_v     <= 1'b1;
                    sw_tag   <= tgt_tag;
                    last_v   <= 1'b1;
                    last_tag <= tgt_tag;
                end
            end

            // The anchor, last: a restart beats the step above.
            if (anchor_v && (st == S_IDLE || diverged)) begin
                ptr <= anchor_addr;
                st  <= S_OP;
            end
        end
    end

endmodule
