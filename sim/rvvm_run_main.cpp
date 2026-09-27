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

#include "Vrvvm_sys.h"
#include "Vrvvm_sys___024root.h"
#include "verilated.h"
#include "rv_ref.h"

#include <algorithm>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
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
        else if (a == "--ref") use_ref = true;
        else if (a == "--ref-only") ref_only = true;
        else if (a == "--prof") prof = true;
        else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
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
