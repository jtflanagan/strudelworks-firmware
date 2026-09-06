`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ssi263_tb - one speech chip's engine at the real sample rate.
//
// The chip alone, its slow clock ticked once per fabric clock so a whole
// phoneme runs in a moment: the numbers checked are the ones software
// times - a phoneme's length in machine cycles under each DUR, the
// leadout and the repeat, D7 and A/!R under every write that touches them,
// power-down, and the sample clock's ratio itself (22050 per 1020408).
// The card bench (sim/mockingboard_tb.sv) covers the same chip behind the
// bus decode, with the rate parameter shortened.
//////////////////////////////////////////////////////////////////////////////////
module ssi263_tb;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    integer errors = 0;
    task fail(input [8*80-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    reg        slow = 1'b0;
    reg        wr = 1'b0;
    reg  [2:0] wreg = 3'd0;
    reg  [7:0] wdata = 8'd0;
    wire       d7, ar_n, tick;

    ssi263 dut (
        .clk (clk), .rst (rst), .slow_clock (slow),
        .wr_strobe (wr), .wr_reg (wreg), .wr_data (wdata),
        .d7 (d7), .ar_n (ar_n), .tick (tick)
    );

    // Every fabric clock is a core cycle.
    integer cycles = 0;
    always @(posedge clk) if (slow) cycles = cycles + 1;

    task write(input [2:0] r, input [7:0] d);
        begin
            @(negedge clk); wr = 1; wreg = r; wdata = d;
            @(negedge clk); wr = 0;
        end
    endtask

    // Run cycles until D7 rises, or a limit; returns the count.
    integer waited;
    task wait_d7(input integer limit);
        begin
            waited = 0;
            while (!d7 && waited < limit) begin @(posedge clk); waited = waited + 1; end
        end
    endtask

    task run(input integer n);
        begin repeat (n) @(posedge clk); end
    endtask

    // The expected cycle counts: ticks * 1020408 / 22050, from the
    // consumption rules in the RTL header (a tick is 46.277 cycles).
    function integer cyc(input integer ticks);
        cyc = integer'((longint'(ticks) * 64'd1020408) / 64'd22050);
    endfunction

    task kick(input [7:0] durphon);
        begin
            write(3'd3, 8'h80);         // CTL high: power-down
            write(3'd0, durphon);
            write(3'd3, 8'h00);         // CTL high-to-low: mode set, phoneme starts
        end
    endtask

    integer ticks = 0;
    always @(posedge clk) if (tick) ticks = ticks + 1;

    initial begin
        $display("ssi263_tb: one SSI-263 at 22050 samples per 1020408 cycles\n");
        repeat (4) @(posedge clk);
        rst = 0;
        @(negedge clk); slow = 1;

        // --- power-on --------------------------------------------------------
        run(100);
        if (d7 !== 1'b0 || ar_n !== 1'b1) fail("D7/A/!R not clear at power-on");
        else                              $display("  ok: power-on - D7 clear, A/!R high");

        // --- the sample clock's ratio ----------------------------------------
        ticks = 0;
        run(1020408);
        if (ticks !== 22050) begin $display("  ticks = %0d", ticks); fail("22050 ticks per 1020408 cycles"); end
        else                 $display("  ok: 22050 sample ticks in 1020408 cycles, exactly");

        // --- a phoneme under each DUR ----------------------------------------
        // Phoneme 0 (a pause as long as phoneme 2: 2656 samples), DUR 3:
        // 664 output samples.  D7 up, A/!R low (interrupts enabled by the
        // DR bits), within a tick of the arithmetic.
        kick(8'hC0);
        if (d7 !== 1'b0) fail("D7 set by the kick itself");
        wait_d7(40000);
        if (!d7)                                        fail("DUR 3: no completion");
        else if (waited < cyc(664) - 50 || waited > cyc(664) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(664));
            fail("DUR 3: wrong length");
        end else $display("  ok: phoneme 0 DUR 3 - D7 after %0d cycles (664 ticks)", waited);
        if (ar_n !== 1'b0) fail("A/!R not asserted at completion with ints enabled");
        else               $display("  ok: A/!R low - interrupts were enabled by DR1:0 = 11");

        // A write to register 1 clears both; the leadout (265) then the
        // repeat (664) bring them back.
        write(3'd1, 8'h00);
        run(2);
        if (d7 !== 1'b0 || ar_n !== 1'b1) fail("a write to reg 1 did not clear D7/A/!R");
        else                              $display("  ok: a write to reg 1 clears D7 and A/!R");
        wait_d7(60000);
        if (!d7) fail("no repeat");
        else if (waited < cyc(929) - 100 || waited > cyc(929) + 100) begin
            $display("  repeated after %0d cycles, wanted ~%0d", waited, cyc(929));
            fail("repeat timing");
        end else $display("  ok: the phoneme repeats - D7 again after %0d cycles (265 leadout + 664)", waited);

        // Registers 4-7 and CTL=0 leave D7 alone; 0 and 2 clear it.
        write(3'd4, 8'h55);
        write(3'd3, 8'h0F);
        run(2);
        if (d7 !== 1'b1) fail("reg 4 or CTL=0 cleared D7");
        else             $display("  ok: reg 4 and a CTL=0 write leave D7 set");
        write(3'd2, 8'hF0);
        run(2);
        if (d7 !== 1'b0) fail("reg 2 did not clear D7");
        else             $display("  ok: reg 2 clears it");

        // DUR 0 with interrupts disabled: reg 0 = $00 while running - a
        // fresh phoneme at 2656 ticks; D7 still sets, A/!R stays high once
        // the mode has been picked up with DR1:0 = 00.
        kick(8'h00);
        wait_d7(140000);
        if (!d7) fail("DUR 0: no completion");
        else if (waited < cyc(2656) - 50 || waited > cyc(2656) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(2656));
            fail("DUR 0: wrong length");
        end else $display("  ok: DUR 0 - D7 after %0d cycles (2656 ticks, the full sample)", waited);
        if (ar_n !== 1'b1) fail("A/!R asserted with interrupts disabled");
        else               $display("  ok: DR1:0 = 00 - D7 set, A/!R stays high");

        // DUR 2 (function 2 from the kick): 1328.
        kick(8'h80);
        wait_d7(80000);
        if (!d7 || waited < cyc(1328) - 50 || waited > cyc(1328) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(1328));
            fail("DUR 2: wrong length");
        end else $display("  ok: DUR 2 - %0d cycles (1328 ticks)", waited);

        // DUR 1 without frame mode: kick with function 3, then rewrite reg 0
        // with DUR 1 while powered up - the phoneme restarts at DUR 1's
        // five-for-four pace: 2125 ticks.
        kick(8'hC0);
        write(3'd0, 8'h40);
        wait_d7(120000);
        if (!d7 || waited < cyc(2125) - 50 || waited > cyc(2125) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(2125));
            fail("DUR 1: wrong length");
        end else $display("  ok: DUR 1 - %0d cycles (2125 ticks: an extra sample every fourth)", waited);

        // Frame mode ($40 at the kick): function 1 forces four per tick
        // whatever DUR says - 664 again.
        kick(8'h40);
        wait_d7(40000);
        if (!d7 || waited < cyc(664) - 50 || waited > cyc(664) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(664));
            fail("frame mode: wrong length");
        end else $display("  ok: frame mode - %0d cycles (664 ticks, DUR forced to 3)", waited);

        // A short phoneme: $28 is 880 samples, DUR 3 -> 220 ticks.
        kick(8'hE8);
        wait_d7(20000);
        if (!d7 || waited < cyc(220) - 50 || waited > cyc(220) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(220));
            fail("phoneme $28: wrong length");
        end else $display("  ok: phoneme $28 - %0d cycles (880 samples, 220 ticks)", waited);

        // Phoneme 1 plays as phoneme 2 (no sample of its own; 2's is the
        // table's first, 2656 samples, and phoneme 3's is 2636): 664, not 659.
        kick(8'hC1);
        wait_d7(40000);
        if (!d7 || waited < cyc(664) - 50 || waited > cyc(664) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(664));
            fail("phoneme 1: wrong length");
        end else $display("  ok: phoneme 1 plays as phoneme 2 - %0d cycles (664 ticks)", waited);
        kick(8'hC3);
        wait_d7(40000);
        if (!d7 || waited < cyc(659) - 50 || waited > cyc(659) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(659));
            fail("phoneme 3: wrong length");
        end else $display("  ok: phoneme 3 - %0d cycles (2636 samples, 659 ticks)", waited);

        // --- power-down mid-phoneme ------------------------------------------
        // CTL=1 while playing: it finishes silently (no D7), then parks;
        // CTL back to 0 starts it again and D7 comes at the usual time.
        kick(8'hE8);
        run(5000);
        write(3'd3, 8'h80);
        run(2);
        if (d7 !== 1'b0) fail("CTL=1 left D7 set");
        wait_d7(30000);
        if (d7) fail("a powered-down chip set D7 at completion");
        else    $display("  ok: CTL=1 - no D7 at completion, the chip parks");
        write(3'd3, 8'h00);
        wait_d7(20000);
        if (!d7 || waited < cyc(220) - 50 || waited > cyc(220) + 50) begin
            $display("  completed after %0d cycles, wanted ~%0d", waited, cyc(220));
            fail("restart after CTL=0: wrong length");
        end else $display("  ok: CTL=0 - the phoneme starts over, D7 after %0d cycles", waited);

        // --- reset -----------------------------------------------------------
        @(negedge clk); rst = 1; @(negedge clk); rst = 0;
        run(30000);
        if (d7 !== 1'b0 || ar_n !== 1'b1) fail("reset did not power the chip down");
        else                              $display("  ok: RES' - power-down, nothing plays until CTL goes low");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
