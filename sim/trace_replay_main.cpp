// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// Replaying a captured Apple II bus trace against rtl/cpu65c02.sv, to close the
// one thing the functional suites cannot check: WHICH address the core drives
// during each cycle, dummy reads included.
//
// THE ARGUMENT.  Klaus Dormann's suites check results - registers and memory
// end up right - and sim/run_cpu_cycles_tb.sh checks that every opcode takes the
// published NUMBER of cycles.  Neither can see the address on a cycle whose
// value the instruction discards, because neither has a bus to look at.  A real
// 65C02 in a real Apple II does, and swhost's --trace writes it down.
//
// So: drive this core with the bytes the real one was given, and compare the
// address and R/W it drives on every cycle against what the real one drove.  A
// divergence is a difference between this core and the part it stands in for -
// which is the whole question for the CPU socket and for DMA bus mastering.
//
// WHAT LOCKSTEP CAN AND CANNOT PROVE.  While the two agree, `din` comes from the
// trace at the address BOTH are driving, so the replay is exact.  The moment
// they disagree, this core is being fed bytes from an address it did not ask
// for and everything after is meaningless.  That is not a weakness of the
// method, it is the method: the useful output is how far it got and what the
// first difference was, and the run is over at that point by construction.
//
// THREE REASONS A DIVERGENCE IS NOT A BUG IN THE CORE, all of which this tool
// names rather than letting them be mistaken for findings:
//
//   1. THE RESET SEQUENCE.  The real part does two dummy reads at PC before the
//      three stack cycles; this core enters at BRK's first stack cycle and does
//      not.  Rather than compare across that difference, the run is aligned on
//      the $FFFC/$FFFD vector fetch, which both machines do and which puts them
//      at the same PC with the same flags.  Any offset left after that is found
//      by --skew, measured, not asserted - a tool that hard-coded the number
//      could not discover that the number was wrong.
//
//   2. THE STACK POINTER.  Reset does not initialise S on a real 6502 - it
//      decrements it by three - so the real machine's stack lives wherever the
//      last hour of software left it, while this core resets S to $00.  The
//      trace states the answer: the first of the three reset stack reads is at
//      $0100+S, and the part leaves reset three below that.  So S is read out
//      of the trace and seeded into the core, and the run starts from genuinely
//      the same state.  --no-seed-s disables it.
//
//   3. INTERRUPTS ARE NOT IN THE TRACE.  The event word carries RES' and
//      nothing else, so an IRQ from a peripheral appears only as the real part
//      suddenly fetching $FFFE.  This tool recognises that shape and says so,
//      because "diverged at a vector fetch" is an interrupt, not a bug.
//
// A/X/Y ARE STILL ARBITRARY after a reset, on both machines.  Nothing can fix
// that from outside, so a trace whose first instructions index off an
// uninitialised register will diverge for a reason that is nobody's fault.  A
// purpose-written test program that sets its own registers first is the way to
// get a long run; the monitor's own reset path is the way to get a quick one.

#include "Vcpu65c02.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <map>
#include <string>
#include <vector>

// ---- the trace file format -------------------------------------------------
//
// Written by strudelworks-host, src/trace_writer.hpp.  Duplicated rather than
// shared because the two repos build separately; the magic and the version
// exist so a mismatch is caught here rather than decoded as garbage.

namespace trace {

constexpr uint32_t kMagic = 0x54425753u;   // "SWBT"
constexpr uint16_t kVersion = 1;
constexpr uint32_t kFlagRealBus = 1u << 0;
constexpr uint32_t kFlagArmedOnReset = 1u << 1;
// Set only by this tool's --emit. Not part of the host's format: the host never
// writes it, and it exists so a self-test trace can never be mistaken for a
// capture of a real machine. See the emit mode below for why that distinction
// is the whole point.
//
// Bit 4, not 2: the host took 2 for kFlagSyncSynth. Two writers of one format
// picking bits independently is how a flag ends up meaning two things, so this
// one moved rather than the host's - nothing has been written with the old
// value except self-test traces, which are regenerated on demand.
constexpr uint32_t kFlagSelfTest = 1u << 4;
// The host's flag: SYNC in this capture is the driving core's, not the bus's.
// A card that has taken the bus has disconnected the real 6502, and SYNC is
// that chip's output - so the card substitutes its own core's.  Everything else
// in the word was measured on the wire; this bit was reconstructed.
constexpr uint32_t kFlagSyncSynth = 1u << 2;

struct Header {
    uint32_t magic;
    uint16_t version;
    uint16_t word_bytes;
    uint32_t flags;
    uint32_t reserved0;
    uint64_t epoch_ms;
    uint64_t reserved1;
};
static_assert(sizeof(Header) == 32, "must match the host's on-disk header");

constexpr uint32_t kEventTag = 0xFu;
constexpr uint32_t kGapTag = 0xEu;

struct Event {
    uint16_t addr;
    uint8_t  data;
    bool     rw;     // 1 = read
    bool     res;    // ACTIVE LOW: 0 means reset is being asserted
    bool     sync;   // this cycle is an opcode fetch
};

// Bit 18 is SYNC, and it is worth saying how that was established rather than
// asserted.  The field is named m2sel in the wire format after the IIe slot
// signal the pin nominally carries; on this card it is wired to the CPU's SYNC.
//
// Checked two ways over a real capture, and both are conclusive:
//
//   - Of 33.5 million cycles, the number that are BOTH a write and SYNC is
//     ZERO.  An opcode fetch is a read, so anything else would have ruled it
//     out immediately.
//   - Taking each SYNC cycle's data byte as an opcode and looking up its
//     published cycle count, the distance to the NEXT SYNC matched that count
//     for 109,090 consecutive instructions - 100%, allowing the documented
//     +1 for a page cross or a taken branch.
//
// The neighbouring bit, m2b0, is never high anywhere in the trace.
//
// This was sitting in the event word unused, and not using it cost a whole
// dimension of checking: instruction boundaries in the trace were previously
// inferred from the CORE's sync, which is the thing under test.

inline bool is_event(uint32_t w) { return (w >> 28) == kEventTag; }
inline bool is_gap(uint32_t w)   { return (w >> 28) == kGapTag; }
inline uint32_t gap_count(uint32_t w) { return w & 0x0FFFFFFFu; }
// A sparse capture's SKIP (docs/SPARSE.md): N cycles the card did not send.
// To a lockstep replay that is a gap by another name - the next word is not
// the next cycle - and it is treated as one everywhere below.
constexpr uint32_t kSkipTag = 0xDu;
inline bool is_skip(uint32_t w)  { return (w >> 28) == kSkipTag; }
inline uint32_t skip_count(uint32_t w) { return w & 0x0FFFFFFFu; }
inline bool is_break(uint32_t w) { return is_gap(w) || is_skip(w); }

inline Event decode(uint32_t w) {
    Event e;
    e.addr = static_cast<uint16_t>(w & 0xFFFF);
    e.data = static_cast<uint8_t>((w >> 20) & 0xFF);
    e.rw   = ((w >> 16) & 1) != 0;
    e.res  = ((w >> 17) & 1) != 0;
    e.sync = ((w >> 18) & 1) != 0;
    return e;
}

// True when the machine is being HELD in reset.
inline bool in_reset(const Event& e) { return !e.res; }

}  // namespace trace

