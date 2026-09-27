// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// rvvm_run - the RISC-V engine (rtl/gs/rv_engine.sv, docs/REQ_RVVM.md) behind
// its window, driven by its 65816 VM (apple/rvvm/rvengine.s) on the card's own
// 65816: the Verilated cpu65816 against a flat 16 MB, no caches, no chipset.
// One loop step is one 65816 cycle.  There is no software VM on riscv_v2 (the
// engine addresses 32 MB, the 65816 only the lower 16): an image whose header
// says the software VM's version is refused.
//
// THE STAGE.  The VM image goes into its own bank (default $F1, our ROM space); its header
// (below) says where its entry and its dispatch point are.  The guest's flat
// image goes to --load.  A bank-0 stub at $0800 comes out of reset,
// goes native and JMLs to the VM.  The VM's console is a pair of sim ports in
// bank $EF; it ends a run with STP, leaving the verdict in its direct page.
//
// THE ADDRESS MODEL IS THE IDENTITY (docs/REQ_RVVM.md section 9): a guest
// address is the 65816's 24-bit address.  The guest image is loaded at
// --load (default $800000, the RAM the IIgs never uses) and entered there;
// an address at or above $0100_0000 or in the null guard ($000000-$0000FF)
// faults, and ECALL peek/poke reach anywhere below $0100_0000.
//
// THE REFERENCE.  A small RV32IM_Zba_Zbb model written from the spec, with
// the VM's execution environment (flat guest space 0..size, the ECALL
// services, the trap causes).  --ref runs it in LOCKSTEP: at every dispatch
// the VM's pc and 32 registers must equal the model's, and at the end the
// verdict, the console output and all of guest memory must too.  --ref-only
// runs the model alone (fast; proves the model on riscv-tests by itself).
//
//   rvvm_run --hex=UCODE.hex --vm=rvvm.bin --guest=prog.bin
//            [--load=ADDR] [--pc=N] [--sp=N] [--input=TEXT]
//            [--ref | --ref-only] [--prof] [--trace=N] [--max-cycles=N]
//            [--expect-trap=CAUSE]
//
// Exit status: 0 when the guest exits 0 (or, with --expect-trap, stops on that
// trap cause) and nothing failed, 1 otherwise.
//
// THE APPLICATION MODE (--app=STUB.bin, docs/RVV2_INTEROP.md rung I2): no guest;
// the stub of a GS/OS application (apple/rvvm/stub, raw bytes) is entered as the
// GS/OS loader would - at $03:1000, native, A = the user ID, D/S = a direct page /
// stack segment at $00:2000-$2FFF - and GS/OS is a STAND-IN: the toolbox's
// dispatcher ($E1:0000) and GS/OS's entry ($E1:00A8) are 65816 trampolines that
// hand S and the call number to this harness through ports ($EF:FFF0-$EF:FFF9);
// the harness does the call against the flat memory, takes the parameters (or the
// inline block) off the stack, and hands back the new S and the error.  The run
// ends at QuitGS, and the verdict is the lifecycle's: the calls in their order
// and with their arguments, the registration table in $EE and the trace at
// $EE:FF00, enhanced video left off, the stack balanced, and no write anywhere
// the lifecycle does not own.  --stale first leaves a dead application in the
// registration table (a bank of the upper half, enhanced video on) to reclaim.
// Rung I3: the runner is built with the engine's memory side (-DRVVM_MEM=1,
// sim/rvvm_sys.sv MEM=1: rv_mem on the card's map, sim/l2_model.h behind it, the
// whole 32 MB); --image=FILE is the program's file GS/OS serves (Open, GetEOF,
// Read as a DMA would write it - the engine's rows invalidated - Close, through
// the stack entry $E1:00B0), which must land in the upper half byte for byte, and
// reach the host's mirror of it by the engine's own 0xB records.
// --expect-code=N: the lifecycle's exit code (the runtime's own failures).
// --launches=N: the application launched N times on the one engine (the Finder
// would; nothing resets the engine in between), every launch checked.

#include "Vrvvm_sys.h"
#include "Vrvvm_sys___024root.h"
#include "verilated.h"
#include "rv_ref.h"
#include "l2_model.h"

#include <algorithm>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <string>
#include <vector>

// ---- the VM's contract (apple/rvvm/rvvm.s keeps the same numbers) ----------
// Header, at the VM bank's offset 0.
static const unsigned H_MAGIC = 0, H_VERSION = 4, H_ENTRY = 6, H_DISPATCH = 8,
                      H_PC = 12, H_SP = 16;
static const unsigned VM_VERSION = 2;          // rvvm.s, the software VM
static const unsigned VM_VERSION_ENGINE = 3;   // rvengine.s, the RISC-V engine's VM
// Direct page (D = 0).
static const unsigned DP_REGS = 0x00;     // x0..x31, 4 bytes each
static const unsigned DP_IW = 0x84;       // the instruction word being executed
static const unsigned DP_PCP = 0x88;      // the pc as a 24-bit long pointer
static const unsigned DP_CODE = 0xC0;     // exit code (32)
static const unsigned DP_STATUS = 0xC4;   // 0 running, 1 exit, 2 trap
static const unsigned DP_CAUSE = 0xC6;    // trap cause (below)
static const unsigned DP_TVAL = 0xC8;     // trap value (32)
// Sim ports.
static const unsigned PORT_PUTC = 0xEFFFE0, PORT_GETC = 0xEFFFE1, PORT_AVAIL = 0xEFFFE2;
static const unsigned PORT_CYC = 0xEFFFE4;   // 8 bytes, latched when the first is read

// ---- the 65816 stage ---------------------------------------------------------
#ifndef RVVM_MEM
#define RVVM_MEM 0      // sim/run_rv_app.sh builds the runner with the engine's memory side (-DRVVM_MEM=1)
#endif
static Vrvvm_sys *dut;   // sim/rvvm_sys.sv: the 65816 and the RISC-V engine
#define CPU(x) dut->rootp->rvvm_sys__DOT__u_cpu__DOT__##x
#define ENG(x) dut->rootp->rvvm_sys__DOT__u_eng__DOT__u_core__DOT__##x
static std::vector<unsigned> fetch_word;
static std::vector<unsigned char> mem(1u << 24, 0);

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static bool load_fetch_word(const char *hex) {
    // The FETCH microinstruction is the hex's last line (sim/cpu816_trace_main.cpp).
    FILE *f = fopen(hex, "r"); if (!f) return false;
    char line[128], last[128] = "";
    while (fgets(line, sizeof line, f)) if (line[0] != '\n') strcpy(last, line);
    fclose(f);
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

static uint32_t rd32(unsigned a) { return mem[a] | (mem[a + 1] << 8) | (mem[a + 2] << 16) | (uint32_t(mem[a + 3]) << 24); }
static unsigned rd16(unsigned a) { return mem[a] | (mem[a + 1] << 8); }

static size_t load_file(const char *path, std::vector<unsigned char> &into, size_t at, size_t max) {
    FILE *f = fopen(path, "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    size_t n = fread(&into[at], 1, max, f);
    if (fgetc(f) != EOF) { fprintf(stderr, "%s: larger than %zu bytes\n", path, max); exit(2); }
    fclose(f);
    return n;
}

static std::string unescape(const std::string &s) {
    std::string o;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '\\' && i + 1 < s.size()) {
            char c = s[++i];
            o += c == 'n' ? '\n' : c == 't' ? '\t' : c == 'r' ? '\r' : c;
        } else o += s[i];
    }
    return o;
}

