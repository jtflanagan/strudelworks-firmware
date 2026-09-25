`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// flash_exec_tb - rtl/common/flash_exec.sv against sim/sst26_model.sv
// (docs/BOOT_LOADER.md BL1).
//
// The golden region (0x000000-0x0FFFFF) is seeded with a pattern first and
// checked at the end: whatever the executor did, golden is untouched.  The
// checks:
//   1. the post-configuration dummy clocks come before the first command;
//   2. OP_ID reads BF 26 42;
//   3. an erase before OP_UNLOCK is sent but IGNORED by the chip (nothing changes);
//   4. the fence: erase/program in golden, unaligned, or past the user region are
//      refused with nothing sent;
//   5. OP_UNLOCK against a chip that drops the WBPR reports E_BPR;
//   6. OP_UNLOCK clears exactly the user region's write-locks;
//   7. erase then program then read: CRC32 of "123456789" is CBF43926 (the check
//      value), and the buffer holds the bytes read;
//   8. sixteen pages programmed and read back as one 4 KB read: the CRC is the
//      bench's own, and the buffer holds the first 256 bytes;
//   9. OP_READ with a zero length or past the end is refused;
//  10. a BUSY that never clears ends in E_TIMEOUT, the executor idle, and the next
//      command works;
//  11. at the end: no model violation, exactly one command ignored by the chip
//      (check 3's), golden intact.
// Stimulus changes on the falling edge (memory bench-stimulus-on-negedge).
//////////////////////////////////////////////////////////////////////////////////
module flash_exec_tb;
    localparam logic [2:0] OP_ID = 3'd1, OP_UNLOCK = 3'd2, OP_ERASE = 3'd3,
                           OP_PROG = 3'd4, OP_READ = 3'd5;
    localparam logic [2:0] E_NONE = 3'd0, E_FENCE = 3'd1, E_TIMEOUT = 3'd2,
                           E_BPR = 3'd3, E_ARG = 3'd4;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    task check(input bit ok, input string what);
        if (!ok) begin $display("FAIL: %s", what); errors++; end
        else $display("  ok: %s", what);
    endtask

    // ---- DUT and flash ----------------------------------------------------
    reg         rst = 1'b1;
    reg         cmd_valid = 1'b0;
    reg  [2:0]  cmd_op = '0;
    reg  [23:0] cmd_addr = '0, cmd_len = '0;
    wire        busy, done;
    wire [2:0]  err;
    wire [23:0] id;
    wire [31:0] crc;
    reg         buf_we = 1'b0;
    reg  [5:0]  buf_waddr = '0, buf_raddr = '0;
    reg  [31:0] buf_wdata = '0;
    wire [31:0] buf_rdata;
    wire sck, cs_n, mosi, miso, wp_n, hold_n;

    flash_exec #(.HALF (2), .TIMEOUT_CLKS (20_000)) dut (
        .clk (clk), .rst (rst),
        .cmd_valid (cmd_valid), .cmd_op (cmd_op), .cmd_addr (cmd_addr), .cmd_len (cmd_len),
        .busy (busy), .done (done), .err (err), .id (id), .crc (crc),
        .buf_we (buf_we), .buf_waddr (buf_waddr), .buf_wdata (buf_wdata),
        .buf_raddr (buf_raddr), .buf_rdata (buf_rdata),
        .spi_sck (sck), .spi_cs_n (cs_n), .spi_mosi (mosi), .spi_miso (miso),
        .spi_wp_n (wp_n), .spi_hold_n (hold_n)
    );
    sst26_model #(.T_ERASE_NS (20_000.0), .T_PROG_NS (2_000.0)) flash (
        .sck (sck), .cs_n (cs_n), .si (mosi), .so (miso), .wp_n (wp_n), .hold_n (hold_n)
    );

    // ---- helpers ------------------------------------------------------------
    task automatic run(input logic [2:0] op, input logic [23:0] a, input logic [23:0] n,
                       output logic [2:0] e);
        @(negedge clk);
        cmd_valid = 1'b1; cmd_op = op; cmd_addr = a; cmd_len = n;
        @(negedge clk);
        cmd_valid = 1'b0;
        while (!done) @(negedge clk);
        e = err;
        @(negedge clk);
    endtask

    task automatic buf_write(input int w, input logic [31:0] d);
        @(negedge clk);
        buf_we = 1'b1; buf_waddr = 6'(w); buf_wdata = d;
        @(negedge clk);
        buf_we = 1'b0;
    endtask

    task automatic buf_byte(input int k, output logic [7:0] b);
        buf_raddr = 6'(k / 4);
        #1;
        b = buf_rdata[8 * (k % 4) +: 8];
    endtask

    function automatic logic [31:0] crc32_ref(input logic [7:0] b [], input int n);
        logic [31:0] c;
        c = 32'hFFFFFFFF;
        for (int i = 0; i < n; i++) begin
            c = c ^ {24'd0, b[i]};
            for (int j = 0; j < 8; j++) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        end
        return ~c;
    endfunction

    function automatic logic [7:0] golden_pat(input int a);
        return 8'((a ^ (a >> 8) ^ (a >> 16)) + 8'h5A);
    endfunction
    function automatic logic [7:0] page_pat(input int i);
        return 8'(i * 7 + 3);
    endfunction

    logic [2:0] e;
    int         cmds_before, ign_before;
    bit         ok;
    logic [7:0] bytes [];
    logic [7:0] bb;

    initial begin
        // seed golden, and old user data under the first user block
        for (int a = 0; a < 'h100000; a++) flash.poke(a, golden_pat(a));
        for (int a = 'h100000; a < 'h100100; a++) flash.poke(a, 8'h00);

        repeat (4) @(negedge clk);
        rst = 1'b0;
        while (busy) @(negedge clk);

        // 1
        check(flash.dummy_clocks >= 3,
              $sformatf("dummy clocks before the first command (%0d)", flash.dummy_clocks));

        // 2
        run(OP_ID, '0, '0, e);
        check(e == E_NONE && id == 24'hBF2642, $sformatf("OP_ID reads %06h", id));

        // 3
        ign_before = flash.ignored;
        run(OP_ERASE, 24'h100000, '0, e);
        check(e == E_NONE && flash.ignored == ign_before + 1 && flash.peek('h100000) == 8'h00,
              "an erase before OP_UNLOCK is sent, ignored by the chip, and changes nothing");

        // 4
        cmds_before = flash.commands;
        run(OP_ERASE, 24'h0F0000, '0, e);  check(e == E_FENCE, "erase in golden refused");
        run(OP_PROG,  24'h0FFF00, '0, e);  check(e == E_FENCE, "program in golden refused");
        run(OP_ERASE, 24'h100100, '0, e);  check(e == E_FENCE, "unaligned erase refused");
        run(OP_PROG,  24'h100080, '0, e);  check(e == E_FENCE, "unaligned program refused");
        run(OP_ERASE, 24'h3F0000, '0, e);  check(e == E_FENCE, "erase past the user region refused");
        run(OP_PROG,  24'h3FFF00, '0, e);  check(e == E_FENCE, "program past the user region refused");
        check(flash.commands == cmds_before, "nothing reached the chip for a refused command");

        // 5
        flash.drop_wbpr = 1;
        run(OP_UNLOCK, '0, '0, e);
        check(e == E_BPR, "OP_UNLOCK reports E_BPR when the chip does not take the WBPR");
        flash.drop_wbpr = 0;

        // 6
        run(OP_UNLOCK, '0, '0, e);
        check(e == E_NONE && flash.bpr == 80'h5555_C0000000_00007FFF,
              $sformatf("OP_UNLOCK: BPR %020h (user blocks 0x100000-0x3EFFFF only)", flash.bpr));

        // 7
        run(OP_ERASE, 24'h100000, '0, e);
        ok = (e == E_NONE);
        for (int a = 'h100000; a < 'h110000; a++) if (flash.peek(a) != 8'hFF) ok = 0;
        check(ok, "the first user block erased");
        buf_write(0, 32'h34333231);         // "1234"
        buf_write(1, 32'h38373635);         // "5678"
        buf_write(2, 32'hFFFFFF39);         // "9"
        for (int w = 3; w < 64; w++) buf_write(w, 32'hFFFFFFFF);
        run(OP_PROG, 24'h100000, '0, e);
        check(e == E_NONE, "program the check string");
        for (int w = 0; w < 64; w++) buf_write(w, 32'h0);    // so a read must refill it
        run(OP_READ, 24'h100000, 24'd9, e);
        check(e == E_NONE && crc == 32'hCBF43926,
              $sformatf("CRC32 of \"123456789\" read back = %08h (check value CBF43926)", crc));
        ok = 1;
        for (int k = 0; k < 9; k++) begin buf_byte(k, bb); if (bb != 8'h31 + 8'(k)) ok = 0; end
        check(ok, "the buffer holds the bytes read");

        // 8
        run(OP_ERASE, 24'h110000, '0, e);
        for (int p = 0; p < 16; p++) begin
            for (int w = 0; w < 64; w++)
                buf_write(w, {page_pat(p*256 + 4*w + 3), page_pat(p*256 + 4*w + 2),
                              page_pat(p*256 + 4*w + 1), page_pat(p*256 + 4*w)});
            run(OP_PROG, 24'h110000 + 24'(p * 256), '0, e);
            if (e != E_NONE) check(0, $sformatf("program page %0d", p));
        end
        bytes = new[4096];
        for (int i = 0; i < 4096; i++) bytes[i] = page_pat(i);
        run(OP_READ, 24'h110000, 24'd4096, e);
        check(e == E_NONE && crc == crc32_ref(bytes, 4096),
              $sformatf("16 pages read back as one: CRC %08h, expected %08h", crc, crc32_ref(bytes, 4096)));
        ok = 1;
        for (int k = 0; k < 256; k++) begin buf_byte(k, bb); if (bb != page_pat(k)) ok = 0; end
        check(ok, "the buffer holds the read's first 256 bytes");

        // 9
        run(OP_READ, 24'h100000, 24'd0, e);   check(e == E_ARG, "a zero-length read refused");
        run(OP_READ, 24'h3FFF00, 24'd512, e); check(e == E_ARG, "a read past the end refused");

        // 10
        flash.stick_next = 1;
        run(OP_ERASE, 24'h120000, '0, e);
        check(e == E_TIMEOUT && !busy, "a BUSY that never clears ends in E_TIMEOUT, the executor idle");
        flash.stuck = 0;
        run(OP_ID, '0, '0, e);
        check(e == E_NONE && id == 24'hBF2642, "the next command works");

        // 11
        check(flash.violations == 0, $sformatf("no model violations (%0d)", flash.violations));
        check(flash.ignored == 1, $sformatf("exactly one command ignored by the chip (%0d)", flash.ignored));
        ok = 1;
        for (int a = 0; a < 'h100000; a++) if (flash.peek(a) != golden_pat(a)) ok = 0;
        check(ok, "golden 0x000000-0x0FFFFF intact");

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
