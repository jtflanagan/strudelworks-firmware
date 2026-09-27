// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// l2_model.h - a model of the L2's ports as the RISC-V engine's memory side
// (rtl/gs/rv_mem.sv) sees them: 16 sets x 8 ways of pages placed by page_cam's
// fold of the page number, the probe (il_*) and the direct read (dr_*) with
// their latencies, fills that evict and broadcast, random evictions of the
// model's own (other L2 users; unpinned ways first), word writes by byte
// enable.  A direct read of a slot that holds no page is an error.
//
// Any Verilated top with rv_mem's L2 face under its own names (sim/rv_mem_tb.sv,
// sim/rvvm_sys.sv with MEM=1): pre_edge() drives the model's side before the
// rising edge, post_edge() takes what the memory side said on it.  Moved here
// from sim/rv_core_main.cpp unchanged (the order of its random draws with it),
// so sim/rvvm_run_main.cpp's application mode has the same L2 as the engine's
// memory-side bench.

#pragma once
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

template <class Top>
struct L2Model {
    std::vector<uint8_t> &mem;
    std::mt19937 &rng;
    const unsigned long long &clocks;
    unsigned evict_one_in = 150;              // other L2 users evict one clock in N (0 = never)
    std::string err;
    std::vector<std::string> ring;            // the last memory-side events, for a mismatch
    int32_t slot_ppn[16][8];
    bool    slot_pin[16][8] = {};
    unsigned long long fills = 0, evicts = 0, probes = 0, reads = 0, writes = 0;

    L2Model(std::vector<uint8_t> &m, std::mt19937 &r, const unsigned long long &c) : mem(m), rng(r), clocks(c) {
        for (auto &s : slot_ppn) for (auto &w : s) w = -1;
    }

    uint32_t rd32(uint32_t a) const { return mem[a] | (mem[a + 1] << 8) | (mem[a + 2] << 16) | (uint32_t(mem[a + 3]) << 24); }
    // page_cam's set: every 4-bit slice of the page number XORed (17 bits at 32 MB)
    static unsigned fold(uint32_t ppn) { unsigned f = 0; for (; ppn; ppn >>= 4) f ^= ppn & 15; return f; }
    bool find(uint32_t ppn, unsigned &set, unsigned &way) const {
        set = fold(ppn);
        for (way = 0; way < 8; way++) if (slot_ppn[set][way] == int32_t(ppn)) return true;
        return false;
    }
    void row_of(uint32_t ppn, unsigned line, uint32_t *w) const {
        const uint32_t a = (ppn << 8) | (line << 4);
        for (int i = 0; i < 4; i++) w[i] = rd32(a + 4 * i);
    }
    // Evict a way of `set` (unpinned first), broadcasting it this clock.
    int evict_in(unsigned set, bool &bcast, unsigned &bset, unsigned &bway) {
        int cand[8], n = 0, any[8], m = 0;
        for (int w = 0; w < 8; w++) {
            if (slot_ppn[set][w] < 0) return w;          // a free way: nothing to evict
            any[m++] = w;
            if (!slot_pin[set][w]) cand[n++] = w;
        }
        const int w = n ? cand[rng() % n] : any[rng() % m];
        slot_ppn[set][w] = -1; bcast = true; bset = set; bway = unsigned(w); evicts++;
        return w;
    }
    void note(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
        char b[200]; va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
        ring.push_back(std::to_string(clocks) + ": " + b);
        if (ring.size() > 24) ring.erase(ring.begin());
    }

    int il_wait = -1, il_done_in = -1, dr_wait = -1, dr_done_in = -1, pw_wait = -1;
    // A request's answer is taken on its ack's clock, as page_cam reads the row
    // RAM just after the ack: an eviction between the ack and the done must not
    // change what comes back.
    bool il_ok_q = false; unsigned il_set_q = 0, il_way_q = 0; uint32_t il_row_q[4] = {}, dr_row_q[4] = {};
    bool pfill_pend = false; int pfill_wait = -1; uint32_t pfill_ppn = 0;   // a probe's fill
    bool dr_empty_q = false; unsigned dr_set_q = 0, dr_way_q = 0;

    void pre_edge(Top *dut) {
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
                il_done_in = 2; il_wait = -1; probes++;
            }
        }
        // the direct read: ack after 0-2 clocks, the row two clocks later
        if (dr_done_in >= 0 && dr_done_in-- == 0) {
            dut->dr_done = 1;
            if (dr_empty_q) { char m[128]; snprintf(m, sizeof m, "L2: a direct read of an empty slot %u/%u\n", dr_set_q, dr_way_q); err += m; }
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
                dr_done_in = 1; dr_wait = -1; reads++;
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
            pfill_pend = false; fills++;
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
                slot_ppn[set][w] = -1; bcast = true; bset = set; bway = unsigned(w); evicts++;
            }
        }
        if (bcast) { dut->evict_v = 1; dut->evict_set = bset; dut->evict_way = bway; note("evict %u/%u", bset, bway); }
        // a word write: ack after 0-2 clocks
        if (dut->pw_req) {
            if (pw_wait < 0) pw_wait = int(rng() % 3);
            if (pw_wait-- == 0) {
                const uint32_t a = uint32_t(dut->pw_addr) << 2;
                for (int i = 0; i < 4; i++) if (dut->pw_be & (1u << i)) mem[a + i] = uint8_t(dut->pw_data >> (8 * i));
                dut->pw_ack = 1; pw_wait = -1; writes++;
            }
        }
    }
    // what the memory side said on that clock
    void post_edge(Top *dut) {
        if (dut->ref_v) slot_pin[dut->ref_set][dut->ref_way] = dut->ref_on;
    }
};