static void dump_regs(const char *who, const uint32_t *x, uint32_t pc) {
    printf("%s pc=%08x\n", who, pc);
    for (int i = 0; i < 32; i++) printf("  %-4s=%08x%s", abi[i], x[i], (i % 4 == 3) ? "\n" : "");
}

// ---- the application mode: a GS/OS stand-in (docs/RVV2_INTEROP.md, rungs I2-I3) ------
static const unsigned APP_STUB = 0x031000;              // where the "loader" put the stub
static const unsigned APP_DP = 0x2000, APP_DP_END = 0x2FFF;   // its ~Direct segment
static const unsigned APP_UID = 0x1002;
static const unsigned SC_S = 0xEFFFF0, SC_CALL = 0xEFFFF2, SC_GS = 0xEFFFF4,
                      SC_SOUT = 0xEFFFF6, SC_ERR = 0xEFFFF8, SC_GSS = 0xEFFFFA;
static const unsigned TRAMPS = 0xE1F000;                // the trampolines the entry points JML to
static const unsigned HEAP = 0x060000, MPTRS = 0x05F000, DPAGE_H = 0x05FF00;
static const unsigned REG = 0xEE0000, TRACE = 0xEEFF00, EV_CTL = 0xE20000;
static const unsigned HI = 0x1000000, SPACE_APP = 0x2000000;

static void wr16(unsigned a, unsigned v) { mem[a] = uint8_t(v); mem[a + 1] = uint8_t(v >> 8); }
static void wr32(unsigned a, uint32_t v) { wr16(a, v & 0xFFFF); wr16(a + 2, v >> 16); }

struct AppCall { std::string name; std::vector<uint32_t> args; unsigned err = 0; };

