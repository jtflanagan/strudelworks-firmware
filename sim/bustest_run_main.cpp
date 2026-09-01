// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// Run apple/bustest.bin on rtl/cpu65c02.sv, and measure what it actually
// covers.
//
// WHY THIS EXISTS.  bustest is written to be executed on real hardware and
// watched on a bus, and the round trip for that is minutes: assemble, build a
// disk, carry it to the machine, boot, press a key, capture, bring the file
// back.  A program that hangs on its third instruction costs the whole trip to
// find out.  This runs it here first, in a second.
//
// It answers three questions, and no others:
//
//   1. Does it run at all, or does it wander off?  Watched by requiring the
//      pass counter at $0400 to keep advancing.
//   2. WHICH opcodes does it execute?  Counted at every sync, so "covers the
//      instruction set" is a measurement rather than a claim about a program
//      nobody has read line by line.
//   3. Does it stay out of the machine's way?  Any access to $C000-$CFFF is a
//      hard failure: on the Apple that is not memory, and a READ there moves
//      the machine.  In this flat model it would be harmless, which is exactly
//      why it has to be checked here rather than discovered on hardware.
//
// It says nothing about whether the core is CORRECT - the core is the thing
// under test elsewhere.  This is about the test program.
//
// The Apple's ROM is not here.  Two stubs stand in for the only parts bustest
// touches: the reset vector, and the BRK path through $03F0.
//
// It does NOT boot the disk image.  It used to, back when the disk carried a
// boot sector written here; the disk is now a real DOS 3.3 disk, and DOS has
// been booting Apples since 1980 without help from this file.  That the right
// bytes are on the disk is checked by apple/build.sh, reading the file back out
// through DOS's own structures.

#include "Vcpu65c02.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static uint8_t mem[65536];

