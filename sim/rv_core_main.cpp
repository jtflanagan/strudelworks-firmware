// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// rv_core_run - the RISC-V engine's core (rtl/gs/rv_core.sv, docs/REQ_RVVM.md
// section 9) against the reference model (sim/rv_ref.h), in lockstep.
//
// THE BENCH PLAYS EVERYTHING AROUND THE CORE.  The memory side: a flat 16 MB
// answering both ports after a random 0-3 clocks, and the permission map -
// banks $02-$DF are engine-direct, every other access is DELEGATED (as are
// all of them with --delegate-all).  The 65816 VM: it steps the core, and on
// an event services it the way the VM will - the ECALLs (exit, write, read,
// cycles, peek, poke), a delegated load or store performed byte-wise - and
// resumes.  After every instruction the core's pc and all 32 registers must
// equal the model's; at the end the verdict, the console and all of memory.
//
//   rv_core_run --guest=prog.bin [--load=ADDR] [--pc=N] [--sp=N] [--input=TEXT]
//               [--ref | --ref-only] [--prof] [--trace=N] [--max-cycles=N]
//               [--expect-trap=CAUSE] [--delegate-all] [--seed=N]
//               [--gap=N] [--cancel=PERCENT] [--evict=N] [--rec-stall=PERCENT] [--hold=PERCENT]
//
// SPECULATION: between steps the bench idles a random 0..N clocks (--gap,
// default 10; the VM's loop is about 8), in which the core runs the next
// instruction on its own, and pulses `cancel` on PERCENT of those clocks
// (--cancel, default 2).  "Exposed" is what the VM waits: the clocks from a
// step to its result.
//
// Clocks are the core's own (100 MHz fabric clocks): "clocks/instruction"
// is its execution cost with an ideal, randomly slow memory, not yet the
// card's (no L2, no VM loop).  Exit status as sim/rvvm_run_main.cpp's.
//
// BUILT WITH RV_MEM (sim/run_rv_mem.sh) it is the bench of the engine's MEMORY
// SIDE too (rtl/gs/rv_mem.sv, top sim/rv_mem_tb.sv): the core talks to rv_mem,
// and behind rv_mem is a MODEL OF THE L2's ports - 16 sets x 8 ways of pages
// placed by page_cam's fold of the page number, the probe (il_*) and the direct
// read (dr_*) with their latencies, fills that evict and broadcast, random
// evictions of the model's own (other L2 users; unpinned ways first), word
// writes by byte enable.  A direct read of a slot that holds no page is an
// error.  A HOST MIRROR takes the engine's writes only from the 0xB records
// (and the VM's from its own writes, as the stream carries a 65816's), and
// must equal memory at the end.  Every VM write to memory pulses `cancel`.

#ifdef RV_MEM
#include "Vrv_mem_tb.h"
typedef Vrv_mem_tb Top;
#else
#include "Vrv_pipe.h"
typedef Vrv_pipe Top;
#endif
#include "verilated.h"
#ifdef RV_MEM
#include "Vrv_mem_tb___024root.h"
#endif
#include "rv_ref.h"

#include <deque>
#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <map>
#include <random>

enum : unsigned {
    R_NEXT = 0, R_ECALL = 2, R_EBREAK = 4, R_ILLEGAL = 6, R_LFAULT = 8, R_SFAULT = 10, R_FFAULT = 12,
    R_DLB = 14, R_DLBU = 16, R_DLH = 18, R_DLHU = 20, R_DLW = 22, R_DSB = 24, R_DSH = 26, R_DSW = 28,
    R_DFETCH = 30,
};

static Top *dut;
static std::vector<uint8_t> mirror;       // the host's view (RV_MEM)
static bool vm_wrote = false;             // the VM wrote memory: pulse cancel
static std::string l2_err;
static unsigned evict_one_in = 150;       // --evict=N: other L2 users evict one clock in N
static unsigned rec_stall_pct = 30;       // --rec-stall=P: the stream refuses a held record on P% of clocks
static FILE *acc_dump = nullptr;          // --accdump=FILE: every direct data access, "L|S addr" (sizing studies)
static unsigned hold_pct = 0;
// --run: the steps are RUN reads (`run` high until the core has an event, or a
// yield after a random 0..--yield=N clocks), checked in lockstep on every retire
static bool run_mode = false;
static unsigned yield_n = 0;
static unsigned long long run_left = ~0ull;      // clocks until this read's yield
static void on_retire();
// --pipeprof: where the pipeline's clocks go (RV_MEM builds)
static bool pipeprof = false;
static unsigned long long pp[12], ppf[8], ppfh = 0, ppfo = 0;             // --hold=P: the governor withholds its token on P% of clocks
static std::vector<uint8_t> mem(SPACE + 8, 0);
static std::mt19937 rng(1);
static bool delegate_all = false;
static bool delegate_fetch = false;   // rung 1: the VM fetches every instruction
static unsigned long long clocks = 0;

// The memory side: a pending request answers after a random 0-3 clocks.
static int f_wait = -1, d_wait = -1;

static uint32_t rd32(uint32_t a) { return mem[a] | (mem[a + 1] << 8) | (mem[a + 2] << 16) | (uint32_t(mem[a + 3]) << 24); }
static bool direct(uint32_t a) { unsigned bank = a >> 16; return !delegate_all && bank >= 0x02 && bank <= 0xDF; }