static int run_app(const char *hex, const char *vm, unsigned vm_bank, const char *stub_path, bool stale,
                   const char *image_path, long expect_code, unsigned launches, unsigned long long max_cycles) {
#if !RVVM_MEM
    (void)hex; (void)vm; (void)vm_bank; (void)stub_path; (void)stale; (void)image_path; (void)expect_code; (void)launches; (void)max_cycles;
    fprintf(stderr, "--app= needs the runner built with the engine's memory side (sim/run_rv_app.sh)\n");
    return 2;
#else
    mem.assign(SPACE_APP + 8, 0);                   // the engine's 32 MB; the 65816 sees the lower 16
    const unsigned vmb = vm_bank << 16;
    load_file(vm, mem, vmb, 0x10000);
    if (memcmp(&mem[vmb], "RVVM", 4) != 0) { fprintf(stderr, "%s: no RVVM header\n", vm); return 2; }
    const size_t stub_len = load_file(stub_path, mem, APP_STUB, 0x10000 - (APP_STUB & 0xFFFF));
    if (!load_fetch_word(hex)) { fprintf(stderr, "cannot read %s\n", hex); return 2; }
    std::vector<uint8_t> image;                     // the program's file, as GS/OS would read it
    if (image_path) {
        FILE *f = fopen(image_path, "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", image_path); return 2; }
        int c; while ((c = fgetc(f)) != EOF) image.push_back(uint8_t(c));
        fclose(f);
    }

    // The stub's header, read as the runtime reads it: its tool list is what
    // StartUpTools must be handed, its image name what Open must be asked for.
    unsigned hdr = 0;
    for (size_t i = 0; i + 4 <= stub_len; i++)
        if (!memcmp(&mem[APP_STUB + i], "RVAP", 4)) { hdr = APP_STUB + unsigned(i); break; }
    if (!hdr) { fprintf(stderr, "%s: no RVAP header\n", stub_path); return 2; }
    const unsigned h_flags = rd16(hdr + 6), h_vmode = rd16(hdr + 8), h_bounce = rd16(hdr + 10);
    const unsigned list = hdr + rd16(hdr + 14), ntools = rd16(list);
    std::vector<uint32_t> want_tools;
    for (unsigned i = 0; i < ntools; i++) want_tools.push_back(rd32(list + 2 + 4 * i));
    const unsigned name_at = hdr + rd16(hdr + 16);
    const std::string image_name(reinterpret_cast<const char *>(&mem[name_at + 2]), rd16(name_at));

    // The machine as the loader leaves it: the stub entered native, 16-bit, with
    // A = the user ID and D/S on its direct page / stack segment.
    const unsigned char boot[] = {
        0x18, 0xFB, 0xC2, 0x30,                         // CLC XCE REP #$30
        0xA9, APP_DP & 0xFF, APP_DP >> 8, 0x5B,         // LDA #dp TCD
        0xA9, APP_DP_END & 0xFF, APP_DP_END >> 8, 0x1B, // LDA #end TCS
        0xA9, APP_UID & 0xFF, APP_UID >> 8,             // LDA #uid
        0x5C, APP_STUB & 0xFF, (APP_STUB >> 8) & 0xFF, APP_STUB >> 16,   // JML stub
    };
    memcpy(&mem[0x000800], boot, sizeof boot);
    mem[0x00FFFC] = 0x00; mem[0x00FFFD] = 0x08;
    // The entry points JML to trampolines: REP #$30, S and the call to the
    // harness, the new S and the error back, C = an error, RTL.
    auto tramp = [&](unsigned entry, unsigned at, unsigned trigger) {
        const unsigned char j[] = {0x5C, uint8_t(at), uint8_t(at >> 8), uint8_t(at >> 16)};
        memcpy(&mem[entry], j, sizeof j);
        const unsigned char t[] = {
            0xC2, 0x30, 0x3B,                                   // REP #$30 TSC
            0x8F, SC_S & 0xFF, (SC_S >> 8) & 0xFF, SC_S >> 16,  // STA SC_S
            0x8A,                                               // TXA
            0x8F, uint8_t(trigger), uint8_t(trigger >> 8), uint8_t(trigger >> 16),   // STA trigger
            0xAF, SC_SOUT & 0xFF, (SC_SOUT >> 8) & 0xFF, SC_SOUT >> 16, 0x1B,        // LDA SC_SOUT TCS
            0xAF, SC_ERR & 0xFF, (SC_ERR >> 8) & 0xFF, SC_ERR >> 16,                 // LDA SC_ERR
            0xC9, 0x01, 0x00, 0x6B,                                                  // CMP #1 RTL
        };
        memcpy(&mem[at], t, sizeof t);
    };
    tramp(0xE10000, TRAMPS + 0x00, SC_CALL);        // the toolbox's dispatcher
    tramp(0xE100A8, TRAMPS + 0x40, SC_GS);          // GS/OS, inline
    tramp(0xE100B0, TRAMPS + 0x80, SC_GSS);         // GS/OS, the stack entry
    for (unsigned a = APP_DP; a <= APP_DP_END; a++) mem[a] = 0xA5;   // the stack's high-water mark
    if (stale) {   // a dead application: registered, one upper bank, enhanced video on
        memcpy(&mem[REG], "RVRG", 4); wr16(REG + 4, 1);
        wr16(REG + 6, 0x3003); wr16(REG + 8, 0x3003); wr32(REG + 10, 0x123400);
        wr16(REG + 0x100 + 2 * 5, 0x3003);
        mem[EV_CTL] = 1;
    }

    dut = new Vrvvm_sys;
    dut->irq_n = 1; dut->nmi_n = 1; dut->cyc_en = 1; dut->i_din = 0; dut->d_din = 0; dut->inval = 0;
    dut->rst = 1; tick(); tick(); dut->rst = 0; dut->eval();

    unsigned long long cycles = 0;
    std::mt19937 rng(7);
    L2Model<Vrvvm_sys> l2(mem, rng, cycles);
    std::vector<uint8_t> mirror(mem.begin() + HI, mem.begin() + SPACE_APP);   // the host's upper half: records only
    unsigned long long recs = 0;
    bool inval_next = false;
    // The program as the loader left it: memory at its first instruction (on
    // whatever clock it retires - the engine runs while the 65816 waits on RUN),
    // before it relocates itself and clears its bss.
    uint32_t entered_at = 0;
    bool entered_same = false;
    auto app_tick = [&]() {
        l2.pre_edge(dut);
        dut->inval = inval_next; inval_next = false;
        dut->rec_take = dut->rec_v;
        if (dut->rec_v) {
            const uint64_t r = dut->rec;
            const uint32_t w0 = uint32_t(r), data = uint32_t(r >> 32);
            const uint32_t a = (w0 & 0x7FFFFFu) << 2;
            for (int i = 0; i < 4; i++)
                if (((w0 >> (24 + i)) & 1) && a + i >= HI) mirror[a + i - HI] = uint8_t(data >> (8 * i));
            recs++;
        }
        dut->clk = 1; dut->eval();
        l2.post_edge(dut);
        dut->clk = 0; dut->eval();
        if (dut->retired && !entered_at && ENG(pc_q) >= HI) {
            entered_at = ENG(pc_q);
            entered_same = entered_at + image.size() <= SPACE_APP &&
                           !memcmp(&mem[entered_at], image.data(), image.size());
        }
    };

    std::string fail;
    char msg[512];
    std::vector<AppCall> calls;
    unsigned sc_s = 0, sc_sout = 0, sc_err = 0;
    std::vector<unsigned> quit_s;                   // S at each QuitGS
    bool quit = false;
    unsigned hp = HEAP, nmp = 0;
    struct Block { uint32_t ptr, size; unsigned uid; bool live; };
    std::map<uint32_t, Block> handles;
    uint32_t tools_ref = 0;
    unsigned low_water = APP_DP_END + 1;
    long ev_enable_at = -1, ev_commit_at = -1;
    unsigned ev_enable = 0xFF;
    unsigned stray = 0;
    bool open = false;
    size_t fpos = 0;


    // A toolbox call: X = the call number, S as the dispatcher saw it (the
    // return address at S+1, the parameters from S+4, the last pushed first).
    // The numbers and parameter sizes are read off System 6.0.1's own Tool
    // Locator on the machine (2026-09-26: StartUpTools $1801 takes 8 bytes and
    // returns a long, ShutDownTools $1901 takes 6), never recalled - a stand-in
    // written from memory agreed with a runtime written from the same memory,
    // and both were wrong.
    auto tool = [&](unsigned num) {
        const unsigned P = sc_s + 4;
        unsigned npop = 0, err = 0;
        AppCall c;
        switch (num) {
        case 0x0201: c.name = "TLStartUp"; break;
        case 0x0301: c.name = "TLShutDown"; break;
        case 0x0202: c.name = "MMStartUp"; wr16(P, APP_UID); break;
        case 0x0302: c.name = "MMShutDown"; c.args = {rd16(P)}; npop = 2; break;
        case 0x0902: {
            c.name = "NewHandle";
            const uint32_t size = rd32(P + 8);
            const unsigned uid = rd16(P + 6), attr = rd16(P + 4);
            c.args = {size, uid, attr};
            npop = 12;
            if (attr & 0x0004) hp = (hp + 0xFF) & ~0xFFu;
            if ((attr & 0x0010) && (hp >> 16) != ((hp + size - 1) >> 16)) hp = (hp + 0xFFFF) & ~0xFFFFu;
            const uint32_t mp = MPTRS + 8 * nmp++;
            wr32(mp, hp);
            handles[mp] = {hp, size, uid, true};
            wr32(P + 12, mp);
            c.args.push_back(mp);
            hp += size;
            break;
        }
        case 0x1002: {
            c.name = "DisposeHandle";
            const uint32_t h = rd32(P);
            c.args = {h};
            npop = 4;
            auto it = handles.find(h);
            if (it == handles.end() || !it->second.live) { err = 0x0206; snprintf(msg, sizeof msg, "DisposeHandle of $%06X: not a live handle\n", h); fail += msg; }
            else it->second.live = false;
            break;
        }
        case 0x1801: {
            c.name = "StartUpTools";
            const uint32_t ref = rd32(P);
            const unsigned desc = rd16(P + 4), uid = rd16(P + 6);
            c.args = {uid, desc, ref};
            npop = 8;
            if (desc != 0) { snprintf(msg, sizeof msg, "StartUpTools: refDesc %u, want 0 (a pointer)\n", desc); fail += msg; }
            if (rd16(ref) != 0) { snprintf(msg, sizeof msg, "StartUpTools: record flags $%04X, want 0\n", rd16(ref)); fail += msg; }
            if (rd16(ref + 2) != h_vmode) { snprintf(msg, sizeof msg, "StartUpTools: video mode $%04X, the header says $%04X\n", rd16(ref + 2), h_vmode); fail += msg; }
            std::vector<uint32_t> got;
            for (unsigned i = 0, n = rd16(ref + 10); i < n && i < 64; i++) got.push_back(rd32(ref + 12 + 4 * i));
            if (got != want_tools) { snprintf(msg, sizeof msg, "StartUpTools: %zu tools, not the header's %zu\n", got.size(), want_tools.size()); fail += msg; }
            wr16(ref + 4, 0);            // resFileID
            wr32(ref + 6, DPAGE_H);      // dPageHandle: ShutDownTools reads it back
            wr32(P + 8, ref);
            tools_ref = ref;
            break;
        }
        case 0x1901: {
            c.name = "ShutDownTools";
            const uint32_t ref = rd32(P);
            const unsigned desc = rd16(P + 4);
            c.args = {desc, ref};
            npop = 6;
            if (desc != 0 || ref != tools_ref) { snprintf(msg, sizeof msg, "ShutDownTools(%u, $%06X): not StartUpTools' record $%06X\n", desc, ref, tools_ref); fail += msg; }
            else if (rd32(ref + 6) != DPAGE_H) { snprintf(msg, sizeof msg, "ShutDownTools: the record's direct page handle is $%06X, StartUpTools wrote $%06X\n", rd32(ref + 6), DPAGE_H); fail += msg; }
            break;
        }
        default:
            snprintf(msg, sizeof msg, "the stand-in has no toolbox call $%04X\n", num);
            fail += msg;
            err = 0x0002;
            c.name = "?";
        }
        c.err = err;
        calls.push_back(c);
        for (int i = 3; i >= 1; i--) mem[sc_s + npop + i] = mem[sc_s + i];   // the return address, over the parameters
        sc_sout = sc_s + npop;
        sc_err = err;
    };
    // A class-1 GS/OS call on its parameter block: the ones the runtime makes.
    // Read writes the buffer as a DMA would (not through the 65816): the
    // engine's rows are invalidated after it, as gs_top does for DMA.
    auto gs_class1 = [&](unsigned num, uint32_t pb, AppCall &c) -> unsigned {
        c.args = {num, pb};
        const unsigned pcount = rd16(pb);
        switch (num) {
        case 0x2010: {
            c.name = "Open";
            const uint32_t path = rd32(pb + 4) & 0xFFFFFF;
            const std::string asked(reinterpret_cast<const char *>(&mem[path + 2]), rd16(path));
            c.args.push_back(pcount >= 3 ? rd16(pb + 8) : 0);
            if (pcount < 2) return 0x0004;
            if (!image_path || asked != image_name) return 0x0046;   // fileNotFound
            if (open) { fail += "Open: the program's file is already open\n"; return 0x0050; }
            if (pcount >= 3 && rd16(pb + 8) != 1) { snprintf(msg, sizeof msg, "Open: requestAccess %u, want 1 (read)\n", rd16(pb + 8)); fail += msg; }
            open = true; fpos = 0;
            wr16(pb + 2, 1);
            return 0;
        }
        case 0x2019:
            c.name = "GetEOF";
            if (!open || rd16(pb + 2) != 1) return 0x0043;             // invalidRefNum
            wr32(pb + 4, uint32_t(image.size()));
            return 0;
        case 0x2012: {
            c.name = "Read";
            if (!open || rd16(pb + 2) != 1) return 0x0043;
            const uint32_t buf = rd32(pb + 4) & 0xFFFFFF, want = rd32(pb + 8);
            const size_t n = std::min<size_t>(want, image.size() - fpos);
            c.args.push_back(uint32_t(n));
            if (want != h_bounce) { snprintf(msg, sizeof msg, "Read of %u bytes: not the bounce buffer's %u\n", want, h_bounce); fail += msg; }
            memcpy(&mem[buf], image.data() + fpos, n);
            fpos += n;
            wr32(pb + 12, uint32_t(n));
            inval_next = true;
            return n == 0 ? 0x004C : 0;                                // eofEncountered
        }
        case 0x2014:
            c.name = "Close";
            if (!open || rd16(pb + 2) != 1) return 0x0043;
            open = false;
            return 0;
        default:
            c.name = "?";
            snprintf(msg, sizeof msg, "the stand-in has no GS/OS call $%04X\n", num);
            fail += msg;
            return 0x0001;
        }
    };
    // GS/OS inline: JSL $E100A8, then the call number and the parameter block.
    auto gsos_inline = [&]() {
        const uint32_t ret = mem[sc_s + 1] | (mem[sc_s + 2] << 8) | (mem[sc_s + 3] << 16);
        const unsigned num = rd16(ret + 1);
        const uint32_t pb = rd32(ret + 3) & 0xFFFFFF;
        AppCall c;
        sc_sout = sc_s;
        uint32_t back = ret + 6;                    // past the inline block
        if (num == 0x2029) {
            c.name = "QuitGS";
            c.args = {num, pb};
            if (rd16(pb) != 0) { snprintf(msg, sizeof msg, "QuitGS: pCount %u, want 0\n", rd16(pb)); fail += msg; }
            quit_s.push_back(sc_s);
            sc_err = 0;
            // launched again, as the Finder would - on the same engine, which
            // nothing resets between applications - or the run is over
            if (quit_s.size() < launches) back = 0x0007FF;   // RTL -> the boot stub at $0800
            else quit = true;
        } else sc_err = gs_class1(num, pb, c);
        c.err = sc_err;
        for (int i = 0; i < 3; i++) mem[sc_s + 1 + i] = uint8_t(back >> (8 * i));
        calls.push_back(c);
    };
    // GS/OS's stack entry: the call number at S+4, the parameter block at S+6;
    // GS/OS takes both off.
    auto gsos_stack = [&]() {
        AppCall c;
        sc_err = gs_class1(rd16(sc_s + 4), rd32(sc_s + 6) & 0xFFFFFF, c);
        c.err = sc_err;
        for (int i = 3; i >= 1; i--) mem[sc_s + 6 + i] = mem[sc_s + i];
        sc_sout = sc_s + 6;
        calls.push_back(c);
    };

    // What the 65816 may write: its direct page and stack, the low block, the
    // registration table and the trace, enhanced video's two control bytes, the
    // stand-in's ports - and the engine's window.
    auto owned = [&](unsigned a) {
        if (a >= APP_DP && a <= APP_DP_END) return true;
        if (a >= REG && a < REG + 0x300) return true;
        if (a >= TRACE && a < TRACE + 0x100) return true;
        if (a == EV_CTL || a == EV_CTL + 1) return true;
        if (a >= SC_S && a < SC_GSS + 2) return true;
        for (auto &h : handles) if (h.second.live && a >= h.second.ptr && a < h.second.ptr + h.second.size) return true;
        return false;
    };

    while (!dut->halted && !quit) {
        if (cycles >= max_cycles) { fail += "runaway: no QuitGS in " + std::to_string(max_cycles) + " cycles\n"; break; }
        const unsigned addr = dut->addr, rw = dut->rw;
        unsigned char din = 0;
        if (rw && (dut->vda || dut->vpa)) {
            if (dut->vda && addr >= SC_SOUT && addr < SC_SOUT + 2) din = uint8_t(sc_sout >> (8 * (addr - SC_SOUT)));
            else if (dut->vda && addr >= SC_ERR && addr < SC_ERR + 2) din = uint8_t(sc_err >> (8 * (addr - SC_ERR)));
            else din = mem[addr];
        }
        if (dut->vpa) { dut->i_din = din; dut->d_din = 0; } else { dut->d_din = din; dut->i_din = 0; }
        dut->eval();
        if (dut->win_sel) {
            while (dut->win_stall) {
                dut->cyc_en = 0; app_tick(); cycles++;
                if (cycles >= max_cycles) break;
            }
            dut->cyc_en = 1;
            if (rw) dut->d_din = dut->win_rdata;
            dut->eval();
        }
        if (!rw && dut->vda) {
            const unsigned char v = dut->dout;
            if (addr == SC_S) sc_s = (sc_s & 0xFF00) | v;
            else if (addr == SC_S + 1) sc_s = (sc_s & 0xFF) | (v << 8);
            else if (addr == SC_CALL) sc_err = v;                                   // the call's low byte, for a moment
            else if (addr == SC_CALL + 1) tool(sc_err | (v << 8));
            else if (addr == SC_GS + 1) gsos_inline();
            else if (addr == SC_GSS + 1) gsos_stack();
            if (dut->win_sel) {}
            else if (!owned(addr)) {
                if (!stray++) { snprintf(msg, sizeof msg, "a write the lifecycle does not own: $%02X to $%06X (pc $%02X/%04X)\n", v, addr, CPU(pbr), CPU(pc)); fail += msg; }
            }
            else mem[addr] = v;
            if (addr == EV_CTL) { ev_enable = v; ev_enable_at = long(cycles); }
            if (addr == EV_CTL + 1) ev_commit_at = long(cycles);
            if (addr >= APP_DP + 0x100 && addr <= APP_DP_END && addr < low_water) low_water = addr;
        }
        app_tick();
        cycles++;
    }

    // The verdict.
    std::string seq;
    for (auto &c : calls) seq += (seq.empty() ? "" : " ") + c.name;
    printf("app: %s\n", seq.c_str());
    // THE ORDER when the program loads: every Read of the file - a chunk at a
    // time, then one more that reads 0 - and Close at its end, before the tools
    // go down.
    std::string one = "TLStartUp MMStartUp NewHandle StartUpTools";
    const long code_want = expect_code;
    if (code_want == 0) {
        one += " Open GetEOF";
        for (size_t k = 0; k <= (image.size() + h_bounce - 1) / h_bounce; k++) one += " Read";
        one += " Close";
    }
    one += " ShutDownTools DisposeHandle MMShutDown TLShutDown QuitGS";
    std::string wseq;
    for (unsigned k = 0; k < launches; k++) wseq += (k ? " " : "") + one;
    if (code_want == 0 && seq != wseq) fail += "the calls are not the lifecycle's: want " + wseq + "\n";
    // Whatever happened: every start has its stop.
    auto count = [&](const char *n) { return std::count_if(calls.begin(), calls.end(), [&](const AppCall &c) { return c.name == n && c.err == 0; }); };
    const std::pair<const char *, const char *> pairs[] = {{"TLStartUp", "TLShutDown"}, {"MMStartUp", "MMShutDown"},
        {"NewHandle", "DisposeHandle"}, {"StartUpTools", "ShutDownTools"}, {"Open", "Close"}};
    for (auto &p : pairs)
        if (count(p.first) != count(p.second)) { snprintf(msg, sizeof msg, "%ld %s but %ld %s\n", long(count(p.first)), p.first, long(count(p.second)), p.second); fail += msg; }
    if (open) fail += "the program's file was left open\n";
    if (!quit) fail += "the stub never quit (" + std::to_string(quit_s.size()) + " of " + std::to_string(launches) + " launches)\n";
    for (unsigned q : quit_s)
        if (q != APP_DP_END - 3) { snprintf(msg, sizeof msg, "the stack at QuitGS is $%04X, want $%04X: the runtime left it unbalanced\n", q, APP_DP_END - 3); fail += msg; break; }
    if (rd16(TRACE + 4) != launches) { snprintf(msg, sizeof msg, "the trace counts %u entries, want %u\n", rd16(TRACE + 4), launches); fail += msg; }
    uint32_t low = 0, handle = 0;
    for (auto &c : calls) {
        if (c.name == "NewHandle") {                // (the last launch's, for the trace)
            handle = c.args[3];
            low = handles[handle].ptr;
            if (c.args[1] != APP_UID) { snprintf(msg, sizeof msg, "NewHandle for user ID $%04X\n", c.args[1]); fail += msg; }
            if ((c.args[2] & 0xC01C) != 0xC01C) { snprintf(msg, sizeof msg, "NewHandle attributes $%04X: not locked, fixed, page-aligned, in one bank, out of special memory ($C01C)\n", c.args[2]); fail += msg; }
            printf("app: the low block $%06X, %u bytes\n", low, c.args[0]);
        }
        if (c.name == "DisposeHandle" && c.args[0] != handle) { snprintf(msg, sizeof msg, "DisposeHandle $%06X, not the low block's $%06X\n", c.args[0], handle); fail += msg; }
        if (c.name == "StartUpTools" && c.args[0] != APP_UID) { snprintf(msg, sizeof msg, "StartUpTools for user ID $%04X\n", c.args[0]); fail += msg; }
        if (c.name == "MMShutDown" && c.args[0] != APP_UID) { snprintf(msg, sizeof msg, "MMShutDown for user ID $%04X\n", c.args[0]); fail += msg; }
    }
    if (tools_ref && (tools_ref < low || tools_ref >= low + 0x10000)) fail += "the start/stop record is not in the low block\n";
    // The trace
    const unsigned t_step = rd16(TRACE + 12), t_err = rd16(TRACE + 14), t_stat = rd16(TRACE + 24), t_done = rd16(TRACE + 40);
    const uint32_t t_code = rd32(TRACE + 20), t_low = rd32(TRACE + 16), t_hi = rd32(TRACE + 42), t_hisz = rd32(TRACE + 46), t_eof = rd32(TRACE + 50);
    printf("app: trace step $%02X, exit %d (status %u, cause %u, pc $%08X), error $%04X, done $%02X, upper $%08X+$%X, file %u bytes\n",
           t_step, int32_t(t_code), t_stat, rd16(TRACE + 26), rd32(TRACE + 32), t_err, t_done, t_hi, t_hisz, t_eof);
    if (memcmp(&mem[TRACE], "RVRT", 4)) fail += "no trace at $EE:FF00\n";
    if (t_step != 0xFF) fail += "the trace: the lifecycle did not come back\n";
    if (int32_t(t_code) != code_want) { snprintf(msg, sizeof msg, "the exit code is %d, want %ld\n", int32_t(t_code), code_want); fail += msg; }
    if (code_want == 0 && t_stat != 1) fail += "the program did not exit (a trap?)\n";
    if (t_low != low) fail += "the trace's low block is not NewHandle's\n";
    const unsigned want_done = 0x0F | ((h_flags & 1) ? 0x10 : 0) | (code_want == 0 ? 0x20 : 0);
    if (code_want == 0 && t_done != want_done) { snprintf(msg, sizeof msg, "the steps done $%02X, want $%02X\n", t_done, want_done); fail += msg; }
    // The program: loaded where the environment block said, byte for byte, and
    // every byte the engine wrote up there reached the host by its records.
    if (code_want == 0) {
        if (t_hi < HI || (t_hi & 0xFFFF) || t_hisz == 0 || t_hi + t_hisz > SPACE_APP) fail += "the upper-half memory is not whole banks above 16 MB\n";
        else if (t_eof != image.size()) fail += "the trace's file size is not the program's\n";
        else if (entered_at != t_hi) { snprintf(msg, sizeof msg, "the engine entered the upper half at $%08X, not the program's first byte $%08X\n", entered_at, t_hi); fail += msg; }
        else if (!entered_same) fail += "when the program started, the upper half did not hold its file\n";
        size_t bad = 0, first = 0;
        for (size_t i = 0; i < mirror.size(); i++) if (mirror[i] != mem[HI + i]) { if (!bad++) first = HI + i; }
        if (bad) { snprintf(msg, sizeof msg, "the host's mirror of the upper half: %zu bytes differ, first $%06zX\n", bad, first); fail += msg; }
        printf("app: %llu engine write records; L2 model %llu probes, %llu reads, %llu fills, %llu evictions, %llu writes\n",
               recs, l2.probes, l2.reads, l2.fills, l2.evicts, l2.writes);
    }
    fail += l2.err;
    // The registration table: made, and empty again
    if (memcmp(&mem[REG], "RVRG", 4) || rd16(REG + 4) != 1) fail += "no registration table at $EE:0000\n";
    if (rd16(REG + 6) || rd16(REG + 8) || rd32(REG + 10)) { snprintf(msg, sizeof msg, "the registration table still holds video $%04X, application $%04X\n", rd16(REG + 6), rd16(REG + 8)); fail += msg; }
    for (unsigned b = 0; b < 256; b++)
        if (rd16(REG + 0x100 + 2 * b)) { snprintf(msg, sizeof msg, "upper bank $%03X still owned by $%04X\n", 0x100 + b, rd16(REG + 0x100 + 2 * b)); fail += msg; break; }
    // Enhanced video: off, and the global commit after it
    if ((h_flags & 1) || stale) {
        if (ev_enable != 0 || ev_commit_at < ev_enable_at) fail += "enhanced video: not left off (ENABLE 0, then the global commit)\n";
    }
    if (low_water <= APP_DP_END) printf("app: the stack's deepest write $%04X: %u bytes of the %u-byte segment\n", low_water, APP_DP_END + 1 - low_water, APP_DP_END + 1 - APP_DP);
    if (stray > 1) { snprintf(msg, sizeof msg, "%u stray writes in all\n", stray); fail += msg; }
    printf("app: %llu cycles\n", cycles);
    if (!fail.empty()) printf("%sFAIL\n", fail.c_str());
    else printf("app: PASS\n");
    delete dut;
    return fail.empty() ? 0 : 1;
