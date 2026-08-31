`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// d_front - the level-1 front end's D side: the zp/stack store, the floating
// page registers and the data cache, ahead of the sequencer.
//
// The l1_front's sibling (docs/DCACHE_PLAN.md).  A data op whose page a
// floating register knows and whose line the D$ holds retires in TWO clocks:
// clock one the op's address registers (a data address can hold live din
// through the AGU, so nothing serves in its own clock - law 1), clock two a
// registered verdict serves.  Main zero page and stack are not cached but
// OWNED: a dedicated 512-byte BRAM is the authoritative home of physical
// main pages 0 and 1 - writes there update the BRAM and go no further, and
// DDR3's copy of those pages is permanently stale (the user's design).
//
// THE CLAIM mirrors l1_claim: a data op this module might yet serve raises
// d_claim for its first three clocks - clock 0 registers the address and
// steers a guessed row, clock 1 verdicts (and re-steers on a wrong guess,
// or reloads a floating register from the MMU's t3 view on a cold page),
// clock 2 verdicts the re-steer.  Then the claim falls and the op takes the
// sequencer's path, at most two clocks later than before.  The claim drops
// at once for a page the registers know is unservable, so it can only delay
// the dispatcher, boundedly.
//
// THE GUESS: the D$'s row register needs its index a clock before the
// matching page register is known, so the steer guesses - the measured
// pattern (accel_tb, fw 4c3d78e) is that data ops ALTERNATE between two
// pages (a copy loop's src and dst), so the guess is the floating entry NOT
// used last.  A wrong guess with the other entry matching costs one
// registered re-steer clock, the icache's mispredict shape.
//
// WRITES retire against two walls, both registered terms of the verdict:
// the event merge must have room for the write's word (law 5 - the host
// mirror is built from the stream; a main-zp/stack write leaves no other
// trace), and the write-back line set must accept the byte (wb_lines.sv).
// A zp/stack write to a VALID line updates the BRAM alone; every other
// served write merges into the write-back lines (write-allocate, no fetch),
// and updates the D$ line only if it is already present.
//
// AUTHORITY INVARIANT (the zp/stack store): valid line => the BRAM is the
// truth and DDR3 may be stale; invalid line => DDR3 is fresh.  Kept by:
// reads install by observation (DDR3 was fresh), writes to valid lines stay
// in the BRAM, writes to cold lines go through the write-back lines (DDR3
// stays fresh, the line stays cold), a bus-path write to a valid line
// UPDATES it in place (cl_* carries the byte), and a producer that just
// freshened DDR3 wholesale - the DMA drain, the host's invalidate - marks
// lines COLD.  The icache never installs these pages (l1_front gates it);
// an I-fetch of them is served here instead, two clocks, from the BRAM.
//
// A SERVED WRITE'S SNOOP: a write served here never reaches the classified
// stream, so this module broadcasts it (dsn_*) to the icache's snoop port
// and the floating-bus copy, holding it until no classified write competes.
// The next write may not serve while the broadcast waits.
//////////////////////////////////////////////////////////////////////////////////
module d_front (
    input  wire        clk,
    input  wire        rst,           // rst_core

    // The core.
    input  wire        cyc_is_i,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    input  wire [7:0]  cpu_dout,
    input  wire        cpu_sync,
    input  wire        g_cyc_en,      // the FINAL cyc_en, all sources merged
    // This module's serve: OR d_hit into the core's cyc_en, mux d_byte in.
    output wire        d_hit,
    output wire [7:0]  d_byte,

    // The sequencer.
    input  wire        d_ok,          // permission to serve a data read
    input  wire        d_ok_w,        // ...and a write (mode 2 only)
    // Could this module EVER serve the op class?  Registered levels from
    // the top (mode on, mastering, serving, not the reset sequence; run_w
    // additionally mode 2).  A claim never raises without them - the reset
    // sequence's stack reads and mode 1's writes are the dispatcher's, and
    // a claim would only split their consecutive bus cycles.
    input  wire        run_rd,
    input  wire        run_w,
    output wire        d_claim,
    // The commit and its event, COMBINATIONAL with the serve: the governor's
    // payment must land the clock the credit was checked (accel_seq's gov
    // rule), and the event's room was a verdict term, so accel_seq emits it
    // unconditionally the next clock.
    output wire        d_commit,
    output wire [15:0] dev_addr,
    output wire        dev_rw,
    output wire [7:0]  dev_data,
    output wire        dev_sync,

    // The chicken bit (ACCEL_CTRL[27]): claims withheld, nothing serves.
    input  wire        d_dis,

    // The MMU: the t3 page query (both views) and the flush.
    output wire [7:0]  t3_page,
    input  wire        t3_r_ok,
    input  wire [16:0] t3_r_ppage,
    input  wire        t3_w_ok,
    input  wire [16:0] t3_w_ppage,
    input  wire        map_changed,

    // The event merge's headroom: a serve may not retire without room for
    // its word (registered, one clock stale; the merge's margin covers it).
    input  wire        fev_room,

    // The cache behind: an observed completion's line.
    input  wire        accel_cyc_en,
    input  wire [127:0] sub_line,
    input  wire         sub_line_ok,

    // The classified stream: snoops in (a bus-path write, with its byte),
    // and the drain's lines behind them.
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [23:0] cl_pa,
    input  wire [7:0]  cl_wdata,      // u_wdata: stable through the op
    input  wire        snoop2_en,
    input  wire [23:0] snoop2_pa,

    // A served write's broadcast (see the header).
    output logic        dsn_en,
    output logic [23:0] dsn_pa,
    output logic [7:0]  dsn_data,

    // The write-back lines (rtl/wb_lines.sv).
    output logic        aw_en,
    output logic [23:0] aw_pa,
    output logic [7:0]  aw_data,
    input  wire         aw_ok,        // a byte would be accepted this clock

    // The flash, and the level that decides what it means for the store:
    // an image RELOAD always happens under a hold (the boot menu's), and
    // only then may the store's lines flash - the new image is the truth.
    // A BARE invalidate under a running machine clears the L2 alone; the
    // store's bytes exist nowhere else and must survive it.
    input  wire        mem_invalidating,
    input  wire        hold_lvl,

    // The store's valid lines, for mem_cache's monitor: a bus read of a
    // valid line compares two legitimately stale copies (the machine's and
    // the L2's) and must not count as a mismatch.
    output wire [31:0]  zs_vld_o,

    // Counters.
    input  wire         cnt_clr,
    output logic [31:0] d_ops
);

    // ---- the op, registered --------------------------------------------------
    // Sampled every clock; `tries` says when they describe the op that is up
    // (from the clock after its first stationary clock - dq_*'s contract).
    logic [15:0] da_q;
    logic        drw_q, dsync_q, dis_i_q;
    logic [7:0]  dd_q;
    always_ff @(posedge clk) begin
        da_q    <= cpu_addr;
        drw_q   <= cpu_rw;
        dd_q    <= cpu_dout;
        dsync_q <= cpu_sync;
        dis_i_q <= cyc_is_i;
    end

    logic dis_q;
    logic hold_q;
    always_ff @(posedge clk) begin
        dis_q  <= d_dis;
        hold_q <= hold_lvl;
    end

    logic run_rd_q, run_w_q;
    always_ff @(posedge clk) begin
        run_rd_q <= run_rd;
        run_w_q  <= run_w;
    end

    // ---- the try window ------------------------------------------------------
    // The window counts only clocks a serve was POSSIBLE (d_ok): while the
    // governor holds the credit, or an override is pending, the op is
    // parked - the dispatcher is blocked by the same terms - and the window
    // must still be alive when the hold lifts, or a read of an
    // AUTHORITATIVE zp/stack line would fall to the sequencer's stale path.
    // The one place d_ok stays low with the dispatcher free is the reset
    // sequence, and run_rd withholds the claim entirely there.
    logic [1:0] tries;
    always_ff @(posedge clk) begin
        if (rst || g_cyc_en) tries <= 2'd0;
        else if (tries != 2'd3 && d_ok) tries <= tries + 2'd1;
    end

    // ---- the floating page registers ----------------------------------------
    logic [7:0]  fl_page [0:1];
    logic        fl_v    [0:1];
    logic        fl_rok  [0:1], fl_wok [0:1];
    logic [16:0] fl_rpp  [0:1], fl_wpp [0:1];
    logic        fl_mru;

    wire m0 = fl_v[0] && (fl_page[0] == da_q[15:8]);
    wire m1 = fl_v[1] && (fl_page[1] == da_q[15:8]);
    wire        fm_any = m0 || m1;
    wire        fm_sel = m1;
    wire        fm_rok = fm_sel ? fl_rok[1] : fl_rok[0];
    wire        fm_wok = fm_sel ? fl_wok[1] : fl_wok[0];
    wire [16:0] fm_rpp = fm_sel ? fl_rpp[1] : fl_rpp[0];
    wire [16:0] fm_wpp = fm_sel ? fl_wpp[1] : fl_wpp[0];
    wire [16:0] fm_pp  = drw_q ? fm_rpp : fm_wpp;
    wire        fm_ok  = drw_q ? fm_rok : fm_wok;

    // ---- main zp/stack: does the map still point at main? --------------------
    logic maps_main, mm_pend, mm_asking;
    assign t3_page = mm_asking ? 8'h00 : da_q[15:8];

    // ---- the zp/stack store --------------------------------------------------
    (* ram_style = "block" *) logic [127:0] zs_mem [0:31];
    logic [31:0]  zvld;
    logic [127:0] zrow;
    logic [4:0]   zrow_idx;
    logic         zrow_ok;

    assign zs_vld_o = zvld;

    wire zs_region  = (da_q[15:9] == 7'd0) && maps_main && !mm_pend;
    wire zs_line_ok = zvld[da_q[8:4]] && zrow_ok && (zrow_idx == da_q[8:4]);

    // A classified (bus-path) write landing in a VALID main-zp/stack line:
    // update in place, stay valid - the byte rides beside the classification.
    wire cl_snoop  = cl_valid && !cl_rw && cl_wr_image;
    wire zs_cl_upd = cl_snoop && (cl_pa[23:9] == 15'd0) && zvld[cl_pa[8:4]];
    // The drain behind: the SAME priority every consumer in the design uses.
    wire sn2_here  = snoop2_en && !cl_snoop && !dsn_en;

    // ---- the D$ --------------------------------------------------------------
    logic        dc_flash;
    logic [16:0] steer_pp_q;           // the ppage the row being loaded assumed
    logic        resteered, reloaded;

    // The steer, combinational into the BRAM's address register, exactly the
    // icache's arrangement.  Clock 0 (a fresh op): the guess - the floating
    // entry NOT used last, in the live op's view (cpu_rw is a core register,
    // not the AGU; the low address bits are wires).  Clock 1 with the page
    // matched elsewhere: the matched entry, all registered.  Clock 1 with a
    // cold page: t3's answer off the registered page - the reload clock, the
    // one place the classifier's cone feeds an address pin, with a whole
    // clock to make it.
    wire        g_sel = !fl_mru;
    wire [16:0] g_pp  = cpu_rw ? (g_sel ? fl_rpp[1] : fl_rpp[0])
                                : (g_sel ? fl_wpp[1] : fl_wpp[0]);
    wire [16:0] t3_pp = drw_q ? t3_r_ppage : t3_w_ppage;
    wire        fresh = g_cyc_en || (tries == 2'd0);
    wire [16:0] steer_pp  = fresh  ? g_pp
                          : fm_any ? fm_pp
                          : (!mm_asking && !dis_i_q) ? t3_pp
                          : steer_pp_q;
    wire [7:0]  steer_idx = {steer_pp[3:0], fresh ? cpu_addr[7:4] : da_q[7:4]};

    wire        dc_look_hit, dc_look_ok;
    wire  [7:0] dc_look_byte;
    logic       dc_inst_en;
    logic [24:0] dc_inst_pa;
    logic       dc_wr_en;
    logic [7:0] dc_wr_idx;
    logic [3:0] dc_wr_byte;
    logic [7:0] dc_wr_data;

    wire dc_snoop_en = cl_snoop || sn2_here;
    wire [23:0] dc_snoop_pa = cl_snoop ? cl_pa : snoop2_pa;

    dcache_l1 u_dc (
        .clk       (clk),
        .rst       (rst),
        .flash     (dc_flash),
        .look_pa   ({fm_pp, da_q[7:0]}),
        .look_hit  (dc_look_hit),
        .look_ok   (dc_look_ok),
        .look_byte (dc_look_byte),
        .steer_idx (steer_idx),
        .steer_tag (steer_pp[16:4]),
        .inst_en   (dc_inst_en),
        .inst_pa   (dc_inst_pa),
        .inst_line (sub_line),
        .wr_en     (dc_wr_en),
        .wr_idx    (dc_wr_idx),
        .wr_byte   (dc_wr_byte),
        .wr_data   (dc_wr_data),
        .snoop_en  (dc_snoop_en),
        .snoop_pa  (dc_snoop_pa)
    );

    // ---- verdicts ------------------------------------------------------------
    wire steered_right = (steer_pp_q == fm_pp);
    // The verdict window.  !dis_q here as well as in the claim: with the
    // claim withheld the dispatcher runs free, and a verdict firing beside
    // a dispatch would serve one op twice.
    wire vq = !dis_q &&
              ((tries == 2'd1) || ((tries == 2'd2) && (resteered || reloaded)));

    wire dsn_free = !dsn_en;

    // zp/stack: any read (I-fetches included - fetches read) from a valid
    // line; a write to a valid line into the BRAM alone; a write to a cold
    // line through the wb lines (DDR3 stays fresh, the line stays cold).
    //
    // READS DO NOT WAIT FOR EVENT ROOM.  A read's event is sheddable - the
    // turbo precedent: the host mirror is built from writes, and the sparse
    // filter discards RAM-read events anyway - and it MUST be: a valid
    // zp/stack line is AHEAD of the L2, so a read of it that fell out of
    // this window would be served stale from the sequencer's path.  With
    // room out of the verdict, a valid line's read always serves in the
    // window, and the d_ok lapses that remain are the ones where the
    // dispatcher parks the op instead of dispatching it.
    wire zs_rd_hit  = vq && zs_region &&  drw_q && zs_line_ok && d_ok;
    wire zs_wr_hit  = vq && zs_region && !drw_q && zs_line_ok &&
                      d_ok_w && fev_room && dsn_free;
    wire zs_wr_cold = vq && zs_region && !drw_q && !zvld[da_q[8:4]] &&
                      d_ok_w && fev_room && dsn_free && aw_ok;

    // The D$: data ops only, never the zp/stack region, never a ROM ppage
    // (no ROM fill path in this first cut - ROM data reads ride the
    // sequencer at the old cost).
    wire dc_zone   = !dis_i_q && !zs_region && fm_any && !fm_pp[16];
    wire dc_rd_hit = vq && dc_zone &&  drw_q && fm_rok && steered_right &&
                     dc_look_hit && d_ok;
    // A write serves only through a PROVEN row (steered_right AND look_ok):
    // the row then answers whether the line is present - updated in place -
    // or PROVEN absent - the wb line alone holds the byte.  Serving past an
    // unproven row could leave a present line stale behind the wb byte.
    // (A write that lapses to the sequencer instead is safe: its classified
    // pass snoop-invalidates any line here.)
    wire dc_wr_hit = vq && dc_zone && !drw_q && fm_wok && steered_right &&
                     dc_look_ok && d_ok_w && fev_room && dsn_free && aw_ok;

    wire serve_rd = zs_rd_hit || dc_rd_hit;
    wire serve_wr = zs_wr_hit || zs_wr_cold || dc_wr_hit;
    assign d_hit  = serve_rd || serve_wr;
    assign d_byte = zs_rd_hit ? zrow[8 * da_q[3:0] +: 8] : dc_look_byte;

    assign d_commit = d_hit;
    assign dev_addr = da_q;
    assign dev_rw   = drw_q;
    assign dev_data = serve_rd ? d_byte : dd_q;
    assign dev_sync = dsync_q;

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (zs_rd_hit && dc_rd_hit)
            $fatal(1, "d_front: zs and D$ both claim one read");
        if (d_hit && accel_cyc_en)
            $fatal(1, "d_front: serve and sequencer cyc_en on one clock");
        if ((zs_wr_hit || (accel_cyc_en && sub_line_ok && drw_q && zs_region))
            && zs_cl_upd)
            $fatal(1, "d_front: zs write/install and cl update on one clock");
    end
`endif

    // ---- the claim -----------------------------------------------------------
    // A data op, or an I-fetch into the zp/stack region (the icache never
    // holds those pages - this module serves them).  cyc_is_i and the PC's
    // high bits are core registers, the same cone l1_claim already lives in.
    // $Cxxx never claims: $C0xx is BUS class in every configuration, and the
    // $C1-$CF pages are at best ROM, which this first cut has no fill path
    // for - claiming them would burn the window and evict a live floating
    // entry for a keyboard-polling loop's benefit of nothing.
    //
    // EVERY TERM IS REGISTERED - unlike l1_claim's cyc_is_i, which is
    // register-only in the core, a data address descends from din through
    // the AGU, and a live-address claim would be din in decide_go's (and so
    // the driver's) cone AND a combinational loop through cpu_din (law 2).
    // Registered is also sufficient: the dispatcher cannot fire before
    // `settled`, which is exactly one clock behind, the same clock da_q is.
    logic unserv;
    wire claim_kind = (!dis_i_q && (da_q[15:12] != 4'hC)) ||
                      (dis_i_q && (da_q[15:9] == 7'd0));
    wire claim_run  = drw_q ? run_rd_q : run_w_q;
    assign d_claim = !dis_q && claim_run && claim_kind && (tries != 2'd3) &&
                     !unserv;

    // ---- the state -----------------------------------------------------------
    integer k;
    always_ff @(posedge clk) begin
        dc_inst_en <= 1'b0;
        dc_wr_en   <= 1'b0;
        aw_en      <= 1'b0;
        mm_asking  <= 1'b0;
        dc_flash   <= mem_invalidating;

        // The row the verdict clock will look at: steered from the wire.
        steer_pp_q <= steer_pp;
        if (fresh) begin
            resteered <= 1'b0;
            reloaded  <= 1'b0;
        end else if (tries == 2'd1) begin
            if (fm_any && !steered_right) resteered <= 1'b1;
            if (!fm_any && !mm_asking && !dis_i_q) reloaded <= 1'b1;
        end

        // ---- a cold page reloads the LRU floating entry from t3 -------------
        if (!fresh && tries == 2'd1 && !fm_any && !mm_asking && !dis_i_q &&
            (da_q[15:12] != 4'hC)) begin
            fl_page[!fl_mru] <= da_q[15:8];
            fl_v[!fl_mru]    <= 1'b1;
            fl_rok[!fl_mru]  <= t3_r_ok;
            fl_wok[!fl_mru]  <= t3_w_ok;
            fl_rpp[!fl_mru]  <= t3_r_ppage;
            fl_wpp[!fl_mru]  <= t3_w_ppage;
            unserv           <= !(drw_q ? t3_r_ok : t3_w_ok);
        end

        // ---- unserv: the claim's early out ----------------------------------
        // A matched page the view says no to, or a ROM ppage (no fill path
        // here): the claim drops rather than burning the window.
        if (g_cyc_en) unserv <= 1'b0;
        else if (vq && !dis_i_q && !zs_region && fm_any &&
                 (!fm_ok || fm_pp[16])) unserv <= 1'b1;

        // ---- LRU touch -------------------------------------------------------
        if (d_hit && dc_zone) fl_mru <= fm_sel;

        // ---- the broadcast slot drains when no classified write competes ----
        if (dsn_en && !cl_snoop) dsn_en <= 1'b0;

        // ---- a served op retires ---------------------------------------------
        if (d_hit) d_ops <= d_ops + 32'd1;

        // ---- a served write lands --------------------------------------------
        if (zs_wr_hit)
            zs_mem[da_q[8:4]][8 * da_q[3:0] +: 8] <= dd_q;
        if (zs_wr_cold || dc_wr_hit) begin
            aw_en   <= 1'b1;
            aw_pa   <= zs_wr_cold ? {15'd0, da_q[8:0]}
                                  : {fm_wpp[15:0], da_q[7:0]};
            aw_data <= dd_q;
        end
        if (serve_wr) begin
            dsn_en   <= 1'b1;
            dsn_pa   <= (zs_wr_hit || zs_wr_cold) ? {15'd0, da_q[8:0]}
                                                  : {fm_wpp[15:0], da_q[7:0]};
            dsn_data <= dd_q;
        end
        if (dc_wr_hit && dc_look_hit) begin
            dc_wr_en   <= 1'b1;
            dc_wr_idx  <= {fm_wpp[3:0], da_q[7:4]};
            dc_wr_byte <= da_q[3:0];
            dc_wr_data <= dd_q;
        end

        // ---- installs by observation -----------------------------------------
        // The op this module released completed on the sequencer's path; the
        // line flies past.  Gated on the entry still standing - a map change
        // between look and completion killed fl_v, and mm_pend blanks
        // zs_region - like the icache's install gate.
        // ...and NEVER over a valid zp/stack line: valid means AHEAD of the
        // L2 (the authority invariant), and the passing sub_line is the
        // L2's stale view of it.  Only a cold line - where DDR3 is fresh by
        // the same invariant - may install.
        if (accel_cyc_en && sub_line_ok && drw_q) begin
            if (zs_region && !zvld[da_q[8:4]]) begin
                zs_mem[da_q[8:4]] <= sub_line;
                zvld[da_q[8:4]]   <= 1'b1;
            end else if (!zs_region && !dis_i_q && fm_any && fm_rok && !fm_rpp[16]) begin
                dc_inst_en <= 1'b1;
                dc_inst_pa <= {fm_rpp, da_q[7:0]};
            end
        end

        // ---- the zp/stack row register ---------------------------------------
        zrow     <= zs_mem[cpu_addr[8:4]];
        zrow_idx <= cpu_addr[8:4];
        // A write into the steered row this edge leaves the register a clock
        // stale: one miss clock, the caches' row_ok argument.
        zrow_ok  <= !(zs_wr_hit && da_q[8:4] == cpu_addr[8:4]) &&
                    !(accel_cyc_en && sub_line_ok && drw_q && zs_region &&
                      da_q[8:4] == cpu_addr[8:4]) &&
                    !(zs_cl_upd && cl_pa[8:4] == cpu_addr[8:4]);

        // ---- snoops into the store -------------------------------------------
        if (zs_cl_upd)
            zs_mem[cl_pa[8:4]][8 * cl_pa[3:0] +: 8] <= cl_wdata;
        if (sn2_here && (snoop2_pa[23:9] == 15'd0))
            zvld[snoop2_pa[8:4]] <= 1'b0;

        if (mem_invalidating && hold_q) zvld <= 32'd0;

        // ---- the map ---------------------------------------------------------
        if (map_changed) begin
            fl_v[0] <= 1'b0;
            fl_v[1] <= 1'b0;
            mm_pend <= 1'b1;
        end else if (mm_pend && !mm_asking) begin
            mm_asking <= 1'b1;
        end else if (mm_asking) begin
            // t3_page was 0 this clock: both views must land in main page 0.
            maps_main <= t3_r_ok && t3_w_ok &&
                         (t3_r_ppage == 17'd0) && (t3_w_ppage == 17'd0);
            mm_pend   <= 1'b0;
        end

        if (rst) begin
            fl_v[0] <= 1'b0; fl_v[1] <= 1'b0; fl_mru <= 1'b0;
            for (k = 0; k < 2; k = k + 1) begin
                fl_page[k] <= 8'd0; fl_rok[k] <= 1'b0; fl_wok[k] <= 1'b0;
                fl_rpp[k] <= 17'd0; fl_wpp[k] <= 17'd0;
            end
            maps_main <= 1'b0; mm_pend <= 1'b1; mm_asking <= 1'b0;
            unserv <= 1'b0; resteered <= 1'b0; reloaded <= 1'b0;
            d_ops <= 32'd0;
            dsn_en <= 1'b0; dsn_pa <= 24'd0; dsn_data <= 8'd0;
            aw_en <= 1'b0; aw_pa <= 24'd0; aw_data <= 8'd0;
            dc_inst_en <= 1'b0; dc_wr_en <= 1'b0;
            steer_pp_q <= 17'd0;
            zvld <= 32'd0; zrow_ok <= 1'b0;
        end
        if (cnt_clr) d_ops <= 32'd0;
    end

endmodule
