/* DBOPL, original against apple/rvvm/doom/dbopl_rv.c: the same register writes
   into both, every 256-sample chunk hashed (sim/run_dbopl_equiv.sh builds this
   twice, once with each, and compares the output line for line).
     phase 1: OPL2, Chip__GenerateBlock2 (DOOM's): random writes over every
              operator and channel register, key on and off, feedback, AM/FM,
              waveforms (wave select on), tremolo and vibrato depth ($BD; never
              rhythm mode - the C port aborts on it and DOOM never sets it)
     phase 2: OPL3 ($105), four-operator pairs ($104), Chip__GenerateBlock3
   With -DTIMING (the engine bench): a DOOM-like load instead - nine melodic
   voices held and released - and the clocks per chunk printed. */
#include <stdint.h>
#include <string.h>
#include "dbopl.h"

#ifdef __riscv
#include "rvvm.h"
static void out(const char *s) { unsigned n = 0; while (s[n]) n++; rvvm_write(1, s, n); }
#else
#include <stdio.h>
static void out(const char *s) { fputs(s, stdout); }
#endif
static void outx(uint32_t v) {
    char b[10]; for (int i = 0; i < 8; i++) b[i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
    b[8] = '\n'; b[9] = 0; out(b);
}

static uint32_t s = 0x12345678u;
static uint32_t rnd(void) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
static Chip chip;
static Bit32s buf[2 * 256];

static uint32_t hash(const Bit32s *p, int n) {
    uint32_t h = 2166136261u;
    for (int i = 0; i < n; i++) { h ^= (uint32_t)p[i]; h *= 16777619u; }
    return h;
}

/* an OPL2 register worth writing: an operator's, a channel's, or a global one */
static uint32_t reg2(void) {
    static const uint8_t op_off[18] = {0,1,2,3,4,5,8,9,10,11,12,13,16,17,18,19,20,21};
    switch (rnd() % 8) {
        case 0: return 0x20 + op_off[rnd() % 18];
        case 1: return 0x40 + op_off[rnd() % 18];
        case 2: return 0x60 + op_off[rnd() % 18];
        case 3: return 0x80 + op_off[rnd() % 18];
        case 4: return 0xE0 + op_off[rnd() % 18];
        case 5: return 0xA0 + rnd() % 9;
        case 6: return 0xB0 + rnd() % 9;
        default: return 0xC0 + rnd() % 9;
    }
}

#ifndef TIMING
int main(void) {
    DBOPL_InitTables();                                 /* (the driver's order: opl_rv.c) */
    Chip__Chip(&chip);
    Chip__Setup(&chip, 11027);
    Chip__WriteReg(&chip, 0x01, 0x20);                  /* wave select on */
    uint32_t all = 0;
    for (int c = 0; c < 3000; c++) {                    /* phase 1: OPL2 */
        int w = rnd() % 12;
        for (int k = 0; k < w; k++) Chip__WriteReg(&chip, reg2(), rnd() & 0xFF);
        if (rnd() % 40 == 0) Chip__WriteReg(&chip, 0xBD, rnd() & 0xDF);   /* tremolo/vibrato depth (never rhythm: the port aborts on it, DOOM never sets it) */
        if (rnd() % 60 == 0) Chip__WriteReg(&chip, 0x08, rnd() & 0xFF);
        Chip__GenerateBlock2(&chip, 256, buf);
        uint32_t h = hash(buf, 256);
        all = all * 31 + h;
        outx(h);
    }
    Chip__WriteReg(&chip, 0x105, 0x01);                 /* phase 2: OPL3 */
    for (int c = 0; c < 3000; c++) {
        int w = rnd() % 12;
        for (int k = 0; k < w; k++) {
            uint32_t r = reg2();
            if (rnd() & 1) r |= 0x100;                  /* the second register set */
            Chip__WriteReg(&chip, r, rnd() & 0xFF);
        }
        if (rnd() % 50 == 0) Chip__WriteReg(&chip, 0x104, rnd() & 0x3F);  /* four-operator pairs */
        if (rnd() % 40 == 0) Chip__WriteReg(&chip, 0xBD, rnd() & 0xDF);
        Chip__GenerateBlock3(&chip, 256, buf);
        uint32_t h = hash(buf, 512);
        all = all * 31 + h;
        outx(h);
    }
    out("all ");
    outx(all);
    return 0;
}
#else
/* DOOM-like: nine two-operator FM voices, notes held a while then released */
static void voice(int ch, int note_on, int fnum, int block) {
    Chip__WriteReg(&chip, 0xA0 + ch, fnum & 0xFF);
    Chip__WriteReg(&chip, 0xB0 + ch, (note_on ? 0x20 : 0) | (block << 2) | ((fnum >> 8) & 3));
}
int main(void) {
    static const uint8_t op1[9] = {0,1,2,8,9,10,16,17,18};
    DBOPL_InitTables();                                 /* (the driver's order: opl_rv.c) */
    Chip__Chip(&chip);
    Chip__Setup(&chip, 11027);
    Chip__WriteReg(&chip, 0x01, 0x20);
    for (int ch = 0; ch < 9; ch++) {                    /* a piano-ish patch: attack, decay, release */
        for (int k = 0; k < 2; k++) {
            int o = op1[ch] + 3 * k;
            Chip__WriteReg(&chip, 0x20 + o, k ? 0x01 : 0x21);
            Chip__WriteReg(&chip, 0x40 + o, k ? 0x00 : 0x18);
            Chip__WriteReg(&chip, 0x60 + o, 0xF2);
            Chip__WriteReg(&chip, 0x80 + o, 0x54);
            Chip__WriteReg(&chip, 0xE0 + o, ch & 1);
        }
        Chip__WriteReg(&chip, 0xC0 + ch, 0x0A);         /* feedback 5, FM */
    }
    const int chunks = 100;                             /* 2.3 s of music */
    uint32_t all = 0;
    unsigned long long t0 = rvvm_cycles();
    for (int c = 0; c < chunks; c++) {
        int ch = c % 9;
        voice(ch, (c / 9) & 1 ? 0 : 1, 0x200 + 37 * ch + 5 * c, 3 + (c & 1));
        Chip__GenerateBlock2(&chip, 256, buf);
        all = all * 31 + hash(buf, 256);
    }
    unsigned long long t1 = rvvm_cycles();
    out("clocks per chunk ");
    outx((uint32_t)((t1 - t0) / chunks));
    out("all ");
    outx(all);
    return 0;
}
#endif
