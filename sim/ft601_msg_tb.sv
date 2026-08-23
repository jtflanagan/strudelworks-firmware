`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_msg_tb - the heartbeat rule, against the case list in docs/PROTOCOL.md.
//
// Runs the real ft601_msg_tx against the real ft601_fifo, with a model of the
// chip on the far side, so the thing under test is the whole transmit path and
// not just the counter in isolation.  What matters is a single number: how many
// heartbeats came out, for each way of stopping.
//
//   256 blocks then idle   ->  exactly 1   (the errata case: buffer left empty)
//   255 or 257 then idle   ->  0           (partial buffer dispatches itself)
//   TXE# stall mid-buffer  ->  0           (chip busy is not chip idle)
//   stall ON a boundary    ->  1, deferred until TXE# comes back
//   stall mid-message      ->  0           (would corrupt the frame)
//   traffic flowing        ->  0           (costs nothing while busy)
//   dead link              ->  the idle timer, and only then
//   BUSY link, no dispatch ->  the idle timer too - it is a backstop against
//                              lost dispatches, and those happen while data is
//                              flowing, so it must not be gated on a quiet FIFO
//
// Stimulus changes on the NEGEDGE throughout.  Driving ft_txe at the active edge
// races the DUT's own sampling and produces phantom results - see the header of
// ft601_fifo_tb, where that cost real time.
//////////////////////////////////////////////////////////////////////////////////

module ft601_msg_tb;

    localparam integer IDLE_TICKS = 2000;   // short, so the timer test is quick

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---- chip side ----------------------------------------------------------
    wire [3:0]  ft_be;
    wire [31:0] ft_data;
    reg         ft_rxf = 1'b1;
    reg         ft_txe = 1'b0;
    wire        ft_oe, ft_rd, ft_wr, ft_wakeup;

    wire [31:0] dout;
    wire        dout_valid;
    wire [31:0] din;
    wire        din_wr_en, din_req_data;
    wire        fwd, q_empty, in_rx;

    ft601_fifo u_ctrl (
        .clk (clk), .rst (rst),
        .ft_be (ft_be), .ft_data (ft_data),
        .ft_rxf (ft_rxf), .ft_txe (ft_txe),
        .ft_oe (ft_oe), .ft_rd (ft_rd), .ft_wr (ft_wr), .ft_wakeup (ft_wakeup),
        .dout (dout), .dout_valid (dout_valid),
        .din (din), .din_wr_en (din_wr_en), .din_req_data (din_req_data),
        .fwd (fwd), .q_empty (q_empty), .in_rx (in_rx)
    );

    // ---- message layer ------------------------------------------------------
    reg  [31:0] fifo_dout = 32'd0;
    reg         fifo_empty = 1'b1;
    wire        fifo_rd_en;
    wire        hb_sent;

    // 0 = the built-in IDLE_TICKS, which is what every pre-existing case below
    // expects; the shift cases drive it explicitly.
    logic [3:0] idle_shift = 4'd0;

    ft601_msg_tx #(.IDLE_TICKS (IDLE_TICKS)) dut (
        .clk (clk), .rst (rst),
        .fifo_dout (fifo_dout), .fifo_empty (fifo_empty), .fifo_rd_en (fifo_rd_en),
        .idle_shift (idle_shift),
        .din (din), .din_wr_en (din_wr_en), .din_req_data (din_req_data),
        .fwd (fwd), .q_empty (q_empty), .in_rx (in_rx),
        .hb_sent (hb_sent)
    );

    // ---- source: a queue of blocks the test pushes in -----------------------
    // Modelling the async FIFO: fifo_dout must be valid whenever !fifo_empty,
    // and a read pops.  Continuous assign, never always @(*) - see ft601_fifo_tb.
    reg [31:0] q [0:8192];
    integer    q_wr = 0, q_rd = 0;

    always @(*) begin
        fifo_empty = (q_rd >= q_wr);
        fifo_dout  = (q_rd < q_wr) ? q[q_rd] : 32'hdeadbeef;
    end

    always @(posedge clk) if (!rst && fifo_rd_en) q_rd <= q_rd + 1;

    task push_block(input [31:0] w);
        begin q[q_wr] = w; q_wr = q_wr + 1; end
    endtask

    // A message: header with len = payload blocks, then that many payload blocks.
    task push_msg(input [7:0] len, input [7:0] mtype);
        integer k;
        begin
            push_block({16'h0000, mtype, len});
            for (k = 0; k < len; k = k + 1) push_block(32'h1000_0000 + k);
        end
    endtask

    // Exactly n blocks of traffic, as whole messages, without landing a partial
    // one.  n must be a multiple of 16 here; 15 payload + 1 header = 16 blocks.
    task push_blocks(input integer n);
        integer m;
        begin
            for (m = 0; m < n / 16; m = m + 1) push_msg(8'd15, 8'h10);
        end
    endtask

    // ---- chip model ---------------------------------------------------------
    integer chip_words = 0;
    integer hb_count   = 0;
    integer hb_marker  = 0;

    always @(posedge clk) begin
        if (!rst && !ft_wr && !ft_txe) chip_words = chip_words + 1;
        if (!rst && hb_sent)           hb_count   = hb_count + 1;
    end

    // Was the source ever dry?  The busy-link case below is only a test of the
    // thing it means to test if the FIFO stayed fed for the whole window - a
    // moment of fifo_empty would have let the OLD gate pass too.
    reg  watch_fed = 1'b0;
    reg  went_dry  = 1'b0;
    always @(posedge clk) if (watch_fed && fifo_empty) went_dry <= 1'b1;

    // ---- helpers ------------------------------------------------------------
    integer errors = 0;

    task expect_hb(input integer want, input string what);
        begin
            if ((hb_count - hb_marker) !== want) begin
                $display("FAIL: %s - expected %0d heartbeat(s), got %0d",
                         what, want, hb_count - hb_marker);
                errors = errors + 1;
            end else begin
                $display("  ok: %s -> %0d heartbeat(s)", what, want);
            end
            hb_marker = hb_count;
        end
    endtask

    // Let everything queued actually DRAIN and the link go idle, without waiting
    // long enough for the idle timer to fire.  A fixed delay is wrong here: 512
    // blocks take 512 cycles to hand over, so a short wait means the link is
    // still busy and no dispatch ever happens.
    task settle;
        begin
            // One edge first: push_blocks fills the array in zero time, and
            // `wait` can evaluate before the combinational fifo_empty has
            // re-run, so the wait would fall straight through and settle on a
            // link that has not started draining yet.
            @(posedge clk);
            wait (fifo_empty && q_empty);
            repeat (60) @(posedge clk);
        end
    endtask

    integer i;

    initial begin
        $display("ft601_msg_tb: heartbeat insertion");

        repeat (10) @(negedge clk);
        rst = 1'b0;
        settle;
        hb_marker = hb_count;

        // --- case 2: stop with the chip's buffer exactly empty ---------------
        // 256 blocks fills one 1 KB buffer exactly.  Nothing left to dispatch,
        // so without a heartbeat the host's read would never terminate.
        push_blocks(256);
        settle;
        expect_hb(1, "256 blocks then idle");

        // --- case 1: stop with a partial buffer ------------------------------
        // 240 blocks leaves 240 in the chip; it dispatches those on idle and the
        // read terminates by itself.  A heartbeat here would be pure waste.
        push_blocks(240);
        settle;
        expect_hb(0, "240 blocks then idle");

        // 512 = two whole buffers.  Still lands empty, still needs exactly one.
        push_blocks(512);
        settle;
        expect_hb(1, "512 blocks then idle");

        // --- traffic flowing: costs nothing ----------------------------------
        // Keep the source hot across a boundary; the rule only fires on idle.
        for (i = 0; i < 32; i = i + 1) push_msg(8'd15, 8'h10);
        repeat (100) @(posedge clk);
        push_blocks(256);
        settle;
        // 512 + 256 = 768 total, a whole number of buffers, so one at the end.
        expect_hb(1, "continuous traffic across a boundary");

        // --- case 4: TXE# stall mid-buffer -----------------------------------
        // The chip goes busy partway through and comes back.  It has NOT
        // dispatched, so the count must survive and no heartbeat may appear.
        push_blocks(128);
        repeat (40) @(posedge clk);
        @(negedge clk); ft_txe = 1'b1;
        repeat (60) @(posedge clk);
        @(negedge clk); ft_txe = 1'b0;
        push_blocks(128);
        settle;
        expect_hb(1, "TXE# stall mid-buffer, 256 total");

        // --- case 8: source stalls mid-message on a boundary -----------------
        // Push 255 blocks as whole messages, then a header promising payload
        // that has not arrived.  blocks_left != 0, so no heartbeat may be
        // inserted - it would corrupt the frame - even though the count is on a
        // boundary once the header goes out.
        push_blocks(240);
        for (i = 0; i < 15; i = i + 1) push_msg(8'd0, 8'h10);   // 15 one-block msgs
        push_block({16'h0000, 8'h10, 8'd4});                    // header, 4 to come
        settle;
        expect_hb(0, "stalled mid-message on a boundary");

        // Finish the message; the count moves off the boundary and it drains.
        for (i = 0; i < 4; i = i + 1) push_block(32'h2000_0000 + i);
        settle;
        expect_hb(0, "message completed, no longer on a boundary");

        // --- case 9 on a BUSY link (regression) ------------------------------
        // Every case above stops the source to provoke the heartbeat, so every
        // one of them tests the timer on a quiet link - and the timer used to be
        // reset by !fifo_empty, which is true on exactly those links and false
        // on none of them.  The bug lived in the gap: with data queued, the 100
        // us backstop was held in reset by the traffic it exists to rescue, and
        // "case 9 unsticks it" became "case 9 unsticks it in milliseconds, if
        // the chip's buffer happens to fill by other means".
        //
        // So: hold the chip off past a full idle window while the source keeps
        // producing.  Nothing reaches the host, fifo_empty is never true, and a
        // heartbeat must still be owed by the end of it - emitted as soon as
        // TXE# allows, like any other deferred debt (case 6).
        // The heartbeat has to be COUNTED before the link goes quiet, or the
        // ordinary boundary rule answers for it and the case proves nothing:
        // an earlier draft ended in settle, and it passed against the very bug
        // it was written to catch.  So queue far more than drains in the check
        // window, and look while the FIFO is still backed up - the deferred
        // debt goes out at the first message boundary after TXE# returns, some
        // 500 blocks before any dispatch can occur.
        push_blocks(128);
        repeat (20) @(posedge clk);
        @(negedge clk); ft_txe = 1'b1;
        push_blocks(512);               // source runs on; the FIFO backs up
        went_dry = 1'b0; watch_fed = 1'b1;
        repeat (IDLE_TICKS + 200) @(posedge clk);
        if (went_dry) begin
            $display("FAIL: busy-link stimulus let the FIFO go empty - the case is void");
            errors = errors + 1;
        end
        @(negedge clk); ft_txe = 1'b0;
        repeat (200) @(posedge clk);
        watch_fed = 1'b0;
        if (went_dry) begin
            $display("FAIL: the FIFO drained inside the check window - the case is void");
            errors = errors + 1;
        end
        expect_hb(1, "busy link, nothing dispatched for a full idle window");

        // Drain the rest.  Where that leaves the chip's buffer depends on every
        // block pushed since reset, so the heartbeat this settle may or may not
        // owe is not this case's to predict - re-mark, and let the dead-link
        // case below start from a clean count.
        settle;
        // --- case 10 / runtime heartbeat period ------------------------------
        // idle_shift halves the period per step, so over a fixed dead-link
        // window a shift of 2 must produce about four times the heartbeats.
        // Ratios rather than exact counts: the window does not divide evenly
        // and the first fire lands wherever the counter happened to be.
        begin : shift_case
            integer base_fires, fast_fires;
            idle_shift = 4'd0;
            hb_marker = hb_count;
            repeat (IDLE_TICKS * 8) @(posedge clk);
            base_fires = hb_count - hb_marker;

            idle_shift = 4'd2;                 // period / 4
            repeat (20) @(posedge clk);        // let the synchroniser-free path settle
            hb_marker = hb_count;
            repeat (IDLE_TICKS * 8) @(posedge clk);
            fast_fires = hb_count - hb_marker;

            if (fast_fires < base_fires * 3) begin
                $display("FAIL: idle_shift=2 gave %0d heartbeat(s), shift=0 gave %0d; expected about 4x", fast_fires, base_fires);
                errors = errors + 1;
            end else begin
                $display("  ok: idle_shift 0 -> %0d, 2 -> %0d heartbeat(s) over the same window", base_fires, fast_fires);
            end

            // And back to the default, to prove it is not a one-way latch.
            idle_shift = 4'd0;
            repeat (20) @(posedge clk);
            hb_marker = hb_count;
            repeat (IDLE_TICKS * 8) @(posedge clk);
            if ((hb_count - hb_marker) > base_fires + 1) begin
                $display("FAIL: shift did not return to the default period");
                errors = errors + 1;
            end else begin
                $display("  ok: shift back to 0 restores the default period");
            end
        end
        hb_marker = hb_count;

        // --- case 9 / idle timer ---------------------------------------------
        // A dead link still has to produce something, or a speculative host read
        // waits out its timeout.  Nothing queued, so this is the timer alone.
        repeat (IDLE_TICKS * 3) @(posedge clk);
        if ((hb_count - hb_marker) < 1) begin
            $display("FAIL: idle timer never fired on a dead link");
            errors = errors + 1;
        end else begin
            $display("  ok: idle timer fired %0d time(s) on a dead link",
                     hb_count - hb_marker);
        end
        hb_marker = hb_count;

        // --- verdict ---------------------------------------------------------
        $display("");
        $display("  %0d blocks reached the chip, %0d heartbeats total",
                 chip_words, hb_count);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
