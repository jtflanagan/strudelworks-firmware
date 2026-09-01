`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// cpu_cycles_tb - measure every opcode's cycle count against the published table.
//
// This is the test the project actually needs and that Klaus Dormann's suites
// cannot give: they check that the CPU computes the right ANSWER, and say
// nothing about how many cycles it took to get there.  A core can pass both
// functional suites end to end with half its instructions a cycle short.  In a
// machine where video, memory refresh and every peripheral are timed off the
// same phi0, that core is useless.
//
// METHOD.  For each opcode, run a prologue that loads X, Y, P and A, then the
// opcode under test at a FIXED address, and count bus cycles from its opcode
// fetch to the next opcode fetch.  Measuring fetch-to-fetch rather than trying
// to detect "instruction complete" internally means the measurement uses only
// the bus, which is the thing that has to be right.
//
// The memory map is arranged so the base case is what gets measured: pointers
// resolve into page 3, X = Y = 2, so no indexed access crosses a page.  The
// page-crossing and decimal cases are measured separately at the end - a core
// that adds the extra cycle unconditionally and one that never adds it both
// pass a base-case-only test.
//
// Vectors come from sim/gen_cycle_table.py, which holds the reference table as a
// flat literal.  Deriving the expected counts from the core's own decoder would
// make this testbench agree with the core by construction.
//////////////////////////////////////////////////////////////////////////////////

module cpu_cycles_tb #(parameter UCODE = "cpu65c02_ucode.hex");

    logic clk = 1'b0;
    logic rst = 1'b1;

    wire [15:0] addr;
    wire        rw;
    wire [7:0]  dout;
    logic [7:0] din;
    wire        sync, halted;

    cpu65c02 #(.UCODE_FILE (UCODE)) dut (
        .clk (clk), .rst (rst), .cyc_en (1'b1),
        .addr (addr), .rw (rw), .dout (dout), .i_din (din), .d_din (din),
        .irq_n (1'b1), .nmi_n (1'b1),
        .sync (sync), .halted (halted)
    );

    logic [7:0] mem [0:65535];
    // Presented mid-cycle rather than combinationally.  A combinational read of
    // a 65536-entry array makes iverilog rebuild its sensitivity on every write
    // to the array, which turns loading the image into an O(n^2) crawl.  The
    // core samples din on the rising edge, so a value settled at the falling
    // edge meets the same contract.
    always_ff @(negedge clk) din <= mem[addr];
    always_ff @(posedge clk) if (!rst && !rw) mem[addr] <= dout;

    // ---- vectors ------------------------------------------------------------
    // 4 bytes per opcode: operand 1, operand 2, initial P, expected cycles.
    logic [7:0] vec [0:1023];

    localparam logic [15:0] PROLOGUE = 16'h0200;
    localparam logic [15:0] UNDER_TEST = 16'h020C;   // after the 12-byte prologue

    int errors = 0;
    int tested = 0;

    // ---- one measurement ----------------------------------------------------
    // Returns the number of bus cycles from the fetch at UNDER_TEST to the next
    // opcode fetch, whatever address that fetch is at.
    task automatic measure(input logic [7:0] opcode,
                           input logic [7:0] o1, input logic [7:0] o2,
                           input logic [7:0] p_init,
                           input logic       set_decimal,
                           input logic [7:0] xval, input logic [7:0] yval,
                           output int        count);
        int   guard;
        logic done, lost;
        begin
            // Background: NOP everywhere, so a wandering pc still makes progress.
            for (int i = 0; i < 65536; i++) mem[i] = 8'hEA;

            // Zero-page pointers, both resolving to $0300.
            mem[16'h0010] = 8'h00;  mem[16'h0011] = 8'h03;   // (zp) and (zp),Y
            mem[16'h0012] = 8'h00;  mem[16'h0013] = 8'h03;   // (zp,X) with X=2
            // A second pointer, deliberately near the top of page 3, so an
            // indexed load through it crosses into page 4.
            mem[16'h0020] = 8'hF8;  mem[16'h0021] = 8'h03;
            for (int i = 0; i < 256; i++) mem[16'h0300 + i] = 8'h5A;

            // Prologue: exactly 12 bytes, so the opcode under test always lands
            // at UNDER_TEST.  PLP is LAST on purpose - loading A sets N and Z,
            // so setting the status before loading A would silently undo the
            // branch-condition setup and make every branch measure as taken.
            mem[PROLOGUE + 0]  = 8'hA9;                                             // LDA #p
            mem[PROLOGUE + 1]  = p_init | (set_decimal ? 8'h08 : 8'h00);
            mem[PROLOGUE + 2]  = 8'h48;                                             // PHA
            mem[PROLOGUE + 3]  = 8'hA2; mem[PROLOGUE + 4]  = xval;                  // LDX #
            mem[PROLOGUE + 5]  = 8'hA0; mem[PROLOGUE + 6]  = yval;                  // LDY #
            mem[PROLOGUE + 7]  = 8'hA9; mem[PROLOGUE + 8]  = 8'h34;                 // LDA #$34
            mem[PROLOGUE + 9]  = 8'h28;                                             // PLP
            mem[PROLOGUE + 10] = 8'hEA; mem[PROLOGUE + 11] = 8'hEA;                 // pad

            mem[UNDER_TEST + 0] = opcode;
            mem[UNDER_TEST + 1] = o1;
            mem[UNDER_TEST + 2] = o2;

            // Reset vector into the prologue, and a landing pad for BRK/JSR/JMP
            // so those instructions have somewhere defined to go.
            mem[16'hFFFC] = PROLOGUE[7:0];   mem[16'hFFFD] = PROLOGUE[15:8];
            mem[16'hFFFE] = 8'h00;           mem[16'hFFFF] = 8'h04;

            rst = 1'b1;
            repeat (3) @(posedge clk);
            rst = 1'b0;

            // Run to the fetch of the instruction under test.
            guard = 0;
            lost  = 1'b0;
            while (!(sync === 1'b1 && addr == UNDER_TEST) && !lost) begin
                @(posedge clk);
                guard++;
                if (guard > 200) begin
                    $display("FAIL $%02h: never reached the instruction under test", opcode);
                    errors++;
                    count = -1;
                    lost  = 1'b1;
                end
            end

            // Count cycles until the next opcode fetch.
            count = 0;
            done  = lost;
            while (!done) begin
                @(posedge clk);
                count++;
                if (sync === 1'b1) begin
                    done = 1'b1;
                end else if (count > 64) begin
                    $display("FAIL $%02h: no next fetch within 64 cycles", opcode);
                    errors++;
                    count = -1;
                    done  = 1'b1;
                end
            end
        end
    endtask

    task automatic check(input logic [7:0] opcode,
                         input logic [7:0] o1, input logic [7:0] o2,
                         input logic [7:0] p_init, input logic set_decimal,
                         input logic [7:0] xval, input logic [7:0] yval,
                         input int want, input string what);
        int got;
        begin
            measure(opcode, o1, o2, p_init, set_decimal, xval, yval, got);
            if (got >= 0) begin
                tested++;
                if (got != want) begin
                    $display("FAIL $%02h %-22s expected %0d cycles, got %0d",
                             opcode, what, want, got);
                    errors++;
                end
            end
        end
    endtask

    // ---- the run ------------------------------------------------------------
    string vecfile;
    int    expect_cyc;

    initial begin
        if (!$value$plusargs("vec=%s", vecfile)) $fatal(1, "need +vec=");
        $readmemh(vecfile, vec);

        $display("=== base cycle counts, all 256 opcodes ===");
        for (int op = 0; op < 256; op++) begin
            expect_cyc = vec[op*4 + 3];
            if (expect_cyc != 0)   // 0 marks an opcode this method cannot measure
                check(op[7:0], vec[op*4], vec[op*4 + 1], vec[op*4 + 2],
                      1'b0, 8'h02, 8'h02, expect_cyc, "base");
        end

        // ---- the +1 cases ---------------------------------------------------
        // Page crossing.  X = Y = $10 against a base of $03F8 pushes every
        // indexed access into page 4.
        $display("=== indexed reads, page boundary crossed (+1) ===");
        check(8'hBD, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 5, "LDA abs,X cross");
        check(8'hB9, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 5, "LDA abs,Y cross");
        check(8'hBC, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 5, "LDY abs,X cross");
        check(8'hBE, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 5, "LDX abs,Y cross");
        check(8'h3D, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 5, "AND abs,X cross");
        check(8'hDD, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 5, "CMP abs,X cross");

        // Writes take the fixup cycle whether or not the index carried, so these
        // are the SAME count as their base case.  That is the asymmetry worth
        // testing: a core that made the fixup conditional everywhere passes the
        // base case and fails here.
        $display("=== indexed writes, no +1 for crossing ===");
        check(8'h9D, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 5, "STA abs,X cross");
        check(8'h99, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 5, "STA abs,Y cross");

        // ASL/LSR/ROL/ROR abs,X are 6 or 7; INC/DEC abs,X are 7 either way.
        $display("=== RMW abs,X ===");
        check(8'h1E, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 7, "ASL abs,X cross");
        check(8'h5E, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 7, "LSR abs,X cross");
        check(8'hFE, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 7, "INC abs,X cross");
        check(8'hDE, 8'hF8, 8'h03, 8'h20, 1'b0, 8'h10, 8'h10, 7, "DEC abs,X cross");

        // (zp),Y: pointer $0011 -> $03F8, so Y=$10 crosses.  Reads gain a cycle,
        // stores do not.
        // Pointer $20 holds $03F8, so Y=$10 lands in page 4.  The read gains a
        // cycle; the store was already paying for the fixup and does not.
        $display("=== (zp),Y page crossed ===");
        check(8'hB1, 8'h20, 8'h00, 8'h20, 1'b0, 8'h10, 8'h10, 6, "LDA (zp),Y cross");
        check(8'h91, 8'h20, 8'h00, 8'h20, 1'b0, 8'h10, 8'h10, 6, "STA (zp),Y cross");
        check(8'hB1, 8'h10, 8'h00, 8'h20, 1'b0, 8'h02, 8'h02, 5, "LDA (zp),Y no cross");

        // Taken branches: 3, and 4 when the target is in another page.
        $display("=== branches ===");
        check(8'hD0, 8'h02, 8'h00, 8'h20, 1'b0, 8'h02, 8'h02, 3, "BNE taken");
        check(8'hF0, 8'h02, 8'h00, 8'h22, 1'b0, 8'h02, 8'h02, 3, "BEQ taken");
        check(8'h80, 8'h02, 8'h00, 8'h20, 1'b0, 8'h02, 8'h02, 3, "BRA taken");
        check(8'hD0, 8'hF0, 8'h00, 8'h20, 1'b0, 8'h02, 8'h02, 4, "BNE taken back a page");
        check(8'h80, 8'hF0, 8'h00, 8'h20, 1'b0, 8'h02, 8'h02, 4, "BRA taken back a page");

        // Decimal ADC/SBC are one cycle longer on the 65C02 than on the NMOS part.
        $display("=== decimal mode (+1) ===");
        check(8'h69, 8'h11, 8'h00, 8'h20, 1'b1, 8'h02, 8'h02, 3, "ADC # decimal");
        check(8'hE9, 8'h11, 8'h00, 8'h21, 1'b1, 8'h02, 8'h02, 3, "SBC # decimal");
        check(8'h65, 8'h10, 8'h00, 8'h20, 1'b1, 8'h02, 8'h02, 4, "ADC zp decimal");
        check(8'h6D, 8'h00, 8'h03, 8'h20, 1'b1, 8'h02, 8'h02, 5, "ADC abs decimal");

        $display("");
        $display("%0d checks, %0d failures", tested, errors);
        if (errors == 0) $display("CYCLES OK");
        $finish;
    end

    always #5 clk = ~clk;

endmodule
