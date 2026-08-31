// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// mmu_trace_check - replay a captured Apple II bus trace through rtl/apple_mmu.sv
// and ask the real machine whether the shadow agrees with its MMU.
//
// WHAT THIS ANSWERS.  apple_mmu decides, for every bus cycle, which physical
// byte the IIe's MMU reached - main or auxiliary RAM, which language-card bank,
// RAM or ROM.  Get that wrong and the card's copy of memory silently diverges
// from the machine's.  There is no testbench that can settle it, because the
// question is what the REAL MMU does; but a bus capture of a real IIe contains
// the answer for every cycle: the byte the machine returned.
//
// So: feed each traced cycle to the RTL shadow exactly as apple_bus_write
// would present it, keep a software image of memory that records every write
// where the shadow says it landed, and on every read the shadow classifies as
// memory whose byte has been written since the capture began, require the
// machine's byte to equal the image's.  A wrong bank, a wrong LC state or a
// wrong ROM/RAM decision shows up as a mismatch on the next read of that byte.
//
// Two more oracles come free:
//   - reads of $C011-$C018 / $C01C / $C01D return the switches in bit 7, so the
//     shadow's state is compared against the machine's own report of it;
//   - reads the shadow classifies as ROM are compared against the ROM image the
//     host will load into rtl/apple_rom.sv, which also proves that file IS this
//     machine's ROM.
//
// Bytes never written since the capture began are not compared - the card
// serves garbage for those by decision (docs/MEMORY.md), and so does a
// powered-up Apple.  A gap in the capture (dropped events) forgets every
// written byte: a write may have been lost.
//
// Format duplicated from sim/trace_replay_main.cpp, and for the same reason.

#include "Vapple_mmu.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace trace {
constexpr uint32_t kMagic = 0x54425753u;   // "SWBT"
constexpr uint16_t kVersion = 1;
struct Header {
    uint32_t magic; uint16_t version; uint16_t word_bytes; uint32_t flags;
    uint32_t reserved0; uint64_t epoch_ms; uint64_t reserved1;
};
static_assert(sizeof(Header) == 32, "must match the host's on-disk header");
constexpr uint32_t kEventTag = 0xFu;
constexpr uint32_t kGapTag = 0xEu;
constexpr uint32_t kSkipTag = 0xDu;   // sparse capture: N cycles passed unsent (docs/SPARSE.md)
struct Event { uint16_t addr; uint8_t data; bool rw; bool res; bool sync; };
inline bool is_event(uint32_t w) { return (w >> 28) == kEventTag; }
inline bool is_gap(uint32_t w)   { return (w >> 28) == kGapTag; }
inline bool is_skip(uint32_t w)  { return (w >> 28) == kSkipTag; }
inline uint32_t skip_count(uint32_t w) { return w & 0x0FFFFFFFu; }
inline Event decode(uint32_t w) {
    Event e;
    e.addr = static_cast<uint16_t>(w & 0xFFFF);
    e.data = static_cast<uint8_t>((w >> 20) & 0xFF);
    e.rw   = ((w >> 16) & 1) != 0;
    e.res  = ((w >> 17) & 1) != 0;
    e.sync = ((w >> 18) & 1) != 0;
    return e;
}
}  // namespace trace

