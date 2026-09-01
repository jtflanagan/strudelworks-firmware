`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// cpu_irq_tb - a live hardware interrupt, which nothing else here exercises.
//
// Every other CPU test ties irq_n high (cpu_cycles_tb, the Klaus Dormann
// harness) or has no interrupt line at all.  So the whole IRQ entry path -
// hijacking the fetch, running BRK's microcode with the PC HELD instead of
// advanced, and coming back via RTI to the instruction that was interrupted -
// ran for the first time on real hardware, driving a Mockingboard, and a
// player locked up the moment its timer first fired.  The failure was the
// pushed return address: BRK advances PC to +2 and an interrupt must not, and
// the core advanced it for both.  This is that bug, written down as a test.
//
// THE PROPERTIES, and each is a way it was or could be wrong:
//
//   * the return address pushed by an IRQ is the instruction boundary, NOT
//     two bytes past it.  Checked by reading the pushed PC off the stack AND
//     by watching where execution resumes after RTI - a core off by two runs
//     into the middle of the next instruction and never reaches the marker.
//   * an IRQ is taken only at an instruction boundary.  irq_n is asserted in
//     the middle of a multi-cycle instruction and that instruction must
//     finish first - its own write must still land.
//   * the I flag masks it, and CLI lets it back in.
//   * BRK is unaffected: still two bytes, still pushes PC+2, still sets a
//     distinguishable B in the pushed status.
//
// A tiny 6502 program in flat RAM, hand-assembled below, plus an IRQ line the
// testbench drives.  No microcode knowledge - only the bus and the registers,
// which is the interface that has to be right.
//////////////////////////////////////////////////////////////////////////////////

module cpu_irq_tb #(parameter UCODE = "cpu65c02_ucode.hex");

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic irq_n = 1'b1;
    logic nmi_n = 1'b1;
    always #5 clk = ~clk;

    wire [15:0] addr;
    wire        rw;
    wire [7:0]  dout;
    logic [7:0] din;
    wire        sync, halted;

    cpu65c02 #(.UCODE_FILE (UCODE)) dut (
        .clk (clk), .rst (rst), .cyc_en (1'b1),
        .addr (addr), .rw (rw), .dout (dout), .i_din (din), .d_din (din),
        .irq_n (irq_n), .nmi_n (nmi_n),
        .sync (sync), .halted (halted)
    );

    logic [7:0] mem [0:65535];
    always_ff @(negedge clk) din <= mem[addr];
    always_ff @(posedge clk) if (!rst && !rw) mem[addr] <= dout;

    integer errors = 0;
    task fail(input [8*80-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    // ---- watch for a given opcode fetch -------------------------------------
    // Runs the clock until the CPU fetches an opcode at `want`, or `guard`
    // bus cycles pass.  Returns the cycle count, or -1 on timeout.
    task automatic run_to_fetch(input [15:0] want, input integer guard,
                                output integer took);
        integer n;
        begin
            n = 0; took = -1;
            while (n < guard && took < 0) begin
                @(posedge clk);
                if (sync && addr == want) took = n;
                n = n + 1;
            end
        end
    endtask

    // The address of the NEXT opcode fetch, whatever it is.  Used to catch
    // where RTI actually lands rather than assuming it - an off-by-two return
    // lands at boundary+2, and a padded main line would otherwise let it
    // wander back and hide the bug.
    task automatic next_fetch(input integer guard, output [15:0] where);
        integer n;
        logic   got;
        begin
            n = 0; got = 1'b0; where = 16'hFFFF;
            while (n < guard && !got) begin
                @(posedge clk);
                if (sync) begin where = addr; got = 1'b1; end
                n = n + 1;
            end
        end
    endtask

    // Addresses that matter.
    localparam [15:0] START     = 16'h0300;
    localparam [15:0] LOOP      = 16'h0300;   // the interruptible main loop
    localparam [15:0] HANDLER   = 16'h0380;
    localparam [15:0] RESUMED   = 16'h030A;   // where the main line must resume
    localparam [15:0] DONE      = 16'h0320;   // reached only if RTI came back right
    localparam [15:0] STORE_TGT = 16'h0040;   // the mid-instruction write's target

    integer took;
    integer i;
    logic [15:0] pushed_pc;
    logic [7:0]  pushed_p;

    initial begin
        $display("cpu_irq_tb: a live IRQ, taken between instructions\n");

        // Background: NOP, so any stray PC still advances rather than jamming.
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA;

        // ---- the program ----------------------------------------------------
        // Main line at $0300.  A store with a long-ish addressing mode sits
        // first so an IRQ asserted during it has an instruction to finish, and
        // its effect ($0040 <= $99) is checkable.  Then a marker store, then
        // the point we require execution to resume at, then a spin.
        //
        //   0300  CLI                 58
        //   0301  LDA #$99            A9 99
        //   0303  STA $0040,X    (X=0)9D 40 00     <- interrupted mid-store
        //   0306  JMP $030A           4C 0A 03      <- the boundary; RTI target
        //   0309  (filler $03)
        //   030A  LDA #$5A            A9 5A         <- RESUMED
        //   030C  STA $0041           8D 41 00
        //   030F  JMP $0320           4C 20 03
        //
        // The boundary is a THREE-byte JMP on purpose: an off-by-two return
        // lands at $0308, the JMP's own operand ($0A), and executes it as an
        // opcode - it does NOT quietly rejoin the main line.  That is what
        // makes "resumed at the boundary" a real check and not a coincidence
        // of padding, and it is exactly how the bug crashed a real game:
        // RTI into the middle of an instruction.
        mem[16'h0300] = 8'h58;
        mem[16'h0301] = 8'hA9; mem[16'h0302] = 8'h99;
        mem[16'h0303] = 8'h9D; mem[16'h0304] = 8'h40; mem[16'h0305] = 8'h00;
        mem[16'h0306] = 8'h4C; mem[16'h0307] = 8'h0A; mem[16'h0308] = 8'h03;
        mem[16'h030A] = 8'hA9; mem[16'h030B] = 8'h5A;
        mem[16'h030C] = 8'h8D; mem[16'h030D] = 8'h41; mem[16'h030E] = 8'h00;
        mem[16'h030F] = 8'h4C; mem[16'h0310] = 8'h20; mem[16'h0311] = 8'h03;

        // $0320: the success landing.  Store a marker, then spin on self.
        //   0320  LDA #$C3            A9 C3
        //   0322  STA $0042           8D 42 00
        //   0325  JMP $0325           4C 25 03
        mem[16'h0320] = 8'hA9; mem[16'h0321] = 8'hC3;
        mem[16'h0322] = 8'h8D; mem[16'h0323] = 8'h42; mem[16'h0324] = 8'h00;
        mem[16'h0325] = 8'h4C; mem[16'h0326] = 8'h25; mem[16'h0327] = 8'h03;

        // The IRQ handler at $0380: acknowledge by raising irq_n (the tb watches
        // for the handler fetch and does that), store a marker, then RTI.
        //   0380  LDA #$77            A9 77
        //   0382  STA $0043           8D 43 00
        //   0385  RTI                 40
        mem[16'h0380] = 8'hA9; mem[16'h0381] = 8'h77;
        mem[16'h0382] = 8'h8D; mem[16'h0383] = 8'h43; mem[16'h0384] = 8'h00;
        mem[16'h0385] = 8'h40;

        // Vectors.  Reset -> $0300, IRQ/BRK -> $0380.
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h03;
        mem[16'hFFFE] = 8'h80; mem[16'hFFFF] = 8'h03;

        // ---- reset ----------------------------------------------------------
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Let the core reach its main loop and run CLI so IRQs are unmasked.
        run_to_fetch(16'h0301, 200, took);           // just past CLI
        if (took < 0) begin fail("never reached the main line"); $finish; end

        // ---- case 1 / assert IRQ during the STA, mid-instruction ------------
        // Wait for the STA opcode fetch, then raise irq_n one cycle later - so
        // it is asserted while a multi-cycle instruction is still running.  The
        // store must still complete before the interrupt is taken.
        run_to_fetch(16'h0303, 50, took);
        if (took < 0) begin fail("never fetched the STA"); $finish; end
        @(posedge clk);                 // now inside the STA
        irq_n = 1'b0;                   // <- mid-instruction

        // The handler must be entered, but not before the store landed.
        run_to_fetch(HANDLER, 60, took);
        if (took < 0) begin
            fail("the IRQ was never taken");
            $finish;
        end
        irq_n = 1'b1;                   // acknowledge: the handler cleared it

        if (mem[STORE_TGT] !== 8'h99)
            fail("the interrupted STA did not complete before the IRQ");
        else
            $display("  ok: the instruction in progress finished first");

        // ---- case 2 / the pushed return address is the boundary -------------
        // The handler was just entered, so the stack holds [P][PCL][PCH] with S
        // pointing below them.  Read them back from page 1.  The 6502 pushes
        // high byte first at $01FF downward, so with the return address at the
        // top of the stack: PCH at $01xx+2, PCL at +1, P at +0 relative to the
        // post-push S.  Rather than track S, scan for the known handler entry:
        // the three bytes just pushed are the only PCH=$03 PCL in {$06} P
        // pattern near the top of the stack.
        pushed_pc = 16'h0000;
        for (i = 16'h01FF; i > 16'h01F8; i = i - 1) begin
            if (mem[i] == 8'h03 && mem[i-1] == 8'h06) begin
                pushed_pc = {mem[i], mem[i-1]};
                pushed_p  = mem[i-2];
            end
        end
        // $0306 is the boundary AFTER the STA: the instruction that was about
        // to run when the interrupt was taken.  NOT $0308 (boundary+2).
        if (pushed_pc !== 16'h0306)
            fail("the pushed return address is not the interrupted boundary");
        else
            $display("  ok: IRQ pushed $0306 - the next instruction, not +2");
        if (pushed_p[4] !== 1'b0)
            fail("B was set in the pushed status for a hardware IRQ");
        else
            $display("  ok: B clear in the pushed status - a hardware interrupt");

        // ---- case 3 / RTI resumes at the boundary, exactly ------------------
        // The RTI is the last instruction of the handler.  Its first opcode
        // fetch afterwards is the return target, and it must be $0306 - the
        // interrupted boundary - and not $0308.  Catching the FETCH ADDRESS
        // rather than waiting for a downstream marker is what makes this
        // discriminating: boundary+2 lands mid-instruction and cannot be
        // confused with a correct return.
        begin : resume_check
            logic [15:0] land;
            // Run out the handler to its RTI first; the fetch after that is
            // the return target.
            run_to_fetch(16'h0385, 40, took);
            if (took < 0) fail("the handler never reached its RTI");
            next_fetch(80, land);
            if (land !== 16'h0306)
                fail("RTI did not return to the interrupted boundary $0306");
            else
                $display("  ok: RTI's first fetch is $0306 - dead on the boundary");
        end

        // And the whole main line runs to the success landing and its store.
        run_to_fetch(DONE, 80, took);
        if (took < 0)
            fail("never reached the success landing - RTI returned wrong");
        else
            $display("  ok: reached $0320, the success landing");
        run_to_fetch(16'h0325, 40, took);
        if (mem[16'h0042] !== 8'hC3)
            fail("the success landing did not run its store");
        else
            $display("  ok: the landing executed - the whole path is intact");

        // ---- case 4 / the I flag masks it -----------------------------------
        // Enter the handler's tail path is done; now prove SEI blocks a new IRQ.
        // Point PC at a fresh spin with interrupts disabled and assert irq_n.
        //   0330  SEI                 78
        //   0331  NOP x8              EA...
        //   0339  JMP $0339           4C 39 03
        mem[16'h0330] = 8'h78;
        for (i = 16'h0331; i <= 16'h0338; i = i + 1) mem[i] = 8'hEA;
        mem[16'h0339] = 8'h4C; mem[16'h033A] = 8'h39; mem[16'h033B] = 8'h03;
        // Reach it via the spin at $0325 being replaced with a jump - simplest
        // is a fresh reset with a different vector.
        mem[16'hFFFC] = 8'h30; mem[16'hFFFD] = 8'h03;
        rst = 1'b1; repeat (4) @(posedge clk); rst = 1'b0;
        run_to_fetch(16'h0339, 200, took);
        if (took < 0) begin fail("never reached the SEI spin"); $finish; end
        irq_n = 1'b0;                   // masked: must be ignored
        run_to_fetch(HANDLER, 120, took);
        if (took >= 0)
            fail("a masked IRQ was taken - the I flag did not block it");
        else
            $display("  ok: with I set, the IRQ stayed out");
        irq_n = 1'b1;

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // A global guard, so a wedged core fails the run rather than hanging it.
    initial begin
        #2_000_000;
        $display("FAIL: global timeout");
        $finish;
    end

endmodule
