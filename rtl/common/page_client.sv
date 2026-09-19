`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// page_client - the page cache's side of the DDR3: a pipelined stream of
// whole-line requests into wb_arb's priority slot.  Replaces rtl/mem_client.sv.
//
// THE ONE HARD REQUIREMENT (docs/PAGE_CACHE.md): beats go out PIPELINED.
// mem_client deliberately issued one op at a time - at Apple speed its queue
// never held more than one request.  A page fill is sixteen; serialized at
// ~11 clocks each that is ~176 clocks and the budget is gone.  So this module
// holds nothing back: stb is up whenever the engine has a beat and the grant
// is here, the stall signal is the only brake, and the engine's stream
// advances on every accepted beat.  UberDDR3 performs accepted requests in
// order and acks in order, which is the whole of the flow control.
//
// THE SEAM.  pq_busy spans the engine's whole transaction - snapshot, fill,
// turnaround, flush - so `req` holds the arbiter's grant across the gaps
// between the fill's last beat and the flush's first (wb_arb takes a dropped
// req as the batch's end).  pq_valid/pq_we/pq_line/pq_wdata are one beat,
// accepted when pq_ready; every request is a whole 16-byte line, sel is
// always all lanes.  A read's line comes back on pr_valid in request order;
// write acks are counted and swallowed.  cyc holds from the first request to
// the last ack, whatever the grant does (the controller aborts outstanding
// acks the clock cyc drops - wb_arb.sv's header).
//
// THE IMAGE IS DDR3 BANK 0's aux region now: line {bank, off[15:4]} maps
// exactly as mem_client's did - {L[19:7], 3'b000, L[6:0]}, 2 KB of every
// 16 KB - but bank k is RAMWORKS bank k, not image bank k+1: main memory
// lives in block RAM (rtl/page_cache.sv) and the DDR3 holds no copy of it.
// A page's sixteen lines sit in one row, so a fill or flush after its first
// beat is all page hits.
//
// THE ROTATION keeps mem_client's scheme: a ring batch may start only in a
// window that is over before the next cycle can need the memory.  Refresh is
// the DDR3 controller's own, on its tREFI timer (the refresh gate that once
// took it in this client's idle window was removed 2026-09-14).  When the card is not the machine's CPU there are no
// cycles to keep clear of.  The image is never cleared, exactly as before.
//////////////////////////////////////////////////////////////////////////////////
module page_client #(
    parameter integer PH_ROT_LO = 30,
    parameter integer PH_ROT_HI = 50
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         calib_complete,
    input  wire         master_active,
    input  wire         op_present,
    // The core is accelerated (rtl/accel_seq.sv): fills and flushes land at
    // any point in the bus cycle, so the window below would only starve the
    // ring's batches.  With this high it is the whole cycle.
    input  wire         accel,

    // From page_cache's engine: the request stream.
    input  wire         pq_busy,
    input  wire         pq_valid,
    input  wire         pq_we,
    input  wire [19:0]  pq_line,
    input  wire [127:0] pq_wdata,
    input  wire [15:0]  pq_sel,      // the lanes a write carries (a2: all; gs: a write-around's one)
    output wire         pq_ready,
    // To page_cache: a read's line, in request order.
    output logic        pr_valid,
    output logic [127:0] pr_data,

    // wb_arb client (the priority slot).
    output wire         req,
    input  wire         gnt,
    output wire         cyc,
    output wire         stb,
    output wire         we,
    output wire [23:0]  addr,
    output wire [127:0] data,
    output wire [15:0]  sel,
    input  wire         stall,
    input  wire         ack,
    input  wire [127:0] rdata,

    // Scheduling and status.
    output wire         rot_ok,
    output wire         mem_idle,
    output wire         image_ready
);

    function automatic [23:0] line_to_wb(input [19:0] l);
        line_to_wb = {1'b0, l[19:7], 3'b000, l[6:0]};
    endfunction

    // ---- the stream, passed through ------------------------------------------
    assign req      = pq_busy || pq_valid;
    assign stb      = pq_valid && gnt;
    assign pq_ready = gnt && !stall;
    assign we       = pq_we;
    assign addr     = line_to_wb(pq_line);
    assign data     = pq_wdata;
    assign sel      = pq_sel;

    wire accept = stb && !stall;

    // Accepted and not yet acknowledged.  Wide enough that it cannot wrap.
    logic [7:0] outstanding;
    assign cyc = req || (outstanding != 8'd0);

    // ---- acks, in order --------------------------------------------------------
    // The kind of each accepted-but-unacked request, oldest first: a read's
    // ack carries its line up, a write's is swallowed.
    logic [31:0] kinds;                 // shift by pointers; 1 = read
    logic [4:0]  k_wp, k_rp;

    // ---- the cycle's position --------------------------------------------------
    logic [7:0] phase;
    wire in_rot_win = (phase >= PH_ROT_LO[7:0]) && (phase <= PH_ROT_HI[7:0]);

    assign mem_idle    = !pq_busy && !pq_valid && (outstanding == 8'd0);
    assign rot_ok      = !pq_busy && !pq_valid && (!master_active || accel || in_rot_win);
    assign image_ready = calib_complete;

    always_ff @(posedge clk) begin
        pr_valid <= 1'b0;

        if (rst) begin
            outstanding <= 8'd0;
            kinds <= 32'd0;
            k_wp <= 5'd0; k_rp <= 5'd0;
            pr_data <= 128'd0;
            phase <= 8'd0;
        end else begin
            // ---- position in the bus cycle --------------------------------
            if (op_present)          phase <= 8'd0;
            else if (phase != 8'hFF) phase <= phase + 8'd1;

            // ---- accepts and acks ------------------------------------------
            if (accept && !ack)      outstanding <= outstanding + 8'd1;
            else if (ack && !accept) outstanding <= outstanding - 8'd1;

            if (accept) begin
                kinds[k_wp] <= !pq_we;
                k_wp <= k_wp + 5'd1;
            end
            if (ack) begin
                k_rp <= k_rp + 5'd1;
                if (kinds[k_rp]) begin
                    pr_valid <= 1'b1;
                    pr_data  <= rdata;
                end
            end
        end
    end

endmodule
