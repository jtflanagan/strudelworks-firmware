// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// no_slot_clock_tb - the No-Slot Clock behind a model of the sequencer's op
// timing and the real message parser.  sim/run_no_slot_clock_tb.sh.
//
// The op model is the TIGHTEST spacing accel_seq allows (rtl/no_slot_clock.sv,
// "Across clocks"): the core's address appears on clock A, the op's present
// on the stream at A+2, the byte is taken at A+3, the commit (fast_tick) is
// seen at A+4 - and the next op's address appears at A+4 too.  If the clock
// keeps up here it keeps up under the real dispatcher, whose gaps are wider.
//
// Every rule is checked against AppleWin's NoSlotClock.cpp: the reset read,
// the 64-bit key LSB first, the mismatch that disables writes until a reset
// read, the populate at the 64th bit, the 64 reads out (LSB first, D0), the
// wrap that ends the window, and a write sequence in the window that is
// simulated and changes nothing.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module no_slot_clock_tb;

    localparam [7:0] T_NSC_TIME = 8'h27;
    localparam [63:0] KEY = 64'h5CA33AC55CA33AC5;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---- host -> card: a FIFO the real parser reads -------------------------
    reg  [31:0] rx_mem [0:255];
    integer     rx_wr = 0, rx_rd = 0;
    wire        rx_empty = (rx_rd >= rx_wr);
    wire [31:0] rx_dout  = rx_empty ? 32'd0 : rx_mem[rx_rd];
    wire        rx_rd_en;
    always @(posedge clk) if (rx_rd_en && !rx_empty) rx_rd <= rx_rd + 1;
    task push_word(input [31:0] w);
        begin rx_mem[rx_wr] = w; rx_wr = rx_wr + 1; end
    endtask
    function [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction
    wire        msg_valid, pay_valid, unknown_valid;
    wire [7:0]  unknown_type, unknown_len;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;
    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .unknown_valid (unknown_valid), .unknown_type (unknown_type), .unknown_len (unknown_len)
    );
    task send_time(input [63:0] t);
        begin
            push_word(hdr(T_NSC_TIME, 8'd2, 16'd0));
            push_word(t[31:0]);
            push_word(t[63:32]);
            repeat (8) @(posedge clk);
            #1;
        end
    endtask

    // ---- the DUT -------------------------------------------------------------
    reg         enable = 1'b1;
    reg         q_nsc = 1'b0, q_rw = 1'b1, q_a2 = 1'b0, ovr_en = 1'b0;
    reg         u_present = 1'b0, u_ovr = 1'b0, commit = 1'b0;
    reg  [2:0]  u_addr_lo = 3'd0;
    wire        sub, sbit, time_loaded, ring_en, wr_en;
    wire [5:0]  cmp_idx, ring_idx;
    wire [7:0]  unlocks;
    wire [63:0] now_o;
    no_slot_clock dut (
        .clk (clk), .rst (rst), .enable (enable),
        .q_nsc (q_nsc), .q_rw (q_rw), .q_a2 (q_a2), .ovr_en (ovr_en),
        .u_present (u_present), .u_ovr (u_ovr), .u_addr_lo (u_addr_lo), .commit (commit),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .sub (sub), .sub_bit (sbit),
        .time_loaded (time_loaded), .ring_en_o (ring_en), .wr_en_o (wr_en),
        .cmp_idx_o (cmp_idx), .ring_idx_o (ring_idx), .unlocks_o (unlocks), .now_o (now_o)
    );

    // ---- the op model ----------------------------------------------------------
    // Called just after an edge (clock A); returns just after the edge that
    // begins A+4, with the commit up.  s/b: what the core would have seen.
    task op(input [15:0] addr, input rw, input page, input ovr, output s, output b);
        begin
            q_nsc = page; q_rw = rw; q_a2 = addr[2]; ovr_en = ovr;      // A
            @(posedge clk); #1; commit = 0;                              // A+1
            @(posedge clk); #1; u_present = 1; u_ovr = ovr; u_addr_lo = addr[2:0];  // A+2
            @(posedge clk); #1; u_present = 0; s = sub; b = sbit;         // A+3
            @(posedge clk); #1; commit = 1;                              // A+4
        end
    endtask
    task quiet;
        begin @(posedge clk); #1; commit = 0; @(posedge clk); #1; end
    endtask

    integer errors = 0;
    task check(input cond, input [255:0] what);
        begin
            if (!cond) begin
                $display("FAIL: %0s", what);
                errors = errors + 1;
            end
        end
    endtask

    // A driver's unlock: the reset read, then the key on A0, LSB first.
    // subs counts substitutions seen along the way (none expected).
    integer subs;
    task unlock(input page, input rw);
        integer i; reg s, b;
        begin
            op(16'hC304, 1'b1, page, 1'b0, s, b); subs = subs + s;
            for (i = 0; i < 64; i = i + 1) begin
                op(KEY[i] ? 16'hC301 : 16'hC300, rw, page, 1'b0, s, b); subs = subs + s;
            end
        end
    endtask
    // Read the 64 bits out; every read must substitute.
    task read_out(input page, output [63:0] got, output integer nsub);
        integer i; reg s, b;
        begin
            nsub = 0; got = 64'd0;
            for (i = 0; i < 64; i = i + 1) begin
                op(16'hC304, 1'b1, page, 1'b0, s, b);
                if (s) begin nsub = nsub + 1; got[i] = b; end
            end
        end
    endtask

    localparam [63:0] T1 = 64'h2609_0507_1341_2599;   // 2026-09-05 Sat 13:41:25.99
    localparam [63:0] T2 = 64'h2701_0102_0000_0000;   // 2027-01-01 Mon 00:00:00.00

    reg [63:0] got;
    integer    nsub, i;
    reg        s, b;

    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;
        repeat (4) @(posedge clk);
        #1;

        // 1. No time yet: the key never unlocks anything.
        $display("1. before a time arrives, the clock is not there");
        subs = 0;
        unlock(1'b1, 1'b1);
        read_out(1'b1, got, nsub);
        quiet;
        check(!time_loaded && unlocks == 8'd0 && nsub == 0 && subs == 0 && !ring_en,
              "no unlock and no substitution before the first NSC_TIME");

        // 2. The time arrives; a driver reads it back bit for bit.
        $display("2. the host's time, read out");
        send_time(T1);
        check(time_loaded && now_o == T1, "NSC_TIME landed whole");
        subs = 0;
        unlock(1'b1, 1'b1);
        quiet;
        check(ring_en && unlocks == 8'd1 && subs == 0, "the key unlocked the clock register, no substitution on the way");
        read_out(1'b1, got, nsub);
        quiet;
        check(nsub == 64, "every one of the 64 reads substituted D0");
        check(got == T1, "the 64 bits are the time, LSB first");
        check(!ring_en && ring_idx == 6'd0, "the 64th read ended the window");
        op(16'hC304, 1'b1, 1'b1, 1'b0, s, b); quiet;
        check(!s, "a 65th read is the ROM's again");

        // 3. A wrong bit disables writes until a reset read.
        $display("3. a mismatch, then the reset read");
        op(16'hC304, 1'b1, 1'b1, 1'b0, s, b);
        for (i = 0; i < 10; i = i + 1) op(KEY[i] ? 16'hC301 : 16'hC300, 1'b1, 1'b1, 1'b0, s, b);
        op(KEY[10] ? 16'hC300 : 16'hC301, 1'b1, 1'b1, 1'b0, s, b);   // the wrong bit
        quiet;
        check(!wr_en && cmp_idx == 6'd10, "a mismatch clears write-enable and freezes the comparison");
        for (i = 11; i < 64; i = i + 1) op(KEY[i] ? 16'hC301 : 16'hC300, 1'b1, 1'b1, 1'b0, s, b);
        quiet;
        check(!ring_en && unlocks == 8'd1 && cmp_idx == 6'd10, "the rest of the key is ignored");
        subs = 0;
        unlock(1'b1, 1'b1);
        quiet;
        check(wr_en && ring_en && unlocks == 8'd2, "the reset read re-arms it; the full key unlocks again");
        read_out(1'b1, got, nsub);
        quiet;
        check(got == T1 && nsub == 64, "...and the time reads out again");

        // 4. A program that SETS the clock: the 64 writes are counted, the
        //    time is the host's still.
        $display("4. a set-time sequence changes nothing");
        unlock(1'b1, 1'b1);
        quiet;
        check(ring_en, "unlocked for the set");
        subs = 0;
        for (i = 0; i < 64; i = i + 1) begin
            op((i & 1) ? 16'hC301 : 16'hC300, 1'b1, 1'b1, 1'b0, s, b); subs = subs + s;
        end
        quiet;
        check(!ring_en && subs == 0 && now_o == T1, "64 A2-low accesses in the window end it, substitute nothing, set nothing");
        unlock(1'b1, 1'b1);
        read_out(1'b1, got, nsub);
        quiet;
        check(got == T1, "the next read-out is the host's time, not the program's");

        // 5. The same accesses in a page the clock does not listen at.
        $display("5. a page that is not the clock's");
        subs = 0;
        unlock(1'b0, 1'b1);
        quiet;
        check(!ring_en && cmp_idx == 6'd0 && subs == 0, "nothing heard where q_nsc is low");
        // ...nor from an override's cycles.
        op(16'hC304, 1'b1, 1'b1, 1'b0, s, b);
        for (i = 0; i < 64; i = i + 1) op(KEY[i] ? 16'hC301 : 16'hC300, 1'b1, 1'b1, 1'b1, s, b);
        quiet;
        check(!ring_en && cmp_idx == 6'd0, "an override's accesses are nobody's");

        // 6. Bus WRITES step the state like reads (AppleWin Write), but no
        //    write ever gets a byte.
        $display("6. writes step the part, reads take the bit");
        subs = 0;
        unlock(1'b1, 1'b0);
        quiet;
        check(ring_en && subs == 0, "a key written with STA unlocks too");
        for (i = 0; i < 64; i = i + 1) begin
            op(16'hC304, (i & 1) ? 1'b1 : 1'b0, 1'b1, 1'b0, s, b);
            check(s == ((i & 1) ? 1'b1 : 1'b0), "only a read substitutes; a write with A2 still advances");
        end
        quiet;
        check(!ring_en, "64 accesses of either kind end the window");

        // 7. A new time; a half-landed one is never seen.
        $display("7. the next NSC_TIME, and a torn one");
        push_word(hdr(T_NSC_TIME, 8'd2, 16'd0));
        push_word(T2[31:0]);
        repeat (6) @(posedge clk); #1;
        check(now_o == T1, "the first word alone changes nothing");
        push_word(T2[63:32]);
        repeat (6) @(posedge clk); #1;
        check(now_o == T2, "the second word lands the whole time");
        unlock(1'b1, 1'b1);
        read_out(1'b1, got, nsub);
        quiet;
        check(got == T2 && nsub == 64, "the new time reads out");
        // A message of the wrong length is skipped by the parser and ignored
        // here: one word.
        push_word(hdr(T_NSC_TIME, 8'd1, 16'd0));
        push_word(32'hDEAD_BEEF);
        repeat (6) @(posedge clk); #1;
        check(now_o == T2, "a one-word NSC_TIME is ignored");

        // 8. A reset read mid-key starts the comparison over.
        $display("8. a reset read in the middle of the key");
        op(16'hC304, 1'b1, 1'b1, 1'b0, s, b);
        for (i = 0; i < 20; i = i + 1) op(KEY[i] ? 16'hC301 : 16'hC300, 1'b1, 1'b1, 1'b0, s, b);
        quiet;
        check(cmp_idx == 6'd20, "twenty bits in");
        op(16'hC304, 1'b1, 1'b1, 1'b0, s, b);
        quiet;
        check(cmp_idx == 6'd0 && !ring_en, "the A2 read resets the comparison");

        // 9. The lever, pulled mid-window.
        $display("9. the lever");
        unlock(1'b1, 1'b1);
        quiet;
        check(ring_en, "unlocked");
        enable = 0;
        quiet;
        check(!ring_en && cmp_idx == 6'd0 && unlocks == 8'd0, "off: the part is at power-on");
        subs = 0;
        unlock(1'b1, 1'b1);
        read_out(1'b1, got, nsub);
        quiet;
        check(!ring_en && nsub == 0 && subs == 0, "off: nothing heard, nothing served");
        enable = 1;
        quiet;
        unlock(1'b1, 1'b1);
        read_out(1'b1, got, nsub);
        quiet;
        check(got == T2 && nsub == 64 && unlocks == 8'd1, "on again: the time is there");

        $display("");
        if (errors == 0) $display("PASS: no_slot_clock_tb");
        else $display("FAIL: no_slot_clock_tb - %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