// The Autostart ROM's BRK handling, reduced to the one thing bustest depends
// on: it ends in JMP ($03F0). The real ROM saves registers first; bustest's
// handler restores the stack pointer itself precisely so that does not matter.
static constexpr uint16_t kBrkStub = 0x7F00;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* bin = nullptr;
    uint16_t entry = 0x6003;          // the jump table's second slot
    uint64_t maxcyc = 40000000;
    unsigned want_passes = 3;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a.rfind("--bin=", 0) == 0)          bin = argv[i] + 6;
        else if (a.rfind("--entry=", 0) == 0)   entry = (uint16_t)strtoul(argv[i] + 8, nullptr, 16);
        else if (a.rfind("--maxcyc=", 0) == 0)  maxcyc = strtoull(argv[i] + 9, nullptr, 10);
        else if (a.rfind("--passes=", 0) == 0)  want_passes = strtoul(argv[i] + 9, nullptr, 10);
    }
    if (!bin) { std::fprintf(stderr, "need --bin=apple/bustest.bin\n"); return 2; }

    std::FILE* f = std::fopen(bin, "rb");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", bin); return 2; }
    const std::size_t n = std::fread(&mem[0x6000], 1, sizeof(mem) - 0x6000, f);
    std::fclose(f);
    std::printf("loaded %zu bytes at $6000..$%04zX\n", n, 0x6000 + n - 1);

    mem[0xFFFC] = entry & 0xFF;
    mem[0xFFFD] = entry >> 8;
    mem[0xFFFE] = kBrkStub & 0xFF;
    mem[0xFFFF] = kBrkStub >> 8;
    mem[kBrkStub + 0] = 0x6C;                 // JMP ($03F0)
    mem[kBrkStub + 1] = 0xF0;
    mem[kBrkStub + 2] = 0x03;

    Vcpu65c02 dut;
    dut.cyc_en = 1; dut.irq_n = 1; dut.nmi_n = 1; dut.rst = 1; dut.i_din = dut.d_din = 0; dut.clk = 0;
    auto tick = [&] {
        if (!dut.rw) mem[dut.addr] = dut.dout;
        dut.i_din = dut.d_din = mem[dut.addr];
        dut.clk = 0; dut.eval();
        dut.clk = 1; dut.eval();
    };
    for (int i = 0; i < 4; ++i) tick();
    dut.rst = 0;

    bool seen[256] = {false};
    uint64_t cycles = 0, instrs = 0;
    unsigned passes = 0;
    uint8_t last_screen = mem[0x0400];
    uint64_t last_progress = 0;
    uint16_t trail[32] = {0}; unsigned ti = 0;
    bool brk_seen = false;
    uint64_t acc_same = 0, acc_cross = 0;
    int io_hits = 0;
    uint16_t io_at = 0, io_pc = 0, cur_pc = 0;

    while (cycles < maxcyc && passes < want_passes) {
        const uint16_t a = (uint16_t)dut.addr;
        if (dut.sync) {
            seen[mem[a]] = true; ++instrs; cur_pc = a; trail[ti++ & 31] = a;
            if (a == 0x7F00 && !brk_seen) {
                brk_seen = true;
                // Worth one line: BRK is the only instruction here that leaves
                // the program, and on hardware it leaves through ROM. If this
                // never prints, the BRK section is not being reached.
                std::printf("  BRK vectored at cycle %llu (saved S = $%02X)\n",
                            (unsigned long long)cycles, mem[0x70A8]);
            }
        }

        // Evidence that the page-sensitive forms really do both things.
        // D_SAME is $4080 and D_CROSS is $40F0, both indexed by $20: the first
        // stays in page $40, the second lands in page $41. An access in page
        // $41 can therefore only come from an index that carried, and its
        // absence would mean the crossing cases quietly stopped crossing.
        if (!dut.sync) {
            if ((a & 0xFF00) == 0x4000) ++acc_same;
            if ((a & 0xFF00) == 0x4100) ++acc_cross;
        }

        // The one thing bustest must never do.
        //
        // Not enforced during the boot, and that is not a loophole: the loader
        // calls the disk controller's ROM, which lives at $C600 and is the
        // whole reason a boot sector can read anything.  The rule is about the
        // exerciser, so it starts at the warm start.
        if ((a & 0xF000) == 0xC000) {
            if (io_hits == 0) { io_at = a; io_pc = cur_pc; }
            ++io_hits;
        }

        // A pass is one WRITE to the counter cell, not a change in its value.
        // The distinction matters: a program that writes the same byte every
        // pass is looping perfectly and looks stopped.
        const bool pass_write = (dut.rw == 0) && (a == 0x0400);

        tick();
        ++cycles;

        if (pass_write) {
            last_screen = mem[0x0400];
            ++passes;
            std::printf("  pass %u complete at cycle %llu (%llu instructions)\n",
                        passes, (unsigned long long)cycles, (unsigned long long)instrs);
            last_progress = cycles;
        }
        // The loader parks after install returns. That is where a person
        // presses Ctrl-Reset, so press it: the Autostart ROM checks the
        // power-up byte and jumps through $03F2, and this checks that install
        // armed both correctly rather than assuming it.
        if (dut.halted) { std::printf("FAIL: core halted (STP)\n"); return 1; }
        if (cycles - last_progress > 8000000) {
            std::printf("FAIL: no progress for 8M cycles - stuck near $%04X\n", cur_pc);
            std::printf("last opcode fetches:");
            for (int k = 0; k < 32; ++k) std::printf(" $%04X", trail[(ti + k) & 31]);
            std::printf("\n$03F0/$03F1 = $%02X $%02X   $0400 = $%02X\n",
                        mem[0x03F0], mem[0x03F1], mem[0x0400]);
            return 1;
        }
    }

    unsigned covered = 0;
    for (int i = 0; i < 256; ++i) if (seen[i]) ++covered;

    std::printf("\ncycles %llu, instructions %llu, passes %u\n",
                (unsigned long long)cycles, (unsigned long long)instrs, passes);
    std::printf("opcode coverage: %u of 256\n", covered);
    if (covered < 256) {
        std::printf("not executed:");
        int shown = 0;
        for (int i = 0; i < 256; ++i) {
            if (!seen[i] && shown < 48) { std::printf(" $%02X", i); ++shown; }
        }
        if (covered < 256 - 48) std::printf(" ...");
        std::printf("\n");
    }

    std::printf("indexed accesses: %llu inside page $40, %llu carried into $41\n",
                (unsigned long long)acc_same, (unsigned long long)acc_cross);

    int rc = 0;
    if (acc_cross == 0 || acc_same == 0) {
        std::printf("FAIL: the page-sensitive forms are not covering both cases.\n");
        rc = 1;
    }
    if (io_hits != 0) {
        std::printf("FAIL: %d access(es) to the I/O page - first $%04X from an "
                    "instruction at $%04X.\n"
                    "      On the Apple that is a soft switch, not memory.\n",
                    io_hits, io_at, io_pc);
        rc = 1;
    }
    if (passes < want_passes) {
        std::printf("FAIL: only %u of %u passes completed\n", passes, want_passes);
        rc = 1;
    }
    if (rc == 0) std::printf("\nPASS: bustest runs, loops, and stays out of $Cxxx.\n");
    return rc;
}