namespace {

enum Cls : int { BUS = 0, RAM = 1, LC = 2, ROM = 3 };
const char* cls_name(int c) {
    static const char* n[] = {"BUS", "RAM", "LC", "ROM"};
    return n[c & 3];
}

struct Options {
    std::string path;
    std::string rom_path;
    uint64_t max_cycles = 0;
    unsigned show = 10;         // mismatches to print in full
    bool verbose = false;
};

// Bits of sw_state, matching apple_mmu's export order.
enum Sw : int { STORE80 = 0, RAMRD, RAMWRT, ALTZP, PAGE2, HIRES, INTCXROM,
                SLOTC3ROM, BANK2, LCRAMRD, WREN, PREWRITE };

const char* sw_name(int b) {
    static const char* n[] = {"80STORE", "RAMRD", "RAMWRT", "ALTZP", "PAGE2",
                              "HIRES", "INTCXROM", "SLOTC3ROM", "BANK2",
                              "LCRAMRD", "WREN", "PREWRITE"};
    return n[b];
}

// $C011-$C01D status reads: which switch bit 7 reports, or -1.
int status_switch(uint16_t addr) {
    switch (addr) {
        case 0xC011: return BANK2;
        case 0xC012: return LCRAMRD;
        case 0xC013: return RAMRD;
        case 0xC014: return RAMWRT;
        case 0xC015: return INTCXROM;
        case 0xC016: return ALTZP;
        case 0xC017: return SLOTC3ROM;
        case 0xC018: return STORE80;
        case 0xC01C: return PAGE2;
        case 0xC01D: return HIRES;
        default: return -1;
    }
}

std::string sw_string(unsigned s) {
    std::string out;
    for (int b = 0; b < 12; ++b) {
        if (s & (1u << b)) { if (!out.empty()) out += ' '; out += sw_name(b); }
    }
    return out.empty() ? "(none)" : out;
}

bool load_words(const std::string& path, std::vector<uint32_t>* words, std::string* err) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) { *err = "cannot open " + path; return false; }
    trace::Header h{};
    if (std::fread(&h, sizeof h, 1, f) != 1) { *err = "too short"; std::fclose(f); return false; }
    if (h.magic != trace::kMagic) { *err = "not a bus trace"; std::fclose(f); return false; }
    if (h.version != trace::kVersion || h.word_bytes != 4) {
        *err = "unsupported trace version"; std::fclose(f); return false;
    }
    std::fseek(f, 0, SEEK_END);
    long end = std::ftell(f);
    std::fseek(f, static_cast<long>(sizeof h), SEEK_SET);
    size_t n = static_cast<size_t>(end - static_cast<long>(sizeof h)) / 4;
    words->resize(n);
    if (n && std::fread(words->data(), 4, n, f) != n) { *err = "short read"; std::fclose(f); return false; }
    std::fclose(f);
    return true;
}

bool load_rom(const std::string& path, std::vector<uint8_t>* rom, std::string* err) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) { *err = "cannot open " + path; return false; }
    rom->resize(16384);
    size_t n = std::fread(rom->data(), 1, rom->size(), f);
    std::fclose(f);
    if (n != rom->size()) { *err = path + ": expected 16384 bytes"; return false; }
    return true;
}

