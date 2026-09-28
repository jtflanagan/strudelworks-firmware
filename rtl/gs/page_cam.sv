`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// page_cam - the 65816 card's L2 as a set-associative page store with its
// directory in distributed RAM (docs/CORE_REFACTOR_65816.md "The L2 in
// sets", the user's direction, 2026-09-20; the fully associative CAM-L2 of
// 2026-09-19 is the design this grows out of, and everything behind P0 is
// still its).
//
// SETS x WAYS SLOTS OF ONE BLOCK RAM (a slot is {set, way}; N x 16 rows of
// 16 bytes: 16 x 8 = 128 slots = 32 KB = eight RAMB36 - the row is 128 bits
// wide, so the tiles go with the depth alone and never with the ways), and
// a DIRECTORY IN LUTRAM: per way, SETS words of {tag, referenced, last
// offset}, read ASYNCHRONOUSLY by the entrant's set in P0, so the compare
// and the matching slot's row read happen in P0 exactly as the CAM's
// compare from flops did.  The valid, dirty and TLB-pointed bits are flop
// vectors, one bit a slot: each has more than one writer a clock, which a
// LUTRAM's single write port cannot take, and at a bit a slot they are
// cheap.  What is NOT in flops is what the CAM paid for: a tag and a last
// offset per slot each with an index-decoded next-state select, and the
// reads indexed by slot as N:1 muxes - 46 LUTs and 33 flops a slot on the
// 64-to-32 A/B, linear in slots.  In LUTRAM the write is one addressed
// write and the read one addressed read, so 128 slots cost about what 16
// would, and the directory's logic is per WAY: eight comparators, an
// eight-way victim choice, a seven-node PLRU tree a set.
//
// WHY THE LOOKUP CAN AFFORD TO BE HERE AT ALL: L1's fills never consult
// the directory.  The TLB names {set, way} and a fill is a DIRECT WAY READ
// (dr_*) of the row, with the directory touched afterwards for the
// referenced bit, the last offset and the PLRU.  The lookup serves the op
// path - the dispatcher's ops that bypass L1, and the TLB's misses - and
// what matters there is its LATENCY, not its throughput: a block RAM
// directory would read synchronously and cost every one of those a clock.
//
// THE WORKING-SET POLICY, NOW PER SET: the victim is a free way first;
// else, among the ways the TLB does not point at, the tree PLRU's pick if
// it was never RE-REFERENCED since its fill, else the lowest such, else the
// PLRU's pick if unpointed, else the lowest unpointed, else the PLRU's
// pick (and the eviction broadcast kills the TLB entry).  A way's
// referenced bit is set only by a NON-SEQUENTIAL touch after its fill (an
// offset that is neither the last one nor its successor: a loop's branch
// back, a table looked up, the stack; never a copy, a clear, a DMA landing
// or a screen sweep) and cleared when the PLRU's pick was skipped for
// being protected, one reference given up a skip, so a working set that
// stops being one drains.  A stream's pages recycle among a set's
// unreferenced ways and the referenced ones survive; the exposure the CAM
// did not have is a working set with more than WAYS pages hashed into one
// set.  THE WRITE-AROUND stands: a write miss is one line write with one
// lane to the backing store and allocates nothing.
//
// THE SET is a fold of the whole page number (every SIDX-bit slice XORed):
// bank $E0's pages must not share bank $00's sets, or every shadowed write
// ping-pongs with its Mega II duplicate (the 64-set bug of 2026-09-19).
//
// THE PIPELINE.  P0: the entrant's set indexes the LUTRAM and the flop
// vectors; the tags compare; the hit way's row is read.  P1: the set's
// valid, pointed, referenced and PLRU bits, registered at P0, choose the
// victim (the engine's own slot masked, so a page filled last clock is
// never the stale pick; a landing of the P0 or P1 clock forwarded into the
// dirty bits).  P2: the victim's tag is read from the LUTRAM at the op's
// set for the flush, and the hit's touch is a one-clock read-modify-write
// of the hit way's word.  Per way, one write a clock, by priority: the
// fill's retag (must land: the slot is valid the same clock), the op's
// touch, a skipped pick's reference given up, the direct read's touch (a
// lost touch is a lost hint, never a wrong line).
//
// The engine (E_SNAP / E_FILL / E_PATCH / E_SETTLE / E_FLUSH / E_LDWR /
// E_WARD), the P+2 law, the snapshot's landing hold, the posted seam, the
// shadow duplicate's entrant, the loader's line port, the direct way read,
// the placement report and the eviction broadcast are page_cache's, by
// name.
//////////////////////////////////////////////////////////////////////////////////
module page_cam #(
    parameter integer SETS = 16,               // sets (a power of two)
    parameter integer WAYS = 8,                // ways a set (a power of two)
    // THE PAGE NUMBER'S WIDTH: 16 = the 65816's 16 MB; 17 = the whole 32 MB DDR3
    // bank, the upper 16 MB the RISC-V engine's alone (docs/REQ_RVVM.md).  A page
    // with any bit above 15 set is NOT in the 65816's map: nothing bank-derived
    // (the machine banks, bank $00's copy, the SCB watch's taps) may see it.
    parameter integer PW = 16
) (
    input  wire        clk,
    input  wire        rst,
    // The classified op stream (P1).
    input  wire        cl_valid,
    input  wire [1:0]  cl_cls,
    input  wire [PW-1:0] cl_ppn,
    input  wire [7:0]  cl_off,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [31:0] cl_wdata,      // a byte in all four lanes, or the RISC-V engine's word
    input  wire [3:0]  cl_be,         // its lanes from cl_off: the row's are cl_be << cl_off[3:0]
    input  wire        cl_posted,
    input  wire        pw_pending,
    output wire        pw_ready,
    // The op's preview (P0).
    input  wire [PW-1:0] pf_ppn,
    input  wire [7:0]  pf_off,
    // The posted seam's entrant and the shadow duplicate's.
    input  wire        pw_take,
    input  wire [PW-1:0] pw_ppn,
    input  wire [7:0]  pw_off,
    input  wire        shd_take,
    input  wire [PW-1:0] shd_ppn,
    input  wire [7:0]  shd_off,
    // The op itself, for the monitor.
    input  wire [15:0] op_addr,
    input  wire        op_present,
    input  wire        op_commit,
    input  wire        op_divert,
    input  wire [7:0]  data_sync,
    output logic       sub_en,
    output logic       op_row_v,
    output logic [127:0] op_row,
    output logic [PW-1:0] op_row_ppn,
    output logic [7:0] sub_data,
    output logic       decided,
    output logic       op_blocked,
    output wire        busy,
    // The write taps (fb_sim, gs_io's SCB watch).
    output wire        mw_stb,
    output wire [15:0] mw_addr,
    output wire [7:0]  mw_byte,
    output wire        mwx_stb,
    output wire [7:0]  mw_bank,
    // The line-row port: the RISC-V engine's probe (rtl/gs/rv_mem.sv,
    // docs/REQ_RVVM.md "The engine on the L2").  A hit answers the row and
    // WHERE it is (il_set/il_way); a miss with il_fill set starts the same fill
    // an op-path read miss starts - as a posted read nobody waits on - and its
    // retag is reported on op_place_* as every fill's is.
    input  wire        il_req,
    input  wire [PW-1:0] il_ppn,
    input  wire [3:0]  il_line,
    input  wire        il_src,
    input  wire        il_fill,
    output wire        il_ack,
    output wire        il_done,
    output logic       il_ok,
    output logic [127:0] il_row,
    output logic [$clog2(SETS)-1:0] il_set,
    output logic [$clog2(WAYS)-1:0] il_way,
    // The TLB's references, the eviction broadcast, the placement report,
    // the direct read: a set and a way, as the set cache had them.
    input  wire                        ref_v,
    input  wire [$clog2(SETS)-1:0]     ref_set,
    input  wire [$clog2(WAYS)-1:0]     ref_way,
    input  wire                        ref_on,
    output logic                       evict_v,
    output logic [$clog2(SETS)-1:0]    evict_set,
    output logic [$clog2(WAYS)-1:0]    evict_way,
    output logic                       op_place_v,
    output logic [PW-1:0]              op_place_ppn,
    output logic [$clog2(SETS)-1:0]    op_place_set,
    output logic [$clog2(WAYS)-1:0]    op_place_way,
    input  wire                        dr_req,
    input  wire [$clog2(SETS)-1:0]     dr_set,
    input  wire [$clog2(WAYS)-1:0]     dr_way,
    input  wire [3:0]                  dr_line,
    output wire                        dr_ack,
    output logic                       dr_done,
    output logic [127:0]               dr_row,
    // ...and the same row ONE CLOCK EARLIER, straight off the RAM's port B
    // (way_ram's b_rdata, valid the clock after the ack): l1i lands its line
    // from it and saves the register clock (docs/CORE_REFACTOR_65816.md,
    // the I side's census 2026-09-19).
    output wire  [127:0]               dr_erow,
    // The image.
    input  wire        serve,
    input  wire        inval,
    input  wire [3:0]  dbg_sel,
    output logic [31:0] dbg_val,
    input  wire        cnt_clr,
    input  wire        image_ready,
    output wire        invalidating,
    output logic [31:0] hits,
    output logic [31:0] misses,
    output logic [31:0] served,
    output logic [31:0] mismatches,
    output logic [31:0] last_mismatch,
    output logic [31:0] diverted,
    output logic [7:0]  late_fills,
    output logic [7:0]  fifo_drops,
    output logic [31:0] mem_fills,
    output logic [31:0] mem_flushes,
    output logic [31:0] mem_declines,
    // The backing store's line queue (rtl/common/page_client.sv).
    output wire         pq_busy,
    output logic        pq_valid,
    output logic        pq_we,
    output logic [PW+3:0] pq_line,
    output wire [127:0] pq_wdata,
    output wire [15:0]  pq_sel,      // the lanes written: all but for a write-around
    input  wire         pq_ready,
    input  wire         pr_valid,
    input  wire [127:0] pr_data,
    // The loader's lines, straight to the backing store.
    input  wire         ld_valid,
    input  wire [19:0]  ld_line,
    input  wire [127:0] ld_wdata,
    output wire         ld_take
);
    localparam [1:0] CLS_BUS = 2'd0;
    localparam [2:0] E_IDLE   = 3'd0;
    localparam [2:0] E_SNAP   = 3'd1;
    localparam [2:0] E_FILL   = 3'd2;
    localparam [2:0] E_PATCH  = 3'd3;
    localparam [2:0] E_SETTLE = 3'd4;
    localparam [2:0] E_FLUSH  = 3'd5;
    localparam [2:0] E_LDWR   = 3'd6;
    localparam [2:0] E_WARD   = 3'd7;   // a write miss, written around: one lane to the backing store

    localparam integer SIDX  = $clog2(SETS);    // a set's index bits
    localparam integer LEV   = $clog2(WAYS);    // a way's
    localparam integer SW    = SIDX + LEV;      // a slot's: {set, way}
    localparam integer N     = SETS * WAYS;     // slots
    localparam integer AW    = SW + 4;          // a row address
    localparam integer NODES = WAYS - 1;        // the PLRU tree over a set's ways
    localparam integer DW    = PW + 9;          // a directory word: {tag[PW-1:0], referenced, last[7:0]}

`ifndef SYNTHESIS
    initial begin
        if (SETS != (1 << SIDX) || WAYS != (1 << LEV))
            $fatal(1, "page_cam: SETS (%0d) and WAYS (%0d) must be powers of two", SETS, WAYS);
    end
