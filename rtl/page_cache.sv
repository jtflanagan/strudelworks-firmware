`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// page_cache - the machine's memory as ONE PHYSICAL SPACE, cached.
// docs/PAGE_CACHE.md is the design; docs/MEMORY_REFACTOR.md is how it got
// here (Part 3, rungs 4 and 5).
//
// The design this replaces WAS the address space: two fixed 64 KB banks
// addressed one-to-one by the folded bus address, main tagless and
// authoritative, the ROM in a block RAM of its own.  That shape has no answer
// for a 65816 whose code and data are anywhere in 16 MB, so memory is now one
// physical space of 256-byte pages - PPN = {bank, page}, bank 0 main, bank 1
// auxiliary, bank k+1 RamWorks bank k, bank $FF the ROM - with the DDR3
// behind everything and this cache in front of it.
//
//   SETS x WAYS pages of block RAM (128 x 8 = 1024 pages = 256 KB), physically
//   indexed and physically tagged.  The set index is HASHED,
//   set = ppn[SIDX-1:0] ^ ppn[2*SIDX-1:SIDX], which spreads a bank crawl over
//   the sets and lands the whole 128 KB machine plus the ROM in five of every
//   set's eight ways - so an ordinary IIe never evicts anything.
//
//   ONE cache for instructions and data.  A 6502 shares 256-byte pages between
//   code and data and self-modifying code is real, so a split would need a
//   coherence protocol to buy nothing.
//
// THE PIPELINE, in clocks after an entrant (P0):
//
//   P0  the set indexes every way's port A and the tag LUTRAMs; the tags, the
//       valid, dirty and replacement bits are registered
//   P1  WAYS tag compares against the entrant's page -> the one-hot hit way,
//       the victim (an invalid way first, else the replacement bits'), all
//       registered; a WRITE's decision is taken here
//   P2  the rows are out of the block RAMs' second registers; one WAYS:1 row
//       mux, one byte select; a write LANDS on its hit way's port A
//   P3  sub_en/sub_data stand, decided pulses
//
// Three clocks to a byte, exactly as the two-bank design, because the tag
// compare rides beside the row read rather than in front of it: the P0 index
// is a hash of a page number apple_mmu has already computed (its pf_ppn), and
// the compare that decides the way happens while the block RAM is fetching.
//
// ONE ENTRANT PER CLOCK, three kinds: an op (op_present), a posted or host
// write (pw_take), a front's line request (il_ack).  A write lands two clocks
// after its entrant, and the LANDING RESERVATION refuses il_ack and pw_take on
// that clock - a fill may not read a page on the clock a write to it lands.  A
// fill acked BEFORE the landing read the pre-write row and is killed by the
// write's classified snoop upstream (the P+2 law, docs/DLINE.md).  An op can
// never collide with a landing: `busy` covers an op's own P0..P2, and
// rtl/accel_seq.sv dispatches nothing while the data front has a posted write
// short of the cache (its d_pending, dline's drain_sr).
//
// ALWAYS FILL.  The old design CLAIMED an invalid aux page where it stood -
// legitimate when the DDR3 held no copy of it.  Here an invalid entry says
// nothing about whether the page was evicted to the DDR3 before, so every
// miss fills.  A cold machine reads the DDR3's power-up garbage, which is
// what a real Apple's RAM holds (docs/MEMORY.md).
//
// THE MISS: E_SNAP (17 clocks, a DIRTY victim only - its page must leave the
// way's block RAM before the fill overwrites it), E_FILL (16 pipelined beats
// critical-line-first: the requested byte is served the moment its beat
// lands, the retag at the last), E_PATCH (a write miss), E_SETTLE, E_FLUSH
// (16 beats, a dirty victim).  A CLEAN victim - the common case, and the only
// one an ordinary IIe ever has - answers in about thirty clocks against a
// 1 MHz budget of ninety.  Hit-under-miss is free: the victim way is invalid
// from the engine's start, so every other way of every set still answers a
// front's line request.  An OP that misses while the engine runs is counted
// (late_fills) and untouched, as before; an op that hits is served.
//
// WRITES ARE WRITE-BACK, one dirty bit per page, and a dirty page flushes
// WHOLE - sixteen beats of one row of the DDR3 (docs/PAGE_CACHE.md).
//
// THE MONITOR keeps its contract: compare at op_commit, only memory the
// machine itself has (physical banks 0 and 1), against the bus's byte;
// unwritten memory is garbage so the count PLATEAUS rather than reads zero.
//////////////////////////////////////////////////////////////////////////////////
module page_cache #(
    parameter integer SETS = 128,
    parameter integer WAYS = 8
) (
    input  wire        clk,
    // The card's reset.  RES' never comes here: like real RAM, the cache
    // survives the machine being reset.
    input  wire        rst,

    // ---- the classified op (P1), from apple_mmu ----------------------------
    input  wire        cl_valid,
    input  wire [1:0]  cl_cls,
    input  wire [15:0] cl_ppn,        // the PHYSICAL page: {bank, page}
    input  wire [7:0]  cl_off,        // the byte in it
    input  wire        cl_rw,
    input  wire        cl_wr_image,   // a write that lands in the image
    input  wire [7:0]  cl_wdata,     // the write's byte
    input  wire        cl_posted,     // a posted write draining, not an op
    input  wire        pw_pending,    // the front has a write short of here
    output wire        pw_ready,

    // ---- the P0 previews ---------------------------------------------------
    // An op's page and offset one clock before its classification (apple_mmu's
    // pf_ppn/pf_off), and a posted write's, which enter on pw_take.
    input  wire [15:0] pf_ppn,
    input  wire [7:0]  pf_off,
    input  wire        pw_take,
    input  wire [15:0] pw_ppn,
    input  wire [7:0]  pw_off,
    // ...AND A SHADOW DUPLICATE'S (docs/GS.md rung 3e).  apple_mmu emits one
    // a clock behind a shadowed write, down the same path a posted write
    // takes - it sets cl_valid exactly as pw_take does - so it needs an
    // entrant here exactly as pw_take does.  Without one no P0 runs for it:
    // the directory is never read for ITS page, so the hit compare, the
    // victim, the victim's tag and dirty bit, and the row its byte lands in
    // all belong to whatever op went before.  On the IIgs that evicted a
    // page under another page's tag and flushed it over a third.  Low on the
    // IIe build, which emits no duplicates.
    input  wire        shd_take,
    input  wire [15:0] shd_ppn,
    input  wire [7:0]  shd_off,

    // ---- the op itself -----------------------------------------------------
    input  wire [15:0] op_addr,
    input  wire        op_present,
    input  wire        op_commit,
    input  wire        op_divert,
    input  wire [7:0]  data_sync,     // the bus's byte, for the monitor

    output logic       sub_en,
    output logic [7:0] sub_data,
    // THE OP'S WHOLE ROW, beside its byte (2026-09-11, docs/DLINE.md "the
    // miss's read fills the line"): valid with sub_en when the read was
    // served from a resident page - never from a fill's critical beat,
    // whose row is not yet whole - with the page it came from.  The data
    // front installs it, so a miss is one page-cache access and not two.
    output logic         op_row_v,
    output logic [127:0] op_row,
    output logic [15:0]  op_row_ppn,
    output logic       decided,
    output wire        busy,

    // ---- the write tap, for the floating-bus simulator ---------------------
    // Every byte that lands in physical bank 0 - the machine's main memory -
    // whether from an op, a posted write or a write miss's patch.
    output wire        mw_stb,
    output wire [15:0] mw_addr,
    // ...and the same landing for ANY bank: the strobe and the bank the
    // address is in, for the IIgs's scan-line interrupt, which watches the
    // SCBs land at $E1/9D00 (rtl/gs_io.sv).  mw_addr/mw_byte are shared.
    output wire        mwx_stb,
    output wire [7:0]  mw_bank,
    output wire [7:0]  mw_byte,

    // ---- the line port, both fronts through master_top's arbitration -------
    // il_ack grants the read; il_done stands exactly three clocks later with
    // il_ok (the page was resident) and il_row.  A non-resident page DECLINES:
    // the op rides the sequencer and its miss fills the page.
    input  wire        il_req,
    input  wire [15:0] il_ppn,
    input  wire [3:0]  il_line,
    input  wire        il_src,        // 0 = the instruction front, 1 = the data front
    output wire        il_ack,
    output wire        il_done,
    output logic       il_ok,
    output logic [127:0] il_row,

    // ---- control and status ------------------------------------------------
    input  wire        serve,
    input  wire        inval,
    input  wire        cnt_clr,
    input  wire        image_ready,
    output wire        invalidating,
    output logic [31:0] hits,
    output logic [31:0] misses,
    output logic [31:0] served,
    output logic [31:0] mismatches,
    output logic [31:0] last_mismatch,
    output logic [31:0] diverted,
    output logic [7:0]  late_fills,   // engine overruns: must read zero
    output logic [7:0]  fifo_drops,   // misses the DDR3 could not service
    output logic [31:0] mem_fills,
    output logic [31:0] mem_flushes,
    output logic [31:0] mem_declines,
    // The debug pair's window (rtl/wb_regfile.sv DBG_SEL/DBG_VAL): the
    // hierarchy-only books, readable on the hardware (docs/GS.md rung 6).
    input  wire [3:0]  dbg_sel,
    output logic [31:0] dbg_val,

    // ---- the engine's seam to rtl/page_client.sv ---------------------------
    output wire         pq_busy,
    output logic        pq_valid,
    output logic        pq_we,
    output logic [19:0] pq_line,      // {ppn, line[3:0]}
    output wire [127:0] pq_wdata,
    input  wire         pq_ready,
    input  wire         pr_valid,
    input  wire [127:0] pr_data
);

    localparam [1:0] CLS_BUS = 2'd0;

    localparam [2:0] E_IDLE   = 3'd0;
    localparam [2:0] E_SNAP   = 3'd1;
    localparam [2:0] E_FILL   = 3'd2;
    localparam [2:0] E_PATCH  = 3'd3;
    localparam [2:0] E_SETTLE = 3'd4;
    localparam [2:0] E_FLUSH  = 3'd5;


    // ---- the geometry ------------------------------------------------------
    localparam integer SIDX  = $clog2(SETS);          // index bits
    localparam integer AW    = SIDX + 4;              // a way's row address
    localparam integer LEV   = $clog2(WAYS);          // the replacement tree's depth
    localparam integer NODES = (1 << LEV) - 1;        // ...and its bits per set

    // The hashed index.  Folding the bank's low bits onto the page's spreads a
    // RamWorks bank crawl over every set instead of piling one bank's pages
    // into the sets its page numbers name; the IIe's own two banks and the
    // ROM then occupy five ways of each set and never collide.
    function automatic [SIDX-1:0] set_of(input [15:0] ppn);
        set_of = ppn[SIDX-1:0] ^ ppn[2*SIDX-1 -: SIDX];
    endfunction

    function automatic [WAYS-1:0] lowest_bit(input [WAYS-1:0] v);
        lowest_bit = v & (-v);
    endfunction

    function automatic [LEV-1:0] way_enc(input [WAYS-1:0] oh);
        int i;
        way_enc = '0;
        for (i = 0; i < WAYS; i = i + 1) if (oh[i]) way_enc = LEV'(i);
    endfunction

    // Tree pseudo-LRU, the classic: one bit per internal node, each pointing
    // at the half that was used less recently.  The VICTIM walk follows the
    // bits; a TOUCH walks the way's own index and flips every node it passes
    // to point away - so an update's new bits are a function of the way alone,
    // which keeps the read-modify-write of one LUTRAM word to LEV bits of
    // constant data rather than a function of the whole word.
    // A way count that is not a power of two leaves the tree with more leaves
    // than ways; the surplus leaves fold back onto the low ways.  That is a
    // legal policy (every way stays reachable, none is starved by more than
    // the fold), and the geometry sweep's point is that the RTL builds and
    // answers correctly at ten ways, not that ten ways replace optimally.
    function automatic [WAYS-1:0] plru_victim(input [NODES-1:0] b);
        int l, node, k;
        logic [LEV-1:0] idx;
        idx  = '0;
        node = 0;
        for (l = 0; l < LEV; l = l + 1) begin
            idx  = (idx << 1) | LEV'(b[node]);
            node = 2*node + 1 + int'(b[node]);
        end
        k = int'(idx);
        if (k >= WAYS) k = k - WAYS;
        plru_victim = {{(WAYS-1){1'b0}}, 1'b1} << k;
    endfunction

    function automatic [NODES-1:0] plru_touch(input [NODES-1:0] b, input [LEV-1:0] t);
        int l, node;
        logic dir;
        plru_touch = b;
        node = 0;
        for (l = 0; l < LEV; l = l + 1) begin
            dir = t[LEV-1-l];
            plru_touch[node] = ~dir;
            node = 2*node + 1 + int'(dir);
        end
    endfunction

    // ---- the directory -----------------------------------------------------
    // A DIRECTORY WORD PER WAY PER SET, in distributed RAM: {valid, dirty,
    // tag}.  The first cut held valid, dirty and the replacement bits in
    // FLOPS - 2944 of them - and out-of-context synthesis priced that at
    // 11,425 LUTs against the plan's thousand.  The flops themselves are not
    // the cost: each one needs its own next-state select fed by a DECODED set
    // index, three writers deep, and that is two or three LUTs apiece.  In
    // LUTRAM the write is one addressed write and the read is the one the
    // tags already do, so the whole structure costs what the tags cost.
    //
    // The price of LUTRAM is that it cannot be cleared in a clock, so the
    // invalidate is a WALK again - one set per clock, `invalidating` high
    // across it, exactly the contract rtl/mem_cache.sv had and
    // rtl/accel_seq.sv still honours (its fast_ok carries mem_invalidating).
    // A reset walks it too, which is why nothing may be served during one.
    // A NOTE ON A WARNING THAT LOOKS LIKE A FAULT AND IS NOT (2026-09-18).
    // Synthesis says a hundred times a build that `ram_style = "distributed"`
    // is ignored for `dir[n][m]`, "not inferred as ram due to incorrect
    // usage".  It is talking about the individual slices of the two-dimensional
    // array, not the array: the mapping report lists all eight ways as
    // 128 x 18 distributed memory, by User Attribute, in exactly the builds
    // that print the warning.  Restructuring it into one array per way silences
    // the warning, maps identically (LUT-as-memory and register counts do not
    // move at all) and cost timing, so it was reverted.  Leave it be.
    localparam integer DW = 18;               // {valid, dirty, tag[15:0]}
    (* ram_style = "distributed" *) logic [DW-1:0]    dir [WAYS][SETS];
    (* ram_style = "distributed" *) logic [NODES-1:0] plr [SETS];

    logic            iv_run;
    logic [SIDX-1:0] iv_k;
    assign invalidating = iv_run;
    always_ff @(posedge clk) begin
        if (rst)          begin iv_run <= 1'b1; iv_k <= {SIDX{1'b0}}; end
        else if (inval)   begin iv_run <= 1'b1; iv_k <= {SIDX{1'b0}}; end
        else if (iv_run)  begin
            iv_k <= iv_k + {{(SIDX-1){1'b0}}, 1'b1};
            if (iv_k == SIDX'(SETS-1)) iv_run <= 1'b0;
        end
    end

    // ---- P0: the entrant ---------------------------------------------------
    logic [2:0] state;
    logic [2:0] il_sr;
    logic       wl_v;
    wire        eng_idle = (state == E_IDLE);

    wire il_busy = il_sr[0] || il_sr[1];
    // The landing reservation and the patch: no line request may read a page
    // on a clock a write to it lands, and E_PATCH is a write landing on port B.
    assign il_ack = il_req && !op_present && !pw_take && !shd_take && !wl_v && !il_busy &&
                    !pw_pending && !iv_run && (state != E_PATCH);

    wire            e_op  = op_present;
    wire            e_pw  = pw_take;
    wire            e_sh  = shd_take;
    wire            e_il  = il_ack;
    wire            e_any = e_op || e_pw || e_sh || e_il;
    wire [15:0]     en_ppn = e_op ? pf_ppn      : e_pw ? pw_ppn      :
                             e_sh ? shd_ppn     : il_ppn;
    wire [3:0]      en_ln  = e_op ? pf_off[7:4] : e_pw ? pw_off[7:4] :
                             e_sh ? shd_off[7:4] : il_line;
    wire [SIDX-1:0] en_set = set_of(en_ppn);
    wire [AW-1:0]   en_row = {en_set, en_ln};

    // ---- the ways ----------------------------------------------------------
    logic [WAYS-1:0] wl_way;
    logic [AW-1:0]   wl_row;
    logic [15:0]     wl_be;
    logic [127:0]    wl_data;
    logic            wl_main;
    logic [7:0]      wl_bank;
    logic [15:0]     wl_addr;

    logic [WAYS-1:0] e_way;          // the engine's way, one-hot
    logic            eb_en;
    logic [15:0]     eb_we;
    logic [AW-1:0]   eb_addr;
    logic [127:0]    eb_wdata;

    wire [127:0] a_row [WAYS];
    wire [127:0] b_row [WAYS];

    genvar gw;
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_way
            wire land = wl_v && wl_way[gw];
            way_ram #(.ROWS (SETS * 16)) u_way (
                .clk     (clk),
                .a_en    (e_any || land),
                .a_we    (land ? wl_be  : 16'd0),
                .a_addr  (land ? wl_row : en_row),
                .a_wdata (wl_data),
                .a_rdata (a_row[gw]),
                .b_en    (eb_en && e_way[gw]),
                .b_we    (eb_we),
                .b_addr  (eb_addr),
                .b_wdata (eb_wdata),
                .b_rdata (b_row[gw])
            );
        end
    endgenerate

    // ---- P0 -> P1: the directory read, registered --------------------------
    logic             e1_v, e1_op, e1_il;
    logic [15:0]      e1_ppn;
    logic [SIDX-1:0]  e1_set;
    logic [3:0]       e1_line;
    logic [15:0]      tq   [WAYS];
    logic [WAYS-1:0]  tq_v, tq_d;
    logic [NODES-1:0] tq_p;

    always_ff @(posedge clk) begin
        e1_v  <= e_any && !rst;
        e1_op <= (e_op || e_pw || e_sh) && !rst;
        e1_il <= e_il && !rst;
        if (e_any) begin
            e1_ppn  <= en_ppn;
            e1_set  <= en_set;
            e1_line <= en_ln;
            tq_p <= plr[en_set];
            for (int i = 0; i < WAYS; i = i + 1) begin
                tq[i]   <= dir[i][en_set][15:0];
                tq_v[i] <= dir[i][en_set][17];
                tq_d[i] <= dir[i][en_set][16];
            end
        end
    end

    // ---- P1: the compare, the victim ---------------------------------------
    // A dirty bit set one clock ago has not reached tq_d.  It cannot reach the
    // hit compare (the op path's entrants are three clocks apart, `busy`), but
    // a victim chosen with a stale dirty bit would drop a page's writes on the
    // floor, so that one bit is forwarded.
    logic            dw_v;
    logic [SIDX-1:0] dw_set;
    logic [WAYS-1:0] dw_way;
    wire [WAYS-1:0]  tq_de = tq_d |
        ((dw_v && dw_set == e1_set) ? dw_way : {WAYS{1'b0}});

    wire [WAYS-1:0] c_hit_w;
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_cmp
            assign c_hit_w[gw] = tq_v[gw] && (tq[gw] == e1_ppn);
        end
    endgenerate
    wire c_hit = |c_hit_w;

    wire [WAYS-1:0] free_w = ~tq_v;
    wire [WAYS-1:0] c_vic  = (|free_w) ? lowest_bit(free_w) : plru_victim(tq_p);

    logic [15:0] c_vtag;
    always_comb begin
        c_vtag = 16'd0;
        for (int i = 0; i < WAYS; i = i + 1) if (c_vic[i]) c_vtag = c_vtag | tq[i];
    end
    wire c_vdty = |(c_vic & tq_de);

    // ---- P1 -> P2: the op's stage, and a write's landing -------------------
    logic            s_v, s_posted, s_rw, s_wr_image, s_machine, s_hit, s_vdty;
    logic [1:0]      s_cls;
    logic [15:0]     s_ppn, s_vtag, s_addr;
    logic [7:0]      s_off, s_wdata;
    logic [SIDX-1:0] s_set;
    logic [WAYS-1:0] s_way, s_vic;

    // The write's decision is taken HERE, one clock before it lands, so the
    // reservation that protects the fill port is a register and not a cone.
    wire p1_wr = cl_valid && !cl_rw && cl_wr_image && c_hit && !iv_run;

    always_ff @(posedge clk) begin
        s_v  <= cl_valid && !rst;
        wl_v <= p1_wr && !rst;
        dw_v <= p1_wr && !rst;
        if (cl_valid) begin
            s_posted   <= cl_posted;
            s_cls      <= cl_cls;
            s_ppn      <= cl_ppn;
            s_off      <= cl_off;
            s_rw       <= cl_rw;
            s_wr_image <= cl_wr_image;
            s_wdata    <= cl_wdata;
            s_addr     <= op_addr;
            s_machine  <= (cl_ppn[15:8] <= 8'd1);
            s_set      <= e1_set;
            s_hit      <= c_hit;
            s_way      <= c_hit_w;
            s_vic      <= c_vic;
            s_vtag     <= c_vtag;
            s_vdty     <= c_vdty;
        end
        if (p1_wr) begin
            wl_way  <= c_hit_w;
            wl_row  <= {e1_set, cl_off[7:4]};
            wl_be   <= 16'd1 << cl_off[3:0];
            wl_data <= {16{cl_wdata}};
            wl_main <= (cl_ppn[15:8] == 8'd0);
            wl_bank <= cl_ppn[15:8];
            wl_addr <= {cl_ppn[7:0], cl_off};
            dw_set  <= e1_set;
            dw_way  <= c_hit_w;
        end
    end

    // ---- P2: one row mux, two consumers ------------------------------------
    // The op's byte and a line request's row are never muxed on the same
    // clock - a line request is refused on an op's P0, so its row is out one
    // clock either side of the op's - so one WAYS:1 mux serves both, its
    // select the compare of the clock before.
    logic [WAYS-1:0] mx_sel;
    always_ff @(posedge clk) mx_sel <= c_hit_w;

    logic [127:0] mux_row;
    always_comb begin
        mux_row = 128'd0;
        for (int i = 0; i < WAYS; i = i + 1) if (mx_sel[i]) mux_row = mux_row | a_row[i];
    end
    wire [7:0] rbyte = mux_row[8 * s_off[3:0] +: 8];

    // ---- the line port's pipeline ------------------------------------------
    // ack at T: the compare at T+1, the row out of the block RAM at T+2 and
    // registered there, so il_done stands at T+3 with il_ok and il_row.
    logic il_hit_q;
    assign il_done = il_sr[2];
    always_ff @(posedge clk) begin
        il_sr <= rst ? 3'd0 : {il_sr[1:0], il_ack};
        if (e1_il)    il_hit_q <= c_hit;
        if (il_sr[1]) il_row   <= mux_row;
        if (il_sr[1]) il_ok    <= il_hit_q;
    end

    // ---- the engine --------------------------------------------------------
    logic [15:0]     e_ppn, e_old, e_addr;
    logic [SIDX-1:0] e_set;
    logic [3:0]      e_crit, e_boff;
    logic [7:0]      e_wbyte;
    logic            e_dirty, e_rw, e_serve, e_cmp, e_main;
    logic [4:0]      snap_k;
    logic [3:0]      req_n, fl_k;
    logic [4:0]      resp_n;

    assign pq_busy = !eng_idle;

    logic [127:0] pbuf [0:15];
    assign pq_wdata = pbuf[fl_k];
    wire accept = pq_valid && pq_ready;

    logic [127:0] b_mux;
    always_comb begin
        b_mux = 128'd0;
        for (int i = 0; i < WAYS; i = i + 1) if (e_way[i]) b_mux = b_mux | b_row[i];
    end

    always_comb begin
        eb_en    = 1'b0;
        eb_we    = 16'd0;
        eb_addr  = {AW{1'b0}};
        eb_wdata = 128'd0;
        case (state)
            E_SNAP: begin
                eb_en   = !snap_k[4];
                eb_addr = {e_set, snap_k[3:0]};
            end
            E_FILL: if (pr_valid) begin
                eb_en    = 1'b1;
                eb_we    = 16'hFFFF;
                eb_addr  = {e_set, e_crit + resp_n[3:0]};
                eb_wdata = pr_data;
            end
            E_PATCH: begin
                eb_en    = 1'b1;
                eb_we    = 16'd1 << e_boff;
                eb_addr  = {e_set, e_crit};
                eb_wdata = {16{e_wbyte}};
            end
            default: ;
        endcase
    end

    // ---- the decision ------------------------------------------------------
    wire d_cache   = (s_cls != CLS_BUS);
    wire serve_this = serve && d_cache;
    wire dec_read  = s_v && s_rw && d_cache;
    wire dec_write = s_v && !s_rw && s_wr_image;
    wire dec_block = (dec_read || dec_write) && (iv_run || (!s_hit && !eng_idle));
    wire eng_read_start = dec_read && !dec_block && !s_hit && image_ready;
    wire eng_retag = (state == E_FILL) && pr_valid && (resp_n == 5'd15);

    // The write tap: main memory's bytes as they land, for rtl/fb_sim.sv.
    assign mw_stb  = (wl_v && wl_main) || ((state == E_PATCH) && e_main);
    assign mwx_stb = wl_v || (state == E_PATCH);
    assign mw_bank = wl_v ? wl_bank : e_ppn[15:8];
    assign mw_addr = wl_v ? wl_addr : e_addr;
    assign mw_byte = wl_v ? wl_data[7:0] : e_wbyte;

    assign busy = op_present || (cl_valid && !cl_posted) || (s_v && !s_posted) ||
                  !eng_idle;
    assign pw_ready = !op_present && !cl_valid && !s_v && eng_idle && !wl_v && !iv_run;

    // ---- the books the bench reads through the hierarchy -------------------
    // A clash is an entrant on a landing clock, or a classified op whose page
    // is not the one its P0 indexed: both are impossible by the argument in
    // the header, and both would corrupt silently, so they are counted.
    // il_src says which front asked, so the line port's traffic can be split
    // between them in the hardware census at rung 5.
    logic [31:0] cnt_land_clash, cnt_ppn_clash, cnt_hit_uc, cnt_decline;
    logic [31:0] cnt_il_i, cnt_il_d, cnt_iv_block;
    // The posted writes, and those that found their page absent and had to
    // fill it: the data front's drain must be able to do that.
    logic [31:0] cnt_posted, cnt_posted_miss;
    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_land_clash <= 32'd0; cnt_ppn_clash <= 32'd0;
            cnt_hit_uc <= 32'd0; cnt_decline <= 32'd0;
            cnt_il_i <= 32'd0; cnt_il_d <= 32'd0; cnt_iv_block <= 32'd0;
            cnt_posted <= 32'd0; cnt_posted_miss <= 32'd0;
        end else begin
            if (il_ack && !il_src)                cnt_il_i       <= cnt_il_i + 32'd1;
            if (il_ack &&  il_src)                cnt_il_d       <= cnt_il_d + 32'd1;
            if (wl_v && e_any)                    cnt_land_clash <= cnt_land_clash + 32'd1;
            if (cl_valid && (!e1_op || e1_ppn != cl_ppn || e1_line != cl_off[7:4]))
                                                  cnt_ppn_clash  <= cnt_ppn_clash + 32'd1;
            if (dec_read && s_hit && !eng_idle)   cnt_hit_uc     <= cnt_hit_uc + 32'd1;
            if ((dec_read || dec_write) && iv_run) cnt_iv_block  <= cnt_iv_block + 32'd1;
            if (s_v && s_posted)                  cnt_posted     <= cnt_posted + 32'd1;
            if (dec_write && s_posted && !s_hit && !dec_block && image_ready)
                                                  cnt_posted_miss <= cnt_posted_miss + 32'd1;
            if (e1_il && !c_hit)                  cnt_decline    <= cnt_decline + 32'd1;
        end
    end

    // ---- the directory's writers -------------------------------------------
    // Valid and dirty never collide: the engine's are its own clocks, and no
    // op or posted write enters while it runs.  The replacement bits can, and
    // the engine wins - they are a hint.
    wire eng_go = (dec_read || dec_write) && !dec_block && !s_hit && image_ready;
    wire plru_op = s_v && s_hit && !dec_block && (dec_read || dec_write);
    wire plru_il = e1_il && c_hit;

    wire            plru_we  = eng_retag || plru_op || plru_il;
    wire [SIDX-1:0] plru_set = eng_retag ? e_set : plru_op ? s_set : e1_set;
    wire [LEV-1:0]  plru_way = way_enc(eng_retag ? e_way : plru_op ? s_way : c_hit_w);

    // Four writers, one port per way, and they cannot collide.  The walk owns
    // the directory outright (nothing is served under it).  A retag runs
    // inside the engine, where no op or posted write can enter; the victim's
    // clear STARTS the engine, so it is never the same clock as a retag; and
    // a write's dirty set can only share a clock with a retag if it hit a
    // DIFFERENT way, which is a different port.
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_dirw
            wire w_retag = eng_retag && e_way[gw];
            wire w_go    = eng_go    && s_vic[gw];
            wire w_dirty = p1_wr     && c_hit_w[gw];
            wire [SIDX-1:0] w_set = iv_run ? iv_k   :
                                    w_retag ? e_set :
                                    w_go    ? s_set : e1_set;
            wire [DW-1:0]   w_dat = iv_run  ? {DW{1'b0}} :
                                    w_retag ? {1'b1, !e_rw, e_ppn} :
                                    w_dirty ? {1'b1, 1'b1,  tq[gw]} : {DW{1'b0}};
            always_ff @(posedge clk) begin
                if (iv_run || w_retag || w_go || w_dirty) dir[gw][w_set] <= w_dat;
            end
        end
    endgenerate

    // The replacement tree is read where a set is indexed and read again where
    // it is touched; the touch is a read-modify-write of one word, and two
    // touches of one set in consecutive clocks see each other because the
    // write is synchronous and the read is not.
    always_ff @(posedge clk) begin
        if (plru_we) plr[plru_set] <= plru_touch(plr[plru_set], plru_way);
    end

    // ---- the pipeline's tail: the serve, the engine, the counters ----------
    logic       cmp_valid;
    logic [7:0] cmp_byte;
    logic [7:0] data_q;

    always_ff @(posedge clk) begin
        data_q  <= data_sync;
        decided <= (s_v && !s_posted && !eng_read_start) ||
                   ((state == E_FILL) && pr_valid && (resp_n == 5'd0) && e_rw);

        if (rst) begin
            sub_en <= 1'b0; sub_data <= 8'd0;
            op_row_v <= 1'b0; op_row <= 128'd0; op_row_ppn <= 16'd0;
            decided <= 1'b0;
            cmp_valid <= 1'b0; cmp_byte <= 8'd0;
            state <= E_IDLE;
            pq_valid <= 1'b0; pq_we <= 1'b0; pq_line <= 20'd0;
            e_ppn <= 16'd0; e_old <= 16'd0; e_set <= {SIDX{1'b0}}; e_way <= {WAYS{1'b0}};
            e_crit <= 4'd0; e_boff <= 4'd0; e_wbyte <= 8'd0; e_addr <= 16'd0;
            e_dirty <= 1'b0; e_rw <= 1'b1; e_serve <= 1'b0; e_cmp <= 1'b0; e_main <= 1'b0;
            snap_k <= 5'd0; req_n <= 4'd0; fl_k <= 4'd0; resp_n <= 5'd0;
            hits <= 32'd0; misses <= 32'd0; served <= 32'd0;
            mismatches <= 32'd0; last_mismatch <= 32'd0; diverted <= 32'd0;
            late_fills <= 8'd0; fifo_drops <= 8'd0;
            mem_fills <= 32'd0; mem_flushes <= 32'd0; mem_declines <= 32'd0;
        end else begin
            // A new op ends the previous one's serve and compare; a miss
            // transaction in flight still completes, for the page's sake.
            if (op_present) begin
                sub_en    <= 1'b0;
                op_row_v  <= 1'b0;
                cmp_valid <= 1'b0;
                e_serve   <= 1'b0;
                e_cmp     <= 1'b0;
            end

            if (e1_il && !c_hit) mem_declines <= mem_declines + 32'd1;

            // ---- P2 ---------------------------------------------------------
            if (dec_block) begin
                if (!iv_run) late_fills <= late_fills + 8'd1;
            end else if (dec_read && s_hit) begin
                hits <= hits + 32'd1;
                if (serve_this) begin
                    sub_en   <= 1'b1;
                    sub_data <= rbyte;
                    op_row_v   <= 1'b1;
                    op_row     <= mux_row;
                    op_row_ppn <= s_ppn;
                    served   <= served + 32'd1;
                end
                cmp_valid <= 1'b1;
                cmp_byte  <= rbyte;
            end else if ((dec_read || dec_write) && !s_hit) begin
                misses <= misses + 32'd1;
                if (image_ready) begin
                    state     <= s_vdty ? E_SNAP : E_FILL;
                    e_ppn     <= s_ppn;
                    e_old     <= s_vtag;
                    e_set     <= s_set;
                    e_way     <= s_vic;
                    e_crit    <= s_off[7:4];     // the classified answer, not the preview
                    e_boff    <= s_off[3:0];
                    e_wbyte   <= s_wdata;
                    e_addr    <= {s_ppn[7:0], s_off};
                    e_main    <= (s_ppn[15:8] == 8'd0);
                    e_dirty   <= s_vdty;
                    e_rw      <= s_rw;
                    e_serve   <= s_rw && serve_this;
                    e_cmp     <= s_rw && s_machine;
                    snap_k    <= 5'd0;
                    mem_fills <= mem_fills + 32'd1;
                    if (s_vdty) mem_flushes <= mem_flushes + 32'd1;
                    if (!s_vdty) begin
                        pq_valid <= 1'b1;
                        pq_we    <= 1'b0;
                        pq_line  <= {s_ppn, s_off[7:4]};
                        req_n    <= 4'd0;
                        resp_n   <= 5'd0;
                    end
                end else begin
                    fifo_drops <= fifo_drops + 8'd1;
                end
            end

            // ---- the engine -------------------------------------------------
            case (state)
                E_SNAP: begin
                    if (snap_k != 5'd0) pbuf[snap_k[3:0] - 4'd1] <= b_mux;
                    if (snap_k == 5'd16) begin
                        state    <= E_FILL;
                        pq_valid <= 1'b1;
                        pq_we    <= 1'b0;
                        pq_line  <= {e_ppn, e_crit};
                        req_n    <= 4'd0;
                        resp_n   <= 5'd0;
                    end else begin
                        snap_k <= snap_k + 5'd1;
                    end
                end
                E_FILL: begin
                    if (accept) begin
                        if (req_n == 4'd15) pq_valid <= 1'b0;
                        else begin
                            req_n        <= req_n + 4'd1;
                            pq_line[3:0] <= e_crit + req_n + 4'd1;
                        end
                    end
                    if (pr_valid) begin
                        resp_n <= resp_n + 5'd1;
                        if (resp_n == 5'd0 && e_rw && !op_present) begin
                            if (e_serve) begin
                                sub_en   <= 1'b1;
                                sub_data <= pr_data[8 * e_boff +: 8];
                                served   <= served + 32'd1;
                            end
                            if (e_cmp) begin
                                cmp_valid <= 1'b1;
                                cmp_byte  <= pr_data[8 * e_boff +: 8];
                            end
                        end
                        if (resp_n == 5'd15) begin
                            state <= !e_rw   ? E_PATCH :
                                     e_dirty ? E_SETTLE : E_IDLE;
                        end
                    end
                end
                E_PATCH: state <= E_SETTLE;
                E_SETTLE: begin
                    if (e_dirty) begin
                        state    <= E_FLUSH;
                        pq_valid <= 1'b1;
                        pq_we    <= 1'b1;
                        pq_line  <= {e_old, 4'd0};
                        fl_k     <= 4'd0;
                    end else begin
                        state <= E_IDLE;
                    end
                end
                E_FLUSH: begin
                    if (accept) begin
                        if (fl_k == 4'd15) begin
                            pq_valid <= 1'b0;
                            pq_we    <= 1'b0;
                            state    <= E_IDLE;
                        end else begin
                            fl_k         <= fl_k + 4'd1;
                            pq_line[3:0] <= fl_k + 4'd1;
                        end
                    end
                end
                default: ;
            endcase

            // ---- a diverted write, once per cycle ---------------------------
            if (op_commit && op_divert) diverted <= diverted + 32'd1;

            // ---- the monitor, at the data phase -----------------------------
            if (op_commit && cmp_valid && s_machine && cmp_byte != data_q) begin
                mismatches    <= mismatches + 32'd1;
                last_mismatch <= {s_addr, cmp_byte, data_q};
            end

            if (cnt_clr) begin
                hits <= 32'd0; misses <= 32'd0; served <= 32'd0;
                mismatches <= 32'd0; last_mismatch <= 32'd0; diverted <= 32'd0;
                late_fills <= 8'd0; fifo_drops <= 8'd0;
                mem_fills <= 32'd0; mem_flushes <= 32'd0; mem_declines <= 32'd0;
            end
        end
    end

    // The debug pair's window.
    always_comb begin
        case (dbg_sel)
            4'd0:  dbg_val = cnt_il_i;
            4'd1:  dbg_val = cnt_il_d;
            4'd2:  dbg_val = cnt_decline;
            4'd3:  dbg_val = cnt_iv_block;
            4'd4:  dbg_val = cnt_hit_uc;
            4'd5:  dbg_val = cnt_land_clash;
            4'd6:  dbg_val = cnt_ppn_clash;
            4'd7:  dbg_val = {late_fills, fifo_drops, 1'b0, state, iv_run, il_busy, wl_v, eng_idle, 8'd0};
            4'd8:  dbg_val = hits;
            4'd9:  dbg_val = misses;
            4'd10: dbg_val = mem_fills;
            4'd11: dbg_val = mem_flushes;
            4'd12: dbg_val = cnt_posted;
            4'd13: dbg_val = cnt_posted_miss;
            default: dbg_val = 32'hDEAD_0000;
        endcase
    end

endmodule
