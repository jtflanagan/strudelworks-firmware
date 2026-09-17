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
    wire [7:0]  pw_off, pw_data, overruns, xlanded;
    wire [31:0] ack_word, rom_sum;

    rom_loader #(.N_CHUNKS (N), .ROM_PPN0 (16'hFFC0), .REQUIRE_HOLD (1'b1),
                 .ABS_EN (1'b1), .ABS_LO (8'hE2), .ABS_HI (8'hEE)) dut (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .op_present (1'b0), .image_ready (1'b1),
        .pw_valid (pw_valid), .pw_ppn (pw_ppn), .pw_off (pw_off), .pw_data (pw_data),
        .pw_take (pw_valid),
        .busy (busy), .overruns (overruns), .xlanded (xlanded), .rom_ok (rom_ok),
        .hold (hold), .ack_word (ack_word), .ack_valid (ack_valid), .ack_take (ack_valid),
        .rom_sum (rom_sum)
    );

    // ---- the ROM image and its sums ----------------------------------------
    // `salt` makes a DIFFERENT ROM for the replacement test (5b); 0 otherwise.
    reg [31:0] salt = 32'd0;
    function automatic [31:0] rom_word(input integer c, input integer w);
        rom_word = (c * 32'h01000193) ^ (w * 32'h9E3779B9) ^ 32'h5A5AA5A5 ^ salt;
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
    // ...and WHERE they landed, for the absolute chunks: the first and last
    // page and offset seen since the marker was cleared, so a chunk can be
    // checked to have gone to the two pages the host named and no others.
    integer   seam_n = 0;
    reg [15:0] seam_ppn_first, seam_ppn_last;
    reg [7:0]  seam_off_first, seam_off_last, seam_data_first;
    always @(posedge clk) if (pw_valid) begin
        if (seam_n == 0) begin
            seam_ppn_first  <= pw_ppn;
            seam_off_first  <= pw_off;
            seam_data_first <= pw_data;
        end
        seam_ppn_last <= pw_ppn;
        seam_off_last <= pw_off;
        seam_n = seam_n + 1;
    end

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

        // 1b. AN ABSOLUTE CHUNK BEFORE THE BASE ROM IS WHOLE (the card's
        //     extended ROM, docs/GS_CONTROL_PANEL.md R2).  It lands, and
        //     rom_ok stays FALSE: the panel's banks satisfy nothing that the
        //     start hold waits on.  Tested here because once the ROM below
        //     has loaded, rom_ok is true for its own good reason and this
        //     property can no longer be seen.
        hold = 1'b1;
        n0 = n_acks; seam_n = 0;
        send(5, 129, 32'h8000_E200);
        wait_ack(n0);
        check(ack_status(last_payload) == 4'd0 && seam_n == 512,
              "an absolute chunk lands before the base ROM is whole");
        check(!rom_ok, "...and rom_ok stays false: an absolute chunk satisfies nothing");
        check(xlanded == 8'd1 && rom_sum == 32'd0,
              "...counted in xlanded, absent from rom_sum");
        drained = 0;        // below counts the BASE ROM's own bytes

        // 2. held: the whole ROM
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

        // 5b. A DIFFERENT ROM REPLACES THE LANDED ONE.  The host sends the ROM
        // on every start (the user, 2026-09-16), and a start may change ROMs
        // (a panel's patched image, then a stock one).  `seen` and `rom_sum`
        // used to be kept from the card's reset, so the second ROM's bytes went
        // in while rom_sum stayed the FIRST ROM's - the host's check failed and
        // the machine ran whatever was left.  Chunk 0 now begins a load.
        // `rom_word` carries a salt the task below sets, so the second ROM
        // differs in every chunk.
        begin
            integer salted, bad2;
            salt = 32'h5A5A_0000;
            n0 = n_acks;
            send(0, 129, 0);
            wait_ack(n0);
            check(!rom_ok, "a new load's chunk 0: rom_ok drops until the new ROM is whole");
            bad2 = 0; total = 32'd0;
            total = total + 32'(chunk_sum(0));
            for (c = 1; c < N; c = c + 1) begin
                n0 = n_acks;
                send(c, 129, c);
                wait_ack(n0);
                if (ack_status(last_payload) != 4'd0) bad2 = bad2 + 1;
                total = total + 32'(chunk_sum(c));
            end
            check(bad2 == 0 && rom_ok, "...and the whole second ROM lands");
            check(rom_sum == total, "...with rom_sum the SECOND ROM's, not the first's");
            salt = 32'd0;
        end

        // 6. THE CARD'S EXTENDED ROM: an ABSOLUTE chunk (word 0 bit 31), whose
        //    low sixteen bits are the page it lands on rather than an index
        //    counted from ROM_PPN0 (docs/GS_CONTROL_PANEL.md R2).
        n0 = n_acks;
        total = rom_sum;
        seam_n = 0;
        send(5, 129, 32'h8000_E200);
        wait_ack(n0);
        check(ack_status(last_payload) == 4'd0, "an absolute chunk: acked OK");
        check(ack_chunk(last_payload) == 12'h200, "...named by the low twelve bits of its page");
        check(ack_sum(last_payload) == 16'(chunk_sum(5)), "...with the sum of the bytes sent");
        check(seam_n == 512, "...512 bytes drained");
        check(seam_ppn_first == 16'hE200 && seam_off_first == 8'd0,
              "...starting at $E2/00, offset 0");
        check(seam_ppn_last == 16'hE201 && seam_off_last == 8'hFF,
              "...ending at $E2/01, offset $FF - a chunk is two pages");
        check(seam_data_first == 8'(rom_word(5, 0) & 32'hFF), "...and the first byte is the one sent");
        check(xlanded == 8'd2, "...counted in xlanded");
        check(rom_sum == total, "...and it is NOT part of the base ROM's sum");

        //    The far end of the range, and then one past it in both
        //    directions: an absolute chunk must not be able to write outside
        //    the card's own banks.
        n0 = n_acks;
        seam_n = 0;
        send(6, 129, 32'h8000_EE7E);
        wait_ack(n0);
        check(ack_status(last_payload) == 4'd0 && seam_ppn_first == 16'hEE7E,
              "the top bank $EE is taken too");
        check(xlanded == 8'd3, "...and counted");
        n0 = n_acks;
        seam_n = 0;
        send(6, 129, 32'h8000_E100);
        wait_ack(n0);
        check(ack_status(last_payload) == 4'd5, "a page below $E2: acked BAD_PPN");
        check(seam_n == 0, "...and nothing drained");
        n0 = n_acks;
        seam_n = 0;
        send(6, 129, 32'h8000_EF00);
        wait_ack(n0);
        check(ack_status(last_payload) == 4'd5, "a page above $EE: acked BAD_PPN");
        check(seam_n == 0 && xlanded == 8'd3, "...nothing drained, nothing counted");

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
