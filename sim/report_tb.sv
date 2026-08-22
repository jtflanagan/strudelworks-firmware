`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// report_tb - check the UART report end to end, before it costs a build and a
// flash to find out a digit is in the wrong column.
//
// Drives report_tx with known statistics, runs the real uart_tx at the real
// 115200 divisor, and decodes the serial line back into characters by sampling
// mid-bit - so this exercises the baud divisor and the framing, not just the
// formatter.  It then diffs the decoded text against the expected report.
//
// Fast: two reports at 180 bytes is about 3.2 M clocks, a couple of seconds.
//////////////////////////////////////////////////////////////////////////////////

module report_tb;

    localparam integer CLK_HZ = 100_000_000;
    localparam integer BAUD   = 115_200;
    localparam real    BIT_NS = 1_000_000_000.0 / BAUD;

    reg clk = 0, rst = 1, enable = 0;
    always #5 clk = ~clk;                    // 100 MHz

    wire [7:0] tx_data;
    wire       tx_valid, tx_ready, serial;

    report_tx #(
        .CLK_HZ        (CLK_HZ),
        .REPORT_PERIOD (1000)                // fire quickly instead of once a second
    ) dut (
        .clk(clk), .rst(rst), .enable(enable),
        .win_count    (32'd42),
        .seq_min      (16'd10),
        .seq_mean_x10 (32'd104),
        .seq_max      (16'd37),
        .seq_gt_gs    (32'd71),
        .seq_gt_leg   (32'd0),
        .rnd_min      (16'd12),
        .rnd_mean_x10 (32'd121),
        .rnd_max      (16'd37),
        .rnd_gt_gs    (32'd69),
        .rnd_gt_leg   (32'd0),
        .err_count    (32'd0),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .rst(rst),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx(serial)
    );

    // ---- receiver: sample the line the way a real UART would ---------------
    localparam integer MAXCH = 512;
    reg [7:0] got [0:MAXCH-1];
    integer   ngot = 0;
    reg [7:0] rxb;
    integer   bi;

    initial begin
        forever begin
            @(negedge serial);               // start bit
            #(BIT_NS * 1.5);                 // into the middle of bit 0
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rxb[bi] = serial;
                #(BIT_NS);
            end
            if (ngot < MAXCH) begin
                got[ngot] = rxb;
                ngot = ngot + 1;
            end
        end
    end

    // ---- expected ----------------------------------------------------------
    localparam integer ELEN = 180;
    localparam [ELEN*8-1:0] EXPECT = {
        "\015\n-- strudelworks latency  win=00000042  1 cy = 10 ns --\015\n",
        "SEQ min=010 mean=010.4 max=037 gt18=000071 gt49=000000\015\n",
        "RND min=012 mean=012.1 max=037 gt18=000069 gt49=000000\015\n",
        "errors=0\015\n"
    };

    integer i, bad, crlf, nlf;
    reg [7:0] e;

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);
        enable = 1;

        wait (ngot >= ELEN);
        repeat (100) @(posedge clk);

        $write("---- decoded from the serial line ----\n");
        for (i = 0; i < ELEN; i = i + 1) $write("%c", got[i]);
        $write("---- end ----\n");

        bad = 0;
        for (i = 0; i < ELEN; i = i + 1) begin
            e = EXPECT[(ELEN-1-i)*8 +: 8];
            if (got[i] !== e) begin
                if (bad < 10)
                    $display("MISMATCH at %0d: got %0d '%c', expected %0d '%c'",
                             i, got[i], got[i], e, e);
                bad = bad + 1;
            end
        end

        // Independent line-ending check, NOT derived from EXPECT.
        //
        // This exists because the string-versus-string diff above once passed
        // while the output was wrong.  Verilog string literals do NOT define \r
        // as an escape: "\r" is the two characters backslash-r collapsed to a
        // literal 'r' (114), not CR (13).  Both TEMPLATE and EXPECT used "\r\n",
        // so the test compared the bug against itself and reported 180/180.
        // Terminals then showed every line overwritten with no carriage return,
        // plus a stray 'r'.  Asserting the numeric byte values closes that hole:
        // a self-consistent encoding mistake cannot satisfy both checks.
        // The invariant is "every LF is preceded by CR", which needs no magic
        // count - deriving the expectation from the data avoids swapping one
        // miscounted constant for another.  (There are 5, not 4: the report opens
        // with a CRLF to separate it from the previous one.)
        crlf = 0;
        nlf  = 0;
        for (i = 0; i < ELEN; i = i + 1) begin
            if (got[i] == 8'd10) begin
                nlf = nlf + 1;
                if (i > 0 && got[i-1] == 8'd13) crlf = crlf + 1;
                else begin
                    $display("BAD LINE ENDING: LF at %0d not preceded by CR", i);
                    bad = bad + 1;
                end
            end
        end
        $display("line endings: %0d LF, %0d of them CRLF", nlf, crlf);
        if (nlf == 0) begin
            $display("BAD: no line endings at all");
            bad = bad + 1;
        end

        if (bad == 0) $display("REPORT OK: %0d bytes match exactly, line endings CRLF", ELEN);
        else          $display("REPORT FAILED: %0d problems", bad);
        $finish;
    end

    initial begin
        #50_000_000;                          // 50 ms
        $display("TIMEOUT: only %0d bytes received", ngot);
        $finish;
    end

endmodule