// ---------------------------------------------------------------------------

namespace {

// Below this, "no divergence" is not a result. One instruction is a handful of
// cycles; a few thousand is enough to have exercised addressing modes, the
// stack, and a branch or two.
constexpr uint64_t kMinUsefulRun = 5000;

struct Options {
    std::string path;
    std::string emit_path;      // --emit: generate a self-test trace instead
    uint64_t emit_cycles = 20000;   // must clear kMinUsefulRun
    unsigned emit_s = 0xF6;     // pre-reset S, so the seeded value is $F3
    int  skew = INT32_MIN;      // unset: search
    int  skew_lo = -4;
    int  skew_hi = 4;
    bool seed_s = true;
    int  reset_index = -1;      // which reset to replay; -1 picks the settled one
    // Align on an opcode fetch at this address instead of on a reset. -1 is
    // off. See the note where it is used: a capture of a program that is
    // REACHED from a reset, rather than being the reset, wants this.
    int  from_addr = -1;
    unsigned from_nth = 0;      // which occurrence of it
    // Tolerate this many read/read address mismatches and keep going, instead
    // of stopping at the first. See the lockstep loop for when that is sound.
    uint64_t tolerate = 0;
    unsigned context = 12;      // cycles of history to print around a divergence
    uint64_t max_cycles = 0;    // 0 = to the end of the trace
    bool quiet = false;
};

std::vector<uint32_t> g_words;
trace::Header g_header{};

bool load(const std::string& path, std::string* err) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) { *err = "cannot open " + path; return false; }
    if (std::fread(&g_header, sizeof(g_header), 1, f) != 1) {
        *err = path + ": too short to hold a header";
        std::fclose(f);
        return false;
    }
    if (g_header.magic != trace::kMagic) {
        char b[128];
        std::snprintf(b, sizeof b, "%s: not a bus trace (magic %08x, expected %08x)",
                      path.c_str(), g_header.magic, trace::kMagic);
        *err = b;
        std::fclose(f);
        return false;
    }
    if (g_header.version != trace::kVersion || g_header.word_bytes != 4) {
        char b[128];
        std::snprintf(b, sizeof b, "%s: version %u/%u-byte words, this tool reads %u/4",
                      path.c_str(), g_header.version, g_header.word_bytes,
                      trace::kVersion);
        *err = b;
        std::fclose(f);
        return false;
    }
    uint32_t w;
    while (std::fread(&w, 4, 1, f) == 1) g_words.push_back(w);
    std::fclose(f);
    return true;
}

// A trace can only be replayed up to its first gap: after one, the next word is
// not the next cycle, and a replay that carried on would be comparing this
// core against a machine several instructions further along.
std::size_t first_gap() {
    for (std::size_t i = 0; i < g_words.size(); ++i) {
        if (trace::is_break(g_words[i])) return i;
    }
    return g_words.size();
}

const char* rwc(bool rw) { return rw ? "r" : "w"; }

// One reset sequence found in the trace, and how much usable run follows it.
struct TraceReset {
    std::size_t vfetch = 0;        // index of the $FFFC read
    std::size_t align_at = 0;      // vfetch + 2: the first opcode fetch
    uint16_t    vec = 0;
    bool        have_s = false;
    uint8_t     s_before = 0;
    unsigned    stack_cycles = 0;
    std::size_t clean_run = 0;     // cycles until RES' is asserted again
};

// Every reset in the trace, with the length of the uninterrupted run after it.
//
// WHY EVERY ONE, and not just the first. RES' on these machines is a switch on
// a wire, and nothing debounces it: one press of Ctrl-Reset lands as several
// assertions a few microseconds apart, each starting a reset sequence the next
// one interrupts. Aligning on the first and calling whatever follows "the run"
// gets a handful of cycles before the next bounce cuts it off - and a checker
// that then reports no divergence has reported nothing at all.
//
// So the run worth replaying is the one after the bus SETTLES: the reset with
// the longest stretch of released RES' behind it. That is measured here rather
// than guessed at, because how long a switch bounces is not a constant.
std::vector<TraceReset> find_all_resets(std::size_t limit) {
    std::vector<TraceReset> out;
    for (std::size_t i = 0; i + 1 < limit; ++i) {
        if (!trace::is_event(g_words[i]) || !trace::is_event(g_words[i + 1])) continue;
        const trace::Event a = trace::decode(g_words[i]);
        const trace::Event b = trace::decode(g_words[i + 1]);
        if (a.addr != 0xFFFC || b.addr != 0xFFFD || !a.rw || !b.rw) continue;

        TraceReset r;
        r.vfetch = i;
        r.align_at = i + 2;
        r.vec = static_cast<uint16_t>(a.data | (b.data << 8));

        // The stack cycles are whatever immediately precedes the vector in page
        // one, descending, as reads - reset reads where BRK writes. Walked
        // backwards, so each earlier cycle is one HIGHER than the one after it.
        std::size_t last = i;
        unsigned n = 0;
        uint16_t prev = 0;
        while (last > 0) {
            const std::size_t j = last - 1;
            if (!trace::is_event(g_words[j])) break;
            const trace::Event e = trace::decode(g_words[j]);
            if ((e.addr & 0xFF00) != 0x0100 || !e.rw) break;
            if (n != 0 && static_cast<uint8_t>(prev + 1) != static_cast<uint8_t>(e.addr & 0xFF)) break;
            prev = e.addr;
            ++n;
            last = j;
        }
        if (n >= 2) {
            r.have_s = true;
            r.s_before = static_cast<uint8_t>(prev & 0xFF);
            r.stack_cycles = n;
        }

        // How far this run gets before RES' is asserted again. That, and not
        // the trace's length, is how much of this reset is usable.
        std::size_t k = r.align_at;
        while (k < limit) {
            if (trace::is_break(g_words[k])) break;
            if (trace::is_event(g_words[k]) && trace::in_reset(trace::decode(g_words[k]))) break;
            ++k;
        }
        r.clean_run = k - r.align_at;
        out.push_back(r);
        i = r.vfetch + 1;   // do not rediscover the same vector fetch
    }
    return out;
}

}  // namespace