// The VM's own write to guest memory (a 65816 write: the stream carries it).
// Every VM write is a 65816 write: with the memory side it is snooped, a byte a
// clock (rv_mem drops the row it names), and all of them land before the VM
// steps or resumes the core, as the 65816's own do.
static std::deque<uint32_t> snoopq;
static void vm_write(uint32_t a, uint8_t v) {
    mem[a] = v; if (!mirror.empty()) mirror[a] = v; vm_wrote = true;
#ifdef RV_MEM
    snoopq.push_back(a);
#endif
}

#ifdef RV_MEM
// ---- the L2 model ----------------------------------------------------------
static int32_t slot_ppn[16][8];
static bool    slot_pin[16][8];
static unsigned long long l2_fills = 0, l2_evicts = 0, l2_probes = 0, l2_reads = 0, l2_writes = 0, recs = 0;
static unsigned fold(uint32_t ppn) { return (ppn ^ (ppn >> 4) ^ (ppn >> 8) ^ (ppn >> 12)) & 15; }
static bool find(uint32_t ppn, unsigned &set, unsigned &way) {
    set = fold(ppn);
    for (way = 0; way < 8; way++) if (slot_ppn[set][way] == int32_t(ppn)) return true;
    return false;
}
static void row_of(uint32_t ppn, unsigned line, uint32_t *w) {
    const uint32_t a = (ppn << 8) | (line << 4);
    for (int i = 0; i < 4; i++) w[i] = rd32(a + 4 * i);
}
// Evict a way of `set` (unpinned first), broadcasting it this clock.
static int evict_in(unsigned set, bool &bcast, unsigned &bset, unsigned &bway) {
    int cand[8], n = 0, any[8], m = 0;
    for (int w = 0; w < 8; w++) {
        if (slot_ppn[set][w] < 0) return w;          // a free way: nothing to evict
        any[m++] = w;
        if (!slot_pin[set][w]) cand[n++] = w;
    }
    const int w = n ? cand[rng() % n] : any[rng() % m];
    slot_ppn[set][w] = -1; bcast = true; bset = set; bway = unsigned(w); l2_evicts++;
    return w;
}
static std::vector<std::string> ev_ring;   // the last memory-side events, for a mismatch
static void note(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void note(const char *fmt, ...) {
    char b[200]; va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    ev_ring.push_back(std::to_string(clocks) + ": " + b);
    if (ev_ring.size() > 24) ev_ring.erase(ev_ring.begin());
}
static int il_wait = -1, il_done_in = -1, dr_wait = -1, dr_done_in = -1, pw_wait = -1;
// A request's answer is taken on its ack's clock, as page_cam reads the row
// RAM just after the ack: an eviction between the ack and the done must not
// change what comes back.
static bool il_ok_q; static unsigned il_set_q, il_way_q; static uint32_t il_row_q[4], dr_row_q[4];
static bool pfill_pend = false; static int pfill_wait = -1; static uint32_t pfill_ppn;   // a probe's fill
static bool dr_empty_q; static unsigned dr_set_q, dr_way_q;
static void tick() {
    // the governor's token: withheld on --hold percent of clocks (a write-back waits)
    dut->run = run_mode && run_left != 0;
    if (run_left != 0 && run_left != ~0ull) run_left--;
    dut->hold = hold_pct && (rng() % 100 < hold_pct);
    dut->il_ack = 0; dut->il_done = 0; dut->dr_ack = 0; dut->dr_done = 0;
    dut->pw_ack = 0; dut->evict_v = 0;
    bool bcast = false; unsigned bset = 0, bway = 0;
    // the probe: ack after 0-2 clocks, the answer three clocks later
    if (il_done_in >= 0 && il_done_in-- == 0) {
        dut->il_done = 1;
        dut->il_ok = il_ok_q;
        for (int i = 0; i < 4; i++) dut->il_row[i] = il_row_q[i];
        dut->il_set = il_set_q; dut->il_way = il_way_q;
    }
    if (dut->il_req && il_done_in < 0) {
        if (il_wait < 0) il_wait = int(rng() % 3);
        if (il_wait-- == 0) {
            unsigned set, way;
            dut->il_ack = 1;
            il_ok_q = find(dut->il_ppn, set, way);
            il_set_q = set; il_way_q = way;
            if (il_ok_q) row_of(dut->il_ppn, dut->il_line, il_row_q);
            else if (dut->il_fill && !pfill_pend) {             // the miss starts a fill (page_cam's)
                pfill_pend = true; pfill_wait = 5 + int(rng() % 26); pfill_ppn = dut->il_ppn;
            }
            note("il ack ppn=%04x line=%x -> ok=%d %u/%u", unsigned(dut->il_ppn), unsigned(dut->il_line), il_ok_q, set, way);
            il_done_in = 2; il_wait = -1; l2_probes++;
        }
    }
    // the direct read: ack after 0-2 clocks, the row two clocks later
    if (dr_done_in >= 0 && dr_done_in-- == 0) {
        dut->dr_done = 1;
        if (dr_empty_q) { char m[128]; snprintf(m, sizeof m, "L2: a direct read of an empty slot %u/%u\n", dr_set_q, dr_way_q); l2_err += m; }
        for (int i = 0; i < 4; i++) dut->dr_row[i] = dr_row_q[i];
    }
    if (dut->dr_req && dr_done_in < 0) {
        if (dr_wait < 0) dr_wait = int(rng() % 3);
        if (dr_wait-- == 0) {
            dut->dr_ack = 1;
            dr_set_q = dut->dr_set; dr_way_q = dut->dr_way;
            const int32_t ppn = slot_ppn[dr_set_q][dr_way_q];
            dr_empty_q = ppn < 0;
            if (!dr_empty_q) row_of(uint32_t(ppn), dut->dr_line, dr_row_q);
            note("dr ack %u/%u line=%x (slot holds %04x)", dr_set_q, dr_way_q, unsigned(dut->dr_line), unsigned(ppn));
            dr_done_in = 1; dr_wait = -1; l2_reads++;
        }
    }
    // a probe's fill: 5-30 clocks, evicting (and broadcasting) if the set is
    // full, then the placement report
    dut->op_place_v = 0;
    if (pfill_pend && pfill_wait-- == 0) {
        unsigned set, way;
        if (!find(pfill_ppn, set, way)) {
            const int w = evict_in(fold(pfill_ppn), bcast, bset, bway);
            slot_ppn[fold(pfill_ppn)][w] = int32_t(pfill_ppn); slot_pin[fold(pfill_ppn)][w] = false;
        }
        dut->op_place_v = 1; dut->op_place_ppn = pfill_ppn;
        pfill_pend = false; l2_fills++;
    }
    // other L2 users now and then take a way (not on a fill's clock)
    if (!bcast && evict_one_in && rng() % evict_one_in == 0) {
        const unsigned set = rng() % 16;
        bool anyres = false; for (int w = 0; w < 8; w++) anyres |= slot_ppn[set][w] >= 0;
        if (anyres) {
            // only a way that holds a page; unpinned first
            int cand[8], n = 0, pinned[8], m = 0;
            for (int w = 0; w < 8; w++) if (slot_ppn[set][w] >= 0) { if (slot_pin[set][w]) pinned[m++] = w; else cand[n++] = w; }
            const int w = n ? cand[rng() % n] : pinned[rng() % m];
            slot_ppn[set][w] = -1; bcast = true; bset = set; bway = unsigned(w); l2_evicts++;
        }
    }
    if (bcast) { dut->evict_v = 1; dut->evict_set = bset; dut->evict_way = bway; note("evict %u/%u", bset, bway); }
    // a word write: ack after 0-2 clocks
    if (dut->pw_req) {
        if (pw_wait < 0) pw_wait = int(rng() % 3);
        if (pw_wait-- == 0) {
            const uint32_t a = uint32_t(dut->pw_addr) << 2;
            for (int i = 0; i < 4; i++) if (dut->pw_be & (1u << i)) mem[a + i] = uint8_t(dut->pw_data >> (8 * i));
            dut->pw_ack = 1; pw_wait = -1; l2_writes++;
        }
    }
    vm_wrote = false;
    if (!snoopq.empty()) { dut->cancel = 1; dut->wsn_a = snoopq.front(); snoopq.pop_front(); }
    // the event stream takes a held record, or not this clock; the mirror
    // applies it at the take, as the host would when it arrives
    dut->rec_take = dut->rec_v && (rng() % 100 >= rec_stall_pct);
    if (dut->rec_v && dut->rec_take) {
        const uint64_t r = dut->rec;
        const uint32_t w0 = uint32_t(r), data = uint32_t(r >> 32);
        if ((w0 >> 28) != 0xB) l2_err += "a record without tag 0xB\n";
        const uint32_t a = (((w0 >> 20) & 0xFF) << 16) | (w0 & 0xFFFF);
        for (int i = 0; i < 4; i++) if ((w0 >> (16 + i)) & 1) mirror[a + i] = uint8_t(data >> (8 * i));
        recs++;
    }
    {
        auto *R = dut->rootp;
        if (R->rv_mem_tb__DOT__f_valid) note("f reply %08x%s%s (core f_req=%u f_addr=%06x)", R->rv_mem_tb__DOT__f_data,
            R->rv_mem_tb__DOT__f_delegate ? " delegate" : "", R->rv_mem_tb__DOT__f_abort ? " abort" : "",
            R->rv_mem_tb__DOT__f_req, uint32_t(R->rv_mem_tb__DOT__f_addr) << 2);
        if (dut->cancel) note("cancel");
    }
#ifdef RV_MEM
    if (pipeprof && dut->busy) {
        auto *C = dut->rootp;
#define PC_(x) C->rv_mem_tb__DOT__u_core__DOT__##x
        pp[0]++;
        if (PC_(w_v) && PC_(w_ev) == 0 && !dut->hold) pp[1]++;                  // a retire
        if (dut->rootp->rv_mem_tb__DOT__u_core__DOT__f_req && !dut->rootp->rv_mem_tb__DOT__f_valid) {
            pp[2]++;                                                                // fetch waiting
            ppf[C->rv_mem_tb__DOT__u_mem__DOT__st & 7]++;                           // ...by rv_mem's state
            if (C->rv_mem_tb__DOT__u_mem__DOT__ic_match && C->rv_mem_tb__DOT__u_mem__DOT__ic_tagok) ppfh++;   // though its row is held
            if (PC_(fo_v)) ppfo++;
        }
        if (C->rv_mem_tb__DOT__d_req && !C->rv_mem_tb__DOT__d_valid) pp[3]++;   // data waiting
        if (PC_(e_v) && (PC_(hz1) || PC_(hz2))) pp[4]++;                        // load-use
        if (PC_(e_v) && PC_(e_mc) && !PC_(mc_done)) pp[5]++;                    // mul/div
        if (PC_(w_v) && dut->hold) pp[6]++;                                     // the governor
        if (PC_(mr_now)) pp[7]++;                                              // E redirects
        if (PC_(dr_now)) pp[8]++;                                              // D redirects (BTFN, JAL)
        if (!PC_(d_v) && !PC_(e_v) && !PC_(m_v) && !PC_(w_v)) pp[9]++;          // empty
        if (C->rv_mem_tb__DOT__u_mem__DOT__st == 5) pp[10]++;                    // a store in flight
#undef PC_
    }
#endif
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    if (run_mode && dut->retired) on_retire();
    // Every fetch answer must be memory's word (code does not change under a fetch).
    {
        auto *R = dut->rootp;
        if (R->rv_mem_tb__DOT__f_valid && !R->rv_mem_tb__DOT__f_delegate && !R->rv_mem_tb__DOT__f_abort && R->rv_mem_tb__DOT__f_req) {
            const uint32_t fa = uint32_t(R->rv_mem_tb__DOT__f_addr) << 2;
            if (R->rv_mem_tb__DOT__f_data != rd32(fa) && l2_err.size() < 2000) {
                char m[256];
                snprintf(m, sizeof m, "FETCH @%llu: asked %06x, answered %08x, memory %08x (rv_mem ra=%06x is_f=%u)\n",
                         clocks, fa, R->rv_mem_tb__DOT__f_data, rd32(fa),
                         uint32_t(R->rv_mem_tb__DOT__u_mem__DOT__ra) << 2, R->rv_mem_tb__DOT__u_mem__DOT__is_f);
                l2_err += m; fputs(m, stdout);
                for (auto &e : ev_ring) printf("    %s\n", e.c_str());
            }
        }
    }
    // what the memory side said on that clock
    if (dut->ref_v) slot_pin[dut->ref_set][dut->ref_way] = dut->ref_on;
    dut->step = 0; dut->resume = 0; dut->w_en = 0; dut->pc_we = 0; dut->cancel = 0;
    clocks++;
}
#else
static void tick() {
    // the governor's token: withheld on --hold percent of clocks (a write-back waits)
    dut->run = run_mode && run_left != 0;
    if (run_left != 0 && run_left != ~0ull) run_left--;
    dut->hold = hold_pct && (rng() % 100 < hold_pct);
    // Drive the replies for this clock from the requests the core holds.
    dut->f_valid = 0; dut->f_delegate = 0; dut->f_abort = 0; dut->d_valid = 0; dut->d_delegate = 0; dut->d_abort = 0;
    if (dut->f_req) {
        if (f_wait < 0) f_wait = int(rng() % 4);
        if (f_wait == 0) {
            dut->f_valid = 1;
            if (delegate_fetch) dut->f_delegate = 1;
            else dut->f_data = rd32(uint32_t(dut->f_addr) << 2);
            f_wait = -1;
        }
        else f_wait--;
    }
    if (dut->d_req) {
        if (d_wait < 0) d_wait = int(rng() % 4);
        if (d_wait == 0) {
            const uint32_t a = uint32_t(dut->d_addr) << 2;
            dut->d_valid = 1;
            if (acc_dump && direct(a)) fprintf(acc_dump, "%c %06x\n", dut->d_we ? 'S' : 'L', a);
            if (!direct(a)) dut->d_delegate = 1;
            else if (dut->d_we) {
                for (int i = 0; i < 4; i++) if (dut->d_be & (1u << i)) mem[a + i] = uint8_t(dut->d_wdata >> (8 * i));
            } else dut->d_rdata = rd32(a);
            d_wait = -1;
        } else d_wait--;
    }
    if (vm_wrote) { dut->cancel = 1; vm_wrote = false; }
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    if (run_mode && dut->retired) on_retire();
    dut->step = 0; dut->resume = 0; dut->w_en = 0; dut->pc_we = 0; dut->cancel = 0;
    clocks++;
}
#endif

static uint32_t reg(unsigned i) { const uint8_t k = dut->rsel; dut->rsel = i; dut->eval(); const uint32_t v = dut->rval; dut->rsel = k; return v; }
// ---- the row-cache sizing study (--cachestudy, with --ref-only) ----------------------
// Row caches of 16-byte rows fed by the reference model's accesses: set-associative
// (ways = 1 direct-mapped ... ways = rows fully associative), LRU within a set.
struct RowCache {
    const char *name; unsigned rows, ways; bool loads_only;
    std::vector<uint32_t> tag; std::vector<uint64_t> age; std::vector<bool> v;
    uint64_t t = 0, n = 0, hit = 0;
    RowCache(const char *nm, unsigned r, unsigned w) : name(nm), rows(r), ways(w), loads_only(true),
        tag(r), age(r), v(r, false) {}
    void acc(uint32_t row, bool alloc) {
        const unsigned sets = rows / ways, s = row % sets;
        ++t;
        for (unsigned w = 0; w < ways; w++) {
            const unsigned i = s * ways + w;
            if (v[i] && tag[i] == row) { if (alloc) { ++n; ++hit; } age[i] = t; return; }
        }
        if (!alloc) return;                       // a store that misses: no allocation
        ++n;
        unsigned vic = s * ways;
        for (unsigned w = 0; w < ways; w++) {
            const unsigned i = s * ways + w;
            if (!v[i]) { vic = i; break; }
            if (age[i] < age[vic]) vic = i;
        }
        v[vic] = true; tag[vic] = row; age[vic] = t;
    }
};
static std::vector<RowCache> dstudy, istudy;
static uint64_t f_seq_hit = 0, f_n = 0;                  // today's fetch side: the row and the next
static uint32_t f_row = ~0u;
static void study_acc(char k, uint32_t a) {
    const uint32_t row = a >> 4;
    if (k == 'F') {
        ++f_n;
        if (row == f_row || row == f_row + 1) ++f_seq_hit;   // the fetch row, or the prefetched next
        f_row = row;
        for (auto &c : istudy) c.acc(row, true);
    } else {
        for (auto &c : dstudy) c.acc(row, k == 'L');
    }
}

// a posted store still going out (the memory side's): the window holds the VM
// until it has landed, and so does the bench
static bool core_wr_busy() {
#ifdef RV_MEM
    return dut->wr_busy;
#else
    return false;
#endif
}
static Ref g_ref;
static unsigned long long g_instret = 0;
static std::string g_fail;
static uint32_t reg(unsigned i);
static void on_retire() {
    if (!g_fail.empty()) return;
    g_instret++;
    const uint32_t pc0 = g_ref.pc;
    g_ref.step();
    if (g_ref.nondet) { g_ref.x[10] = reg(10); if (g_ref.x[17] == 0x5000) g_ref.x[11] = reg(11); g_ref.nondet = false; }
    bool same = g_ref.status == 0 && g_ref.pc == dut->pc;
    for (int i = 0; i < 32 && same; i++) same = g_ref.x[i] == reg(unsigned(i));
    if (!same) {
        char m[256];
        snprintf(m, sizeof m, "LOCKSTEP (run): diverged after instruction %llu at %08x (core pc %08x, ref pc %08x)\n",
                 g_instret, pc0, dut->pc, g_ref.pc);
        g_fail += m;
        for (int i = 0; i < 32; i++)
            if (g_ref.x[i] != reg(unsigned(i))) printf("  differs: x%d core=%08x ref=%08x\n", i, reg(unsigned(i)), g_ref.x[i]);
    }
}
// (and one clock more: the memory side takes the snoop through a register)
static void drain() { if (snoopq.empty()) return; while (!snoopq.empty()) tick(); tick(); }
static void set_reg(unsigned i, uint32_t v) { dut->w_en = 1; dut->w_sel = i; dut->w_val = v; tick(); }

static std::string unescape(const std::string &s) {
    std::string o;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '\\' && i + 1 < s.size()) { char c = s[++i]; o += c == 'n' ? '\n' : c == 't' ? '\t' : c; }
        else o += s[i];
    }
    return o;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *guest = nullptr;
    long long load = 0x800000, pc0 = -1, sp_arg = -1, expect_trap = -1;
    unsigned long long max_clocks = 4000000000ull, trace = 0, gap = 10, cancel_pct = 2;
    int watch = -1;                     // --watch=REG: print it (core and model) at each traced retirement
    bool ref_only = false, prof = false, cachestudy = false;
    std::string input;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto val = [&](const char *k) { return a.substr(strlen(k)); };
        if (a.rfind("--guest=", 0) == 0) guest = argv[i] + 8;
        else if (a.rfind("--load=", 0) == 0) load = strtoll(val("--load=").c_str(), nullptr, 0);
        else if (a.rfind("--pc=", 0) == 0) pc0 = strtoll(val("--pc=").c_str(), nullptr, 0);
        else if (a.rfind("--sp=", 0) == 0) sp_arg = strtoll(val("--sp=").c_str(), nullptr, 0);
        else if (a.rfind("--input=", 0) == 0) input = unescape(val("--input="));
        else if (a.rfind("--max-cycles=", 0) == 0) max_clocks = strtoull(val("--max-cycles=").c_str(), nullptr, 0);
        else if (a.rfind("--trace=", 0) == 0) trace = strtoull(val("--trace=").c_str(), nullptr, 0);
        else if (a.rfind("--expect-trap=", 0) == 0) expect_trap = strtol(val("--expect-trap=").c_str(), nullptr, 0);
        else if (a.rfind("--seed=", 0) == 0) rng.seed(unsigned(strtoul(val("--seed=").c_str(), nullptr, 0)));
        else if (a.rfind("--watch=", 0) == 0) watch = atoi(val("--watch=").c_str());
        else if (a.rfind("--evict=", 0) == 0) evict_one_in = unsigned(strtoul(val("--evict=").c_str(), nullptr, 0));
        else if (a.rfind("--accdump=", 0) == 0) acc_dump = fopen(val("--accdump=").c_str(), "w");
        else if (a == "--run") run_mode = true;
        else if (a == "--pipeprof") pipeprof = true;
        else if (a.rfind("--yield=", 0) == 0) yield_n = unsigned(strtoul(val("--yield=").c_str(), nullptr, 0));
        else if (a.rfind("--hold=", 0) == 0) hold_pct = unsigned(strtoul(val("--hold=").c_str(), nullptr, 0));
        else if (a.rfind("--rec-stall=", 0) == 0) rec_stall_pct = unsigned(strtoul(val("--rec-stall=").c_str(), nullptr, 0));
        else if (a == "--delegate-all") delegate_all = true;
        else if (a == "--delegate-fetch") delegate_fetch = true;
        else if (a == "--rung1") delegate_all = delegate_fetch = true;
        else if (a.rfind("--gap=", 0) == 0) gap = strtoull(val("--gap=").c_str(), nullptr, 0);
        else if (a.rfind("--cancel=", 0) == 0) cancel_pct = strtoull(val("--cancel=").c_str(), nullptr, 0);
        else if (a == "--ref") {}
        else if (a == "--ref-only") ref_only = true;
        else if (a == "--cachestudy") cachestudy = true;
        else if (a == "--prof") prof = true;
        else if (a.rfind("--hex=", 0) == 0 || a.rfind("--vm=", 0) == 0) {}   // the VM runner's; not ours
        else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }
    if (!guest) { fprintf(stderr, "need --guest=\n"); return 2; }
    if (load < 0 || load >= SPACE) { fprintf(stderr, "--load outside the 24-bit space\n"); return 2; }
    if (pc0 < 0) pc0 = load;
    const uint32_t sp0 = sp_arg > 0 ? uint32_t(sp_arg) : DEFAULT_SP;
    {
        FILE *f = fopen(guest, "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", guest); return 2; }
        fread(&mem[size_t(load)], 1, SPACE - size_t(load), f);
        fclose(f);
    }
    Ref &ref = g_ref;
    ref.m = mem;
    ref.x[2] = sp0;
    ref.pc = uint32_t(pc0);
    ref.in = input;
    if (ref_only) {
        if (cachestudy) {
            for (unsigned r : {16u, 32u, 64u, 128u, 256u, 512u}) dstudy.emplace_back("dm", r, 1);
            for (unsigned r : {32u, 64u, 128u}) dstudy.emplace_back("2way", r, 2);
            for (unsigned r : {32u, 64u}) dstudy.emplace_back("lru", r, r);
            for (unsigned r : {16u, 32u, 64u, 512u, 1024u, 2048u}) istudy.emplace_back("dm", r, 1);
            for (unsigned r : {512u, 1024u}) istudy.emplace_back("2way", r, 2);
            ref.on_acc = study_acc;
        }
        while (ref.status == 0) ref.step();
        if (cachestudy) {
            printf("cachestudy: loads");
            for (auto &c : dstudy) printf(" %s%u=%.3f", c.name, c.rows, c.n ? double(c.hit) / double(c.n) : 0.0);
            printf("\ncachestudy: fetch row+next=%.3f", f_n ? double(f_seq_hit) / double(f_n) : 0.0);
            for (auto &c : istudy) printf(" %s%u=%.3f", c.name, c.rows, c.n ? double(c.hit) / double(c.n) : 0.0);
            printf("\ncachestudy: %" PRIu64 " loads, %" PRIu64 " fetches\n", dstudy[0].n, f_n);
        }
        fwrite(ref.out.data(), 1, ref.out.size(), stdout);
        printf("\nref: %s", ref.status == 1 ? "exit" : "trap");
        if (ref.status == 1) printf(" %d", int32_t(ref.code));
        else printf(" %s pc=%08x tval=%08x", cause_name(ref.cause), ref.pc, ref.tval);
        printf(", %" PRIu64 " instructions\n", ref.instret);
        if (expect_trap >= 0) return (ref.status == 2 && long(ref.cause) == expect_trap) ? 0 : 1;
        return (ref.status == 1 && ref.code == 0) ? 0 : 1;
    }

    dut = new Top;
