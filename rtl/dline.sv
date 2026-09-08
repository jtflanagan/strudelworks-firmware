`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// dline - the data front.  Rung 1: the zp/stack shadow.  Rung 2: the 4-line
// CAM and the last-byte serve.  Rung 3: writes, splice + post.  docs/DLINE.md
// is the authority.
//
// Between rtl/iline.sv and the core's d_din port, exactly as iline sits on
// i_din: registered candidates in, a one-clock retire out, the sequencer
// seeing only the books.  Three servers, in priority order:
//
//   * THE SHADOW (rung 1): physical MAIN pages 0 and 1 in a 512-byte LUTRAM
//     (32 lines x 16 B, one valid FF per line, claimed lazily).  It never
//     invalidates for map reasons: its identity is physical, ALTZP only
//     DIVERTS traffic, and the content dies only with the image (inval).
//   * THE CACHE (rung 5, 2026-09-07; rung 2's 4-line CAM before it): 64
//     sets x 2 ways of 16-byte lines, 2 KB of LUTRAM in the shadow's own
//     shape, indexed by addr[9:4], serving RAM- and LC-class reads outside
//     the shadow's estate.  The serve compares a 6-bit VIRTUAL tag
//     (addr[15:10]) against the indexed way - rung 2's lesson kept: under
//     an unchanged map one virtual line is one physical line, so the whole
//     classify cone stays out of the serve, and the cache flash-clears on
//     map_changed as the CAM did.  A PHYSICAL tag - {aux, bank, folded
//     off[15:10]} - sits beside each line for the snoops, which index by the
//     write's off[9:4] (the fold never touches the low 12 bits, so the two
//     views agree on the set).  One LRU bit per set.  Why this and not more
//     CAM ways: a full capture of the animated Nox map showed 190 distinct
//     lines in play with 67 carrying 93% of the reads - the 4-way CAM missed
//     64% of them, this geometry 0.9% in the model - and 12 FF ways had
//     already missed timing: capacity has to be indexed, and an index is a
//     LUTRAM read, one level deep.  Each way's LUTRAM has ONE write port
//     behind the shadow's mux discipline: a splice's read-modify-write beats
//     an install, which drops and reclaims.
//   * THE LAST BYTE (rung 2): the previous data read's {addr, byte} in one
//     register.  The CMOS core's LAST and FIXUP dummy cycles re-read the
//     previous cycle's address, so they always hit here - one clock, no
//     storage.  Cleared by any classified write, any map change, and reset:
//     it may only ever answer what nothing could have changed.
//
// THE ONE QUERY ROOT.  Every serve- and fill-side fact - class, bank side,
// folded offset - comes from the MMU's d-side query port, whose input is
// the REGISTERED dq_addr (and dq_rw, the candidate's direction).  Nothing
// evaluates on d_pred's late cone (rung 1's second lesson): the candidate
// registers the address and the prediction's validity only, and the whole
// serve cycle belongs to the register-rooted cones.
//
// THE SERVE, in iline's discipline (the laws in docs/DLINE.md):
//   * cpu65c02's d_pred names the next data cycle's address a cycle early,
//     BY CONSTRUCTION (proven over both Klaus suites, sim/cpu_predict).
//   * The retire is a registered compare against registered state: the live
//     cycle's address equals dq_addr, the cycle is data-class read, and
//     turbo_ok grants - then cyc_en fires and the served byte is the byte.
//   * claim (mirroring iline's) holds the dispatcher off any cycle a server
//     holds the answer; the fc_q||claim_q gate fences the registered
//     claim's one-clock lag (rung 1's third lesson).
//   * The books are the sequencer's own: d_commit rides the turbo_commit
//     contract, tick_q pulses the peripherals' timebases, and the event
//     goes out at retire when the merge has room - best effort, as for
//     turbo ifetches: a read changes no host state.
//
// A miss rides the dispatcher unclaimed - it can only waste - and triggers
// the line's claim: one il_row grant, lowest priority behind iline's, the
// whole 16 bytes in one write, into the shadow row or the CAM's round-robin
// victim.  A splice that lands on the claim's own line ABORTS the claim:
// the row was read before the write landed, and installing it would
// resurrect the stale byte.  The old D$ stab's two hardware bugs were
// exactly this class of race; the abort-and-reclaim is the cheap shape
// that cannot lose.
//
// WRITES (rung 3): SPLICE + POST.  A mode-2 data write retires in ONE
// clock, exactly as a read does - registered candidate, live-address
// compare, turbo_ok - and then lives on in three places:
//
//   * THE STAMP.  At the retire edge the write's physical identity - the
//     MMU query's {aux, bank, folded off} for the REGISTERED candidate, so
//     the map of that instant - and its byte land in one register (spl_*).
//     Nothing about the write is re-derived later.
//   * THE SPLICE, one clock after retire, from that register: the shadow
//     row it lands in is read-modified-written, every CAM entry holding the
//     line takes the byte, an in-flight claim of the line aborts, and the
//     same register is the instruction front's snoop (ws_*): iline kills
//     every held copy of the line on that clock, cancelling a fetch it was
//     about to serve from it - the store INTO THE NEXT OPCODE is the case,
//     and it is one clock away.  Splicing a clock late is safe because the
//     ISA never reads a data address the clock after writing it (a write
//     is an instruction's last cycle, or a push followed by another push
//     or a vector fetch) - and that argument is CHECKED, not trusted: the
//     simulation assertion below fires on a read serve of the splice
//     register's address.  (A live fence - a 16-bit compare in serve_hit -
//     was built first and cost 0.3 ns in the cyc_en cone; the ISA makes it
//     dead logic, so it went.)
//   * THE POST.  The splice register pushes into a small FIFO whose head
//     is offered to the MMU's classified stage (pw_*): the page cache
//     drains it through its ordinary write path - P1 classified, P2
//     decided, P3 in the banks, the aux miss engine included - one entry
//     at a time, on clocks the op pipeline is idle.  `pending` is high
//     from the retire until the last entry is in the banks, and it is the
//     ONE term every ordering hangs on: the dispatcher does not dispatch
//     (read-after-write of a line nothing here holds; every map-changing
//     bus op), the sequencer does not enter or leave a hold (the DMA
//     ordering), and the page cache grants NO line fill (the fill-port
//     P+2 law, generalized to the FIFO's depth: a fill must never read a
//     line with a posted write still in flight).
//
// The laws, as RTL: the retire itself waits for the merge to have room
// (a write's event is NEVER dropped, and it is emitted at retire, so the
// host sees program order); the retire qualifier is VIRTUAL - below
// $C000, which is RAM class and in the image whatever the map says - so
// no classify cone reaches the retire; RamWorks bank 0 only (a divert is a
// bus read, never fast); mode 1 keeps writes on the bus through wr_en.  An
// LC write ($D000+) or a write under a non-zero bank rides the dispatcher
// as before - correct, only slower.
//////////////////////////////////////////////////////////////////////////////////
module dline #(
    parameter integer PW_DEPTH = 4       // posted writes in flight
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,

    // The core: the prediction, and the live cycle it names.
    input  wire [15:0] d_pred,
    input  wire        d_pred_v,
    input  wire        d_pred_rw,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    input  wire [7:0]  cpu_dout,       // a write's byte, register-direct
    input  wire        cyc_is_i,

    // The chain to the core: iline's cyc_en in, ours out; the byte.
    input  wire        il_cyc_en,     // the sequencer's, or an I retire
    input  wire [7:0]  accel_din,     // the sequencer's byte, when we do not serve
    input  wire [7:0]  i_din,         // iline's byte: what an I cycle consumed
    output wire        cyc_en,        // to the core
    output wire [7:0]  d_din,         // to the core

    // The leash and the books, shared with iline through the sequencer.
    input  wire        turbo_en,
    input  wire        turbo_ok,
    input  wire        wr_en,         // turbo_en AND mode 2: writes may retire here
    output wire        d_commit,      // combinational: one op retired on this edge
    output wire        claim,         // hold the dispatcher: this cycle is mine
    output logic       tick_q,        // one pulse per retired op (floppy, Mockingboard)
    output wire        pending,       // posted writes not yet in the banks

    // The event.  Reads best effort like a turbo ifetch's; a write's
    // guaranteed - its retire waited for ev_room_w.
    output logic       dev_valid,
    output logic [15:0] dev_addr,
    output logic [7:0]  dev_data,
    output logic       dev_rw,
    input  wire        ev_room,       // the merge can take a read's word (best effort)
    input  wire        ev_room_w,     // ...and a write's, guaranteed a clock later

    // The map: ALTZP as the MMU holds it (sw_state[3]); registered here.
    input  wire        altzp,

    // The MMU's d-side query port, rooted at dq_addr/dq_rw below: the
    // class, the bank side and the folded offset of the candidate,
    // evaluated THROUGH the serve cycle.  rw_bank is the wanted RamWorks
    // bank; map_changed flash-clears the CAM.
    output logic [15:0] dq_addr,
    output wire        dq_rw,
    input  wire [1:0]  d_cls,
    input  wire        d_aux,
    input  wire [15:0] d_off,
    input  wire [7:0]  rw_bank,
    input  wire        map_changed,
    // The PHYSICAL identity of the same candidate, and the map's own state
    // (docs/MEMORY_REFACTOR.md, Part 2): the page, the REGION it was
    // classified in, the language card's fold bit, the ten packed read-table
    // entries a held line is revalidated against, and the physical bank an
    // auxiliary access reaches.  map_settling is map_changed stretched over
    // the clocks the revalidation needs.
    input  wire [15:0] d_ppn,
    input  wire [3:0]  d_reg,
    input  wire        d_fold,
    input  wire [69:0] rt_rd_flat,
    input  wire [7:0]  rwb_p1,
    input  wire        map_settling,

    // The line-row port, arbitrated in the top behind iline's requests.
    output logic       dl_req,
    output logic       dl_aux,
    output logic [7:0] dl_bank,
    output logic [11:0] dl_line,
    input  wire        dl_ack,        // granted this clock (top gates by priority)
    input  wire        dl_ok,
    input  wire [127:0] dl_row,       // valid two clocks after an ok'd ack

    // The splice: the classified stream's writes that reach the image
    // (bus ops, the dispatcher's, DMA).  A posted write comes back round
    // through this stream when it drains (cl_posted) and is ignored here:
    // it was spliced at its retire.
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire        cl_posted,
    input  wire [15:0] cl_ppn,        // the classified write's PHYSICAL page
    input  wire [15:0] cl_off,        // ...its folded offset; [7:0] is the byte
    input  wire [7:0]  wdata,         // the classified write's byte (cl_wdata)

    // The posted FIFO's head, to the MMU's classified stage: the page the
    // write was stamped with at its retire, the byte in it, and the byte.
    output wire        pw_valid,
    output wire [15:0] pw_ppn,
    output wire [7:0]  pw_off,
    output wire [7:0]  pw_data,
    input  wire        pw_take,       // the MMU registered it this clock

    // The retire+1 snoop, to the instruction front.
    output wire        ws_valid,
    output wire        ws_aux,
    output wire [7:0]  ws_bank,
    output wire [15:0] ws_off,

    // The image.
    input  wire        inval,

    // Counters.
    input  wire        cnt_clr,
    output logic [31:0] cnt_serves,      // every retire, reads and writes
    output logic [31:0] cnt_claims,
    output logic [31:0] cnt_splices,
    output logic [31:0] cnt_cam_serves,
    output logic [31:0] cnt_lb_serves,
    output logic [31:0] cnt_posts,       // writes retired here
    output logic [31:0] cnt_post_waits,  // clocks a servable write waited for room
    // The revalidation's books (docs/MEMORY_REFACTOR.md): lines a map change
    // took out of service, and lines a later map change put back.  A line
    // that drops and revives cost nothing; a line that drops and is evicted
    // before it revives cost a refill.
    output logic [31:0] cnt_reval_drop,
    output logic [31:0] cnt_reval_revive,
    output logic [31:0] cnt_rev_serves   // serves from a line that had revived
);

    localparam [1:0] CLS_RAM = 2'd1;
    localparam [1:0] CLS_LC  = 2'd2;
    localparam [1:0] CLS_ROM = 2'd3;
    localparam integer PW_AW = $clog2(PW_DEPTH);

    // ---- the shadow ---------------------------------------------------------
    // Rows, not bytes: a claim installs il_row whole in one clock, a splice
    // read-modifies-writes one row, and the serve reads a row and muxes the
    // byte inside the pre-read cone.
    //
    // ONE write port, coded explicitly.  Two write statements to one array -
    // the splice's and the install's, mutually exclusive though they were -
    // defeated RAM extraction, and 4 Kb of LUTRAM became 4
    // thousand flip-flops and their mux forest: the build died on LUT
    // over-utilization, 27.8k of 20.8k.  The mux below is what "mutually
    // exclusive" has to look like for the tools to believe it.
    logic [127:0] shrow [0:31];
    logic [31:0]  shv;

    logic        sh_we;
    logic [4:0]  sh_waddr;
    logic [127:0] sh_wdata;
    always_ff @(posedge clk) if (sh_we) shrow[sh_waddr] <= sh_wdata;

    // ---- the qualifiers, registered -----------------------------------------
    // The map bit lives a clock region away in the MMU; one clock of lag on
    // an ALTZP flip is invisible - the flip itself is a bus op ~98 clocks
    // long, and the flip's own cycle is $C0xx, never served here.  The bank
    // register the same: it moves only at a bus op's commit.
    logic zs_main_q, rwb_nz_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            zs_main_q <= 1'b1;
            rwb_nz_q  <= 1'b0;
        end else begin
            zs_main_q <= !altzp;
            rwb_nz_q  <= (rw_bank != 8'd0);
        end
    end

    // ---- the candidate ------------------------------------------------------
    // Registered ONLY at edges the core moves, so it always describes the
    // LIVE cycle: re-registering on every clock would let it drift one cycle
    // ahead while a missed read still rode the dispatcher, and the d_din mux
    // below would hand the core the wrong byte.
    //
    // What registers is deliberately MINIMAL: the address, and the
    // prediction's own validity, split by direction (dq_v a read, dq_wv a
    // write).  d_pred settles late - it inherits din's timing - and every
    // serve-side fact stacked on its cone has missed timing once: the
    // pre-read byte at 16 levels (-0.65), then a verdict register fed by
    // prediction AND range AND valid AND map at 15 (-0.17).  So range,
    // valid bits, map and the MMU's classification are evaluated THROUGH
    // the serve cycle from the REGISTERED address instead: register-rooted,
    // a whole cycle to run, sampled by the edge that ends the cycle.
    logic        dq_v, dq_wv;
    // Fanout copies of the byte index (2026-09-06): dq_addr[3:0] drove 165
    // loads - every row mux of the shadow and the four CAM ways, plus the
    // compares - and its first hop alone was 1.27 ns on the worst path.
    // One copy for the shadow's row mux and one PER CAM WAY - a single CAM
    // copy still carried 128 loads and the same 1.2 ns first hop; dq_addr
    // keeps the compares.  keep_equivalent_registers is set for synthesis,
    // KEEP holds the nets apart.
    (* KEEP = "TRUE" *) logic [3:0] dq_ix_sh;
    (* KEEP = "TRUE" *) logic [3:0] dq_ix_cam [0:3];
    // ...and of the set index, one per way (rung 5): the build that met at
    // +0.008 had Vivado's own copies at 111 loads each on the worst path.
    (* KEEP = "TRUE" *) logic [2:0] dq_sx [0:3];
    // ...and one more per way for the TAG array alone: with rows and tags
    // on one copy (142 loads) the tag read was the worst path's first hop
    // at +0.043; the tag leg is the long one, so it gets the light copy.
    (* KEEP = "TRUE" *) logic [2:0] dq_st [0:3];
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval) begin
            dq_v  <= 1'b0;
            dq_wv <= 1'b0;
        end else if (cyc_en) begin
            dq_v  <= d_pred_v &&  d_pred_rw;
            dq_wv <= d_pred_v && !d_pred_rw;
        end
        if (cyc_en) begin
            dq_addr   <= d_pred;
            dq_ix_sh     <= d_pred[3:0];
            dq_ix_cam[0] <= d_pred[3:0];
            dq_ix_cam[1] <= d_pred[3:0];
            dq_ix_cam[2] <= d_pred[3:0];
            dq_ix_cam[3] <= d_pred[3:0];
            dq_sx[0] <= d_pred[6:4];
            dq_sx[1] <= d_pred[6:4];
            dq_sx[2] <= d_pred[6:4];
            dq_sx[3] <= d_pred[6:4];
            dq_st[0] <= d_pred[6:4];
            dq_st[1] <= d_pred[6:4];
            dq_st[2] <= d_pred[6:4];
            dq_st[3] <= d_pred[6:4];
        end
    end
    assign dq_rw = !dq_wv;
    wire [7:0] dq_byte = shrow[dq_addr[8:4]][dq_ix_sh*8 +: 8];
    wire       sh_hit  = dq_v && (dq_addr[15:9] == 7'd0) &&
                         shv[dq_addr[8:4]] && zs_main_q;

    // ---- the CAM ------------------------------------------------------------
    // Four lines, FF rows, and TWO tags each: a VIRTUAL one the serve
    // compares, and the PHYSICAL identity the snoops compare.  The serve
    // may trust the virtual tag because the CAM flash-clears on every
    // map_changed: under an unchanged map, one virtual line is one physical
    // line, and the class it entered with still holds - so the whole MMU
    // classify cone leaves the serve path.  This is what kept serve_hit
    // out of cyc_en's timing after the physical compare put 16 levels
    // there (the first rung-2 build, WNS -0.689: the classify rooted at
    // the MMU's switch registers ran through serve_hit into the candidate
    // registers' own enables).  A main line's bank is 0 by convention
    // (cl_bank carries rw_bank even for main writes, so the effective bank
    // is normalized on both sides of the snoop).
    // ---- the cache (rung 5) -----------------------------------------------
    // NSET sets x NWAY ways of 16-byte lines, indexed by addr[IW+3:4].  The
    // rows and tags are small arrays (a set index of three bits reads in
    // one LUT level); the valid bits and the round-robin pointers are
    // flip-flops, so a map change clears every line in one clock, as the
    // CAM flash-cleared.  The 64 x 2 LUTRAM shape tried first (2026-09-07)
    // put a 64:1 valid mux and F7/F8 read stages in the serve cone and
    // missed timing twice; the user's call: small and shallow, forever.
    localparam integer NSET = 8;
    localparam integer NWAY = 4;
    localparam integer IW   = 3;                // the set: addr[6:4]
    localparam integer TW   = 16 - 4 - IW;      // the virtual tag: addr[15:7]
    // The physical tag is the line's PAGE and which of the page's two
    // half-page halves the set index does not carry: {ppn[15:0], addr[7]}.
    // The set is addr[6:4] and a page holds 16 lines, so page + addr[7:4] is
    // the whole identity and addr[7] is the only bit the set leaves out.
    localparam integer PTW  = 16 + 1;
    localparam integer WW   = 2;                // a way index
    wire [IW-1:0] sidx = dq_addr[IW+3:4];
    wire [TW-1:0] stag = dq_addr[15:IW+4];
    wire       in_sh_estate = (dq_addr[15:9] == 7'd0) && zs_main_q;
    wire       d_cls_ok     = (d_cls == CLS_RAM) || (d_cls == CLS_LC);
    wire [7:0] want_bank    = d_aux ? rw_bank : 8'd0;
    integer k;
    logic [NSET-1:0] cv   [0:NWAY-1];           // valid, per line (flip-flops)
    // RETAINED, beside valid: the tags and the row mean something and the
    // line can be revived.  A map change no longer empties the cache - it
    // recomputes every line's VALID bit from the line's stored identity
    // against the map's new region table, and a line whose region did not
    // move keeps serving.  A line only ever loses `r` to the image going
    // away or to being replaced.  Snoops compare RETAINED lines, so a line
    // written while invalid serves the new byte when it revives.
    logic [NSET-1:0] cr   [0:NWAY-1];
    logic [NSET-1:0] crev [0:NWAY-1];           // ...has revived at least once
    // A line's IDENTITY, in flip-flops so a map change can read all of them
    // at once: the physical bank, the region it was classified in, and
    // whether the language card's fold applied.  The page's low byte and the
    // line are in the LUTRAM tag beside the row.
    logic [7:0]      cbank [0:NWAY-1][0:NSET-1];
    logic [3:0]      creg  [0:NWAY-1][0:NSET-1];
    logic            cfold [0:NWAY-1][0:NSET-1];
    logic [WW-1:0]   rrp  [0:NSET-1];           // the next victim, per set
    logic [NWAY-1:0] hitv;
    wire  [7:0]      wbyte [0:NWAY-1];
    // Per way: rows, tags, hit, byte, and the one-write-port mux.  The
    // install's inputs (inst_w, t_set, the m_*_t stamp) and the splice's
    // (spc_hit_w, spi, iw_*) are declared ahead of the generate below.
    logic [NWAY-1:0] inst_w, spc_hit;
    logic [IW-1:0]   t_set;
    logic [IW-1:0]   spi;
    logic [PTW-1:0]  spt;
    logic            m_aux_q_t;
    logic [7:0]      m_bank_q_t;
    logic [11:0]     m_off_q_t, m_vt_q_t;
    logic [15:0]     m_ppn_q_t;
    logic [3:0]      m_reg_q_t;
    logic            m_fold_q_t;
    wire  [127:0]    dl_row_w = dl_row;
    genvar gw;
    generate for (gw = 0; gw < NWAY; gw = gw + 1) begin : g_way
        logic [127:0]  rows [0:NSET-1];
        logic [TW-1:0] vt   [0:NSET-1];
        logic [PTW-1:0] pt  [0:NSET-1];
        assign hitv[gw]  = cv[gw][dq_st[gw]] && (vt[dq_st[gw]] == stag);
        assign wbyte[gw] = {8{hitv[gw]}} & rows[dq_sx[gw]][dq_ix_cam[gw]*8 +: 8];
        // The splice's cut: the write's set, its physical identity - against
        // every RETAINED line, valid or not, so a line written while it is
        // out of service comes back holding the new byte.
        assign spc_hit[gw] = iw_v && cr[gw][spi] && (pt[spi] == spt);
        // One write port: a splice's read-modify-write beats an install,
        // which drops (its valid bit stays clear) and reclaims.
        logic          we;
        logic [IW-1:0] wa;
        logic [127:0]  wd, md;
        always_comb begin
            we = spc_hit[gw] || inst_w[gw];
            wa = spc_hit[gw] ? spi : t_set;
            md = rows[wa];
            md[iw_off8[3:0]*8 +: 8] = iw_data;
            wd = spc_hit[gw] ? md : dl_row_w;
        end
        always_ff @(posedge clk) if (we) rows[wa] <= wd;
        always_ff @(posedge clk) if (inst_w[gw]) begin
            vt[t_set] <= m_vt_q_t[11:IW];
            pt[t_set] <= {m_ppn_q_t, m_vt_q_t[3]};
        end
    end endgenerate
    wire cam_hit = dq_v && (hitv != '0);

    // ---- the revalidation ---------------------------------------------------
    // A map change no longer empties the cache.  Every line's VALID bit is
    // recomputed instead, from the line's own stored identity against the
    // map's new region table, in two register-rooted stages so nothing deep
    // reaches a serve cone:
    //
    //   stage 1, EVERY clock:  rv1[line] <= rt_rd[creg[line]]
    //   stage 2, on reval_q:   cv[line]  <= cr[line] && that entry still
    //                          names this line's class, bank and fold
    //
    // The line's ADDRESS never enters.  Its REGION was decided when it was
    // filled, and what a region answers is a function of the switches alone
    // (rtl/apple_mmu.sv, THE REGION TABLE) - so a line whose region did not
    // move stays valid through the switch write, and a line whose region did
    // move keeps its tags and its row and revives when the map comes back.
    // That is the whole point of the rung: on the animated Nox map the
    // AUXMOVE dance moves RAMRD/RAMWRT ~51k times a second, and the caller
    // in LC RAM and AUXMOVE itself in ROM live in regions those switches do
    // not touch.
    localparam integer RT_W = 7;      // {cls[1:0], wr, bsel[1:0], fold, fs}
    localparam integer NREG = 10;
    localparam [1:0] BS_AUX = 2'd1, BS_ROM = 2'd2;
    wire [RT_W-1:0] rt_rd [0:15];
    genvar gr;
    generate for (gr = 0; gr < 16; gr = gr + 1) begin : g_rt
        // Region numbers no line can carry are never front-servable, so a
        // line that somehow held one would simply drop.
        if (gr < NREG) begin : g_real
            assign rt_rd[gr] = rt_rd_flat[gr*RT_W +: RT_W];
        end else begin : g_none
            assign rt_rd[gr] = '0;
        end
    end endgenerate

    logic reval_q;
    always_ff @(posedge clk) reval_q <= map_changed && !rst;

    logic [RT_W-1:0] rv1 [0:NWAY-1][0:NSET-1];
    integer ra, rb;
    always_ff @(posedge clk)
        for (ra = 0; ra < NWAY; ra = ra + 1)
            for (rb = 0; rb < NSET; rb = rb + 1)
                rv1[ra][rb] <= rt_rd[creg[ra][rb]];

    logic [NSET-1:0] rv_ok [0:NWAY-1];
    logic [7:0]      rv_bank;
    logic [5:0]      n_drop, n_rev;
    integer rc, rd_;
    always_comb begin
        n_drop = 6'd0; n_rev = 6'd0;
        for (rc = 0; rc < NWAY; rc = rc + 1) begin
            for (rd_ = 0; rd_ < NSET; rd_ = rd_ + 1) begin
                rv_bank = (rv1[rc][rd_][3:2] == BS_AUX) ? rwb_p1 :
                          (rv1[rc][rd_][3:2] == BS_ROM) ? 8'hFF : 8'd0;
                rv_ok[rc][rd_] = cr[rc][rd_] && rv1[rc][rd_][0] &&
                                 ((rv1[rc][rd_][6:5] == CLS_RAM) ||
                                  (rv1[rc][rd_][6:5] == CLS_LC)) &&
                                 (cbank[rc][rd_] == rv_bank) &&
                                 (cfold[rc][rd_] == rv1[rc][rd_][1]);
                if ( cv[rc][rd_] && !rv_ok[rc][rd_]) n_drop = n_drop + 6'd1;
                if (!cv[rc][rd_] &&  rv_ok[rc][rd_]) n_rev  = n_rev  + 6'd1;
            end
        end
    end

    // A serve from a line that has come back from a map change at least
    // once: the bench's proof that revival is real and not a refill.
    logic [NWAY-1:0] crevv;
    integer rv;
    always_comb
        for (rv = 0; rv < NWAY; rv = rv + 1) crevv[rv] = crev[rv][dq_st[rv]];
    // One-hot AND-OR across the ways (no two ways hold one line: a miss
    // sees them all before it claims).
    logic [7:0] cam_byte;
    integer wi;
    always_comb begin
        cam_byte = 8'd0;
        for (wi = 0; wi < NWAY; wi = wi + 1) cam_byte = cam_byte | wbyte[wi];
    end

    // ---- the last byte ------------------------------------------------------
    // The previous completed READ - I side or D side - one register deep.
    // The CMOS core's dummy cycles re-read the PREVIOUS cycle's address,
    // and that cycle is as often an instruction-stream fetch (the FIXUP
    // dummy re-reads the operand byte) as a data read (the RMW dummy
    // re-reads the target).  Any classified write clears it - conservative:
    // the dummy that wants it follows its parent on the very next cycle,
    // before any other op's write could land.  The only class guard the
    // serve needs is virtual: everything below $C000 is RAM by
    // construction, everything at $D000+ (LC or ROM, loaded or not) is
    // side-effect free and deterministic, and every map concern already
    // clears the register - while $Cxxx is excluded whole, so no soft
    // switch fires late and the INTC8ROM latch never misses its food.
    logic        lb_v;
    logic [15:0] lb_addr;
    logic [7:0]  lb_byte;
    wire lb_hit = dq_v && lb_v && (dq_addr == lb_addr) && (dq_addr[15:12] != 4'hC);

    // ---- the splice register: a write's stamp, one clock after retire -----
    // Everything rung 3 does with a write after its retire is rooted here:
    // the splice into the shadow and the CAM, the claim abort, the
    // instruction front's snoop, the push onto the posted FIFO, and the
    // one-clock read fence (spl_blk).  A retire fills it; it holds one.
    logic        spl_v, spl_aux;
    logic [7:0]  spl_bank, spl_data;
    logic [15:0] spl_addr, spl_off;
    // ...and the same write's PHYSICAL page and byte-in-page, which is what
    // the cache's tags, the posted FIFO and the page cache now speak.  The
    // triple above survives only as the instruction front's snoop port until
    // that front is converted too (docs/MEMORY_REFACTOR.md, rung 3).
    logic [15:0] spl_ppn;
    logic [7:0]  spl_off8;

    // ---- the retire ---------------------------------------------------------
    // The candidate against the live cycle, gated by the leash.  The settle
    // discipline makes this preempt the dispatcher when turbo_ok is
    // immediate, and the claim holds the dispatcher when it is not.  The
    // claim is REGISTERED - one clock behind serve_hit - and the fc_q ||
    // claim_q gate fences the one-clock window where a fresh serve_hit and
    // a settled dispatcher could both fire (rung 1's third lesson).
    //
    // A write's verdict is VIRTUAL (below $C000: RAM class, in the image
    // under every map) and register-rooted throughout: wr_en (mode 2),
    // the bank register's zero-ness, and ONE local register for the room -
    // the posted FIFO's and the merge's, sampled a clock earlier (the
    // merge's own level already carries the margin for that, and the
    // FIFO's count is taken one short so the retire the sample could not
    // see still fits).  The room is the write's WAIT, not its miss: w_serv
    // alone claims, so the dispatcher stands down while the write waits
    // for a slot - a few clocks at most, the FIFO draining and the merge
    // popping on their own - and the write never pays the dispatcher's
    // price.
    wire serve_hit  = sh_hit || cam_hit || lb_hit;
    // One-hot AND-OR, not a priority chain: the shadow and the cache never
    // hold the same line (claims exclude the estate), and the last byte,
    // when it also hits, IS that line's byte (any write clears it).
    wire [7:0] serve_byte = ({8{sh_hit}} & dq_byte) | ({8{cam_hit}} & cam_byte) |
                            ({8{lb_hit && !sh_hit && !cam_hit}} & lb_byte);

    wire d_cycle = !cyc_is_i &&  cpu_rw;
    wire w_cycle = !cyc_is_i && !cpu_rw;
    wire pf_near_full;
    logic w_room;
    always_ff @(posedge clk) begin
        if (rst) w_room <= 1'b0;
        else     w_room <= ev_room_w && !pf_near_full;
    end
    wire w_serv  = wr_en && dq_wv && (dq_addr[15:14] != 2'b11) && !rwb_nz_q;

    logic fc_q, claim_q;
    always_ff @(posedge clk) begin
        if (rst || cpu_rst) begin
            fc_q <= 1'b0; claim_q <= 1'b0;
        end else begin
            fc_q    <= cyc_en;
            claim_q <= (turbo_en && serve_hit && d_cycle) || (w_serv && w_cycle);
        end
    end
    wire addr_match = (cpu_addr == dq_addr) && (fc_q || claim_q);
    // A read retires only into room on the stream (docs/VIRTUAL_TIME.md):
    // with the merge full the op falls to the dispatcher rather than leave
    // a cycle without a word.
    wire r_retire = !cpu_rst && turbo_en && turbo_ok && serve_hit && d_cycle && addr_match && ev_room;
    wire w_retire = !cpu_rst && turbo_ok && w_serv && w_room && w_cycle && addr_match;
    wire retire   = r_retire || w_retire;

    assign d_commit = retire;
    assign cyc_en   = il_cyc_en || retire;
    // The core's byte is one flat one-hot OR - the shadow's, each way's
    // (wbyte is already gated), the last byte's and, when nothing here
    // serves, the sequencer's - not a mux after an OR after an OR: two LUT
    // levels where the build at +0.008 spent three.
    assign d_din    = ({8{sh_hit}} & dq_byte) | wbyte[0] | wbyte[1] | wbyte[2] | wbyte[3] |
                      ({8{lb_hit && !sh_hit && !cam_hit}} & lb_byte) |
                      ({8{!serve_hit}} & accel_din);
    assign claim    = claim_q;

    // The last byte follows the retiring edge: whatever READ completed -
    // an ifetch through iline, a data read through us or the dispatcher -
    // is the new last; a write clears it (a posted one on its own retire,
    // through cyc_en && !cpu_rw).  The clear-on-any-write runs first so a
    // same-edge read capture wins: that read is ordered after the write
    // and its byte is post-write.
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval || map_changed) begin
            lb_v <= 1'b0;
        end else begin
            if (cl_valid && !cl_rw) lb_v <= 1'b0;
            if (cyc_en) begin
                if (cpu_rw) begin
                    lb_v    <= 1'b1;
                    lb_addr <= cpu_addr;
                    lb_byte <= cyc_is_i ? i_din : d_din;
                end else lb_v <= 1'b0;
            end
        end
    end

    // The stamp: the query port's answer for the registered candidate,
    // sampled by the retire's own edge.  d_off is dq_addr itself below
    // $C000 (the LC fold never applies there) and want_bank is 0 under the
    // bank gate; both are carried whole so the port stays general.
    always_ff @(posedge clk) begin
        if (rst || inval) spl_v <= 1'b0;
        else              spl_v <= w_retire;
        if (w_retire) begin
            spl_addr <= dq_addr;
            spl_data <= cpu_dout;
            spl_aux  <= d_aux;
            spl_bank <= want_bank;
            spl_off  <= d_off;
            spl_ppn  <= d_ppn;
            spl_off8 <= dq_addr[7:0];   // the fold never touches a[11:4]
        end
    end
    assign ws_valid = spl_v;
    assign ws_aux   = spl_aux;
    assign ws_bank  = spl_bank;
    assign ws_off   = spl_off;

    // ---- the posted FIFO ----------------------------------------------------
    // Filled from the splice register, drained by the MMU's take.  The
    // room sample counts the entry still in the splice register (it will
    // push next clock whatever happens) and keeps one slot in hand for the
    // retire that may have landed on the clock the sample was taken, so
    // a write retires only when a slot is free beyond both.  inval drops
    // everything (the image is going away);
    // RES' drops nothing - RAM survives the machine's reset, and so must
    // the writes on their way into it.
    logic [31:0]     pf [0:PW_DEPTH-1];
    logic [PW_AW-1:0] pf_wp, pf_rp;
    logic [PW_AW:0]   pf_cnt;
    wire pf_empty = (pf_cnt == '0);
    assign pf_near_full = (pf_cnt + (PW_AW+1)'(spl_v)) >= (PW_AW+1)'(PW_DEPTH - 1);
    always_ff @(posedge clk) begin
        if (rst || inval) begin
            pf_wp <= '0; pf_rp <= '0; pf_cnt <= '0;
        end else begin
            if (spl_v) begin
                pf[pf_wp] <= {spl_ppn, spl_off8, spl_data};
                pf_wp     <= pf_wp + 1'b1;
            end
            if (pw_take) pf_rp <= pf_rp + 1'b1;
            pf_cnt <= pf_cnt + (PW_AW+1)'(spl_v) - (PW_AW+1)'(pw_take);
        end
    end
    assign pw_valid = !pf_empty;
    assign {pw_ppn, pw_off, pw_data} = pf[pf_rp];

`ifndef SYNTHESIS
    // The ISA argument, checked: no data read of an address is served the
    // clock after a write to it retired (the splice lands on that edge).
    always @(posedge clk)
        if (r_retire && spl_v && spl_addr == dq_addr)
            $error("dline: a read of $%04x served on the splice clock of a write to it", dq_addr);
    // ...and the FIFO never overflows: a push into a full FIFO is a lost write.
    always @(posedge clk)
        if (spl_v && pf_cnt == (PW_AW+1)'(PW_DEPTH) && !pw_take)
            $error("dline: the posted FIFO overflowed");
`endif

    // The drain in flight: a taken entry is classified the clock after
    // (P1), decided the next (P2) and in the banks the one after that
    // (P3); a bank read presented on the clock after THAT sees it.  So
    // pending covers three clocks past the take.
    logic [2:0] drain_sr;
    always_ff @(posedge clk) begin
        if (rst) drain_sr <= 3'd0;
        else     drain_sr <= {drain_sr[1:0], pw_take};
    end
    assign pending = spl_v || !pf_empty || (drain_sr != 3'd0);

    // ---- the claim engine ---------------------------------------------------
    // A miss starts one row claim - into the shadow (its estate) or the
    // CAM's round-robin victim (RAM/LC class elsewhere).  The read itself
    // rides the dispatcher; the SECOND touch hits.  The triggers are
    // registered (iline's discipline: the miss cone never feeds an enable
    // live).  A CAM miss requires dq_addr == cpu_addr so the physical stamp
    // it captures describes the very address being claimed.  Writes never
    // claim: a line that is only ever written is not worth holding.
    localparam [1:0] C_IDLE = 2'd0, C_REQ = 2'd1, C_W1 = 2'd2, C_W2 = 2'd3;
    logic [1:0] cst;
    logic [4:0] c_line;
    logic       miss_q, cmiss_q;
    logic [4:0] miss_line_q;
    logic       t_cam;
    logic [WW-1:0] t_way;
    logic       m_aux_q;
    logic [7:0] m_bank_q;
    logic [11:0] m_off_q, m_vt_q;
    logic [15:0] m_ppn_q;
    logic [3:0]  m_reg_q;
    logic        m_fold_q;

    // The fill trigger's classify, registered one clock behind: the MMU
    // round trip is too deep to sit live in a miss cone, and a claim is
    // lazy by design - the second touch hits either way.  pq_fresh marks
    // the registered copy as describing THIS cycle's dq_addr; on the
    // clock after a cyc_en it still describes the previous cycle's, and
    // the trigger waits (a missed read cycle lasts many clocks).
    logic       pc_ok_q, p_aux_q2, pq_fresh;
    logic [7:0] p_bank_q2;
    logic [11:0] p_off_q2;
    logic [15:0] p_ppn_q2;
    logic [3:0]  p_reg_q2;
    logic        p_fold_q2;
    always_ff @(posedge clk) begin
        pc_ok_q   <= d_cls_ok;
        p_aux_q2  <= d_aux;
        p_bank_q2 <= want_bank;
        p_off_q2  <= d_off[15:4];
        p_ppn_q2  <= d_ppn;
        p_reg_q2  <= d_reg;
        p_fold_q2 <= d_fold;
        pq_fresh  <= !cyc_en && !rst && !cpu_rst;
    end

    wire live_zs   = (cpu_addr[15:9] == 7'd0);
    wire live_miss = turbo_en && d_cycle && live_zs && zs_main_q &&
                     !shv[cpu_addr[8:4]] && !inval;
    wire live_cmiss = turbo_en && d_cycle && dq_v && (dq_addr == cpu_addr) &&
                      pq_fresh && pc_ok_q && !in_sh_estate && !cam_hit &&
                      !inval && !map_settling;

    // ---- the splice ---------------------------------------------------------
    // Every write that reaches the image, seen ONCE: the classified
    // stream's (a bus op's, the dispatcher's, a DMA's) at its P1, or our
    // own posted write from the splice register the clock after its retire
    // - never both on one clock, since the stream carries a write only
    // when the dispatcher or an override runs, and both wait for pending.
    // The stream's copy of a posted write (cl_posted) is skipped: it was
    // spliced at retire.  The shadow's cut: main, offset in pages 0/1.
    // The CAM's cut: any entry whose physical tag matches - per-entry FF
    // rows, so every matching entry updates with no port to contend for.
    wire        cl_w     = cl_valid && !cl_rw && cl_wr_image && !cl_posted;
    wire        iw_v     = cl_w || spl_v;
    wire [15:0] iw_ppn   = spl_v ? spl_ppn  : cl_ppn;
    wire [7:0]  iw_off8  = spl_v ? spl_off8 : cl_off[7:0];
    wire [7:0]  iw_data  = spl_v ? spl_data : wdata;

    // The shadow's cut: physical main pages 0 and 1, the zero page and the
    // stack, which is exactly PPN 0 and PPN 1.
    wire sp_hit  = iw_v && (iw_ppn[15:1] == 15'd0);
    wire [4:0] sp_line = {iw_ppn[0], iw_off8[7:4]};

    // The cache's cut: the write's own set, its physical identity against
    // every way there (spc_hit, in the generate above).
    assign spi = iw_off8[IW+3:4];
    assign spt = {iw_ppn, iw_off8[7]};
    // ...and against an in-flight cache claim's target identity: its page and
    // its line within that page.
    wire spc_flight = iw_v && (m_ppn_q_t == iw_ppn) && (m_vt_q_t[3:0] == iw_off8[7:4]);

    // The shadow write port's one mux: a splice (the row it read, one byte
    // replaced) beats an install, which drops and reclaims - see C_W2 below.
    wire sp_write = sp_hit && shv[sp_line] && !inval;
    logic [127:0] sp_mod;
    always_comb begin
        sp_mod = shrow[sp_line];
        sp_mod[iw_off8[3:0]*8 +: 8] = iw_data;
    end
    always_comb begin
        sh_we    = sp_write || (cst == C_W2 && !t_cam && !sp_hit && !rst && !inval);
        sh_waddr = sp_write ? sp_line : c_line;
        sh_wdata = sp_write ? sp_mod : dl_row;
    end

    // The install, per way: the claim's target way, on the row's clock,
    // unless a splice owns that way's port this clock (then it drops and
    // reclaims) or the claim was aborted.
    wire inst_ok = (cst == C_W2) && t_cam && !spc_flight && !rst && !inval && !map_changed;
    integer wj;
    always_comb begin
        for (wj = 0; wj < NWAY; wj = wj + 1)
            inst_w[wj] = inst_ok && (t_way == WW'(wj)) && !spc_hit[wj];
    end

    always_ff @(posedge clk) begin
        tick_q    <= retire;
        dev_valid <= retire;
        if (retire) begin
            dev_addr <= dq_addr;
            dev_data <= cpu_rw ? serve_byte : cpu_dout;
            dev_rw   <= cpu_rw;
        end

        miss_q      <= live_miss && (cst == C_IDLE);
        miss_line_q <= cpu_addr[8:4];
        cmiss_q     <= live_cmiss && (cst == C_IDLE);
        m_aux_q     <= p_aux_q2;
        m_bank_q    <= p_bank_q2;
        m_off_q     <= p_off_q2;
        m_vt_q      <= dq_addr[15:4];
        m_ppn_q     <= p_ppn_q2;
        m_reg_q     <= p_reg_q2;
        m_fold_q    <= p_fold_q2;

        if (rst || inval) begin
            shv <= 32'd0;
            for (k = 0; k < NWAY; k = k + 1) begin
                cv[k] <= '0; cr[k] <= '0; crev[k] <= '0;
            end
            for (k = 0; k < NSET; k = k + 1) rrp[k] <= '0;
            cst <= C_IDLE; dl_req <= 1'b0; dl_line <= 12'd0; c_line <= 5'd0;
            dl_aux <= 1'b0; dl_bank <= 8'd0; t_cam <= 1'b0; t_way <= '0; t_set <= '0;
            m_aux_q_t <= 1'b0; m_bank_q_t <= 8'd0; m_off_q_t <= 12'd0;
            m_ppn_q_t <= 16'd0; m_reg_q_t <= 4'd0; m_fold_q_t <= 1'b0;
            miss_q <= 1'b0; cmiss_q <= 1'b0;
            tick_q <= 1'b0; dev_valid <= 1'b0;
            if (rst) begin
                cnt_serves <= 32'd0; cnt_claims <= 32'd0; cnt_splices <= 32'd0;
                cnt_cam_serves <= 32'd0; cnt_lb_serves <= 32'd0;
                cnt_posts <= 32'd0; cnt_post_waits <= 32'd0;
                cnt_reval_drop <= 32'd0; cnt_reval_revive <= 32'd0;
                cnt_rev_serves <= 32'd0;
                dev_addr <= 16'd0; dev_data <= 8'd0; dev_rw <= 1'b1;
            end
        end else begin
            if (retire) cnt_serves <= cnt_serves + 32'd1;
            if (r_retire) begin
                if (!sh_hit && cam_hit) cnt_cam_serves <= cnt_cam_serves + 32'd1;
                if (!sh_hit && !cam_hit) cnt_lb_serves <= cnt_lb_serves + 32'd1;
            end
            if (w_retire) cnt_posts <= cnt_posts + 32'd1;
            // Room-waits only: a write held by the governor or a hold is
            // not waiting on this module.
            if (turbo_ok && w_serv && w_cycle && addr_match && !w_room && !cpu_rst)
                cnt_post_waits <= cnt_post_waits + 32'd1;

            // The splices themselves ride the write ports above; only the
            // books live here.
            if (sp_write || spc_hit != '0) cnt_splices <= cnt_splices + 32'd1;

            case (cst)
                C_IDLE: if (miss_q) begin
                    t_cam   <= 1'b0;
                    c_line  <= miss_line_q;
                    dl_line <= {7'd0, miss_line_q};
                    dl_aux  <= 1'b0;
                    dl_bank <= 8'd0;
                    dl_req  <= 1'b1;
                    cst     <= C_REQ;
                end else if (cmiss_q) begin
                    // The victim: an empty way first, else the set's round robin.
                    t_cam     <= 1'b1;
                    t_set     <= m_vt_q[IW-1:0];
                    // An EMPTY way first, then the round robin.  A retained
                    // line that is merely invalid counts as occupied: under
                    // AUXMOVE both banks' copies of a set coexist, one valid
                    // at a time, and each switch write costs nothing.
                    t_way     <= !cr[0][m_vt_q[IW-1:0]] ? 2'd0 :
                                 !cr[1][m_vt_q[IW-1:0]] ? 2'd1 :
                                 !cr[2][m_vt_q[IW-1:0]] ? 2'd2 :
                                 !cr[3][m_vt_q[IW-1:0]] ? 2'd3 : rrp[m_vt_q[IW-1:0]];
                    m_aux_q_t <= m_aux_q;
                    m_bank_q_t <= m_bank_q;
                    m_off_q_t <= m_off_q;
                    m_vt_q_t  <= m_vt_q;
                    m_ppn_q_t <= m_ppn_q;
                    m_reg_q_t <= m_reg_q;
                    m_fold_q_t <= m_fold_q;
                    dl_line   <= m_off_q;
                    dl_aux    <= m_aux_q;
                    dl_bank   <= m_bank_q;
                    dl_req    <= 1'b1;
                    cst       <= C_REQ;
                end
                C_REQ: if (dl_ack) begin
                    dl_req <= 1'b0;
                    // Main always holds; an aux line's page may not be
                    // resident, and then there is nothing to install.
                    cst    <= dl_ok ? C_W1 : C_IDLE;
                end
                C_W1: cst <= C_W2;
                C_W2: begin
                    // The row arrives, on the write ports above - unless a
                    // splice interferes.  For the shadow: ANY splice this
                    // clock (a splice to this line means the row is stale;
                    // a splice to any other line owns the array's one write
                    // port).  For the CAM: only a splice to the claim's own
                    // identity (per-entry rows have no shared port).  Either
                    // way: drop, stay invalid, and the next miss claims it
                    // fresh - a claim can only be late, never wrong.
                    if (!t_cam) begin
                        if (!sp_hit) begin
                            shv[c_line] <= 1'b1;
                            cnt_claims  <= cnt_claims + 32'd1;
                        end
                    end else begin
                        // The row and the tags land through the ports above
                        // on this same edge (inst_w); here the books.
                        if (inst_w != '0) begin
                            cv[t_way][t_set]   <= 1'b1;
                            cr[t_way][t_set]   <= 1'b1;
                            crev[t_way][t_set] <= 1'b0;
                            cbank[t_way][t_set] <= m_ppn_q_t[15:8];
                            creg[t_way][t_set]  <= m_reg_q_t;
                            cfold[t_way][t_set] <= m_fold_q_t;
                            rrp[t_set]       <= t_way + 1'b1;
                            cnt_claims       <= cnt_claims + 32'd1;
                        end
                    end
                    cst <= C_IDLE;
                end
                default: cst <= C_IDLE;
            endcase

            // A splice racing an in-flight claim of the same line aborts it
            // in the earlier states too: the grant may already have read the
            // pre-write row.  A posted write's splice lands the clock after
            // its retire, and a grant on the retire clock itself read the
            // banks before the write could reach them - this is the abort
            // that covers it.
            if (cst != C_IDLE &&
                ((!t_cam && sp_hit && sp_line == c_line) ||
                 ( t_cam && spc_flight))) begin
                dl_req <= 1'b0;
                cst    <= C_IDLE;
            end

            // The map moved.  The lines STAY - an in-flight claim still
            // dies, because its stamp was taken under the old map and the
            // row it is about to read may not be the line it named.
            if (map_changed) begin
                if (cst != C_IDLE && t_cam) begin
                    dl_req <= 1'b0;
                    cst    <= C_IDLE;
                end
            end
            // ...and one clock later every line's valid bit is the new map's
            // answer for the identity that line was filled with.  This is
            // the only writer of cv on this clock: no claim can install here
            // (the abort above ran a clock ago, and live_cmiss is held off
            // through map_settling).
            if (reval_q) begin
                for (k = 0; k < NWAY; k = k + 1) begin
                    cv[k]   <= rv_ok[k];
                    crev[k] <= crev[k] | (rv_ok[k] & ~cv[k]);
                end
                cnt_reval_drop   <= cnt_reval_drop   + {26'd0, n_drop};
                cnt_reval_revive <= cnt_reval_revive + {26'd0, n_rev};
            end
            if (r_retire && cam_hit && ((hitv & crevv) != '0))
                cnt_rev_serves <= cnt_rev_serves + 32'd1;

            if (cnt_clr) begin
                cnt_serves <= 32'd0; cnt_claims <= 32'd0; cnt_splices <= 32'd0;
                cnt_cam_serves <= 32'd0; cnt_lb_serves <= 32'd0;
                cnt_posts <= 32'd0; cnt_post_waits <= 32'd0;
                cnt_reval_drop <= 32'd0; cnt_reval_revive <= 32'd0;
                cnt_rev_serves <= 32'd0;
            end
        end
    end

endmodule