// ---- self-test trace generation --------------------------------------------
//
// --emit runs THIS core against a small program and writes the result out in
// the host's trace format, with a synthesised reset in front of it.
//
// WHAT THIS IS FOR, and what it is emphatically not for. Replaying it proves
// the tool: that the reset is found, the vector located, S recovered from the
// stack cycles and seeded correctly, the alignment right, and every field
// decoded the way the host encoded it. It proves NOTHING about the core, which
// is on both sides of the comparison - a core that drove the wrong address
// during a dummy cycle would emit that wrong address and then match it.
//
// That is why the file is flagged, and why the replay says so in its banner. A
// green self-test that got mistaken for a verified core would be worse than no
// self-test at all.

namespace {

// Exercises the shapes whose dummy-cycle addresses are unverified - indexed
// page crossings in both the read and the always-pay write form, the CMOS
// JMP (abs), decimal ADC/SBC - plus stack traffic, so a mis-seeded S diverges
// immediately rather than a thousand cycles later.
struct Prog { uint16_t at; std::vector<uint8_t> bytes; };

const Prog kSelfTest[] = {
    {0x0300, {
        0x48,                    // PHA          - S must be right from cycle one
        0xA2, 0x05,              // LDX #$05
        0xA0, 0xFF,              // LDY #$FF
        0xA9, 0x41,              // LDA #$41
        0x85, 0x12,              // STA $12
        0xA9, 0x03,              // LDA #$03
        0x85, 0x13,              // STA $13      - ($12) = $0341
        0xBD, 0x80, 0x02,        // LDA $0280,X  - indexed, no page cross
        0xB9, 0xFE, 0x02,        // LDA $02FE,Y  - CROSSES: the fixup cycle
        0x99, 0xFE, 0x02,        // STA $02FE,Y  - write form: pays it regardless
        0xB1, 0x12,              // LDA ($12),Y  - (zp),Y, crosses
        0xFE, 0x00, 0x04,        // INC $0400,X  - RMW abs,X, a flat 7
        0x1E, 0x00, 0x04,        // ASL $0400,X  - 6 or 7
        0xF8,                    // SED
        0xA9, 0x19,              // LDA #$19
        0x69, 0x08,              // ADC #$08     - decimal: the extra CMOS cycle
        0xE9, 0x05,              // SBC #$05
        0xD8,                    // CLD
        0x20, 0x40, 0x03,        // JSR $0340    - stack again
        0x6C, 0x50, 0x03,        // JMP ($0350)  - the 6-cycle CMOS form
    }},
    {0x0340, {0x60}},                    // RTS
    {0x0350, {0x60, 0x03}},              // the indirect pointer -> $0360
    // INX / BNE $0360 - taken and not taken - then round the whole body again,
    // so a longer --emit-cycles keeps exercising the program rather than
    // falling out of the loop into BRK.
    {0x0360, {0xE8, 0xD0, 0xFD, 0x4C, 0x00, 0x03}},
};

uint32_t encode_event(uint16_t addr, uint8_t data, bool rw, bool res) {
    return (trace::kEventTag << 28) | (static_cast<uint32_t>(data) << 20) |
           (static_cast<uint32_t>(res) << 17) | (static_cast<uint32_t>(rw) << 16) | addr;
}

int emit(const std::string& path, uint64_t cycles, uint8_t s_before) {
    static uint8_t mem[65536];
    std::memset(mem, 0, sizeof mem);
    for (const Prog& p : kSelfTest) {
        for (std::size_t i = 0; i < p.bytes.size(); ++i) mem[p.at + i] = p.bytes[i];
    }
    const uint16_t vec = 0x0300;
    mem[0xFFFC] = static_cast<uint8_t>(vec & 0xFF);
    mem[0xFFFD] = static_cast<uint8_t>(vec >> 8);

    Vcpu65c02 dut;
    dut.cyc_en = 1;
    dut.irq_n = 1;
    dut.nmi_n = 1;
    dut.rst = 1;
    dut.din = 0;
    dut.clk = 0;
    auto tick = [&](uint8_t din) {
        if (!dut.rw) mem[dut.addr] = static_cast<uint8_t>(dut.dout);
        dut.din = din;
        dut.clk = 0; dut.eval();
        dut.clk = 1; dut.eval();
    };

    // Give this core the S the synthesised reset below will claim, by the same
    // injection the replay uses - through the instruction stream, with the
    // program's own first bytes temporarily displaced and then put back.
    const uint8_t s_after = static_cast<uint8_t>(s_before - 3);
    const uint16_t scratch = 0x0280;
    const uint8_t saved[3] = {mem[vec], mem[vec + 1], mem[vec + 2]};
    mem[vec] = 0x4C; mem[vec + 1] = static_cast<uint8_t>(scratch & 0xFF);
    mem[vec + 2] = static_cast<uint8_t>(scratch >> 8);
    mem[scratch]     = 0xA2; mem[scratch + 1] = s_after;   // LDX #S
    mem[scratch + 2] = 0x9A;                               // TXS
    mem[scratch + 3] = 0x4C;                               // JMP vec
    mem[scratch + 4] = static_cast<uint8_t>(vec & 0xFF);
    mem[scratch + 5] = static_cast<uint8_t>(vec >> 8);

    for (int i = 0; i < 4; ++i) tick(0);
    dut.rst = 0;
    int seen = 0;
    bool ready = false;
    for (int guard = 0; guard < 64; ++guard) {
        if (dut.sync && static_cast<uint16_t>(dut.addr) == vec && ++seen == 2) {
            ready = true;
            break;
        }
        tick(mem[dut.addr]);
    }
    if (!ready) { std::fprintf(stderr, "emit: the core never reached $%04X\n", vec); return 2; }
    mem[vec] = saved[0]; mem[vec + 1] = saved[1]; mem[vec + 2] = saved[2];
    std::memset(&mem[scratch], 0, 6);

    // The reset the real part would have driven, in front of the recording. Two
    // dummy reads at PC, three stack reads descending from $0100+S, then the
    // vector - which is the sequence the replay's searches look for, so this is
    // also what tests those searches.
    std::vector<uint32_t> out;
    for (int i = 0; i < 8; ++i) out.push_back(encode_event(0xFFFF, 0xFF, true, false));
    out.push_back(encode_event(vec, 0x00, true, true));
    out.push_back(encode_event(vec + 1, 0x00, true, true));
    for (int i = 0; i < 3; ++i) {
        out.push_back(encode_event(static_cast<uint16_t>(0x0100 | ((s_before - i) & 0xFF)),
                                   0x00, true, true));
    }
    out.push_back(encode_event(0xFFFC, mem[0xFFFC], true, true));
    out.push_back(encode_event(0xFFFD, mem[0xFFFD], true, true));

    for (uint64_t c = 0; c < cycles; ++c) {
        const uint16_t a = static_cast<uint16_t>(dut.addr);
        const bool rw = dut.rw != 0;
        const uint8_t data = rw ? mem[a] : static_cast<uint8_t>(dut.dout);
        out.push_back(encode_event(a, data, rw, true));
        tick(mem[a]);
        if (dut.halted) break;
    }

    FILE* f = std::fopen(path.c_str(), "wb");
    if (f == nullptr) { std::fprintf(stderr, "emit: cannot write %s\n", path.c_str()); return 2; }
    trace::Header h{};
    h.magic = trace::kMagic;
    h.version = trace::kVersion;
    h.word_bytes = 4;
    h.flags = trace::kFlagRealBus | trace::kFlagArmedOnReset | trace::kFlagSelfTest;
    h.epoch_ms = 0;
    std::fwrite(&h, sizeof h, 1, f);
    std::fwrite(out.data(), 4, out.size(), f);
    std::fclose(f);
    std::printf("emitted %zu words to %s  (reset S $%02X -> $%02X, vector $%04X)\n",
                out.size(), path.c_str(), s_before, s_after, vec);
    return 0;
}

}  // namespace

