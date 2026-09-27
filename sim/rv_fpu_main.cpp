// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// rv_fpu_main.cpp - rtl/gs/rv_fpu.sv against Berkeley SoftFloat 3 built with
// the RISCV specialization (the model spike uses: the canonical NaN, tininess
// after rounding, RISC-V's saturating conversions).  Two sources of cases:
//
//   rv_fpu_run --tf OP --dbl 0|1 --rm N   < testfloat_gen output
//       OP: add sub mul div sqrt madd eq lt le cvtw cvtwu cvtfw cvtfwu cvtff
//       (cvtff: --dbl is the source's format)
//   rv_fpu_run --rand N [--seed S]
//       every opcode, every rounding mode, both formats, operands biased to the
//       edges (zeros, subnormals, the extremes, NaNs, near-cancellations)
//
// A mismatch prints the case and counts; the run exits 1 on any.
#include "Vrv_fpu.h"
#include "verilated.h"
extern "C" {
#include "softfloat.h"
}
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <random>

enum {
    F_ADD, F_SUB, F_MUL, F_DIV, F_SQRT, F_MADD, F_MSUB, F_NMSUB, F_NMADD,
    F_SGNJ, F_SGNJN, F_SGNJX, F_MIN, F_MAX, F_EQ, F_LT, F_LE, F_CLASS,
    F_CVTW, F_CVTWU, F_CVTFW, F_CVTFWU, F_CVTFF, F_N
};
static const char *opname[F_N] = {"add", "sub", "mul", "div", "sqrt", "madd", "msub", "nmsub", "nmadd",
                                  "sgnj", "sgnjn", "sgnjx", "min", "max", "eq", "lt", "le", "class",
                                  "cvtw", "cvtwu", "cvtfw", "cvtfwu", "cvtff"};

static Vrv_fpu *top;
static uint64_t clocks;
static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    clocks++;
}

struct Out { uint64_t v; unsigned f; };
static unsigned max_lat[F_N][2];

static Out dut(int op, int dbl, int rm, uint64_t a, uint64_t b, uint64_t c) {
    top->op = op; top->dbl = dbl; top->rm = rm; top->a = a; top->b = b; top->c = c;
    top->start = 1;
    tick();
    top->start = 0;
    unsigned n = 1;
    while (!top->done) {
        tick();
        if (++n > 1000) { fprintf(stderr, "hang: op %s\n", opname[op]); exit(2); }
    }
    if (n > max_lat[op][dbl]) max_lat[op][dbl] = n;
    Out o{top->res, top->flags};
    tick();     // back to idle
    return o;
}

// ---- the reference -------------------------------------------------------------
static const uint32_t S32 = 0x80000000u;
static const uint64_t S64 = 0x8000000000000000ull;
static bool nan32(uint32_t v) { return (v & 0x7F800000u) == 0x7F800000u && (v & 0x7FFFFFu); }
static bool nan64(uint64_t v) { return (v & 0x7FF0000000000000ull) == 0x7FF0000000000000ull && (v & 0xFFFFFFFFFFFFFull); }
static uint32_t cls32(uint32_t v) {
    bool s = v >> 31; uint32_t e = (v >> 23) & 0xFF, f = v & 0x7FFFFF;
    if (e == 0xFF) return f ? ((f >> 22) ? 1u << 9 : 1u << 8) : (s ? 1u : 1u << 7);
    if (e == 0) return f ? (s ? 1u << 2 : 1u << 5) : (s ? 1u << 3 : 1u << 4);
    return s ? 1u << 1 : 1u << 6;
}
static uint32_t cls64(uint64_t v) {
    bool s = v >> 63; uint64_t e = (v >> 52) & 0x7FF, f = v & 0xFFFFFFFFFFFFFull;
    if (e == 0x7FF) return f ? ((f >> 51) ? 1u << 9 : 1u << 8) : (s ? 1u : 1u << 7);
    if (e == 0) return f ? (s ? 1u << 2 : 1u << 5) : (s ? 1u << 3 : 1u << 4);
    return s ? 1u << 1 : 1u << 6;
}
static float32_t F(uint64_t v) { float32_t r; r.v = (uint32_t)v; return r; }
static float64_t D(uint64_t v) { float64_t r; r.v = v; return r; }

