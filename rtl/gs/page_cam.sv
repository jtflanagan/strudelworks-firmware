`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// page_cam - the 65816 card's L2 as a fully associative page store
// (docs/CORE_REFACTOR_65816.md "The CAM-L2", the user's design, 2026-09-19).
//
// N SLOTS OF ONE BLOCK RAM (N x 16 rows of 16 bytes: 64 slots = 16 KB =
// four RAMB36, against the 64 of 128 x 8), and a DIRECTORY IN FLOPS - one
// entry per slot {valid, dirty, tag, referenced, last offset} - that IS the
// CAM: an entrant's page is compared against every slot in P0, the row of
// the slot that matched is read at once, and the pipeline behind (P1 the
// landing, P2 the decision, the engine, the seams, the taps, the monitor)
// is rtl/gs/page_cache.sv's, kept whole.  There is no set: the L1 sides'
// TLB names a slot where it named a set, and a one-bit way that is always
// zero.
//
// WHAT THE SET CACHE COULD NOT DO, THIS DOES: keep a WORKING SET against a
// STREAM.  The victim is chosen as before among the ways L1 does not point
// at (the referenced-slot rule), but first among slots that were never
// RE-REFERENCED since they were filled: a slot's referenced bit is set only
// by a NON-SEQUENTIAL touch after its fill (an access whose offset is not
// the last one's or the last one's successor - a loop's branch back, a
// table looked up, the stack; never a copy, a clear, a DMA landing or a
// sweep of the screen, however long it dwells on the page), and the tree
// PLRU picks among the rest.  A protected slot the PLRU would have taken is
// given up one reference at a time (its bit clears when it is skipped), so
// a working set that stops being one drains out.  Write misses still
// allocate in this first cut; writing around them is the next step.
//
// The engine (E_SNAP / E_FILL / E_PATCH / E_SETTLE / E_FLUSH / E_LDWR), the
// P+2 law, the snapshot's landing hold, the posted seam, the shadow
// duplicate's entrant, the loader's line port, the direct way read, the
// placement report and the eviction broadcast are page_cache's, by name.
//////////////////////////////////////////////////////////////////////////////////
module page_cam #(
    parameter integer N = 64                   // slots (a power of two)
) (
    input  wire        clk,
    input  wire        rst,
    // The classified op stream (P1).
    input  wire        cl_valid,
    input  wire [1:0]  cl_cls,
    input  wire [15:0] cl_ppn,
    input  wire [7:0]  cl_off,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [7:0]  cl_wdata,
    input  wire        cl_posted,
    input  wire        pw_pending,
    output wire        pw_ready,
    // The op's preview (P0).
    input  wire [15:0] pf_ppn,
    input  wire [7:0]  pf_off,
    // The posted seam's entrant and the shadow duplicate's.
    input  wire        pw_take,
    input  wire [15:0] pw_ppn,
    input  wire [7:0]  pw_off,
    input  wire        shd_take,
    input  wire [15:0] shd_ppn,
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
    output logic [15:0] op_row_ppn,
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
    // The line-row port (no user on this card since rung 3; kept).
    input  wire        il_req,
    input  wire [15:0] il_ppn,
    input  wire [3:0]  il_line,
    input  wire        il_src,
    output wire        il_ack,
    output wire        il_done,
    output logic       il_ok,
    output logic [127:0] il_row,
    // The TLB's references, the eviction broadcast, the placement report,
    // the direct read: a slot where the set cache had a set, way zero.
    input  wire                    ref_v,
    input  wire [$clog2(N)-1:0]    ref_set,
    input  wire [0:0]              ref_way,
    input  wire                    ref_on,
    output logic                   evict_v,
    output logic [$clog2(N)-1:0]   evict_set,
    output logic [0:0]             evict_way,
    output logic                   op_place_v,
    output logic [15:0]            op_place_ppn,
    output logic [$clog2(N)-1:0]   op_place_set,
    output logic [0:0]             op_place_way,
    input  wire                    dr_req,
    input  wire [$clog2(N)-1:0]    dr_set,
    input  wire [0:0]              dr_way,
    input  wire [3:0]              dr_line,
    output wire                    dr_ack,
    output logic                   dr_done,
    output logic [127:0]           dr_row,
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
    output logic [19:0] pq_line,
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

    localparam integer SW    = $clog2(N);       // a slot's index bits
    localparam integer AW    = SW + 4;          // a row address
    localparam integer NODES = N - 1;           // the PLRU tree over N slots

    function automatic [N-1:0] lowest_bit(input [N-1:0] v);
        lowest_bit = v & (-v);
    endfunction
    function automatic [SW-1:0] enc(input [N-1:0] oh);
        int i;
        enc = '0;
        for (i = 0; i < N; i = i + 1) if (oh[i]) enc = SW'(i);
    endfunction
    function automatic [N-1:0] plru_victim(input [NODES-1:0] b);
        int l, node;
        logic [SW-1:0] idx;
        idx  = '0;
        node = 0;
        for (l = 0; l < SW; l = l + 1) begin
            idx  = (idx << 1) | SW'(b[node]);
            node = 2*node + 1 + int'(b[node]);
        end
        plru_victim = {{(N-1){1'b0}}, 1'b1} << idx;
    endfunction
    function automatic [NODES-1:0] plru_touch(input [NODES-1:0] b, input [SW-1:0] t);
        int l, node;
        logic dir;
        plru_touch = b;
        node = 0;
        for (l = 0; l < SW; l = l + 1) begin
            dir = t[SW-1-l];
            plru_touch[node] = ~dir;
            node = 2*node + 1 + int'(dir);
        end
    endfunction

    // ---- the directory, in flops -------------------------------------------
    logic [N-1:0]    d_v;
    logic [N-1:0]    d_d;
    logic [15:0]     d_tag [N];
    logic [N-1:0]    d_ref;           // re-referenced since its fill (non-sequentially)
    logic [7:0]      d_last[N];       // the last offset touched
    logic [N-1:0]    refb;            // pointed at by the TLB
    logic [NODES-1:0] plr;

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
    assign il_ack = il_req && !op_present && !pw_take && !shd_take && !wl_v && !il_busy &&
                    !pw_pending && !iv_run && (state != E_PATCH);

    // ---- P0: the entrant, the CAM, the row read --------------------------------
    wire            e_op  = op_present;
    wire            e_pw  = pw_take;
    wire            e_sh  = shd_take;
    wire            e_il  = il_ack;
    wire            e_any = e_op || e_pw || e_sh || e_il;
    wire [15:0]     en_ppn = e_op ? pf_ppn      : e_pw ? pw_ppn      :
                             e_sh ? shd_ppn     : il_ppn;
    wire [3:0]      en_ln  = e_op ? pf_off[7:4] : e_pw ? pw_off[7:4] :
                             e_sh ? shd_off[7:4] : il_line;
    logic [N-1:0] m0;
    always_comb for (int i = 0; i < N; i = i + 1) m0[i] = d_v[i] && (d_tag[i] == en_ppn);
    wire          hit0  = |m0;
    wire [SW-1:0] slot0 = enc(m0);
    wire [AW-1:0] en_row = {slot0, en_ln};

    // ---- the landing register (P1 -> the row) ------------------------------
    logic [AW-1:0]   wl_row;
    logic [15:0]     wl_be;
    logic [127:0]    wl_data;
    logic            wl_main;
    logic [7:0]      wl_bank;
    logic [15:0]     wl_addr;
    logic [SW-1:0]   wl_slot;

    // ---- the block RAM: port A the op path and the landings, port B the engine
    // and the direct read ------------------------------------------------------
    logic [SW-1:0]   e_slot;
    wire [AW-1:0] dr_row_addr = {dr_set, dr_line};
    wire          dr_clash    = wl_v && (wl_row == dr_row_addr);
    assign dr_ack = dr_req && eng_idle && !iv_run && !pw_pending && !dr_clash && !rst;
    logic [1:0]     dr_sr;
    logic            eb_en;
    logic [15:0]     eb_we;
    logic [AW-1:0]   eb_addr;
    logic [127:0]    eb_wdata;
    wire [127:0] a_row;
    wire [127:0] b_row;
    wire land = wl_v;
    way_ram #(.ROWS (N * 16)) u_ram (
        .clk     (clk),
        .a_en    (e_any || land),
        .a_we    (land ? wl_be  : 16'd0),
        .a_addr  (land ? wl_row : en_row),
        .a_wdata (wl_data),
        .a_rdata (a_row),
        .b_en    (eb_en || dr_ack),
        .b_we    (dr_ack ? 16'd0 : eb_we),
        .b_addr  (dr_ack ? dr_row_addr : eb_addr),
        .b_wdata (eb_wdata),
        .b_rdata (b_row)
    );

    // ---- P1: what P0 found ------------------------------------------------------
    logic             e1_v, e1_op, e1_il;
    logic [15:0]      e1_ppn;
    logic [3:0]       e1_line;
    logic             c_hit;
    logic [SW-1:0]    c_slot;
    always_ff @(posedge clk) begin
        e1_v  <= e_any && !rst;
        e1_op <= (e_op || e_pw || e_sh) && !rst;
        e1_il <= e_il && !rst;
        if (e_any) begin
            e1_ppn  <= en_ppn;
            e1_line <= en_ln;
            c_hit   <= hit0;
            c_slot  <= slot0;
        end
    end

    // The victim, from the directory's flops: a free slot; else, among the
    // slots the TLB does not point at, the PLRU's pick if it was never
    // re-referenced, else the lowest such, else the PLRU's pick if unpointed,
    // else the lowest unpointed, else the PLRU's pick.
    // THE VICTIM IS A REGISTER, recomputed every clock from the directory's
    // flops and nothing else (the first Pt build's worst path was this choice
    // as a cone at P1: 21 levels, four fifths route).  The engine's own slot
    // is never "free" here, so a page filled last clock is not the stale pick.
    wire [N-1:0]  e_slot_oh = {{(N-1){1'b0}}, 1'b1} << e_slot;
    wire [N-1:0]  free_w   = ~(d_v | e_slot_oh);
    wire [N-1:0]  unref_w  = ~refb;
    wire [N-1:0]  unprot_w = ~d_ref;
    wire [N-1:0]  plru_w   = plru_victim(plr);
    wire [N-1:0]  c_vic_c  = (|free_w)                       ? lowest_bit(free_w) :
                             (|(plru_w & unref_w & unprot_w)) ? plru_w :
                             (|(unref_w & unprot_w))          ? lowest_bit(unref_w & unprot_w) :
                             (|(plru_w & unref_w))            ? plru_w :
                             (|unref_w)                       ? lowest_bit(unref_w) : plru_w;
    logic [SW-1:0] vic_q;
    logic [N-1:0]  plru_q;
    always_ff @(posedge clk) begin
        vic_q  <= enc(c_vic_c);
        plru_q <= plru_w;
    end
    wire [SW-1:0] c_vslot = vic_q;
    wire [15:0]   c_vtag  = d_tag[c_vslot];
    // ...a dirty bit set one clock ago (the landing register) has not reached
    // d_d: the victim's dirtiness counts it.
    wire          c_vdty  = d_d[c_vslot] || (wl_v && wl_slot == c_vslot);

    // ---- P1 -> P2: the op's stage, and a write's landing -------------------
    logic            s_v, s_posted, s_rw, s_wr_image, s_machine, s_hit, s_vdty;
    logic [1:0]      s_cls;
    logic [15:0]     s_ppn, s_vtag, s_addr;
    logic [7:0]      s_off, s_wdata;
    logic [SW-1:0]   s_slot, s_vslot;
    logic [N-1:0]    s_plru;
    wire p1_wr = cl_valid && !cl_rw && cl_wr_image && c_hit && !iv_run;
    always_ff @(posedge clk) begin
        s_v  <= cl_valid && !rst;
        wl_v <= p1_wr && !rst;
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
            s_hit      <= c_hit;
            s_slot     <= c_slot;
            s_vslot    <= c_vslot;
            s_vtag     <= c_vtag;
            s_vdty     <= c_vdty;
            s_plru     <= plru_q;
        end
        if (p1_wr) begin
            wl_slot <= c_slot;
            wl_row  <= {c_slot, cl_off[7:4]};
            wl_be   <= 16'd1 << cl_off[3:0];
            wl_data <= {16{cl_wdata}};
            wl_main <= (cl_ppn[15:8] == 8'd0);
            wl_bank <= cl_ppn[15:8];
            wl_addr <= {cl_ppn[7:0], cl_off};
        end
    end
    wire [127:0] mux_row = a_row;     // two clocks after P0's read: at P2
    wire [7:0]   rbyte   = mux_row[8 * s_off[3:0] +: 8];

    logic il_hit_q;
    assign il_done = il_sr[2];
    always_ff @(posedge clk) begin
        il_sr <= rst ? 3'd0 : {il_sr[1:0], il_ack};
        if (e1_il)    il_hit_q <= c_hit;
        if (il_sr[1]) il_row   <= mux_row;
        if (il_sr[1]) il_ok    <= il_hit_q;
    end
    always_ff @(posedge clk) begin
        dr_sr <= rst ? 2'd0 : {dr_sr[0], dr_ack};
        if (dr_sr[0]) dr_row <= b_row;
        dr_done <= dr_sr[0] && !rst;
    end

    // ---- the engine ---------------------------------------------------------
    logic [15:0]     e_ppn, e_old, e_addr;
    logic [3:0]      e_crit, e_boff;
    logic [7:0]      e_wbyte;
    logic            e_dirty, e_rw, e_serve, e_cmp, e_main;
    logic [4:0]      snap_k;
    wire             snap_hold = (snap_k == 5'd0) && wl_v && (wl_slot == e_slot);
    logic [3:0]      req_n, fl_k;
    logic [4:0]      resp_n;
    assign pq_busy = !eng_idle;
    logic [127:0] pbuf [0:15];
    logic [127:0] ld_wdata_q;
    assign pq_wdata = (state == E_LDWR || state == E_WARD) ? ld_wdata_q : pbuf[fl_k];
    assign pq_sel   = (state == E_WARD) ? (16'd1 << e_boff) : 16'hFFFF;
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
                eb_we    = 16'd1 << e_boff;
                eb_addr  = {e_slot, e_crit};
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
    wire   e_wr_stb = (state == E_PATCH) || (state == E_WARD && accept);
    assign mw_stb  = (wl_v && wl_main) || (e_wr_stb && e_main);
    assign mwx_stb = wl_v || e_wr_stb;
    assign mw_bank = wl_v ? wl_bank : e_ppn[15:8];
    assign mw_addr = wl_v ? wl_addr : e_addr;
    assign mw_byte = wl_v ? wl_data[7:0] : e_wbyte;
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
            if (wl_v && e_any)                    cnt_land_clash <= cnt_land_clash + 32'd1;
            if (cl_valid && (!e1_op || e1_ppn != cl_ppn || e1_line != cl_off[7:4]))
                                                  cnt_ppn_clash  <= cnt_ppn_clash + 32'd1;
            if (dec_read && s_hit && !eng_idle)   cnt_hit_uc     <= cnt_hit_uc + 32'd1;
            if ((dec_read || dec_write) && iv_run) cnt_iv_block  <= cnt_iv_block + 32'd1;
            if (s_v && s_posted)                  cnt_posted     <= cnt_posted + 32'd1;
            if (dec_write && s_posted && !s_hit && !dec_block && image_ready)
                                                  cnt_posted_miss <= cnt_posted_miss + 32'd1;
            if (e1_il && !c_hit)                  cnt_decline    <= cnt_decline + 32'd1;
            if (eng_fill && !s_plru[s_vslot])     cnt_prot_skips <= cnt_prot_skips + 32'd1;
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
        op_place_way <= 1'b0;
        if (plru_op) begin
            op_place_ppn <= s_ppn; op_place_set <= s_slot;
        end else if (eng_retag) begin
            op_place_ppn <= e_ppn; op_place_set <= e_slot;
        end
        evict_v <= eng_fill && !rst;
        evict_way <= 1'b0;
        if (eng_fill) evict_set <= s_vslot;
    end

    // ---- the directory's writes ----------------------------------------------
    // A touch: the op path's hit (P2), a direct read (L1's), a line-port hit.
    // The referenced bit is set by a NON-SEQUENTIAL touch after the fill;
    // the PLRU is touched by every one.
    wire            touch_op = plru_op;
    wire [7:0]      touch_off = s_off;
    wire            touch_dr = dr_ack;
    wire [7:0]      dr_off   = {dr_line, 4'd0};
    wire            skipped  = eng_fill && !s_plru[s_vslot];   // the PLRU's pick was protected
    wire [SW-1:0]   plru_pick = enc(s_plru);
    always_ff @(posedge clk) begin
        if (iv_run) begin
            for (int i = 0; i < N; i = i + 1) begin
                d_v[i] <= 1'b0; d_d[i] <= 1'b0; d_ref[i] <= 1'b0; d_last[i] <= 8'd0;
            end
            refb <= '0;
            plr  <= '0;
        end else begin
            if (ref_v) refb[ref_set] <= ref_on;
            // The victim leaves the directory the clock the engine starts.
            if (eng_fill) begin
                d_v[s_vslot] <= 1'b0;
                if (skipped && d_ref[plru_pick]) d_ref[plru_pick] <= 1'b0;   // one reference given up
            end
            // The fill's retag, at the last beat: valid, clean (a write miss's
            // patch dirties it), unreferenced, its last offset the miss's.
            if (eng_retag) begin
                d_v[e_slot]    <= 1'b1;
                d_d[e_slot]    <= !e_rw;
                d_tag[e_slot]  <= e_ppn;
                d_ref[e_slot]  <= 1'b0;
                d_last[e_slot] <= {e_crit, e_boff};
                plr <= plru_touch(plr, e_slot);
            end
            // A landing dirties its slot.
            if (wl_v) d_d[wl_slot] <= 1'b1;
            // The touches.
            if (touch_op) begin
                if (touch_off != d_last[s_slot] && touch_off != d_last[s_slot] + 8'd1) d_ref[s_slot] <= 1'b1;
                d_last[s_slot] <= touch_off;
                plr <= plru_touch(plr, s_slot);
            end else if (touch_dr) begin
                if (dr_line != d_last[dr_set][7:4] && dr_line != d_last[dr_set][7:4] + 4'd1) d_ref[dr_set] <= 1'b1;
                d_last[dr_set] <= dr_off;
                plr <= plru_touch(plr, dr_set);
            end else if (plru_il) begin
                plr <= plru_touch(plr, c_slot);
            end
        end
    end

    // ---- P2: the decision, the engine's states, the monitor -------------------
    logic       cmp_valid;
    logic [7:0] cmp_byte;
    logic [7:0] data_q;
    always_ff @(posedge clk) begin
        data_q  <= data_sync;
        op_blocked <= s_v && !s_posted && dec_block && !rst;
        decided <= (s_v && !s_posted && !eng_read_start) ||
                   ((state == E_FILL) && pr_valid && (resp_n == 5'd0) && e_rw);
        if (rst) begin
            sub_en <= 1'b0; sub_data <= 8'd0;
            op_row_v <= 1'b0; op_row <= 128'd0; op_row_ppn <= 16'd0;
            decided <= 1'b0;
            cmp_valid <= 1'b0; cmp_byte <= 8'd0;
            state <= E_IDLE;
            pq_valid <= 1'b0; pq_we <= 1'b0; pq_line <= 20'd0;
            e_ppn <= 16'd0; e_old <= 16'd0; e_slot <= {SW{1'b0}};
            e_crit <= 4'd0; e_boff <= 4'd0; e_wbyte <= 8'd0; e_addr <= 16'd0;
            e_dirty <= 1'b0; e_rw <= 1'b1; e_serve <= 1'b0; e_cmp <= 1'b0; e_main <= 1'b0;
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
                pq_line    <= ld_line;
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
                ld_wdata_q <= {16{s_wdata}};
                e_ppn      <= s_ppn;
                e_boff     <= s_off[3:0];
                e_wbyte    <= s_wdata;
                e_addr     <= {s_ppn[7:0], s_off};
                e_main     <= (s_ppn[15:8] == 8'd0);
            end else if ((dec_read || dec_write) && !s_hit) begin
                misses <= misses + 32'd1;
                if (image_ready) begin
                    state     <= s_vdty ? E_SNAP : E_FILL;
                    e_ppn     <= s_ppn;
                    e_old     <= s_vtag;
                    e_slot    <= s_vslot;
                    e_crit    <= s_off[7:4];
                    e_boff    <= s_off[3:0];
                    e_wbyte   <= s_wdata;
                    e_addr    <= {s_ppn[7:0], s_off};
                    e_dirty   <= s_vdty;
                    e_rw      <= s_rw;
                    e_serve   <= serve_this && !s_posted;
                    e_cmp     <= s_rw && s_machine;
                    e_main    <= (s_ppn[15:8] == 8'd0);
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