// ---------------------------------------------------------------------------

// What a reset sequence did to the stack, on either side. Derived the same way
// from a trace and from the core, so the two are directly comparable - which is
// the point: the compensation is a measured difference, not an assumption about
// what a reset is supposed to do.
struct ResetShape {
    bool     found = false;
    uint8_t  s_before = 0;   // S as the sequence began
    unsigned stack_cycles = 0;
    unsigned total_cycles = 0;   // release (or rst deassert) through the vector
    [[nodiscard]] uint8_t s_after() const {
        return static_cast<uint8_t>(s_before - stack_cycles);
    }
};

// Runs the core through its own reset out of a scratch memory and reports what
// it did, in the same terms the trace is read in. Nothing here is told what a
// reset ought to look like.
static ResetShape probe_core_reset(uint16_t vec) {
    ResetShape r;
    static uint8_t mem[65536];
    std::memset(mem, 0, sizeof mem);
    mem[0xFFFC] = static_cast<uint8_t>(vec & 0xFF);
    mem[0xFFFD] = static_cast<uint8_t>(vec >> 8);

    Vcpu65c02 dut;
    dut.cyc_en = 1; dut.irq_n = 1; dut.nmi_n = 1; dut.rst = 1; dut.din = 0; dut.clk = 0;
    auto tick = [&] {
        dut.din = mem[dut.addr];
        dut.clk = 0; dut.eval();
        dut.clk = 1; dut.eval();
    };
    for (int i = 0; i < 4; ++i) tick();
    dut.rst = 0;

    bool first = true;
    for (int guard = 0; guard < 32; ++guard) {
        const uint16_t a = static_cast<uint16_t>(dut.addr);
        if (a == 0xFFFC) { r.found = true; break; }
        if ((a & 0xFF00) == 0x0100) {
            if (first) { r.s_before = static_cast<uint8_t>(a & 0xFF); first = false; }
            ++r.stack_cycles;
        }
        ++r.total_cycles;
        tick();
    }
    return r;
}

// A dummy-cycle address difference, grouped by the instruction and the cycle
// within it - which is the granularity the answer actually has. "Opcode $94,
// cycle 3, real $FEA6, this core $0000" is a finding; the same thing listed
// eleven thousand times at eleven thousand addresses is a log file.
struct DummyDiff {
    uint8_t  opcode = 0;
    unsigned cycle = 0;
    uint16_t trace_addr = 0, core_addr = 0;
    uint16_t example_at = 0;   // the opcode's address, for looking it up
    uint64_t count = 0;
};

// One replay attempt at a fixed alignment. Returns how many cycles matched, and
// fills the divergence details.
struct Result {
    uint64_t matched = 0;
    bool     diverged = false;
    std::size_t at = 0;          // trace index of the first mismatch
    uint16_t exp_addr = 0, got_addr = 0;
    bool     exp_rw = true, got_rw = true;
    uint8_t  exp_data = 0, got_data = 0;
    bool     data_mismatch = false;   // a write whose value differed
    bool     hit_gap = false;
    bool     hit_reset = false;   // RES' asserted again: the bounce, or a new press
    bool     halted = false;
    bool     cascaded = false;   // tolerated so many that the run is meaningless
    std::map<uint32_t, DummyDiff> dummies;
    uint64_t tolerated = 0;
};