static Out ref(int op, int dbl, int rm, uint64_t a, uint64_t b, uint64_t c) {
    softfloat_roundingMode = rm;
    softfloat_detectTininess = softfloat_tininess_afterRounding;
    softfloat_exceptionFlags = 0;
    uint64_t r = 0;
    if (!dbl) {
        uint32_t x = a, y = b, z = c;
        switch (op) {
            case F_ADD: r = f32_add(F(x), F(y)).v; break;
            case F_SUB: r = f32_sub(F(x), F(y)).v; break;
            case F_MUL: r = f32_mul(F(x), F(y)).v; break;
            case F_DIV: r = f32_div(F(x), F(y)).v; break;
            case F_SQRT: r = f32_sqrt(F(x)).v; break;
            case F_MADD: r = f32_mulAdd(F(x), F(y), F(z)).v; break;
            case F_MSUB: r = f32_mulAdd(F(x), F(y), F(z ^ S32)).v; break;
            case F_NMSUB: r = f32_mulAdd(F(x ^ S32), F(y), F(z)).v; break;
            case F_NMADD: r = f32_mulAdd(F(x ^ S32), F(y), F(z ^ S32)).v; break;
            case F_SGNJ: r = (x & ~S32) | (y & S32); break;
            case F_SGNJN: r = (x & ~S32) | (~y & S32); break;
            case F_SGNJX: r = x ^ (y & S32); break;
            case F_MIN: case F_MAX: {
                bool pick_a;
                if (op == F_MIN) pick_a = f32_lt_quiet(F(x), F(y)) || (f32_eq(F(x), F(y)) && (x & S32));
                else             pick_a = f32_lt_quiet(F(y), F(x)) || (f32_eq(F(y), F(x)) && (y & S32));
                if (nan32(x) && nan32(y)) r = 0x7FC00000u;
                else r = (pick_a || nan32(y)) ? x : y;
                break;
            }
            case F_EQ: r = f32_eq(F(x), F(y)); break;
            case F_LT: r = f32_lt(F(x), F(y)); break;
            case F_LE: r = f32_le(F(x), F(y)); break;
            case F_CLASS: r = cls32(x); break;
            case F_CVTW: r = (uint32_t)f32_to_i32(F(x), rm, true); break;
            case F_CVTWU: r = f32_to_ui32(F(x), rm, true); break;
            case F_CVTFW: r = i32_to_f32((int32_t)x).v; break;
            case F_CVTFWU: r = ui32_to_f32(x).v; break;
            case F_CVTFF: r = f32_to_f64(F(x)).v; break;
        }
    } else {
        uint64_t x = a, y = b, z = c;
        switch (op) {
            case F_ADD: r = f64_add(D(x), D(y)).v; break;
            case F_SUB: r = f64_sub(D(x), D(y)).v; break;
            case F_MUL: r = f64_mul(D(x), D(y)).v; break;
            case F_DIV: r = f64_div(D(x), D(y)).v; break;
            case F_SQRT: r = f64_sqrt(D(x)).v; break;
            case F_MADD: r = f64_mulAdd(D(x), D(y), D(z)).v; break;
            case F_MSUB: r = f64_mulAdd(D(x), D(y), D(z ^ S64)).v; break;
            case F_NMSUB: r = f64_mulAdd(D(x ^ S64), D(y), D(z)).v; break;
            case F_NMADD: r = f64_mulAdd(D(x ^ S64), D(y), D(z ^ S64)).v; break;
            case F_SGNJ: r = (x & ~S64) | (y & S64); break;
            case F_SGNJN: r = (x & ~S64) | (~y & S64); break;
            case F_SGNJX: r = x ^ (y & S64); break;
            case F_MIN: case F_MAX: {
                bool pick_a;
                if (op == F_MIN) pick_a = f64_lt_quiet(D(x), D(y)) || (f64_eq(D(x), D(y)) && (x & S64));
                else             pick_a = f64_lt_quiet(D(y), D(x)) || (f64_eq(D(y), D(x)) && (y & S64));
                if (nan64(x) && nan64(y)) r = 0x7FF8000000000000ull;
                else r = (pick_a || nan64(y)) ? x : y;
                break;
            }
            case F_EQ: r = f64_eq(D(x), D(y)); break;
            case F_LT: r = f64_lt(D(x), D(y)); break;
            case F_LE: r = f64_le(D(x), D(y)); break;
            case F_CLASS: r = cls64(x); break;
            case F_CVTW: r = (uint32_t)f64_to_i32(D(x), rm, true); break;
            case F_CVTWU: r = f64_to_ui32(D(x), rm, true); break;
            case F_CVTFW: r = i32_to_f64((int32_t)(uint32_t)x).v; break;
            case F_CVTFWU: r = ui32_to_f64((uint32_t)x).v; break;
            case F_CVTFF: r = f64_to_f32(D(x)).v; break;
        }
    }
    return Out{r, softfloat_exceptionFlags};
}

