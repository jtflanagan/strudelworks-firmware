`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_fifo - FT601 / FT245 synchronous FIFO controller.
//
// A functional port of pcileech_ft601.sv from ufrisk/pcileech-fpga (Ulf Frisk),
// which drives this chip at 100 MHz in a shipped design.  States, signal
// polarities, bus-ownership policy, queue behaviour and exit conditions all
// follow the original; only identifiers are renamed to this project's ports.
//
// Every place an earlier version of this file diverged from that structure
// produced a bug at the burst boundary - a registered TXE#, a four-state machine,
// tristate-by-default, an acknowledge-based pop.  None of those are reintroduced.
//
// ONE divergence is now deliberate: the reference's five-DWORD 0x66665555 preload
// is removed, so the output queue starts and returns to EMPTY.  That was on the
// list above, and it is safe here for a specific reason - FWD is gated on a
// non-empty queue and the FSM leaves S_IDLE only on a non-empty queue, so the
// undefined power-on contents of DATA_OUT are never forwarded.  The preload was
// the reference's 1024-byte errata workaround; this design moves that job to the
// message layer (see the note at the queue logic, docs/PROTOCOL.md, ft601_top).
//
// Despite the filename this module contains NO FIFO.  The reference keeps the
// clock-domain crossing outside the FT601 controller and so does this: ft601_top
// holds the async FIFOs, and everything here runs in the single ft_clk domain.
//
// Signal naming: this project's ft_rxf / ft_txe / ft_rd / ft_wr / ft_oe are the
// chip's active-low RXF# / TXE# / RD# / WR# / OE# - the same signals as the
// reference's FT601_*_N, without the suffix.
//////////////////////////////////////////////////////////////////////////////////

module ft601_fifo (
    input  wire         clk,          // the FT601's FIFO clock
    input  wire         rst,

    // TO/FROM PADS
    output wire  [3:0]  ft_be,
    inout  wire  [31:0] ft_data,
    input  wire         ft_rxf,       // RXF#
    input  wire         ft_txe,       // TXE#
    output logic        ft_oe,        // OE#
    output logic        ft_rd,        // RD#
    output logic        ft_wr,        // WR#
    output wire         ft_wakeup,    // WAKEUP#, held inactive

    // TO/FROM FIFO
    output logic [31:0] dout,
    output logic        dout_valid,
    input  wire  [31:0] din,
    input  wire         din_wr_en,
    output wire         din_req_data,

    // TO THE MESSAGE LAYER (ft601_msg_tx).  Everything it needs to track the
    // chip's internal 1 KB buffer; see docs/PROTOCOL.md.
    output wire         fwd,          // a block was handed to the chip THIS cycle
    output wire         q_empty,      // the skid buffer has drained
    output wire         in_rx,        // the bus is turned around for RX

    // For the link snapshot on the UART: the FSM state and the skid count as
    // they are, sampled from another domain at the moment a reset fires.
    output wire  [3:0]  dbg_state,
    output wire  [1:0]  dbg_qcount
);

    initial begin
        ft_oe      <= 1'b1;
        ft_rd      <= 1'b1;
        ft_wr      <= 1'b1;
        dout_valid <= 1'b0;
        dout       <= 32'h00000000;
    end

    // The reference ties SIWU# inactive and never changes it.  This board brings
    // out WAKEUP# rather than SIWU#; same treatment, and driven rather than left
    // floating.
    assign ft_wakeup = 1'b1;

    localparam [3:0] S_IDLE         = 4'h0;
    localparam [3:0] S_RX_WAIT1     = 4'h2;
    localparam [3:0] S_RX_WAIT2     = 4'h3;
    localparam [3:0] S_RX_WAIT3     = 4'h4;
    localparam [3:0] S_RX_ACTIVE    = 4'h5;
    localparam [3:0] S_RX_COOLDOWN1 = 4'h6;
    localparam [3:0] S_RX_COOLDOWN2 = 4'h7;
    localparam [3:0] S_TX_WAIT1     = 4'h8;
    localparam [3:0] S_TX_WAIT2     = 4'h9;
    localparam [3:0] S_TX_ACTIVE    = 4'ha;
    localparam [3:0] S_TX_COOLDOWN1 = 4'hb;
    localparam [3:0] S_TX_COOLDOWN2 = 4'hc;

                        logic [31:0] DATA_OUT [2];
    (* KEEP = "TRUE" *) wire         FWD;
    // THE TRISTATE ENABLE, ONE FLOP PER BYTE LANE.  A single OE fanned out
    // to all thirty-six pads' T inputs from one fabric flop, and where the
    // placer happened to put that flop decided the ft_clk_12 group: build
    // gs_adbstat (2026-09-11) left it at -0.300 after routing, post-route
    // phys_opt then "adjusted clock skew" for it six times - six BUFGs
    // cascaded into the whole domain's clock - and moved the miss onto the
    // data pads' clock-to-out.  Four copies, one per lane of eight data
    // pads and its BE pad, let each sit by its pins.  The IOB T flop is
    // still not used: it shares a control set with DATA_OUT's output flop
    // and cannot be packed beside it (constr/ft601.xdc).  KEEP and the
    // equivalent-register attribute stop synthesis folding them back into
    // one.
    (* KEEP = "TRUE", EQUIVALENT_REGISTER_REMOVAL = "NO" *) logic [3:0] OE_lane = 4'b1111;
    (* KEEP = "TRUE" *) logic [1:0]  data_queue_count = 2'd0;
    (* KEEP = "TRUE" *) logic [3:0]  state            = S_IDLE;

    // TURNAROUND IDLE.  A burst in the direction opposite to the last one
    // starts only after the bus has sat in S_IDLE for TURN_IDLE cycles, on
    // top of the two cooldown cycles every burst already ends with.  Found
    // on hardware 2026-09-10: with the card's TX otherwise idle, a startup
    // burst of register requests - each reply a TX burst landing between
    // the host's next words - left ft601_msg_rx parsing the host's stream
    // one word out of step (the ROM's bytes announced as unknown message
    // types), the way other FT60x controllers' explicit turnaround states
    // suggest it would.  A same-direction restart is not a turnaround and
    // is not delayed, so TX throughput is untouched; while a turnaround is
    // pending the wanting direction keeps its place, so a busy TX cannot
    // starve RX of its turn.  Four is a proving number, not a tuned one.
    localparam [2:0] TURN_IDLE = 3'd4;
    logic        last_rx  = 1'b0;    // the direction of the last burst
    logic [2:0]  idle_cnt = 3'd0;    // consecutive cycles spent in S_IDLE
    wire         turn_ok  = (idle_cnt >= TURN_IDLE);

    // -------------------------------------------------------------------------
    // FT245 RX / DATA INPUT
    //
    // No byte swap.  The wire is little-endian end to end: ft_data[7:0] is the
    // low byte of the fabric word, both directions, and the host reads it with a
    // plain little-endian load.  The reference reversed the four bytes here; that
    // was pcileech's wire format, not the chip's.  Delete it in both directions
    // or neither - a one-sided change fails bench --verify on the first word.
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        dout_valid <= !rst && !ft_rxf && (state == S_RX_ACTIVE);
        dout       <= ft_data;
    end

    // -------------------------------------------------------------------------
    // FT245 TX / DATA OUTPUT
    //
    // OE drives the bus by DEFAULT and releases it only for RX, so the bus is not
    // turned around on every transmit burst.
    //
    // DATA_OUT + data_queue_count is a SKID BUFFER, not a redundant FIFO in
    // front of the async FIFO behind it.  It earns its place twice over:
    //
    //   1. It breaks the path from downstream-ready to upstream-pop.
    //      din_req_data is a function of data_queue_count ALONE, so the BRAM
    //      read enable never sees TXE#; TXE# reaches only FWD, which drives
    //      local flops.  Popping the async FIFO directly on TXE# instead is
    //      exactly the -5.216 ns path DERISK records as the root cause of the
    //      build-to-build flakiness: TXE# crossing the state machine
    //      combinationally into a FIFO pop within a half cycle.
    //
    //   2. DATA_OUT[0] is the IOB output register for ft_data.  A BRAM output
    //      cannot be packed into an IOB; this flop can, and is.
    //
    // TWO registers, which is the minimum that works, and the reference's five
    // were inherited slack rather than a requirement: its FIFO Generator core has
    // read latency to cover, where our XPM FIFO is FWFT at zero latency and hands
    // over a word the same cycle it is asked.
    //
    // Why not one.  Sustaining a word per cycle from a single register means
    // popping the FIFO on the cycle its word is consumed - that is FWD, which is
    // gated by TXE#, so the BRAM read enable would see TXE# again.  Popping only
    // when empty keeps TXE# out but then forwards one word every TWO cycles: half
    // rate, ~200 MB/s against the 335 measured.  One skid entry behind the output
    // register buys both.  With a request on count <= 1, a request and a FWD
    // cancel at count 1, so it parks there and forwards every cycle.
    //
    // Depth is therefore load-bearing in both directions - too few costs
    // throughput or timing, too many is dead flops - and the request window must
    // include 0 or the queue cannot load from empty and TX deadlocks outright.
    // See din_req_data below; that is not hypothetical, it happened.
    //
    // It is still not a textbook valid/ready skid buffer, because TXE# is not
    // AXI-ready: ft_wr is asserted SPECULATIVELY in S_TX_WAIT2, a cycle before
    // S_TX_ACTIVE consumes anything, and that lead is what reaches full
    // throughput.  Mapping WR#/TXE# onto valid/ready is a near neighbour of the
    // "acknowledge-based pop" listed in the header among the divergences that
    // each produced a bug.
    // -------------------------------------------------------------------------

    genvar gl;
    generate
        for (gl = 0; gl < 4; gl = gl + 1) begin : g_oe_lane
            assign ft_be[gl]              = OE_lane[gl] ? 1'b1 : 1'bz;
            assign ft_data[8*gl+7:8*gl]   = OE_lane[gl] ? DATA_OUT[0][8*gl+7:8*gl] : 8'hzz;
        end
    endgenerate
    // Request whenever there is room for one more, INCLUDING when empty.  The
    // reference requests only at count == 2 or 3 and reaches that window from
    // ABOVE - its five-DWORD preload starts the count at 5 and FWD drains it into
    // range.  Delete the preload and the count starts at 0, which cannot reach
    // 2..3: a request needs count 2..3, count only rises on a request, and FWD
    // only fires on a non-empty queue.  The queue never loads, the FSM never
    // leaves S_IDLE, and TX deadlocks with the FIFO backed up behind it.
    // Measured on hardware: words_sent frozen, every host read timing out, zero
    // bytes moved.  sim/run_ft601_fifo_tb.sh reproduces it in 20 us.
    //
    // A function of registered state ALONE - no ft_txe - which is the property
    // that keeps the pad signal out of the BRAM read-enable path.
    assign din_req_data = !rst && (data_queue_count <= 2'd1);
    assign FWD          = !rst && !ft_txe && (data_queue_count != 2'd0) && (state == S_TX_ACTIVE);

    // Exports for the message layer.  fwd is the blocks-to-chip pulse, NOT
    // din_wr_en: din_wr_en counts blocks entering the skid buffer, and the two
    // differ by up to two blocks at the end of a run - which is exactly when the
    // heartbeat decision gets made.
    assign fwd     = FWD;
    assign q_empty = (data_queue_count == 2'd0);
    assign dbg_state  = state;
    assign dbg_qcount = data_queue_count;
    assign in_rx   = (state == S_RX_WAIT1)     || (state == S_RX_WAIT2)  ||
                     (state == S_RX_WAIT3)     || (state == S_RX_ACTIVE) ||
                     (state == S_RX_COOLDOWN1) || (state == S_RX_COOLDOWN2);

    // The reference reloads five 0x66665555 DWORDs here whenever the queue has
    // been empty for 15 cycles - its errata workaround, padding every idle stream
    // so a transfer never ends on a 1024-byte boundary.  It is gone.  This design
    // handles the errata at the message layer instead: the transmitter inserts a
    // heartbeat frame when it goes idle on a boundary (see docs/PROTOCOL.md and
    // ft601_top), which is a real frame the receiver parses rather than a magic
    // constant it must filter by value - and real payload can legitimately be
    // 0x66665555.
    //
    // The queue therefore starts and returns to EMPTY, with no preload.  That is
    // safe only because FWD is gated on data_queue_count != 0 and the FSM leaves
    // S_IDLE only on data_queue_count > 0: DATA_OUT is never forwarded until real
    // data has been loaded into it, so its power-on contents are don't-care.
    always_ff @(posedge clk) begin
        if (rst) begin
            data_queue_count <= 2'd0;
        end else begin
            data_queue_count <= data_queue_count + (din_wr_en ? 2'd1 : 2'd0) - (FWD ? 2'd1 : 2'd0);

            // Skid to the output register when the word there is being consumed.
            // Only reachable at count 2, and a request cannot land at count 2, so
            // this never races the write below for DATA_OUT[0].
            if (FWD && (data_queue_count > 2'd1)) DATA_OUT[0] <= DATA_OUT[1];

            // A request implies count <= 1, so the incoming word goes straight to
            // the output register when that register is empty (count 0) or is
            // being drained this cycle (count 1 with FWD), and to the skid entry
            // otherwise.
            if (din_wr_en) begin
                if (FWD || (data_queue_count == 2'd0)) DATA_OUT[0] <= din;
                else                                   DATA_OUT[1] <= din;
            end
        end
    end

    // -------------------------------------------------------------------------
    // FT245 main control
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        OE_lane <= {4{(rst || ft_rxf || ((state != S_RX_ACTIVE)    && (state != S_RX_WAIT3) &&
                                         (state != S_RX_WAIT2)     && (state != S_RX_COOLDOWN1) &&
                                         (state != S_RX_COOLDOWN2)))}};
        ft_oe <= (rst || ft_rxf || ((state != S_RX_ACTIVE)    && (state != S_RX_WAIT3) &&
                                    (state != S_RX_WAIT2)));
        ft_rd <= (rst || ft_rxf || ((state != S_RX_ACTIVE)    && (state != S_RX_WAIT3)));
        ft_wr <= !(!rst && !ft_txe && ((state == S_TX_WAIT2) ||
                                       ((state == S_TX_ACTIVE) &&
                                        (din_wr_en || (data_queue_count > 2'd1)))));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            idle_cnt <= 3'd0;
            last_rx  <= 1'b0;
        end else begin
            idle_cnt <= (state != S_IDLE) ? 3'd0 : (turn_ok ? idle_cnt : idle_cnt + 3'd1);
            if (state == S_RX_WAIT1) last_rx <= 1'b1;
            if (state == S_TX_WAIT1) last_rx <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                // RX is prioritised above TX when both are available.  A
                // change of direction waits out the turnaround idle (above);
                // the direction that is waiting holds the bus idle meanwhile.
                S_IDLE:
                    if (!ft_rxf) begin
                        if (last_rx || turn_ok)                     state <= S_RX_WAIT1;
                    end else if (!ft_txe && (data_queue_count > 2'd0)) begin
                        if (!last_rx || turn_ok)                    state <= S_TX_WAIT1;
                    end

                // RX.  The receiver is assumed never full; if it is, data is
                // still received and lost.
                S_RX_WAIT1:     state <= ft_rxf ? S_RX_COOLDOWN1 : S_RX_WAIT2;
                S_RX_WAIT2:     state <= ft_rxf ? S_RX_COOLDOWN1 : S_RX_WAIT3;
                S_RX_WAIT3:     state <= ft_rxf ? S_RX_COOLDOWN1 : S_RX_ACTIVE;
                S_RX_ACTIVE:    state <= ft_rxf ? S_RX_COOLDOWN1 : S_RX_ACTIVE;
                S_RX_COOLDOWN1: state <= S_RX_COOLDOWN2;
                S_RX_COOLDOWN2: state <= S_IDLE;

                // TX.
                S_TX_WAIT1:     state <= ft_txe ? S_TX_COOLDOWN1 : S_TX_WAIT2;
                S_TX_WAIT2:     state <= ft_txe ? S_TX_COOLDOWN1 : S_TX_ACTIVE;
                S_TX_ACTIVE:    state <= (ft_txe || (!din_wr_en && (data_queue_count <= 2'd1)))
                                            ? S_TX_COOLDOWN1 : S_TX_ACTIVE;
                S_TX_COOLDOWN1: state <= S_TX_COOLDOWN2;
                S_TX_COOLDOWN2: state <= S_IDLE;

                default:        state <= S_IDLE;
            endcase
        end
    end

endmodule