static Result replay(const Options& opt, std::size_t align_at, int skew, uint8_t seed_s,
                     bool have_s, uint16_t vec, std::size_t limit) {
    Result r;
    Vcpu65c02 dut;
    dut.cyc_en = 1;
    dut.irq_n = 1;
    dut.nmi_n = 1;
    dut.rst = 1;
    dut.din = 0;
    dut.clk = 0;

    auto tick = [&](uint8_t din) {
        dut.din = din;
        dut.clk = 0; dut.eval();
        dut.clk = 1; dut.eval();
    };

    // A real memory for the bring-up phase, rather than a list of bytes handed
    // over one per cycle. The difference matters: a 6502 takes cycles that do
    // not consume an instruction byte - TXS reads the next byte and throws it
    // away, reset reads the stack three times - so anything that feeds a
    // sequence positionally desynchronises on the first of them. Memory does
    // not have that problem, because the core says what it wants.
    static uint8_t mem[65536];
    std::memset(mem, 0, sizeof mem);
    mem[0xFFFC] = static_cast<uint8_t>(vec & 0xFF);
    mem[0xFFFD] = static_cast<uint8_t>(vec >> 8);

    // Seed S by injection. The core has no port for its stack pointer, so the
    // only way in is through the instruction stream - which this harness owns
    // completely, because it IS memory. A JMP at the vector into a scratch
    // page, LDX #S / TXS there, then JMP back to the vector: the core arrives
    // at the same PC the real part did, with the same S.
    //
    // Costs X, which the injection clobbers. On a real machine X after reset is
    // arbitrary anyway, so this trades one unknown for another rather than
    // introducing an error - but a divergence on an X-indexed address before
    // software has loaded X is explained by this, and not by the core.
    const bool seed = have_s && opt.seed_s;
    // Anywhere the vector is not. $0200 is the monitor's input buffer, dead at
    // this point in a reset, and the check keeps a pathological vector from
    // landing on top of the prologue.
    const uint16_t scratch = (vec >= 0x0200 && vec <= 0x0210) ? 0x0300 : 0x0200;
    if (seed) {
        mem[vec]     = 0x4C;                                  // JMP scratch
        mem[vec + 1] = static_cast<uint8_t>(scratch & 0xFF);
        mem[vec + 2] = static_cast<uint8_t>(scratch >> 8);
        mem[scratch]     = 0xA2;  mem[scratch + 1] = seed_s;  // LDX #S
        mem[scratch + 2] = 0x9A;                              // TXS
        mem[scratch + 3] = 0x4C;                              // JMP vec
        mem[scratch + 4] = static_cast<uint8_t>(vec & 0xFF);
        mem[scratch + 5] = static_cast<uint8_t>(vec >> 8);
    }

    // Held in reset for a few cycles, the way the machine is.
    for (int i = 0; i < 4; ++i) tick(0);
    dut.rst = 0;

    // Run the core's own reset out of that memory and stop on the opcode fetch
    // at the vector - the second one when seeding, since the first is the JMP
    // that carries it into the prologue. That fetch is the same instant as the
    // trace's first post-vector cycle, and is where the comparison begins.
    const int want = seed ? 2 : 1;
    int seen = 0;
    bool aligned = false;
    for (int guard = 0; guard < 64; ++guard) {
        if (dut.sync && static_cast<uint16_t>(dut.addr) == vec && ++seen == want) {
            aligned = true;
            break;
        }
        tick(mem[dut.addr]);
    }
    if (!aligned) return r;   // 0 matched; the caller reports it as no alignment

    // The trace index this core's first compared cycle lines up with. Skew
    // exists because the answer to "how many cycles after the vector does the
    // first opcode fetch happen" is a fact about the part, measured here rather
    // than asserted.
    const int64_t base = static_cast<int64_t>(align_at) + skew;
    if (base < 0) return r;
    std::size_t t = static_cast<std::size_t>(base);

    uint8_t  cur_opcode = 0;
    uint16_t cur_at = 0;
    unsigned cur_cycle = 0;

    // ---- lockstep --------------------------------------------------------
    while (t < limit) {
        if (trace::is_break(g_words[t])) { r.hit_gap = true; break; }
        if (!trace::is_event(g_words[t])) { ++t; continue; }
        const trace::Event e = trace::decode(g_words[t]);
        // A cycle with RES' asserted is the machine being reset again; the run
        // this tool is checking is over. Recorded rather than merged into
        // "ran out of trace", because the two mean opposite things about how
        // much the run proved.
        if (trace::in_reset(e)) { r.hit_reset = true; break; }

        const uint16_t got_addr = static_cast<uint16_t>(dut.addr);
        const bool got_rw = dut.rw != 0;

        // Where we are inside the current instruction, tracked off the core's
        // own sync so a difference can be reported as "opcode X, cycle N"
        // rather than as a bare address.
        if (dut.sync) { cur_opcode = e.data; cur_at = e.addr; cur_cycle = 0; }
        else          { ++cur_cycle; }

        if (got_addr != e.addr || got_rw != e.rw) {
            // A read/read mismatch is a cycle whose value BOTH machines throw
            // away, so the two are still in the same architectural state and
            // the run can continue - which is what turns this from "here is the
            // first difference" into "here is the list of them". A mismatch in
            // DIRECTION, or a write landing somewhere else, is a real state
            // difference and stops the run.
            if (r.tolerated < opt.tolerate && got_rw && e.rw) {
                const uint32_t key = (static_cast<uint32_t>(cur_opcode) << 8) |
                                     (cur_cycle & 0xFF);
                DummyDiff& d = r.dummies[key];
                if (d.count == 0) {
                    d.opcode = cur_opcode;
                    d.cycle = cur_cycle;
                    d.trace_addr = e.addr;
                    d.core_addr = got_addr;
                    d.example_at = cur_at;
                }
                ++d.count;
                ++r.tolerated;
                ++r.matched;
                tick(e.data);
                ++t;
                continue;
            }
            if (r.tolerated >= opt.tolerate && opt.tolerate != 0) r.cascaded = true;
            r.diverged = true;
            r.at = t;
            r.exp_addr = e.addr; r.got_addr = got_addr;
            r.exp_rw = e.rw;     r.got_rw = got_rw;
            break;
        }
        if (!e.rw) {
            // Both are writing the same address. The value is the other half of
            // the claim, and a mismatch there is a real difference even though
            // the address agreed.
            const uint8_t got_data = static_cast<uint8_t>(dut.dout);
            if (got_data != e.data) {
                r.diverged = true;
                r.data_mismatch = true;
                r.at = t;
                r.exp_addr = e.addr; r.got_addr = got_addr;
                r.exp_rw = e.rw;     r.got_rw = got_rw;
                r.exp_data = e.data; r.got_data = got_data;
                break;
            }
        }

        ++r.matched;
        if (dut.halted) { r.halted = true; break; }
        if (opt.max_cycles != 0 && r.matched >= opt.max_cycles) break;
        tick(e.data);
        ++t;
    }
    return r;
}

// ---------------------------------------------------------------------------

static void print_context(const Options& opt, std::size_t at, uint16_t got_addr,
                          bool got_rw) {
    const std::size_t lo = at > opt.context ? at - opt.context : 0;
    std::printf("\n  trace cycle   addr  rw  data\n");
    for (std::size_t i = lo; i <= at && i < g_words.size(); ++i) {
        if (trace::is_gap(g_words[i])) {
            std::printf("  %10zu   -- gap of %u events --\n", i, trace::gap_count(g_words[i]));
            continue;
        }
        if (trace::is_skip(g_words[i])) {
            std::printf("  %10zu   -- %u cycles not sent (sparse capture) --\n", i, trace::skip_count(g_words[i]));
            continue;
        }
        const trace::Event e = trace::decode(g_words[i]);
        std::printf("  %10zu   $%04X  %s   $%02X%s\n", i, e.addr, rwc(e.rw), e.data,
                    i == at ? "   <-- the real part did this" : "");
    }
    std::printf("  %10s   $%04X  %s        <-- this core did this\n", "", got_addr,
                rwc(got_rw));
}

static int run_from(const Options& opt, std::size_t align_at, uint16_t vec,
                    std::size_t limit);

