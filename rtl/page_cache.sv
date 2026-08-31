`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// page_cache - the machine's memory in two 64 KB banks of block RAM, served
// to the core; the DDR3 demoted to backing the RamWorks.  docs/PAGE_CACHE.md
// is the design; this replaces rtl/mem_cache.sv and its 4-way cache.
//
// THE CACHE IS THE ADDRESS SPACE.  Both banks are addressed one-to-one by the
// folded 16-bit bus address (rtl/apple_mmu.sv's pf_off/cl_off: the language
// card's bank 1 of $D000 in the $C000 hole), so the row read starts at
// op_present, before classification - the classifier runs BESIDE the fetch
// and its verdict arrives with the data, not in front of it.
//
//   MAIN is tagless, permanently resident, and AUTHORITATIVE: it is not a
//   cache of main memory, it IS main memory, and the DDR3 holds no copy.
//   It cannot miss and it never flushes.
//
//   AUX carries one tag per 256-byte page - which RamWorks bank is resident,
//   a valid bit, ONE dirty bit - and misses only when RamWorks banking is
//   actually in use.  An INVALID page is CLAIMED where it stands: tagged for
//   the wanted bank with no fill and no flush, its bytes the garbage they
//   were, exactly as a powered-up Apple's memory is garbage (docs/MEMORY.md).
//   So a machine that never writes $C071/$C073 never touches the DDR3 at all.
//
// THE PIPELINE, in clocks after op_present (P0):
//
//   P0  both banks and the ROM are addressed from the raw op; apple_mmu is
//       classifying beside them
//   P1  the classified op and the aux page's tag are registered
//   P2  the rows are out of the block RAMs' second registers; ONE byte select
//       per bank, ONE tag compare; the decision is registered
//   P3  sub_en/sub_data stand, a write is landing in its bank, or the page
//       engine has taken over
//
// Three clocks against the old design's six, because nothing is serialized:
// no classify-then-index, no four-way compare, no victim, no LRU, no tag
// write-back on the way out.
//
// WRITES ARE WRITE-BACK.  A write lands in its bank's row and, on the aux
// side, sets its page's one dirty bit; the DDR3 sees nothing until the page
// is evicted, and a dirty page then flushes WHOLE - sixteen beats of one
// incrementally-addressed burst.  Per-line dirty bits would fragment that
// burst to save writes that cost a clock each (docs/PAGE_CACHE.md).
//
// THE MISS, sequentially: SNAPSHOT the victim page out of port B into a
// 256-byte buffer (17 clocks), FILL the page critical-line-first in sixteen
// pipelined beats - the requested byte is served the moment its beat lands,
// ~30 clocks into a ~98-clock cycle against a deadline of ~91 - then PATCH
// the written byte in (a write miss), then FLUSH the buffer to the victim's
// bank iff it was dirty.  The design doc overlaps the snapshot with the
// critical read; this first cut takes the 17 clocks in series instead, which
// spends margin the 1 MHz budget has and removes a race between the
// snapshot's reads and the fill's installs on the one port.
//
// ONE OP AT A TIME, and the engine done before the next.  At Apple speed the
// whole miss (~50 clocks, ~85 dirty and refresh-collided) is over before the
// next op_present.  If an aux op ever arrives while the engine is busy it is
// counted (late_fills) and NOT touched - not served, not written - because
// the tags and the aux port are the engine's until it is done.  That counter
// must read zero on hardware, exactly as the old design's late_fills did.
//
// THE MONITOR AND THE COUNTERS keep rtl/mem_cache.sv's contract: compare
// only memory the machine has (main, and aux RamWorks bank 0), at op_commit,
// against the bus's byte; unwritten memory is garbage and the mismatch count
// PLATEAUS rather than reads zero.  `late_fills` is the engine-overrun count
// and `fifo_drops` counts ops a miss could not service (DDR3 not ready).
// `invalidating` is tied low: an invalidate is one clock now (the valid bits
// are flops), and note it DISCARDS dirty RamWorks pages - it is a debug
// lever, not an operation the running machine uses.
//////////////////////////////////////////////////////////////////////////////////
module page_cache (
    input  wire        clk,
    // The card's reset.  RES' never comes here: like real RAM, the banks
    // survive the machine being reset.
    input  wire        rst,

    // The classified op, from apple_mmu (P1), and its P0 preview of the
    // folded offset for the banks' addressing.
    input  wire        cl_valid,
    input  wire [1:0]  cl_cls,
    input  wire        cl_aux,
    input  wire [7:0]  cl_bank,
    input  wire [15:0] cl_off,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [15:0] pf_off,

    // The op itself, from apple_bus_write.
    input  wire [15:0] op_addr,
    input  wire [7:0]  op_wdata,
    input  wire        op_present,
    input  wire        op_commit,
    input  wire        op_divert,
    // The bus's byte, for the monitor.
    input  wire [7:0]  data_sync,

    // The ROM's byte for this op, valid from P2 (rtl/apple_rom.sv addressed
    // at op_present).
    input  wire [7:0]  rom_byte,
    input  wire        rom_loaded,

    // To the din mux: hold from the decision until the next op_present.
    output logic       sub_en,
    output logic [7:0] sub_data,

    // The floating-bus simulator's read of main memory (rtl/fb_sim.sv): the
    // main bank's port B is its alone - the page engine works the aux
    // bank's - so no arbitration, just the byte the clock after the
    // address.
    input  wire [15:0] fb_addr,
    output wire [7:0]  fb_byte,

    // Control and status, from MEM_CTRL / to MEM_STAT.
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
    output logic [7:0]  late_fills,     // engine overruns: must read zero
    output logic [7:0]  fifo_drops,     // misses the DDR3 could not service

    // The page engine's seam to rtl/page_client.sv: a pipelined stream of
    // whole-line requests.  pq_busy spans the transaction so the client holds
    // the arbiter's grant across the fill-to-flush turnaround.
    output wire         pq_busy,
    output logic        pq_valid,
    output logic        pq_we,
    output logic [19:0] pq_line,        // {bank, off[15:4]}
    output wire [127:0] pq_wdata,
    input  wire         pq_ready,
    input  wire         pr_valid,
    input  wire [127:0] pr_data
);

    localparam [1:0] CLS_BUS = 2'd0;
    localparam [1:0] CLS_RAM = 2'd1;
    localparam [1:0] CLS_LC  = 2'd2;
    localparam [1:0] CLS_ROM = 2'd3;

    // ---- the banks -------------------------------------------------------------
    logic [127:0] main_row, aux_row;

    // Port A: the op's read at P0, the decision's write at P3.
    logic         mw_en, aw_en;
    logic [11:0]  w_row;
    logic [15:0]  w_be;
    logic [127:0] w_data;

    logic         b_en;
    logic [15:0]  b_we;
    logic [11:0]  b_addr;
    logic [127:0] b_wdata;
    logic [127:0] b_rdata;

    logic [127:0] fb_row;
    logic [3:0]   fb_lo_q;

    bank_ram u_main (
        .clk     (clk),
        .a_en    (op_present || mw_en),
        .a_we    (mw_en ? w_be : 16'd0),
        .a_addr  (mw_en ? w_row : pf_off[15:4]),
        .a_wdata (w_data),
        .a_rdata (main_row),
        // Port B is the floating-bus simulator's, every clock.
        .b_en    (1'b1),
        .b_we    (16'd0),
        .b_addr  (fb_addr[15:4]),
        .b_wdata (128'd0),
        .b_rdata (fb_row)
    );

    always_ff @(posedge clk) fb_lo_q <= fb_addr[3:0];
    assign fb_byte = fb_row[8 * fb_lo_q +: 8];

    bank_ram u_aux (
        .clk     (clk),
        .a_en    (op_present || aw_en),
        .a_we    (aw_en ? w_be : 16'd0),
        .a_addr  (aw_en ? w_row : pf_off[15:4]),
        .a_wdata (w_data),
        .a_rdata (aux_row),
        .b_en    (b_en),
        .b_we    (b_we),
        .b_addr  (b_addr),
        .b_wdata (b_wdata),
        .b_rdata (b_rdata)
    );

    // ---- the aux tags ----------------------------------------------------------
    // One entry per 256-byte page: the resident bank in LUTRAM, valid and
    // dirty as flops so an invalidate is one clock and the engine can set
    // them beside its own state.
    (* ram_style = "distributed" *) logic [7:0] tag_bank [0:255];
    logic [255:0] vld, dty;

    assign invalidating = 1'b0;

    // ---- the op, staged --------------------------------------------------------
    // P1: the classified op and the tag it indexes.
    logic        g2;
    logic [1:0]  s_cls;
    logic        s_aux, s_rw, s_wr_image, s_machine;
    logic [7:0]  s_bank, s_tbank, s_wdata;
    logic [15:0] s_off, s_addr;
    logic        s_tvld, s_tdty;

    always_ff @(posedge clk) begin
        g2 <= cl_valid && !rst;
        if (cl_valid) begin
            s_cls      <= cl_cls;
            s_aux      <= cl_aux;
            s_bank     <= cl_bank;
            s_off      <= cl_off;
            s_rw       <= cl_rw;
            s_wr_image <= cl_wr_image;
            s_addr     <= op_addr;
            s_wdata    <= op_wdata;
            s_machine  <= !cl_aux || (cl_bank == 8'd0);
            s_tbank    <= tag_bank[cl_off[15:8]];
            s_tvld     <= vld[cl_off[15:8]];
            s_tdty     <= dty[cl_off[15:8]];
        end
    end

    // P2: the decision's raw material, combinational.
    wire [7:0] t_idx   = s_off[15:8];
    wire [7:0] rbyte   = s_aux ? aux_row[8 * s_off[3:0] +: 8]
                               : main_row[8 * s_off[3:0] +: 8];
    wire       aux_hit = s_tvld && (s_tbank == s_bank);
    wire       d_cache = (s_cls == CLS_RAM) || (s_cls == CLS_LC);
    wire       d_hit   = !s_aux || aux_hit;
    wire       d_claim = s_aux && !s_tvld;
    wire       d_rom   = (s_cls == CLS_ROM) && rom_loaded;
    wire       serve_this = serve && (d_cache || d_rom);

    // ---- the page engine -------------------------------------------------------
    localparam [2:0] E_IDLE  = 3'd0;
    localparam [2:0] E_SNAP  = 3'd1;
    localparam [2:0] E_FILL  = 3'd2;
    localparam [2:0] E_PATCH = 3'd3;
    localparam [2:0] E_FLUSH = 3'd4;

    logic [2:0] state;
    logic [7:0] e_page_want, e_old;
    logic [7:0] e_page;
    logic [3:0] e_crit, e_boff;
    logic [7:0] e_wbyte;
    logic       e_dirty, e_rw, e_serve, e_cmp;
    logic [4:0] snap_k;
    logic [3:0] req_n, fl_k;
    logic [4:0] resp_n;

    wire eng_idle = (state == E_IDLE);
    assign pq_busy = !eng_idle;

    // The snapshot buffer: the victim page, one line per entry.
    logic [127:0] pbuf [0:15];
    assign pq_wdata = pbuf[fl_k];

    wire accept = pq_valid && pq_ready;

    // Port B: the snapshot's reads, a fill's installs, the patch.
    always_comb begin
        b_en    = 1'b0;
        b_we    = 16'd0;
        b_addr  = 12'd0;
        b_wdata = 128'd0;
        case (state)
            E_SNAP: begin
                b_en   = !snap_k[4];
                b_addr = {e_page, snap_k[3:0]};
            end
            E_FILL: if (pr_valid) begin
                b_en    = 1'b1;
                b_we    = 16'hFFFF;
                b_addr  = {e_page, e_crit + resp_n[3:0]};
                b_wdata = pr_data;
            end
            E_PATCH: begin
                b_en    = 1'b1;
                b_we    = 16'd1 << e_boff;
                b_addr  = {e_page, e_crit};
                b_wdata = {16{e_wbyte}};
            end
            default: ;
        endcase
    end

    // ---- the tag writes --------------------------------------------------------
    // Two writers that cannot collide: the engine retags at its fill's end,
    // and the engine holds off every aux decision while it runs.
    wire dec_read  = g2 && s_rw && d_cache;
    wire dec_write = g2 && !s_rw && s_wr_image;
    wire dec_aux_blocked = (dec_read || dec_write) && s_aux && !eng_idle;
    wire eng_retag = (state == E_FILL) && pr_valid && (resp_n == 5'd15);
    wire dec_claim = (dec_read || dec_write) && d_claim && eng_idle;

    always_ff @(posedge clk) begin
        if (eng_retag)      tag_bank[e_page] <= e_page_want;
        else if (dec_claim) tag_bank[t_idx]  <= s_bank;
    end

    // ---- the decision, the engine, the counters -------------------------------
    logic       cmp_valid;
    logic [7:0] cmp_byte;
    logic [7:0] data_q;

    always_ff @(posedge clk) begin
        // Defaults: single-cycle strobes.
        mw_en  <= 1'b0;
        aw_en  <= 1'b0;
        data_q <= data_sync;

        if (rst) begin
            sub_en <= 1'b0; sub_data <= 8'd0;
            cmp_valid <= 1'b0; cmp_byte <= 8'd0;
            vld <= 256'd0; dty <= 256'd0;
            state <= E_IDLE;
            pq_valid <= 1'b0; pq_we <= 1'b0; pq_line <= 20'd0;
            e_page_want <= 8'd0; e_old <= 8'd0; e_page <= 8'd0;
            e_crit <= 4'd0; e_boff <= 4'd0; e_wbyte <= 8'd0;
            e_dirty <= 1'b0; e_rw <= 1'b1; e_serve <= 1'b0; e_cmp <= 1'b0;
            snap_k <= 5'd0; req_n <= 4'd0; fl_k <= 4'd0; resp_n <= 5'd0;
            w_row <= 12'd0; w_be <= 16'd0; w_data <= 128'd0;
            hits <= 32'd0; misses <= 32'd0; served <= 32'd0;
            mismatches <= 32'd0; last_mismatch <= 32'd0; diverted <= 32'd0;
            late_fills <= 8'd0; fifo_drops <= 8'd0;
        end else begin
            // ---- a new op: the previous one is over -------------------------
            // A miss transaction in flight still completes - its installs and
            // its retag are the page's, not the op's - but its serve and its
            // compare belonged to the op that started it, and die with it.
            if (op_present) begin
                sub_en    <= 1'b0;
                cmp_valid <= 1'b0;
                e_serve   <= 1'b0;
                e_cmp     <= 1'b0;
            end

            // ---- P2: the decision -------------------------------------------
            if (dec_read) begin
                if (dec_aux_blocked) begin
                    late_fills <= late_fills + 8'd1;
                end else if (d_hit) begin
                    hits <= hits + 32'd1;
                    if (serve_this) begin
                        sub_en   <= 1'b1;
                        sub_data <= rbyte;
                        served   <= served + 32'd1;
                    end
                    cmp_valid <= 1'b1;
                    cmp_byte  <= rbyte;
                end else if (d_claim) begin
                    // Claimed where it stands: garbage, as real RAM powers up.
                    misses <= misses + 32'd1;
                    vld[t_idx] <= 1'b1;
                    dty[t_idx] <= 1'b0;
                    if (serve_this) begin
                        sub_en   <= 1'b1;
                        sub_data <= rbyte;
                        served   <= served + 32'd1;
                    end
                    cmp_valid <= 1'b1;
                    cmp_byte  <= rbyte;
                end else begin
                    misses <= misses + 32'd1;
                    if (image_ready) begin
                        state       <= E_SNAP;
                        e_page      <= s_off[15:8];
                        e_crit      <= s_off[7:4];
                        e_boff      <= s_off[3:0];
                        e_page_want <= s_bank;
                        e_old       <= s_tbank;
                        e_dirty     <= s_tdty;
                        e_rw        <= 1'b1;
                        e_serve     <= serve_this;
                        e_cmp       <= s_machine;
                        snap_k      <= 5'd0;
                    end else begin
                        fifo_drops <= fifo_drops + 8'd1;
                    end
                end
            end else if (g2 && s_rw && d_rom) begin
                if (serve) begin
                    sub_en   <= 1'b1;
                    sub_data <= rom_byte;
                    served   <= served + 32'd1;
                end
                cmp_valid <= 1'b1;
                cmp_byte  <= rom_byte;
            end else if (dec_write) begin
                if (dec_aux_blocked) begin
                    late_fills <= late_fills + 8'd1;
                end else if (!s_aux || aux_hit || d_claim) begin
                    w_row  <= s_off[15:4];
                    w_be   <= 16'd1 << s_off[3:0];
                    w_data <= {16{s_wdata}};
                    if (s_aux) begin
                        aw_en      <= 1'b1;
                        vld[t_idx] <= 1'b1;   // a claim; a hit re-affirms
                        dty[t_idx] <= 1'b1;
                        if (d_claim) misses <= misses + 32'd1;
                    end else begin
                        mw_en <= 1'b1;
                    end
                end else begin
                    misses <= misses + 32'd1;
                    if (image_ready) begin
                        state       <= E_SNAP;
                        e_page      <= s_off[15:8];
                        e_crit      <= s_off[7:4];
                        e_boff      <= s_off[3:0];
                        e_wbyte     <= s_wdata;
                        e_page_want <= s_bank;
                        e_old       <= s_tbank;
                        e_dirty     <= s_tdty;
                        e_rw        <= 1'b0;
                        e_serve     <= 1'b0;
                        e_cmp       <= 1'b0;
                        snap_k      <= 5'd0;
                    end else begin
                        fifo_drops <= fifo_drops + 8'd1;
                    end
                end
            end

            // ---- the engine ---------------------------------------------------
            case (state)
                E_SNAP: begin
                    // Address k this clock, catch its line the next.
                    if (snap_k != 5'd0) pbuf[snap_k[3:0] - 4'd1] <= b_rdata;
                    if (snap_k == 5'd16) begin
                        state    <= E_FILL;
                        pq_valid <= 1'b1;
                        pq_we    <= 1'b0;
                        pq_line  <= {e_page_want, e_page, e_crit};
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
                            req_n         <= req_n + 4'd1;
                            pq_line[3:0]  <= e_crit + req_n + 4'd1;
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
                            vld[e_page] <= 1'b1;
                            dty[e_page] <= !e_rw;
                            state <= !e_rw    ? E_PATCH :
                                     e_dirty  ? E_FLUSH : E_IDLE;
                            if (e_rw && e_dirty) begin
                                pq_valid <= 1'b1;
                                pq_we    <= 1'b1;
                                pq_line  <= {e_old, e_page, 4'd0};
                                fl_k     <= 4'd0;
                            end
                        end
                    end
                end
                E_PATCH: begin
                    state <= e_dirty ? E_FLUSH : E_IDLE;
                    if (e_dirty) begin
                        pq_valid <= 1'b1;
                        pq_we    <= 1'b1;
                        pq_line  <= {e_old, e_page, 4'd0};
                        fl_k     <= 4'd0;
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

            // ---- the levers -------------------------------------------------
            if (inval) begin
                vld <= 256'd0;
                dty <= 256'd0;
            end
            if (cnt_clr) begin
                hits <= 32'd0; misses <= 32'd0; served <= 32'd0;
                mismatches <= 32'd0; last_mismatch <= 32'd0; diverted <= 32'd0;
                late_fills <= 8'd0; fifo_drops <= 8'd0;
            end
        end
    end

endmodule
