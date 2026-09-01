// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// Verilated harness for the split I/D front and the late-cancel contract.
//
// sim/cpu65c02_main.cpp proves the core at one bus cycle per clock with cyc_en
// tied high.  This harness proves the three properties the L1 caches are going
// to lean on, none of which that model exercises:
//
//   1. LATE CANCEL.  cyc_en is decided fresh every clock, like an icache hit
//      signal: usually high, pulled low at random - sometimes in bursts shaped
//      like a miss latency.  A cancelled clock must consume NOTHING: to prove
//      it, din carries deliberate garbage on every cancelled clock, exactly the
//      wrong value a speculatively-read cache line would carry on a miss.  If
//      the core so much as breathes on a cancelled edge, the Klaus suites fail.
//
//   2. RETRY IDENTITY.  Across a cancelled clock the presented cycle -
//      addr, rw, dout, sync, cyc_is_i - must not change, or the retry would be
//      a different bus cycle than the one that was cancelled.
//
//   3. PREDICTION.  i_pred sampled at an advancing edge must equal the address
//      of the cycle that edge begins, whenever that cycle is program-stream.
//      That is the whole icache bet: the line read under i_pred is the line
//      the fetch wants.  Checked on every advancing edge of both suites, which
//      is ~163 million cycles of sequential flow, branches, jumps, returns and
//      interrupts entries.
//
// The classified views are checked as views (i_addr/d_addr/d_rw/d_dout against
// the legacy pins) and the classification for sanity: an opcode fetch is I, a
// write is D.
//
// The model is otherwise cpu65c02_main.cpp's: 64 KiB flat RAM, completion by
// the same opcode address fetched twice in a row.

#include "Vcpu65c02.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static unsigned char mem[65536];

static bool load_hex(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return false;
    char line[64];
    unsigned addr = 0;
    while (addr < 65536 && fgets(line, sizeof line, f)) {
        if (line[0] == '\n' || line[0] == '\0') continue;
        mem[addr++] = (unsigned char)strtoul(line, nullptr, 16);
    }
    fclose(f);
    return addr == 65536;
}

