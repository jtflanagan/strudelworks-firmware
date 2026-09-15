// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// gspanel_run - the GS control panel's binary on the card's own 65816
// (docs/GS_CONTROL_PANEL.md R0): the cheapest loop that runs the REAL bytes
// the panel will run on hardware, with nothing else of a IIgs around them.
//
// THE MACHINE IS A STAGE, NOT A IIgs.  A flat 16 MB of memory; the panel's
// image in bank $E2; a bank-0 caller that stands where the Desk Manager does
// (FE/D467: native mode, M = X = 1, DBR = 0, D = 0, a JSL to the panel);
// $C0xx in banks $00/$01/$E0/$E1 answered by a small soft-switch model with
// a scripted keyboard; the text pages at $E0/$E1 $0400 read back as the 80
// columns a monitor would show; the $EF doorbell answered by echoing the
// request; and a trap at FF/8FB0 standing in for the ROM's own Control Panel
// (the chain's far end: it checks the contract the stock panel needs, pops
// the one byte the chain pushed, and RTLs).
//
// A RUN PASSES when the panel returns to the caller with the machine as the
// caller left it - S, D, DBR, emulation off, M and X set, page zero's
// imaginary registers ($00-$1F) untouched, the soft switches restored - and
// every --expect string was on the screen at some point along the way.
//
//   gspanel_run --hex=rtl/cpu65816_ucode.hex --bin=PANEL.bin
//               [--keys='{down}{down}{ret}{esc}'] [--expect=TEXT ...]
//               [--stock=N] [--max-cycles=N] [--screens]
//
// Keys: plain characters, or {ret} {esc} {up} {down} {left} {right} {tab}
// {del} {oa-X} (Open-Apple held).  A key is presented when the panel's
// $C000 read finds the strobe clear, so a script is a type-ahead buffer.

#include "Vcpu65816.h"
#include "Vcpu65816___024root.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