// the operand's width: the source format, or 32 bits for an integer
static bool src_dbl(int op, int dbl) { return (op == F_CVTFW || op == F_CVTFWU) ? false : dbl; }
static bool res_dbl(int op, int dbl) {
    if (op == F_CVTFF) return !dbl;
    if (op == F_EQ || op == F_LT || op == F_LE || op == F_CLASS || op == F_CVTW || op == F_CVTWU) return false;
    return dbl;
}

static uint64_t bad, checked;
static void check(int op, int dbl, int rm, uint64_t a, uint64_t b, uint64_t c, Out want) {
    Out got = dut(op, dbl, rm, a, b, c);
    uint64_t mask = res_dbl(op, dbl) ? ~0ull : 0xFFFFFFFFull;
    checked++;
    if ((got.v & mask) != (want.v & mask) || got.f != want.f || (got.v & ~mask)) {
        if (bad < 40)
            printf("MISMATCH %s.%c rm%d a=%016llx b=%016llx c=%016llx: got %016llx/%02x want %016llx/%02x\n",
                   opname[op], dbl ? 'd' : 's', rm, (unsigned long long)a, (unsigned long long)b,
                   (unsigned long long)c, (unsigned long long)got.v, got.f,
                   (unsigned long long)(want.v & mask), want.f);
        bad++;
    }
}

// ---- random operands, biased to the edges ----------------------------------------------
static std::mt19937_64 rng;
static uint64_t pick(bool d) {
    uint64_t r = rng();
    unsigned k = rng() % 16;
    int ebits = d ? 11 : 8, fbits = d ? 52 : 23;
    uint64_t emax = (1ull << ebits) - 1, fmask = (1ull << fbits) - 1;
    uint64_t s = rng() & 1, e, f = r & fmask;
    switch (k) {
        case 0: e = 0; f = 0; break;                                    // zero
        case 1: e = 0; break;                                           // subnormal
        case 2: e = 0; f = 1ull << (rng() % fbits); break;              // a lone subnormal bit
        case 3: e = emax; f = 0; break;                                 // infinity
        case 4: e = emax; if (!f) f = 1; break;                         // NaN (either kind)
        case 5: e = emax - 1 - rng() % 3; break;                        // near overflow
        case 6: e = 1 + rng() % 3; break;                               // near underflow
        case 7: e = (emax >> 1) + (rng() % 5) - 2; f = (rng() & 1) ? fmask : f & (rng() | rng()); break;
        case 8: e = (emax >> 1) + (rng() % 5) - 2; f = (rng() & 1) ? 0 : (f & ~(fmask >> (rng() % fbits))); break;
        default: e = 1 + rng() % (emax - 1);
    }
    return d ? (s << 63) | (e << 52) | f : (s << 31) | (e << 23) | f;
}
static uint64_t pick_int() {
    switch (rng() % 6) {
        case 0: return 0;
        case 1: return 0x80000000u;
        case 2: return 0x7FFFFFFFu;
        case 3: return 0xFFFFFFFFu;
        case 4: return (uint32_t)rng() >> (rng() % 32);
        default: return (uint32_t)rng();
    }
}