#ifdef RV_MEM
    for (auto &s : slot_ppn) for (auto &w : s) w = -1;
    mirror = mem;
    dut->dlo = delegate_all ? 1 : 0x02;          // --delegate-all: an empty range
    dut->dhi = delegate_all ? 0 : 0xDF;
#endif
    dut->rst = 1; tick(); tick(); dut->rst = 0;
    dut->pc_we = 1; dut->pc_wval = uint32_t(pc0); tick();
    set_reg(2, sp0);

    std::string out, fail;
    char msg[512];
    size_t in_pos = 0;
    unsigned status = 0, cause = 0;
    uint32_t code = 0, tval = 0, stop_pc = 0;
    unsigned long long instret = 0, events = 0, exposed = 0, cancels = 0;
    std::map<std::string, std::pair<unsigned long long, unsigned long long>> hist;
    const unsigned long long start = clocks;

    auto trap_of = [](unsigned r) -> unsigned {
        switch (r) {
            case R_EBREAK: return T_EBREAK; case R_ILLEGAL: return T_ILLEGAL; case R_LFAULT: return T_LOAD;
            case R_SFAULT: return T_STORE; case R_FFAULT: return T_FETCH;
        }
        return 0;
    };

    while (status == 0) {
        if (clocks - start >= max_clocks) { fail += "runaway\n"; break; }
        const uint32_t pc = dut->pc;
        const uint32_t iw_pre = pc < SPACE ? rd32(pc & ~3u) : 0;
        const unsigned long long c0 = clocks;
        if (trace && instret < trace) printf("[%8llu] %08x: %08x %s\n", instret, pc, iw_pre, mnemonic(iw_pre) ? mnemonic(iw_pre) : "?");
        // The VM's loop: a few idle clocks, now and then a cancel.
        const unsigned idle = gap ? unsigned(rng() % (gap + 1)) : 0;
        for (unsigned i = 0; i < idle; i++) {
            if (cancel_pct && rng() % 100 < cancel_pct) { dut->cancel = 1; cancels++; }
            tick();
        }
        const unsigned long long s0 = clocks;
        run_left = (run_mode && yield_n) ? (unsigned long long)(rng() % (yield_n + 1)) + 1 : ~0ull;
        drain(); dut->step = 1; tick();
        while (dut->busy || core_wr_busy()) tick();
        run_left = ~0ull;
        if (!g_fail.empty()) { fail += g_fail; break; }
        exposed += clocks - s0;
        unsigned r = dut->result;
        // The VM's part: service the event, then resume.
        bool stopped = false;
    again:
        if (r != R_NEXT) {
            if (r != R_DFETCH) events++;
            const uint32_t ea = dut->ev_addr, data = dut->ev_data;
            if (r == R_ECALL) {
                const uint32_t n = reg(17), a0 = reg(10), a1 = reg(11), a2 = reg(12);
                if (n == 93) { status = 1; code = a0; stopped = true; }
                else if (n == 64) {
                    if (a0 != 1 && a0 != 2) set_reg(10, uint32_t(-9));
                    else {
                        bool bad = false;
                        for (uint32_t i = 0; i < a2; i++) {
                            if (!Ref::ok(a1 + i)) { status = 2; cause = T_LOAD; tval = a1 + i; stop_pc = run_mode ? dut->pc : pc; stopped = bad = true; break; }
                            out += char(mem[a1 + i]); fputc(mem[a1 + i], stdout);
                        }
                        if (!bad) set_reg(10, a2);
                    }
                } else if (n == 63) {
                    if (a0 != 0) set_reg(10, uint32_t(-9));
                    else {
                        uint32_t k = 0; bool bad = false;
                        while (k < a2 && in_pos < input.size()) {
                            if (!Ref::ok(a1 + k)) { status = 2; cause = T_STORE; tval = a1 + k; stop_pc = run_mode ? dut->pc : pc; stopped = bad = true; break; }
                            vm_write(a1 + k, uint8_t(input[in_pos++])); k++;
                        }
                        if (!bad) set_reg(10, k);
                    }
                } else if (n == 0x5000) { set_reg(10, uint32_t(clocks)); set_reg(11, uint32_t(clocks >> 32)); }
                else if (n == 0x5001 || n == 0x5002) {
                    const bool peek = n == 0x5001;
                    const uint32_t w = peek ? a1 : a2;
                    if (a0 >= SPACE) { status = 2; cause = peek ? T_LOAD : T_STORE; tval = a0; stop_pc = run_mode ? dut->pc : pc; stopped = true; }
                    else if (w != 1 && w != 2 && w != 4) set_reg(10, peek ? 0 : uint32_t(-22));
                    else if (peek) { uint32_t v = 0; for (uint32_t i = 0; i < w; i++) v |= uint32_t(mem[a0 + i]) << (8 * i); set_reg(10, v); }
                    else { for (uint32_t i = 0; i < w; i++) vm_write(a0 + i, uint8_t(a1 >> (8 * i))); set_reg(10, 0); }
                } else set_reg(10, uint32_t(-38));
                if (!stopped) { drain(); dut->resume = 1; tick(); }
            } else if (r >= R_DLB && r <= R_DLW) {
                const unsigned w = (r == R_DLB || r == R_DLBU) ? 1 : (r == R_DLH || r == R_DLHU) ? 2 : 4;
                uint32_t v = 0;
                for (unsigned i = 0; i < w; i++) v |= uint32_t(mem[ea + i]) << (8 * i);
                drain(); dut->resume = 1; dut->resume_val = v; tick();
            } else if (r == R_DFETCH) {
                // The VM fetches the instruction; the core decodes it and parks,
                // and the step below commits it (or presents its event).
                drain(); dut->resume = 1; dut->resume_val = rd32(ea); tick();
                drain(); dut->step = 1; tick();
                while (dut->busy || core_wr_busy()) tick();
                r = dut->result;
                if (r != R_NEXT) { events++; goto again; }
            } else if (r >= R_DSB && r <= R_DSW) {
                const unsigned w = r == R_DSB ? 1 : r == R_DSH ? 2 : 4;
                for (unsigned i = 0; i < w; i++) vm_write(ea + i, uint8_t(data >> (8 * i)));
                drain(); dut->resume = 1; tick();
            } else {
                status = 2; cause = trap_of(r); tval = ea; stop_pc = run_mode ? dut->pc : pc; stopped = true;
                if (!cause) { snprintf(msg, sizeof msg, "unknown result %u\n", r); fail += msg; }
            }
        }
        if (prof) { const char *mn = mnemonic(iw_pre); auto &h = hist[mn ? mn : "(illegal)"]; h.first++; h.second += clocks - c0; }
        // The model runs the same instruction whole; then the two must agree.
        if (run_mode) {
            // (every retire was checked as it happened; an instruction that stops the
            // run - an exit, a trap - never retires, so the model runs it here)
            if (!g_fail.empty()) { fail += g_fail; break; }
            instret = g_instret;
            if (stopped) ref.step();
        } else if (!stopped) {
            instret++;
            ref.step();
            if (ref.nondet) { ref.x[10] = reg(10); if (ref.x[17] == 0x5000) ref.x[11] = reg(11); ref.nondet = false; }
            if (watch >= 0 && trace && instret <= trace)
                printf("           after: %s core=%08x ref=%08x  (result %u, events %llu)\n", abi[watch], reg(unsigned(watch)), ref.x[watch], r, events);
#ifdef RV_MEM
            if (watch >= 0 && trace && instret <= trace)
                printf("           the core committed iw=%08x rd=%u res=%08x\n",
                       dut->rootp->rv_mem_tb__DOT__u_core__DOT__w_iw, dut->rootp->rv_mem_tb__DOT__u_core__DOT__w_rd,
                       dut->rootp->rv_mem_tb__DOT__u_core__DOT__w_res);
#endif
            bool same = ref.status == 0 && ref.pc == dut->pc;
            for (int i = 0; i < 32 && same; i++) same = ref.x[i] == reg(i);
            if (!same) {
                snprintf(msg, sizeof msg, "LOCKSTEP: diverged after instruction %llu at %08x (%08x %s)\n", instret, pc, iw_pre,
                         mnemonic(iw_pre) ? mnemonic(iw_pre) : "?");
                fail += msg;
                printf("core pc=%08x ref pc=%08x (ref status %u)\n", dut->pc, ref.pc, ref.status);
                for (int i = 0; i < 32; i++) if (ref.x[i] != reg(i)) printf("  differs: %s core=%08x ref=%08x\n", abi[i], reg(i), ref.x[i]);
                break;
            }
        } else {
            ref.step();
        }
    }
    fflush(stdout);
    if (!out.empty() && out.back() != '\n') printf("\n");
    if (status == 1) printf("rvvm: exit %d\n", int32_t(code));
    else if (status == 2) printf("rvvm: trap %s at pc=%08x tval=%08x\n", cause_name(cause), stop_pc, tval);
    const unsigned long long run = clocks - start;
    printf("rvvm: %llu instructions, %llu clocks, %.2f clocks/instruction (the core alone), %llu events\n",
           instret, run, instret ? double(run) / double(instret) : 0.0, events);
    if (pipeprof) {
        const double n = double(pp[0]);
        printf("pipeprof: %llu busy clocks, %llu retires (%.2f/clk); fetch wait %.1f%%, data wait %.1f%%, load-use %.1f%%, mul/div %.1f%%, "
               "governor %.1f%%, pipe empty %.1f%%, store in flight %.1f%%; E redirects %llu, D redirects %llu\n",
               pp[0], pp[1], pp[1] / n, 100 * pp[2] / n, 100 * pp[3] / n, 100 * pp[4] / n, 100 * pp[5] / n,
               100 * pp[6] / n, 100 * pp[9] / n, 100 * pp[10] / n, pp[7], pp[8]);
        printf("pipeprof: fetch wait by rv_mem state IDLE %llu LOOK %llu DR %llu IL %llu FILL %llu WR %llu REPLY %llu PF %llu; "
               "its row held %llu, an outstanding request %llu\n",
               ppf[0], ppf[1], ppf[2], ppf[3], ppf[4], ppf[5], ppf[6], ppf[7], ppfh, ppfo);
    }
    printf("rvvm: exposed %.2f clocks/step (step to result, gap 0..%llu), %llu cancels\n",
           instret ? double(exposed) / double(instret + events) : 0.0, gap, cancels);

    if (fail.empty()) {
        if (ref.status != status) { snprintf(msg, sizeof msg, "LOCKSTEP: status core=%u ref=%u\n", status, ref.status); fail += msg; }
        else if (status == 1 && ref.code != code) { snprintf(msg, sizeof msg, "LOCKSTEP: exit core=%d ref=%d\n", int32_t(code), int32_t(ref.code)); fail += msg; }
        else if (status == 2 && (ref.cause != cause || ref.tval != tval || ref.pc != stop_pc)) {
            snprintf(msg, sizeof msg, "LOCKSTEP: trap core=%u/%08x@%08x ref=%u/%08x@%08x\n", cause, tval, stop_pc, ref.cause, ref.tval, ref.pc);
            fail += msg;
        }
        for (int i = 0; i < 32; i++)
            if (ref.x[i] != reg(i)) { snprintf(msg, sizeof msg, "LOCKSTEP: at the stop %s core=%08x ref=%08x\n", abi[i], reg(i), ref.x[i]); fail += msg; }
        if (out != ref.out) fail += "LOCKSTEP: console output differs\n";
        size_t bad = 0, first = 0;
        for (uint32_t i = 0; i < SPACE; i++) if (mem[i] != ref.m[i]) { if (!bad++) first = i; }
        if (bad) { snprintf(msg, sizeof msg, "LOCKSTEP: %zu bytes differ, first at %06zx (core %02x ref %02x)\n", bad, first, mem[first], ref.m[first]); fail += msg; }
#ifdef RV_MEM
        fail += l2_err;
        size_t mb = 0, mf = 0;
        for (uint32_t i = 0; i < SPACE; i++) if (mirror[i] != mem[i]) { if (!mb++) mf = i; }
        if (mb) { snprintf(msg, sizeof msg, "MIRROR: %zu bytes differ from memory, first at %06zx\n", mb, mf); fail += msg; }
        printf("rvvm: L2: %llu probes, %llu direct reads, %llu fills, %llu evictions, %llu word writes, %llu records\n",
               l2_probes, l2_reads, l2_fills, l2_evicts, l2_writes, recs);
#endif
        if (fail.empty()) printf("rvvm: lockstep with the reference: %llu instructions agree\n", instret);
    }
    if (prof && !hist.empty()) {
        std::vector<std::pair<std::string, std::pair<unsigned long long, unsigned long long>>> v(hist.begin(), hist.end());
        std::sort(v.begin(), v.end(), [](auto &x, auto &y) { return x.second.second > y.second.second; });
        printf("%-10s %12s %8s %14s %8s %10s\n", "insn", "count", "count%", "clocks", "clk%", "clk/insn");
        for (auto &e : v)
            printf("%-10s %12llu %7.2f%% %14llu %7.2f%% %10.2f\n", e.first.c_str(), e.second.first,
                   100.0 * e.second.first / std::max(1ull, instret), e.second.second, 100.0 * e.second.second / std::max(1ull, run),
                   double(e.second.second) / e.second.first);
    }
    const bool ok = fail.empty() &&
                    (expect_trap >= 0 ? (status == 2 && long(cause) == expect_trap) : (status == 1 && code == 0));
    if (!fail.empty()) printf("%sFAIL\n", fail.c_str());
    delete dut;
    return ok ? 0 : 1;
}
