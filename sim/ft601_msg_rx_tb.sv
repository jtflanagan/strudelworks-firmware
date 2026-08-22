`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_msg_rx_tb - host->card frame parsing, and the watchdog on top of it.
//
// Two things are being checked and they are different in kind:
//
//   the parser  decodes headers, skips payload, and reports an unknown type
//               rather than trying to carry on
//   the watchdog fires only when armed and only when genuinely starved, and is
//               kicked by ANY message rather than only by heartbeats
//
// The watchdog uses a short timeout here so the test runs in milliseconds rather
// than seconds; the real one is 1 s at 100 MHz.
//
// Stimulus is driven on the NEGEDGE throughout - driving inputs at the active
// edge races the DUT's own sampling and produces results that look like DUT bugs.
// That cost real time in ft601_fifo_tb; see its header.
//////////////////////////////////////////////////////////////////////////////////

module ft601_msg_rx_tb;

    localparam integer WD_TIMEOUT = 1000;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---- RX FIFO model -------------------------------------------------------
    reg [31:0] q [0:1023];
    integer    q_wr = 0, q_rd = 0;

    wire fifo_rd_en;

    // Continuous assigns, NOT always @(*): iverilog does not evaluate an @(*)
    // block until something in its sensitivity list changes, so before the first
    // push these would still be X - and `wait (fifo_empty)` on an X blocks
    // forever.  Same trap as ft601_fifo_tb, different shape.
    wire        fifo_empty = (q_rd >= q_wr);
    wire [31:0] fifo_dout  = (q_rd < q_wr) ? q[q_rd] : 32'hdeadbeef;

    always @(posedge clk) if (!rst && fifo_rd_en) q_rd <= q_rd + 1;

    task push(input [31:0] w);
        begin q[q_wr] = w; q_wr = q_wr + 1; end
    endtask

    // Header: len in [7:0], type in [15:8], free in [31:16].
    task push_hdr(input [7:0] len, input [7:0] ty, input [15:0] free);
        begin push({free, ty, len}); end
    endtask

    // ---- DUT -----------------------------------------------------------------
    wire        msg_valid, pay_valid, frame_error;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;

    ft601_msg_rx dut (
        .clk (clk), .rst (rst),
        .fifo_dout (fifo_dout), .fifo_empty (fifo_empty), .fifo_rd_en (fifo_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type),
        .msg_free (msg_free), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .frame_error (frame_error)
    );

    // ---- watchdog, wired the way snoop_top will wire it -----------------------
    wire wd_arm    = msg_valid && (msg_type == 8'h11) && msg_free[0];
    wire wd_disarm = msg_valid && (msg_type == 8'h11) && !msg_free[0];
    wire wd_kick   = msg_valid;
    wire wd_armed, wd_fired;

    link_watchdog #(.TIMEOUT_CYCLES (WD_TIMEOUT)) wd (
        .clk (clk), .rst (rst),
        .arm (wd_arm), .disarm (wd_disarm), .kick (wd_kick),
        .armed (wd_armed), .fired (wd_fired)
    );

    // ---- observers -----------------------------------------------------------
    integer n_msgs = 0, n_pay = 0, errors = 0;
    integer n_enable = 0, n_disable = 0;
    reg [31:0] last_pay = 32'd0;

    always @(posedge clk) if (!rst) begin
        if (msg_valid) begin
            n_msgs = n_msgs + 1;
            if (msg_type == 8'h11) begin
                if (msg_free[0]) n_enable  = n_enable + 1;
                else             n_disable = n_disable + 1;
            end
        end
        if (pay_valid) begin n_pay = n_pay + 1; last_pay = pay_data; end
    end

    task check(input integer got, input integer want, input string what);
        begin
            if (got !== want) begin
                $display("FAIL: %s - expected %0d, got %0d", what, want, got);
                errors = errors + 1;
            end else begin
                $display("  ok: %s = %0d", what, got);
            end
        end
    endtask

    task drain;  // let the parser consume everything queued
        begin
            @(posedge clk);
            wait (fifo_empty);
            repeat (4) @(posedge clk);
        end
    endtask

    integer i;

    initial begin
        $display("ft601_msg_rx_tb: host->card framing and watchdog");

        repeat (10) @(negedge clk);
        rst = 1'b0;
        drain;

        // --- heartbeats: a bare IDLE frame, the same 4 bytes the card sends ----
        for (i = 0; i < 5; i = i + 1) push(32'h00000000);
        drain;
        check(n_msgs, 5, "five IDLE heartbeats decoded");
        check(n_pay,  0, "heartbeats carry no payload");

        // --- BUS_ENABLE with flags --------------------------------------------
        push_hdr(8'd0, 8'h11, 16'h0001);          // enable, synthetic source
        drain;
        check(n_enable, 1, "BUS_ENABLE(enable=1) decoded");
        if (!wd_armed) begin
            $display("FAIL: watchdog not armed by BUS_ENABLE(1)");
            errors = errors + 1;
        end else $display("  ok: watchdog armed by BUS_ENABLE(1)");

        // --- ANY message kicks the watchdog, not just heartbeats --------------
        // Starve it to just short of expiry, then send a BUS_ENABLE and confirm
        // the count restarted rather than expiring.
        repeat (WD_TIMEOUT - 100) @(posedge clk);
        if (wd_fired) begin
            $display("FAIL: watchdog fired early");
            errors = errors + 1;
        end
        push_hdr(8'd0, 8'h11, 16'h0001);
        drain;
        repeat (WD_TIMEOUT - 100) @(posedge clk);
        if (wd_fired) begin
            $display("FAIL: a BUS_ENABLE did not kick the watchdog");
            errors = errors + 1;
        end else $display("  ok: any message kicks the watchdog, not only IDLE");

        // --- and it does fire when genuinely starved ---------------------------
        repeat (WD_TIMEOUT + 50) @(posedge clk);
        if (!wd_fired) begin
            $display("FAIL: watchdog did not fire on a starved link");
            errors = errors + 1;
        end else $display("  ok: watchdog fired on a starved link");

        // --- payload is presented, and counted correctly -----------------------
        // A frame with payload: the parser must present each block once and then
        // treat the NEXT block as a header again.
        rst = 1'b1; @(negedge clk); rst = 1'b0; drain;
        n_msgs = 0; n_pay = 0;
        push_hdr(8'd4, 8'h00, 16'h0000);          // IDLE with 4 filler blocks
        for (i = 0; i < 4; i = i + 1) push(32'h1100_0000 + i);
        push(32'h00000000);                        // then a plain heartbeat
        drain;
        check(n_msgs, 2, "header, 4 payload, header");
        check(n_pay,  4, "payload blocks presented");
        if (last_pay !== 32'h1100_0003) begin
            $display("FAIL: last payload was %08x, expected 11000003", last_pay);
            errors = errors + 1;
        end else $display("  ok: payload contents intact");

        // --- clean stop disarms ------------------------------------------------
        push_hdr(8'd0, 8'h11, 16'h0001);          // enable  -> armed
        drain;
        push_hdr(8'd0, 8'h11, 16'h0000);          // disable -> disarmed
        drain;
        check(n_disable, 1, "BUS_ENABLE(enable=0) decoded");
        if (wd_armed) begin
            $display("FAIL: clean stop left the watchdog armed");
            errors = errors + 1;
        end else $display("  ok: clean stop disarmed the watchdog");

        // And a disarmed watchdog must never fire, however long it is starved.
        repeat (WD_TIMEOUT * 3) @(posedge clk);
        if (wd_fired) begin
            $display("FAIL: disarmed watchdog fired - this would reset an idle link");
            errors = errors + 1;
        end else $display("  ok: disarmed watchdog stays quiet");

        // --- an unknown type is a desync, not something to skip ----------------
        if (frame_error) begin
            $display("FAIL: frame_error set before any bad frame");
            errors = errors + 1;
        end
        push_hdr(8'd0, 8'h7e, 16'h0000);          // no such type
        drain;
        if (!frame_error) begin
            $display("FAIL: unknown type did not raise frame_error");
            errors = errors + 1;
        end else $display("  ok: unknown type raised frame_error");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #10_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
