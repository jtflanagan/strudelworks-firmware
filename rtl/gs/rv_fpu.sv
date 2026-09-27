`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// rv_fpu - the RISC-V engine's floating-point unit (F and D: rtl/gs/rv_pipe.sv
// holds the FP registers), one operation at a time, multi-clock, sized for
// LUTs rather than speed.  IEEE 754 binary32/binary64 with RISC-V's rules: the
// canonical NaN, tininess after rounding, fflags = {NV, DZ, OF, UF, NX}.
//
// ONE DATAPATH FOR THE ARITHMETIC: every add, multiply, fused multiply-add and
// float-to-float conversion is a product (a real one, or the first operand
// passed through), an optional addend, one sum, one normalization and one
// rounding at the output format's width.  Division and square root are
// radix-2 digit recurrences that join at the normalization; the integer
// conversions enter at the normalization (int -> float) or the rounding
// (float -> int).  A single operation is a double one rounded at 24 bits.
//
//   UNP   the operands unpacked: sign, exponent, a 53-bit significand
//   NRM   a subnormal operand normalized (one a clock, one shared unit)
//   SPEC  NaN, infinity and zero cases answered; the rest set up
//   MUL   53 x 53 in four 53 x 14 slices on DSPs, accumulated (single: two)
//   PN    the product normalized by one bit
//   ALN   the smaller operand shifted right into a 110-bit window with sticky
//   ADD   one add or subtract (the larger magnitude first: never negative)
//   LZC   the leading zeros counted
//   SHL   normalized: the leading one at bit 109
//   RND1  shifted to the output's precision (subnormals, integers) with sticky
//   RND2  rounded, packed, the flags
//
// Operands and results are the values: a single in [31:0] (the pipe unboxes and
// boxes it), a double as 64 bits, an integer in [31:0].  `dbl` is the operation's format: the
// source's for FCVTW/FCVTWU/FCVTFF, the destination's for FCVTFW/FCVTFWU.
// `rm` is the resolved rounding mode (0-4).  `done` pulses with res and flags.
// `kill` abandons the operation in progress (its instruction was flushed): no
// `done` follows, and a `start` on the same clock is refused.
//////////////////////////////////////////////////////////////////////////////////
module rv_fpu (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire         kill,
    input  wire  [4:0]  op,
    input  wire         dbl,
    input  wire  [2:0]  rm,
    input  wire  [63:0] a,
    input  wire  [63:0] b,
    input  wire  [63:0] c,
    output logic        busy,
    output logic        done,
    output logic [63:0] res,
    output logic [4:0]  flags
);
    localparam logic [4:0] F_ADD = 5'd0, F_SUB = 5'd1, F_MUL = 5'd2, F_DIV = 5'd3, F_SQRT = 5'd4,
                           F_MADD = 5'd5, F_MSUB = 5'd6, F_NMSUB = 5'd7, F_NMADD = 5'd8,
                           F_SGNJ = 5'd9, F_SGNJN = 5'd10, F_SGNJX = 5'd11, F_MIN = 5'd12, F_MAX = 5'd13,
                           F_EQ = 5'd14, F_LT = 5'd15, F_LE = 5'd16, F_CLASS = 5'd17,
                           F_CVTW = 5'd18, F_CVTWU = 5'd19, F_CVTFW = 5'd20, F_CVTFWU = 5'd21, F_CVTFF = 5'd22;
    localparam logic [2:0] RNE = 3'd0, RTZ = 3'd1, RDN = 3'd2, RUP = 3'd3, RMM = 3'd4;
    localparam logic [4:0] NV = 5'h10, DZ = 5'h08, OF = 5'h04, UF = 5'h02, NX = 5'h01;

    typedef struct packed {
        logic               s;
        logic signed [13:0] e;
        logic [52:0]        m;      // the leading one at bit 52 once normalized
        logic               zero, inf, nan, snan, sub;
    } unp_t;

    function automatic unp_t unpack(input logic [63:0] r, input logic d);
        unp_t u;
        u = '0;
        if (d) begin
            u.s = r[63];
            if (r[62:52] == 11'd0) begin
                u.zero = r[51:0] == 52'd0; u.sub = !u.zero;
                u.e = -14'sd1022; u.m = {1'b0, r[51:0]};
            end else if (r[62:52] == 11'h7FF) begin
                u.inf = r[51:0] == 52'd0; u.nan = !u.inf; u.snan = u.nan && !r[51];
            end else begin
                u.e = $signed({3'd0, r[62:52]}) - 14'sd1023; u.m = {1'b1, r[51:0]};
            end
        end else begin
            u.s = r[31];
            if (r[30:23] == 8'd0) begin
                u.zero = r[22:0] == 23'd0; u.sub = !u.zero;
                u.e = -14'sd126; u.m = {1'b0, r[22:0], 29'd0};
            end else if (r[30:23] == 8'hFF) begin
                u.inf = r[22:0] == 23'd0; u.nan = !u.inf; u.snan = u.nan && !r[22];
            end else begin
                u.e = $signed({6'd0, r[30:23]}) - 14'sd127; u.m = {1'b1, r[22:0], 29'd0};
            end
        end
        return u;
    endfunction

    function automatic logic [5:0] lzc53(input logic [52:0] v);
        for (int i = 52; i >= 0; i--) if (v[i]) return 6'(52 - i);
        return 6'd53;
    endfunction
    function automatic logic [6:0] lzc110(input logic [109:0] v);
        for (int i = 109; i >= 0; i--) if (v[i]) return 7'(109 - i);
        return 7'd110;
    endfunction
    function automatic logic rinc(input logic [2:0] r, input logic s, input logic lsb, input logic g,
                                  input logic st);
        case (r)
            RNE:     return g && (st || lsb);
            RDN:     return s && (g || st);
            RUP:     return !s && (g || st);
            RMM:     return g;
            default: return 1'b0;
        endcase
    endfunction
    // the packed results
    function automatic logic [63:0] qnan(input logic d);
        return d ? 64'h7FF8_0000_0000_0000 : 64'h0000_0000_7FC0_0000;
    endfunction
    function automatic logic [63:0] infv(input logic d, input logic s);
        return d ? {s, 11'h7FF, 52'd0} : {32'd0, s, 8'hFF, 23'd0};
    endfunction
    function automatic logic [63:0] zerov(input logic d, input logic s);
        return d ? {s, 63'd0} : {32'd0, s, 31'd0};
    endfunction
    function automatic logic [63:0] maxv(input logic d, input logic s);
        return d ? {s, 11'h7FE, {52{1'b1}}} : {32'd0, s, 8'hFE, {23{1'b1}}};
    endfunction

    typedef enum logic [3:0] {
        S_IDLE, S_UNP, S_NRM, S_SPEC, S_MUL, S_PN, S_ALN, S_ADD, S_LZC, S_SHL, S_RND1, S_RND2,
        S_DIV, S_SQRT
    } st_t;
    st_t st;

    logic [4:0]  op_q;
    logic        dbl_q, odbl, imode, isgn;
    logic [2:0]  rm_q;
    logic [63:0] ra, rb, rc;
    unp_t        ua, ub, uc;
    // the product (or the pass-through) and the addend, 106 bits, the leading one at 105
    logic [105:0]       pm, cm;
    logic signed [13:0] pe, ce;
    logic               ps, cs, hc;
    // the multiplier
    logic [1:0]  mk;
    logic        mi_v, pp_v, pp_last;
    logic [66:0] pp;
    logic [53:0] acc_r;
    logic [55:0] acc_l;
    // the sum
    logic [109:0]       xw, yw, z;
    logic signed [13:0] ze;
    logic               zs, sub;
    logic [6:0]         lz;
    // normalized
    logic [109:0]       nrm;
    logic signed [13:0] ne;
    logic               ns;
    // rounding
    logic [52:0] kept;
    logic        g, stk, tiny, ovf_i;
    // division and square root
    logic [5:0]   cnt;
    logic [54:0]  q;
    logic [57:0]  rem;
    logic [109:0] rad;

    // the multiplier's slice of b: bits 14k .. 14k+13
    wire [55:0] mb56 = {3'd0, ub.m};
    logic [13:0] mchunk;
    always_comb case (mk)
        2'd0:    mchunk = mb56[13:0];
        2'd1:    mchunk = mb56[27:14];
        2'd2:    mchunk = mb56[41:28];
        default: mchunk = mb56[55:42];
    endcase

    // ---- SPEC's classification --------------------------------------------------------
    wire fma   = op_q == F_MADD || op_q == F_MSUB || op_q == F_NMSUB || op_q == F_NMADD;
    wire addop = op_q == F_ADD || op_q == F_SUB;
    wire byp   = addop || op_q == F_CVTFF;                          // the product is a itself
    wire psign = byp ? ua.s : (ua.s ^ ub.s ^ (op_q == F_NMSUB || op_q == F_NMADD));
    wire csgn  = addop ? (ub.s ^ (op_q == F_SUB)) : (uc.s ^ (op_q == F_MSUB || op_q == F_NMADD));
    wire hc_in = addop || fma;
    unp_t        uadd;
    always_comb uadd = addop ? ub : uc;
    wire [63:0]  raw_add = addop ? rb : rc;
    wire p_nan  = ua.nan || (!byp && ub.nan);
    wire p_snan = ua.snan || (!byp && ub.snan);
    wire p_inf  = ua.inf || (!byp && ub.inf);
    wire p_zero = ua.zero || (!byp && ub.zero);
    wire dv_inv  = (ua.inf && ub.inf) || (ua.zero && ub.zero);    // (never with a NaN)
    wire inv_mul = !byp && ((ua.inf && ub.zero) || (ua.zero && ub.inf));
    // a subnormal operand still to normalize
    wire na = !ua.zero && !ua.inf && !ua.nan && !ua.m[52];
    wire nb = !ub.zero && !ub.inf && !ub.nan && !ub.m[52];
    wire nc = !uc.zero && !uc.inf && !uc.nan && !uc.m[52];
    unp_t        un_sel;
    always_comb un_sel = na ? ua : nb ? ub : uc;
    wire [5:0]   un_lz = lzc53(un_sel.m);

    // the ordering for min/max and the compares (-0 below +0 here; the compares make them equal)
    wire [62:0] mag_a = dbl_q ? ra[62:0] : {32'd0, ra[30:0]};
    wire [62:0] mag_b = dbl_q ? rb[62:0] : {32'd0, rb[30:0]};
    wire        lt_raw = (ua.s != ub.s) ? ua.s : (ua.s ? mag_a > mag_b : mag_a < mag_b);
    wire        eq_raw = mag_a == mag_b && ua.s == ub.s;
    wire        bothz  = ua.zero && ub.zero;
    wire [63:0] sg_a   = dbl_q ? {1'b0, ra[62:0]} : {33'd0, ra[30:0]};
    function automatic logic [63:0] withsign(input logic d, input logic [63:0] m, input logic s);
        return d ? {s, m[62:0]} : {32'd0, s, m[30:0]};
    endfunction

    // ---- ALN ------------------------------------------------------------------------------
    wire              c_big  = hc && (ce > pe || (ce == pe && cm > pm));
    wire [105:0]      al_x   = c_big ? cm : pm;
    wire [105:0]      al_y   = !hc ? 106'd0 : c_big ? pm : cm;
    wire signed [13:0] al_ex = c_big ? ce : pe;
    wire signed [13:0] al_d  = !hc ? 14'sd0 : c_big ? ce - pe : pe - ce;
    wire [109:0]      al_yw  = {1'b0, al_y, 3'd0};
    wire [6:0]        al_dd  = al_d[6:0];
    wire [109:0]      al_ysh = al_d >= 14'sd110 ? {109'd0, |al_y}
                             : (al_yw >> al_dd) | {109'd0, |(al_yw & ~({110{1'b1}} << al_dd))};

    // ---- RND1: the shift to the output's precision ----------------------------------------
    wire signed [13:0] emin  = odbl ? -14'sd1022 : -14'sd126;
    wire signed [13:0] den   = (ne < emin) ? emin - ne : 14'sd0;
    wire signed [13:0] sh_f  = (odbl ? 14'sd0 : 14'sd29) + den;
    wire signed [13:0] sh_i  = 14'sd52 - ne;
    wire signed [13:0] sh_w  = imode ? sh_i : sh_f;
    wire [5:0]         sh    = sh_w > 14'sd63 ? 6'd63 : sh_w[5:0];
    wire [53:0]        r_hi  = nrm[109:56];
    wire [53:0]        r_t   = sh >= 6'd54 ? 54'd0 : r_hi >> sh;
    wire [53:0]        r_msk = sh >= 6'd54 ? {54{1'b1}} : ~({54{1'b1}} << sh);
    wire               r_stk = |nrm[55:0] || |(r_hi & r_msk);
    // tininess after rounding: rounded to p bits with an unbounded exponent, below 2^emin?
    wire allones_p = odbl ? &nrm[109:57] : &nrm[109:86];
    wire g_p       = odbl ? nrm[56] : nrm[85];
    wire s_p       = odbl ? |nrm[55:0] : |nrm[84:0];
    wire inc_p     = rinc(rm_q, ns, 1'b1, g_p, s_p);
    wire r_tiny    = ne < emin - 14'sd1 || (ne == emin - 14'sd1 && !(allones_p && inc_p));

    // ---- RND2: round and pack ---------------------------------------------------------------
    wire        r_inc  = rinc(rm_q, ns, kept[0], g, stk);
    wire [53:0] mr     = {1'b0, kept} + {53'd0, r_inc};
    wire        r_nx   = g || stk;
    wire        top    = odbl ? mr[52] : mr[23];
    wire        carry  = odbl ? mr[53] : mr[24];
    wire signed [13:0] eeff = ne < emin ? emin : ne;
    wire signed [13:0] ebias = eeff + (odbl ? 14'sd1023 : 14'sd127);
    wire signed [13:0] eout  = carry ? ebias + 14'sd1 : top ? ebias : 14'sd0;
    wire        r_ovf  = eout >= (odbl ? 14'sd2047 : 14'sd255);
    wire        ovf_inf = rm_q == RNE || rm_q == RMM || (rm_q == RDN && ns) || (rm_q == RUP && !ns);
    wire [63:0] fpack  = odbl ? {ns, eout[10:0], carry ? 52'd0 : mr[51:0]}
                              : {32'd0, ns, eout[7:0], carry ? 23'd0 : mr[22:0]};
    // the integer: saturation outside the range
    wire [32:0] imax   = isgn ? (ns ? 33'h0_8000_0000 : 33'h0_7FFF_FFFF) : (ns ? 33'd0 : 33'h0_FFFF_FFFF);
    wire        i_nv   = ovf_i || (|mr[53:33]) || ({1'b0, mr[32:0]} > {1'b0, imax}) ;
    wire [31:0] isat   = isgn ? (ns ? 32'h8000_0000 : 32'h7FFF_FFFF) : (ns ? 32'd0 : 32'hFFFF_FFFF);
    wire [31:0] ival   = ns ? -mr[31:0] : mr[31:0];

    // ---- division and square root steps -------------------------------------------------------
    wire [53:0] dv_r2  = rem[53:0];
    wire        dv_ge  = dv_r2 >= {1'b0, ub.m};
    wire [57:0] sq_r2  = {rem[55:0], rad[109:108]};
    wire [57:0] sq_t   = {1'b0, q, 2'b01};
    wire        sq_ge  = sq_r2 >= sq_t;

    task automatic finish(input logic [63:0] r, input logic [4:0] f);
        res <= r; flags <= f; done <= 1'b1; busy <= 1'b0; st <= S_IDLE;
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0; res <= 64'd0; flags <= 5'd0;
            mi_v <= 1'b0; pp_v <= 1'b0;
        end else if (kill) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0; mi_v <= 1'b0; pp_v <= 1'b0;
        end else begin
            done <= 1'b0;
            // the multiplier's slices: issued in MUL, accumulated a clock later
            pp_v <= mi_v; pp_last <= mi_v && mk == 2'd3;
            if (mi_v) pp <= ua.m * mchunk;
            case (st)
                S_IDLE: if (start) begin
                    op_q <= op; dbl_q <= dbl; rm_q <= rm; ra <= a; rb <= b; rc <= c;
                    busy <= 1'b1; st <= S_UNP;
                end
                S_UNP: begin
                    // FCVTW/WU/FF: a in `dbl`'s format; FCVTFW/FWU: a is an integer
                    ua <= unpack(ra, dbl_q); ub <= unpack(rb, dbl_q); uc <= unpack(rc, dbl_q);
                    odbl  <= op_q == F_CVTFF ? !dbl_q : dbl_q;
                    imode <= op_q == F_CVTW || op_q == F_CVTWU;
                    isgn  <= op_q == F_CVTW;
                    st <= S_NRM;
                end
                S_NRM: begin
                    if (na || nb || nc) begin
                        unp_t nu;
                        nu = un_sel;
                        nu.m = un_sel.m << un_lz;
                        nu.e = un_sel.e - 14'(un_lz);
                        if (na) ua <= nu; else if (nb) ub <= nu; else uc <= nu;
                    end else st <= S_SPEC;
                end
                S_SPEC: begin
                    // defaults for the arithmetic path
                    pm <= {ua.m, 53'd0}; pe <= ua.e; ps <= psign;
                    cm <= {uadd.m, 53'd0}; ce <= uadd.e; cs <= csgn; hc <= hc_in && !uadd.zero;
                    ns <= psign;
                    case (op_q)
                        F_SGNJ:  finish(withsign(dbl_q, sg_a, ub.s), 5'd0);
                        F_SGNJN: finish(withsign(dbl_q, sg_a, !ub.s), 5'd0);
                        F_SGNJX: finish(withsign(dbl_q, sg_a, ua.s ^ ub.s), 5'd0);
                        F_MIN, F_MAX: begin
                            logic [63:0] r;
                            if (ua.nan && ub.nan) r = qnan(dbl_q);
                            else if (ua.nan)      r = rb;
                            else if (ub.nan)      r = ra;
                            else                  r = (lt_raw ^ (op_q == F_MAX)) ? ra : rb;
                            if (!dbl_q) r[63:32] = 32'd0;
                            finish(r, (ua.snan || ub.snan) ? NV : 5'd0);
                        end
                        F_EQ: finish({63'd0, !ua.nan && !ub.nan && (eq_raw || bothz)},
                                     (ua.snan || ub.snan) ? NV : 5'd0);
                        F_LT: finish({63'd0, !ua.nan && !ub.nan && !bothz && lt_raw},
                                     (ua.nan || ub.nan) ? NV : 5'd0);
                        F_LE: finish({63'd0, !ua.nan && !ub.nan && (bothz || eq_raw || lt_raw)},
                                     (ua.nan || ub.nan) ? NV : 5'd0);
                        F_CLASS: finish({54'd0,
                                         ua.nan && !ua.snan, ua.snan,
                                         !ua.s && ua.inf, !ua.s && !ua.inf && !ua.nan && !ua.zero && !ua.sub,
                                         !ua.s && ua.sub, !ua.s && ua.zero,
                                         ua.s && ua.zero, ua.s && ua.sub,
                                         ua.s && !ua.inf && !ua.nan && !ua.zero && !ua.sub, ua.s && ua.inf}, 5'd0);
                        F_CVTW, F_CVTWU: begin
                            if (ua.nan)       finish({32'd0, op_q == F_CVTW ? 32'h7FFF_FFFF : 32'hFFFF_FFFF}, NV);
                            else if (ua.inf)  finish({32'd0, op_q == F_CVTW ? (ua.s ? 32'h8000_0000 : 32'h7FFF_FFFF)
                                                                           : (ua.s ? 32'd0 : 32'hFFFF_FFFF)}, NV);
                            else if (ua.zero) finish(64'd0, 5'd0);
                            else begin
                                nrm <= {ua.m, 57'd0}; ne <= $signed(ua.e) > 14'sd31 ? 14'sd31 : ua.e; ns <= ua.s;
                                ovf_i <= $signed(ua.e) > 14'sd31;
                                st <= S_RND1;
                            end
                        end
                        F_CVTFW, F_CVTFWU: begin
                            logic        sg;
                            logic [31:0] mag;
                            sg  = op_q == F_CVTFW && ra[31];
                            mag = sg ? -ra[31:0] : ra[31:0];
                            if (mag == 32'd0) finish(64'd0, 5'd0);
                            else begin
                                z <= {1'b0, mag, 77'd0}; ze <= 14'sd31; zs <= sg;
                                st <= S_LZC;
                            end
                        end
                        F_DIV: begin
                            if (ua.nan || ub.nan || dv_inv)
                                finish(qnan(dbl_q), (ua.snan || ub.snan || dv_inv) ? NV : 5'd0);
                            else if (ua.inf)  finish(infv(dbl_q, ua.s ^ ub.s), 5'd0);
                            else if (ub.zero) finish(infv(dbl_q, ua.s ^ ub.s), DZ);
                            else if (ua.zero || ub.inf) finish(zerov(dbl_q, ua.s ^ ub.s), 5'd0);
                            else begin
                                rem <= {5'd0, ua.m}; q <= 55'd0; cnt <= dbl_q ? 6'd55 : 6'd26;
                                ze <= ua.e - ub.e; zs <= ua.s ^ ub.s;
                                st <= S_DIV;
                            end
                        end
                        F_SQRT: begin
                            if (ua.nan)                 finish(qnan(dbl_q), ua.snan ? NV : 5'd0);
                            else if (ua.zero)           finish(zerov(dbl_q, ua.s), 5'd0);
                            else if (ua.s)              finish(qnan(dbl_q), NV);
                            else if (ua.inf)            finish(infv(dbl_q, 1'b0), 5'd0);
                            else begin
                                rad <= ua.e[0] ? {ua.m, 57'd0} : {1'b0, ua.m, 56'd0};
                                rem <= 58'd0; q <= 55'd0; cnt <= dbl_q ? 6'd55 : 6'd26;
                                ze <= $signed(ua.e - $signed({13'd0, ua.e[0]})) >>> 1; zs <= 1'b0;
                                st <= S_SQRT;
                            end
                        end
                        default: begin
                            // the arithmetic: add, sub, mul, the fused four, float to float
                            logic       anan, asnan;
                            anan  = p_nan || (hc_in && uadd.nan);
                            asnan = p_snan || (hc_in && uadd.snan);
                            if (anan || inv_mul)
                                finish(qnan(odbl), (asnan || inv_mul) ? NV : 5'd0);
                            else if (p_inf) begin
                                if (hc_in && uadd.inf && psign != csgn) finish(qnan(odbl), NV);
                                else finish(infv(odbl, psign), 5'd0);
                            end else if (hc_in && uadd.inf) finish(infv(odbl, csgn), 5'd0);
                            else if (p_zero) begin
                                if (hc_in && !uadd.zero) finish(withsign(dbl_q, raw_add, csgn), 5'd0);
                                else if (!hc_in)         finish(zerov(odbl, psign), 5'd0);
                                else finish(zerov(odbl, psign == csgn ? psign : rm_q == RDN), 5'd0);
                            end else if (byp) st <= S_ALN;
                            else begin
                                mk <= dbl_q ? 2'd0 : 2'd2; mi_v <= 1'b1;
                                acc_r <= 54'd0; acc_l <= 56'd0;
                                st <= S_MUL;
                            end
                        end
                    endcase
                end
                S_MUL: begin
                    // issue: one slice a clock; accumulate each a clock later
                    if (mi_v) begin
                        mk <= mk + 2'd1;
                        if (mk == 2'd3) mi_v <= 1'b0;
                    end
                    if (pp_v) begin
                        logic [67:0] t;
                        t = {14'd0, acc_r} + {1'b0, pp};
                        acc_l <= {t[13:0], acc_l[55:14]};
                        acc_r <= t[67:14];
                        if (pp_last) st <= S_PN;
                    end
                end
                S_PN: begin
                    logic [105:0] p;
                    p = {acc_r[49:0], acc_l};
                    pm <= p[105] ? p : {p[104:0], 1'b0};
                    pe <= ua.e + ub.e + (p[105] ? 14'sd1 : 14'sd0);
                    st <= S_ALN;
                end
                S_ALN: begin
                    xw  <= {1'b0, al_x, 3'd0};
                    yw  <= al_ysh;
                    ze  <= al_ex;
                    zs  <= c_big ? cs : ps;
                    sub <= hc && (ps != cs);
                    st  <= S_ADD;
                end
                S_ADD: begin
                    z  <= sub ? xw - yw : xw + yw;
                    st <= S_LZC;
                end
                S_LZC: begin
                    lz <= lzc110(z);
                    if (z == 110'd0) finish(zerov(odbl, rm_q == RDN), 5'd0);    // an exact cancellation
                    else st <= S_SHL;
                end
                S_SHL: begin
                    nrm <= z << lz;
                    ne  <= ze + 14'sd1 - 14'(lz);
                    ns  <= zs;
                    st  <= S_RND1;
                end
                S_RND1: begin
                    kept <= r_t[53:1]; g <= r_t[0]; stk <= r_stk;
                    tiny <= !imode && r_tiny;
                    st <= S_RND2;
                end
                S_RND2: begin
                    if (imode) begin
                        if (i_nv) finish({32'd0, isat}, NV);
                        else      finish({32'd0, ival}, r_nx ? NX : 5'd0);
                    end else if (r_ovf)
                        finish(ovf_inf ? infv(odbl, ns) : maxv(odbl, ns), OF | NX);
                    else
                        finish(fpack, (r_nx ? NX : 5'd0) | ((tiny && r_nx) ? UF : 5'd0));
                end
                S_DIV: begin
                    if (cnt != 6'd0) begin
                        q   <= {q[53:0], dv_ge};
                        rem <= {4'd0, (dv_ge ? dv_r2 - {1'b0, ub.m} : dv_r2) << 1};
                        cnt <= cnt - 6'd1;
                    end else begin
                        z  <= {1'b0, dbl_q ? q : q << 29, 53'd0, rem != 58'd0};
                        st <= S_LZC;
                    end
                end
                S_SQRT: begin
                    if (cnt != 6'd0) begin
                        rem <= sq_ge ? sq_r2 - sq_t : sq_r2;
                        q   <= {q[53:0], sq_ge};
                        rad <= {rad[107:0], 2'b00};
                        cnt <= cnt - 6'd1;
                    end else begin
                        z  <= {1'b0, dbl_q ? q : q << 29, 53'd0, rem != 58'd0};
                        st <= S_LZC;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    wire unused = &{1'b0, sg_a[63]};
endmodule
