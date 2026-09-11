// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// cpu65816 against SingleStepTests/65816, one instruction at a time.
//
// Every test in the suite is one instruction: the full register state before
// and after, the bytes it touches, and the bus cycle by cycle - address, data
// and the VDA/VPA/VPB/RWB/E/M/X/MLB lines.  This harness puts the core at an
// opcode fetch with the initial state poked straight into its registers, runs
// it until the next opcode fetch, and compares:
//
//   - every cycle's address (on cycles the suite marks VDA or VPA - an
//     internal cycle's address is not architectural, is not compared, and
//     THIS CORE'S IS NOT THE REFERENCE'S: docs/GS.md rung 3e),
//     direction, and data (dout on writes, the byte the model handed on reads)
//   - VDA/VPA/VPB every cycle, by default, because the memory model below
//     uses VDA as its write enable the way a real system does
//   - that every address the core writes is one the reference writes
//   - the cycle COUNT, by where the next fetch lands
//   - the final registers, and every byte the suite lists afterwards
//
// The record format is sim/cpu816_tests.py's.  A sync cycle is the previous
// instruction's trailing slot, so the core is parked there by setting uc_q to
// the FETCH word (the filler line of the hex, every undefined opcode's slot)
// with use_dec clear - the only pipeline state a fetch cycle depends on.
//
// WAI and STP park: the suite ends those with a null "--------" record, and
// the check stops one cycle short with no fetch expected.
//
// THE SPLIT FRONT'S CONTRACT (docs/GS.md rung 6), sim/cpu_predict_main.cpp's
// four properties, checked on the same run:
//
//   1. LATE CANCEL.  cyc_en is pulled low at random (--cancel=PERCENT, in
//      bursts), and on every cancelled clock BOTH din ports carry garbage.
//      A cancelled edge must consume nothing: if the core breathes on one,
//      the suite fails.
//   2. RETRY IDENTITY.  Across a cancelled clock the presented cycle - addr,
//      rw, dout, sync, vda, vpa, vpb, cyc_is_i, pc_addr - must not change.
//   3. THE I VIEW.  cyc_is_i is VPA, and on every such cycle addr equals
//      pc_addr.  The byte is driven on i_din alone; d_din carries garbage.
//      On a data cycle the reverse; on an internal cycle both are garbage.
//   4. DATA PREDICTION.  d_pred sampled at an advancing edge with d_pred_v
//      set must equal the address of the cycle that edge begins, d_pred_rw
//      its direction, and that cycle must be VDA-and-not-VPA; the bank
//      class must agree with the bank byte (ZERO: $00; DBR: the data bank
//      register).  Coverage is COUNTED: a data cycle d_pred_v sat out is
//      reported, and the run expects none.

#include "Vcpu65816.h"
#include "Vcpu65816___024root.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>
#include <map>
#include <set>

struct Regs { unsigned pc, s, p, a, x, y, dbr, d, pbr, e; };
struct Cyc  { unsigned addr, val, flags; };
struct Test {
    unsigned opcode, efile;
    Regs ini, fin;
    std::vector<std::pair<unsigned, unsigned>> ram_i, ram_f;
    std::vector<Cyc> cyc;
};

static const unsigned char *rp;
static const unsigned char *rend;
static unsigned rd8()  { return *rp++; }
static unsigned rd16() { unsigned v = rp[0] | (rp[1] << 8); rp += 2; return v; }
static unsigned rd32() { unsigned v = rp[0] | (rp[1] << 8) | (rp[2] << 16) | ((unsigned)rp[3] << 24); rp += 4; return v; }
static Regs rdregs() {
    Regs r; r.pc = rd16(); r.s = rd16(); r.p = rd8(); r.a = rd16(); r.x = rd16();
    r.y = rd16(); r.dbr = rd8(); r.d = rd16(); r.pbr = rd8(); r.e = rd8(); return r;
}
static void rdram(std::vector<std::pair<unsigned, unsigned>> &v) {
    unsigned n = rd16(); v.resize(n);
    for (unsigned i = 0; i < n; i++) { unsigned a = rd32(); unsigned b = rd8(); v[i] = {a, b}; }
}
static bool rdtest(Test &t) {
    if (rp >= rend) return false;
    t.opcode = rd8(); t.efile = rd8();
    t.ini = rdregs(); rdram(t.ram_i); t.fin = rdregs(); rdram(t.ram_f);
    unsigned n = rd16(); t.cyc.resize(n);
    for (unsigned i = 0; i < n; i++) { t.cyc[i].addr = rd32(); t.cyc[i].val = rd16(); t.cyc[i].flags = rd8(); }
    return true;
}

