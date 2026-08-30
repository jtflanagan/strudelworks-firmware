`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mem_client - the memory image's side of the DDR3: the cache's fills and
// writes, the refresh window, and the image in bank 0.
//
// THE IMAGE IS DDR3 BANK 0.  A line's 20-bit address L becomes the burst
// {L[19:7], 3'b000, L[6:0]}: 2 KB of every 16 KB, 32 MB in all, a 16 MB image
// of 256 64 KB banks.  Bank 0 alone because the TX ring owns bank 7 and a
// bank is the one thing two clients can share without evicting each other's
// open row (docs/DDR3_USAGE.md §4).  The Apple's own traffic is random over
// its region and takes a row miss most of the time regardless; a 12-clock
// miss is what the cache's budget already assumes.
//
// ONE QUEUE, IN ORDER.  Writes and fills go into one FIFO and out to the
// controller in arrival order, and UberDDR3 performs accepted requests in
// order.  So a write to a line followed by a fill of that line returns the
// written byte, with no bypass anywhere - the one hazard write-through has,
// closed by construction.  At Apple speed the queue never holds more than the
// current cycle's one request; the depth is for the day the core runs faster.
//
// THE PRIORITY SLOT.  This is wb_arb's strict-priority client: its request
// pre-empts a streaming batch at the next burst boundary, nothing waits behind
// anything, and a fill's first ack is a controller pipeline plus a turnaround
// away at worst.
//
// REFRESH, FROM THE CYCLE'S POSITION.  The controller's refresh gate
// (patches/0001-refresh-gate.patch) takes a refresh early when refresh_ok is
// high.  At Apple speed the card's own memory work is done a few tens of
// clocks into the bus cycle and nothing else can arrive before the next
// op_present, some 98 clocks after the last - so refresh_ok is simply "this
// client is idle and the cycle is between clocks PH_REF_LO and PH_REF_HI",
// leaving the ~23 clocks a refresh takes before the next cycle can need the
// memory.  No prediction of hits is needed; it would be, on a IIgs, and the
// predicate has a place for it.  When the card is not the machine's CPU there
// are no cycles to keep clear of, and refreshes go whenever this client is idle.
//
// The same window, a little shorter, is what lets the arbiter START a
// streaming batch (rot_ok): a batch of 32 lines begun by PH_ROT_HI is finished
// before the next cycle, so a fill never queues behind more than the burst in
// flight.
//
// THE IMAGE IS NEVER CLEARED.  Not at power-up, not on a card reset, not on
// RES': it holds whatever it held, exactly as the machine's RAM does, and
// unwritten memory is garbage by decision (docs/MEMORY.md).  image_ready is
// simply "the DDR3 is calibrated".
//////////////////////////////////////////////////////////////////////////////////
module mem_client #(
    parameter integer PH_REF_LO = 30,
    parameter integer PH_REF_HI = 60,
    parameter integer PH_ROT_LO = 30,
    parameter integer PH_ROT_HI = 50
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         calib_complete,
    input  wire         master_active,
    input  wire         op_present,
    // The core is accelerated (rtl/accel_seq.sv): fills and writes land at
    // any point in the bus cycle, so the windows below would only starve the
    // ring's batches and hold refreshes back for no deadline that exists
    // any more - a refresh under a fast op is a stall, not a wrong answer.
    // With this high both windows are the whole cycle.
    input  wire         accel,

    // From mem_cache: one request, held until taken.
    input  wire         mq_valid,
    input  wire         mq_kind,        // 0 = byte write, 1 = line fill
    input  wire [1:0]   mq_id,
    input  wire [19:0]  mq_line,
    input  wire [3:0]   mq_byte,
    input  wire [7:0]   mq_data,
    output wire         mq_ready,
    // To mem_cache: a fill's line.
    output logic        mr_valid,
    output logic [1:0]  mr_id,
    output logic [127:0] mr_data,

    // wb_arb client (the priority slot).
    output wire         req,
    input  wire         gnt,
    output wire         cyc,
    output logic        stb,
    output logic        we,
    output logic [23:0] addr,
    output logic [127:0] data,
    output logic [15:0] sel,
    input  wire         stall,
    input  wire         ack,
    input  wire [127:0] rdata,

    // Scheduling and status.
    output wire         refresh_ok,
    output wire         rot_ok,
    output wire         mem_idle,
    output wire         image_ready
);

    // ---- the request FIFO ------------------------------------------------------
    localparam integer QW = 1 + 2 + 20 + 4 + 8;    // {kind, id, line, byte, data}
    logic [QW-1:0] q [0:3];
    logic [2:0]    q_wp, q_rp;                     // one extra bit for full/empty
    wire  q_empty = (q_wp == q_rp);
    wire  q_full  = (q_wp[1:0] == q_rp[1:0]) && (q_wp[2] != q_rp[2]);
    assign mq_ready = !q_full;
    wire  q_push = mq_valid && !q_full;

    // ---- issue ----------------------------------------------------------------------
    logic        issuing;               // stb is up, waiting to be accepted
    logic        cur_kind;
    logic [1:0]  cur_id;
    // Accepted and not yet acknowledged.  Wide enough that it cannot wrap
    // whatever the controller's ack latency turns out to be: a wrapped count
    // never returns to zero, and cyc would never drop.
    logic [7:0]  outstanding;
    wire  accept = stb && !stall;

    assign req = issuing || !q_empty;
    assign cyc = req || (outstanding != 8'd0);

    // ---- acks, in order ------------------------------------------------------------
    // Kinds of the accepted-but-unacked requests, oldest first.
    logic [2:0] ak [0:15];               // {kind, id}
    logic [3:0] ak_wp, ak_rp;

    function automatic [23:0] line_to_wb(input [19:0] l);
        line_to_wb = {1'b0, l[19:7], 3'b000, l[6:0]};
    endfunction

    // ---- the cycle's position ----------------------------------------------------
    logic [7:0] phase;
    wire in_ref_win = (phase >= PH_REF_LO[7:0]) && (phase <= PH_REF_HI[7:0]);
    wire in_rot_win = (phase >= PH_ROT_LO[7:0]) && (phase <= PH_ROT_HI[7:0]);

    assign mem_idle    = q_empty && !issuing && (outstanding == 8'd0);
    assign refresh_ok  = calib_complete && mem_idle && (!master_active || accel || in_ref_win);
    assign rot_ok      = q_empty && !issuing && (!master_active || accel || in_rot_win);
    assign image_ready = calib_complete;

    always_ff @(posedge clk) begin
        mr_valid <= 1'b0;

        if (rst) begin
            q_wp <= 3'd0; q_rp <= 3'd0;
            issuing <= 1'b0; cur_kind <= 1'b0; cur_id <= 2'd0;
            stb <= 1'b0; we <= 1'b0; addr <= 24'd0; data <= 128'd0; sel <= 16'd0;
            outstanding <= 8'd0;
            ak_wp <= 4'd0; ak_rp <= 4'd0;
            mr_id <= 2'd0; mr_data <= 128'd0;
            phase <= 8'd0;
        end else begin
            // ---- position in the bus cycle ------------------------------------
            if (op_present)          phase <= 8'd0;
            else if (phase != 8'hFF) phase <= phase + 8'd1;

            // ---- the queue ---------------------------------------------------------
            if (q_push) begin
                q[q_wp[1:0]] <= {mq_kind, mq_id, mq_line, mq_byte, mq_data};
                q_wp <= q_wp + 3'd1;
            end

            // ---- issue -------------------------------------------------------------
            if (issuing) begin
                if (accept) begin
                    issuing <= 1'b0;
                    stb     <= 1'b0;
                    ak[ak_wp] <= {cur_kind, cur_id};
                    ak_wp   <= ak_wp + 4'd1;
                end
            end else if (!q_empty) begin
                // Pop the oldest request onto the port.
                issuing  <= 1'b1;
                stb      <= 1'b1;
                cur_kind <= q[q_rp[1:0]][QW-1];
                cur_id   <= q[q_rp[1:0]][QW-2 -: 2];
                we       <= !q[q_rp[1:0]][QW-1];
                addr     <= line_to_wb(q[q_rp[1:0]][31:12]);
                data     <= {16{q[q_rp[1:0]][7:0]}};
                sel      <= q[q_rp[1:0]][QW-1] ? 16'hFFFF : (16'd1 << q[q_rp[1:0]][11:8]);
                q_rp     <= q_rp + 3'd1;
            end

            // ---- acks ----------------------------------------------------------------
            if (accept && !ack)      outstanding <= outstanding + 8'd1;
            else if (ack && !accept) outstanding <= outstanding - 8'd1;
            if (ack) begin
                ak_rp <= ak_rp + 4'd1;
                if (ak[ak_rp][2]) begin
                    mr_valid <= 1'b1;
                    mr_id    <= ak[ak_rp][1:0];
                    mr_data  <= rdata;
                end
            end
        end
    end

endmodule
