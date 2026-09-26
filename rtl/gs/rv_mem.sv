`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// rv_mem - the RISC-V engine's memory side (docs/REQ_RVVM.md section 9, "The
// engine on the L2"): between rtl/gs/rv_core.sv's two ports and the L2
// (rtl/gs/page_cam.sv), outside L1, a DMA layer of its own.
//
// WHAT IT SERVES ITSELF.  An address whose bank is in the engine-direct range
// [dlo, dhi] (the permission map; the identity map makes a guest address the
// 65816's) - every other access goes back to the core as DELEGATED, for the VM
// to perform with all of the IIgs's semantics.
//
// READS go through a ROW BUFFER for fetches, a ROW CACHE (DROWS rows) for loads - 16-byte L2
// row, four words, answered on the clock it is asked on a hit (and the fetch
// row is PEEKED for the core's next pc as it writes back: pk_*) - and behind them a
// four-entry TRANSLATION TABLE, {bank, page} to the L2's {set, way}:
//   * a translation hit is a DIRECT WAY READ (dr_*), as an L1 fill is;
//   * a miss PROBES the L2 by page (il_*), which answers the row and where it
//     is, and the entry is installed (its page pinned: ref_*);
//   * a probe that misses STARTS A FILL when il_fill is set (page_cam fills
//     it as it fills an op-path read miss), and the fill's retag is reported
//     on op_place_*; the memory side waits for that report (or a timeout: the
//     L2 drops a fill it cannot start) and probes again.  il_fill is set only
//     for a committed request: a SPECULATION's miss (req_spec) is answered
//     ABORT - a speculation never fills (REQ_RVVM), the step redoes it.
// The L2's eviction broadcast kills a translation it names - including one a
// direct read is waiting on, which then probes instead.  A probe's answer is
// only as fresh as its ack: if the L2 evicts anything between the probe's ack
// and its answer, the row is used (it was read before) but the translation is
// not installed - a slot evicted in that window would otherwise be trusted
// for a page it no longer holds.
//
// WRITES are aligned words with byte enables through the widened posted seam
// (pw_*), which looks the page up itself: no translation.  A write updates a
// row buffer holding its row in place, and is reported to the stream as the
// engine-write record (rec_*, tag 0xB: REQ_RVVM "The engine-write record"),
// held until the stream takes it; a store waits while one is still held.
//
// COHERENCE.  The rows (fetch, next, the data row cache) are copies of guest
// memory.  The snoop (wsn_*: a 65816 data write outside the window) drops the
// row it names; `inval` (anything else that writes guest memory: an override's
// DMA, the cache's invalidation) drops them all; an engine store merges into
// every row holding its word.  A row that a write overtook on its way is used
// once and not kept (`stale`).  Emptying everything on every 65816 write - as
// before the row cache - threw it away on each of the VM's stack pushes.
//////////////////////////////////////////////////////////////////////////////////
module rv_mem #(
    parameter integer SIDX = 4,     // the L2's set index bits (16 sets)
    parameter integer LEV  = 3,     // ...and way bits (8 ways)
    // DIRECT_WRITES = 0: stores are DELEGATED like any non-direct access
    // (integration rung 3a: reads engine-direct, writes still the VM's until
    // the posted seam carries words)
    parameter integer DIRECT_WRITES = 1,
    parameter integer DROWS = 512,  // the data row cache: rows, direct-mapped, in block RAM (a power of two)
    parameter integer IROWS = 512,  // the instruction row cache, likewise
    // TN: the page -> {set, way} table's entries (a power of two).  Misnamed a
    // translation - the map is the identity - it lets a row miss use the direct
    // way read instead of a probe through the L2's directory.  Probing every
    // miss instead was measured slower (Embench 1.763 -> 1.791, nsichneu +15%).
    parameter integer TN = 4
) (
    input  wire              clk,
    input  wire              rst,
    input  wire  [7:0]       dlo,
    input  wire  [7:0]       dhi,
    // THE SNOOP: a 65816 data write (outside the window), and where.  The rows
    // it names are dropped; anything else that writes guest memory is `inval`,
    // which drops them all.
    input  wire              wsn_v,
    input  wire  [23:0]      wsn_a,
    input  wire              inval,
    // the core
    input  wire              req_spec,
    input  wire              f_req,
    input  wire  [21:0]      f_addr,
    input  wire  [21:0]      f_pre,         // the core's next fetch address (a guess: a wrong one costs a clock)
    output wire              f_valid,
    output logic             f_delegate,
    output logic             f_abort,
    output wire  [31:0]      f_data,
    input  wire              d_req,
    input  wire              d_we,
    input  wire  [21:0]      d_addr,
    input  wire  [21:0]      d_pre,         // the core's next data address (its execute stage)
    input  wire  [3:0]       d_be,
    input  wire  [31:0]      d_wdata,
    output wire              d_valid,
    output logic             d_delegate,
    output logic             d_abort,
    output wire  [31:0]      d_rdata,
    // THE PEEK: the fetch row buffer, looked up combinationally for the core's
    // next pc as it writes back (a hit starts that instruction with no fetch)
    input  wire  [21:0]      pk_addr,
    input  wire              pk_use,        // the core started an instruction from the peek
    output wire              pk_hit,
    output wire  [31:0]      pk_word,
    // the L2: probe by page
    output logic             il_req,
    output logic [15:0]      il_ppn,
    output logic [3:0]       il_line,
    output logic             il_fill,
    input  wire              il_ack,
    input  wire              il_done,
    input  wire              il_ok,
    input  wire  [127:0]     il_row,
    input  wire  [SIDX-1:0]  il_set,
    input  wire  [LEV-1:0]   il_way,
    // the L2: direct way read
    output logic             dr_req,
    output logic [SIDX-1:0]  dr_set,
    output logic [LEV-1:0]   dr_way,
    output logic [3:0]       dr_line,
    input  wire              dr_ack,
    input  wire              dr_done,
    input  wire  [127:0]     dr_row,
    // the L2: every fill's retag (the placement report)
    input  wire              op_place_v,
    input  wire  [15:0]      op_place_ppn,
    // the L2: a word write (the widened posted seam)
    output logic             pw_req,
    output logic [21:0]      pw_addr,
    output logic [3:0]       pw_be,
    output logic [31:0]      pw_data,
    input  wire              pw_ack,
    // the L2's eviction broadcast
    input  wire              evict_v,
    input  wire  [SIDX-1:0]  evict_set,
    input  wire  [LEV-1:0]   evict_way,
    // the engine's references (its pins)
    output logic             ref_v,
    output logic             ref_on,
    output logic [SIDX-1:0]  ref_set,
    output logic [LEV-1:0]   ref_way,
    // the stream: the engine-write record
    output logic             rec_v,         // held until rec_take: the stream never sheds one
    output logic [63:0]      rec,
    input  wire              rec_take,
    // a posted store not yet landed (and its landing's clock): the window holds
    // the 65816 in its STEP/RUN read until it is down, so no event the VM
    // services can meet a copy of memory the store has not reached yet
    output wire              wr_busy
);
    typedef enum logic [2:0] { M_IDLE, M_LOOK, M_DR, M_IL, M_FILL, M_WR, M_REPLY, M_PF } mst_t;
    mst_t st;

    // ---- the request -------------------------------------------------------------
    logic        is_f;              // the request being served is a fetch
    logic [21:0] ra;                // its word address
    // A fetch and a load are both asked for at once by the pipelined core; each
    // is judged direct (and a hit) on its own, and the one the miss engine
    // serves - `a_now` - is the data request first (the older instruction).
    wire         direct_f = f_addr[21:14] >= dlo && f_addr[21:14] <= dhi;
    wire         direct_d = d_addr[21:14] >= dlo && d_addr[21:14] <= dhi;
    wire         sel_d;             // the miss engine takes the data request
    wire  [21:0] a_now  = sel_d ? d_addr : f_addr;
    wire         direct_now = sel_d ? direct_d : direct_f;
    wire  [15:0] ppn = ra[21:6];    // {bank, page}
    wire  [3:0]  line = ra[5:2];
    wire  [1:0]  wsel = ra[1:0];

    // ---- the rows ----------------------------------------------------------------------
    logic         stale;               // a write to this row (or an inval) since it was asked for
    wire  [19:0]  wsn_row = wsn_a[23:4];

    // THE DATA ROW CACHE: DROWS rows of 16 bytes, direct-mapped by the row's low
    // bits, row and tag in BLOCK RAM.  Its read is registered, so it is addressed
    // a clock early: from the core's execute stage (d_pre) until a request is
    // up, then from the request itself - the row is out on the request's first
    // clock and a hit still answers then.  Valid bits in flops, read registered
    // beside it (the snoop drops one, an inval all, in one clock).
    localparam integer DI = $clog2(DROWS);
    localparam integer TW = 20 - DI;            // the tag: the row's bits above the index
    // THE HIT IS DECIDED WHEN THE ROW IS READ, a clock before it is used: a LUTRAM
    // copy of the tags is read asynchronously at the same address as the RAM, and
    // the hit is registered beside the RAM's output.  On the request's clock a hit
    // is a registered flag and a compare of two registers (the row read against
    // the row asked for) - the tag compare is not in front of the pipe's stalls.
    logic [DROWS-1:0]  dc_v;
    (* ram_style = "block" *) logic [127:0] dc_mem [DROWS];
    logic [TW-1:0]     dc_tagl [DROWS];         // the tags, read asynchronously
    logic [127:0]      dc_row;                  // the row at rd_row_q
    logic [19:0]       rd_row_q;                // the row read
    logic              dc_hitq;                 // ...and it was there, valid, as the read saw it
    wire  [DI-1:0]     d_idx   = d_addr[DI+1:2];
    wire  [DI-1:0]     ra_idx  = ra[DI+1:2];
    // (a store reads its own row - its merge's - on the clock it is taken; a load
    // its own while it waits; otherwise the next one, from the execute stage)
    wire  [19:0]       rd_row  = (st == M_WR) ? pw_addr[21:2] :
                                 (d_req && (d_we || !d_valid)) ? d_addr[21:2] : d_pre[21:2];
    wire  [DI-1:0]     rd_idx  = rd_row[DI-1:0];
    wire               d_in_c  = dc_hitq && rd_row_q == d_addr[21:2];

    function automatic logic [31:0] word_of(input logic [127:0] r, input logic [1:0] k);
        return r[{k, 5'd0} +: 32];
    endfunction
    function automatic logic [127:0] merge_word(input logic [127:0] r, input logic [1:0] k,
                                                input logic [3:0] be, input logic [31:0] d);
        logic [127:0] o;
        o = r;
        for (int i = 0; i < 4; i++)
            if (be[i]) o[32 * int'(k) + 8 * i +: 8] = d[8 * i +: 8];
        return o;
    endfunction

    // ---- the translation table ---------------------------------------------------------
    localparam integer TW_ = $clog2(TN);
    logic [TN-1:0]   t_v;
    logic [15:0]     t_ppn [TN];
    logic [SIDX-1:0] t_set [TN];
    logic [LEV-1:0]  t_way [TN];
    logic [TW_-1:0]  t_next;            // round-robin replacement
    logic            t_hit;
    logic [TW_-1:0]  t_idx;
    always_comb begin
        t_hit = 1'b0; t_idx = '0;
        for (int i = 0; i < TN; i++)
            if (t_v[i] && t_ppn[i] == ppn) begin t_hit = 1'b1; t_idx = TW_'(i); end
    end
    // ...and the same lookup on the live request, so a miss issues its read on
    // the clock it is presented (no separate lookup state)
    wire  [15:0]     ppn_now  = a_now[21:6];
    logic            t_hit_now;
    logic [TW_-1:0]  t_idx_now;
    always_comb begin
        t_hit_now = 1'b0; t_idx_now = '0;
        for (int i = 0; i < TN; i++)
            if (t_v[i] && t_ppn[i] == ppn_now) begin t_hit_now = 1'b1; t_idx_now = TW_'(i); end
    end

    // THE ONE-CLOCK HIT: a request that finds its row in a row cache is answered
    // on the clock it is presented, not registered through M_REPLY.  M_REPLY
    // carries only the replies without a word - a delegation or an abort - so
    // its valid bits are registered and its data is none.
    logic        f_valid_q, d_valid_q;

    // THE INSTRUCTION ROW CACHE: IROWS rows of 16 bytes, direct-mapped, row and tag
    // in BLOCK RAM read a clock early from the core's next fetch address (f_pre).
    // A read of another index than the fetch asks for (the guess was wrong) makes
    // it wait a clock, never a miss.  Valid bits in flops, read registered beside
    // it; a LUTRAM copy of the tags lets a store or the snoop drop only a row that
    // really holds what was written, and the prefetch see what is there.
    localparam integer IDI = $clog2(IROWS);
    localparam integer ITW = 20 - IDI;
    logic [IROWS-1:0]  ic_v;
    (* ram_style = "block" *) logic [127:0] ic_mem [IROWS];
    logic [ITW-1:0]    ic_tagl [IROWS];         // the tags, read asynchronously
    logic [127:0]      ic_out;
    logic [19:0]       ic_row_q;                // the row read
    logic              ic_hitq;                 // ...and it was held, as the read saw it
    // (the read is this fetch's row: a hit, or - not held - a real miss)
    wire               ic_match  = ic_row_q == f_addr[21:2];
    wire               ic_tagok  = ic_hitq;
    function automatic logic ic_has(input logic [19:0] row);
        return ic_v[row[IDI-1:0]] && ic_tagl[row[IDI-1:0]] == row[19:IDI];
    endfunction

    // THE PREFETCH: while nothing needs the miss engine, the row after the one
    // last fetched - same page, its translation in the table, not already held -
    // is read into the cache (M_PF), so a straight run finds it there.  A fetch
    // asking for it as it lands is answered then.
    logic [19:0]  pf_tag;
    logic         pf_stale;
    logic [19:0]  f_last;              // the row the last answered fetch came from
    logic         f_last_v;
    wire hit_ok  = (st == M_IDLE || st == M_PF) && !wsn_v && !inval;
    // (a fetch hit takes no port but the cache's: it goes on while a store is out -
    // the store dropped its own row's entry as it was taken)
    wire f_fast  = f_req && direct_f && ic_match && ic_tagok && (hit_ok || (st == M_WR && !wsn_v && !inval));
    wire d_fast  = hit_ok && d_req && !d_we && direct_d && d_in_c;
    // THE POSTED STORE: a direct store is answered on the clock it is taken, and
    // goes out through the seam behind the core's back (M_WR); every request
    // after it waits for its landing (M_WR is not a state that serves one).
    // (the record slot must already be free: waiting on a same-clock take would put
    // the event stream's arbitration in front of the pipe's stall chain)
    wire st_post = (st == M_IDLE) && d_req && d_we && direct_d && DIRECT_WRITES != 0 &&
                   !rec_v && !wsn_v;
    wire d_need = d_req && !d_fast;         // the data request needs the miss engine (or the seam)
    // a fetch needs the miss engine when it is not direct, or its row is not held
    // (the row read is its own index's and the tag is another's)
    wire f_need = f_req && (!direct_f || (ic_match && !ic_tagok));
    assign sel_d = d_need;
    logic wr_tail;
    assign wr_busy = (st == M_WR) || wr_tail;
    // ...and a direct read's row answers on the clock it lands (M_DR's dr_done)
    wire dr_land = (st == M_DR) && dr_done;
    // ...and a probe's, likewise (M_IL's il_done with the row)
    wire il_land = (st == M_IL) && il_done && il_ok;
    // a fetch asking for the very row the prefetch is bringing: answered as it lands
    wire pf_done = dr_done;
    wire [127:0] pf_row = dr_row;
    wire f_pfland = (st == M_PF) && pf_done && f_req && direct_f && f_addr[21:2] == pf_tag &&
                    !pf_stale && !wsn_v && !inval;
    assign f_valid = f_valid_q || f_fast || f_pfland || (dr_land && is_f) || (il_land && is_f);
    assign f_data  = f_fast ? word_of(ic_out, f_addr[1:0]) :
                     f_pfland ? word_of(pf_row, f_addr[1:0]) :
                     dr_land ? word_of(dr_row, wsel) :
                     il_land ? word_of(il_row, wsel) : 32'd0;
    assign d_valid = d_valid_q || d_fast || st_post || (dr_land && !is_f) || (il_land && !is_f);
    assign d_rdata = d_fast ? word_of(dc_row, d_addr[1:0]) :
                     dr_land ? word_of(dr_row, wsel) :
                     il_land ? word_of(il_row, wsel) : 32'd0;
    assign pk_hit  = 1'b0;                  // (the old core's peek: the cache serves the fetch itself)
    assign pk_word = 32'd0;
    // the prefetch's translation: the last fetched row's page in the table
    logic            pf_t_hit;
    logic [SIDX-1:0] pf_set;
    logic [LEV-1:0]  pf_way;
    wire  [19:0]     pf_next = f_last + 20'd1;
    always_comb begin
        pf_t_hit = 1'b0; pf_set = '0; pf_way = '0;
        for (int i = 0; i < TN; i++)
            if (t_v[i] && t_ppn[i] == f_last[19:4]) begin pf_t_hit = 1'b1; pf_set = t_set[i]; pf_way = t_way[i]; end
    end
    wire pf_go = (st == M_IDLE) && !f_need && !d_need && f_last_v && f_last[3:0] != 4'hF &&
                 !ic_has(pf_next) && pf_tag != pf_next && !wsn_v && !inval &&
                 pf_t_hit && !(evict_v && evict_set == pf_set && evict_way == pf_way);

    // A pin to raise after an unpin went out on the same install.
    logic            pin_pend;
    logic            il_acked, il_evicted;  // the probe is out; an eviction since its ack
    logic [7:0]      fill_wait;             // clocks left before probing again without a report
    logic [SIDX-1:0] pin_set;
    logic [LEV-1:0]  pin_way;

    // Keep a row that answered the core combinationally (unless it went stale).
    wire keep_ok = !stale && !inval && !(wsn_v && wsn_row == ra[21:2]);
    task automatic keep_row(input logic [127:0] r);
        if (keep_ok) begin
            if (is_f) ic_v[ra[IDI+1:2]] <= 1'b1;     // (the rows themselves: the caches' write ports)
            else      dc_v[ra_idx] <= 1'b1;
        end
        st <= M_IDLE;
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            st <= M_IDLE; t_v <= '0; t_next <= '0; dc_v <= '0; ic_v <= '0;
            pf_stale <= 1'b0; f_last_v <= 1'b0; pf_tag <= 20'hFFFFF;
            f_valid_q <= 1'b0; f_delegate <= 1'b0; f_abort <= 1'b0;
            d_valid_q <= 1'b0; d_delegate <= 1'b0; d_abort <= 1'b0;
            il_req <= 1'b0; dr_req <= 1'b0; pw_req <= 1'b0; il_fill <= 1'b0;
            ref_v <= 1'b0; rec_v <= 1'b0; pin_pend <= 1'b0; stale <= 1'b0; wr_tail <= 1'b0;
            il_acked <= 1'b0; il_evicted <= 1'b0;
        end else begin
            ref_v <= 1'b0;
            wr_tail <= (st == M_WR) && pw_ack;      // the landing's clock (the classified stream's)
            if (rec_take) rec_v <= 1'b0;
            if (pin_pend) begin
                ref_v <= 1'b1; ref_on <= 1'b1; ref_set <= pin_set; ref_way <= pin_way;
                pin_pend <= 1'b0;
            end
            // the row the fetch is in (the prefetch runs ahead of it)
            if (f_req && f_valid && direct_f) begin f_last <= f_addr[21:2]; f_last_v <= 1'b1; end
            // An eviction kills the translation it names.
            if (evict_v)
                for (int i = 0; i < TN; i++)
                    if (t_set[i] == evict_set && t_way[i] == evict_way) t_v[i] <= 1'b0;

            case (st)
            M_IDLE: begin
                // (a request waits out a snoop's clock: its staleness is judged against ra)
                if ((d_need || f_need) && !wsn_v) begin
                    is_f  <= !sel_d;
                    ra    <= a_now;
                    stale <= 1'b0;
                    if (!direct_now) begin
                        if (!sel_d) begin f_valid_q <= 1'b1; f_delegate <= 1'b1; end
                        else        begin d_valid_q <= 1'b1; d_delegate <= 1'b1; end
                        st <= M_REPLY;
                    end else if (sel_d && d_we && DIRECT_WRITES == 0) begin
                        d_valid_q <= 1'b1; d_delegate <= 1'b1;
                        st <= M_REPLY;
                    end else if (sel_d && d_we) begin
                        // one record in hand at a time: the next store waits for the take
                        if (st_post) begin          // (answered now: st_post)
                            pw_req  <= 1'b1;
                            pw_addr <= d_addr;
                            pw_be   <= d_be;
                            pw_data <= d_wdata;
                            st      <= M_WR;
                        end
                    end else if (t_hit_now && !(evict_v && evict_set == t_set[t_idx_now] && evict_way == t_way[t_idx_now])) begin
                        // a translation hit: the direct read goes out now
                        dr_req <= 1'b1; dr_set <= t_set[t_idx_now]; dr_way <= t_way[t_idx_now]; dr_line <= a_now[5:2];
                        st <= M_DR;
                    end else begin
                        il_req <= 1'b1; il_ppn <= ppn_now; il_line <= a_now[5:2]; il_fill <= !req_spec;
                        st <= M_IL;
                    end
                end else if (pf_go) begin
                    dr_req <= 1'b1; dr_set <= pf_set; dr_way <= pf_way; dr_line <= pf_next[3:0];
                    pf_tag <= pf_next; pf_stale <= 1'b0;
                    st <= M_PF;
                end
            end

            // The next row's read: kept unless a write to it or an invalidate came
            // since it was asked; given up if its way is evicted before the ack.
            M_PF: begin
                if (dr_req && dr_ack) dr_req <= 1'b0;
                else if (dr_req && ((evict_v && evict_set == dr_set && evict_way == dr_way) ||
                                    d_need || (f_need && f_addr[21:2] != pf_tag))) begin
                    // its way evicted, or a demand request is waiting: give it up
                    dr_req <= 1'b0; st <= M_IDLE;
                end
                if (dr_done) begin
                    if (pf_keep) ic_v[pf_tag[IDI-1:0]] <= 1'b1;   // (the row: the cache's write port)
                    st <= M_IDLE;
                end
            end

            // A translation hit reads the row directly; a miss probes.
            M_LOOK: begin
                if (t_hit && !(evict_v && evict_set == t_set[t_idx] && evict_way == t_way[t_idx])) begin
                    dr_req <= 1'b1; dr_set <= t_set[t_idx]; dr_way <= t_way[t_idx]; dr_line <= line;
                    st <= M_DR;
                end else begin
                    il_req <= 1'b1; il_ppn <= ppn; il_line <= line; il_fill <= !req_spec;
                    st <= M_IL;
                end
            end

            // One direct read out: its row, or - if the L2 evicted the way
            // before taking the read - a probe instead.
            M_DR: begin
                if (dr_req && dr_ack) dr_req <= 1'b0;
                else if (dr_req && evict_v && evict_set == dr_set && evict_way == dr_way) begin
                    dr_req <= 1'b0;
                    il_req <= 1'b1; il_ppn <= ppn; il_line <= line; il_fill <= !req_spec;
                    st <= M_IL;
                end
                if (dr_done) keep_row(dr_row);       // (answered combinationally: dr_land)
            end

            M_IL: begin
                // (an eviction on the ack's own clock counts too)
                if (il_ack) begin il_req <= 1'b0; il_acked <= 1'b1; il_evicted <= evict_v; end
                else if (il_acked && evict_v) il_evicted <= 1'b1;
                if (il_done) begin
                    il_acked <= 1'b0;
                    if (il_ok && (il_evicted || evict_v)) begin
                        keep_row(il_row);           // (answered combinationally: il_land; with an eviction
                                                    // since the ack, used but its translation not installed)
                    end else if (il_ok) begin
                        // install: unpin what it replaces now, pin the new one next clock
                        if (t_v[t_next]) begin
                            ref_v <= 1'b1; ref_on <= 1'b0; ref_set <= t_set[t_next]; ref_way <= t_way[t_next];
                        end
                        pin_pend <= 1'b1; pin_set <= il_set; pin_way <= il_way;
                        t_v[t_next]   <= 1'b1;
                        t_ppn[t_next] <= ppn;
                        t_set[t_next] <= il_set;
                        t_way[t_next] <= il_way;
                        t_next        <= t_next + 1'b1;
                        keep_row(il_row);
                    end else if (req_spec) begin
                        if (is_f) begin f_valid_q <= 1'b1; f_abort <= 1'b1; end
                        else      begin d_valid_q <= 1'b1; d_abort <= 1'b1; end
                        st <= M_REPLY;
                    end else if (!il_fill) begin
                        // a speculation's probe, now the step's: probe again, filling
                        il_req <= 1'b1; il_fill <= 1'b1;
                    end else begin
                        fill_wait <= 8'd255;
                        st        <= M_FILL;
                    end
                end
            end

            // The fill this probe started: its report, or give up waiting and probe again.
            M_FILL: begin
                fill_wait <= fill_wait - 8'd1;
                if ((op_place_v && op_place_ppn == ppn) || fill_wait == 8'd0) begin
                    il_req <= 1'b1; il_ppn <= ppn; il_line <= line; il_fill <= 1'b1;
                    st     <= M_IL;
                end
            end

            M_WR: if (pw_ack) begin
                pw_req <= 1'b0;
                // the row buffers stay true to memory
                // the engine-write record: {tag B, bank, byte enables, address[15:0]}, the data
                rec_v <= 1'b1;
                rec   <= {pw_data, 4'hB, pw_addr[21:14], pw_be, pw_addr[13:0], 2'b00};
                st <= M_IDLE;                       // (the core was answered at the issue)
            end

            M_REPLY: begin
                f_valid_q <= 1'b0; f_delegate <= 1'b0; f_abort <= 1'b0;
                d_valid_q <= 1'b0; d_delegate <= 1'b0; d_abort <= 1'b0;
                st <= M_IDLE;
            end

            default: st <= M_IDLE;
            endcase

            // a store taken drops the instruction row it writes, if held (code written
            // is fetched again from the L2 - the store's landing - after fence.i)
            if (st_post && ic_has(d_addr[21:2])) ic_v[d_addr[IDI+1:2]] <= 1'b0;
            // THE INVALIDATIONS, last so they win over a fill on the same clock:
            // an inval drops every row; the snoop drops the row it names.
            if (inval) begin
                ic_v <= '0; dc_v <= '0; stale <= 1'b1; pf_stale <= 1'b1;
            end else if (wsn_v) begin
                if (ic_has(wsn_row)) ic_v[wsn_row[IDI-1:0]] <= 1'b0;
                dc_v[wsn_row[DI-1:0]] <= 1'b0;
                if (wsn_row == ra[21:2]) stale <= 1'b1;
                if (wsn_row == pf_tag)   pf_stale <= 1'b1;
            end
        end
    end

    // The row cache's write port: a data row arriving (a direct read landing, a
    // probe's row), or an engine store merging into a row it holds - the row
    // read for the store's own address (the core holds it through the store).
    wire [DI-1:0] pw_idx  = pw_addr[DI+1:2];
    wire          pw_dhit = dc_hitq && rd_row_q == pw_addr[21:2];
    // (only a row that is kept: an entry whose valid bit still stands for an
    // older row must never take a row that went stale on its way)
    wire dc_fill_dr = (st == M_DR) && dr_done && !is_f && keep_ok;
    wire dc_fill_il = (st == M_IL) && il_done && il_ok && !is_f && keep_ok;
    wire dc_merge   = (st == M_WR) && pw_ack && pw_dhit;
    wire          dc_we = dc_merge || dc_fill_dr || dc_fill_il;
    wire [DI-1:0] dc_wa = dc_merge ? pw_idx : ra_idx;
    wire [127:0]  dc_wd = dc_merge ? merge_word(dc_row, pw_addr[1:0], pw_be, pw_data)
                                   : (dc_fill_dr ? dr_row : il_row);
    always_ff @(posedge clk) begin
        if (dc_we) begin
            dc_mem[dc_wa] <= dc_wd;
            if (!dc_merge) dc_tagl[dc_wa] <= ra[21:DI+2];
        end
        dc_row   <= dc_mem[rd_idx];
        rd_row_q <= rd_row;
        // the hit as this read will stand: not if an inval, a snoop or a write to
        // the same entry on this clock (the RAM reads the old row then)
        dc_hitq  <= dc_v[rd_idx] && dc_tagl[rd_idx] == rd_row[19:DI] && !inval &&
                    !(wsn_v && wsn_row[DI-1:0] == rd_idx) && !(dc_we && dc_wa == rd_idx);
    end

    // The instruction cache's write port: a fetch's row landing (a direct read, a
    // probe's row), or the prefetch's.  Only a kept row.
    wire pf_keep   = (st == M_PF) && pf_done && !pf_stale && !inval && !(wsn_v && wsn_row == pf_tag);
    wire ic_fill_dr = (st == M_DR) && dr_done && is_f && keep_ok;
    wire ic_fill_il = (st == M_IL) && il_done && il_ok && is_f && keep_ok;
    wire           ic_we = ic_fill_dr || ic_fill_il || pf_keep;
    wire [19:0]    ic_wrow = pf_keep ? pf_tag : ra[21:2];
    wire [IDI-1:0] ic_wa = ic_wrow[IDI-1:0];
    wire [127:0]   ic_wd = ic_fill_il ? il_row : pf_keep ? pf_row : dr_row;
    wire [IDI-1:0] ic_rd_idx = f_pre[IDI+1:2];
    wire [19:0]    ic_rd_row = f_pre[21:2];
    // an entry dropped or written on the reading clock reads as not valid
    wire ic_clr = (wsn_v && ic_has(wsn_row) && wsn_row[IDI-1:0] == ic_rd_idx) ||
                  (st_post && ic_has(d_addr[21:2]) && d_addr[IDI+1:2] == ic_rd_idx);
    always_ff @(posedge clk) begin
        if (ic_we) begin
            ic_mem[ic_wa]  <= ic_wd;
            ic_tagl[ic_wa] <= ic_wrow[19:IDI];
        end
        ic_out   <= ic_mem[ic_rd_idx];
        ic_row_q <= ic_rd_row;
        ic_hitq  <= ic_has(ic_rd_row) && !inval && !ic_clr && !(ic_we && ic_wa == ic_rd_idx);
    end
endmodule
