// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// l1i_store - THE INSTRUCTION STORE: L1-I as a block-RAM fetch source
// (docs/CORE_REFACTOR_65816.md rung 8, the user's design, 2026-09-20).
//
// Two ways of sixteen 256-byte pages (two RAMB36, rtl/gs/store_ram.sv),
// read by the core's NEXT PC.  The core exports pc_d, the D input of its PC
// register; the store reads the byte at pc_d[11:0] from both ways this
// clock, looks the two tags up at pc_d[11:8] in the same clock, and
// registers the hit beside the RAMs' own output registers.  Next clock the
// core fetches at exactly that address, and its din is the hit way's output
// register through one mux level.  Nothing is predicted: a sequential
// fetch, a taken branch, a JMP through a vector, an RTS, an RTL, an RTI, a
// JSL - the target is the PC register's D input on the cycle before the
// fetch, so a fetch to ANY resident byte retires on its own cycle.  The
// two-line buffers, the expected-address predictor, the branch scanner,
// the target table and the target serve of rtl/gs/l1i.sv are what this
// approximates, and they are gone here.
//
// Kept from the lines: the fill engine (the TLB lookup, the page cache's
// direct way read, the row landing at F_W1 off page_cam's dr_erow), now
// writing the row into a way as two 64-bit halves; the row-valid bits (a
// page fills row by row as the code touches it); a next-row prefetch when
// the fetch enters a row's last quarter; and the landing bypass - the byte
// the stalled fetch wants is taken off the landing row into a side
// register and served next clock, so a demand miss costs what it costs the
// lines, not the write-then-read's two more.  Coherence as the lines': an
// image write clears the row's valid bit by physical page; a map change,
// an invalidation or serving off clears every page.  L2's evictions and
// the TLB's deaths are not deaths here: the store copies memory, not L2,
// and every write to memory is on the snoop.
module l1i_store #(
    parameter integer SIDX = 6,
    parameter integer LEV  = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,
    // The core's fetch side.
    input  wire [15:0] pc_addr,
    input  wire [7:0]  pc_bank,
    input  wire [23:0] pc_d,          // the PC register's D input: next clock's pc_addr
    input  wire        cpu_rw,
    input  wire        cpu_sync,
    input  wire        cyc_is_i,
    input  wire [7:0]  p_flags,       // unused here (the lines' branch resolution)
    output wire        cyc_en,
    output wire [7:0]  i_din,
    // l1i's split of i_din for the core's early carry: here no target serve
    output wire [7:0]  i_base,
    output wire [7:0]  i_tgt,
    output wire        i_tgt_sel,
    // The sequencer.
    input  wire        accel_cyc_en,
    input  wire [7:0]  accel_din,
    input  wire        turbo_en,
    input  wire        turbo_ok,
    output wire        claim,
    output wire        turbo_commit,
    output wire        turbo_sync,
    output logic       tick_q,
    output logic       tev_valid,
    output logic [15:0] tev_addr,
    output logic [7:0] tev_data,
    output logic       tev_sync,
    output logic [7:0] tev_bank,
    input  wire        ev_room,
    // The region table (the want's physical page when the TLB has none).
    output wire [23:0] p_addr,
    input  wire [15:0] p_ppn,
    input  wire [3:0]  p_reg,
    input  wire        p_fold,
    input  wire        p_fs,
    input  wire        map_changed,
    input  wire        map_settling,
    input  wire        intc8rom,
    // The TLB.
    output wire [15:0] la_vpage,
    input  wire        la_hit,
    input  wire [15:0] la_ppn,
    input  wire [SIDX-1:0] la_set,
    input  wire [LEV-1:0]  la_way,
    // lookup C (l1i's prefetch lookup; the store has none: it mirrors A)
    output wire [15:0] lc_vpage,
    input  wire        lc_hit,
    input  wire [15:0] lc_ppn,
    input  wire [SIDX-1:0] lc_set,
    input  wire [LEV-1:0]  lc_way,
    output logic       fi_v,
    output logic [15:0] fi_vpage,
    output logic [15:0] fi_ppn,
    output logic [SIDX-1:0] fi_set,
    output logic [LEV-1:0]  fi_way,
    output logic [3:0] fi_reg,
    output logic       fi_fold,
    input  wire        fi_busy,
    input  wire        kill_v,        // not a death here
    input  wire [15:0] kill_ppn,
    // The page cache: the direct way read, the placement.
    output logic       dr_req,
    output logic [SIDX-1:0] dr_set,
    output logic [LEV-1:0]  dr_way,
    output logic [3:0] dr_line,
    input  wire        dr_ack,
    input  wire        dr_done,
    input  wire [127:0] dr_row,
    input  wire [127:0] dr_erow,
    input  wire        op_place_v,
    input  wire [15:0] op_place_ppn,
    input  wire [SIDX-1:0] op_place_set,
    input  wire [LEV-1:0]  op_place_way,
    input  wire        evict_v,       // not a death here
    input  wire [SIDX-1:0] evict_set,
    input  wire [LEV-1:0]  evict_way,
    // The snoops: image writes, by physical page and offset.
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [15:0] cl_ppn,
    input  wire [15:0] cl_off,
    input  wire        ws_valid,
    input  wire [15:0] ws_ppn,
    input  wire [7:0]  ws_off8,
    input  wire        serve,
    input  wire        inval,
    input  wire [3:0]  dbg_sel,
    output logic [31:0] dbg_val,
    output wire        fill_busy
);
    localparam integer WAYS = 2, SETS = 16;

    // ---- the tags -------------------------------------------------------------
    logic        t_v   [WAYS][SETS];
    logic [7:0]  t_bank[WAYS][SETS];
    logic [3:0]  t_hi  [WAYS][SETS];
    logic [15:0] t_ppn [WAYS][SETS];
    logic [15:0] t_rv  [WAYS][SETS];
    logic        lru   [SETS];          // the way used last

    // ---- the lookup at the next PC ----------------------------------------------
    wire [3:0] set_d = pc_d[11:8];
    wire [3:0] row_d = pc_d[7:4];
    logic [WAYS-1:0] page_d, hit_d;
    always_comb begin
        for (int w = 0; w < WAYS; w = w + 1) begin
            page_d[w] = t_v[w][set_d] && (t_bank[w][set_d] == pc_d[23:16]) && (t_hi[w][set_d] == pc_d[15:12]);
            hit_d[w]  = page_d[w] && t_rv[w][set_d][row_d];
        end
    end
    logic        pair_q, intc8rom_q;
    always_ff @(posedge clk) begin
        intc8rom_q <= rst ? 1'b0 : intc8rom;
        pair_q     <= (pc_bank[7:1] == 7'd0) || (pc_bank[7:1] == 7'h70);
    end
    // Never served from here: the I/O page and the slot ROM page $C3 without
    // INTC8ROM and $CFF in a pair bank (the lines' exclusions).
    function automatic logic excl(input [23:0] a);
        excl = ((a[23:17] == 7'd0) || (a[23:17] == 7'h70)) &&
               ((a[15:8] == 8'hC0) || (a[15:8] == 8'hC3 && !intc8rom_q) || (a[15:4] == 12'hCFF));
    endfunction

    // ---- the ways' RAMs ---------------------------------------------------------
    logic [7:0]  q [WAYS];
    // The writes are combinational from the engine's state: each half lands
    // on the edge that moves the engine on, so the row-valid bit set at F_W2
    // and the second half's write share an edge and a read the next clock
    // sees the row.  (Registered, the write came a clock after the bit, and
    // a fetch on that clock read the row's old bytes: $00/FE3D read as $00
    // at instruction 24 of the short boot, 2026-09-20.)
    wire [WAYS-1:0] wr_en;
    wire [8:0]  wr_addr;
    wire [63:0] wr_data;
    genvar gw;
    generate for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_way
        store_ram u_ram (
            .clk (clk), .rd_en (1'b1), .rd_addr (pc_d[11:0]), .rd_data (q[gw]),
            .wr_en (wr_en[gw]), .wr_addr (wr_addr), .wr_data (wr_data)
        );
    end endgenerate

    // ---- what the read found, registered beside the RAMs' outputs --------------
    logic        hit_q, way_q, excl_q, page_q, pway_q;
    logic [23:0] pcd_q;
    always_ff @(posedge clk) begin
        hit_q  <= !rst && (hit_d != '0);
        way_q  <= hit_d[1];
        page_q <= !rst && (page_d != '0);       // the page is held (its row maybe not)
        pway_q <= page_d[1];
        excl_q <= excl(pc_d);
        pcd_q  <= pc_d;
    end
    wire [23:0] fa      = {pc_bank, pc_addr};        // the fetch on offer
    wire        fetch   = turbo_en && cyc_is_i && cpu_rw && !cpu_rst;
    wire        aligned = (pcd_q == fa);
    wire        res     = hit_q && aligned && !excl_q;
    wire [3:0]  set_q   = pcd_q[11:8];

    // ---- the landing bypass -----------------------------------------------------
    logic        byp_v;
    logic [23:0] byp_addr;
    logic [15:0] byp_ppn;
    logic [7:0]  byp_byte;
    wire byp_hit = byp_v && (byp_addr == fa);

    // ---- the snoops ---------------------------------------------------------------
    wire snp = cl_valid && !cl_rw && cl_wr_image;
    // ...against the fetch's own row this clock (the hit is a clock old).
    wire snp_now = (snp      && (t_ppn[way_q][set_q] == cl_ppn) && (cl_off[7:4]  == pc_addr[7:4])) ||
                   (ws_valid && (t_ppn[way_q][set_q] == ws_ppn) && (ws_off8[7:4] == pc_addr[7:4]));
    wire kill_now = map_settling || inval || !serve || snp_now;

    // ---- the retire ---------------------------------------------------------------
    wire retire = fetch && turbo_ok && ev_room && !kill_now && (res || byp_hit);
    assign turbo_commit = retire;
    assign turbo_sync   = retire && cpu_sync;
    assign cyc_en       = accel_cyc_en || retire;
    // The sequencer's byte for a fetch the store did not serve (the reset
    // vector's, an excluded page's, a miss the dispatcher took).
    assign i_din        = byp_hit ? byp_byte :
                          res     ? (way_q ? q[1] : q[0]) : accel_din;
    assign i_base       = i_din;
    assign i_tgt        = 8'd0;
    assign i_tgt_sel    = 1'b0;

    // ---- the fill engine ------------------------------------------------------------
    localparam [2:0] F_IDLE = 3'd0, F_DR = 3'd1, F_W1 = 3'd2, F_W2 = 3'd3, F_TLB = 3'd4;
    logic [2:0]      fst;
    logic [23:0]     f_addr;            // the row being filled: bank, page, row
    logic [15:0]     f_ppn;
    logic            f_wsel;            // the way it lands in
    logic [3:0]      f_reg;
    logic            f_fold;
    wire f_live = (fst != F_IDLE);
    assign fill_busy = (fst == F_DR) || (fst == F_W1) || (fst == F_W2);
    // Claimed while its row is on the way (F_DR..F_W2) - NOT in F_TLB: there
    // the fetch must reach the dispatcher, whose op places the page that the
    // engine is waiting for (the lines' rule; a claim in F_TLB deadlocks).
    wire f_same_row = fill_busy && (f_addr[23:4] == fa[23:4]);
    assign claim = fetch && (res || byp_hit || f_same_row);

    // The wants: the fetch on offer that nothing holds; the next row once the
    // stream is in the last quarter of this one.
    wire want_fetch = fetch && !res && !byp_hit;
    logic        nx_v;
    logic [23:0] nx_addr;
    // The prefetch's registered lookup is a clock behind nx_addr: the want
    // waits that clock (nx_ok_q), else a row already held was fetched again
    // (1,591 prefetches for 238 in the short boot).
    logic nx_ok_q;
    always_ff @(posedge clk) nx_ok_q <= nx_v && !rst;
    wire want_any = want_fetch || (nx_v && nx_ok_q);
    wire [23:0] want = want_fetch ? fa : nx_addr;
    assign la_vpage = want[23:8];
    assign lc_vpage = want[23:8];
    wire unused_lc = &{1'b0, lc_hit, lc_ppn, lc_set, lc_way};
    assign p_addr   = {want[23:4], 4'h0};
    // Is the wanted page resident, and in which way?  For the fetch, the
    // lookup registered beside the RAM output says (the fetch IS pcd_q when
    // it is aligned, and only an aligned miss wants); for the prefetch, its
    // own lookup, registered every clock from nx_addr.  Neither puts a tag
    // mux between the PC and the engine (gs_pt53 missed by 2.33 ns there).
    wire [3:0] wset = want[11:8];
    logic        nx_page_q, nx_pway_q, nx_rowok_q;
    logic [WAYS-1:0] nx_page_d;
    always_comb
        for (int w = 0; w < WAYS; w = w + 1)
            nx_page_d[w] = t_v[w][nx_addr[11:8]] && (t_bank[w][nx_addr[11:8]] == nx_addr[23:16]) &&
                           (t_hi[w][nx_addr[11:8]] == nx_addr[15:12]);
    always_ff @(posedge clk) begin
        nx_page_q  <= (nx_page_d != '0);
        nx_pway_q  <= nx_page_d[1];
        nx_rowok_q <= (nx_page_d != '0) && t_rv[nx_page_d[1]][nx_addr[11:8]][nx_addr[7:4]];
    end
    wire       w_present = want_fetch ? page_q : nx_page_q;
    wire       w_pway    = want_fetch ? pway_q : nx_pway_q;
    wire       w_way     = w_present ? w_pway : ~lru[wset];
    wire       w_rowok   = want_fetch ? (hit_q && aligned) : nx_rowok_q;

    wire f_snp = (snp      && (f_ppn == cl_ppn) && (f_addr[7:4] == cl_off[7:4])) ||
                 (ws_valid && (f_ppn == ws_ppn) && (f_addr[7:4] == ws_off8[7:4]));
    wire f_restart = f_live && (map_changed || inval || !serve || f_snp);
    wire w1 = (fst == F_W1) && !f_restart;
    wire w2 = (fst == F_W2) && !f_restart;
    assign wr_en   = {f_wsel & (w1 | w2), ~f_wsel & (w1 | w2)};
    assign wr_addr = {f_addr[11:4], w2};
    assign wr_data = w2 ? dr_row[127:64] : dr_erow[63:0];

    // ---- the books -------------------------------------------------------------------
    logic [31:0] cnt_slow_i, cnt_fills, cnt_allocs, cnt_kills, cnt_unserv, cnt_tlb_waits,
                 cnt_prefetch, cnt_byp, cnt_res_bubble, cnt_notres, cnt_misalign;

    // ---- the engine, the tags, the events ---------------------------------------------
    always_ff @(posedge clk) begin
        tick_q    <= retire;
        tev_valid <= retire;
        if (retire) begin
            tev_addr <= pc_addr;
            tev_data <= i_din;
            tev_sync <= cpu_sync;
            tev_bank <= pc_bank;
        end
        fi_v  <= 1'b0;

        if (rst) begin
            for (int w = 0; w < WAYS; w = w + 1)
                for (int s = 0; s < SETS; s = s + 1) begin
                    t_v[w][s] <= 1'b0; t_rv[w][s] <= 16'd0;
                    t_bank[w][s] <= 8'd0; t_hi[w][s] <= 4'd0; t_ppn[w][s] <= 16'd0;
                end
            for (int s = 0; s < SETS; s = s + 1) lru[s] <= 1'b0;
            fst <= F_IDLE; f_addr <= 24'd0; f_ppn <= 16'd0; f_wsel <= 1'b0; f_reg <= 4'd0; f_fold <= 1'b0;
            dr_req <= 1'b0; dr_set <= '0; dr_way <= '0; dr_line <= 4'd0;
            byp_v <= 1'b0; byp_addr <= 24'd0; byp_ppn <= 16'd0; byp_byte <= 8'd0;
            nx_v <= 1'b0; nx_addr <= 24'd0;
            tev_bank <= 8'd0;
            cnt_slow_i <= 32'd0; cnt_fills <= 32'd0; cnt_allocs <= 32'd0; cnt_kills <= 32'd0;
            cnt_unserv <= 32'd0; cnt_tlb_waits <= 32'd0; cnt_prefetch <= 32'd0; cnt_byp <= 32'd0;
            cnt_res_bubble <= 32'd0; cnt_notres <= 32'd0; cnt_misalign <= 32'd0;
        end else begin
            // The books.
            if (accel_cyc_en && cyc_is_i && cpu_rw) cnt_slow_i <= cnt_slow_i + 32'd1;
            if (retire && byp_hit && !res) cnt_byp <= cnt_byp + 32'd1;
            if (fetch && turbo_ok && !retire) begin
                if (res || byp_hit)        cnt_res_bubble <= cnt_res_bubble + 32'd1;
                else if (hit_q && !aligned) cnt_misalign <= cnt_misalign + 32'd1;
                else                        cnt_notres <= cnt_notres + 32'd1;
            end

            // The LRU: the way that served.
            if (retire && res) lru[set_q] <= way_q;

            // The bypass: served, or its address left behind, or its row written.
            if (retire || (byp_v && cyc_is_i && cpu_rw && !byp_hit && turbo_en)) byp_v <= 1'b0;
            if (byp_v && ((snp && byp_ppn == cl_ppn && cl_off[7:4] == byp_addr[7:4]) ||
                          (ws_valid && byp_ppn == ws_ppn && ws_off8[7:4] == byp_addr[7:4]))) byp_v <= 1'b0;

            // The next-row want: raised as the stream enters the last quarter
            // of a row whose successor is not held; dropped once it is, or
            // when the stream moves elsewhere.
            if (retire && res && pc_addr[3:2] == 2'b11) begin
                nx_v    <= 1'b1;
                nx_addr <= {pc_bank, pc_addr[15:4] + 12'd1, 4'h0};
            end else if (nx_v && !want_fetch && (fst == F_IDLE) && w_rowok) begin
                nx_v <= 1'b0;                      // already there
            end

            // The snoops: an image write clears EVERY row of the page it hit,
            // in every way that holds it - a word, not a bit: a bit costs
            // three writers of logic under each of 512 flops (gs_pt53's
            // 3,300 LUTs), and code pages are written rarely (8.9 k kills in
            // the Nox row's 4 M instructions).
            for (int w = 0; w < WAYS; w = w + 1)
                for (int s = 0; s < SETS; s = s + 1)
                    if (t_v[w][s] && ((snp && t_ppn[w][s] == cl_ppn) || (ws_valid && t_ppn[w][s] == ws_ppn))) begin
                        t_rv[w][s] <= 16'd0;
                        cnt_kills <= cnt_kills + 32'd1;
                    end

            // The engine.
            if (f_restart) begin
                if (fst == F_DR) dr_req <= 1'b0;
                fst <= F_IDLE;
            end else case (fst)
                F_IDLE: if (want_any && !map_settling) begin
                    if (excl(want)) begin
                        cnt_unserv <= cnt_unserv + 32'd1;   // the fetch rides the sequencer
                        if (!want_fetch) nx_v <= 1'b0;
                    end else if (w_rowok) begin
                        if (!want_fetch) nx_v <= 1'b0;      // a prefetch of a row already held
                    end else if (la_hit) begin
                        f_addr <= want;
                        f_ppn  <= la_ppn;
                        f_wsel <= w_way;
                        if (!w_present) begin
                            // A page miss: the set's other way takes the page, empty.
                            t_v[w_way][wset]    <= 1'b1;
                            t_bank[w_way][wset] <= want[23:16];
                            t_hi[w_way][wset]   <= want[15:12];
                            t_ppn[w_way][wset]  <= la_ppn;
                            t_rv[w_way][wset]   <= 16'd0;
                            cnt_allocs <= cnt_allocs + 32'd1;
                        end
                        dr_req  <= 1'b1;
                        dr_set  <= la_set;
                        dr_way  <= la_way;
                        dr_line <= want[7:4];
                        if (!want_fetch) cnt_prefetch <= cnt_prefetch + 32'd1;
                        fst <= F_DR;
                    end else if (!p_fs) begin
                        cnt_unserv <= cnt_unserv + 32'd1;
                        if (!want_fetch) nx_v <= 1'b0;
                    end else begin
                        f_addr <= want;
                        f_ppn  <= p_ppn;
                        f_reg  <= p_reg;
                        f_fold <= p_fold;
                        cnt_tlb_waits <= cnt_tlb_waits + 32'd1;
                        fst <= F_TLB;
                    end
                end
                F_TLB: begin
                    if (op_place_v && (op_place_ppn == f_ppn) && !fi_busy) begin
                        fi_v     <= 1'b1;
                        fi_vpage <= f_addr[23:8];
                        fi_ppn   <= f_ppn;
                        fi_set   <= op_place_set;
                        fi_way   <= op_place_way;
                        fi_reg   <= f_reg;
                        fi_fold  <= f_fold;
                        fst <= F_IDLE;
                    end else if (!(want_any && want[23:8] == f_addr[23:8])) begin
                        fst <= F_IDLE;
                    end
                end
                F_DR: if (dr_ack) begin dr_req <= 1'b0; fst <= F_W1; end
                F_W1: begin
                    // The row is on the cache RAM's output (page_cam dr_erow):
                    // the low half lands now, the high half next clock from
                    // the registered copy; the stalled fetch takes its byte
                    // off the row this clock.
                    if (want_fetch && (fa[23:4] == f_addr[23:4])) begin
                        byp_v    <= 1'b1;
                        byp_addr <= fa;
                        byp_ppn  <= f_ppn;
                        byp_byte <= dr_erow[8 * fa[3:0] +: 8];
                    end
                    fst <= F_W2;
                end
                F_W2: begin
`ifndef SYNTHESIS
                    if (!dr_done) $error("l1i_store: no dr_done at the second half");
`endif
                    t_rv[f_wsel][f_addr[11:8]][f_addr[7:4]] <= 1'b1;
                    cnt_fills <= cnt_fills + 32'd1;
                    if (nx_v && nx_addr[23:4] == f_addr[23:4]) nx_v <= 1'b0;
                    fst <= F_IDLE;
                end
                default: fst <= F_IDLE;
            endcase

            if (map_changed || inval || !serve) begin
                for (int w = 0; w < WAYS; w = w + 1)
                    for (int s = 0; s < SETS; s = s + 1) t_v[w][s] <= 1'b0;
                byp_v <= 1'b0;
                nx_v  <= 1'b0;
            end
        end
    end

    // ---- the debug words ----------------------------------------------------------------
    always_comb begin
        case (dbg_sel)
            4'd0:  dbg_val = cnt_slow_i;
            4'd1:  dbg_val = cnt_fills;
            4'd2:  dbg_val = cnt_allocs;
            4'd3:  dbg_val = cnt_kills;
            4'd4:  dbg_val = cnt_unserv;
            4'd5:  dbg_val = cnt_tlb_waits;
            4'd6:  dbg_val = cnt_prefetch;
            4'd7:  dbg_val = cnt_byp;
            4'd10: dbg_val = cnt_res_bubble;
            4'd12: dbg_val = cnt_notres;
            4'd13: dbg_val = cnt_misalign;
            4'd14: dbg_val = {fst, hit_q, way_q, byp_v, nx_v, turbo_en, serve, inval, intc8rom_q, pair_q, dr_req, 19'd0};
            default: dbg_val = 32'd0;
        endcase
    end
endmodule