void usage() {
    std::fprintf(stderr,
        "usage: mmu_trace_check --trace=FILE [--rom=FILE] [--max=N] [--show=N] [--verbose]\n");
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Options opt;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a.rfind("--trace=", 0) == 0) opt.path = a.substr(8);
        else if (a.rfind("--rom=", 0) == 0) opt.rom_path = a.substr(6);
        else if (a.rfind("--max=", 0) == 0) opt.max_cycles = std::strtoull(a.substr(6).c_str(), nullptr, 0);
        else if (a.rfind("--show=", 0) == 0) opt.show = static_cast<unsigned>(std::strtoul(a.substr(7).c_str(), nullptr, 0));
        else if (a == "--verbose") opt.verbose = true;
        else if (a == "--help" || a == "-h") { usage(); return 0; }
        else { std::fprintf(stderr, "unknown option %s\n", argv[i]); usage(); return 2; }
    }
    if (opt.path.empty()) { usage(); return 2; }

    std::vector<uint32_t> words;
    std::string err;
    if (!load_words(opt.path, &words, &err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 2; }
    std::vector<uint8_t> rom;
    bool have_rom = false;
    if (!opt.rom_path.empty()) {
        if (!load_rom(opt.rom_path, &rom, &err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 2; }
        have_rom = true;
    }

    // The image: 256 banks of 64 KB, emulator layout - main, then the
    // auxiliary memory one RamWorks bank at a time.  A real IIe's capture
    // never leaves banks 0 and 1 unless something wrote the bank register.
    std::vector<uint8_t> image(1u << 24, 0);
    std::vector<uint8_t> written(1u << 24, 0);

    Vapple_mmu top;
    auto tick = [&]() { top.clk = 0; top.eval(); top.clk = 1; top.eval(); };

    top.rst = 1; top.res_sync = 1; top.op_present = 0; top.op_commit = 0;
    top.op_addr = 0; top.op_rw = 1; top.op_wdata = 0; top.q_addr = 0;
    for (int i = 0; i < 4; ++i) tick();
    top.rst = 0;
    tick();

    uint64_t cycles = 0, gaps = 0, resets = 0, skips = 0;
    uint64_t cls_count[4] = {0, 0, 0, 0};
    uint64_t compared[4] = {0, 0, 0, 0};
    uint64_t mismatch[4] = {0, 0, 0, 0};
    uint64_t status_checked[12] = {0}, status_wrong[12] = {0};
    uint64_t sw_accesses[12] = {0};
    uint64_t lc_accesses = 0, writes_recorded = 0, writes_dropped = 0;
    uint64_t bad_bank = 0;
    bool armed = false;         // a reset has been seen: the shadow is known
    bool prev_res = true;
    unsigned shown = 0;

    for (size_t wi = 0; wi < words.size(); ++wi) {
        uint32_t w = words[wi];
        if (trace::is_gap(w)) {
            ++gaps;
            std::fill(written.begin(), written.end(), 0);
            continue;
        }
        // A sparse capture's unsent cycles: reads of RAM and ROM, none of
        // which change the shadow, so the check goes on - with fewer reads
        // to compare.
        if (trace::is_skip(w)) { ++skips; cycles += trace::skip_count(w); continue; }
        if (!trace::is_event(w)) continue;
        trace::Event e = trace::decode(w);
        if (opt.max_cycles && cycles >= opt.max_cycles) break;
        ++cycles;

        if (!e.res && prev_res) { ++resets; armed = true; }
        prev_res = e.res;

        // Present the op as apple_bus_write would.
        top.res_sync = e.res ? 1 : 0;
        top.op_addr = e.addr;
        top.op_rw = e.rw ? 1 : 0;
        top.op_wdata = e.data;
        top.op_present = 1; tick();          // cl_* latched on this edge
        top.op_present = 0;
        unsigned sw = top.sw_state;
        int cls = top.cl_cls;
        // The classifier speaks {aux, bank, folded offset} now; this
        // checker's image keeps its old 16 MB shape, main at bank 0 and
        // RamWorks bank k at k+1, so reconstruct that index.
        uint32_t pa = (top.cl_aux ? (static_cast<uint32_t>(top.cl_bank) + 1u) << 16 : 0u)
                      | top.cl_off;
        uint32_t rom_addr = e.addr & 0x3FFFu;
        bool wr_image = top.cl_wr_image;
        if (!top.cl_valid) { std::fprintf(stderr, "cl_valid did not pulse\n"); return 3; }

        bool in_reset = !e.res;
        if (armed && !in_reset) {
            ++cls_count[cls];
            if ((e.addr & 0xFFF0) == 0xC080) ++lc_accesses;
            if ((e.addr & 0xFFF0) == 0xC000 && !e.rw) ++sw_accesses[(e.addr >> 1) & 7];

            if (pa >= image.size()) { ++bad_bank; }
            else if (!e.rw) {
                if (wr_image && (cls == RAM || cls == LC)) {
                    image[pa] = e.data; written[pa] = 1; ++writes_recorded;
                } else if (cls == ROM) {
                    ++writes_dropped;
                }
            } else {
                if ((cls == RAM || cls == LC) && written[pa]) {
                    ++compared[cls];
                    if (image[pa] != e.data) {
                        ++mismatch[cls];
                        if (shown < opt.show) {
                            ++shown;
                            std::printf("MISMATCH cycle %llu: read $%04X (%s pa=%06X) machine=%02X image=%02X  switches: %s\n",
                                        static_cast<unsigned long long>(cycles), e.addr, cls_name(cls),
                                        pa, e.data, image[pa], sw_string(sw).c_str());
                        }
                        // Take the machine's word for it, so one bad decision is
                        // reported once rather than on every later read.
                        image[pa] = e.data;
                    }
                } else if (cls == ROM && have_rom) {
                    ++compared[ROM];
                    if (rom[rom_addr] != e.data) {
                        ++mismatch[ROM];
                        if (shown < opt.show) {
                            ++shown;
                            std::printf("MISMATCH cycle %llu: read $%04X (ROM) machine=%02X rom=%02X  switches: %s\n",
                                        static_cast<unsigned long long>(cycles), e.addr, e.data,
                                        rom[rom_addr], sw_string(sw).c_str());
                        }
                    }
                }
                int st = status_switch(e.addr);
                if (st >= 0) {
                    ++status_checked[st];
                    bool machine = (e.data & 0x80) != 0;
                    bool shadow = (sw >> st) & 1;
                    if (machine != shadow) {
                        ++status_wrong[st];
                        if (shown < opt.show) {
                            ++shown;
                            std::printf("STATUS cycle %llu: read $%04X (%s) machine=%d shadow=%d  switches: %s\n",
                                        static_cast<unsigned long long>(cycles), e.addr, sw_name(st),
                                        machine ? 1 : 0, shadow ? 1 : 0, sw_string(sw).c_str());
                        }
                    }
                }
            }
        }

        // The data phase: the switches move.
        top.op_commit = 1; tick();
        top.op_commit = 0; tick();
    }

    uint64_t total_mismatch = 0, total_status_wrong = 0;
    for (int c = 0; c < 4; ++c) total_mismatch += mismatch[c];
    for (int b = 0; b < 12; ++b) total_status_wrong += status_wrong[b];

    std::printf("-- mmu_trace_check: %s --\n", opt.path.c_str());
    std::printf("cycles %llu  resets %llu  gaps %llu  skips %llu  armed %s\n",
                static_cast<unsigned long long>(cycles), static_cast<unsigned long long>(resets),
                static_cast<unsigned long long>(gaps), static_cast<unsigned long long>(skips), armed ? "yes" : "NO - no reset in the trace");
    std::printf("classes: BUS %llu  RAM %llu  LC %llu  ROM %llu   (bad bank %llu)\n",
                static_cast<unsigned long long>(cls_count[BUS]), static_cast<unsigned long long>(cls_count[RAM]),
                static_cast<unsigned long long>(cls_count[LC]), static_cast<unsigned long long>(cls_count[ROM]),
                static_cast<unsigned long long>(bad_bank));
    std::printf("writes recorded %llu  dropped (ROM, write-protected) %llu  LC switch accesses %llu\n",
                static_cast<unsigned long long>(writes_recorded), static_cast<unsigned long long>(writes_dropped),
                static_cast<unsigned long long>(lc_accesses));
    std::printf("switch writes:");
    for (int b = 0; b < 6; ++b) std::printf("  %s %llu", sw_name(b == 3 ? INTCXROM : b == 4 ? ALTZP : b == 5 ? SLOTC3ROM : b),
                                            static_cast<unsigned long long>(sw_accesses[b]));
    std::printf("\n");
    std::printf("compared: RAM %llu (mismatch %llu)  LC %llu (mismatch %llu)  ROM %llu (mismatch %llu)%s\n",
                static_cast<unsigned long long>(compared[RAM]), static_cast<unsigned long long>(mismatch[RAM]),
                static_cast<unsigned long long>(compared[LC]), static_cast<unsigned long long>(mismatch[LC]),
                static_cast<unsigned long long>(compared[ROM]), static_cast<unsigned long long>(mismatch[ROM]),
                have_rom ? "" : "  [no --rom: ROM not compared]");
    std::printf("status reads:");
    for (int b = 0; b < 12; ++b) {
        if (status_checked[b])
            std::printf("  %s %llu/%llu wrong", sw_name(b),
                        static_cast<unsigned long long>(status_wrong[b]),
                        static_cast<unsigned long long>(status_checked[b]));
    }
    std::printf("\n");

    bool pass = armed && total_mismatch == 0 && total_status_wrong == 0 && bad_bank == 0;
    std::printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
