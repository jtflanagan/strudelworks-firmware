`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_fifo_tb - does the controller actually move data, from a cold start?
//
// This exists because of a real bug, found on hardware at a cost of a build, a
// flash and a bench run, when it was catchable here in under a second.
//
// Removing the reference's five-DWORD 0x66665555 preload left the output queue
// starting EMPTY.  The reference requests refills only at data_queue_count 2 or
// 3, and reaches that window from ABOVE - the preload starts the count at 5 and
// FWD drains it into range.  From 0 the window is unreachable: a request needs
// count 2..3, count only rises on a request, and FWD only fires on a non-empty
// queue.  The queue never loaded, the FSM never left S_IDLE, and TX deadlocked -
// zero bytes to the host, every read timing out, throughput exactly 0.
//
// The lesson generalises past that one fix: this controller can be perfectly
// well-formed and still never start.  So the assertion that matters is the dumb
// one - words in, same words out, in order, from reset, with no preload to prime
// anything.
//
// Models the chip's side of FT245 synchronous FIFO: TXE# is the chip's "you may
// write", and a word is accepted on any clock where WR# and TXE# are both low.
//
// TWO TESTBENCH TRAPS, both of which cost real time here and both of which look
// exactly like DUT bugs:
//
//   1. Drive din with a continuous assign, never `always @(*)`.  iverilog does
//      not evaluate an @(*) block until something in its sensitivity list
//      changes, so the first word is driven X and lands in DATA_OUT[0] before
//      the source counter ever moves.  Presents as a corrupt first word.
//
//   2. Change stimulus on the NEGEDGE, never at the active edge.  Setting ft_txe
//      at a posedge races the DUT's own sampling: the DUT's flops see the old
//      value and advance the queue while the checker sees the new one and does
//      not count the word.  Presents as words vanishing at burst boundaries -
//      indistinguishable, at a glance, from the real bug class this file has a
//      history of.  The conservation counter is what tells them apart: a race
//      loses words at the OBSERVER, so written-queued still equals forwarded
//      once the race is removed.
//////////////////////////////////////////////////////////////////////////////////

module ft601_fifo_tb;

    localparam integer N_WORDS = 2000;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                    // 100 MHz, the real ft_clk rate

    // ---- DUT ----------------------------------------------------------------
    wire [3:0]  ft_be;
    wire [31:0] ft_data;
    reg         ft_rxf = 1'b1;               // no RX traffic in this test
    reg         ft_txe = 1'b0;               // chip ready by default
    wire        ft_oe, ft_rd, ft_wr, ft_wakeup;

    wire [31:0] dout;
    wire        dout_valid;
    wire [31:0] din;
    wire        din_wr_en;
    wire        din_req_data;

    ft601_fifo dut (
        .clk (clk), .rst (rst),
        .ft_be (ft_be), .ft_data (ft_data),
        .ft_rxf (ft_rxf), .ft_txe (ft_txe),
        .ft_oe (ft_oe), .ft_rd (ft_rd), .ft_wr (ft_wr), .ft_wakeup (ft_wakeup),
        .dout (dout), .dout_valid (dout_valid),
        .din (din), .din_wr_en (din_wr_en), .din_req_data (din_req_data)
    );

    // ---- source: an incrementing counter, always ready -----------------------
    // Stands in for ft601_top's async FIFO with data available.  The controller
    // pulls with din_req_data; we answer every request immediately, which is what
    // a non-empty FWFT FIFO at zero read latency does.
    reg [31:0] next_word = 32'd1;

    // din must be valid in the same cycle the controller consumes it.  A
    // continuous assign, NOT always @(*): iverilog does not evaluate an @(*)
    // block until something in its sensitivity list changes, so the first word
    // would be driven X and land in DATA_OUT[0] before next_word ever moved.
    assign din = next_word;

    always @(posedge clk) begin
        if (rst)            next_word <= 32'd1;
        else if (din_wr_en) next_word <= next_word + 32'd1;
    end

    // ft601_fifo drives din_wr_en itself in the real design (ft601_top wires it
    // from the FIFO read enable).  Here the controller's request IS the write.
    assign din_wr_en = din_req_data && !rst;

    // ---- contract check ------------------------------------------------------
    // The FT245 contract is: the chip latches the bus on every rising edge where
    // WR# and TXE# are both low.  The controller's internal FWD is what advances
    // the queue.  If those two ever disagree, a word is dropped or sent twice -
    // the exact class of burst-boundary bug this file has a history of.  Assert
    // they are the same signal, cycle for cycle.
    wire chip_latches = !ft_wr && !ft_txe;
    integer contract_errors = 0;

    // Conservation: every word the source hands over is either still queued or
    // has reached the chip.  written == forwarded + queued, always.
    integer n_written = 0;
    always @(posedge clk) if (!rst && din_wr_en) n_written = n_written + 1;

    // Throughput.  A shallower skid buffer is only correct if it still forwards a
    // word EVERY cycle with the chip ready and the source hot.  One entry cannot:
    // it would have to pop the FIFO on FWD (putting TXE# back on the BRAM read
    // enable) or pop only when empty, which halves the rate.  Measure the steady
    // state between two marks, well clear of the cold start and the stalls.
    integer cyc = 0;
    integer mark_lo = 0, mark_hi = 0;
    always @(posedge clk) if (!rst) cyc = cyc + 1;

    always @(posedge clk) begin
        if (!rst && (chip_latches !== dut.FWD)) begin
            contract_errors = contract_errors + 1;
            if (contract_errors <= 5) begin
                $display("  CONTRACT: chip latches=%b but FWD=%b (state=%h qcnt=%0d)",
                         chip_latches, dut.FWD, dut.state, dut.data_queue_count);
            end
        end
    end

    // ---- sink: model the FT601 accepting words -------------------------------
    integer got = 0;
    integer errors = 0;
    reg [31:0] expect_word = 32'd1;

    always @(posedge clk) begin
        if (!rst && !ft_wr && !ft_txe) begin
            got = got + 1;
            if (ft_data !== expect_word) begin
                errors = errors + 1;
                if (errors <= 5) begin
                    $display("  MISMATCH at word %0d: expected %08x, got %08x  [state=%h qcnt=%0d txe=%b wren=%b src=%08x]",
                             got, expect_word, ft_data, dut.state,
                             dut.data_queue_count, ft_txe, din_wr_en, next_word);
                end
            end
            expect_word = ft_data + 32'd1;
            if (got == 100)  mark_lo = cyc;
            if (got == 1900) mark_hi = cyc;
        end
    end

    // ---- stimulus ------------------------------------------------------------
    integer stall_i;
    integer idle_words;

    initial begin
        $display("ft601_fifo_tb: cold start, no preload");

        repeat (10) @(negedge clk);
        rst = 1'b0;

        // 1. COLD START.  The whole point: from an empty queue, with no preload,
        //    does anything come out at all?
        fork : cold_start
            begin
                repeat (2000) @(posedge clk);
                $display("FAIL: no data forwarded within 2000 cycles of reset.");
                $display("      The controller never left S_IDLE - the output");
                $display("      queue never loaded from a cold, empty start.");
                $finish;
            end
            begin
                wait (got > 0);
                disable cold_start;
            end
        join

        $display("  cold start OK: first word forwarded");

        // 2. Sustained streaming with the chip always ready.
        wait (got >= N_WORDS);
        $display("  streamed %0d words", got);

        // 3. TXE# backpressure: the chip goes busy mid-stream and comes back.
        //    Nothing may be lost or duplicated across the stall.
        for (stall_i = 0; stall_i < 8; stall_i = stall_i + 1) begin
            @(negedge clk); ft_txe = 1'b1;
            repeat (3 + stall_i * 5) @(posedge clk);
            @(negedge clk); ft_txe = 1'b0;
            repeat (20) @(posedge clk);
        end
        $display("  survived %0d TXE# stalls, %0d words total", 8, got);

        // 4. Source starvation: stop answering requests, let the queue drain to
        //    empty, then resume.  This is the state the heartbeat logic keys off,
        //    and the controller has to restart from it - the same restart the
        //    cold-start case proves, but now mid-run.
        idle_words = got;
        @(negedge clk);
        force din_wr_en = 1'b0;
        repeat (200) @(posedge clk);
        if (got > idle_words) begin
            // Draining the last queued words is expected; it must then STOP.
            idle_words = got;
            repeat (100) @(posedge clk);
        end
        if (got != idle_words) begin
            $display("FAIL: still forwarding %0d words after the source went dry.",
                     got - idle_words);
            errors = errors + 1;
        end else begin
            $display("  went idle cleanly with a dry source");
        end
        @(negedge clk);
        release din_wr_en;

        fork : restart
            begin
                repeat (2000) @(posedge clk);
                $display("FAIL: did not restart after the source came back.");
                errors = errors + 1;
                disable restart;
            end
            begin
                wait (got > idle_words + 10);
                $display("  restarted after starvation");
                disable restart;
            end
        join

        // ---- verdict ---------------------------------------------------------
        $display("");
        $display("  steady-state rate: %0d words in %0d cycles", 1800, mark_hi - mark_lo);
        if ((mark_hi - mark_lo) > 1800 * 11 / 10) begin
            $display("FAIL: forwarding slower than one word per cycle - the skid");
            $display("      buffer cannot sustain full rate.");
            errors = errors + 1;
        end
        $display("  conservation: written=%0d forwarded=%0d queued=%0d  (written-queued=%0d)",
                 n_written, got, dut.data_queue_count, n_written - dut.data_queue_count);
        if (errors == 0 && contract_errors == 0) begin
            $display("PASS: %0d words forwarded, sequence intact, WR#/FWD agree.", got);
        end else begin
            $display("FAIL: %0d sequence error(s), %0d contract error(s), over %0d words.",
                     errors, contract_errors, got);
        end
        $finish;
    end

    // Global safety net so a hang is a failure, not a hung CI job.
    initial begin
        #2_000_000;
        $display("FAIL: timeout - the testbench never completed.");
        $finish;
    end

endmodule