static Vcpu65816 *dut;
static std::vector<unsigned> fetch_word;
static std::vector<unsigned char> mem(1u << 24, 0);

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static bool load_fetch_word(const char *hex) {
    // The FETCH microinstruction: the hex's last line (sim/cpu816_trace_main.cpp).
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

// ---- the soft switches this stage models ---------------------------------
struct Switches {
    bool store80 = false, intcxrom = false, col80 = false, altchar = false;
    bool text = true, mixed = false, page2 = false, hires = false;
    unsigned char c022 = 0xF0, c027 = 0x00, c029 = 0x01, c034 = 0x00, c035 = 0x08, c036 = 0x80;
    bool operator==(const Switches &o) const {
        return store80 == o.store80 && intcxrom == o.intcxrom && col80 == o.col80 &&
               altchar == o.altchar && text == o.text && mixed == o.mixed && page2 == o.page2 &&
               hires == o.hires && c022 == o.c022 && c027 == o.c027 && c029 == o.c029 &&
               c034 == o.c034 && c035 == o.c035 && c036 == o.c036;
    }
};
static Switches sw;

static std::deque<unsigned> keys;   // byte | mods << 8
static unsigned char kbd_latch = 0, kbd_mods = 0;
static bool strobe = false;
static unsigned long long keys_given = 0;

static bool is_io(unsigned a) {
    unsigned bank = a >> 16, lo16 = a & 0xFFFF;
    return (lo16 & 0xFF00) == 0xC000 && (bank == 0x00 || bank == 0x01 || bank == 0xE0 || bank == 0xE1);
}

static void touch_switch(unsigned lo) {
    // $C050-$C057 act on a read or a write alike.
    switch (lo) {
        case 0x50: sw.text = false; break;  case 0x51: sw.text = true; break;
        case 0x52: sw.mixed = false; break; case 0x53: sw.mixed = true; break;
        case 0x54: sw.page2 = false; break; case 0x55: sw.page2 = true; break;
        case 0x56: sw.hires = false; break; case 0x57: sw.hires = true; break;
    }
}

static std::vector<std::string> screens;
static bool print_screens = false;
static std::string screen_text();

static unsigned char io_read(unsigned lo) {
    touch_switch(lo);
    switch (lo) {
        case 0x00:
            if (!strobe && !keys.empty()) {
                unsigned k = keys.front(); keys.pop_front();
                kbd_latch = k & 0x7F; kbd_mods = (k >> 8) & 0xFF; strobe = true; keys_given++;
                screens.push_back(screen_text());
                if (print_screens) printf("-- key %llu ($%02X): screen before it --\n%s", keys_given, kbd_latch, screens.back().c_str());
            }
            return kbd_latch | (strobe ? 0x80 : 0);
        case 0x10: { unsigned char v = kbd_latch | (strobe ? 0x80 : 0); strobe = false; return v; }
        case 0x15: return sw.intcxrom ? 0x80 : 0x00;
        case 0x18: return sw.store80 ? 0x80 : 0x00;
        case 0x1A: return sw.text ? 0x80 : 0x00;
        case 0x1B: return sw.mixed ? 0x80 : 0x00;
        case 0x1C: return sw.page2 ? 0x80 : 0x00;
        case 0x1D: return sw.hires ? 0x80 : 0x00;
        case 0x1E: return sw.altchar ? 0x80 : 0x00;
        case 0x1F: return sw.col80 ? 0x80 : 0x00;
        case 0x22: return sw.c022;
        case 0x25: return kbd_mods;
        case 0x27: return sw.c027;
        case 0x29: return sw.c029;
        case 0x34: return sw.c034;
        case 0x35: return sw.c035;
        case 0x36: return sw.c036;
    }
    return 0x00;
}

static void io_write(unsigned lo, unsigned char v) {
    touch_switch(lo);
    switch (lo) {
        case 0x00: sw.store80 = false; break;  case 0x01: sw.store80 = true; break;
        case 0x06: sw.intcxrom = false; break; case 0x07: sw.intcxrom = true; break;
        case 0x0C: sw.col80 = false; break;    case 0x0D: sw.col80 = true; break;
        case 0x0E: sw.altchar = false; break;  case 0x0F: sw.altchar = true; break;
        case 0x10: strobe = false; break;
        case 0x22: sw.c022 = v; break;
        case 0x27: sw.c027 = v; break;
        case 0x29: sw.c029 = v; break;
        case 0x34: sw.c034 = v; break;
        case 0x35: sw.c035 = v; break;
        case 0x36: sw.c036 = v; break;
    }
}

// ---- the screen: 80 columns, even columns aux ($E1), odd main ($E0) -------
static char screen_char(unsigned char c) {
    // ALTCHAR's set, reduced to ASCII: inverse shows as its letter, MouseText as '#'.
    if (c >= 0xA0) return (char)(c - 0x80);
    if (c >= 0x80) return (char)(c - 0x40);
    if (c >= 0x60) return (char)c;
    if (c >= 0x40) return '#';
    if (c >= 0x20) return (char)c;
    return (char)(c + 0x40);
}
static std::string screen_text() {
    std::string s;
    for (unsigned row = 0; row < 24; row++) {
        unsigned base = 0x0400 + (row % 8) * 0x80 + (row / 8) * 0x28;
        std::string line;
        for (unsigned col = 0; col < 80; col++) {
            unsigned a = ((col & 1) ? 0xE00000 : 0xE10000) + base + col / 2;
            line += screen_char(mem[a]);
        }
        while (!line.empty() && line.back() == ' ') line.pop_back();
        s += line + "\n";
    }
    return s;
}

// ---- the doorbell: echo the request as the reply --------------------------
static unsigned long long bells = 0;
static void doorbell(unsigned char seq) {
    bells++;
    for (unsigned i = 0; i < 0x100; i++) mem[0xEFF100 + i] = mem[0xEFF000 + i];
    mem[0xEFF2FE] = 0x00;          // status: ok
    mem[0xEFF2FF] = seq;           // the completion byte, last
}

// ---- registers --------------------------------------------------------------
static unsigned peek_p() {
    auto *R = dut->rootp;
    return (R->cpu65816__DOT__f_n << 7) | (R->cpu65816__DOT__f_v << 6) | (R->cpu65816__DOT__f_m << 5) |
           (R->cpu65816__DOT__f_x << 4) | (R->cpu65816__DOT__f_d << 3) | (R->cpu65816__DOT__f_i << 2) |
           (R->cpu65816__DOT__f_z << 1) | R->cpu65816__DOT__f_c;
}
// Put the core at an opcode fetch of pbr:pc with this S (the trace harness's
// park: the FETCH word in uc_q, slot 0 clear).
static void park_at(unsigned pbr, unsigned pc, unsigned s) {
    auto *R = dut->rootp;
    R->cpu65816__DOT__pc = pc; R->cpu65816__DOT__pbr = pbr; R->cpu65816__DOT__s = s;
    R->cpu65816__DOT__slot0_q = 0;
    R->cpu65816__DOT__agu_c = 0; R->cpu65816__DOT__agu_hc = 0;
    for (int i = 0; i < 3; i++) R->cpu65816__DOT__uc_q[i] = fetch_word[i];
    dut->eval();
}

static std::vector<std::string> expects;
static void check_expects(std::vector<bool> &seen, const std::string &scr) {
    for (size_t i = 0; i < expects.size(); i++)
        if (!seen[i] && scr.find(expects[i]) != std::string::npos) seen[i] = true;
}

static bool parse_keys(const std::string &s, std::string *err) {
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] != '{') { keys.push_back((unsigned char)s[i]); continue; }
        size_t j = s.find('}', i);
        if (j == std::string::npos) { *err = "unclosed { in --keys"; return false; }
        std::string n = s.substr(i + 1, j - i - 1);
        i = j;
        if (n == "ret") keys.push_back(0x0D);
        else if (n == "esc") keys.push_back(0x1B);
        else if (n == "up") keys.push_back(0x0B);
        else if (n == "down") keys.push_back(0x0A);
        else if (n == "left") keys.push_back(0x08);
        else if (n == "right") keys.push_back(0x15);
        else if (n == "tab") keys.push_back(0x09);
        else if (n == "del") keys.push_back(0x7F);
        else if (n.size() == 4 && n.rfind("oa-", 0) == 0) keys.push_back((unsigned char)n[3] | (0x80u << 8));
        else { *err = "unknown key {" + n + "}"; return false; }
    }
    return true;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *hex = nullptr, *bin = nullptr;
    unsigned long long max_cycles = 50000000ull;
    long want_stock = -1;
    std::string err;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("--hex=", 0) == 0) hex = argv[i] + 6;
        else if (a.rfind("--bin=", 0) == 0) bin = argv[i] + 6;
        else if (a.rfind("--keys=", 0) == 0) { if (!parse_keys(a.substr(7), &err)) { fprintf(stderr, "%s\n", err.c_str()); return 2; } }
        else if (a.rfind("--expect=", 0) == 0) expects.push_back(a.substr(9));
        else if (a.rfind("--stock=", 0) == 0) want_stock = strtol(argv[i] + 8, nullptr, 10);
        else if (a.rfind("--max-cycles=", 0) == 0) max_cycles = strtoull(argv[i] + 13, nullptr, 10);
        else if (a == "--screens") print_screens = true;
        else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }
    if (!hex || !bin) { fprintf(stderr, "need --hex= and --bin=\n"); return 2; }
    if (!load_fetch_word(hex)) { fprintf(stderr, "cannot read %s\n", hex); return 2; }

    // THE PANEL'S IMAGE in bank $E2, and its header.
    {
        FILE *f = fopen(bin, "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", bin); return 2; }
        size_t n = fread(&mem[0xE20000], 1, 0x10000 * 13, f);   // $E2-$EE at most
        fclose(f);
        if (n < 16 || memcmp(&mem[0xE20000], "SWCP", 4) != 0) { fprintf(stderr, "%s: no SWCP header\n", bin); return 2; }
    }
    const unsigned entry = mem[0xE20008] | (mem[0xE20009] << 8) | (mem[0xE2000A] << 16);
    printf("panel %s: version %u, size word $%04X, entry $%02X/%04X\n", bin,
           mem[0xE20004] | (mem[0xE20005] << 8), mem[0xE20006] | (mem[0xE20007] << 8),
           entry >> 16, entry & 0xFFFF);

    // THE CALLER, where the Desk Manager stands.  Reset comes up in emulation
    // at $00/0800; this goes native with the Desk Manager's state and calls.
    const unsigned char stub[] = {
        0x18,                   // CLC
        0xFB,                   // XCE           native
        0xC2, 0x10,             // REP #$10
        0xA2, 0xE0, 0x01,       // LDX #$01E0
        0x9A,                   // TXS           S = $01E0
        0xE2, 0x30,             // SEP #$30      M = X = 1
        0xA9, 0x00,             // LDA #$00
        0x48,                   // PHA
        0xAB,                   // PLB           DBR = 0
        0xF4, 0x00, 0x00,       // PEA $0000
        0x2B,                   // PLD           D = 0
        0x22, (unsigned char)entry, (unsigned char)(entry >> 8), (unsigned char)(entry >> 16),  // JSL entry
        0xDB,                   // STP
    };
    memcpy(&mem[0x000800], stub, sizeof stub);
    const unsigned stp_addr = 0x000800 + sizeof stub - 1;
    mem[0x00FFFC] = 0x00; mem[0x00FFFD] = 0x08;
    // Page zero's imaginary registers get a pattern the panel must put back.
    for (unsigned i = 0; i < 0x20; i++) mem[i] = (unsigned char)(0xA0 + i);
    // The text pages start blank, as a cleared screen would be.
    for (unsigned a = 0x0400; a < 0x0800; a++) { mem[0xE00000 + a] = 0xA0; mem[0xE10000 + a] = 0xA0; }
    const Switches sw0 = sw;

    dut = new Vcpu65816;
    dut->irq_n = 1; dut->nmi_n = 1; dut->cyc_en = 1; dut->i_din = 0; dut->d_din = 0;
    dut->rst = 1; tick(); tick(); dut->rst = 0; dut->eval();

    std::vector<bool> seen(expects.size(), false);
    unsigned long long cycles = 0, stock = 0;
    bool entered = false;
    unsigned entry_s = 0;
    std::string fail;
    char m[256];

    for (;;) {
        unsigned addr = dut->addr;
        if (dut->halted) break;
        if (cycles >= max_cycles) { fail += "runaway: no return to the caller in " + std::to_string(max_cycles) + " cycles\n"; break; }

        if (dut->sync && dut->vpa) {
            if (addr == entry && !entered) { entered = true; entry_s = dut->rootp->cpu65816__DOT__s; }
            // THE STOCK PANEL'S FAR END.  The chain arrives here by JML with
            // one byte pushed (FF/8FAF) and the stock panel RTLs after pulling
            // it (FF/90E5); it needs D = 0 and DBR = 0.
            if (addr == 0xFF8FB0) {
                auto *R = dut->rootp;
                stock++;
                screens.push_back(screen_text());
                if (R->cpu65816__DOT__d != 0) { snprintf(m, sizeof m, "stock panel entered with D = $%04X\n", R->cpu65816__DOT__d); fail += m; }
                if (R->cpu65816__DOT__dbr != 0) { snprintf(m, sizeof m, "stock panel entered with DBR = $%02X\n", R->cpu65816__DOT__dbr); fail += m; }
                if (!R->cpu65816__DOT__f_m || !R->cpu65816__DOT__f_x) { snprintf(m, sizeof m, "stock panel entered with P = $%02X (M, X must be set)\n", peek_p()); fail += m; }
                unsigned s = R->cpu65816__DOT__s;
                unsigned char pushed = mem[0x000000 | ((s + 1) & 0xFFFF)];
                if (pushed != (sw.intcxrom ? 0x80 : 0x00)) { snprintf(m, sizeof m, "stock panel: the pushed byte is $%02X, not $C015's $%02X\n", pushed, sw.intcxrom ? 0x80 : 0x00); fail += m; }
                s = (s + 1) & 0xFFFF;                                   // PLA
                if (!(pushed & 0x80)) sw.intcxrom = false;              // BMI / STA $C006
                unsigned pcl = mem[(s + 1) & 0xFFFF], pch = mem[(s + 2) & 0xFFFF], pbr = mem[(s + 3) & 0xFFFF];
                s = (s + 3) & 0xFFFF;                                   // RTL
                if (print_screens) printf("-- stock panel #%llu: screen at the chain --\n%s", stock, screens.back().c_str());
                park_at(pbr, ((pch << 8) | pcl) + 1, s);
                continue;
            }
        }

        unsigned rw = dut->rw;
        unsigned char din = 0;
        if (rw && (dut->vda || dut->vpa)) din = is_io(addr) && dut->vda ? io_read(addr & 0xFF) : mem[addr];
        if (dut->vpa) { dut->i_din = din; dut->d_din = 0; } else { dut->d_din = din; dut->i_din = 0; }
        dut->eval();
        if (!rw && dut->vda) {
            unsigned char v = dut->dout;
            if (is_io(addr)) io_write(addr & 0xFF, v);
            else {
                mem[addr] = v;
                if (addr == 0xEFFFF0) doorbell(v);
            }
        }
        tick();
        cycles++;
    }

    auto *R = dut->rootp;
    const std::string final_screen = screen_text();
    screens.push_back(final_screen);
    for (auto &s : screens) check_expects(seen, s);

    if (dut->halted) {
        unsigned pc = (R->cpu65816__DOT__pbr << 16) | R->cpu65816__DOT__pc;
        if (pc != stp_addr + 1) { snprintf(m, sizeof m, "halted at $%06X, not the caller's STP\n", pc); fail += m; }
        if (R->cpu65816__DOT__s != 0x01E0) { snprintf(m, sizeof m, "S = $%04X on return, want $01E0\n", R->cpu65816__DOT__s); fail += m; }
        if (R->cpu65816__DOT__d != 0) { snprintf(m, sizeof m, "D = $%04X on return, want 0\n", R->cpu65816__DOT__d); fail += m; }
        if (R->cpu65816__DOT__dbr != 0) { snprintf(m, sizeof m, "DBR = $%02X on return, want 0\n", R->cpu65816__DOT__dbr); fail += m; }
        if (R->cpu65816__DOT__f_e) fail += "emulation mode on return\n";
        if (!R->cpu65816__DOT__f_m || !R->cpu65816__DOT__f_x) { snprintf(m, sizeof m, "P = $%02X on return (M, X must be set)\n", peek_p()); fail += m; }
        for (unsigned i = 0; i < 0x20; i++)
            if (mem[i] != (unsigned char)(0xA0 + i)) { snprintf(m, sizeof m, "page zero $%02X = $%02X on return, want $%02X\n", i, mem[i], 0xA0 + i); fail += m; }
        if (!(sw == sw0)) fail += "soft switches not restored on return\n";
    }
    for (size_t i = 0; i < expects.size(); i++)
        if (!seen[i]) fail += "never on the screen: \"" + expects[i] + "\"\n";
    if (!keys.empty()) { snprintf(m, sizeof m, "%zu scripted keys never read\n", keys.size()); fail += m; }
    if (want_stock >= 0 && (long)stock != want_stock) { snprintf(m, sizeof m, "stock panel entered %llu times, want %ld\n", stock, want_stock); fail += m; }

    printf("-- final screen --\n%s", final_screen.c_str());
    printf("%llu cycles, %llu keys, %llu stock panel entries, %llu doorbells, entry S $%04X (%u bytes below the caller's $01E0)\n",
           cycles, keys_given, stock, bells, entry_s, entered ? 0x01E0 - entry_s : 0);
    if (!fail.empty()) { printf("%sFAIL\n", fail.c_str()); delete dut; return 1; }
    printf("PASS\n");
    delete dut;
    return 0;
}
