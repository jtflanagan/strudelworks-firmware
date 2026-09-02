`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// dline - the data front, rung 1: the zp/stack shadow.  docs/DLINE.md.
//
// Between rtl/iline.sv and the core's d_din port, exactly as iline sits on
// i_din: registered candidates in, a one-clock retire out, the sequencer
// seeing only the books.  This rung serves READS of physical MAIN pages 0
// and 1 from a 512-byte shadow (32 lines x 16 B, one valid FF per line,
// claimed lazily through the page cache's line-row port).  Writes still ride
// the dispatcher; the shadow SPLICES them in from the classified stream, so
// a store costs what it always cost and the shadow never goes stale.
//
// THE SHADOW NEVER INVALIDATES FOR MAP REASONS.  Its identity is physical
// main pages 0/1; ALTZP only DIVERTS traffic to auxiliary memory, it never
// changes what main holds.  The serve qualifier is the REGISTERED pair
// {address in $00xx/$01xx, zp/stack maps main}; the content dies only with
// the image (inval) - never on map_changed, never on reset.
//
// THE SERVE, in iline's discipline (the laws in docs/DLINE.md):
//   * cpu65c02's d_pred names the next data cycle's address a cycle early,
//     BY CONSTRUCTION (proven over both Klaus suites, sim/cpu_predict).
//     At each edge the shadow's row is read at the predicted line and the
//     candidate registered: dq_addr, dq_byte, dq_serve.
//   * The retire is a registered compare against registered state: the live
//     cycle's address equals dq_addr, the cycle is data-class read, and
//     turbo_ok grants - then cyc_en fires and dq_byte is the byte.
//   * claim (mirroring iline's) holds the dispatcher off any cycle the
//     shadow holds the answer, so a governor or override stall never lets
//     the settled dispatcher race the retire.
//   * The books are the sequencer's own: d_commit rides the same
//     turbo_commit contract, tick_q pulses the peripherals' timebases, and
//     the event goes out at retire when the merge has room - best effort,
//     as for turbo ifetches: a read changes no host state.
//
// A miss (valid line absent) rides the dispatcher unclaimed - it can only
// waste - and triggers the line's claim: one il_row grant, lowest priority
// behind iline's, the whole 16 bytes in one write.  A splice that lands on
// a line whose claim is in flight ABORTS the claim: the row was read before
// the write landed, and installing it would resurrect the stale byte.  The
// old D$ stab's two hardware bugs were exactly this class of race; the
// abort-and-reclaim is the cheap shape that cannot lose.
//////////////////////////////////////////////////////////////////////////////////
module dline (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,

    // The core: the prediction, and the live cycle it names.
    input  wire [15:0] d_pred,
    input  wire        d_pred_v,
    input  wire        d_pred_rw,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    input  wire        cyc_is_i,

    // The chain to the core: iline's cyc_en in, ours out; the byte.
    input  wire        il_cyc_en,     // the sequencer's, or an I retire
    input  wire [7:0]  accel_din,     // the sequencer's byte, when we do not serve
    output wire        cyc_en,        // to the core
    output wire [7:0]  d_din,         // to the core

    // The leash and the books, shared with iline through the sequencer.
    input  wire        turbo_en,
    input  wire        turbo_ok,
    output wire        d_commit,      // combinational: one op retired on this edge
    output wire        claim,         // hold the dispatcher: this read is mine
    output logic       tick_q,        // one pulse per retired op (floppy, Mockingboard)

    // The event, best effort like a turbo ifetch's.
    output logic       dev_valid,
    output logic [15:0] dev_addr,
    output logic [7:0]  dev_data,
    input  wire        ev_room,

    // The map: ALTZP as the MMU holds it (sw_state[3]); registered here.
    input  wire        altzp,

    // The line-row port, arbitrated in the top behind iline's requests.
    output logic       dl_req,
    output logic [11:0] dl_line,
    input  wire        dl_ack,        // granted this clock (top gates by priority)
    input  wire        dl_ok,
    input  wire [127:0] dl_row,       // valid two clocks after an ok'd ack

    // The splice: the classified stream's writes that reach main image.
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire        cl_aux,
    input  wire [15:0] cl_off,
    input  wire [7:0]  wdata,         // the stream's write data, held with the op

    // The image.
    input  wire        inval,

    // Counters.
    input  wire        cnt_clr,
    output logic [31:0] cnt_serves,
    output logic [31:0] cnt_claims,
    output logic [31:0] cnt_splices
);

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
    // long, and the flip's own cycle is $C0xx, never served here.
    logic zs_main_q;
    always_ff @(posedge clk) begin
        if (rst) zs_main_q <= 1'b1;
        else     zs_main_q <= !altzp;
    end

    // ---- the candidate ------------------------------------------------------
    // Registered ONLY at edges the core moves, so it always describes the
    // LIVE cycle: re-registering on every clock would let it drift one cycle
    // ahead while a missed read still rode the dispatcher, and the d_din mux
    // below would hand the core the wrong byte.
    //
    // What registers is deliberately MINIMAL: the address, and the
    // prediction's own validity (dq_v).  d_pred settles late - it inherits
    // din's timing - and every serve-side fact stacked on its cone has
    // missed timing once: the pre-read byte at 16 levels (-0.65), then a
    // verdict register fed by prediction AND range AND valid AND map at 15
    // (-0.17).  So range, valid bit and map are evaluated THROUGH the serve
    // cycle from the REGISTERED address instead (serve_hit): register-rooted,
    // a few levels, a whole cycle to run - the same split that serves the
    // byte, sampled by the edge that ends the cycle.
    logic        dq_v;
    logic [15:0] dq_addr;
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || inval) begin
            dq_v <= 1'b0;
        end else if (cyc_en) begin
            dq_v <= d_pred_v && d_pred_rw;
        end
        if (cyc_en) begin
            dq_addr <= d_pred;
        end
    end
    wire [7:0] dq_byte   = shrow[dq_addr[8:4]][dq_addr[3:0]*8 +: 8];
    wire       serve_hit = dq_v && (dq_addr[15:9] == 7'd0) &&
                           shv[dq_addr[8:4]] && zs_main_q;

    // ---- the retire ---------------------------------------------------------
    // The candidate against the live cycle, gated by the leash.  The settle
    // discipline makes this preempt the dispatcher when turbo_ok is
    // immediate, and the claim holds the dispatcher when it is not.  The
    // claim is REGISTERED - one clock behind serve_hit - and the settle
    // discipline is again what makes that safe: the dispatcher cannot act
    // before its second clock (settled), by which time the claim stands.
    // One window needs closing: serve_hit can RISE mid-cycle (a claim's
    // install landing while the governor holds this very cycle), and the
    // registered claim is a clock behind it - so for exactly one clock a
    // fresh serve_hit and a settled dispatcher could both fire.  The gate:
    // a retire is legal on the cycle's FIRST clock (fc_q - the dispatcher
    // cannot act before its second, that is the settle discipline), or once
    // the claim already stands - never in the gap.  A serve_hit that rises
    // late therefore waits one clock for its claim; if the dispatcher won
    // that clock instead, the op rides it - the shadow's byte and the
    // dispatcher's are the same byte, and the next cycle serves fast.
    wire d_cycle = !cyc_is_i && cpu_rw;
    logic fc_q, claim_q;
    always_ff @(posedge clk) begin
        if (rst || cpu_rst) begin
            fc_q <= 1'b0; claim_q <= 1'b0;
        end else begin
            fc_q    <= cyc_en;
            claim_q <= turbo_en && serve_hit && d_cycle;
        end
    end
    wire retire = !cpu_rst && turbo_en && turbo_ok && serve_hit &&
                  d_cycle && (cpu_addr == dq_addr) && (fc_q || claim_q);

    assign d_commit = retire;
    assign cyc_en   = il_cyc_en || retire;
    assign d_din    = serve_hit ? dq_byte : accel_din;
    assign claim    = claim_q;

    // ---- the claim engine ---------------------------------------------------
    // A miss - a data read in range, mapped main, line invalid - starts one
    // row claim.  The read itself rides the dispatcher; the SECOND touch
    // hits.  The trigger is registered (iline's discipline: the miss cone
    // never feeds an enable live).
    localparam [1:0] C_IDLE = 2'd0, C_REQ = 2'd1, C_W1 = 2'd2, C_W2 = 2'd3;
    logic [1:0] cst;
    logic [4:0] c_line;
    logic       miss_q;
    logic [4:0] miss_line_q;

    wire live_zs   = (cpu_addr[15:9] == 7'd0);
    wire live_miss = turbo_en && d_cycle && live_zs && zs_main_q &&
                     !shv[cpu_addr[8:4]] && !inval;

    // ---- the splice ---------------------------------------------------------
    // Every write the classifier says reaches main image at an offset the
    // shadow owns.  Diverted writes are aux (cl_aux); LC never maps here.
    wire sp_hit  = cl_valid && !cl_rw && cl_wr_image && !cl_aux &&
                   (cl_off[15:9] == 7'd0);
    wire [4:0] sp_line = cl_off[8:4];

    // The write port's one mux: a splice (the row it read, one byte replaced)
    // beats an install, which drops and reclaims - see C_W2 below.
    wire sp_write = sp_hit && shv[sp_line] && !inval;
    logic [127:0] sp_mod;
    always_comb begin
        sp_mod = shrow[sp_line];
        sp_mod[cl_off[3:0]*8 +: 8] = wdata;
    end
    always_comb begin
        sh_we    = sp_write || (cst == C_W2 && !sp_hit && !rst && !inval);
        sh_waddr = sp_write ? sp_line : c_line;
        sh_wdata = sp_write ? sp_mod : dl_row;
    end

    integer i;
    always_ff @(posedge clk) begin
        tick_q    <= retire;
        dev_valid <= retire && ev_room;
        if (retire) begin
            dev_addr <= dq_addr;
            dev_data <= dq_byte;
        end

        miss_q      <= live_miss && (cst == C_IDLE);
        miss_line_q <= cpu_addr[8:4];

        if (rst || inval) begin
            shv <= 32'd0;
            cst <= C_IDLE; dl_req <= 1'b0; dl_line <= 12'd0; c_line <= 5'd0;
            miss_q <= 1'b0;
            tick_q <= 1'b0; dev_valid <= 1'b0;
            if (rst) begin
                cnt_serves <= 32'd0; cnt_claims <= 32'd0; cnt_splices <= 32'd0;
                dev_addr <= 16'd0; dev_data <= 8'd0;
            end
        end else begin
            if (retire) cnt_serves <= cnt_serves + 32'd1;

            // The splice itself rides the write port above; only the books
            // live here.
            if (sp_write) cnt_splices <= cnt_splices + 32'd1;

            case (cst)
                C_IDLE: if (miss_q) begin
                    c_line  <= miss_line_q;
                    dl_line <= {7'd0, miss_line_q};
                    dl_req  <= 1'b1;
                    cst     <= C_REQ;
                end
                C_REQ: if (dl_ack) begin
                    dl_req <= 1'b0;
                    cst    <= dl_ok ? C_W1 : C_IDLE;   // main always holds; belt anyway
                end
                C_W1: cst <= C_W2;
                C_W2: begin
                    // The row arrives, on the write port above - unless ANY
                    // splice lands this clock.  A splice to this line means
                    // the row was read before the write and is stale by one
                    // byte; a splice to any other line owns the array's one
                    // write port this clock.  Either way: drop, stay
                    // invalid, and the next miss claims it fresh - a claim
                    // can only be late, never wrong.
                    if (!sp_hit) begin
                        shv[c_line] <= 1'b1;
                        cnt_claims  <= cnt_claims + 32'd1;
                    end
                    cst <= C_IDLE;
                end
                default: cst <= C_IDLE;
            endcase

            // A splice racing an in-flight claim of the same line aborts it in
            // the earlier states too: the grant may already have read the
            // pre-write row.
            if (sp_hit && cst != C_IDLE && sp_line == c_line) begin
                dl_req <= 1'b0;
                cst    <= C_IDLE;
            end

            if (cnt_clr) begin
                cnt_serves <= 32'd0; cnt_claims <= 32'd0; cnt_splices <= 32'd0;
            end
        end
    end

endmodule
