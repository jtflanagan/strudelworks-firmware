`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// rom_loader_tb - the formal ROM load (docs/CLEAN_START.md CS2).
//
// rtl/rom_loader.sv with REQUIRE_HOLD, 32 chunks, a host model sending MEM_ROM
// messages the way ft601_msg_rx hands them over (a header strobe, then one
// strobe per payload word), the posted-write seam always taking, and every
// MEM_ROM_ACK collected.  The checks:
//   1. not held: refused, acked NOT_HELD with the chunk number, nothing drained;
//   2. held: every chunk acked OK once its 512 bytes drained, with the sum of
//      those bytes; rom_ok once all 32 have; rom_sum the whole ROM's sum;
//   3. a chunk arriving while another drains: acked OVERRUN, counted, dropped;
//   4. a wrong length: acked BAD_LEN; a chunk number past the ROM: BAD_INDEX;
//   5. a chunk sent again after landing (a retry): acked OK with its sum,
//      rom_sum unchanged.
//////////////////////////////////////////////////////////////////////////////////
module rom_loader_tb;
    localparam integer N = 32;
    localparam [7:0] T_MEM_ROM = 8'h22;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    integer errors = 0;
    task check(input bit ok, input [1023:0] what);
        begin
            if (!ok) begin $display("FAIL: %0s", what); errors = errors + 1; end
            else $display("  ok: %0s", what);
        end
    endtask

    reg        rst = 1'b1, hold = 1'b0;
    reg        msg_valid = 1'b0, pay_valid = 1'b0;
    reg [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    reg [31:0] pay_data = 32'd0;
    wire       pw_valid, busy, rom_ok, ack_valid;
    wire [15:0] pw_ppn;
    wire [7:0]  pw_off, pw_data, overruns;
    wire [31:0] ack_word, rom_sum;

    rom_loader #(.N_CHUNKS (N), .ROM_PPN0 (16'hFFC0), .REQUIRE_HOLD (1'b1)) dut (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .op_present (1'b0), .image_ready (1'b1),
        .pw_valid (pw_valid), .pw_ppn (pw_ppn), .pw_off (pw_off), .pw_data (pw_data),
        .pw_take (pw_valid),
        .busy (busy), .overruns (overruns), .rom_ok (rom_ok),
        .hold (hold), .ack_word (ack_word), .ack_valid (ack_valid), .ack_take (ack_valid),
        .rom_sum (rom_sum)
    );

    // ---- the ROM image and its sums ----------------------------------------
    function automatic [31:0] rom_word(input integer c, input integer w);
        rom_word = (c * 32'h01000193) ^ (w * 32'h9E3779B9) ^ 32'h5A5AA5A5;
    endfunction
    function automatic [16:0] chunk_sum(input integer c);
        integer w, b;
        reg [16:0] s;
        begin
            s = 17'd0;
            for (w = 0; w < 128; w = w + 1)
                for (b = 0; b < 4; b = b + 1) s = s + 17'((rom_word(c, w) >> (8 * b)) & 8'hFF);
            chunk_sum = s;
        end
    endfunction

    // ---- drained bytes, counted ---------------------------------------------
    integer drained = 0;
    always @(posedge clk) if (pw_valid) drained = drained + 1;

    // ---- acks, collected ------------------------------------------------------
    integer n_acks = 0;
    reg [31:0] last_payload = 32'd0;
    reg        expect_payload = 1'b0;
    always @(posedge clk) begin
        if (ack_valid) begin
            if (!expect_payload) begin
                if (ack_word !== {16'd0, 8'h36, 8'd1}) begin
                    $display("FAIL: an ack header read %08x", ack_word); errors = errors + 1;
                end
                expect_payload <= 1'b1;
            end else begin
                last_payload   <= ack_word;
                n_acks         <= n_acks + 1;
                expect_payload <= 1'b0;
            end
        end
    end
    function automatic [3:0] ack_status(input [31:0] p); ack_status = p[15:12]; endfunction
    function automatic [11:0] ack_chunk(input [31:0] p);  ack_chunk = p[11:0];   endfunction
    function automatic [15:0] ack_sum(input [31:0] p);    ack_sum = p[31:16];    endfunction

    // ---- the host model ----------------------------------------------------------
    task send(input integer c, input integer len, input integer index);
        integer w;
        begin
            @(negedge clk);
            msg_valid = 1'b1; msg_type = T_MEM_ROM; msg_len = 8'(len);
            @(negedge clk);
            msg_valid = 1'b0;
            for (w = 0; w < len; w = w + 1) begin
                pay_valid = 1'b1;
                pay_data  = (w == 0) ? 32'(index) : rom_word(c, w - 1);
                @(negedge clk);
            end
            pay_valid = 1'b0;
        end
    endtask
    task wait_ack(input integer n0);
        integer t;
        begin
            for (t = 0; t < 4000 && n_acks == n0; t = t + 1) @(posedge clk);
            @(posedge clk);
        end
    endtask

    integer c, n0, bad;
    reg [31:0] total;
    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // 1. not held
        n0 = n_acks;
        send(3, 129, 3);
        wait_ack(n0);
        check(n_acks == n0 + 1 && ack_status(last_payload) == 4'd2 && ack_chunk(last_payload) == 12'd3,
              "not held: refused, acked NOT_HELD naming chunk 3");
        check(drained == 0 && !rom_ok, "...and nothing drained");

        // 2. held: the whole ROM
        hold = 1'b1;
        bad = 0; total = 32'd0;
        for (c = 0; c < N; c = c + 1) begin
            n0 = n_acks;
            send(c, 129, c);
            wait_ack(n0);
            if (!(ack_status(last_payload) == 4'd0 && ack_chunk(last_payload) == 12'(c) &&
                  ack_sum(last_payload) == 16'(chunk_sum(c)))) bad = bad + 1;
            total = total + 32'(chunk_sum(c));
        end
        check(bad == 0, "held: every chunk acked OK, naming itself, with the sum of its bytes");
        check(drained == N * 512, "...all 32 x 512 bytes drained to the seam");
        check(rom_ok, "...and rom_ok is set");
        check(rom_sum == total, "...and rom_sum is the whole ROM's sum");

        // 3. overrun: send one, then another while it drains
        n0 = n_acks;
        send(5, 129, 5);
        send(6, 129, 6);
        wait_ack(n0);
        wait_ack(n0 + 1);
        check(overruns == 8'd1, "a chunk sent while one drains is counted as an overrun");
        check(n_acks == n0 + 2, "...both get an ack");
        check(ack_status(last_payload) == 4'd0 && ack_chunk(last_payload) == 12'd5,
              "...the draining one's OK comes last, after the refusal");

        // 4. a wrong length, a chunk past the ROM
        n0 = n_acks;
        send(7, 10, 7);
        wait_ack(n0);
        check(ack_status(last_payload) == 4'd3 && ack_chunk(last_payload) == 12'd7, "a wrong length: acked BAD_LEN naming its chunk");
        n0 = n_acks;
        send(0, 129, 40);
        wait_ack(n0);
        check(ack_status(last_payload) == 4'd4 && ack_chunk(last_payload) == 12'd40, "a chunk past the ROM: acked BAD_INDEX");

        // 5. a retry of a landed chunk
        n0 = n_acks;
        total = rom_sum;
        send(9, 129, 9);
        wait_ack(n0);
        check(ack_status(last_payload) == 4'd0 && ack_sum(last_payload) == 16'(chunk_sum(9)),
              "a chunk sent again after landing: acked OK with its sum");
        check(rom_sum == total, "...and rom_sum does not count it twice");

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