// The replay proper: search the alignment, run it, and say what happened.
// Shared by both ways in - aligning on a reset, and aligning on a program -
// because everything after "where does the comparison start" is the same.
static int replay_and_report(const Options& opt, std::size_t align_at, uint8_t seed_s,
                            bool have_s, uint16_t vec, std::size_t limit) {
    // ---- alignment -------------------------------------------------------
    //
    // Measured, not assumed. This core enters its reset at BRK's first stack
    // cycle and skips the two dummy PC reads the real part does, so some
    // offset is expected - but which offset is a fact about the part, and a
    // tool that hard-coded it could not discover it was wrong.
    int best_skew = 0;
    Result best;
    if (opt.skew != INT32_MIN) {
        best_skew = opt.skew;
        best = replay(opt, align_at, best_skew, seed_s, have_s, vec, limit);
    } else {
        bool first = true;
        for (int s = opt.skew_lo; s <= opt.skew_hi; ++s) {
            if (static_cast<int64_t>(align_at) + s < 0) continue;
            if (align_at + static_cast<std::size_t>(static_cast<int64_t>(s)) >= limit) continue;
            const Result r = replay(opt, align_at, s, seed_s, have_s, vec, limit);
            if (first || r.matched > best.matched) {
                best = r;
                best_skew = s;
                first = false;
            }
        }
        std::printf("skew    : %+d cycles matched best, over the search %+d..%+d\n",
                    best_skew, opt.skew_lo, opt.skew_hi);
    }

    if (!best.dummies.empty()) {
        std::printf("\ndummy-cycle address differences, by instruction:\n\n"
                    "  opcode  cycle        real 65C02   this core        seen  first at\n");
        // Sorted by how often each was hit: the common ones are addressing
        // modes, the rare ones are the interesting corners.
        std::vector<const DummyDiff*> ds;
        for (const auto& kv : best.dummies) ds.push_back(&kv.second);
        std::sort(ds.begin(), ds.end(),
                  [](const DummyDiff* a, const DummyDiff* b) { return a->count > b->count; });
        for (const DummyDiff* d : ds) {
            std::printf("    $%02X       %u          $%04X        $%04X   %9llu  $%04X\n",
                        d->opcode, d->cycle, d->trace_addr, d->core_addr,
                        static_cast<unsigned long long>(d->count), d->example_at);
        }
        std::printf("\n  %llu tolerated in total, across %zu distinct (opcode, cycle) "
                    "sites.\n"
                    "  These are cycles whose value both machines discard, so the run "
                    "continued\n  through them - the architectural state never parted "
                    "company.\n",
                    static_cast<unsigned long long>(best.tolerated), best.dummies.size());
    }

    std::printf("\nmatched : %llu cycles in lockstep\n",
                static_cast<unsigned long long>(best.matched));

    if (!best.diverged) {
        if (best.hit_gap) {
            std::printf("stopped : the trace's first gap (or a sparse capture's first SKIP).\n");
        } else if (best.hit_reset) {
            std::printf("stopped : RES' asserted again - the next bounce, or another "
                        "press.\n");
        } else if (best.halted) {
            std::printf("stopped : the core executed STP.\n");
        } else {
            std::printf("stopped : end of the trace.\n");
        }

        // A run has to be long enough to have been able to fail. Reporting
        // "no divergence" over a few dozen cycles is reporting nothing, and
        // the whole reason this floor exists is that the first version of this
        // tool aligned on a bouncing reset, got four cycles, and called it a
        // pass.
        if (best.matched < kMinUsefulRun) {
            std::printf("\nINCONCLUSIVE - %llu cycles is too short to have proved "
                        "anything.\n",
                        static_cast<unsigned long long>(best.matched));
            if (best.hit_reset) {
                std::printf("The run was cut off by another RES' assertion. RES' is not "
                            "debounced, so\none press arrives as several - capture again "
                            "and let the machine run for a\nfew seconds after the last "
                            "bounce, or select a different reset with --reset=N.\n");
            }
            return 2;
        }

        if (g_header.flags & trace::kFlagSyncSynth) {
        std::printf("\n          NOTE: SYNC here is the DRIVING CORE'S own, not the bus's.\n"
                    "          The card had taken the bus, so the real 6502 was disconnected\n"
                    "          and its SYNC line reads zero throughout.  The bit is the same\n"
                    "          signal the core will drive on the real SYNC line once the card\n"
                    "          sits in the CPU socket instead of a slot - logically exact,\n"
                    "          electrically absent.  Every other field was measured on the\n"
                    "          wire, and --from works normally.\n");
    }
    if (g_header.flags & trace::kFlagSelfTest) {
            std::printf("\nPASS - the tool works end to end on a trace it generated. This "
                        "says nothing\nabout the core; only a capture of a real 65C02 "
                        "can.\n");
        } else if (best.tolerated != 0) {
            std::printf("\nDIFFERENCES FOUND - %llu cycles ran without the two machines' "
                        "state parting\ncompany, but %llu of those cycles drove a "
                        "different address. See the table\nabove: each row is a dummy "
                        "cycle where this core and the part disagree.\n",
                        static_cast<unsigned long long>(best.matched),
                        static_cast<unsigned long long>(best.tolerated));
            return 1;
        } else {
            std::printf("\nPASS - %llu cycles, every one of them matching the real "
                        "65C02.\n",
                        static_cast<unsigned long long>(best.matched));
        }
        return 0;
    }

    std::printf("diverged: at trace word %zu\n", best.at);
    if (best.data_mismatch) {
        std::printf("          same address and direction, different value written:\n"
                    "          real $%02X, this core $%02X at $%04X\n",
                    best.exp_data, best.got_data, best.exp_addr);
    } else {
        std::printf("          real 65C02 drove $%04X %s, this core drove $%04X %s\n",
                    best.exp_addr, rwc(best.exp_rw), best.got_addr, rwc(best.got_rw));
    }

    // Name the explanations rather than leaving them to be rediscovered.
    if (best.exp_addr == 0xFFFE || best.exp_addr == 0xFFFF) {
        std::printf("\n          The real part fetched the IRQ/BRK vector. The event word "
                    "carries RES'\n          and nothing else, so an interrupt from a "
                    "peripheral is invisible to this\n          replay - this is almost "
                    "certainly an IRQ, not a difference in the core.\n");
    } else if (best.exp_addr == 0xFFFA || best.exp_addr == 0xFFFB) {
        std::printf("\n          The real part fetched the NMI vector, which the trace "
                    "cannot show coming.\n          Not a difference in the core.\n");
    } else if ((best.exp_addr & 0xFF00) == 0x0100 || (best.got_addr & 0xFF00) == 0x0100) {
        std::printf("\n          A page-one access. If S was not seeded, or was seeded "
                    "and software has\n          since changed it differently, the stacks "
                    "have drifted apart and this\n          is the consequence rather than "
                    "a finding.\n");
    } else if ((best.exp_addr & 0xF000) == 0xC000 || (best.got_addr & 0xF000) == 0xC000) {
        std::printf("\n          An I/O page access. Reading $C0xx has side effects on the "
                    "real machine\n          that the replay reproduces only as the byte "
                    "the trace recorded, so\n          control flow can legitimately part "
                    "company here.\n");
    }

    if (!opt.quiet) print_context(opt, best.at, best.got_addr, best.got_rw);

    std::printf("\nFAIL - see above. A divergence is a difference between this core and "
                "the\npart it stands in for; whether it is a bug depends on which of the "
                "two is\nright, and the notes above say when it is neither.\n");
    return 1;
}