// ---- testfloat_gen's lines -----------------------------------------------------------
static int arity(int op) {
    switch (op) {
        case F_SQRT: case F_CVTW: case F_CVTWU: case F_CVTFW: case F_CVTFWU: case F_CVTFF: return 1;
        case F_MADD: return 3;
        default: return 2;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vrv_fpu;
    top->rst = 1; tick(); tick(); top->rst = 0; tick();
    std::string mode;
    int op = -1, dbl = 0, rm = 0;
    uint64_t n = 100000, seed = 1;
    for (int i = 1; i < argc; i++) {
        std::string s = argv[i];
        auto nxt = [&]() { return std::string(i + 1 < argc ? argv[++i] : ""); };
        if (s == "--tf") { mode = "tf"; std::string o = nxt(); for (int k = 0; k < F_N; k++) if (o == opname[k]) op = k; }
        else if (s == "--rand") { mode = "rand"; n = strtoull(nxt().c_str(), 0, 0); }
        else if (s == "--seed") seed = strtoull(nxt().c_str(), 0, 0);
        else if (s == "--dbl") dbl = atoi(nxt().c_str());
        else if (s == "--rm") rm = atoi(nxt().c_str());
    }
    if (mode == "tf") {
        if (op < 0) { fprintf(stderr, "unknown op\n"); return 2; }
        char line[512];
        while (fgets(line, sizeof line, stdin)) {
            uint64_t v[5] = {0};
            int k = 0;
            for (char *t = strtok(line, " \t\n"); t && k < 5; t = strtok(nullptr, " \t\n")) v[k++] = strtoull(t, 0, 16);
            int na = arity(op);
            if (k != na + 2) continue;
            uint64_t a = v[0], b = na > 1 ? v[1] : 0, c = na > 2 ? v[2] : 0;
            check(op, dbl, rm, a, b, c, Out{v[na], (unsigned)v[na + 1]});
        }
    } else if (mode == "rand") {
        rng.seed(seed);
        for (uint64_t i = 0; i < n; i++) {
            int o = rng() % F_N, d = rng() & 1, r = rng() % 5;
            bool sd = src_dbl(o, d);
            uint64_t a = (o == F_CVTFW || o == F_CVTFWU) ? pick_int() : pick(sd);
            uint64_t b = pick(sd), c = pick(sd);
            // near-cancellations: b (or c) close to a's negation
            if ((o == F_ADD || o == F_SUB) && (rng() % 4 == 0)) b = (a ^ (o == F_ADD ? (sd ? S64 : S32) : 0)) + (rng() % 5) - 2;
            if (o >= F_MADD && o <= F_NMADD && (rng() % 4 == 0)) {
                Out p = ref(F_MUL, d, r, a, b, 0);
                c = (p.v ^ ((o == F_MADD || o == F_NMADD) ? (sd ? S64 : S32) : 0)) + (rng() % 5) - 2;
            }
            if (!sd) { a &= (o == F_CVTFW || o == F_CVTFWU) ? 0xFFFFFFFFull : 0xFFFFFFFFull; b &= 0xFFFFFFFFull; c &= 0xFFFFFFFFull; }
            check(o, d, r, a, b, c, ref(o, d, r, a, b, c));
        }
    } else {
        fprintf(stderr, "usage: --tf OP --dbl D --rm R < vectors | --rand N [--seed S]\n");
        return 2;
    }
    printf("%llu checked, %llu mismatches, %llu clocks\n", (unsigned long long)checked,
           (unsigned long long)bad, (unsigned long long)clocks);
    if (getenv("FPU_LAT")) {
        for (int o = 0; o < F_N; o++)
            if (max_lat[o][0] || max_lat[o][1])
                printf("  %-7s max clocks  s %3u  d %3u\n", opname[o], max_lat[o][0], max_lat[o][1]);
    }
    delete top;
    return bad ? 1 : 0;
}