`endif

    // THE SET: every SIDX-bit slice of the page number XORed together, the
    // bank byte included (the 64-set bug of 2026-09-19: a fold of bits 11:0
    // alone put bank $E0's pages in bank $00's sets).
    function automatic [SIDX-1:0] set_of(input [PW-1:0] ppn);
        int i;
        set_of = '0;
        for (i = 0; i < PW; i = i + SIDX) set_of = set_of ^ SIDX'(ppn >> i);
    endfunction
    // In the 65816's 16 MB: the only pages a bank number means anything for.
    function automatic logic low16(input [PW-1:0] ppn);
        low16 = (ppn >> 16) == '0;
    endfunction
    function automatic [WAYS-1:0] lowest_bit(input [WAYS-1:0] v);
        lowest_bit = v & (-v);
    endfunction
    // ONE-HOT TO BINARY, BY OR AND NOT BY PRIORITY (2026-09-20): an OR is
    // associative where an override is not, so this is a balanced tree and
    // not a WAYS-deep chain.  Only equal to the priority form for a ONE-HOT
    // input; every caller is (the compare below is asserted so in sim).
    function automatic [LEV-1:0] way_enc(input [WAYS-1:0] oh);
        int i;
        way_enc = '0;
        for (i = 0; i < WAYS; i = i + 1) if (oh[i]) way_enc = way_enc | LEV'(i);
    endfunction
    function automatic [WAYS-1:0] plru_victim(input [NODES-1:0] b);
        int l, node;
        logic [LEV-1:0] idx;
        idx  = '0;
        node = 0;
        for (l = 0; l < LEV; l = l + 1) begin
            idx  = (idx << 1) | LEV'(b[node]);
            node = 2*node + 1 + int'(b[node]);
        end
        plru_victim = {{(WAYS-1){1'b0}}, 1'b1} << idx;
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

    // ---- the directory -------------------------------------------------------
    // The flop vectors, a bit a slot ({set, way}): valid, dirty, pointed at
    // by the TLB.  The LUTRAM words are per way (g_dir below): three
    // asynchronous reads - the entrant's set (P0), the op's set (P2), the
    // direct read's set - and one write a clock.
    logic [N-1:0]     d_v;
    logic [N-1:0]     d_d;
    logic [N-1:0]     refb;
    logic [DW-1:0]    dir_a [WAYS];    // read at en_set (P0)
    logic [DW-1:0]    dir_b [WAYS];    // read at s_set (P2)
    logic [DW-1:0]    dir_c [WAYS];    // read at dr_set
    // The PLRU tree of each set, in LUTRAM too (one touch a clock, by
    // priority); not cleared by an invalidate - a stale tree is a stale hint.
    (* ram_style = "distributed" *) logic [NODES-1:0] plr [SETS];
    initial for (int i = 0; i < SETS; i = i + 1) plr[i] = '0;

    logic iv_run;
    assign invalidating = iv_run;
    always_ff @(posedge clk) begin
        if (rst || inval) iv_run <= 1'b1;
        else              iv_run <= 1'b0;
    end

    logic [2:0] state;
    logic [2:0] il_sr;
    logic       wl_v;
    wire        eng_idle = (state == E_IDLE);

    wire il_busy = il_sr[0] || il_sr[1];
    // NOT WHILE AN OP IS IN P1 (!cl_valid, as pw_ready has it): a write there
    // lands next clock - the probe's P1, whose row read the landing takes (port
    // A is the landing's on its clock), and il_row would be the row the write
    // landed in.  The suspected cause of the HW trap of 2026-09-27 (the engine
    // ran $00F1E000, a word memory did not hold, after an ECALL; the write most
    // likely an interrupt's stack push - docs/RVV2_DOOM.md, Open); not proven.
    assign il_ack = il_req && !op_present && !cl_valid && !pw_take && !shd_take && !wl_v && !il_busy &&
                    !pw_pending && !iv_run && (state != E_PATCH);

    // ---- P0: the entrant, the set, the compare, the row read --------------------
    wire            e_op  = op_present;
    wire            e_pw  = pw_take;
    wire            e_sh  = shd_take;
    wire            e_il  = il_ack;
    wire            e_any = e_op || e_pw || e_sh || e_il;
    wire [PW-1:0]   en_ppn = e_op ? pf_ppn      : e_pw ? pw_ppn      :
                             e_sh ? shd_ppn     : il_ppn;
    wire [3:0]      en_ln  = e_op ? pf_off[7:4] : e_pw ? pw_off[7:4] :
                             e_sh ? shd_off[7:4] : il_line;
    wire [SIDX-1:0] en_set = set_of(en_ppn);
    wire [WAYS-1:0] v0  = d_v [en_set * WAYS +: WAYS];
    wire [WAYS-1:0] dd0 = d_d [en_set * WAYS +: WAYS];
    wire [WAYS-1:0] rb0 = refb[en_set * WAYS +: WAYS];
    logic [WAYS-1:0] m0;
    logic [WAYS-1:0] ref0;
    always_comb for (int i = 0; i < WAYS; i = i + 1) begin
        m0[i]   = v0[i] && (dir_a[i][DW-1:9] == en_ppn);
        ref0[i] = dir_a[i][8];
    end
    wire           hit0  = |m0;
    wire [LEV-1:0] way0  = way_enc(m0);
    wire [SW-1:0]  slot0 = {en_set, way0};
`ifndef SYNTHESIS
    // The P1 read must address exactly the row P0's compare chose, and a
    // landing must never steal a hit's read clock.  The ops are three clocks
    // apart; the engine's probe was not, until il_ack waited out an op in P1
    // (2026-09-27: acked the clock after a write's P0, its read would be the landing's).
    logic [AW-1:0] en_row_q;
    logic          en_row_qv;
    always_ff @(posedge clk) begin
        en_row_q  <= en_row;
        en_row_qv <= e_any && hit0 && !rst;
        if (!rst && en_row_qv && p1_rd && (p1_row !== en_row_q))
            $error("page_cam: the P1 row address %0d is not the row P0 chose (%0d)", p1_row, en_row_q);
        if (!rst && land && p1_rd)
            $error("page_cam: a landing took the row read's clock - the op's row is the landing's");
    end
    // way_enc() IS AN OR-REDUCTION AND ASSUMES ONE-HOT (above).  A set that
    // ever held one page in two ways would make it answer a third, so the
    // assumption is watched rather than trusted: this fires on the first
    // duplicate, in every bench, for ever.
    always_ff @(posedge clk)
        if (!rst && e_any && hit0 && ((m0 & (m0 - 1)) != {WAYS{1'b0}}))
            $error("page_cam: page $%04x is in more than one way of set %0d (m0=%b): way_enc() assumes one-hot",
                   en_ppn, en_set, m0);
`endif
    // en_row is what the lookup WOULD have addressed at P0; the read is issued
    // at P1 from p1_row now (below).  Kept for the assertion that the two agree.
    wire [AW-1:0] en_row = {slot0, en_ln};

    // ---- the landing register (P1 -> the row) ------------------------------
    logic [AW-1:0]   wl_row;
    logic [15:0]     wl_be;
    logic [127:0]    wl_data;
    logic            wl_main;
    logic            wl_low;         // the landing is in the 65816's 16 MB (its bank means something)
    logic [7:0]      wl_bank;
    logic [15:0]     wl_addr;
    logic [SW-1:0]   wl_slot;

    // ---- the block RAM: port A the op path and the landings, port B the engine
    // and the direct read ------------------------------------------------------
    logic [SW-1:0]   e_slot;
    wire [SIDX-1:0]  e_set = e_slot[SW-1:LEV];
    wire [LEV-1:0]   e_way = e_slot[LEV-1:0];
    wire [AW-1:0] dr_row_addr = {dr_set, dr_way, dr_line};
    wire          dr_clash    = wl_v && (wl_row == dr_row_addr);
    assign dr_ack = dr_req && eng_idle && !iv_run && !pw_pending && !dr_clash && !rst;
    logic [1:0]     dr_sr;
    logic            eb_en;
    logic [15:0]     eb_we;
    logic [AW-1:0]   eb_addr;
    logic [127:0]    eb_wdata;
    wire [127:0] a_row;
    wire [127:0] b_row;
    assign dr_erow = b_row;
    wire land = wl_v;
    // THE ROW READ IS ISSUED AT P1 (2026-09-22), from the slot the lookup
    // registered, not at P0 from the compare's own output: the address used to
    // arrive at the RAM through the op's translation, the set hash, the
    // directory's LUTRAM and the eight tag compares, and that was the 50T's
    // worst path.  way_ram's port A lost its second output register in the
    // same change, so the row is still out at P2 and nothing downstream moves.
    // A read is issued only for a HIT: a miss has no row to read (the engine
    // fills it), and a landing still owns the port on its own clock.
    wire            p1_rd  = e1_v && c_hit;
    wire [AW-1:0]   p1_row = {c_slot, e1_line};
    way_ram #(.ROWS (N * 16)) u_ram (
        .clk     (clk),
        .a_en    (p1_rd || land),
        .a_we    (land ? wl_be  : 16'd0),
        .a_addr  (land ? wl_row : p1_row),
        .a_wdata (wl_data),
        .a_rdata (a_row),
        .b_en    (eb_en || dr_ack),
        .b_we    (dr_ack ? 16'd0 : eb_we),
        .b_addr  (dr_ack ? dr_row_addr : eb_addr),
        .b_wdata (eb_wdata),
        .b_rdata (b_row)
    );

    // ---- P1: what P0 found, and the set's bits for the victim -------------------
    logic             e1_v, e1_op, e1_il, e1_fill;
    logic [PW-1:0]    e1_ppn;
    logic [3:0]       e1_line;
    logic [SIDX-1:0]  e1_set;
    logic             c_hit;
    logic [SW-1:0]    c_slot;
    logic [WAYS-1:0]  tq_v, tq_d, tq_r, tq_ref;
    logic [NODES-1:0] tq_p;
    always_ff @(posedge clk) begin
        e1_v  <= e_any && !rst;
        e1_op <= (e_op || e_pw || e_sh) && !rst;
        e1_il <= e_il && !rst;
        e1_fill <= e_il && il_fill && !rst;
        if (e_any) begin
            e1_ppn  <= en_ppn;
            e1_line <= en_ln;
            e1_set  <= en_set;
            c_hit   <= hit0;
            c_slot  <= slot0;
            tq_v    <= v0;
            tq_d    <= dd0;
            tq_r    <= rb0;
            tq_ref  <= ref0;
            tq_p    <= plr[en_set];
        end
    end

    // The victim, within the entrant's set, from the bits registered at P0:
    // a free way; else, among the ways the TLB does not point at, the PLRU's
    // pick if it was never re-referenced, else the lowest such, else the
    // PLRU's pick if unpointed, else the lowest unpointed, else the PLRU's
    // pick.  The engine's own slot is never "free" here, so a page filled
    // last clock is not the stale pick (its valid bit reached d_v after tq_v
    // was taken).  A clock's staleness in the pointed and referenced bits
    // costs a hint, never a line: a pointed way evicted is killed in the TLB
    // by the broadcast.  A DIRTY bit must not be stale - a victim chosen
    // clean would drop a page's writes - so the landings of the P0 clock
    // (dw_*) and of this clock (wl_*) are forwarded.
    wire [WAYS-1:0] e_way_oh  = WAYS'(1) << e_way;
    wire [WAYS-1:0] e_mask    = (e_set == e1_set) ? e_way_oh : {WAYS{1'b0}};
    wire [WAYS-1:0] free_w    = ~(tq_v | e_mask);
    wire [WAYS-1:0] unref_w   = ~tq_r;
    wire [WAYS-1:0] unprot_w  = ~tq_ref;
    wire [WAYS-1:0] plru_w    = plru_victim(tq_p);
    wire [WAYS-1:0] c_vic     = (|free_w)                        ? lowest_bit(free_w) :
                                (|(plru_w & unref_w & unprot_w)) ? plru_w :
                                (|(unref_w & unprot_w))          ? lowest_bit(unref_w & unprot_w) :
                                (|(plru_w & unref_w))            ? plru_w :
                                (|unref_w)                       ? lowest_bit(unref_w) : plru_w;
    wire [LEV-1:0]  c_vway    = way_enc(c_vic);
    wire [SW-1:0]   c_vslot   = {e1_set, c_vway};
    logic            dw_v;
    logic [SW-1:0]   dw_slot;
    always_ff @(posedge clk) begin
        dw_v    <= wl_v && !rst;
        dw_slot <= wl_slot;
    end
    wire [WAYS-1:0] wl_way_oh = WAYS'(1) << wl_slot[LEV-1:0];
    wire [WAYS-1:0] dw_way_oh = WAYS'(1) << dw_slot[LEV-1:0];
    wire [WAYS-1:0] tq_de     = tq_d |
                                ((wl_v && wl_slot[SW-1:LEV] == e1_set) ? wl_way_oh : {WAYS{1'b0}}) |
                                ((dw_v && dw_slot[SW-1:LEV] == e1_set) ? dw_way_oh : {WAYS{1'b0}});
    wire            c_vdty    = |(c_vic & tq_de);

    // ---- P1 -> P2: the op's stage, and a write's landing -------------------
    logic            s_v, s_posted, s_rw, s_wr_image, s_machine, s_hit, s_vdty, s_probe;
    logic [1:0]      s_cls;
    logic [PW-1:0]   s_ppn;
    logic [15:0]     s_addr;
    logic [7:0]      s_off;
    logic [31:0]     s_wdata;
    logic [3:0]      s_be;
    logic [SIDX-1:0] s_set;
    logic [SW-1:0]   s_slot, s_vslot;
    logic [WAYS-1:0] s_vic, s_plru;
    wire [LEV-1:0]   s_way = s_slot[LEV-1:0];
    wire p1_wr = cl_valid && !cl_rw && cl_wr_image && c_hit && !iv_run;
    // A probe that missed and may fill becomes a posted read at P2 (a probe is
    // acknowledged only with no op present, so it never meets cl_valid here).
    wire p1_pfill = e1_il && e1_fill && !c_hit && !cl_valid;
    always_ff @(posedge clk) begin
        s_v  <= (cl_valid || p1_pfill) && !rst;
        wl_v <= p1_wr && !rst;
        if (p1_pfill) begin
            s_posted   <= 1'b1;
            s_probe    <= 1'b1;
            s_cls      <= 2'd1;             // not CLS_BUS: cacheable
            s_ppn      <= e1_ppn;
            s_off      <= {e1_line, 4'd0};
            s_rw       <= 1'b1;
            s_wr_image <= 1'b0;
            s_wdata    <= 32'd0;
            s_be       <= 4'b0001;
            s_addr     <= 16'd0;
            s_machine  <= 1'b0;
            s_hit      <= 1'b0;
            s_slot     <= c_slot;
            s_set      <= e1_set;
            s_vic      <= c_vic;
            s_vslot    <= c_vslot;
            s_vdty     <= c_vdty;
            s_plru     <= plru_w;
        end
        if (cl_valid) begin
            s_probe    <= 1'b0;
            s_posted   <= cl_posted;
            s_cls      <= cl_cls;
            s_ppn      <= cl_ppn;
            s_off      <= cl_off;
            s_rw       <= cl_rw;
            s_wr_image <= cl_wr_image;
            s_wdata    <= cl_wdata;
            s_be       <= cl_be;
            s_addr     <= op_addr;
            s_machine  <= low16(cl_ppn) && (cl_ppn[15:8] <= 8'd1);
            s_hit      <= c_hit;
            s_slot     <= c_slot;
            s_set      <= e1_set;
            s_vic      <= c_vic;
            s_vslot    <= c_vslot;
            s_vdty     <= c_vdty;
            s_plru     <= plru_w;       // the decode the victim was chosen from
        end
        if (p1_wr) begin
            wl_slot <= c_slot;
            wl_row  <= {c_slot, cl_off[7:4]};
            wl_be   <= 16'(cl_be) << cl_off[3:0];
            wl_data <= {4{cl_wdata}};
            wl_main <= low16(cl_ppn) && (cl_ppn[15:8] == 8'd0);
            wl_low  <= low16(cl_ppn);
            wl_bank <= cl_ppn[15:8];
            wl_addr <= {cl_ppn[7:0], cl_off};
        end
    end
    wire [127:0] mux_row = a_row;     // one clock after P1's read: at P2
    wire [7:0]   rbyte   = mux_row[8 * s_off[3:0] +: 8];
    // The victim's tag, for the flush: read at P2 from the LUTRAM at the
    // op's set (a retag is the only writer of a tag and never the victim's).
    logic [PW-1:0] v_tag2;
    always_comb begin
        v_tag2 = '0;
        for (int i = 0; i < WAYS; i = i + 1) if (s_vic[i]) v_tag2 = v_tag2 | dir_b[i][DW-1:9];
    end

    logic il_hit_q;
    logic [SW-1:0] il_slot_q;
    assign il_done = il_sr[2];
    always_ff @(posedge clk) begin
        il_sr <= rst ? 3'd0 : {il_sr[1:0], il_ack};
        if (e1_il)    il_hit_q <= c_hit;
        if (e1_il)    il_slot_q <= c_slot;
        if (il_sr[1]) begin il_set <= il_slot_q[SW-1:LEV]; il_way <= il_slot_q[LEV-1:0]; end
        if (il_sr[1]) il_row   <= mux_row;
        if (il_sr[1]) il_ok    <= il_hit_q;
    end
    always_ff @(posedge clk) begin
        dr_sr <= rst ? 2'd0 : {dr_sr[0], dr_ack};
        if (dr_sr[0]) dr_row <= b_row;
        dr_done <= dr_sr[0] && !rst;
    end

    // ---- the engine ---------------------------------------------------------
    logic [PW-1:0]   e_ppn, e_old;
    logic [15:0]     e_addr;
    logic [3:0]      e_crit, e_boff;
    logic [31:0]     e_wword;       // a write-around's data, as s_wdata
    logic [15:0]     e_lanes;       // ...and its lanes in the row
    logic            e_dirty, e_rw, e_serve, e_cmp, e_main, e_low, e_probe;
    logic [4:0]      snap_k;
    wire             snap_hold = (snap_k == 5'd0) && wl_v && (wl_slot == e_slot);
    logic [3:0]      req_n, fl_k;
    logic [4:0]      resp_n;
    assign pq_busy = !eng_idle;
    logic [127:0] pbuf [0:15];
    logic [127:0] ld_wdata_q;
    assign pq_wdata = (state == E_LDWR || state == E_WARD) ? ld_wdata_q : pbuf[fl_k];
    assign pq_sel   = (state == E_WARD) ? e_lanes : 16'hFFFF;
    wire accept = pq_valid && pq_ready;
    assign ld_take = (state == E_LDWR) && accept;
    always_comb begin
        eb_en    = 1'b0;
        eb_we    = 16'd0;
        eb_addr  = {AW{1'b0}};
        eb_wdata = 128'd0;
        case (state)
            E_SNAP: begin
                eb_en   = !snap_k[4] && !snap_hold;
                eb_addr = {e_slot, snap_k[3:0]};
            end
            E_FILL: if (pr_valid) begin
                eb_en    = 1'b1;
                eb_we    = 16'hFFFF;
                eb_addr  = {e_slot, e_crit + resp_n[3:0]};
                eb_wdata = pr_data;
            end
            E_PATCH: begin
                eb_en    = 1'b1;
                eb_we    = e_lanes;
                eb_addr  = {e_slot, e_crit};
                eb_wdata = {4{e_wword}};
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
    wire   e_wr_stb = (state == E_PATCH) || (state == E_WARD && accept);
    assign mw_stb  = (wl_v && wl_main) || (e_wr_stb && e_main);
    // ANY bank's writes for the SCB watch - but only the 65816's 16 MB has banks
    assign mwx_stb = (wl_v && wl_low) || (e_wr_stb && e_low);
    assign mw_bank = wl_v ? wl_bank : e_ppn[15:8];
    assign mw_addr = wl_v ? wl_addr : e_addr;
    // ONE BYTE WIDE: its consumers (the video copy of main, the SCBs in $E1)
    // watch banks only the 65816's byte writes reach; the RISC-V engine's
    // words stay in $02-$DF (asserted below).
    assign mw_byte = wl_v ? wl_data[7:0] : e_wword[7:0];
    assign busy = op_present || (cl_valid && !cl_posted) || (s_v && !s_posted) ||
                  !eng_idle;
    assign pw_ready = !op_present && !cl_valid && !s_v && eng_idle && !wl_v && !iv_run;

    logic [31:0] cnt_land_clash, cnt_ppn_clash, cnt_hit_uc, cnt_decline;
    logic [31:0] cnt_il_i, cnt_il_d, cnt_iv_block;
    logic [31:0] cnt_posted, cnt_posted_miss, cnt_dr, cnt_prot_skips, cnt_ward;
    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_land_clash <= 32'd0; cnt_ppn_clash <= 32'd0;
            cnt_hit_uc <= 32'd0; cnt_decline <= 32'd0;
            cnt_il_i <= 32'd0; cnt_il_d <= 32'd0; cnt_iv_block <= 32'd0;
            cnt_posted <= 32'd0; cnt_posted_miss <= 32'd0; cnt_dr <= 32'd0; cnt_prot_skips <= 32'd0; cnt_ward <= 32'd0;
        end else begin
            if (dr_ack)                           cnt_dr         <= cnt_dr + 32'd1;
            if (il_ack && !il_src)                cnt_il_i       <= cnt_il_i + 32'd1;
            if (il_ack &&  il_src)                cnt_il_d       <= cnt_il_d + 32'd1;
            if (land && p1_rd)                    cnt_land_clash <= cnt_land_clash + 32'd1;
            if (cl_valid && (!e1_op || e1_ppn != cl_ppn || e1_line != cl_off[7:4]))
                                                  cnt_ppn_clash  <= cnt_ppn_clash + 32'd1;
            if (dec_read && s_hit && !eng_idle)   cnt_hit_uc     <= cnt_hit_uc + 32'd1;
            if ((dec_read || dec_write) && iv_run) cnt_iv_block  <= cnt_iv_block + 32'd1;
            if (s_v && s_posted)                  cnt_posted     <= cnt_posted + 32'd1;
            if (dec_write && s_posted && !s_hit && !dec_block && image_ready)
                                                  cnt_posted_miss <= cnt_posted_miss + 32'd1;
            if (e1_il && !c_hit)                  cnt_decline    <= cnt_decline + 32'd1;
            if (skipped)                          cnt_prot_skips <= cnt_prot_skips + 32'd1;
            if (eng_ward)                         cnt_ward       <= cnt_ward + 32'd1;
        end
    end

    wire eng_go  = (dec_read || dec_write) && !dec_block && !s_hit && image_ready;
    // A WRITE MISS ALLOCATES NOTHING (the user's design: a stream of writes - a
    // copy's destination, a clear, a DMA block, the screen - must not walk
    // the working set out): the byte goes to the backing store as one line
    // write with one lane, in order with the fills that follow it.
    wire eng_ward = eng_go && !s_rw;
    wire eng_fill = eng_go &&  s_rw;
    wire plru_op = s_v && s_hit && !dec_block && (dec_read || dec_write);
    wire plru_il = e1_il && c_hit;
    always_ff @(posedge clk) begin
        op_place_v <= (plru_op || eng_retag) && !rst;
        if (plru_op) begin
            op_place_ppn <= s_ppn; op_place_set <= s_set; op_place_way <= s_way;
        end else if (eng_retag) begin
            op_place_ppn <= e_ppn; op_place_set <= e_set; op_place_way <= e_way;
        end
        evict_v <= eng_fill && !rst;
        if (eng_fill) begin evict_set <= s_set; evict_way <= s_vslot[LEV-1:0]; end
    end

    // ---- the directory's writes ----------------------------------------------
    // The flop vectors: the victim leaves the clock the engine starts, the
    // fill's retag at the last beat makes its slot valid and clean (a write
    // miss's patch dirties it), a landing dirties its slot, the TLB points
    // and unpoints.  An invalidate clears them all in one clock; the LUTRAM
    // words need no clearing (a free way is taken before its bits are read,
    // and a retag writes the whole word).
    wire skipped = eng_fill && !(|(s_vic & s_plru));   // the PLRU's pick was protected
    always_ff @(posedge clk) begin
        if (iv_run) begin
            d_v  <= '0;
            d_d  <= '0;
            refb <= '0;
        end else begin
            if (ref_v)     refb[{ref_set, ref_way}] <= ref_on;
            if (eng_fill)  d_v[s_vslot] <= 1'b0;
            if (eng_retag) begin
                d_v[e_slot] <= 1'b1;
                d_d[e_slot] <= !e_rw;
            end
            if (wl_v)      d_d[wl_slot] <= 1'b1;
        end
    end

    // The LUTRAM words, per way.  A touch: the op path's hit (P2) or a direct
    // read (L1's).  The referenced bit is set by a NON-SEQUENTIAL touch after
    // the fill; the last offset follows every touch.  One write a clock a
    // way, by priority: the retag (its slot is valid the same clock, so its
    // tag MUST land), the op's touch, the skipped pick's reference given up
    // (never the op touch's clock: a skip is a miss), the direct read's touch.
    wire            touch_op = plru_op;
    wire [WAYS-1:0] s_way_oh = WAYS'(1) << s_way;
    genvar gw;
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_dir
            (* ram_style = "distributed" *) logic [DW-1:0] mem [SETS];
            initial for (int i = 0; i < SETS; i = i + 1) mem[i] = '0;
            assign dir_a[gw] = mem[en_set];
            assign dir_b[gw] = mem[s_set];
            assign dir_c[gw] = mem[dr_set];
            wire [7:0] last_b = dir_b[gw][7:0];
            wire [7:0] last_c = dir_c[gw][7:0];
            wire nonseq_b = (s_off   != last_b)      && (s_off   != last_b + 8'd1);
            wire nonseq_c = (dr_line != last_c[7:4]) && (dr_line != last_c[7:4] + 4'd1);
            wire w_retag = eng_retag && (e_way == LEV'(gw));
            wire w_op    = touch_op  && s_way_oh[gw];
            wire w_skip  = skipped   && s_plru[gw] && dir_b[gw][8];
            wire w_dr    = dr_ack    && (dr_way == LEV'(gw));
            always_ff @(posedge clk) begin
                if (w_retag)     mem[e_set]  <= {e_ppn, 1'b0, e_crit, e_boff};
                else if (w_op)   mem[s_set]  <= {dir_b[gw][DW-1:9], dir_b[gw][8] | nonseq_b, s_off};
                else if (w_skip) mem[s_set]  <= {dir_b[gw][DW-1:9], 1'b0, last_b};
                else if (w_dr)   mem[dr_set] <= {dir_c[gw][DW-1:9], dir_c[gw][8] | nonseq_c, dr_line, 4'd0};
            end
        end
    endgenerate

    // The PLRU: every touch, one a clock, the op's first (a retag's touch
    // lost to an op's on the same clock is the CAM's own priority, kept).
    wire            plru_we  = touch_op || dr_ack || plru_il || eng_retag;
    wire [SIDX-1:0] plru_set = touch_op ? s_set : dr_ack ? dr_set : plru_il ? e1_set : e_set;
    wire [LEV-1:0]  plru_way = touch_op ? s_way : dr_ack ? dr_way : plru_il ? c_slot[LEV-1:0] : e_way;
    always_ff @(posedge clk)
        if (plru_we) plr[plru_set] <= plru_touch(plr[plru_set], plru_way);

`ifndef SYNTHESIS
    // The benches' view of the directory: a tag a slot (boot_gs_tb's peek).
    logic [PW-1:0] d_tag [N];
    initial for (int i = 0; i < N; i = i + 1) d_tag[i] = '0;
    always_ff @(posedge clk) if (eng_retag) d_tag[e_slot] <= e_ppn;
    // mw_* carries one byte: a wider write must never land where it is watched.
    always @(posedge clk)
        if (mwx_stb && !rst && ((wl_v ? $countones(wl_be) : $countones(e_lanes)) != 1) &&
            ((mw_bank[7:1] == 7'd0) || (mw_bank[7:1] == 7'h70)))
            $error("page_cam: a multi-byte write landed in bank $%02x, which mw_* watches a byte at a time", mw_bank);
`endif

    // ---- P2: the decision, the engine's states, the monitor -------------------
    logic       cmp_valid;
    logic [7:0] cmp_byte;
    logic [7:0] data_q;
    always_ff @(posedge clk) begin
        data_q  <= data_sync;
        op_blocked <= s_v && !s_posted && dec_block && !rst;
        decided <= (s_v && !s_posted && !eng_read_start) ||
                   ((state == E_FILL) && pr_valid && (resp_n == 5'd0) && e_rw && !e_probe);
        if (rst) begin
            sub_en <= 1'b0; sub_data <= 8'd0;
            op_row_v <= 1'b0; op_row <= 128'd0; op_row_ppn <= '0;
            decided <= 1'b0;
            cmp_valid <= 1'b0; cmp_byte <= 8'd0;
            state <= E_IDLE;
            pq_valid <= 1'b0; pq_we <= 1'b0; pq_line <= '0;
            e_ppn <= '0; e_old <= '0; e_slot <= {SW{1'b0}};
            e_crit <= 4'd0; e_boff <= 4'd0; e_wword <= 32'd0; e_lanes <= 16'd0; e_addr <= 16'd0;
            e_dirty <= 1'b0; e_rw <= 1'b1; e_serve <= 1'b0; e_cmp <= 1'b0; e_main <= 1'b0; e_low <= 1'b0; e_probe <= 1'b0;
            snap_k <= 5'd0; req_n <= 4'd0; fl_k <= 4'd0; resp_n <= 5'd0;
            hits <= 32'd0; misses <= 32'd0; served <= 32'd0;
            mismatches <= 32'd0; last_mismatch <= 32'd0; diverted <= 32'd0;
            late_fills <= 8'd0; fifo_drops <= 8'd0;
            mem_fills <= 32'd0; mem_flushes <= 32'd0; mem_declines <= 32'd0;
            ld_wdata_q <= 128'd0;
        end else begin
            sub_en    <= 1'b0;
            op_row_v  <= 1'b0;
            cmp_valid <= 1'b0;

            if (e1_il && !c_hit) mem_declines <= mem_declines + 32'd1;

            // The loader's line, when nothing else wants the engine.
            if (ld_valid && state == E_IDLE && !iv_run && image_ready && !s_v) begin
                state      <= E_LDWR;
                pq_valid   <= 1'b1;
                pq_we      <= 1'b1;
                pq_line    <= (PW+4)'(ld_line);   // the loader writes the 65816's 16 MB
                ld_wdata_q <= ld_wdata;
            end

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
            end else if (dec_write && !s_hit && image_ready) begin
                // The write-around.
                misses     <= misses + 32'd1;
                state      <= E_WARD;
                pq_valid   <= 1'b1;
                pq_we      <= 1'b1;
                pq_line    <= {s_ppn, s_off[7:4]};
                ld_wdata_q <= {4{s_wdata}};
                e_ppn      <= s_ppn;
                e_boff     <= s_off[3:0];
                e_wword    <= s_wdata;
                e_lanes    <= 16'(s_be) << s_off[3:0];
                e_addr     <= {s_ppn[7:0], s_off};
                e_main     <= low16(s_ppn) && (s_ppn[15:8] == 8'd0);
                e_low      <= low16(s_ppn);
            end else if ((dec_read || dec_write) && !s_hit) begin
                misses <= misses + 32'd1;
                if (image_ready) begin
                    state     <= s_vdty ? E_SNAP : E_FILL;
                    e_ppn     <= s_ppn;
                    e_old     <= v_tag2;
                    e_slot    <= s_vslot;
                    e_crit    <= s_off[7:4];
                    e_boff    <= s_off[3:0];
                    e_wword   <= s_wdata;
                    e_lanes   <= 16'(s_be) << s_off[3:0];
                    e_addr    <= {s_ppn[7:0], s_off};
                    e_dirty   <= s_vdty;
                    e_rw      <= s_rw;
                    e_serve   <= serve_this && !s_posted;
                    e_probe   <= s_probe;
                    e_cmp     <= s_rw && s_machine;
                    e_main    <= low16(s_ppn) && (s_ppn[15:8] == 8'd0);
                    e_low     <= low16(s_ppn);
                    mem_fills <= mem_fills + 32'd1;
                    snap_k    <= 5'd0;
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
                    if (snap_hold) begin
                    end else
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
                        mem_flushes <= mem_flushes + 32'd1;
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
                E_LDWR: if (accept) begin
                    pq_valid <= 1'b0;
                    pq_we    <= 1'b0;
                    state    <= E_IDLE;
                end
                E_WARD: if (accept) begin
                    pq_valid <= 1'b0;
                    pq_we    <= 1'b0;
                    state    <= E_IDLE;
                end
                default: ;
            endcase

            if (op_commit && op_divert) diverted <= diverted + 32'd1;
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
    wire [127:0] b_mux = b_row;

    always_comb begin
        case (dbg_sel)
            4'd0:  dbg_val = cnt_il_i;
            4'd1:  dbg_val = cnt_il_d;
            4'd2:  dbg_val = cnt_land_clash;
            4'd3:  dbg_val = cnt_ppn_clash;
            4'd4:  dbg_val = cnt_hit_uc;
            4'd5:  dbg_val = cnt_decline;
            4'd6:  dbg_val = cnt_iv_block;
            4'd7:  dbg_val = cnt_posted;
            4'd8:  dbg_val = cnt_posted_miss;
            4'd9:  dbg_val = cnt_prot_skips;
            4'd10: dbg_val = cnt_ward;
            4'd14: dbg_val = cnt_dr;
            default: dbg_val = {29'd0, state};
        endcase
    end
endmodule