// xorshift32: cheap, seedable, and the same sequence on every machine, so a
// failing run is reproducible from its command line alone.
static unsigned rng_state = 1;
static unsigned rng() {
    unsigned x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    const char *hex = nullptr;
    unsigned start = 0x0400, success = 0;
    unsigned long long maxclk = 2000000000ull;
    unsigned stall = 0;      // per-mille chance a clock is cancelled
    unsigned burst = 0;      // per-mille chance a cancel starts a 2..17 clock burst
    unsigned seed  = 1;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("--hex=", 0) == 0)          hex = argv[i] + 6;
        else if (a.rfind("--start=", 0) == 0)   start = strtoul(argv[i] + 8, nullptr, 16);
        else if (a.rfind("--success=", 0) == 0) success = strtoul(argv[i] + 10, nullptr, 16);
        else if (a.rfind("--maxclk=", 0) == 0)  maxclk = strtoull(argv[i] + 9, nullptr, 10);
        else if (a.rfind("--stall=", 0) == 0)   stall = strtoul(argv[i] + 8, nullptr, 10);
        else if (a.rfind("--burst=", 0) == 0)   burst = strtoul(argv[i] + 8, nullptr, 10);
        else if (a.rfind("--seed=", 0) == 0)    seed = strtoul(argv[i] + 7, nullptr, 10);
    }
    if (!hex) { fprintf(stderr, "need --hex=\n"); return 2; }
    if (!load_hex(hex)) { fprintf(stderr, "could not load 64 KiB from %s\n", hex); return 2; }
    rng_state = seed ? seed : 1;

    mem[0xFFFC] = start & 0xFF;
    mem[0xFFFD] = (start >> 8) & 0xFF;

    printf("running %s  start $%04X  success trap $%04X  stall %u/1000  burst %u/1000  seed %u\n",
           hex, start, success, stall, burst, seed);

    Vcpu65c02 *dut = new Vcpu65c02;
    dut->cyc_en = 1;
    dut->irq_n = 1;
    dut->nmi_n = 1;
    dut->rst = 1;
    dut->i_din = dut->d_din = 0;

    unsigned long long clocks = 0, cycles = 0, instrs = 0, cancels = 0;
    unsigned long long i_cycles = 0, d_cycles = 0;
    unsigned last_fetch = 0xFFFFFFFF;
    unsigned pred = 0xFFFF;         // i_pred sampled at the last advancing edge
    bool pred_valid = false;        // false until the first advancing edge
    unsigned burst_left = 0;
    bool new_cycle = true;          // the presented cycle began at the last
                                    // edge; false while a cancel retries it
    int rc = 1;

    auto fail = [&](const char *what, unsigned got, unsigned want) {
        printf("FAIL: %s at clock %llu (cycle %llu): got $%04X want $%04X\n",
               what, clocks, cycles, got, want);
        printf("TRAP=contract\n");
    };

    // Reset rides plain full-speed cycles; the machinery under test starts
    // with the first real fetch.
    auto step_plain = [&]() {
        if (!dut->rw) mem[dut->addr] = dut->dout;
        dut->i_din = dut->d_din = mem[dut->addr];
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    };
    for (int i = 0; i < 4; i++) step_plain();
    dut->rst = 0;

    while (true) {
        // ---- the cycle now presented (began at the previous edge) ----------
        unsigned addr = dut->addr, rw = dut->rw, dout = dut->dout;
        unsigned syn = dut->sync, is_i = dut->cyc_is_i;

        // The views are the bus, reclassified - never a different bus.
        if (dut->i_addr != addr) { fail("i_addr != addr", dut->i_addr, addr); break; }
        if (dut->d_addr != addr) { fail("d_addr != addr", dut->d_addr, addr); break; }
        if (dut->d_rw != rw)     { fail("d_rw != rw", dut->d_rw, rw); break; }
        if (dut->d_dout != dout) { fail("d_dout != dout", dut->d_dout, dout); break; }
        // An opcode fetch is the program stream; a write never is.
        if (syn && !is_i)  { fail("sync cycle not classified I", addr, addr); break; }
        if (!rw && is_i)   { fail("write cycle classified I", addr, addr); break; }

        // Once per CYCLE, not per clock: a retried cycle already counted, and
        // a retried opcode fetch must not read as "same address twice in a
        // row" to the completion detector.
        if (new_cycle) {
            // The icache bet: the address of an I cycle is what i_pred said
            // at the edge that began it.
            if (is_i && pred_valid && addr != pred) { fail("i_pred missed", addr, pred); break; }

            if (syn) {
                instrs++;
                if (addr == last_fetch) {
                    printf("\n%s  trap $%04X%s   %llu cycles in %llu clocks (%llu cancelled), %llu instructions\n",
                           addr == success ? "PASS" : "FAIL", addr,
                           addr == success ? "  is the success trap" : "",
                           cycles, clocks, cancels, instrs);
                    printf("I/D: %llu / %llu cycles\n", i_cycles, d_cycles);
                    printf("TRAP=%04x\n", addr);
                    rc = (addr == success) ? 0 : 1;
                    break;
                }
                last_fetch = addr;
            }
            if (is_i) i_cycles++; else d_cycles++;
        }

        // ---- decide this clock's fate, like an icache hit line -------------
        bool cancel;
        if (burst_left) { cancel = true; burst_left--; }
        else {
            cancel = stall && (rng() % 1000) < stall;
            if (cancel && burst && (rng() % 1000) < burst) burst_left = 1 + (rng() % 16);
        }

        // A cancelled clock carries GARBAGE data: the value a speculative read
        // returns when the speculation was wrong.  The cancelled edge must not
        // look at it.  An advancing clock commits the write and serves the
        // true byte, both properties of the edge that ends the cycle.
        // The INACTIVE din port carries garbage on EVERY clock, cancelled or
        // not: cyc_is_i says which port this cycle consumes, and the other
        // port belongs to a front speculating about a different stream - the
        // independence the split ports exist for.
        dut->cyc_en = !cancel;
        if (cancel) {
            dut->i_din = rng() & 0xFF;
            dut->d_din = rng() & 0xFF;
        } else {
            if (!rw) mem[addr] = dout;
            if (dut->cyc_is_i) { dut->i_din = mem[addr]; dut->d_din = rng() & 0xFF; }
            else               { dut->d_din = mem[addr]; dut->i_din = rng() & 0xFF; }
        }
        dut->clk = 0; dut->eval();

        // i_pred is sampled only at an advancing edge, when din is true data -
        // the same discipline the icache will keep.
        if (!cancel) { pred = dut->i_pred; pred_valid = true; }

        dut->clk = 1; dut->eval();
        clocks++;

        if (cancel) {
            cancels++;
            // Retry identity: the cancelled cycle is re-presented unchanged.
            if (dut->addr != addr || dut->rw != rw || dut->dout != dout ||
                dut->sync != syn || dut->cyc_is_i != is_i) {
                fail("cycle changed across a cancel", dut->addr, addr);
                break;
            }
        } else {
            cycles++;
        }
        new_cycle = !cancel;

        if (dut->halted) {
            printf("FAIL: core executed STP at clock %llu\n", clocks);
            printf("TRAP=stp\n");
            break;
        }
        if (clocks >= maxclk) {
            printf("FAIL: no trap after %llu clocks (last fetch $%04X)\n", clocks, last_fetch);
            printf("TRAP=none\n");
            break;
        }
    }

    delete dut;
    return rc;
}
