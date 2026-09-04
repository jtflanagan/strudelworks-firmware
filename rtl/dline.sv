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
//   * THE CAM (rung 2): 4 lines as FF rows with FF tags carrying PHYSICAL
//     identity - {aux, bank, folded off[15:4]} - serving RAM- and LC-class
//     reads outside the shadow's estate.  Tags are physical, but a fill's
//     FOLDING was captured under the map of its day, so the CAM flash-clears
//     on map_changed - iline's rule, kept.  Round-robin replacement until
//     rung 4 refines insertion.  The rows are flip-flops, not LUTRAM: four
//     rows are cheap, and per-entry write ports mean a splice never contends
//     with anything - no kills, only the in-flight install abort.
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
    input  wire        cl_aux,
    input  wire [7:0]  cl_bank,
    input  wire [15:0] cl_off,
    input  wire [7:0]  wdata,         // the classified write's byte (cl_wdata)

    // The posted FIFO's head, to the MMU's classified stage.
    output wire        pw_valid,
    output wire        pw_aux,
    output wire [7:0]  pw_bank,
    output wire [15:0] pw_off,
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
    output logic [31:0] cnt_post_waits   // clocks a servable write waited for room
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
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval) begin
            dq_v  <= 1'b0;
            dq_wv <= 1'b0;
        end else if (cyc_en) begin
            dq_v  <= d_pred_v &&  d_pred_rw;
            dq_wv <= d_pred_v && !d_pred_rw;
        end
        if (cyc_en) begin
            dq_addr <= d_pred;
        end
    end
    assign dq_rw = !dq_wv;
    wire [7:0] dq_byte = shrow[dq_addr[8:4]][dq_addr[3:0]*8 +: 8];
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
    logic [3:0]   cv;
    logic [11:0]  vt      [0:3];      // virtual: addr[15:4], the serve's compare
    logic         ct_aux  [0:3];      // physical, the snoops' compare
    logic [7:0]   ct_bank [0:3];
    logic [11:0]  ct_off  [0:3];
    logic [127:0] crow    [0:3];
    logic [1:0]   rr;

    wire       in_sh_estate = (dq_addr[15:9] == 7'd0) && zs_main_q;
    wire       d_cls_ok     = (d_cls == CLS_RAM) || (d_cls == CLS_LC);
    wire [7:0] want_bank    = d_aux ? rw_bank : 8'd0;

    wire [3:0] chit;
    genvar ge;
    generate for (ge = 0; ge < 4; ge = ge + 1) begin : g_chit
        assign chit[ge] = cv[ge] && (vt[ge] == dq_addr[15:4]);
    end endgenerate
    wire       cam_hit  = dq_v && (chit != 4'd0);
    wire [7:0] cam_byte = chit[0] ? crow[0][dq_addr[3:0]*8 +: 8] :
                          chit[1] ? crow[1][dq_addr[3:0]*8 +: 8] :
                          chit[2] ? crow[2][dq_addr[3:0]*8 +: 8] :
                                    crow[3][dq_addr[3:0]*8 +: 8];

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
    wire [7:0] serve_byte = sh_hit ? dq_byte : cam_hit ? cam_byte : lb_byte;

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
    assign d_din    = serve_hit ? serve_byte : accel_din;
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
    logic [32:0]     pf [0:PW_DEPTH-1];
    logic [PW_AW-1:0] pf_wp, pf_rp;
    logic [PW_AW:0]   pf_cnt;
    wire pf_empty = (pf_cnt == '0);
    assign pf_near_full = (pf_cnt + (PW_AW+1)'(spl_v)) >= (PW_AW+1)'(PW_DEPTH - 1);
    always_ff @(posedge clk) begin
        if (rst || inval) begin
            pf_wp <= '0; pf_rp <= '0; pf_cnt <= '0;
        end else begin
            if (spl_v) begin
                pf[pf_wp] <= {spl_aux, spl_bank, spl_off, spl_data};
                pf_wp     <= pf_wp + 1'b1;
            end
            if (pw_take) pf_rp <= pf_rp + 1'b1;
            pf_cnt <= pf_cnt + (PW_AW+1)'(spl_v) - (PW_AW+1)'(pw_take);
        end
    end
    assign pw_valid = !pf_empty;
    assign {pw_aux, pw_bank, pw_off, pw_data} = pf[pf_rp];

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
    logic [1:0] t_ent;
    logic       m_aux_q;
    logic [7:0] m_bank_q;
    logic [11:0] m_off_q, m_vt_q;

    // The fill trigger's classify, registered one clock behind: the MMU
    // round trip is too deep to sit live in a miss cone, and a claim is
    // lazy by design - the second touch hits either way.  pq_fresh marks
    // the registered copy as describing THIS cycle's dq_addr; on the
    // clock after a cyc_en it still describes the previous cycle's, and
    // the trigger waits (a missed read cycle lasts many clocks).
    logic       pc_ok_q, p_aux_q2, pq_fresh;
    logic [7:0] p_bank_q2;
    logic [11:0] p_off_q2;
    always_ff @(posedge clk) begin
        pc_ok_q   <= d_cls_ok;
        p_aux_q2  <= d_aux;
        p_bank_q2 <= want_bank;
        p_off_q2  <= d_off[15:4];
        pq_fresh  <= !cyc_en && !rst && !cpu_rst;
    end

    wire live_zs   = (cpu_addr[15:9] == 7'd0);
    wire live_miss = turbo_en && d_cycle && live_zs && zs_main_q &&
                     !shv[cpu_addr[8:4]] && !inval;
    wire live_cmiss = turbo_en && d_cycle && dq_v && (dq_addr == cpu_addr) &&
                      pq_fresh && pc_ok_q && !in_sh_estate && !cam_hit &&
                      !inval && !map_changed;

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
    wire        cl_w    = cl_valid && !cl_rw && cl_wr_image && !cl_posted;
    wire        iw_v    = cl_w || spl_v;
    wire        iw_aux  = spl_v ? spl_aux  : cl_aux;
    wire [7:0]  iw_bank = spl_v ? spl_bank : (cl_aux ? cl_bank : 8'd0);
    wire [15:0] iw_off  = spl_v ? spl_off  : cl_off;
    wire [7:0]  iw_data = spl_v ? spl_data : wdata;

    wire sp_hit  = iw_v && !iw_aux && (iw_off[15:9] == 7'd0);
    wire [4:0] sp_line = iw_off[8:4];

    wire [3:0] spc_hit;
    generate for (ge = 0; ge < 4; ge = ge + 1) begin : g_spc
        assign spc_hit[ge] = iw_v && cv[ge] && (ct_aux[ge] == iw_aux) &&
                             (ct_bank[ge] == iw_bank) && (ct_off[ge] == iw_off[15:4]);
    end endgenerate
    // ...and against an in-flight CAM claim's target identity.
    logic       m_aux_q_t;
    logic [7:0] m_bank_q_t;
    logic [11:0] m_off_q_t, m_vt_q_t;
    wire spc_flight = iw_v && (m_aux_q_t == iw_aux) && (m_bank_q_t == iw_bank) &&
                      (m_off_q_t == iw_off[15:4]);

    // The shadow write port's one mux: a splice (the row it read, one byte
    // replaced) beats an install, which drops and reclaims - see C_W2 below.
    wire sp_write = sp_hit && shv[sp_line] && !inval;
    logic [127:0] sp_mod;
    always_comb begin
        sp_mod = shrow[sp_line];
        sp_mod[iw_off[3:0]*8 +: 8] = iw_data;
    end
    always_comb begin
        sh_we    = sp_write || (cst == C_W2 && !t_cam && !sp_hit && !rst && !inval);
        sh_waddr = sp_write ? sp_line : c_line;
        sh_wdata = sp_write ? sp_mod : dl_row;
    end

    // The CAM rows: per-entry write, splice or install, splice first (an
    // install racing a splice of its own line is aborted below and never
    // reaches here on the same entry).
    integer e;
    always_ff @(posedge clk) begin
        for (e = 0; e < 4; e = e + 1) begin
            if (spc_hit[e])
                crow[e][iw_off[3:0]*8 +: 8] <= iw_data;
            else if (cst == C_W2 && t_cam && !spc_flight && !rst && !inval &&
                     !map_changed && t_ent == 2'(e))
                crow[e] <= dl_row;
        end
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

        if (rst || inval) begin
            shv <= 32'd0;
            cv  <= 4'd0;
            rr  <= 2'd0;
            cst <= C_IDLE; dl_req <= 1'b0; dl_line <= 12'd0; c_line <= 5'd0;
            dl_aux <= 1'b0; dl_bank <= 8'd0; t_cam <= 1'b0; t_ent <= 2'd0;
            m_aux_q_t <= 1'b0; m_bank_q_t <= 8'd0; m_off_q_t <= 12'd0;
            miss_q <= 1'b0; cmiss_q <= 1'b0;
            tick_q <= 1'b0; dev_valid <= 1'b0;
            if (rst) begin
                cnt_serves <= 32'd0; cnt_claims <= 32'd0; cnt_splices <= 32'd0;
                cnt_cam_serves <= 32'd0; cnt_lb_serves <= 32'd0;
                cnt_posts <= 32'd0; cnt_post_waits <= 32'd0;
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
            if (sp_write || spc_hit != 4'd0) cnt_splices <= cnt_splices + 32'd1;

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
                    t_cam     <= 1'b1;
                    t_ent     <= rr;
                    m_aux_q_t <= m_aux_q;
                    m_bank_q_t <= m_bank_q;
                    m_off_q_t <= m_off_q;
                    m_vt_q_t  <= m_vt_q;
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
                        if (!spc_flight && !map_changed) begin
                            cv[t_ent]      <= 1'b1;
                            vt[t_ent]      <= m_vt_q_t;
                            ct_aux[t_ent]  <= m_aux_q_t;
                            ct_bank[t_ent] <= m_bank_q_t;
                            ct_off[t_ent]  <= m_off_q_t;
                            rr             <= rr + 2'd1;
                            cnt_claims     <= cnt_claims + 32'd1;
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

            // The map moved: the CAM's foldings are of the old map.  Tags
            // die, and an in-flight CAM claim dies with them.
            if (map_changed) begin
                cv <= 4'd0;
                if (cst != C_IDLE && t_cam) begin
                    dl_req <= 1'b0;
                    cst    <= C_IDLE;
                end
            end

            if (cnt_clr) begin
                cnt_serves <= 32'd0; cnt_claims <= 32'd0; cnt_splices <= 32'd0;
                cnt_cam_serves <= 32'd0; cnt_lb_serves <= 32'd0;
                cnt_posts <= 32'd0; cnt_post_waits <= 32'd0;
            end
        end
    end

endmodule
