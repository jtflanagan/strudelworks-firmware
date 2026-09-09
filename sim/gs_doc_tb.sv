`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_doc_tb - the Ensoniq 5503, driven through its four registers.
//
// WHY A UNIT BENCH.  The boot bench reaches the DOC only as whatever GS/OS
// happens to play, and the corners here are not reachable that way: the swap
// pair, the free-running loop, the interrupt queue's ARRIVAL ORDER, and the
// wavetable arithmetic at both ends of its range.  Here a wavetable is eight
// bytes and a scan is a handful of clocks.
//
// THE REFERENCE IS KEGS's doc.c, as the module's is.  Everything checked here
// is a statement that file makes: the one-access read delay, $E0's bit 7,
// halt-on-zero-byte, the mode table in doc_sound_end, and $E1's encoding.
//////////////////////////////////////////////////////////////////////////////////
module gs_doc_tb;

    localparam integer P = 10;
    reg clk = 1'b0;
    always #(P/2) clk = ~clk;

    reg        rst = 1'b1, res_sync = 1'b0;
    reg [7:0]  op_lo = 8'd0, op_wdata = 8'd0;
    reg        op_rw = 1'b1, act = 1'b0;
    wire [7:0] rd_byte, cnt_ends, cnt_irqs;
    wire signed [20:0] snd_l, snd_r;
    wire       irq;

    // A fast scan, so a bench clock is not a whole IIgs sample period: the
    // NCO's step is the only thing that changes, and the engine cannot tell.
    gs_doc #(.SCAN_INC (32'h4000_0000)) dut (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (op_lo), .op_rw (op_rw), .op_wdata (op_wdata), .act (act),
        .rd_byte (rd_byte),
        .snd_l (snd_l), .snd_r (snd_r), .irq (irq),
        .cnt_ends (cnt_ends), .cnt_irqs (cnt_irqs)
    );

    integer checks = 0, errors = 0;
    task ok(input string what);
        begin checks = checks + 1; $display("ok: %0s", what); end
    endtask
    task fail(input string what);
        begin checks = checks + 1; errors = errors + 1; $display("FAIL: %0s", what); end
    endtask
    task chk(input [7:0] got, input [7:0] want, input string what);
        begin
            if (got === want) ok($sformatf("%0s = $%02X", what, got));
            else fail($sformatf("%0s = $%02X, want $%02X", what, got, want));
        end
    endtask

    // ---- the machine's side -------------------------------------------------
    task automatic wr(input [7:0] lo, input [7:0] d);
        begin
            @(negedge clk);
            op_lo = lo; op_rw = 1'b0; op_wdata = d; act = 1'b0;
            @(negedge clk); act = 1'b1;
            @(negedge clk); act = 1'b0;
        end
    endtask
    task automatic rd(input [7:0] lo, output [7:0] v);
        begin
            @(negedge clk);
            op_lo = lo; op_rw = 1'b1; act = 1'b0;
            @(negedge clk);
            v = rd_byte;
            act = 1'b1;
            @(negedge clk); act = 1'b0;
        end
    endtask

    // Point the pointer, then touch the data port.  $C03C bit 5 is
    // auto-increment and bit 6 chooses RAM over registers.
    task automatic set_ptr(input [15:0] a);
        begin wr(8'h3E, a[7:0]); wr(8'h3F, a[15:8]); end
    endtask
    task automatic reg_wr(input [7:0] r, input [7:0] d);
        begin set_ptr({8'd0, r}); wr(8'h3C, 8'h00); wr(8'h3D, d); end
    endtask
    // A register read costs TWO accesses: the first returns the previous
    // fetch, the second the one it started.  That is the chip's one-access
    // read delay, and it is why this is a task and not a read.
    task automatic reg_rd(input [7:0] r, output [7:0] v);
        begin set_ptr({8'd0, r}); wr(8'h3C, 8'h00); rd(8'h3D, v); rd(8'h3D, v); end
    endtask
    task automatic ram_wr(input [15:0] a, input [7:0] d);
        begin set_ptr(a); wr(8'h3C, 8'h40); wr(8'h3D, d); end
    endtask

    // An oscillator's six registers, by type: type*32 + osc.
    task automatic osc_setup(input [4:0] o, input [15:0] f, input [7:0] v,
                             input [7:0] wp, input [7:0] ws);
        begin
            reg_wr({3'd0, o}, f[7:0]);
            reg_wr({3'd1, o}, f[15:8]);
            reg_wr({3'd2, o}, v);
            reg_wr({3'd4, o}, wp);
            reg_wr({3'd6, o}, ws);
        end
    endtask

    task automatic scans(input integer n);
        begin repeat (n) @(negedge clk); end
    endtask

    reg [7:0] v, v2;
    integer   n;

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0; res_sync = 1'b1;
        repeat (4) @(negedge clk);

        // ---- $E0 SAYS "NOTHING IS INTERRUPTING" -----------------------------
        // The whole reason this module exists instead of a face.  Bit 7 CLEAR
        // means an interrupt is pending, so a stub answering $00 claims
        // oscillator 0 is interrupting for ever - which is what put
        // "Unclaimed Sound Interrupt" on the screen.
        reg_rd(8'hE0, v); chk(v, 8'hFF, "$E0 with nothing interrupting");
        if (!irq) ok("...and the interrupt line is low");
        else fail("the interrupt line is high with an empty queue");
        reg_rd(8'hE2, v); chk(v, 8'h80, "$E2 reads $80");

        // ---- $E1 is the enabled count, ((val & $3E) >> 1) + 1 ---------------
        reg_wr(8'hE1, 8'h3E); reg_rd(8'hE1, v);
        chk(v, 8'h3E, "$E1 written $3E reads back 32 oscillators");
        reg_wr(8'hE1, 8'h02); reg_rd(8'hE1, v);
        chk(v, 8'h02, "...and $02 is two");

        // ---- a register round trip, and the read delay ----------------------
        reg_wr(8'h00, 8'h34);                        // osc 0 freq lo
        reg_wr(8'h20, 8'h12);                        // osc 0 freq hi
        reg_rd(8'h00, v); chk(v, 8'h34, "freq lo reads back");
        reg_rd(8'h20, v); chk(v, 8'h12, "freq hi reads back");
        reg_wr(8'h40, 8'h7F); reg_rd(8'h40, v); chk(v, 8'h7F, "volume reads back");

        // ---- the wave RAM ---------------------------------------------------
        ram_wr(16'h0100, 8'hAA);
        set_ptr(16'h0100); wr(8'h3C, 8'h40); rd(8'h3D, v); rd(8'h3D, v);
        chk(v, 8'hAA, "the wave RAM reads back what was written");

        // ---- THE ENGINE -----------------------------------------------------
        // A wavetable of 256 bytes at $0100 (waveptr $01, wavesize $00 = size
        // 256, resolution 0).  The index is acc >> (17 - 8 + 0) = acc >> 9, so
        // a frequency of 512 walks the table one byte a tick and the whole
        // table is 1 << 17 of accumulator - which is the end.
        reg_wr(8'hE1, 8'h3E);                        // all 32 enabled
        for (n = 0; n < 8; n = n + 1) ram_wr(16'h0100 + n[15:0], 8'h90);
        ram_wr(16'h0104, 8'h00);                     // ...with a terminator
        osc_setup(5'd0, 16'd512, 8'hFF, 8'h01, 8'h00);

        // One-shot (mode 1), interrupt enabled (bit 3), not halted.
        reg_wr(8'h05 * 8'd32, 8'h0A);
        scans(4000);
        reg_rd(8'hA0, v);                            // osc 0's control register
        chk(v & 8'h01, 8'h01, "a zero byte in the table halts the oscillator");
        // THE LINE IS CHECKED BEFORE $E0 IS READ, because reading it clears
        // the head - see the note on reg_rd below.
        if (irq) ok("...and the interrupt line is high");
        else fail("the interrupt line stayed low");
        reg_rd(8'hE0, v);
        chk(v, 8'h00, "$E0 names oscillator 0 - bit 7 clear, an interrupt IS pending");
        if (!irq) ok("...and reading $E0 dropped the interrupt line");
        else fail("the interrupt line stayed high after $E0 was read");

        // ---- free-running loops rather than halting -------------------------
        // Mode 0 with no zero byte in the table: the oscillator reaches the
        // end and starts again.  This is how a held note is made.
        for (n = 0; n < 256; n = n + 1) ram_wr(16'h0200 + n[15:0], 8'hC0);
        osc_setup(5'd2, 16'd512, 8'hFF, 8'h02, 8'h00);
        reg_wr(8'h05 * 8'd32 + 8'd2, 8'h00);          // free-run, no interrupt
        scans(20000);
        reg_rd(8'hA2, v);
        chk(v & 8'h01, 8'h00, "a free-running oscillator is still going");
        if (cnt_ends != 8'd0) ok("...having been round the table at least once");
        else fail("the free-running oscillator never reached the table's end");

        // ---- swap hands over to the partner ---------------------------------
        // Osc 4 in swap mode (3), its partner osc 5 halted with a table of its
        // own.  When 4 ends, 5 starts: "if either this osc or it's partner is
        // in swap mode, treat the pair as being in swap mode".
        for (n = 0; n < 8; n = n + 1) ram_wr(16'h0300 + n[15:0], 8'hA0);
        ram_wr(16'h0302, 8'h00);
        osc_setup(5'd4, 16'd512, 8'h80, 8'h03, 8'h00);
        osc_setup(5'd5, 16'd512, 8'h80, 8'h02, 8'h00);
        reg_wr(8'h05 * 8'd32 + 8'd5, 8'h01);          // the partner, halted
        reg_wr(8'h05 * 8'd32 + 8'd4, 8'h06);          // swap mode, running
        scans(4000);
        reg_rd(8'hA4, v); chk(v & 8'h01, 8'h01, "the swap oscillator halted itself");
        reg_rd(8'hA5, v); chk(v & 8'h01, 8'h00, "...and started its partner");

        // ---- THE INTERRUPT QUEUE IS IN ARRIVAL ORDER ------------------------
        // Not index order.  Oscillator 9 is made to finish BEFORE oscillator
        // 8, and $E0 must name 9 first: KEGS keeps an arrival rank per
        // oscillator, so a priority encoder over a bit vector would answer 8.
        for (n = 0; n < 64; n = n + 1) begin
            ram_wr(16'h0400 + n[15:0], 8'hB0);        // osc 9's, short
            ram_wr(16'h0500 + n[15:0], 8'hB0);        // osc 8's, longer
        end
        ram_wr(16'h0402, 8'h00);
        ram_wr(16'h0530, 8'h00);
        osc_setup(5'd9, 16'd512, 8'h80, 8'h04, 8'h00);
        osc_setup(5'd8, 16'd512, 8'h80, 8'h05, 8'h00);
        reg_wr(8'h05 * 8'd32 + 8'd9, 8'h0A);          // both one-shot with ints
        reg_wr(8'h05 * 8'd32 + 8'd8, 8'h0A);
        scans(60000);
        chk(cnt_irqs, 8'd3, "three interrupts have been raised in the run so far");
        // EVERY FETCH OF $E0 CLEARS THE HEAD (doc.c:769), and a register read
        // costs two fetches, so ONE reg_rd consumes TWO interrupts: the value
        // it returns is the first fetch, and the second is left in the read
        // delay's register for a single further read to collect.  That is the
        // chip, and the bench asked the wrong question before it was written
        // this way round.
        reg_rd(8'hE0, v);
        chk(v, 8'h12, "$E0 names oscillator 9 - the one that finished FIRST");
        rd(8'h3D, v2);
        chk(v2, 8'h10, "...and oscillator 8 is behind it, in ARRIVAL order");
        if (!irq) ok("...and both have been taken");
        else fail("an interrupt is still pending after both were read");

        // ---- A ZEROED TABLE MUST NOT STORM ----------------------------------
        // The DOC's RAM comes up cleared and the ROM clears it again, so an
        // oscillator started over it fetches $00 on its very first slot and
        // ends at once.  It must end ONCE.  If it can end, restart and end
        // again at scan rate, every pass pushes an interrupt and the machine
        // is buried: the stack marches down and GS/OS lands in the monitor.
        reg_wr(8'hE1, 8'h3E);
        for (n = 0; n < 32; n = n + 1) ram_wr(16'h0600 + n[15:0], 8'h00);
        osc_setup(5'd12, 16'd512, 8'h80, 8'h06, 8'h00);
        v2 = cnt_irqs;
        reg_wr(8'h05 * 8'd32 + 8'd12, 8'h0A);         // one-shot, interrupt on
        scans(8000);
        reg_rd(8'hAC, v); chk(v & 8'h01, 8'h01, "a zeroed table halts the oscillator");
        chk(cnt_irqs - v2, 8'd1, "...and raises EXACTLY ONE interrupt, not a storm");

        // ...and the same for a SWAP pair over zeroed tables, which is the
        // shape that could ping-pong: this one ends, hands to its partner,
        // the partner ends on its own zero byte and hands back.
        osc_setup(5'd14, 16'd512, 8'h80, 8'h06, 8'h00);
        osc_setup(5'd15, 16'd512, 8'h80, 8'h06, 8'h00);
        reg_wr(8'h05 * 8'd32 + 8'd15, 8'h07);         // partner: swap, halted
        v2 = cnt_irqs;
        reg_wr(8'h05 * 8'd32 + 8'd14, 8'h0E);         // swap, interrupt on
        scans(20000);
        // IT DOES NOT SETTLE, AND THAT IS THE REFERENCE'S BEHAVIOUR.  Each one
        // ends on its own zero byte and hands to the other, for ever - KEGS's
        // doc_sound_end starts the partner whenever either of the pair is in
        // swap mode and has no guard for a partner that will end at once.  So
        // one of the two is always running.
        reg_rd(8'hAE, v); v2 = v;
        reg_rd(8'hAF, v);
        if (((v2 & 8'h01) == 8'h00) != ((v & 8'h01) == 8'h00))
            ok("a swap pair over zeroed tables hands back and forth, one running");
        else
            fail("the swap pair is not handing over");
        // The queue is what keeps this from being an interrupt storm HERE:
        // an oscillator already in it is not pushed again.  On the machine
        // that guard is lifted the moment the handler reads $E0, which is why
        // this shape matters - see docs/GS.md.
        if (irq) ok("...with one interrupt raised and still pending");
        else fail("the swap pair raised no interrupt at all");

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
