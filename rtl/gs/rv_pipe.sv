`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// rv_pipe - the RISC-V engine's core, pipelined (docs/REQ_RVVM.md section 9,
// "The pipeline"): RV32IM_Zba_Zbb in order, five stages, rtl/gs/rv_core.sv's
// ports and protocol less the speculation.
//
//   F  fetch      f_req/f_addr from registers; rv_mem answers a row hit on the
//                 same clock, a miss later.  One answer buffered (fb) when D
//                 cannot take it.  A fetch the pipe no longer wants (a redirect
//                 while it was out) is waited out and dropped.
//   D  decode     the register file read (bypassed from W's write), the decode,
//                 BTFN: a backward branch and a JAL redirect F from here.
//   E  execute    operands forwarded from M and W, the ALU, the single-cycle
//                 shifter and counts, multiply (3 clocks, DSPs), divide
//                 (iterative), branch and JALR resolution (a misprediction
//                 flushes D and F), the effective address - d_pre, which
//                 addresses rv_mem's block-RAM row cache a clock early.
//   M  memory     d_req from registers; a load's hit answers on its first
//                 clock, a store is posted.  An event is resolved here: moving
//                 to W it flushes everything younger and stops the fetch.
//   W  writeback  the register write and the retire - one op to the governor
//                 (paid), waiting for its token (hold) - or the event's
//                 presentation.
//
// A load's value reaches E through W: an instruction that uses it straight
// after waits one clock.  Stores commit at M, when nothing older can still
// raise an event (an event anywhere older has flushed them by then).
//
// THE PROTOCOL (the window's, as rv_core's): `step` starts a run from pc; with
// `run` low the run fetches one instruction, with `run` high it fetches until
// `run` falls (a yield) - either way what is in the pipe drains and retires,
// and `busy` falls with `result` = 0, or with an event's code the moment one
// reaches W (pc stays at it; resume as rv_core).  A delegated fetch's resume
// injects the VM's word as the next run's first instruction.  `cancel` and
// req_spec are the old core's speculation and do nothing here.
//////////////////////////////////////////////////////////////////////////////////
module rv_pipe #(
    // THE ADDRESS SPACE: AW bits of byte address.  25 = the whole 32 MB DDR3 bank
    // the card gives main memory - the lower 16 MB the 65816's own, the upper
    // 16 MB the engine's alone (docs/REQ_RVVM.md).  An address at or above
    // 2**AW, or in the null guard, faults.  24 = the 65816's space only.
    parameter integer AW = 25
) (
    input  wire         clk,
    input  wire         rst,
    // control
    input  wire         step,
    input  wire         cancel,
    input  wire         resume,
    input  wire [31:0]  resume_val,
    input  wire         run,
    input  wire         hold,
    output logic        paid,
    output logic        busy,
    output logic        retired,
    output logic [7:0]  result,
    output logic [31:0] ev_addr,
    output logic [31:0] ev_data,
    output logic [31:0] ev_iw,
    // the state, while idle
    input  wire  [4:0]  rsel,
    output wire  [31:0] rval,
    input  wire         w_en,
    input  wire  [4:0]  w_sel,
    input  wire  [31:0] w_val,
    input  wire         pc_we,
    input  wire  [31:0] pc_wval,
    output wire  [31:0] pc,
    // instruction fetch
    output wire         f_req,
    output wire  [AW-3:0] f_addr,
    output wire  [AW-3:0] f_pre,          // the address F will ask for next clock (a guess; rv_mem's
                                        // instruction cache reads it a clock early)
    output wire         req_spec,
    input  wire         f_valid,
    input  wire         f_delegate,
    input  wire         f_abort,
    input  wire  [31:0] f_data,
    output wire  [AW-3:0] pk_addr,
    output wire         pk_use,
    input  wire         pk_hit,
    input  wire  [31:0] pk_word,
    // data
    output wire         d_req,
    output wire         d_we,
    output wire  [AW-3:0] d_addr,
    output wire  [AW-3:0] d_pre,
    output wire  [3:0]  d_be,
    output wire  [31:0] d_wdata,
    input  wire         d_valid,
    input  wire         d_delegate,
    input  wire         d_abort,
    input  wire  [31:0] d_rdata
);
    localparam logic [7:0] R_NEXT = 8'd0, R_ECALL = 8'd2, R_EBREAK = 8'd4, R_ILLEGAL = 8'd6,
                           R_LFAULT = 8'd8, R_SFAULT = 8'd10, R_FFAULT = 8'd12,
                           R_DLB = 8'd14, R_DLBU = 8'd16, R_DLH = 8'd18, R_DLHU = 8'd20, R_DLW = 8'd22,
                           R_DSB = 8'd24, R_DSH = 8'd26, R_DSW = 8'd28, R_DFETCH = 8'd30;

    typedef enum logic [5:0] {
        OP_ADD, OP_SUB, OP_SLL, OP_SLT, OP_SLTU, OP_XOR, OP_SRL, OP_SRA, OP_OR, OP_AND,
        OP_ANDN, OP_ORN, OP_XNOR, OP_MIN, OP_MINU, OP_MAX, OP_MAXU,
        OP_SH1ADD, OP_SH2ADD, OP_SH3ADD, OP_ROL, OP_ROR,
        OP_ZEXTH, OP_SEXTB, OP_SEXTH, OP_REV8, OP_ORCB, OP_CLZ, OP_CTZ, OP_CPOP,
        OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU, OP_DIV, OP_DIVU, OP_REM, OP_REMU,
        OP_LUI, OP_AUIPC, OP_JAL, OP_JALR, OP_BR, OP_LOAD, OP_STORE,
        OP_FENCE, OP_FENCEI, OP_ECALL, OP_EBREAK, OP_ILL
    } op_t;

    assign req_spec = 1'b0;
    assign pk_addr  = '0;
    assign pk_use   = 1'b0;

    function automatic logic addr_ok(input logic [31:0] ad);
        return ad[31:AW] == '0 && ad[AW-1:8] != '0;
    endfunction
    function automatic logic [31:0] ld_ext(input logic [31:0] w, input logic [1:0] off,
                                           input logic [1:0] sz, input logic u);
        logic [31:0] s;
        s = w >> {off, 3'b000};
        case (sz)
            2'd0:    return u ? {24'd0, s[7:0]}  : {{24{s[7]}}, s[7:0]};
            2'd1:    return u ? {16'd0, s[15:0]} : {{16{s[15]}}, s[15:0]};
            default: return s;
        endcase
    endfunction
    function automatic logic [7:0] dl_code(input logic [1:0] sz, input logic u);
        case (sz)
            2'd0:    return u ? R_DLBU : R_DLB;
            2'd1:    return u ? R_DLHU : R_DLH;
            default: return R_DLW;
        endcase
    endfunction

    // ---- the architectural state -------------------------------------------------
    logic [31:0] rf [0:31];
    logic        rf_we;
    logic [4:0]  rf_wsel;
    logic [31:0] rf_wval;
    always_ff @(posedge clk) if (rf_we) rf[rf_wsel] <= rf_wval;
    assign rval = rsel == 5'd0 ? 32'd0 : rf[rsel];

    logic [31:0] pc_q;
    assign pc = pc_q;
    logic [7:0]  pend;          // the event awaiting resume (ECALL, a delegated access), or R_NEXT
    logic [4:0]  pend_rd;
    logic [1:0]  pend_w;
    logic        pend_u;
    logic        inj_v;         // a delegated fetch's word, to run first
    logic [31:0] inj_iw;
    logic        run_on;        // F fetches
    logic        one;           // STEP: one instruction, already fetched

    // ---- the stage registers ------------------------------------------------------
    // F: the next pc, one buffered answer, one outstanding request
    logic [31:0] fpc;
    logic        fb_v;
    logic [31:0] fb_pc, fb_iw;
    logic [7:0]  fb_ev;
    logic        fo_v, fo_drop;     // a request out and unanswered; its answer is not wanted
    logic [AW-3:0] fo_addr;
    // D
    logic        d_v;
    logic [31:0] d_pc, d_iw;
    logic [7:0]  d_ev;
    // THE PREDICTION, PREDECODED as the instruction enters D: a backward branch or
    // a JAL, and its target - registers, so D's redirect and the early fetch
    // address do not wait on the full decode and an adder (gs_rvredir1)
    logic        d_pbr;                 // D redirects F (a backward branch, a JAL)
    logic        d_pbb;                 // ...a branch, predicted taken (E's e_pred)
    logic [31:0] d_ptgt;
    // E
    logic        e_v;
    logic [31:0] e_pc, e_iw, e_a, e_c, e_imm;
    op_t         e_op;
    logic [4:0]  e_rs1, e_rs2, e_rd;
    logic        e_wr, e_bimm, e_pred;
    logic [2:0]  e_fn3;
    logic [7:0]  e_ev;
    logic [31:0] e_evaddr;
    // M
    logic        m_v, m_wr, m_mem, m_we, m_done, m_ldu;
    logic [31:0] m_pc, m_iw, m_res, m_npc, m_ea, m_c, m_evaddr;
    logic [4:0]  m_rd;
    logic [AW-3:0] m_addr;
    logic [3:0]  m_be;
    logic [31:0] m_wdata;
    logic [1:0]  m_ldw;
    logic [7:0]  m_ev;
    // W
    logic        w_v, w_wr, w_ldu;
    logic [31:0] w_pc, w_iw, w_res, w_npc, w_evaddr, w_evdata;
    logic [4:0]  w_rd;
    logic [1:0]  w_ldw;
    logic [7:0]  w_ev;

    // ---- W: retire or present --------------------------------------------------------
    wire w_leave = w_v && (w_ev != R_NEXT || !hold);
    wire w_free  = !w_v || w_leave;

    // ---- M ---------------------------------------------------------------------------------
    assign d_req   = m_v && m_mem && !m_done && m_ev == R_NEXT;
    assign d_we    = m_we;
    assign d_addr  = m_addr;
    assign d_be    = m_be;
    assign d_wdata = m_wdata;
    wire   m_dgt   = d_req && d_valid && d_delegate;               // rv_mem will not do it: an event
    // (a delegate reply becomes M's event register and M moves on the clock
    // after: the flush and the forwarding look only at registered state)
    wire   m_ready = m_v && (m_ev != R_NEXT || !m_mem || m_done || (d_valid && !d_delegate));
    wire   m_adv   = m_ready && w_free;
    wire   m_evnt  = m_ev != R_NEXT;
    // the value M hands W (a load's, straight from the answer when it came this clock)
    wire [31:0] m_out = (m_mem && !m_we && !m_done) ? ld_ext(d_rdata, m_ea[1:0], m_ldw, m_ldu) : m_res;
    // an event in M flushes everything younger at once (not on the clock it
    // moves on: that would hang the whole stall chain on the flush)
    wire   flush_ev = m_v && m_evnt;
    // THE REDIRECT FROM M: E worked out a misprediction, a JALR's target or a
    // fence.i into M's registers; on the instruction's first clock in M the
    // redirect goes out from registered state, once, flushing E, D and F
    logic        m_mis, m_rdone;
    logic [31:0] m_rtgt;
    wire   mr_now = m_v && m_mis && !m_evnt && !m_rdone;

    // ---- E: operands, forwarded ------------------------------------------------------------
    wire m_fwd_ok = m_v && m_wr && !m_evnt && (!m_mem || m_we || m_done);   // M's result is in its register
    wire m_ldpend = m_v && m_wr && m_mem && !m_we && !m_done;                 // a load M has not got yet
    wire hz1 = e_rs1 != 5'd0 && m_ldpend && m_rd == e_rs1;
    wire hz2 = e_rs2 != 5'd0 && m_ldpend && m_rd == e_rs2;
    function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] v);
        if (r == 5'd0)                               return 32'd0;
        else if (m_fwd_ok && m_rd == r)             return m_res;
        else if (w_v && w_wr && w_ev == R_NEXT && w_rd == r) return w_res;
        else                                         return v;
    endfunction
    wire [31:0] a = fwd(e_rs1, e_a);
    wire [31:0] c = fwd(e_rs2, e_c);
    wire [31:0] b = e_bimm ? e_imm : c;
    wire [31:0] ea_now = a + e_imm;
    assign d_pre = ea_now[AW-1:2];

    // the single-cycle units
    function automatic logic [31:0] shf(input op_t o, input logic [31:0] v, input logic [4:0] n);
        case (o)
            OP_SLL:  return v << n;
            OP_SRL:  return v >> n;
            OP_SRA:  return $signed(v) >>> n;
            OP_ROL:  return (v << n) | (v >> (6'd32 - {1'b0, n}));
            default: return (v >> n) | (v << (6'd32 - {1'b0, n}));   // ROR
        endcase
    endfunction
    function automatic logic [5:0] clz32(input logic [31:0] v);
        for (int i = 31; i >= 0; i--) if (v[i]) return 6'(31 - i);
        return 6'd32;
    endfunction
    function automatic logic [5:0] ctz32(input logic [31:0] v);
        for (int i = 0; i < 32; i++) if (v[i]) return 6'(i);
        return 6'd32;
    endfunction
    function automatic logic [5:0] pop32(input logic [31:0] v);
        logic [5:0] n;
        n = 6'd0;
        for (int i = 0; i < 32; i++) n = n + {5'd0, v[i]};
        return n;
    endfunction
    logic [31:0] alu;
    logic        lt_s, lt_u;
    always_comb begin
        lt_s = $signed(a) < $signed(b);
        lt_u = a < b;
        alu  = 32'd0;
        case (e_op)
            OP_ADD:    alu = a + b;
            OP_SUB:    alu = a - b;
            OP_SLT:    alu = {31'd0, lt_s};
            OP_SLTU:   alu = {31'd0, lt_u};
            OP_XOR:    alu = a ^ b;
            OP_OR:     alu = a | b;
            OP_AND:    alu = a & b;
            OP_ANDN:   alu = a & ~b;
            OP_ORN:    alu = a | ~b;
            OP_XNOR:   alu = ~(a ^ b);
            OP_MIN:    alu = lt_s ? a : b;
            OP_MAX:    alu = lt_s ? b : a;
            OP_MINU:   alu = lt_u ? a : b;
            OP_MAXU:   alu = lt_u ? b : a;
            OP_SH1ADD: alu = {a[30:0], 1'b0} + b;
            OP_SH2ADD: alu = {a[29:0], 2'b0} + b;
            OP_SH3ADD: alu = {a[28:0], 3'b0} + b;
            OP_ZEXTH:  alu = {16'd0, a[15:0]};
            OP_SEXTB:  alu = {{24{a[7]}}, a[7:0]};
            OP_SEXTH:  alu = {{16{a[15]}}, a[15:0]};
            OP_REV8:   alu = {a[7:0], a[15:8], a[23:16], a[31:24]};
            OP_ORCB:   alu = {{8{|a[31:24]}}, {8{|a[23:16]}}, {8{|a[15:8]}}, {8{|a[7:0]}}};
            OP_SLL, OP_SRL, OP_SRA, OP_ROL, OP_ROR: alu = shf(e_op, a, b[4:0]);
            OP_CLZ:    alu = {26'd0, clz32(a)};
            OP_CTZ:    alu = {26'd0, ctz32(a)};
            OP_CPOP:   alu = {26'd0, pop32(a)};
            OP_LUI:    alu = e_imm;
            OP_AUIPC:  alu = e_pc + e_imm;
            OP_JAL, OP_JALR: alu = e_pc + 32'd4;
            default:   alu = 32'd0;
        endcase
    end
    logic br_take;
    always_comb begin
        case (e_fn3)
            3'd0:    br_take = a == c;
            3'd1:    br_take = a != c;
            3'd4:    br_take = $signed(a) < $signed(c);
            3'd5:    br_take = $signed(a) >= $signed(c);
            3'd6:    br_take = a < c;
            default: br_take = a >= c;
        endcase
    end

    // multiply (3 clocks, the DSPs' pipeline) and divide (32 steps), E held meanwhile
    logic               mc_on, mc_done;
    logic [31:0]        mc_res;
    logic signed [32:0] m_a, m_b;
    logic signed [65:0] m_p1, m_p2;
    logic [1:0]         m_cnt;
    logic [31:0]        dv_q, dv_d;
    logic [32:0]        dv_r;
    logic [5:0]         dv_cnt;
    logic               dv_negq, dv_negr;
    wire e_mul = e_op == OP_MUL || e_op == OP_MULH || e_op == OP_MULHSU || e_op == OP_MULHU;
    wire e_div = e_op == OP_DIV || e_op == OP_DIVU || e_op == OP_REM || e_op == OP_REMU;
    wire e_mc  = (e_mul || e_div) && e_ev == R_NEXT;

    // E's outcome
    wire        e_hz    = hz1 || hz2;
    logic       d_rdone;                // D's prediction has gone out
    wire        e_ready = e_v && !e_hz && (!e_mc || mc_done);
    wire        m_free  = !m_v || m_adv;
    wire        e_adv   = e_ready && m_free && !flush_ev && !mr_now;
    wire [31:0] e_tgt   = e_op == OP_JALR ? (ea_now & ~32'd1) : e_pc + e_imm;
    wire        e_taken = e_op == OP_JAL || e_op == OP_JALR || (e_op == OP_BR && br_take);
    wire        e_tbad  = e_taken && (e_tgt[1:0] != 2'd0 || !addr_ok(e_tgt));
    wire [31:0] e_npc   = (e_taken && !e_tbad) ? e_tgt : e_pc + 32'd4;
    wire [1:0]  e_sz    = e_fn3[1:0];
    wire        e_mis   = (e_sz == 2'd1 && ea_now[0]) || (e_sz == 2'd2 && ea_now[1:0] != 2'd0);
    wire        e_ls    = e_op == OP_LOAD || e_op == OP_STORE;
    // E's event: D's, else a bad target, a memory fault, a misaligned (delegated) access
    logic [7:0]  e_evo;
    logic [31:0] e_evao;
    always_comb begin
        e_evo = e_ev; e_evao = e_evaddr;
        if (e_ev == R_NEXT) begin
            if (e_tbad) begin e_evo = R_FFAULT; e_evao = e_tgt; end
            else if (e_ls && !addr_ok(ea_now)) begin e_evo = e_op == OP_LOAD ? R_LFAULT : R_SFAULT; e_evao = ea_now; end
            else if (e_ls && e_mis) begin
                e_evo  = e_op == OP_LOAD ? dl_code(e_sz, e_fn3[2]) : R_DSB + {5'd0, e_sz, 1'b0};
                e_evao = ea_now;
            end
        end
    end
    // what E hands M for the redirect: a mispredicted branch, a JALR, a fence.i
    // (a bad target is an event instead, whose flush takes anything fetched from it)
    wire        e_misp  = (e_op == OP_BR && (br_take != e_pred)) || e_op == OP_JALR || e_op == OP_FENCEI;
    wire [31:0] e_rtgt  = e_op == OP_FENCEI ? e_pc + 32'd4 :
                          e_op == OP_JALR   ? (ea_now & ~32'd1) :
                          br_take           ? e_pc + e_imm : e_pc + 32'd4;

    // ---- D: decode ---------------------------------------------------------------------------
    wire [6:0]  opc   = d_iw[6:0];
    wire [4:0]  rd_f  = d_iw[11:7], rs1_f = d_iw[19:15], rs2_f = d_iw[24:20];
    wire [2:0]  f3    = d_iw[14:12];
    wire [6:0]  f7    = d_iw[31:25];
    wire [11:0] imm12 = d_iw[31:20];
    wire [31:0] imm_i = {{20{d_iw[31]}}, d_iw[31:20]};
    wire [31:0] imm_s = {{20{d_iw[31]}}, d_iw[31:25], d_iw[11:7]};
    wire [31:0] imm_b = {{19{d_iw[31]}}, d_iw[31], d_iw[7], d_iw[30:25], d_iw[11:8], 1'b0};
    wire [31:0] imm_u = {d_iw[31:12], 12'd0};
    wire [31:0] imm_j = {{11{d_iw[31]}}, d_iw[31], d_iw[19:12], d_iw[20], d_iw[30:21], 1'b0};
    op_t dop;
    always_comb begin
        dop = OP_ILL;
        unique case (opc)
            7'h37: dop = OP_LUI;
            7'h17: dop = OP_AUIPC;
            7'h6F: dop = OP_JAL;
            7'h67: dop = f3 == 3'd0 ? OP_JALR : OP_ILL;
            7'h63: dop = (f3 == 3'd2 || f3 == 3'd3) ? OP_ILL : OP_BR;
            7'h03: dop = (f3 == 3'd3 || f3 == 3'd6 || f3 == 3'd7) ? OP_ILL : OP_LOAD;
            7'h23: dop = f3 <= 3'd2 ? OP_STORE : OP_ILL;
            7'h0F: dop = f3 == 3'd0 ? OP_FENCE : f3 == 3'd1 ? OP_FENCEI : OP_ILL;
            7'h73: dop = d_iw == 32'h0000_0073 ? OP_ECALL : d_iw == 32'h0010_0073 ? OP_EBREAK : OP_ILL;
            7'h13: unique case (f3)
                3'd0: dop = OP_ADD;
                3'd2: dop = OP_SLT;
                3'd3: dop = OP_SLTU;
                3'd4: dop = OP_XOR;
                3'd6: dop = OP_OR;
                3'd7: dop = OP_AND;
                3'd1: dop = f7 == 7'h00 ? OP_SLL :
                            imm12 == 12'h600 ? OP_CLZ : imm12 == 12'h601 ? OP_CTZ : imm12 == 12'h602 ? OP_CPOP :
                            imm12 == 12'h604 ? OP_SEXTB : imm12 == 12'h605 ? OP_SEXTH : OP_ILL;
                3'd5: dop = f7 == 7'h00 ? OP_SRL : f7 == 7'h20 ? OP_SRA : f7 == 7'h30 ? OP_ROR :
                            imm12 == 12'h698 ? OP_REV8 : imm12 == 12'h287 ? OP_ORCB : OP_ILL;
                default: dop = OP_ILL;
            endcase
            7'h33: unique case (f7)
                7'h00: case (f3)
                    3'd0: dop = OP_ADD;  3'd1: dop = OP_SLL; 3'd2: dop = OP_SLT; 3'd3: dop = OP_SLTU;
                    3'd4: dop = OP_XOR;  3'd5: dop = OP_SRL; 3'd6: dop = OP_OR;  default: dop = OP_AND;
                endcase
                7'h20: case (f3)
                    3'd0: dop = OP_SUB;  3'd4: dop = OP_XNOR; 3'd5: dop = OP_SRA;
                    3'd6: dop = OP_ORN;  3'd7: dop = OP_ANDN; default: dop = OP_ILL;
                endcase
                7'h01: case (f3)
                    3'd0: dop = OP_MUL;  3'd1: dop = OP_MULH; 3'd2: dop = OP_MULHSU; 3'd3: dop = OP_MULHU;
                    3'd4: dop = OP_DIV;  3'd5: dop = OP_DIVU; 3'd6: dop = OP_REM;    default: dop = OP_REMU;
                endcase
                7'h05: case (f3)
                    3'd4: dop = OP_MIN;  3'd5: dop = OP_MINU; 3'd6: dop = OP_MAX; 3'd7: dop = OP_MAXU;
                    default: dop = OP_ILL;
                endcase
                7'h10: case (f3)
                    3'd2: dop = OP_SH1ADD; 3'd4: dop = OP_SH2ADD; 3'd6: dop = OP_SH3ADD; default: dop = OP_ILL;
                endcase
                7'h30: dop = f3 == 3'd1 ? OP_ROL : f3 == 3'd5 ? OP_ROR : OP_ILL;
                7'h04: dop = (f3 == 3'd4 && rs2_f == 5'd0) ? OP_ZEXTH : OP_ILL;
                default: dop = OP_ILL;
            endcase
            default: dop = OP_ILL;
        endcase
    end
    // which registers the op reads (a false read only costs a spurious stall)
    wire d_use1 = !(dop == OP_LUI || dop == OP_AUIPC || dop == OP_JAL);
    wire d_use2 = opc == 7'h33 || opc == 7'h23 || opc == 7'h63;
    wire d_wr   = !(dop == OP_BR || dop == OP_STORE || dop == OP_FENCE || dop == OP_FENCEI ||
                    dop == OP_ECALL || dop == OP_EBREAK || dop == OP_ILL) && rd_f != 5'd0;
    // the register file read, bypassed from W's write this clock
    wire [31:0] rs1v = (rf_we && rf_wsel == rs1_f && rs1_f != 5'd0) ? rf_wval : (rs1_f == 5'd0 ? 32'd0 : rf[rs1_f]);
    wire [31:0] rs2v = (rf_we && rf_wsel == rs2_f && rs2_f != 5'd0) ? rf_wval : (rs2_f == 5'd0 ? 32'd0 : rf[rs2_f]);
    logic [31:0] d_imm;
    always_comb begin
        case (opc)
            7'h37, 7'h17: d_imm = imm_u;
            7'h6F:        d_imm = imm_j;
            7'h63:        d_imm = imm_b;
            7'h23:        d_imm = imm_s;
            default:      d_imm = imm_i;
        endcase
    end
    // D's event: the fetch's, else the decode's
    wire [7:0]  d_evo   = d_ev != R_NEXT ? d_ev :
                          dop == OP_ILL ? R_ILLEGAL : dop == OP_ECALL ? R_ECALL : dop == OP_EBREAK ? R_EBREAK : R_NEXT;
    wire [31:0] d_evao  = d_ev != R_NEXT ? d_pc : (dop == OP_ILL ? d_iw : 32'd0);
    // BTFN: a backward branch predicted taken, a JAL taken - F redirected from here
    wire        d_pred  = d_pbb;
    wire        e_free  = !e_v || e_adv;
    wire        d_adv   = d_v && e_free && !mr_now && !flush_ev;
    // D's prediction goes out while D holds the branch, whether or not it advances
    wire        dr_now  = d_v && d_pbr && !d_rdone && !mr_now && !flush_ev;
    wire [31:0] d_tgt   = d_ptgt;

    // ---- F: the fetch -----------------------------------------------------------------------
    wire fpc_bad = fpc[1:0] != 2'd0 || !addr_ok(fpc);
    // fetch while running (STEP: the one instruction), with room, no answer waited out
    wire f_want  = run_on && (run || !one) && !fb_v && !inj_v;
    assign f_req  = fo_v || (f_want && !fpc_bad);
    assign f_addr = fo_v ? fo_addr : fpc[AW-1:2];
    wire f_got   = f_req && f_valid && !(fo_v && fo_drop);        // an answer the pipe wants
    wire redir   = mr_now || dr_now || flush_ev;
    // what F offers D this clock: the injected word, the buffer, a fetch fault, the answer
    logic        fo_off;
    logic [31:0] fo_pc, fo_iw;
    logic [7:0]  fo_ev;
    always_comb begin
        fo_off = 1'b0; fo_pc = fpc; fo_iw = 32'd0; fo_ev = R_NEXT;
        if (inj_v && run_on)               begin fo_off = 1'b1; fo_iw = inj_iw; end
        else if (fb_v)                     begin fo_off = 1'b1; fo_pc = fb_pc; fo_iw = fb_iw; fo_ev = fb_ev; end
        else if (f_want && fpc_bad)        begin fo_off = 1'b1; fo_ev = R_FFAULT; end
        else if (f_got)                    begin fo_off = 1'b1; fo_iw = f_data;
                                                 fo_ev = f_delegate ? R_DFETCH : R_NEXT; end
    end
    // THE NEXT FETCH ADDRESS, guessed without waiting on whether E and D advance
    // (that would put the whole stall chain in front of the cache's RAM): a
    // redirect E or D has decided, else the next word after an answer, else the
    // same word; the start of a run while idle.  A wrong guess costs a clock.
    assign f_pre = !busy ? pc_q[AW-1:2] :
                   mr_now ? m_rtgt[AW-1:2] :
                   dr_now ? d_tgt[AW-1:2] :
                   (f_req && f_valid) ? f_addr + 1'b1 : f_addr;
    wire d_take = !d_v || d_adv;
    wire f_into_d = fo_off && d_take && !redir;
    // an answer (or fault) this clock that D cannot take goes to the buffer
    wire f_into_b = !inj_v && !fb_v && ((f_want && fpc_bad) || f_got) && !d_take && !redir;
    wire f_step   = (f_into_d && !fb_v) || f_into_b;         // F produced a new one: fpc moves on

    // ---- the register write port: W, a delegated load's resume, the window --------------
    always_comb begin
        rf_we   = 1'b0;
        rf_wsel = w_sel;
        rf_wval = w_val;
        if (w_leave && w_ev == R_NEXT && w_wr) begin
            rf_we = 1'b1; rf_wsel = w_rd; rf_wval = w_res;
        end else if (!busy && resume && (pend >= R_DLB && pend <= R_DLW) && pend_rd != 5'd0) begin
            rf_we = 1'b1; rf_wsel = pend_rd; rf_wval = ld_ext(resume_val, 2'd0, pend_w, pend_u);
        end else if (w_en && w_sel != 5'd0) begin
            rf_we = 1'b1;
        end
    end

    wire pipe_empty = !d_v && !e_v && !m_v && !w_v && !fb_v && !fo_v;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; result <= R_NEXT; pend <= R_NEXT; pc_q <= 32'd0;
            retired <= 1'b0; paid <= 1'b0; inj_v <= 1'b0; run_on <= 1'b0; one <= 1'b0;
            fb_v <= 1'b0; fo_v <= 1'b0; fo_drop <= 1'b0;
            d_v <= 1'b0; e_v <= 1'b0; m_v <= 1'b0; w_v <= 1'b0; m_rdone <= 1'b0; d_rdone <= 1'b0; m_mis <= 1'b0;
            mc_on <= 1'b0; mc_done <= 1'b0;
            ev_addr <= 32'd0; ev_data <= 32'd0; ev_iw <= 32'd0;
        end else begin
            retired <= 1'b0;
            paid    <= 1'b0;
            if (pc_we && !busy) pc_q <= pc_wval;

            // ---- idle: a step starts a run; a resume finishes an event ----------------
            if (!busy) begin
                if (resume && pend == R_DFETCH) begin
                    inj_v <= 1'b1; inj_iw <= resume_val;
                    pend <= R_NEXT; result <= R_NEXT;
                end else if (resume && pend != R_NEXT) begin
                    pc_q <= pc_q + 32'd4; pend <= R_NEXT; result <= R_NEXT; retired <= 1'b1;
                end else if (step) begin
                    if (pend != R_NEXT) result <= pend;             // still pending: say so again
                    else begin
                        busy <= 1'b1; result <= R_NEXT;
                        run_on <= 1'b1; one <= 1'b0; fpc <= pc_q;
                    end
                end
            end

            // ---- W ----------------------------------------------------------------
            if (w_leave) begin
                if (w_ev == R_NEXT) begin
                    retired <= 1'b1; paid <= 1'b1;
                    pc_q <= w_npc;
                end else begin
                    // the event: pc at it, the run over (everything younger flushed as it left M)
                    result  <= w_ev;
                    pend    <= (w_ev == R_ECALL || (w_ev >= R_DLB && w_ev <= R_DFETCH)) ? w_ev : R_NEXT;
                    pend_rd <= w_rd; pend_w <= w_ldw; pend_u <= w_ldu;
                    ev_addr <= w_evaddr; ev_iw <= w_iw; ev_data <= w_evdata;
                    pc_q    <= w_pc;
                    busy    <= 1'b0;
                    run_on  <= 1'b0;
                end
            end
            // a run that drained: no event, nothing left
            if (busy && !run_on && pipe_empty) begin busy <= 1'b0; result <= R_NEXT; end
            // the fetch stops once the one instruction a STEP (or a yield: `run` fell)
            // allows has been fetched; what is in the pipe drains
            if (run_on && !run && one) run_on <= 1'b0;

            // M -> W
            if (w_leave || !w_v) w_v <= 1'b0;
            if (m_adv) begin
                w_v      <= 1'b1;
                w_pc     <= m_pc; w_iw <= m_iw; w_rd <= m_rd; w_npc <= m_npc;
                w_wr     <= m_wr && !m_evnt;
                w_res    <= m_out;
                w_ldw    <= m_ldw; w_ldu <= m_ldu;
                w_ev     <= m_ev;
                w_evaddr <= m_evaddr;
                w_evdata <= m_c;
            end
            // M: a load's answer while W cannot take it yet
            if (m_v && !m_adv && d_req && d_valid && !d_delegate) begin
                m_done <= 1'b1;
                if (!m_we) m_res <= ld_ext(d_rdata, m_ea[1:0], m_ldw, m_ldu);
            end
            if (m_dgt) begin
                m_ev <= m_we ? R_DSB + {5'd0, m_ldw, 1'b0} : dl_code(m_ldw, m_ldu);
                m_evaddr <= m_ea;
            end

            // E -> M
            if (m_adv) m_v <= 1'b0;
            if (e_adv) begin
                m_v      <= 1'b1;
                m_pc     <= e_pc; m_iw <= e_iw; m_rd <= e_rd;
                m_wr     <= e_wr && e_evo == R_NEXT;
                m_res    <= e_mc ? mc_res : alu;
                m_npc    <= e_npc;
                m_ev     <= e_evo; m_evaddr <= e_evao;
                m_mem    <= e_ls && e_evo == R_NEXT;
                m_we     <= e_op == OP_STORE;
                m_done   <= 1'b0;
                m_addr   <= ea_now[AW-1:2];
                m_ea     <= ea_now;
                m_ldw    <= e_sz; m_ldu <= e_fn3[2];
                m_be     <= (e_sz == 2'd0 ? 4'b0001 : e_sz == 2'd1 ? 4'b0011 : 4'b1111) << ea_now[1:0];
                m_wdata  <= c << {ea_now[1:0], 3'b000};
                m_c      <= c;
                m_mis    <= e_misp && e_evo == R_NEXT;
                m_rtgt   <= e_rtgt;
            end
            if (mr_now) m_rdone <= 1'b1;
            if (e_adv || m_adv) m_rdone <= 1'b0;

            // E: the multi-clock units
            if (e_v && e_mc && !e_hz && !mc_on && !mc_done) begin
                if (e_mul) begin
                    m_a   <= (e_op == OP_MULHU) ? $signed({1'b0, a}) : $signed({a[31], a});
                    m_b   <= (e_op == OP_MULH) ? $signed({b[31], b}) : $signed({1'b0, b});
                    m_cnt <= 2'd0; mc_on <= 1'b1;
                end else begin
                    logic sgn;
                    sgn = e_op == OP_DIV || e_op == OP_REM;
                    if (b == 32'd0) begin
                        mc_res <= (e_op == OP_DIV || e_op == OP_DIVU) ? 32'hFFFF_FFFF : a; mc_done <= 1'b1;
                    end else if (sgn && a == 32'h8000_0000 && b == 32'hFFFF_FFFF) begin
                        mc_res <= e_op == OP_DIV ? a : 32'd0; mc_done <= 1'b1;
                    end else begin
                        dv_q    <= (sgn && a[31]) ? -a : a;
                        dv_d    <= (sgn && b[31]) ? -b : b;
                        dv_r    <= 33'd0;
                        dv_negq <= sgn && (a[31] ^ b[31]);
                        dv_negr <= sgn && a[31];
                        dv_cnt  <= 6'd32;
                        mc_on   <= 1'b1;
                    end
                end
            end
            if (mc_on) begin
                if (e_mul) begin
                    m_p1 <= m_a * m_b; m_p2 <= m_p1; m_cnt <= m_cnt + 2'd1;
                    if (m_cnt == 2'd2) begin
                        mc_res <= e_op == OP_MUL ? m_p2[31:0] : m_p2[63:32];
                        mc_on <= 1'b0; mc_done <= 1'b1;
                    end
                end else if (dv_cnt != 6'd0) begin
                    logic [32:0] r2;
                    r2 = {dv_r[31:0], dv_q[31]};
                    if (r2 >= {1'b0, dv_d}) begin dv_r <= r2 - {1'b0, dv_d}; dv_q <= {dv_q[30:0], 1'b1}; end
                    else                    begin dv_r <= r2;                 dv_q <= {dv_q[30:0], 1'b0}; end
                    dv_cnt <= dv_cnt - 6'd1;
                end else begin
                    mc_res  <= (e_op == OP_DIV || e_op == OP_DIVU) ? (dv_negq ? -dv_q : dv_q)
                                                                   : (dv_negr ? -dv_r[31:0] : dv_r[31:0]);
                    mc_on <= 1'b0; mc_done <= 1'b1;
                end
            end
            if (e_adv) mc_done <= 1'b0;
            if (flush_ev || mr_now) begin mc_on <= 1'b0; mc_done <= 1'b0; end   // (its instruction is gone)
            // E's captured operands follow a register W writes while E waits
            if (!d_adv && rf_we) begin
                if (e_rs1 == rf_wsel) e_a <= rf_wval;
                if (e_rs2 == rf_wsel) e_c <= rf_wval;
            end

            // D -> E
            if (e_adv || flush_ev || mr_now) e_v <= 1'b0;
            if (d_adv) begin
                e_v    <= 1'b1;
                e_pc   <= d_pc; e_iw <= d_iw;
                e_op   <= dop;
                e_rs1  <= d_use1 ? rs1_f : 5'd0;
                e_rs2  <= d_use2 ? rs2_f : 5'd0;
                e_rd   <= rd_f;
                e_wr   <= d_wr;
                e_a    <= rs1v; e_c <= rs2v;
                e_imm  <= d_imm;
                e_bimm <= opc != 7'h33;
                e_fn3  <= f3;
                e_ev   <= d_evo; e_evaddr <= d_evao;
                e_pred <= d_pred;
            end

            // F -> D
            if (d_adv || mr_now || flush_ev) d_v <= 1'b0;    // (D's own prediction keeps it)
            if (dr_now) d_rdone <= 1'b1;
            if (d_adv || mr_now || flush_ev) d_rdone <= 1'b0;
            if (f_into_d) begin
                d_v  <= 1'b1;
                d_pc <= fo_pc; d_iw <= fo_iw; d_ev <= fo_ev;
                d_pbb  <= fo_ev == R_NEXT && fo_iw[6:0] == 7'h63 && fo_iw[14:13] != 2'b01 && fo_iw[31];
                d_pbr  <= fo_ev == R_NEXT && ((fo_iw[6:0] == 7'h63 && fo_iw[14:13] != 2'b01 && fo_iw[31]) ||
                                              fo_iw[6:0] == 7'h6F);
                d_ptgt <= fo_pc + (fo_iw[6:0] == 7'h6F
                                   ? {{11{fo_iw[31]}}, fo_iw[31], fo_iw[19:12], fo_iw[20], fo_iw[30:21], 1'b0}
                                   : {{19{fo_iw[31]}}, fo_iw[31], fo_iw[7], fo_iw[30:25], fo_iw[11:8], 1'b0});
            end
            // the buffer: filled when D was full, emptied into D
            if (redir) fb_v <= 1'b0;
            else if (fb_v && f_into_d) fb_v <= 1'b0;
            else if (f_into_b) begin
                fb_v <= 1'b1; fb_pc <= fpc; fb_iw <= f_data;
                fb_ev <= (f_want && fpc_bad) ? R_FFAULT : (f_delegate ? R_DFETCH : R_NEXT);
            end
            if (inj_v && run_on && f_into_d) inj_v <= 1'b0;
            // the next pc: past what F produced, or a redirect's target
            if (f_step && !redir) begin
                fpc <= fpc + 32'd4;
                if (!run) one <= 1'b1;                      // STEP: the one is fetched
            end
            if (mr_now)                    fpc <= m_rtgt;
            else if (dr_now)               fpc <= d_tgt;
            // a request out and unanswered: keep asking the same word; after a redirect,
            // wait out its answer and drop it
            if (f_req && !f_valid) begin
                if (!fo_v) begin fo_v <= 1'b1; fo_addr <= f_addr; fo_drop <= redir; end
                else if (redir) fo_drop <= 1'b1;
            end else if (f_req && f_valid) begin
                fo_v <= 1'b0; fo_drop <= 1'b0;
            end
            if (flush_ev) begin run_on <= 1'b0; fb_v <= 1'b0; inj_v <= 1'b0; end
        end
    end

    wire unused = &{1'b0, cancel, f_abort, d_abort, pk_hit, pk_word};
endmodule
