// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// rv_ref.h - the reference RV32IMFD_Zba_Zbb model with rvvm's execution
// environment (docs/REQ_RVVM.md): the identity address map with its null guard,
// the ECALL services, the trap causes.  Written from the spec, independent of
// both implementations it judges: the 65816 VM (sim/rvvm_run_main.cpp) and the
// RISC-V engine (sim/rv_core_main.cpp) run in lockstep against it.
//
// FLOATING POINT (F and D): 32 FP registers of 64 bits, a single NaN-boxed (a
// source not boxed reads as the canonical NaN; fmv.x.w and fsw take the raw
// bits), fcsr's CSRs 1-3.  The arithmetic is Berkeley SoftFloat 3 built with the
// RISCV specialization, as spike's (../berkeley-softfloat-3: `make
// SPECIALIZE_TYPE=RISCV` in build/Linux-x86_64-GCC; every bench that includes
// this links it).
#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
extern "C" {
#include "softfloat.h"
}

static const uint32_t SPACE = 1u << 25;       // the engine's space: the whole 32 MB DDR3 bank
static const uint32_t LOW   = 1u << 24;       // the 65816's space: the services it performs reach only this
static const uint32_t GUARD = 0x100;          // the null guard: $000000-$0000FF
static const uint32_t ROM_LO = 0xF00000;      // banks $F0-$FF: ROM - a store there is dropped, as the machine drops it
static const uint32_t DEFAULT_SP = 0xE00000;  // the top of $DF

