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

    ft601_msg_tx #(.IDLE_TICKS (IDLE_TICKS)) dut (
        .clk (clk), .rst (rst),
        .fifo_dout (fifo_dout), .fifo_empty (fifo_empty), .fifo_rd_en (fifo_rd_en),
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