// Aligning on a program: no stack seeding, because a program entered from a
// reset vector sets its own stack pointer before it pushes anything - and the
// trace cannot say what S was mid-run anyway.
static int run_from(const Options& opt, std::size_t align_at, uint16_t vec,
                    std::size_t limit) {
    return replay_and_report(opt, align_at, 0, false, vec, limit);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Options opt;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a.rfind("--trace=", 0) == 0)        opt.path = argv[i] + 8;
        else if (a.rfind("--emit=", 0) == 0)    opt.emit_path = argv[i] + 7;
        else if (a.rfind("--emit-cycles=", 0) == 0) opt.emit_cycles = std::strtoull(argv[i] + 14, nullptr, 10);
        else if (a.rfind("--emit-s=", 0) == 0)  opt.emit_s = std::strtoul(argv[i] + 9, nullptr, 16);
        else if (a.rfind("--skew=", 0) == 0)    opt.skew = std::atoi(argv[i] + 7);
        else if (a.rfind("--skew-lo=", 0) == 0) opt.skew_lo = std::atoi(argv[i] + 10);
        else if (a.rfind("--skew-hi=", 0) == 0) opt.skew_hi = std::atoi(argv[i] + 10);
        else if (a == "--no-seed-s")            opt.seed_s = false;
        else if (a.rfind("--from=", 0) == 0)    opt.from_addr = (int)strtoul(argv[i] + 7, nullptr, 16);
        else if (a.rfind("--from-nth=", 0) == 0) opt.from_nth = strtoul(argv[i] + 11, nullptr, 10);
        else if (a.rfind("--reset=", 0) == 0)   opt.reset_index = std::atoi(argv[i] + 8);
        else if (a.rfind("--tolerate=", 0) == 0) opt.tolerate = std::strtoull(argv[i] + 11, nullptr, 10);
        else if (a.rfind("--context=", 0) == 0) opt.context = std::strtoul(argv[i] + 10, nullptr, 10);
        else if (a.rfind("--max=", 0) == 0)     opt.max_cycles = std::strtoull(argv[i] + 6, nullptr, 10);
        else if (a == "--quiet")                opt.quiet = true;
        else if (a == "--help" || a == "-h") {
            std::printf(
                "usage: trace_replay --trace=FILE [options]\n"
                "  --skew=N       fix the alignment instead of searching for it\n"
                "  --skew-lo=N    low end of the search (default -4)\n"
                "  --skew-hi=N    high end of the search (default 4)\n"
                "  --no-seed-s    do not read S out of the reset stack cycles\n"
                "  --reset=N      replay the Nth reset rather than the settled one\n"
                "  --from=HEX     align on an opcode fetch at this address instead of on a\n"
                "                 reset, for a program the reset only leads TO\n"
                "  --from-nth=N   which occurrence of it (default 0, the first)\n"
                "  --tolerate=N   do not stop at a read/read address mismatch; note it and\n"
                "                 carry on, up to N of them, then report them grouped by\n"
                "                 opcode and cycle. Sound only because a cycle whose value\n"
                "                 both machines discard leaves them in the same state\n"
                "  --context=N    cycles of history around a divergence (default 12)\n"
                "  --max=N        stop after N matched cycles\n"
                "  --quiet        the verdict only\n"
                "\n"
                "  --emit=FILE    write a SELF-TEST trace generated by this same core,\n"
                "                 instead of replaying one. Replaying it exercises this\n"
                "                 tool end to end and proves nothing about the core -\n"
                "                 the core is on both sides of that comparison\n"
                "  --emit-cycles=N  how many cycles to record (default 20000)\n"
                "  --emit-s=HEX     the pre-reset stack pointer (default F6)\n");
            return 0;
        }
    }
    if (!opt.emit_path.empty()) {
        return emit(opt.emit_path, opt.emit_cycles, static_cast<uint8_t>(opt.emit_s));
    }
    if (opt.path.empty()) { std::fprintf(stderr, "need --trace=FILE or --emit=FILE\n"); return 2; }

    std::string err;
    if (!load(opt.path, &err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 2; }

    const std::size_t limit = first_gap();
    std::printf("trace   : %s\n", opt.path.c_str());
    std::printf("          %zu words, %s, %s\n", g_words.size(),
                (g_header.flags & trace::kFlagRealBus) ? "real Apple bus"
                                                       : "SYNTHETIC generator - not a CPU",
                (g_header.flags & trace::kFlagArmedOnReset) ? "armed on RES'"
                                                            : "not armed on RES'");
    if (limit != g_words.size()) {
        std::printf("          replayable up to the first gap at word %zu\n", limit);
    }
    if (g_header.flags & trace::kFlagSelfTest) {
        std::printf("\n          *** SELF-TEST TRACE: generated by this same core. A PASS "
                    "here exercises\n              this tool - the reset search, the S "
                    "recovery, the alignment and the\n              decode - and says "
                    "NOTHING about whether the core is right, because the\n              "
                    "core is on both sides of the comparison. ***\n");
    }
    if ((g_header.flags & trace::kFlagRealBus) == 0) {
        std::printf("\nThis trace is the card's synthetic event generator, which is a "
                    "counter,\nnot a processor. There is nothing here to compare a CPU "
                    "against.\n");
        return 2;
    }

    // ---- aligning on a program, rather than on a reset --------------------
    //
    // A capture of the machine's own reset path can be replayed from the reset.
    // A capture of a PROGRAM cannot, because the reset only leads to it: in
    // between runs the monitor, and DOS, and whatever else - a hundred thousand
    // cycles of code whose flags and registers came out of a reset that does
    // not clear them, so this core and the part disagree about A, X, Y and the
    // carry from the first instruction and there is nothing to be done about
    // it.
    //
    // So align on the program instead. SYNC says exactly where an instruction
    // starts, so "the first opcode fetch at $604A" is unambiguous, and a
    // program that begins by setting up its own registers and stack - which any
    // program entered from a reset vector must - puts both machines in the same
    // state within a few instructions of that point.
    if (opt.from_addr >= 0) {
        const uint16_t want = static_cast<uint16_t>(opt.from_addr);
        std::size_t found = static_cast<std::size_t>(-1);
        unsigned seen_n = 0;
        for (std::size_t i = 0; i < limit; ++i) {
            if (!trace::is_event(g_words[i])) continue;
            const trace::Event e = trace::decode(g_words[i]);
            if (e.sync && e.addr == want) {
                if (seen_n++ == opt.from_nth) { found = i; break; }
            }
        }
        if (found == static_cast<std::size_t>(-1)) {
            std::printf("\nNo opcode fetch at $%04X in this trace%s. The program "
                        "either never ran,\nor ran somewhere else.\n", want,
                        opt.from_nth ? " at that occurrence" : "");
            return 2;
        }
        std::printf("from    : opcode fetch #%u at $%04X, word %zu\n",
                    opt.from_nth, want, found);
        std::size_t clean = 0;
        for (std::size_t k = found; k < limit; ++k) {
            if (trace::is_break(g_words[k])) break;
            if (trace::is_event(g_words[k]) && trace::in_reset(trace::decode(g_words[k]))) break;
            ++clean;
        }
        std::printf("          %zu cycles before the next RES' or gap\n", clean);
        return run_from(opt, found, want, limit);
    }

    const std::vector<TraceReset> resets = find_all_resets(limit);
    if (resets.empty()) {
        std::printf("\nNo $FFFC/$FFFD fetch anywhere in this trace, so the machine never "
                    "completed a\nreset in it and there is nothing to align to. Capture "
                    "again and press\nCtrl-Reset once the link is up.\n");
        return 2;
    }

    // RES' is a switch on a wire with nothing debouncing it, so one press
    // arrives as several assertions microseconds apart. Pick the reset with the
    // longest run behind it - the one after the bus settled - rather than the
    // first, which the next bounce cuts off after a handful of cycles.
    std::size_t pick = 0;
    for (std::size_t i = 1; i < resets.size(); ++i) {
        if (resets[i].clean_run > resets[pick].clean_run) pick = i;
    }
    if (opt.reset_index >= 0) {
        if (static_cast<std::size_t>(opt.reset_index) >= resets.size()) {
            std::printf("\n--reset=%d but this trace has only %zu.\n", opt.reset_index,
                        resets.size());
            return 2;
        }
        pick = static_cast<std::size_t>(opt.reset_index);
    }
    const TraceReset& R = resets[pick];
    const uint16_t vec = R.vec;
    const std::size_t vfetch = R.vfetch;
    const std::size_t align_at = R.align_at;

    std::printf("resets  : %zu reset sequence(s) in the trace\n", resets.size());
    {
        // Bounce is worth showing rather than silently coping with: it is a
        // property of the machine, and a capture with only bouncy short runs is
        // one to retake rather than to squeeze a verdict out of.
        const unsigned show = static_cast<unsigned>(resets.size() < 12 ? resets.size() : 12);
        for (unsigned i = 0; i < show; ++i) {
            std::printf("          [%u] word %-9zu vector $%04X  %9zu clean cycles%s\n",
                        i, resets[i].vfetch, resets[i].vec, resets[i].clean_run,
                        i == pick ? "   <-- replaying this one" : "");
        }
        if (show < resets.size()) {
            std::printf("          ... %zu more\n", resets.size() - show);
        }
        unsigned bounced = 0;
        for (const TraceReset& t : resets) if (t.clean_run < 1000) ++bounced;
        if (bounced != 0 && resets.size() > 1) {
            std::printf("          %u of them run for under 1000 cycles - RES' is not "
                        "debounced, so one\n          press of Ctrl-Reset lands as "
                        "several assertions and only the last\n          one has a run "
                        "behind it.\n", bounced);
        }
    }
    std::printf("vector  : word %zu, reset PC $%04X\n", vfetch, vec);

    // ---- the stack pointer, inferred from BOTH sides ---------------------
    //
    // Reset does not load S, it decrements it, so the value a machine leaves
    // reset with is a fact about the hour of software that ran before the
    // capture - and it differs between the traced machine and this core no
    // matter how correct the core is. Rather than assume either side's
    // behaviour, both resets are read off their own buses in the same terms and
    // the difference is compensated.
    ResetShape tr;
    tr.found = R.have_s;
    tr.s_before = R.s_before;
    tr.stack_cycles = R.stack_cycles;
    // Cycles from this reset's release to its vector. Found by walking back to
    // the last asserted cycle rather than from the trace's first release, which
    // with bounce is a different reset entirely.
    {
        std::size_t j = vfetch;
        while (j > 0) {
            if (!trace::is_event(g_words[j - 1])) break;
            if (trace::in_reset(trace::decode(g_words[j - 1]))) break;
            --j;
        }
        tr.total_cycles = static_cast<unsigned>(vfetch - j);
    }

    const ResetShape core = probe_core_reset(vec);

    if (tr.found) {
        std::printf("stack   : traced part  reset from S $%02X, %u stack cycle(s), "
                    "%u cycles to the vector -> S $%02X\n",
                    tr.s_before, tr.stack_cycles, tr.total_cycles, tr.s_after());
    } else {
        std::printf("stack   : traced part  no recognisable reset stack sequence\n");
    }
    if (core.found) {
        std::printf("          this core    reset from S $%02X, %u stack cycle(s), "
                    "%u cycles to the vector -> S $%02X\n",
                    core.s_before, core.stack_cycles, core.total_cycles, core.s_after());
    } else {
        std::printf("          this core    never reached the vector\n");
    }

    const uint8_t seed_s = tr.s_after();
    const bool have_s = tr.found;

    // A difference in the SHAPE of the reset is a finding in its own right, and
    // separate from the compensation. Compensating for it and saying nothing
    // would hide exactly the kind of difference this tool exists to surface.
    if (tr.found && core.found && tr.stack_cycles != core.stack_cycles) {
        std::printf("\n          *** RESET SHAPE DIFFERS: the traced part spends %u stack "
                    "cycle(s) on reset,\n              this core spends %u. S therefore "
                    "lands %d byte(s) apart from the same\n              starting value, "
                    "and the reset sequence is %d cycle(s) shorter here.\n"
                    "              Compensated below so the run can proceed - but this is "
                    "a real\n              difference between the core and the part, not "
                    "an artefact. ***\n",
                    tr.stack_cycles, core.stack_cycles,
                    static_cast<int>(tr.stack_cycles) - static_cast<int>(core.stack_cycles),
                    static_cast<int>(tr.total_cycles) - static_cast<int>(core.total_cycles));
    } else if (tr.found && core.found && tr.total_cycles != core.total_cycles) {
        std::printf("\n          Note: same stack behaviour, but the traced part takes %u "
                    "cycles from RES'\n          release to the vector and this core takes "
                    "%u. Alignment is on the vector,\n          so the run is unaffected - "
                    "but for a CPU socket the difference is real.\n",
                    tr.total_cycles, core.total_cycles);
    }

    if (have_s) {
        std::printf("\ncompens.: seeding this core with S $%02X%s\n", seed_s,
                    opt.seed_s ? " so both machines start the run with the same stack"
                               : " DISABLED by --no-seed-s");
    } else {
        std::printf("\ncompens.: S cannot be inferred from this trace - expect a "
                    "divergence at the\n          first stack access\n");
    }


    return replay_and_report(opt, align_at, seed_s, have_s, vec, limit);
}