// Trap causes.
enum { T_ILLEGAL = 1, T_EBREAK = 2, T_LOAD = 3, T_STORE = 4, T_FETCH = 5 };
static const char *cause_name(unsigned c) {
    switch (c) {
        case T_ILLEGAL: return "illegal instruction";
        case T_EBREAK: return "ebreak";
        case T_LOAD: return "load fault";
        case T_STORE: return "store fault";
        case T_FETCH: return "fetch fault";
    }
    return "?";
}
static const char *abi[32] = {"zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0",
                              "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5",
                              "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

// ---- the reference model ---------------------------------------------------
// An FP instruction (OP-FP, the fused four): its name, or nullptr when reserved.
// `rmchk`: f3 is a rounding mode (5 and 6 reserved; 7 = frm, which must be 0-4).
static const char *fp_name(uint32_t in, bool *rmchk = nullptr) {
    const uint32_t op = in & 0x7F, f3 = (in >> 12) & 7, rs2 = (in >> 20) & 31, f5 = in >> 27, fmt = (in >> 25) & 3;
    if (fmt > 1) return nullptr;
    const bool d = fmt == 1;
    bool rm = true;
    const char *n = nullptr;
    if (op == 0x43 || op == 0x47 || op == 0x4B || op == 0x4F) {
        n = op == 0x43 ? "fmadd" : op == 0x47 ? "fmsub" : op == 0x4B ? "fnmsub" : "fnmadd";
    } else if (op == 0x53) {
        switch (f5) {
            case 0x00: n = "fadd"; break;
            case 0x01: n = "fsub"; break;
            case 0x02: n = "fmul"; break;
            case 0x03: n = "fdiv"; break;
            case 0x0B: n = rs2 ? nullptr : "fsqrt"; break;
            case 0x04: n = f3 <= 2 ? "fsgnj" : nullptr; rm = false; break;
            case 0x05: n = f3 <= 1 ? "fminmax" : nullptr; rm = false; break;
            case 0x14: n = f3 <= 2 ? "fcmp" : nullptr; rm = false; break;
            case 0x1C: n = rs2 ? nullptr : f3 == 1 ? "fclass" : (f3 == 0 && !d) ? "fmv.x.w" : nullptr; rm = false; break;
            case 0x1E: n = (!rs2 && f3 == 0 && !d) ? "fmv.w.x" : nullptr; rm = false; break;
            case 0x18: n = rs2 <= 1 ? "fcvt.w" : nullptr; break;
            case 0x1A: n = rs2 <= 1 ? "fcvt.f.w" : nullptr; break;
            case 0x08: n = rs2 == (d ? 0u : 1u) ? (d ? "fcvt.d.s" : "fcvt.s.d") : nullptr; break;
        }
    }
    if (n && rm && (f3 == 5 || f3 == 6)) n = nullptr;
    if (rmchk) *rmchk = rm;
    return n;
}

static const char *mnemonic(uint32_t in) {
    const uint32_t op = in & 0x7F, f3 = (in >> 12) & 7, f7 = in >> 25, imm = in >> 20;
    switch (op) {
        case 0x07: return f3 == 2 ? "flw" : f3 == 3 ? "fld" : nullptr;
        case 0x27: return f3 == 2 ? "fsw" : f3 == 3 ? "fsd" : nullptr;
        case 0x53: case 0x43: case 0x47: case 0x4B: case 0x4F: return fp_name(in);
        case 0x37: return "lui";
        case 0x17: return "auipc";
        case 0x6F: return "jal";
        case 0x67: return f3 == 0 ? "jalr" : nullptr;
        case 0x63: { static const char *n[8] = {"beq", "bne", 0, 0, "blt", "bge", "bltu", "bgeu"}; return n[f3]; }
        case 0x03: { static const char *n[8] = {"lb", "lh", "lw", 0, "lbu", "lhu", 0, 0}; return n[f3]; }
        case 0x23: { static const char *n[8] = {"sb", "sh", "sw", 0, 0, 0, 0, 0}; return n[f3]; }
        case 0x13:
            switch (f3) {
                case 0: return "addi"; case 2: return "slti"; case 3: return "sltiu";
                case 4: return "xori"; case 6: return "ori";  case 7: return "andi";
                case 1:
                    if (f7 == 0) return "slli";
                    if (imm == 0x600) return "clz";
                    if (imm == 0x601) return "ctz";
                    if (imm == 0x602) return "cpop";
                    if (imm == 0x604) return "sext.b";
                    if (imm == 0x605) return "sext.h";
                    return nullptr;
                case 5:
                    if (f7 == 0) return "srli";
                    if (f7 == 0x20) return "srai";
                    if (f7 == 0x30) return "rori";
                    if (imm == 0x698) return "rev8";
                    if (imm == 0x287) return "orc.b";
                    return nullptr;
            }
            return nullptr;
        case 0x33:
            switch (f7) {
                case 0x00: { static const char *n[8] = {"add", "sll", "slt", "sltu", "xor", "srl", "or", "and"}; return n[f3]; }
                case 0x20: { static const char *n[8] = {"sub", 0, 0, 0, "xnor", "sra", "orn", "andn"}; return n[f3]; }
                case 0x01: { static const char *n[8] = {"mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"}; return n[f3]; }
                case 0x05: { static const char *n[8] = {0, 0, 0, 0, "min", "minu", "max", "maxu"}; return n[f3]; }
                case 0x10: { static const char *n[8] = {0, 0, "sh1add", 0, "sh2add", 0, "sh3add", 0}; return n[f3]; }
                case 0x30: { static const char *n[8] = {0, "rol", 0, 0, 0, "ror", 0, 0}; return n[f3]; }
                case 0x04: return (f3 == 4 && ((in >> 20) & 31) == 0) ? "zext.h" : nullptr;
            }
            return nullptr;
        case 0x0F: return f3 <= 1 ? (f3 ? "fence.i" : "fence") : nullptr;
        case 0x73:
            if (in == 0x00000073) return "ecall";
            if (in == 0x00100073) return "ebreak";
            if (f3 != 0 && f3 != 4 && imm >= 1 && imm <= 3) return "csr";   // fflags, frm, fcsr
            return nullptr;
    }
    return nullptr;
}

struct Ref {
    std::vector<uint8_t> m;   // the whole space, plus slack for a straddling access
    uint32_t space = SPACE;   // where the engine's own accesses are legal (LOW for a bench whose
                              // memory side is the 65816, which reaches only the lower 16 MB)
    uint32_t x[32] = {0}, pc = 0;
    uint64_t f[32] = {0};
    uint32_t fflags = 0, frm = 0;
    unsigned status = 0, cause = 0;
    uint32_t code = 0, tval = 0;
    std::string out, in;
    size_t in_pos = 0;
    bool nondet = false;   // the last ECALL's a0/a1 are the platform's (cycles): take the VM's
    uint64_t instret = 0;
    // a sizing study's tap: every fetch ('F'), load ('L') and store ('S') address
    void (*on_acc)(char, uint32_t) = nullptr;

    // The engine's range rule: an access is legal when its first AND last bytes are
    // below `space` ($0200_0000) and outside the null guard (acc_ok); alignment is
    // free - the engine does a misaligned access itself.  A SERVICE the 65816 performs - a write or read buffer, peek, poke -
    // must lie in the 65816's own space, below $0100_0000 (low_ok).
    bool ok(uint32_t a) const { return a < space && a >= GUARD; }
    bool acc_ok(uint32_t a, uint32_t n) const { return ok(a) && ok(a + n - 1); }
    static bool low_ok(uint32_t a) { return a < LOW && a >= GUARD; }
    uint32_t ld(uint32_t a, int n) const { uint32_t v = 0; for (int i = 0; i < n; i++) v |= uint32_t(m[a + i]) << (8 * i); return v; }
    static uint64_t box(uint32_t v) { return 0xFFFFFFFF00000000ull | v; }
    void st(uint32_t a, uint32_t v, int n) {
        for (int i = 0; i < n; i++) if (a + i < ROM_LO || a + i >= LOW) m[a + i] = uint8_t(v >> (8 * i));
    }
    void trap(unsigned c, uint32_t t) { status = 2; cause = c; tval = t; }
    bool target(uint32_t t) { if ((t & 3) || !ok(t)) { trap(T_FETCH, t); return false; } return true; }

    void step() {
        if ((pc & 3) || !ok(pc)) { trap(T_FETCH, pc); return; }
        const uint32_t in = ld(pc, 4);
        if (on_acc) on_acc('F', pc);
        if (!mnemonic(in)) { trap(T_ILLEGAL, in); return; }
        const uint32_t op = in & 0x7F, rd = (in >> 7) & 31, f3 = (in >> 12) & 7,
                       rs1 = (in >> 15) & 31, rs2 = (in >> 20) & 31, f7 = in >> 25, imm12 = in >> 20;
        const uint32_t iI = uint32_t(int32_t(in) >> 20);
        const uint32_t iS = uint32_t((int32_t(in) >> 25) << 5) | ((in >> 7) & 31);
        const uint32_t iB = uint32_t((int32_t(in) >> 31) << 12) | ((in << 4) & 0x800) | ((in >> 20) & 0x7E0) | ((in >> 7) & 0x1E);
        const uint32_t iU = in & 0xFFFFF000u;
        const uint32_t iJ = uint32_t((int32_t(in) >> 31) << 20) | (in & 0xFF000) | ((in >> 9) & 0x800) | ((in >> 20) & 0x7FE);
        const uint32_t a = x[rs1], b = x[rs2];
        uint32_t npc = pc + 4, r = 0;
        bool wr = true;
        switch (op) {
            case 0x37: r = iU; break;
            case 0x17: r = pc + iU; break;
            case 0x6F: { const uint32_t t = pc + iJ; if (!target(t)) return; r = npc; npc = t; break; }
            case 0x67: { const uint32_t t = (a + iI) & ~1u; if (!target(t)) return; r = npc; npc = t; break; }
            case 0x63: {
                bool take = false;
                switch (f3) {
                    case 0: take = a == b; break; case 1: take = a != b; break;
                    case 4: take = int32_t(a) < int32_t(b); break; case 5: take = int32_t(a) >= int32_t(b); break;
                    case 6: take = a < b; break; case 7: take = a >= b; break;
                }
                wr = false;
                if (take) { const uint32_t t = pc + iB; if (!target(t)) return; npc = t; }
                break;
            }
            case 0x03: {
                const uint32_t ea = a + iI;
                if (!acc_ok(ea, 1u << (f3 & 3))) { trap(T_LOAD, ea); return; }
                if (on_acc) on_acc('L', ea);
                switch (f3) {
                    case 0: r = uint32_t(int8_t(ld(ea, 1))); break; case 1: r = uint32_t(int16_t(ld(ea, 2))); break;
                    case 2: r = ld(ea, 4); break; case 4: r = ld(ea, 1); break; case 5: r = ld(ea, 2); break;
                }
                break;
            }
            case 0x23: {
                const uint32_t ea = a + iS;
                if (!acc_ok(ea, 1u << (f3 & 3))) { trap(T_STORE, ea); return; }
                if (on_acc) on_acc('S', ea);
                st(ea, b, f3 == 0 ? 1 : f3 == 1 ? 2 : 4);
                wr = false;
                break;
            }
            case 0x13: {
                const uint32_t sh = imm12 & 31;
                switch (f3) {
                    case 0: r = a + iI; break; case 2: r = int32_t(a) < int32_t(iI); break; case 3: r = a < iI; break;
                    case 4: r = a ^ iI; break; case 6: r = a | iI; break; case 7: r = a & iI; break;
                    case 1:
                        if (f7 == 0) r = a << sh;
                        else if (imm12 == 0x600) r = a ? __builtin_clz(a) : 32;
                        else if (imm12 == 0x601) r = a ? __builtin_ctz(a) : 32;
                        else if (imm12 == 0x602) r = __builtin_popcount(a);
                        else if (imm12 == 0x604) r = uint32_t(int8_t(a));
                        else r = uint32_t(int16_t(a));
                        break;
                    case 5:
                        if (f7 == 0) r = a >> sh;
                        else if (f7 == 0x20) r = uint32_t(int32_t(a) >> sh);
                        else if (f7 == 0x30) r = sh ? (a >> sh) | (a << (32 - sh)) : a;
                        else if (imm12 == 0x698) r = __builtin_bswap32(a);
                        else { r = 0; for (int i = 0; i < 4; i++) if ((a >> (8 * i)) & 0xFF) r |= 0xFFu << (8 * i); }
                        break;
                }
                break;
            }
            case 0x33: {
                const uint32_t sh = b & 31;
                if (f7 == 0x00) {
                    switch (f3) {
                        case 0: r = a + b; break; case 1: r = a << sh; break;
                        case 2: r = int32_t(a) < int32_t(b); break; case 3: r = a < b; break;
                        case 4: r = a ^ b; break; case 5: r = a >> sh; break;
                        case 6: r = a | b; break; case 7: r = a & b; break;
                    }
                } else if (f7 == 0x20) {
                    switch (f3) {
                        case 0: r = a - b; break; case 5: r = uint32_t(int32_t(a) >> sh); break;
                        case 4: r = ~(a ^ b); break; case 6: r = a | ~b; break; case 7: r = a & ~b; break;
                    }
                } else if (f7 == 0x01) {
                    const int32_t sa = int32_t(a), sb = int32_t(b);
                    switch (f3) {
                        case 0: r = a * b; break;
                        case 1: r = uint32_t((int64_t(sa) * int64_t(sb)) >> 32); break;
                        case 2: r = uint32_t((int64_t(sa) * int64_t(uint64_t(b))) >> 32); break;
                        case 3: r = uint32_t((uint64_t(a) * uint64_t(b)) >> 32); break;
                        case 4: r = b == 0 ? ~0u : (sa == INT32_MIN && sb == -1) ? a : uint32_t(sa / sb); break;
                        case 5: r = b == 0 ? ~0u : a / b; break;
                        case 6: r = b == 0 ? a : (sa == INT32_MIN && sb == -1) ? 0 : uint32_t(sa % sb); break;
                        case 7: r = b == 0 ? a : a % b; break;
                    }
                } else if (f7 == 0x05) {
                    switch (f3) {
                        case 4: r = int32_t(a) < int32_t(b) ? a : b; break; case 5: r = a < b ? a : b; break;
                        case 6: r = int32_t(a) > int32_t(b) ? a : b; break; case 7: r = a > b ? a : b; break;
                    }
                } else if (f7 == 0x10) {
                    r = (a << (f3 >> 1)) + b;
                } else if (f7 == 0x30) {
                    r = sh == 0 ? a : f3 == 1 ? (a << sh) | (a >> (32 - sh)) : (a >> sh) | (a << (32 - sh));
                } else {
                    r = a & 0xFFFF;   // zext.h
                }
                break;
            }
            case 0x07: {                                            // flw, fld
                const uint32_t ea = a + iI;
                const bool d = f3 == 3;
                if (!acc_ok(ea, d ? 8 : 4)) { trap(T_LOAD, ea); return; }
                if (on_acc) on_acc('L', ea);
                f[rd] = d ? (uint64_t(ld(ea + 4, 4)) << 32) | ld(ea, 4) : box(ld(ea, 4));
                wr = false;
                break;
            }
            case 0x27: {                                            // fsw, fsd
                const uint32_t ea = a + iS;
                const bool d = f3 == 3;
                if (!acc_ok(ea, d ? 8 : 4)) { trap(T_STORE, ea); return; }
                if (on_acc) on_acc('S', ea);
                st(ea, uint32_t(f[rs2]), 4);
                if (d) st(ea + 4, uint32_t(f[rs2] >> 32), 4);
                wr = false;
                break;
            }
            case 0x53: case 0x43: case 0x47: case 0x4B: case 0x4F:
                wr = false;
                if (!fp(in)) return;
                break;
            case 0x0F: wr = false; break;
            case 0x73:
                wr = false;
                if (f3 != 0) {                                      // Zicsr on fflags, frm, fcsr
                    const uint32_t old = imm12 == 1 ? fflags : imm12 == 2 ? frm : (frm << 5) | fflags;
                    const uint32_t src = (f3 & 4) ? rs1 : a;
                    const uint32_t nv = (f3 & 3) == 1 ? src : (f3 & 3) == 2 ? (old | src) : (old & ~src);
                    if ((f3 & 3) == 1 || rs1 != 0) {
                        if (imm12 == 1) fflags = nv & 31;
                        else if (imm12 == 2) frm = nv & 7;
                        else { frm = (nv >> 5) & 7; fflags = nv & 31; }
                    }
                    r = old; wr = true;
                    break;
                }
                if (in == 0x00100073) { trap(T_EBREAK, 0); return; }
                if (!ecall()) return;
                break;
        }
        if (wr && rd) x[rd] = r;
        pc = npc;
        instret++;
    }

    // One FP op (legal by fp_name).  false = an illegal dynamic rounding mode
    // (frm > 4): trapped, pc stays.
    bool fp(uint32_t in) {
        bool rmchk = true;
        fp_name(in, &rmchk);
        const uint32_t op = in & 0x7F, f3 = (in >> 12) & 7, rd = (in >> 7) & 31, rs1 = (in >> 15) & 31,
                       rs2 = (in >> 20) & 31, rs3 = in >> 27, f5 = in >> 27;
        const bool d = ((in >> 25) & 3) == 1;
        const uint32_t rm = f3 == 7 ? frm : f3;
        if (rmchk && rm > 4) { trap(T_ILLEGAL, in); return false; }
        softfloat_roundingMode = uint_fast8_t(rm);
        softfloat_detectTininess = softfloat_tininess_afterRounding;
        softfloat_exceptionFlags = 0;
        // the sources in the op's format: a single unboxed
        auto src = [&](uint32_t r, bool dd) -> uint64_t {
            return dd ? f[r] : (f[r] >> 32) == 0xFFFFFFFFu ? uint32_t(f[r]) : 0x7FC00000u;
        };
        const bool sd = (op == 0x53 && f5 == 0x08) ? !d : d;    // fcvt.d.s's source is a single (the
                                                                // fused four's bits 31:27 are rs3)
        const uint64_t A = src(rs1, sd), B = src(rs2, d), C = src(rs3, d);
        const uint64_t S = d ? 0x8000000000000000ull : 0x80000000u;
        auto f32 = [](uint64_t v) { float32_t t; t.v = uint32_t(v); return t; };
        auto f64 = [](uint64_t v) { float64_t t; t.v = v; return t; };
        auto isnan = [&](uint64_t v) {
            return d ? ((v >> 52) & 0x7FF) == 0x7FF && (v & 0xFFFFFFFFFFFFFull)
                     : ((v >> 23) & 0xFF) == 0xFF && (v & 0x7FFFFF);
        };
        auto mad = [&](uint64_t p, uint64_t q, uint64_t s) -> uint64_t {
            return d ? f64_mulAdd(f64(p), f64(q), f64(s)).v : f32_mulAdd(f32(p), f32(q), f32(s)).v;
        };
        uint64_t r = 0;
        bool to_x = false;                                      // the result is an integer register's
        bool rdbl = d;                                          // ...else an FP register's, in this format
        if (op == 0x43) r = mad(A, B, C);
        else if (op == 0x47) r = mad(A, B, C ^ S);
        else if (op == 0x4B) r = mad(A ^ S, B, C);
        else if (op == 0x4F) r = mad(A ^ S, B, C ^ S);
        else switch (f5) {
            case 0x00: r = d ? f64_add(f64(A), f64(B)).v : f32_add(f32(A), f32(B)).v; break;
            case 0x01: r = d ? f64_sub(f64(A), f64(B)).v : f32_sub(f32(A), f32(B)).v; break;
            case 0x02: r = d ? f64_mul(f64(A), f64(B)).v : f32_mul(f32(A), f32(B)).v; break;
            case 0x03: r = d ? f64_div(f64(A), f64(B)).v : f32_div(f32(A), f32(B)).v; break;
            case 0x0B: r = d ? f64_sqrt(f64(A)).v : f32_sqrt(f32(A)).v; break;
            case 0x04: r = f3 == 0 ? (A & ~S) | (B & S) : f3 == 1 ? (A & ~S) | (~B & S) : A ^ (B & S); break;
            case 0x05: {
                bool pick_a;
                if (f3 == 0) pick_a = d ? f64_lt_quiet(f64(A), f64(B)) || (f64_eq(f64(A), f64(B)) && (A & S))
                                        : f32_lt_quiet(f32(A), f32(B)) || (f32_eq(f32(A), f32(B)) && (A & S));
                else         pick_a = d ? f64_lt_quiet(f64(B), f64(A)) || (f64_eq(f64(B), f64(A)) && (B & S))
                                        : f32_lt_quiet(f32(B), f32(A)) || (f32_eq(f32(B), f32(A)) && (B & S));
                if (isnan(A) && isnan(B)) r = d ? 0x7FF8000000000000ull : 0x7FC00000u;
                else r = (pick_a || isnan(B)) ? A : B;
                break;
            }
            case 0x14:
                to_x = true;
                r = f3 == 2 ? (d ? f64_eq(f64(A), f64(B)) : f32_eq(f32(A), f32(B)))
                  : f3 == 1 ? (d ? f64_lt(f64(A), f64(B)) : f32_lt(f32(A), f32(B)))
                            : (d ? f64_le(f64(A), f64(B)) : f32_le(f32(A), f32(B)));
                break;
            case 0x1C:
                to_x = true;
                if (f3 == 0) { r = uint32_t(f[rs1]); break; }  // fmv.x.w: the raw bits
                {
                    const bool s = d ? A >> 63 : (A >> 31) & 1;
                    const uint64_t e = d ? (A >> 52) & 0x7FF : (A >> 23) & 0xFF, emax = d ? 0x7FF : 0xFF;
                    const uint64_t fr = d ? A & 0xFFFFFFFFFFFFFull : A & 0x7FFFFF, qb = d ? 1ull << 51 : 1ull << 22;
                    if (e == emax) r = fr ? ((fr & qb) ? 1u << 9 : 1u << 8) : (s ? 1u : 1u << 7);
                    else if (e == 0) r = fr ? (s ? 1u << 2 : 1u << 5) : (s ? 1u << 3 : 1u << 4);
                    else r = s ? 1u << 1 : 1u << 6;
                }
                break;
            case 0x1E: r = x[rs1]; break;                       // fmv.w.x
            case 0x18:
                to_x = true;
                r = rs2 ? (d ? f64_to_ui32(f64(A), uint_fast8_t(rm), true) : f32_to_ui32(f32(A), uint_fast8_t(rm), true))
                        : uint32_t(d ? f64_to_i32(f64(A), uint_fast8_t(rm), true) : f32_to_i32(f32(A), uint_fast8_t(rm), true));
                break;
            case 0x1A:
                r = rs2 ? (d ? ui32_to_f64(x[rs1]).v : ui32_to_f32(x[rs1]).v)
                        : (d ? i32_to_f64(int32_t(x[rs1])).v : i32_to_f32(int32_t(x[rs1])).v);
                break;
            case 0x08: r = d ? f32_to_f64(f32(A)).v : f64_to_f32(f64(A)).v; break;
        }
        fflags |= softfloat_exceptionFlags;
        if (to_x) { if (rd) x[rd] = uint32_t(r); }
        else f[rd] = rdbl ? r : box(uint32_t(r));
        return true;
    }

    // The ECALL services (a7 = number; Linux/newlib numbering).  false = the
    // run stopped (exit or a fault) and pc must not move.
    bool ecall() {
        switch (x[17]) {
            case 93: status = 1; code = x[10]; return false;
            case 64: {
                const uint32_t fd = x[10], buf = x[11], len = x[12];
                if (fd != 1 && fd != 2) { x[10] = uint32_t(-9); return true; }
                for (uint32_t i = 0; i < len; i++) {
                    if (!low_ok(buf + i)) { trap(T_LOAD, buf + i); return false; }
                    out += char(m[buf + i]);
                }
                x[10] = len;
                return true;
            }
            case 0x5000: x[10] = x[11] = 0; nondet = true; return true;
            case 0x5001: case 0x5002: {                        // peek, poke: anywhere below $0100_0000
                const bool peek = x[17] == 0x5001;
                const uint32_t a = x[10], w = peek ? x[11] : x[12];
                if (a >= LOW) { trap(peek ? T_LOAD : T_STORE, a); return false; }
                if (w != 1 && w != 2 && w != 4) { x[10] = peek ? 0 : uint32_t(-22); return true; }
                if (peek) {
                    x[10] = ld(a, int(w));
                    if (a < 0x200) nondet = true;   // the VM's own direct page and stack: take the VM's value
                } else {
                    st(a, x[11], int(w));
                    x[10] = 0;
                }
                return true;
            }
            case 63: {
                const uint32_t fd = x[10], buf = x[11], len = x[12];
                if (fd != 0) { x[10] = uint32_t(-9); return true; }
                uint32_t n = 0;
                while (n < len && in_pos < in.size()) {
                    if (!low_ok(buf + n)) { trap(T_STORE, buf + n); return false; }
                    st(buf + n, uint8_t(in[in_pos++]), 1);   // (the ROM drops it, as any 65816 write)
                    n++;
                }
                x[10] = n;
                return true;
            }
        }
        x[10] = uint32_t(-38);   // ENOSYS
        return true;
    }
};

