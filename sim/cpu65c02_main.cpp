// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// Verilated harness for the Klaus Dormann functional suites.
//
// Why this exists alongside the iverilog testbenches.  The rest of this project
// simulates under iverilog, and that is the right default - it needs no C++ and
// the testbenches read as hardware.  It does not scale to this particular test:
// the 6502 functional suite is ~96 million bus cycles, which iverilog grinds
// through in roughly three quarters of an hour.  A core under active development
// gets this suite run dozens of times, and a 45-minute answer is not a debugging
// loop, it is a batch job.  Verilated, the same run takes a few seconds.
//
// The model is identical to sim/cpu65c02_tb.sv: 64 KiB of flat RAM, no I/O, and
// completion detected by the same opcode address being fetched twice in a row.

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

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    const char *hex = nullptr;
    unsigned start = 0x0400, success = 0, maxcyc = 400000000u;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("--hex=", 0) == 0)          hex = argv[i] + 6;
        else if (a.rfind("--start=", 0) == 0)   start = strtoul(argv[i] + 8, nullptr, 16);
        else if (a.rfind("--success=", 0) == 0) success = strtoul(argv[i] + 10, nullptr, 16);
        else if (a.rfind("--maxcyc=", 0) == 0)  maxcyc = strtoul(argv[i] + 9, nullptr, 10);
    }
    if (!hex) { fprintf(stderr, "need --hex=\n"); return 2; }
    if (!load_hex(hex)) { fprintf(stderr, "could not load 64 KiB from %s\n", hex); return 2; }

    // The images expect a monitor to set PC; the reset vector gets to the same
    // place through the front door.
    mem[0xFFFC] = start & 0xFF;
    mem[0xFFFD] = (start >> 8) & 0xFF;

    printf("running %s  start $%04X  success trap $%04X\n", hex, start, success);

    Vcpu65c02 *dut = new Vcpu65c02;
    dut->cyc_en = 1;
    dut->irq_n = 1;
    dut->nmi_n = 1;
    dut->rst = 1;
    dut->din = 0;

    unsigned long long cycles = 0, instrs = 0;
    unsigned last_fetch = 0xFFFFFFFF;
    int rc = 1;

    // One bus cycle, matching the core's contract exactly: addr/rw/dout are
    // registered and already valid for THIS cycle, a write commits during it,
    // and din is sampled by the edge that ends it.
    auto step = [&]() {
        if (!dut->rw) mem[dut->addr] = dut->dout;
        dut->din = mem[dut->addr];
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    };

    for (int i = 0; i < 4; i++) step();
    dut->rst = 0;

    while (true) {
        if (dut->sync) {
            instrs++;
            unsigned a = dut->addr;
            if (a == last_fetch) {
                printf("\n%s  trap $%04X%s   %llu cycles, %llu instructions\n",
                       a == success ? "PASS" : "FAIL", a,
                       a == success ? "  is the success trap" : "",
                       cycles, instrs);
                printf("TRAP=%04x\n", a);
                rc = (a == success) ? 0 : 1;
                break;
            }
            last_fetch = a;
        }

        step();
        cycles++;

        if (dut->halted) {
            printf("FAIL: core executed STP at cycle %llu\n", cycles);
            printf("TRAP=stp\n");
            break;
        }
        if (cycles >= maxcyc) {
            printf("FAIL: no trap after %llu cycles (last fetch $%04X)\n", cycles, last_fetch);
            printf("TRAP=none\n");
            break;
        }
    }

    delete dut;
    return rc;
}