#endif
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *hex = nullptr, *vm = nullptr, *guest = nullptr;
    unsigned long long max_cycles = 2000000000ull;
    unsigned vm_bank = 0xF1;
    long long load = 0x800000, pc0 = -1, sp_arg = -1;
    bool use_ref = false, ref_only = false, prof = false;
    unsigned long long trace = 0;
    long expect_trap = -1;
    std::string input;
    const char *app = nullptr, *image = nullptr;
    bool stale = false;
    long expect_code = 0;
    unsigned launches = 1;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto val = [&](const char *k) { return a.substr(strlen(k)); };
        if (a.rfind("--hex=", 0) == 0) hex = argv[i] + 6;
        else if (a.rfind("--vm=", 0) == 0) vm = argv[i] + 5;
        else if (a.rfind("--guest=", 0) == 0) guest = argv[i] + 8;
        else if (a.rfind("--load=", 0) == 0) load = strtoll(val("--load=").c_str(), nullptr, 0);
        else if (a.rfind("--pc=", 0) == 0) pc0 = strtoll(val("--pc=").c_str(), nullptr, 0);
        else if (a.rfind("--sp=", 0) == 0) sp_arg = strtoll(val("--sp=").c_str(), nullptr, 0);
        else if (a.rfind("--input=", 0) == 0) input = unescape(val("--input="));
        else if (a.rfind("--max-cycles=", 0) == 0) max_cycles = strtoull(val("--max-cycles=").c_str(), nullptr, 0);
        else if (a.rfind("--trace=", 0) == 0) trace = strtoull(val("--trace=").c_str(), nullptr, 0);
        else if (a.rfind("--expect-trap=", 0) == 0) expect_trap = strtol(val("--expect-trap=").c_str(), nullptr, 0);
        else if (a.rfind("--app=", 0) == 0) app = argv[i] + 6;
        else if (a == "--stale") stale = true;
        else if (a.rfind("--image=", 0) == 0) image = argv[i] + 8;
        else if (a.rfind("--launches=", 0) == 0) launches = unsigned(strtoul(val("--launches=").c_str(), nullptr, 0));
        else if (a.rfind("--expect-code=", 0) == 0) expect_code = strtol(val("--expect-code=").c_str(), nullptr, 0);
        else if (a == "--ref") use_ref = true;
        else if (a == "--ref-only") ref_only = true;
        else if (a == "--prof") prof = true;
        else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }
    if (app) {
        if (!hex || !vm || guest || ref_only || use_ref) { fprintf(stderr, "--app= takes --hex= --vm= and no guest, no reference\n"); return 2; }
        return run_app(hex, vm, vm_bank, app, stale, image, expect_code, launches, max_cycles);
    }
    if (!guest || (!ref_only && (!hex || !vm))) { fprintf(stderr, "need --guest= and (--hex= --vm= | --ref-only)\n"); return 2; }

    if (load < 0 || load >= LOW) { fprintf(stderr, "--load=$%llX is outside the 65816's 16 MB\n", load); return 2; }
    if (pc0 < 0) pc0 = load;

    // The VM image and its header; the options patch the header, as a loader would.
    const unsigned vmb = vm_bank << 16;
    if (!ref_only) {
        load_file(vm, mem, vmb, 0x10000);
        if (memcmp(&mem[vmb + H_MAGIC], "RVVM", 4) != 0) { fprintf(stderr, "%s: no RVVM header\n", vm); return 2; }
        if (rd16(vmb + H_VERSION) != VM_VERSION && rd16(vmb + H_VERSION) != VM_VERSION_ENGINE) {
            fprintf(stderr, "%s: header version %u, want %u or %u\n", vm, rd16(vmb + H_VERSION), VM_VERSION, VM_VERSION_ENGINE);
            return 2;
        }
        for (int i = 0; i < 4; i++) mem[vmb + H_PC + i] = uint8_t(pc0 >> (8 * i));
        if (sp_arg >= 0) for (int i = 0; i < 4; i++) mem[vmb + H_SP + i] = uint8_t(sp_arg >> (8 * i));
    }
    const uint32_t sp0 = sp_arg > 0 ? uint32_t(sp_arg) : DEFAULT_SP;

    // The guest image at --load; the model starts from the same 16 MB.
    load_file(guest, mem, size_t(load), LOW - size_t(load));
    Ref ref;
    ref.m.assign(LOW + 8, 0);
    ref.space = LOW;   // the memory side is the 65816: the engine reaches only its 16 MB here
    ref.x[2] = sp0;
    ref.pc = uint32_t(pc0);
    ref.in = input;
    if (ref_only) memcpy(ref.m.data(), mem.data(), LOW);

    if (ref_only) {
        while (ref.status == 0) ref.step();
        fwrite(ref.out.data(), 1, ref.out.size(), stdout);
        printf("\nref: %s", ref.status == 1 ? "exit" : "trap");
        if (ref.status == 1) printf(" %d", int32_t(ref.code));
        else printf(" %s pc=%08x tval=%08x", cause_name(ref.cause), ref.pc, ref.tval);
        printf(", %" PRIu64 " instructions\n", ref.instret);
        if (expect_trap >= 0) return (ref.status == 2 && long(ref.cause) == expect_trap) ? 0 : 1;
        return (ref.status == 1 && ref.code == 0) ? 0 : 1;
    }
    if (!load_fetch_word(hex)) { fprintf(stderr, "cannot read %s\n", hex); return 2; }

    // Which VM: the software VM keeps the RISC-V state in its direct page and is
    // checked at each dispatch; the engine's VM leaves it in the engine, which is
    // checked at each instruction it retires.
    const bool engine = rd16(vmb + H_VERSION) == VM_VERSION_ENGINE;
    if (!engine) { fprintf(stderr, "%s: header version %u is not the engine's VM (%u)\n", vm, rd16(vmb + H_VERSION), VM_VERSION_ENGINE); return 2; }
    const unsigned entry = vmb | rd16(vmb + H_ENTRY);
    const unsigned dispatch = vmb | rd16(vmb + H_DISPATCH);
    const unsigned char stub[] = {
        0x18,                   // CLC
        0xFB,                   // XCE           native
        0x5C, (unsigned char)entry, (unsigned char)(entry >> 8), (unsigned char)(entry >> 16),  // JML entry
    };
    memcpy(&mem[0x000800], stub, sizeof stub);
    mem[0x00FFFC] = 0x00; mem[0x00FFFD] = 0x08;
    memcpy(ref.m.data(), mem.data(), LOW);   // the model sees what the VM sees

    dut = new Vrvvm_sys;
    dut->irq_n = 1; dut->nmi_n = 1; dut->cyc_en = 1; dut->i_din = 0; dut->d_din = 0;
    dut->rst = 1; tick(); tick(); dut->rst = 0; dut->eval();

    std::string fail, vm_out;
    char msg[512];
    size_t in_pos = 0;
    unsigned char cyc_latch[8] = {0};
    unsigned long long cycles = 0, instret = 0, first_dispatch = 0, last_dispatch = 0;
    std::map<std::string, std::pair<unsigned long long, unsigned long long>> hist;   // name -> {count, cycles}
    std::string last_name;
    bool diverged = false;

    auto vm_pc = [&]() -> uint32_t {
        if (engine) return ENG(pc_q);
        return (uint32_t(rd16(DP_PCP + 2)) << 16) | rd16(DP_PCP);   // the bank as a word: a pc run off the space is bank $0100
    };
    auto vm_reg = [&](int i) -> uint32_t {
        if (engine) return i == 0 ? 0 : uint32_t(ENG(rf)[i]);
        return rd32(DP_REGS + 4 * i);
    };
    unsigned long long win_stalls = 0;
    // After every clock: if the engine retired an instruction: the model runs the same one, then
        // the engine's pc and registers must equal the model's.
    auto on_clock = [&]() {
        if (!(engine && dut->retired)) return;
            const uint32_t rpc = ref.pc, iw = ref.pc < LOW ? ref.ld(ref.pc & ~3u, 4) : 0;
            const char *mn = mnemonic(iw);
            if (instret == 0) first_dispatch = cycles;
            if (prof && instret) { auto &h = hist[last_name]; h.first++; h.second += cycles - last_dispatch; }
            last_name = mn ? mn : "(illegal)";
            last_dispatch = cycles;
            if (trace && instret < trace) printf("[%8llu] %08x: %08x %s\n", instret, rpc, iw, last_name.c_str());
            if (use_ref && !diverged) {
                ref.step();
                if (ref.nondet) { ref.x[10] = vm_reg(10); if (ref.x[17] == 0x5000) ref.x[11] = vm_reg(11); ref.nondet = false; }
                bool same = ref.status == 0 && ref.pc == vm_pc();
                for (int i = 0; i < 32 && same; i++) same = ref.x[i] == vm_reg(i);
                if (!same) {
                    diverged = true;
                    snprintf(msg, sizeof msg, "LOCKSTEP: the engine diverged at instruction %llu, %08x %08x %s\n", instret, rpc, iw, last_name.c_str());
                    fail += msg;
                    uint32_t vx[32]; for (int i = 0; i < 32; i++) vx[i] = vm_reg(i);
                    dump_regs("eng", vx, vm_pc());
                    dump_regs("ref", ref.x, ref.pc);
                    for (int i = 0; i < 32; i++) if (vx[i] != ref.x[i]) printf("  differs: %s eng=%08x ref=%08x\n", abi[i], vx[i], ref.x[i]);
                }
            }
            instret++;
        };


    for (;;) {
        if (dut->halted) break;
        if (cycles >= max_cycles) { fail += "runaway: no STP in " + std::to_string(max_cycles) + " cycles\n"; break; }
        const unsigned addr = dut->addr;

        if (!engine && dut->sync && dut->vpa && addr == dispatch) {
            // One RISC-V instruction is about to be dispatched: IW holds it,
            // PCP points at it, and the previous one's effects are all written.
            const uint32_t iw = rd32(DP_IW);
            if (instret == 0) first_dispatch = cycles;
            if (prof && instret) { auto &h = hist[last_name]; h.first++; h.second += cycles - last_dispatch; }
            const char *mn = mnemonic(iw);
            last_name = mn ? mn : "(illegal)";
            last_dispatch = cycles;
            if (trace && instret < trace) printf("[%8llu] %08x: %08x %s\n", instret, vm_pc(), iw, last_name.c_str());
            if (use_ref && !diverged) {
                if (ref.nondet) { ref.x[10] = vm_reg(10); if (ref.x[17] == 0x5000) ref.x[11] = vm_reg(11); ref.nondet = false; }
                bool same = ref.status == 0 && ref.pc == vm_pc();
                for (int i = 0; i < 32 && same; i++) same = ref.x[i] == vm_reg(i);
                if (!same) {
                    diverged = true;
                    snprintf(msg, sizeof msg, "LOCKSTEP: diverged before instruction %llu (the previous one, %s, is the suspect)\n", instret, instret ? "see below" : "none");
                    fail += msg;
                    uint32_t vx[32]; for (int i = 0; i < 32; i++) vx[i] = vm_reg(i);
                    dump_regs("vm ", vx, vm_pc());
                    dump_regs("ref", ref.x, ref.pc);
                    for (int i = 0; i < 32; i++) if (vx[i] != ref.x[i]) printf("  differs: %s vm=%08x ref=%08x\n", abi[i], vx[i], ref.x[i]);
                } else {
                    ref.step();
                }
            }
            instret++;
        }

        const unsigned rw = dut->rw;
        unsigned char din = 0;
        if (rw && (dut->vda || dut->vpa)) {
            if (dut->vda && addr == PORT_GETC) din = in_pos < input.size() ? (unsigned char)input[in_pos++] : 0;
            else if (dut->vda && addr == PORT_AVAIL) din = in_pos < input.size() ? 1 : 0;
            else if (dut->vda && addr >= PORT_CYC && addr < PORT_CYC + 8) {
                if (addr == PORT_CYC) for (int i = 0; i < 8; i++) cyc_latch[i] = uint8_t(cycles >> (8 * i));
                din = cyc_latch[addr - PORT_CYC];
            }
            else din = mem[addr];
        }
        if (dut->vpa) { dut->i_din = din; dut->d_din = 0; } else { dut->d_din = din; dut->i_din = 0; }
        dut->eval();
        // The engine's window: its byte, and the cycle held while it works.
        if (dut->win_sel) {
            while (dut->win_stall) {
                dut->cyc_en = 0; tick(); cycles++; win_stalls++; on_clock();
                if (cycles >= max_cycles) break;
            }
            dut->cyc_en = 1;
            if (rw) dut->d_din = dut->win_rdata;
            dut->eval();
        }
        if (!rw && dut->vda) {
            const unsigned char v = dut->dout;
            if (addr == PORT_PUTC) { vm_out += char(v); fputc(v, stdout); }
            else if (dut->win_sel) {}                       // the engine's register, not memory
            else if (addr < ROM_LO) mem[addr] = v;
            else if ((addr >> 16) != vm_bank) {}            // the ROM ($F0-$FF): dropped, as the machine drops it
            else {                                          // ...but the VM writing its own bank is a VM bug
                snprintf(msg, sizeof msg, "stray write $%02X to $%06X (VM pc $%02X/%04X)\n", v, addr,
                         CPU(pbr), CPU(pc));
                fail += msg;
                break;
            }
        }
        tick();
        cycles++;
        on_clock();
    }
    if (prof && instret) { auto &h = hist[last_name]; h.first++; h.second += cycles - last_dispatch; }
    fflush(stdout);

    const unsigned status = rd16(DP_STATUS);
    const uint32_t code = rd32(DP_CODE);
    if (!vm_out.empty() && vm_out.back() != '\n') printf("\n");
    if (dut->halted) {
        if (status == 1) printf("rvvm: exit %d\n", int32_t(code));
        else if (status == 2) printf("rvvm: trap %s at pc=%08x tval=%08x\n", cause_name(rd16(DP_CAUSE)), vm_pc(), rd32(DP_TVAL));
        else { snprintf(msg, sizeof msg, "halted with status %u\n", status); fail += msg; }
    }
    const unsigned long long run = cycles - first_dispatch;
    printf("rvvm: %llu instructions, %llu cycles (%llu to the first dispatch), %.1f cycles/instruction\n",
           instret, cycles, first_dispatch, instret ? double(run) / double(instret) : 0.0);
    if (engine) printf("rvvm: the engine: %llu clocks the 65816 waited on STEP\n", win_stalls);

    if (use_ref && !diverged && dut->halted) {
        // The model has executed every instruction the VM dispatched; the one
        // that stopped the VM (exit, trap) is the model's last step too - except
        // a pc that ran off the end of guest RAM, which faults before a dispatch.
        if (ref.status == 0) ref.step();
        if (ref.status != status) { snprintf(msg, sizeof msg, "LOCKSTEP: status vm=%u ref=%u\n", status, ref.status); fail += msg; }
        else if (status == 1 && ref.code != code) { snprintf(msg, sizeof msg, "LOCKSTEP: exit code vm=%d ref=%d\n", int32_t(code), int32_t(ref.code)); fail += msg; }
        else if (status == 2 && (ref.cause != rd16(DP_CAUSE) || ref.tval != rd32(DP_TVAL) || ref.pc != vm_pc())) {
            snprintf(msg, sizeof msg, "LOCKSTEP: trap vm=%u/%08x@%08x ref=%u/%08x@%08x\n", rd16(DP_CAUSE), rd32(DP_TVAL), vm_pc(), ref.cause, ref.tval, ref.pc);
            fail += msg;
        }
        // The registers at the stop: a faulting instruction must not have written rd.
        for (int i = 0; i < 32; i++)
            if (ref.x[i] != vm_reg(i)) {
                snprintf(msg, sizeof msg, "LOCKSTEP: at the stop %s vm=%08x ref=%08x\n", abi[i], vm_reg(i), ref.x[i]);
                fail += msg;
            }
        // The VM's console also carries the monitor's report; compare the part before it.
        if (vm_out.compare(0, ref.out.size(), ref.out) != 0) fail += "LOCKSTEP: console output differs\n";
        // All of memory but the VM's own direct page and stack.
        size_t bad = 0, first = 0;
        for (uint32_t i = 0x200; i < LOW; i++) if (mem[i] != ref.m[i]) { if (!bad++) first = i; }
        if (bad) { snprintf(msg, sizeof msg, "LOCKSTEP: %zu bytes differ, first at %06zx (vm %02x ref %02x)\n", bad, first, mem[first], ref.m[first]); fail += msg; }
        if (fail.empty()) printf("rvvm: lockstep with the reference: %" PRIu64 " instructions agree\n", ref.instret);
    }

    if (prof && !hist.empty()) {
        std::vector<std::pair<std::string, std::pair<unsigned long long, unsigned long long>>> v(hist.begin(), hist.end());
        std::sort(v.begin(), v.end(), [](auto &a, auto &b) { return a.second.second > b.second.second; });
        printf("%-10s %12s %8s %14s %8s %10s\n", "insn", "count", "count%", "cycles", "cyc%", "cyc/insn");
        for (auto &e : v)
            printf("%-10s %12llu %7.2f%% %14llu %7.2f%% %10.1f\n", e.first.c_str(), e.second.first,
                   100.0 * e.second.first / instret, e.second.second, 100.0 * e.second.second / run,
                   double(e.second.second) / e.second.first);
    }

    const bool ok = fail.empty() && dut->halted &&
                    (expect_trap >= 0 ? (status == 2 && long(rd16(DP_CAUSE)) == expect_trap) : (status == 1 && code == 0));
    if (!fail.empty()) printf("%sFAIL\n", fail.c_str());
    delete dut;
    return ok ? 0 : 1;
}
