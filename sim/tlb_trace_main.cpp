// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// tlb_trace_main - pump a captured bus trace through sim/tlb_check_top.sv.
//
// The comparison lives in the RTL wrapper (class_tlb beside the apple_mmu it
// caches, disagreement counted); this is only the pump, driving each traced
// cycle exactly as sim/mmu_trace_check.cpp does - present, commit, breathe -
// and reading the counters at the end.  PASS is zero mismatches over every
// op whose page the TLB had cached.
//
// Trace format duplicated from sim/trace_replay_main.cpp, for the same reason
// it is duplicated everywhere: the format is frozen and the copies are the
// proof that nothing drifted.

#include "Vtlb_check_top.h"
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
constexpr uint32_t kSkipTag = 0xDu;
constexpr uint32_t kFastTag = 0xCu;
struct Event { uint16_t addr; uint8_t data; bool rw; bool res; bool sync; };
inline bool is_event(uint32_t w) { return (w >> 28) == kEventTag; }
inline bool is_fast(uint32_t w) { return (w >> 28) == kFastTag; }
inline bool is_gap(uint32_t w) { return (w >> 28) == kGapTag; }
inline bool is_skip(uint32_t w) { return (w >> 28) == kSkipTag; }
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

static bool load_words(const std::string& path, std::vector<uint32_t>* words,
                       std::string* err) {
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

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string path;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a.rfind("--trace=", 0) == 0) path = a.substr(8);
        else { std::fprintf(stderr, "usage: tlb_trace_check --trace=FILE\n"); return 2; }
    }
    if (path.empty()) { std::fprintf(stderr, "usage: tlb_trace_check --trace=FILE\n"); return 2; }

    std::vector<uint32_t> words;
    std::string err;
    if (!load_words(path, &words, &err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 2; }

    Vtlb_check_top top;
    auto tick = [&]() { top.clk = 0; top.eval(); top.clk = 1; top.eval(); };

    top.rst = 1; top.res_sync = 1; top.op_present = 0; top.op_commit = 0;
    top.op_addr = 0; top.op_rw = 1; top.op_wdata = 0;
    top.rom_ok = 1;
    for (int i = 0; i < 4; ++i) tick();
    top.rst = 0;
    tick();

    uint64_t ops = 0;
    for (uint32_t w : words) {
        if (!trace::is_event(w) && !trace::is_fast(w)) continue;
        trace::Event e = trace::decode(w);
        ++ops;

        top.res_sync = e.res ? 1 : 0;
        top.op_addr = e.addr;
        top.op_rw = e.rw ? 1 : 0;
        top.op_wdata = e.data;
        top.op_present = 1; tick();
        top.op_present = 0; tick();          // cl_valid: compare and install
        top.op_commit = 1; tick();           // the switches move
        top.op_commit = 0; tick();
    }

    std::printf("-- tlb_trace_check: %s --\n", path.c_str());
    std::printf("ops %llu  lookups %u  hits %u (%.4f%%)  installs %u  flushes %u\n",
                static_cast<unsigned long long>(ops), top.n_lookups, top.n_hits,
                top.n_lookups ? 100.0 * top.n_hits / top.n_lookups : 0.0,
                top.n_installs, top.n_flushes);
    std::printf("mismatches %u\n", top.n_mismatch);
    bool pass = top.n_mismatch == 0 && top.n_lookups > 0;
    std::printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
