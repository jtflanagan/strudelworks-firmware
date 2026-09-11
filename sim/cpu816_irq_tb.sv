`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 John Flanagan
//////////////////////////////////////////////////////////////////////////////////
// cpu816_irq_tb - a live hardware interrupt through the 65816, which nothing
// else here exercises.
//
// The 65C02 has sim/cpu_irq_tb.sv because its first hardware interrupt ever
// fired on a Mockingboard and locked the machine: BRK advances PC to +2 and an
// interrupt must not, and the core advanced it for both.  The 65816 core was
// written after that with the same shape, and SingleStepTests hold it
// instruction by instruction without ever driving irq_n - so the IIgs took its
// first real interrupts running GS/OS, and EVERY ONE returned two bytes late
// (docs/GS.md rung 4c).  This is that bug written down as a test, for both of
// the part's modes.
//
// THE PROPERTIES, and each is a way it was or could be wrong:
//
//   * the return address pushed by an IRQ or NMI is the instruction boundary,
//     NOT two bytes past it - read off the stack AND seen as RTI's first fetch.
//     The boundary is a three-byte JMP so that boundary+2 lands on its operand
//     and cannot rejoin the main line by accident.
//   * the frame is the mode's: three bytes in emulation, four in native with
//     PBR on top; the vector is the mode's ($FFFE / $FFEE, NMI $FFFA / $FFEA).
//   * B is clear in the status a hardware interrupt pushes (emulation mode has
//     one); D is clear in the handler and the old D is in the pushed status.
//   * an interrupt is taken only at an instruction boundary: asserted inside a
//     store, the store still lands.
//   * BRK is unaffected in either mode: still two bytes, still PC+2, B set.
//   * the I flag masks an IRQ.
//
// A hand-assembled program in a flat 64 KB bank zero.  Only the bus and the
// registers are consulted, which is the interface that has to be right.
//////////////////////////////////////////////////////////////////////////////////

module cpu816_irq_tb #(parameter UCODE  = "cpu65816_ucode.hex",
                       parameter UCODE0 = "cpu65816_ucode0.hex",
                       parameter USEQ0  = "cpu65816_useq0.hex");

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic irq_n = 1'b1;
    logic nmi_n = 1'b1;
    always #5 clk = ~clk;

    wire [23:0] addr;
    wire        rw, sync, vda, vpa, vpb, emu, halted;
    wire [7:0]  dout;
    logic [7:0] din;

    cpu65816 #(.UCODE_FILE (UCODE), .UCODE0_FILE (UCODE0), .USEQ0_FILE (USEQ0)) dut (
        .clk (clk), .rst (rst), .cyc_en (1'b1),
        .addr (addr), .rw (rw), .dout (dout), .din (din),
        .irq_n (irq_n), .nmi_n (nmi_n),
        .sync (sync), .vda (vda), .vpa (vpa), .vpb (vpb), .emu (emu), .halted (halted)
    );

    logic [7:0] mem [0:65535];
    always_ff @(negedge clk) din <= mem[addr[15:0]];
    always_ff @(posedge clk) if (!rst && !rw && (vda || vpa)) mem[addr[15:0]] <= dout;

    // The program never leaves bank zero; an access anywhere else is a fault.
    integer bank_faults = 0;
    always_ff @(posedge clk) if (!rst && (vda || vpa) && addr[23:16] != 8'h00) bank_faults = bank_faults + 1;

    integer errors = 0;
    task fail(input string why); begin $display("FAIL: %0s", why); errors = errors + 1; end endtask
    task ok(input string what);  begin $display("  ok: %0s", what); end endtask

    task automatic run_to_fetch(input [15:0] want, input integer guard, output integer took);
        integer n;
        begin
            n = 0; took = -1;
            while (n < guard && took < 0) begin
                @(posedge clk);
                if (sync && addr[15:0] == want) took = n;
                n = n + 1;
            end
        end
    endtask
    task automatic next_fetch(input integer guard, output [15:0] where);
        integer n; logic got;
        begin
            n = 0; got = 1'b0; where = 16'hFFFF;
            while (n < guard && !got) begin
                @(posedge clk);
                if (sync) begin where = addr[15:0]; got = 1'b1; end
                n = n + 1;
            end
        end
    endtask

    // ---- a two-line assembler ---------------------------------------------
    integer at;
    task org(input [15:0] a); at = a; endtask
    task b(input [7:0] v); begin mem[at] = v; at = at + 1; end endtask

    // Handlers, fixed so the checks can name their RTIs.
    localparam [15:0] H_EIRQ = 16'h0380, H_NIRQ = 16'h0390, H_NMI = 16'h03A0, H_NBRK = 16'h03B0;
    localparam [15:0] LANDING = 16'h0320, SPIN = 16'h0325;
    task handler(input [15:0] a, input [7:0] mark, input [15:0] where);
        begin org(a); b(8'hA9); b(mark); b(8'h8D); b(where[7:0]); b(where[15:8]); b(8'h40); end   // LDA # / STA abs / RTI
    endtask
    task landing;   // LDA #$C3 / STA $0042 / JMP self
        begin org(LANDING); b(8'hA9); b(8'hC3); b(8'h8D); b(8'h42); b(8'h00); b(8'h4C); b(SPIN[7:0]); b(SPIN[15:8]); end
    endtask
    // The interruptible main line: [prologue] LDA #$99 / STA $0040,X / JMP resume / filler /
    // resume: LDA #$5A / STA $0041 / JMP landing.  Returns the boundary (the JMP) and resume.
    task mainline(input [15:0] a, input native, input decimal, output [15:0] boundary, output [15:0] resume, output [15:0] sta_at);
        logic [15:0] r;
        begin
            org(a);
            if (native) begin b(8'h18); b(8'hFB); end        // CLC / XCE -> native, m = x = 1
            if (decimal) b(8'hF8);                            // SED: the handler must see D clear
            b(8'h58);                                         // CLI
            b(8'hA9); b(8'h99);                               // LDA #$99
            sta_at = at; b(8'h9D); b(8'h40); b(8'h00);        // STA $0040,X  <- interrupted mid-store
            boundary = at; r = at + 4;
            b(8'h4C); b(r[7:0]); b(r[15:8]); b(8'h03);        // JMP resume; filler $03 (boundary+2 is the operand)
            resume = at;
            b(8'hA9); b(8'h5A); b(8'h8D); b(8'h41); b(8'h00); // LDA #$5A / STA $0041
            b(8'h4C); b(LANDING[7:0]); b(LANDING[15:8]);      // JMP landing
        end
    endtask
    task reset_to(input [15:0] a);
        begin
            mem[16'hFFFC] = a[7:0]; mem[16'hFFFD] = a[15:8];
            irq_n = 1'b1; nmi_n = 1'b1;
            rst = 1'b1; repeat (4) @(posedge clk); rst = 1'b0;
        end
    endtask
    task clear_marks;
        integer k; begin for (k = 16'h0040; k < 16'h0048; k = k + 1) mem[k] = 8'h00; end
    endtask

    // The frame just pushed, read at the handler's first fetch.  S points below it.
    task automatic frame(output [7:0] p, output [15:0] pc, output [7:0] pbr, input native);
        logic [15:0] s;
        begin
            s = dut.s;
            p   = mem[s + 1];
            pc  = {mem[s + 3], mem[s + 2]};
            pbr = native ? mem[s + 4] : 8'h00;
        end
    endtask

    // One interrupt trial: reset into the main line, assert the line inside
    // the STA, check the store landed, the frame, the flags, RTI's landing and
    // the marker at the end.
    task automatic trial(input string name, input [15:0] start, input native, input use_nmi,
                         input [15:0] hand, input [15:0] rti_at);
        integer took; logic [15:0] boundary, resume, sta_at, land; logic [7:0] p, pbr; logic [15:0] pc;
        logic [15:0] s_before;
        begin
            $display("-- %0s", name);
            clear_marks();
            mainline(start, native, 1'b1, boundary, resume, sta_at);
            reset_to(start);
            run_to_fetch(sta_at, 200, took);
            if (took < 0) begin fail({name, ": never fetched the STA"}); return; end
            if (native && emu) fail({name, ": still in emulation mode"});
            s_before = dut.s;
            @(posedge clk);                       // inside the STA
            if (use_nmi) nmi_n = 1'b0; else irq_n = 1'b0;
            run_to_fetch(hand, 80, took);
            if (took < 0) begin fail({name, ": the interrupt was never taken"}); irq_n = 1'b1; nmi_n = 1'b1; return; end
            irq_n = 1'b1; nmi_n = 1'b1;
            if (mem[16'h0040] !== 8'h99) fail({name, ": the interrupted STA did not complete first"});
            else ok("the instruction in progress finished first");
            frame(p, pc, pbr, native);
            if (pc !== boundary) fail($sformatf("%0s: pushed $%04X, the boundary is $%04X (boundary+2 = $%04X)", name, pc, boundary, boundary + 16'd2));
            else ok($sformatf("pushed $%04X - the boundary, not +2", pc));
            if ((s_before - dut.s) !== (native ? 16'd4 : 16'd3))
                fail($sformatf("%0s: frame is %0d bytes, expected %0d", name, s_before - dut.s, native ? 4 : 3));
            else ok($sformatf("a %0d-byte frame", s_before - dut.s));
            if (native && pbr !== 8'h00) fail({name, ": PBR pushed is not zero"});
            if (!native && p[4] !== 1'b0) fail({name, ": B set in a hardware interrupt's pushed status"});
            else if (!native) ok("B clear in the pushed status");
            if (p[3] !== 1'b1) fail({name, ": the pushed status lost the old D"});
            if (dut.f_d !== 1'b0) fail({name, ": D not cleared on entry"});
            else ok("D cleared on entry, old D in the pushed status");
            run_to_fetch(rti_at, 40, took);
            if (took < 0) fail({name, ": the handler never reached its RTI"});
            next_fetch(80, land);
            if (land !== boundary) fail($sformatf("%0s: RTI landed at $%04X, not the boundary $%04X", name, land, boundary));
            else ok($sformatf("RTI's first fetch is $%04X - dead on the boundary", land));
            run_to_fetch(SPIN, 120, took);
            if (took < 0 || mem[16'h0042] !== 8'hC3) fail({name, ": the main line did not reach its landing"});
            else ok("the whole path ran to the landing");
        end
    endtask

    // BRK: two bytes, PC+2, B set (emulation), the mode's vector, RTI to the byte after the signature.
    task automatic brk_trial(input string name, input [15:0] start, input native, input [15:0] hand, input [15:0] rti_at);
        integer took; logic [15:0] after, land, s_before; logic [7:0] p, pbr; logic [15:0] pc;
        begin
            $display("-- %0s", name);
            clear_marks();
            org(start);
            if (native) begin b(8'h18); b(8'hFB); end
            b(8'h58);
            s_before = at;
            b(8'h00); b(8'hEA);                               // BRK, signature
            after = at;
            b(8'hA9); b(8'h5A); b(8'h8D); b(8'h41); b(8'h00);
            b(8'h4C); b(LANDING[7:0]); b(LANDING[15:8]);
            reset_to(start);
            run_to_fetch(s_before, 200, took);
            if (took < 0) begin fail({name, ": never fetched the BRK"}); return; end
            s_before = dut.s;
            run_to_fetch(hand, 60, took);
            if (took < 0) begin fail({name, ": BRK did not reach its handler"}); return; end
            frame(p, pc, pbr, native);
            if (pc !== after) fail($sformatf("%0s: BRK pushed $%04X, expected $%04X (past the signature)", name, pc, after));
            else ok($sformatf("BRK pushed $%04X - two bytes, as it must", pc));
            if (!native && p[4] !== 1'b1) fail({name, ": B clear in BRK's pushed status"});
            else if (!native) ok("B set in BRK's pushed status");
            if ((s_before - dut.s) !== (native ? 16'd4 : 16'd3)) fail({name, ": BRK frame size wrong"});
            run_to_fetch(rti_at, 40, took);
            next_fetch(80, land);
            if (land !== after) fail($sformatf("%0s: RTI after BRK landed at $%04X, expected $%04X", name, land, after));
            else ok("RTI after BRK lands past the signature");
        end
    endtask

    integer took, i;
    initial begin
        $display("cpu816_irq_tb: live interrupts through the 65816, both modes\n");
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA;
        handler(H_EIRQ, 8'h77, 16'h0043);
        handler(H_NIRQ, 8'h78, 16'h0043);
        handler(H_NMI,  8'h66, 16'h0044);
        handler(H_NBRK, 8'h55, 16'h0045);
        landing();
        // Vectors: emulation IRQ/BRK $FFFE, emulation NMI $FFFA, native IRQ $FFEE,
        // native NMI $FFEA, native BRK $FFE6.
        mem[16'hFFFE] = H_EIRQ[7:0]; mem[16'hFFFF] = H_EIRQ[15:8];
        mem[16'hFFFA] = H_NMI[7:0];  mem[16'hFFFB] = H_NMI[15:8];
        mem[16'hFFEE] = H_NIRQ[7:0]; mem[16'hFFEF] = H_NIRQ[15:8];
        mem[16'hFFEA] = H_NMI[7:0];  mem[16'hFFEB] = H_NMI[15:8];
        mem[16'hFFE6] = H_NBRK[7:0]; mem[16'hFFE7] = H_NBRK[15:8];

        trial("IRQ in emulation mode", 16'h0300, 1'b0, 1'b0, H_EIRQ, H_EIRQ + 16'd5);
        trial("IRQ in native mode",    16'h0400, 1'b1, 1'b0, H_NIRQ, H_NIRQ + 16'd5);
        trial("NMI in native mode",    16'h0440, 1'b1, 1'b1, H_NMI,  H_NMI  + 16'd5);
        trial("NMI in emulation mode", 16'h0480, 1'b0, 1'b1, H_NMI,  H_NMI  + 16'd5);
        brk_trial("BRK in emulation mode", 16'h0500, 1'b0, H_EIRQ, H_EIRQ + 16'd5);
        brk_trial("BRK in native mode",    16'h0520, 1'b1, H_NBRK, H_NBRK + 16'd5);

        // ---- the I flag masks an IRQ -----------------------------------------
        $display("-- I masks");
        org(16'h0600); b(8'h78); for (i = 0; i < 8; i = i + 1) b(8'hEA); b(8'h4C); b(8'h09); b(8'h06);
        reset_to(16'h0600);
        run_to_fetch(16'h0609, 200, took);
        if (took < 0) fail("never reached the SEI spin");
        irq_n = 1'b0;
        run_to_fetch(H_EIRQ, 120, took);
        if (took >= 0) fail("a masked IRQ was taken"); else ok("with I set, the IRQ stayed out");
        irq_n = 1'b1;

        if (bank_faults != 0) fail($sformatf("%0d accesses left bank zero", bank_faults));
        $display("");
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin #4_000_000; $display("FAIL: global timeout"); $finish; end
endmodule