static std::vector<unsigned> fetch_word;   // the FETCH microinstruction, 32-bit words

static bool load_fetch_word(const char *hex) {
    FILE *f = fopen(hex, "r"); if (!f) return false;
    char line[128], last[128] = "";
    while (fgets(line, sizeof line, f)) if (line[0] != '\n') strcpy(last, line);
    fclose(f);
    // hex string -> little-endian 32-bit words
    std::string s(last); while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
    fetch_word.assign(3, 0);
    unsigned bit = 0;
    for (int i = (int)s.size() - 1; i >= 0; i--) {
        unsigned nib = (unsigned)strtoul(std::string(1, s[i]).c_str(), nullptr, 16);
        fetch_word[bit / 32] |= nib << (bit % 32);
        bit += 4;
    }
    return true;
}

static Vcpu65816 *dut;
static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

// xorshift32: cheap, seedable, the same sequence on every machine.
static unsigned rng_state = 1;
static unsigned rng() {
    unsigned x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

// The byte on the port this cycle's stream selects, garbage on the other -
// and garbage on both when told to (a cancelled clock, an internal cycle).
static void drive_din(unsigned byte, bool garbage_all) {
    unsigned g1 = rng() & 0xFF, g2 = rng() & 0xFF;
    if (garbage_all) { dut->i_din = g1; dut->d_din = g2; return; }
    if (dut->vpa) { dut->i_din = byte; dut->d_din = g1; }
    else          { dut->i_din = g1;   dut->d_din = byte; }
}

struct Presented { unsigned addr, rw, dout, sync, vda, vpa, vpb, cyc_is_i, pc_addr; };
static Presented presented() {
    Presented p;
    p.addr = dut->addr; p.rw = dut->rw; p.dout = dut->dout; p.sync = dut->sync;
    p.vda = dut->vda; p.vpa = dut->vpa; p.vpb = dut->vpb;
    p.cyc_is_i = dut->cyc_is_i; p.pc_addr = dut->pc_addr;
    return p;
}
static bool same(const Presented &a, const Presented &b) {
    return a.addr == b.addr && a.rw == b.rw && a.dout == b.dout && a.sync == b.sync &&
           a.vda == b.vda && a.vpa == b.vpa && a.vpb == b.vpb &&
           a.cyc_is_i == b.cyc_is_i && a.pc_addr == b.pc_addr;
}

static void poke(const Regs &r) {
    auto *R = dut->rootp;
    R->cpu65816__DOT__a = r.a; R->cpu65816__DOT__x = r.x; R->cpu65816__DOT__y = r.y;
    // The suite's S in emulation mode carries an arbitrary high byte in the
    // initial state and reads $01xx afterwards; the core keeps it in page one.
    R->cpu65816__DOT__s = r.e ? (0x0100 | (r.s & 0xFF)) : r.s; R->cpu65816__DOT__d = r.d; R->cpu65816__DOT__pc = r.pc;
    R->cpu65816__DOT__dbr = r.dbr; R->cpu65816__DOT__pbr = r.pbr;
    R->cpu65816__DOT__f_n = (r.p >> 7) & 1; R->cpu65816__DOT__f_v = (r.p >> 6) & 1;
    R->cpu65816__DOT__f_m = r.e ? 1 : (r.p >> 5) & 1;
    R->cpu65816__DOT__f_x = r.e ? 1 : (r.p >> 4) & 1;
    R->cpu65816__DOT__f_d = (r.p >> 3) & 1; R->cpu65816__DOT__f_i = (r.p >> 2) & 1;
    R->cpu65816__DOT__f_z = (r.p >> 1) & 1; R->cpu65816__DOT__f_c = r.p & 1;
    R->cpu65816__DOT__f_e = r.e;
    R->cpu65816__DOT__in_rst = 0; R->cpu65816__DOT__hlt = 0;
    R->cpu65816__DOT__nmi_pend = 0; R->cpu65816__DOT__int_brk = 0; R->cpu65816__DOT__int_nmi = 0;
    R->cpu65816__DOT__use_dec = 0;
    R->cpu65816__DOT__agu_c = 0; R->cpu65816__DOT__agu_hc = 0;
    for (int i = 0; i < 3; i++) R->cpu65816__DOT__uc_q[i] = fetch_word[i];
}

static unsigned peek_p() {
    auto *R = dut->rootp;
    return (R->cpu65816__DOT__f_n << 7) | (R->cpu65816__DOT__f_v << 6) | (R->cpu65816__DOT__f_m << 5) |
           (R->cpu65816__DOT__f_x << 4) | (R->cpu65816__DOT__f_d << 3) | (R->cpu65816__DOT__f_i << 2) |
           (R->cpu65816__DOT__f_z << 1) | R->cpu65816__DOT__f_c;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *tests = nullptr, *hex = nullptr;
    unsigned detail = 3;        // failures printed in full per opcode/mode
    // VDA/VPA/VPB are compared BY DEFAULT.  They are not decoration: the
    // harness's memory below is written only on a cycle the core marks VDA,
    // which is how a real 65816 system enables a write, so the flags have to
    // be held to the reference for that to mean anything.  --no-flags is for
    // bringing a new opcode up, not for a gate.
    bool cmpflags = true;       // compare the core's vda/vpa/vpb (needs the ports)
    unsigned cancel = 25;       // percent of clocks cancelled (in bursts)
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("--tests=", 0) == 0) tests = argv[i] + 8;
        else if (a.rfind("--hex=", 0) == 0) hex = argv[i] + 6;
        else if (a.rfind("--detail=", 0) == 0) detail = strtoul(argv[i] + 9, nullptr, 10);
        else if (a.rfind("--cancel=", 0) == 0) cancel = strtoul(argv[i] + 9, nullptr, 10);
        else if (a.rfind("--seed=", 0) == 0) rng_state = strtoul(argv[i] + 7, nullptr, 10) | 1;
        else if (a == "--flags") cmpflags = true;
        else if (a == "--no-flags") cmpflags = false;
    }
    if (!tests || !hex) { fprintf(stderr, "need --tests= and --hex=\n"); return 2; }
    if (!load_fetch_word(hex)) { fprintf(stderr, "cannot read %s\n", hex); return 2; }

    FILE *f = fopen(tests, "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", tests); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> buf(len); if (fread(buf.data(), 1, len, f) != (size_t)len) return 2;
    fclose(f);
    rp = buf.data(); rend = rp + len;

    dut = new Vcpu65816;
    dut->irq_n = 1; dut->nmi_n = 1; dut->cyc_en = 1; dut->i_din = 0; dut->d_din = 0;

    std::map<unsigned, unsigned> pass, fail, shown;   // key = opcode*2 + efile
    unsigned long long total = 0, failed = 0, cycles_run = 0;
    // The contract's books: cancelled clocks, data cycles predicted and not.
    unsigned long long cancelled = 0, data_cycles = 0, data_predicted = 0, data_unpredicted = 0;
    std::map<unsigned, unsigned> unpred_by_op;
    Test t;
    while (rdtest(t)) {
        total++;
        unsigned key = t.opcode * 2 + t.efile;
        std::unordered_map<unsigned, unsigned> mem;
        for (auto &e : t.ram_i) mem[e.first] = e.second;

        dut->rst = 1; tick(); tick(); dut->rst = 0;
        poke(t.ini);
        dut->eval();

        std::string err;
        char m[256];
        // Every byte the core writes must be a byte the reference wrote.  The
        // final-memory check cannot say this on its own: the suite lists only
        // the addresses IT touched, so a write anywhere else lands in no
        // list and is never compared.
        std::set<unsigned> core_wrote, ref_wrote;
        bool parked = !t.cyc.empty() && t.cyc.back().flags == 0 && t.cyc.back().addr == 0xFFFFFFFFu;
        // A block move's test is cut at 100 cycles with the state as of that
        // point, so it too ends by count rather than by the next fetch.
        bool bycount = parked || t.opcode == 0x44 || t.opcode == 0x54;
        unsigned ncyc = parked ? t.cyc.size() - 1 : t.cyc.size();
        unsigned k = 0;
        // The prediction sampled at the last advancing edge, for the cycle
        // that edge began.
        bool pred_v = false; unsigned pred_addr = 0, pred_rw = 1, pred_bcls = 0;
        for (;;) {
            // LATE CANCEL: a burst of cancelled clocks, garbage on both din
            // ports, and the presented cycle held across every one of them.
            if (cancel && (rng() % 100) < cancel) {
                unsigned burst = 1 + (rng() % 4);
                Presented before = presented();
                for (unsigned b = 0; b < burst; b++) {
                    dut->cyc_en = 0;
                    drive_din(0, true);
                    dut->eval();
                    tick(); cancelled++;
                    dut->cyc_en = 1;
                    drive_din(0, true);
                    dut->eval();
                    Presented after = presented();
                    if (!same(before, after)) {
                        snprintf(m, sizeof m, "cycle %u: presented cycle changed across a cancelled clock (addr %06x->%06x rw %u->%u sync %u->%u)\n",
                                 k, before.addr, after.addr, before.rw, after.rw, before.sync, after.sync);
                        err += m; break;
                    }
                }
            }
            unsigned addr = dut->addr, rw = dut->rw;
            unsigned din = 0;
            if (rw) { auto it = mem.find(addr); din = (it == mem.end()) ? 0 : it->second; }
            drive_din(din, !dut->vda && !dut->vpa);
            dut->eval();
            unsigned dout = dut->dout, sync = dut->sync;
            // THE I VIEW, and the prediction made for this cycle.
            if ((unsigned)dut->cyc_is_i != (unsigned)dut->vpa) { snprintf(m, sizeof m, "cycle %u: cyc_is_i %u but vpa %u\n", k, (unsigned)dut->cyc_is_i, (unsigned)dut->vpa); err += m; }
            if (dut->cyc_is_i && dut->pc_addr != addr) { snprintf(m, sizeof m, "cycle %u: I cycle at %06x but pc_addr %06x\n", k, addr, (unsigned)dut->pc_addr); err += m; }
            {
                unsigned pf = dut->p_flags;
                if (pf != peek_p()) { snprintf(m, sizeof m, "cycle %u: p_flags %02x but P %02x\n", k, pf, peek_p()); err += m; }
            }
            bool is_data = dut->vda && !dut->vpa;
            if (k > 0) {
                if (pred_v) {
                    if (!is_data) { snprintf(m, sizeof m, "cycle %u: predicted a data cycle, got vda %u vpa %u\n", k, (unsigned)dut->vda, (unsigned)dut->vpa); err += m; }
                    else {
                        if (pred_addr != addr) { snprintf(m, sizeof m, "cycle %u: d_pred %06x but addr %06x\n", k, pred_addr, addr); err += m; }
                        if (pred_rw != rw) { snprintf(m, sizeof m, "cycle %u: d_pred_rw %u but rw %u\n", k, pred_rw, rw); err += m; }
                        unsigned bank = addr >> 16, dbr = dut->rootp->cpu65816__DOT__dbr;
                        if (pred_bcls == 0 && bank != 0) { snprintf(m, sizeof m, "cycle %u: bank class ZERO but bank %02x\n", k, bank); err += m; }
                        if (pred_bcls == 1 && bank != dbr) { snprintf(m, sizeof m, "cycle %u: bank class DBR but bank %02x, dbr %02x\n", k, bank, dbr); err += m; }
                        if (pred_bcls > 2) { snprintf(m, sizeof m, "cycle %u: bank class %u\n", k, pred_bcls); err += m; }
                    }
                }
                if (is_data) { data_cycles++; if (pred_v) data_predicted++; else { data_unpredicted++; unpred_by_op[t.opcode]++; } }
            }
            // The next fetch ends the instruction - once the expected count is
            // reached.  A block move re-fetches its own opcode per byte, and
            // those syncs are inside the test.
            if (k > 0 && sync && k >= ncyc && !bycount) break;
            if (k >= ncyc + 2) { err += "runaway: no fetch after " + std::to_string(k) + " cycles\n"; break; }
            bool access = false;
            if (k < ncyc) {
                const Cyc &c = t.cyc[k];
                access = (c.flags & 3) != 0;
                if (!((c.flags >> 3) & 1) && access) ref_wrote.insert(c.addr);
                unsigned want_rw = (c.flags >> 3) & 1;
                if (k == 0 && !sync) { snprintf(m, sizeof m, "cycle 0: no sync\n"); err += m; }
                if (rw != want_rw) { snprintf(m, sizeof m, "cycle %u: rw %u want %u\n", k, rw, want_rw); err += m; }
                if (access && addr != c.addr) { snprintf(m, sizeof m, "cycle %u: addr %06x want %06x\n", k, addr, c.addr); err += m; }
                if (access && !rw && c.val != 0xFFFF && dout != c.val) { snprintf(m, sizeof m, "cycle %u: wrote %02x want %02x\n", k, dout, c.val); err += m; }
                if (access && rw && c.val != 0xFFFF && addr == c.addr && din != c.val) { snprintf(m, sizeof m, "cycle %u: read %02x want %02x (model)\n", k, din, c.val); err += m; }
                if (cmpflags) {
                    unsigned got = dut->vda | (dut->vpa << 1) | (dut->vpb << 2);
                    if (got != (c.flags & 7)) { snprintf(m, sizeof m, "cycle %u: vda/vpa/vpb %u want %u\n", k, got, c.flags & 7); err += m; }
                }
            }
            // AN INTERNAL CYCLE CHANGES NOTHING.  The part drives R/W low
            // through the internal cycle of a read-modify-write - the 6502's
            // dummy write - with VDA low, so no decoder ever sees it, and
            // the address on the pins is whatever the last address step left
            // there.  Writing it into this model made the harness a machine
            // that does not exist, and hid the core's dp+1 there for
            // 981,610 tests (docs/GS.md rung 3e).
            if (!rw && dut->vda) { mem[addr] = dout; core_wrote.insert(addr); }
            // The prediction for the cycle this edge begins.
            pred_v = dut->d_pred_v; pred_addr = dut->d_pred; pred_rw = dut->d_pred_rw; pred_bcls = dut->d_pred_bcls;
            tick(); cycles_run++;
            k++;
            if (bycount && k >= ncyc) break;
        }
        if (k != ncyc && err.empty()) { snprintf(m, sizeof m, "cycle count %u want %u\n", k, ncyc); err += m; }
        else if (k != ncyc) { snprintf(m, sizeof m, "cycle count %u want %u\n", k, ncyc); err += m; }

        auto *R = dut->rootp;
        Regs g; g.pc = R->cpu65816__DOT__pc; g.s = R->cpu65816__DOT__s; g.p = peek_p();
        g.a = R->cpu65816__DOT__a; g.x = R->cpu65816__DOT__x; g.y = R->cpu65816__DOT__y;
        g.dbr = R->cpu65816__DOT__dbr; g.d = R->cpu65816__DOT__d; g.pbr = R->cpu65816__DOT__pbr;
        g.e = R->cpu65816__DOT__f_e;
        const Regs &w = t.fin;
        if (!parked) {
            if (g.pc != w.pc) { snprintf(m, sizeof m, "final pc %04x want %04x\n", g.pc, w.pc); err += m; }
            if (g.pbr != w.pbr) { snprintf(m, sizeof m, "final pbr %02x want %02x\n", g.pbr, w.pbr); err += m; }
        }
        if (g.s != w.s) { snprintf(m, sizeof m, "final s %04x want %04x\n", g.s, w.s); err += m; }
        if (g.p != w.p) { snprintf(m, sizeof m, "final p %02x want %02x\n", g.p, w.p); err += m; }
        if (g.a != w.a) { snprintf(m, sizeof m, "final a %04x want %04x\n", g.a, w.a); err += m; }
        if (g.x != w.x) { snprintf(m, sizeof m, "final x %04x want %04x\n", g.x, w.x); err += m; }
        if (g.y != w.y) { snprintf(m, sizeof m, "final y %04x want %04x\n", g.y, w.y); err += m; }
        if (g.dbr != w.dbr) { snprintf(m, sizeof m, "final dbr %02x want %02x\n", g.dbr, w.dbr); err += m; }
        if (g.d != w.d) { snprintf(m, sizeof m, "final d %04x want %04x\n", g.d, w.d); err += m; }
        if (g.e != w.e) { snprintf(m, sizeof m, "final e %u want %u\n", g.e, w.e); err += m; }
        for (unsigned a : core_wrote)
            if (!ref_wrote.count(a)) {
                snprintf(m, sizeof m, "wrote %06x, which the reference never writes\n", a); err += m;
            }
        for (auto &e : t.ram_f) {
            auto it = mem.find(e.first);
            unsigned have = (it == mem.end()) ? 0 : it->second;
            if (have != e.second) { snprintf(m, sizeof m, "final mem %06x = %02x want %02x\n", e.first, have, e.second); err += m; }
        }

        if (err.empty()) { pass[key]++; continue; }
        fail[key]++; failed++;
        if (shown[key]++ < detail) {
            printf("FAIL $%02X %s #%u: pc=%02x/%04x s=%04x p=%02x a=%04x x=%04x y=%04x dbr=%02x d=%04x e=%u\n",
                   t.opcode, t.efile ? "e" : "n", pass[key] + fail[key], t.ini.pbr, t.ini.pc, t.ini.s,
                   t.ini.p, t.ini.a, t.ini.x, t.ini.y, t.ini.dbr, t.ini.d, t.ini.e);
            printf("  expected:");
            for (auto &c : t.cyc) {
                if (c.addr == 0xFFFFFFFFu) printf(" [-,-,%c%c%c%c]", (c.flags&1)?'d':'-', (c.flags&2)?'p':'-', (c.flags&4)?'v':'-', (c.flags&8)?'r':'w');
                else if (c.val == 0xFFFF) printf(" [%06x,-,%c%c%c%c]", c.addr, (c.flags&1)?'d':'-', (c.flags&2)?'p':'-', (c.flags&4)?'v':'-', (c.flags&8)?'r':'w');
                else printf(" [%06x,%02x,%c%c%c%c]", c.addr, c.val, (c.flags&1)?'d':'-', (c.flags&2)?'p':'-', (c.flags&4)?'v':'-', (c.flags&8)?'r':'w');
            }
            printf("\n  final: pc=%02x/%04x s=%04x p=%02x a=%04x x=%04x y=%04x dbr=%02x d=%04x e=%u\n",
                   w.pbr, w.pc, w.s, w.p, w.a, w.x, w.y, w.dbr, w.d, w.e);
            printf("%s", err.c_str());
        }
    }

    printf("== per opcode (fail/total), failures only:\n");
    unsigned failing_keys = 0;
    for (auto &kv : fail) {
        unsigned key = kv.first;
        printf("  $%02X %s: %u/%u\n", key >> 1, (key & 1) ? "e" : "n", kv.second, kv.second + pass[key]);
        failing_keys++;
    }
    printf("%llu tests, %llu failed, %u opcode/mode groups failing, %llu cycles\n",
           total, failed, failing_keys, cycles_run);
    printf("contract: %llu cancelled clocks (%u%%), %llu data cycles, %llu predicted, %llu unpredicted\n",
           cancelled, cancel, data_cycles, data_predicted, data_unpredicted);
    if (data_unpredicted) {
        printf("  unpredicted data cycles by opcode:");
        for (auto &kv : unpred_by_op) printf(" $%02X:%u", kv.first, kv.second);
        printf("\n");
    }
    printf(failed ? "FAIL\n" : "PASS\n");
    delete dut;
    return failed ? 1 : 0;
}
