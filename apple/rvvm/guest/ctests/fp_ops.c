/* Every F and D instruction on edge-biased operands, in every rounding mode,
   with the flags read back: run on the engine in lockstep with the reference
   model (sim/rv_ref.h on SoftFloat), which judges every retire - so the
   checksum printed is for eyes only (sim/run_rvvm_tests.sh). */
#include "rvvm.h"

typedef unsigned long long u64;
typedef unsigned u32;

static u64 s = 0x9E3779B97F4A7C15ull;
static u64 rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }

/* a double or single bit pattern: zeros, subnormals, infinities, NaNs of both
   kinds, the extremes, round numbers, anything */
static u64 pick(int d) {
    u64 r = rnd();
    int eb = d ? 11 : 8, fb = d ? 52 : 23;
    u64 emax = (1ull << eb) - 1, fm = (1ull << fb) - 1, sg = r >> 63, e, f = r & fm;
    switch (rnd() % 14) {
        case 0: e = 0; f = 0; break;
        case 1: e = 0; break;
        case 2: e = emax; f = 0; break;
        case 3: e = emax; if (!f) f = 1; break;
        case 4: e = emax - 1; break;
        case 5: e = 1; break;
        case 6: e = (emax >> 1) + rnd() % 8 - 4; f &= ~(fm >> (rnd() % fb)); break;
        case 7: e = (emax >> 1) + rnd() % 8 - 4; f |= fm >> (rnd() % fb); break;
        default: e = 1 + rnd() % (emax - 1);
    }
    return d ? (sg << 63) | (e << 52) | f : (sg << 31) | (e << 23) | f;
}

static u64 acc = 0xCBF29CE484222325ull;
static void mix(u64 v) { acc = (acc ^ v) * 0x100000001B3ull; }

static inline double D(u64 v) { union { u64 u; double d; } x; x.u = v; return x.d; }
static inline u64 UD(double v) { union { u64 u; double d; } x; x.d = v; return x.u; }
static inline float F(u32 v) { union { u32 u; float f; } x; x.u = v; return x.f; }
static inline u32 UF(float v) { union { u32 u; float f; } x; x.f = v; return x.u; }
static inline void set_rm(u32 r) { __asm__ volatile("fsrm %0" :: "r"(r) : "memory"); }
static inline u32 flags(void) { u32 f; __asm__ volatile("frflags %0" : "=r"(f) :: "memory"); return f; }
static inline void clr(void) { __asm__ volatile("fsflags zero" ::: "memory"); }

static volatile u64 va, vb, vc;
static volatile u32 wa, wb, wc;
static volatile int vi;

int main(void) {
    for (int i = 0; i < 1500; i++) {
        set_rm(rnd() % 5);
        clr();
        va = pick(1); vb = pick(1); vc = pick(1);
        if (rnd() % 4 == 0) vb = va ^ (rnd() & 1ull ? 0x8000000000000000ull : 0) ^ (rnd() % 3);
        double a = D(va), b = D(vb), c = D(vc);
        mix(UD(a + b)); mix(UD(a - b)); mix(UD(a * b)); mix(UD(a / b));
        mix(UD(__builtin_sqrt(a)));
        mix(UD(__builtin_fma(a, b, c))); mix(UD(__builtin_fma(a, b, -c)));
        mix(UD(-__builtin_fma(a, b, c))); mix(UD(__builtin_fma(-a, b, c)));
        mix(UD(__builtin_fmin(a, b))); mix(UD(__builtin_fmax(a, b)));
        mix(UD(__builtin_copysign(a, b))); mix(UD(-a)); mix(UD(__builtin_fabs(b)));
        mix(a < b); mix(a <= b); mix(a == b);
        mix(__builtin_isinf(a)); mix(__builtin_isnan(b)); mix(__builtin_issignaling(c));
        mix((u32)__builtin_lrint(a)); mix((u32)(int)b); mix((u32)(unsigned)c);
        vi = (int)rnd();
        mix(UD((double)vi)); mix(UD((double)(unsigned)vi));
        mix(UF((float)a)); mix(flags());

        clr();
        wa = (u32)pick(0); wb = (u32)pick(0); wc = (u32)pick(0);
        if (rnd() % 4 == 0) wb = wa ^ (rnd() & 1 ? 0x80000000u : 0) ^ (u32)(rnd() % 3);
        float x = F(wa), y = F(wb), z = F(wc);
        mix(UF(x + y)); mix(UF(x - y)); mix(UF(x * y)); mix(UF(x / y));
        mix(UF(__builtin_sqrtf(x)));
        mix(UF(__builtin_fmaf(x, y, z))); mix(UF(__builtin_fmaf(x, y, -z)));
        mix(UF(-__builtin_fmaf(x, y, z))); mix(UF(__builtin_fmaf(-x, y, z)));
        mix(UF(__builtin_fminf(x, y))); mix(UF(__builtin_fmaxf(x, y)));
        mix(UF(__builtin_copysignf(x, y))); mix(UF(-x)); mix(UF(__builtin_fabsf(y)));
        mix(x < y); mix(x <= y); mix(x == y);
        mix(__builtin_isinf(x)); mix(__builtin_isnan(y)); mix(__builtin_issignaling(z));
        mix((u32)__builtin_lrintf(x)); mix((u32)(int)y); mix((u32)(unsigned)z);
        mix(UF((float)vi)); mix(UF((float)(unsigned)vi));
        mix(UD((double)x)); mix(flags());
    }
    char buf[20];
    const char *hx = "0123456789abcdef";
    for (int k = 0; k < 16; k++) buf[k] = hx[(acc >> (60 - 4 * k)) & 15];
    buf[16] = '\n';
    rvvm_write(1, "fp_ops checksum ", 16);
    rvvm_write(1, buf, 17);
    return 0;
}
