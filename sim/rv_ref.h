// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// rv_ref.h - the reference RV32IM_Zba_Zbb model with rvvm's execution
// environment (docs/REQ_RVVM.md): the identity address map with its null guard,
// the ECALL services, the trap causes.  Written from the spec, independent of
// both implementations it judges: the 65816 VM (sim/rvvm_run_main.cpp) and the
// RISC-V engine (sim/rv_core_main.cpp) run in lockstep against it.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

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
static const char *mnemonic(uint32_t in) {
    const uint32_t op = in & 0x7F, f3 = (in >> 12) & 7, f7 = in >> 25, imm = in >> 20;
    switch (op) {
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
            return nullptr;
    }
    return nullptr;
}

struct Ref {
    std::vector<uint8_t> m;   // the whole space, plus slack for a straddling access
    uint32_t space = SPACE;   // where the engine's own accesses are legal (LOW for a bench whose
                              // memory side is the 65816, which reaches only the lower 16 MB)
    uint32_t x[32] = {0}, pc = 0;
    unsigned status = 0, cause = 0;
    uint32_t code = 0, tval = 0;
    std::string out, in;
    size_t in_pos = 0;
    bool nondet = false;   // the last ECALL's a0/a1 are the platform's (cycles): take the VM's
    uint64_t instret = 0;
    // a sizing study's tap: every fetch ('F'), load ('L') and store ('S') address
    void (*on_acc)(char, uint32_t) = nullptr;

    // The engine's range rule: an access is legal when its FIRST byte is below
    // `space` ($0200_0000) and outside the null guard (a straddle off the end is not
    // caught).  A SERVICE the 65816 performs - a write or read buffer, peek, poke -
    // must lie in the 65816's own space, below $0100_0000 (low_ok).
    bool ok(uint32_t a) const { return a < space && a >= GUARD; }
    static bool low_ok(uint32_t a) { return a < LOW && a >= GUARD; }
    uint32_t ld(uint32_t a, int n) const { uint32_t v = 0; for (int i = 0; i < n; i++) v |= uint32_t(m[a + i]) << (8 * i); return v; }
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
                if (!ok(ea)) { trap(T_LOAD, ea); return; }
                if (on_acc) on_acc('L', ea);
                switch (f3) {
                    case 0: r = uint32_t(int8_t(ld(ea, 1))); break; case 1: r = uint32_t(int16_t(ld(ea, 2))); break;
                    case 2: r = ld(ea, 4); break; case 4: r = ld(ea, 1); break; case 5: r = ld(ea, 2); break;
                }
                break;
            }
            case 0x23: {
                const uint32_t ea = a + iS;
                if (!ok(ea)) { trap(T_STORE, ea); return; }
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
            case 0x0F: wr = false; break;
            case 0x73:
                wr = false;
                if (in == 0x00100073) { trap(T_EBREAK, 0); return; }
                if (!ecall()) return;
                break;
        }
        if (wr && rd) x[rd] = r;
        pc = npc;
        instret++;
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

