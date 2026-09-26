`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// flash_ctrl_tb - the card's flash block (rtl/common/flash_ctrl.sv) behind the real
// reg_bridge, against sim/sst26_model.sv, and the IPROG sequencer
// (rtl/common/iprog.sv) that LINK_RESET drives (docs/BOOT_LOADER.md BL2).
//
// The bench is the host: REG_READ / REG_WRITE / FLASH_PAGE messages at the message
// layer's outputs, replies from reg_bridge.  It builds a package the way the build
// will (a record whose CRCs it computes itself, and a bitstream) and loads it the
// way the host will: ERASE, the bitstream's pages from 0 stop-and-wait, the record's
// page at REC_ADDR last, QUERY.  The checks:
//   1. at reset: FLASH_ID = BF2642 (read by the block itself), BOOT_ID, the layout;
//   2. QUERY on a flash with no record: NO_RECORD, not verified;
//   3. ERASE with a zero length, or longer than the image's room, refused (BAD_ARG);
//   4. the load: ERASE, every page acknowledged, QUERY OK and verified, REC holds the
//      record; the blocks past the image (seeded) untouched;
//   5. a page written after QUERY clears verified; a page of the wrong length is
//      refused and counted;
//   6. one bit of the bitstream changed: IMAGE_CRC; the record's own CRC broken:
//      RECORD_CRC; a record for another part: BAD_PART;
//   7. a load that stops after its ERASE leaves no record: NO_RECORD;
//   8. a write's reply carries the value the register holds afterwards;
//   9. iprog: the nine ICAP words, bit-swapped back, are UG470's IPROG with WBSTAR 0;
//  10. no model violation.
//////////////////////////////////////////////////////////////////////////////////
module flash_ctrl_tb;
    localparam logic [31:0] A_BOOT_ID = 32'h8000_0F00, A_CMD = 32'h8000_0F08,
                            A_ADDR = 32'h8000_0F0C, A_LEN = 32'h8000_0F10, A_STAT = 32'h8000_0F14,
                            A_PAGES = 32'h8000_0F18, A_ID = 32'h8000_0F1C, A_IMGEND = 32'h8000_0F24,
                            A_RECADDR = 32'h8000_0F28, A_REC = 32'h8000_0F40;
    localparam logic [3:0] C_QUERY = 4'd2, C_ERASE = 4'd3;
    localparam logic [3:0] R_OK = 4'd0, R_NO_RECORD = 4'd3, R_RECORD_CRC = 4'd4,
                           R_IMAGE_CRC = 4'd5, R_BAD_PART = 4'd6, R_BAD_ARG = 4'd7;
    localparam int REC  = 'h3FF000;
    localparam int NBIT = 70000;                // bytes of "bitstream": crosses the 8/32/64 KB blocks
    localparam int FAR  = 'h200000;             // seeded, and never part of this image
    localparam logic [31:0] IDCODE = 32'h13631093;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    task check(input bit ok, input string what);
        if (!ok) begin $display("FAIL: %s", what); errors++; end
        else $display("  ok: %s", what);
    endtask

    // ---- the host side of the message layer -------------------------------------
    reg         rst = 1'b1;
    reg         msg_valid = 1'b0, pay_valid = 1'b0;
    reg  [7:0]  msg_type = '0, msg_len = '0;
    reg  [31:0] pay_data = '0;
    wire        wb_cyc, wb_stb, wb_we, wb_ack;
    wire [31:0] wb_adr, wb_dat_w, wb_dat_r;
    wire [3:0]  wb_sel;
    wire [31:0] rsp_addr, rsp_data;
    wire        rsp_valid;
    reg         rsp_take = 1'b0;

    reg_bridge u_bridge (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .pay_data (pay_data), .pay_valid (pay_valid),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we), .wb_adr (wb_adr), .wb_dat_w (wb_dat_w),
        .wb_sel (wb_sel), .wb_ack (wb_ack), .wb_stall (1'b0), .wb_dat_r (wb_dat_r),
        .rsp_addr (rsp_addr), .rsp_data (rsp_data), .rsp_valid (rsp_valid), .rsp_take (rsp_take)
    );

    wire sck, cs_n, mosi, miso, wp_n, hold_n;

    flash_ctrl #(.IDCODE (IDCODE), .HALF (2), .TIMEOUT_CLKS (20_000)) dut (
        .clk (clk), .rst (rst), .stage (8'd1),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we), .wb_adr (wb_adr), .wb_dat_w (wb_dat_w),
        .wb_ack (wb_ack), .wb_dat_r (wb_dat_r),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .spi_sck (sck), .spi_cs_n (cs_n), .spi_mosi (mosi), .spi_miso (miso),
        .spi_wp_n (wp_n), .spi_hold_n (hold_n)
    );
    sst26_model #(.T_ERASE_NS (20_000.0), .T_PROG_NS (2_000.0)) flash (
        .sck (sck), .cs_n (cs_n), .si (mosi), .so (miso), .wp_n (wp_n), .hold_n (hold_n)
    );

    reg         iprog_req = 1'b0;
    wire        icap_csib, icap_rdwrb;
    wire [31:0] icap_i;
    iprog u_iprog (
        .clk (clk), .rst (rst), .req (iprog_req), .addr (24'h000000),
        .icap_csib (icap_csib), .icap_rdwrb (icap_rdwrb), .icap_i (icap_i), .busy ()
    );
    logic [31:0] icap_words [$];
    always @(posedge clk) if (!icap_csib && !icap_rdwrb) icap_words.push_back(icap_i);

    // ---- host helpers ---------------------------------------------------------------
    task automatic hdr(input logic [7:0] t, input logic [7:0] n);
        @(negedge clk); msg_valid = 1'b1; msg_type = t; msg_len = n;
        @(negedge clk); msg_valid = 1'b0;
    endtask
    task automatic word(input logic [31:0] w);
        @(negedge clk); pay_valid = 1'b1; pay_data = w;
        @(negedge clk); pay_valid = 1'b0;
    endtask
    task automatic reply(output logic [31:0] v);
        while (!rsp_valid) @(negedge clk);
        v = rsp_data;
        rsp_take = 1'b1; @(negedge clk); rsp_take = 1'b0;
    endtask
    task automatic rd(input logic [31:0] a, output logic [31:0] v);
        hdr(8'h14, 8'd1); word(a); reply(v);
    endtask
    task automatic wr(input logic [31:0] a, input logic [31:0] d, output logic [31:0] v);
        hdr(8'h15, 8'd2); word(a); word(d); reply(v);
    endtask
    task automatic cmd(input logic [3:0] c, output logic [3:0] r);
        logic [31:0] s0, s, v;
        rd(A_STAT, s0);
        wr(A_CMD, {28'd0, c}, v);
        do rd(A_STAT, s); while (s[0] || s[23:16] == s0[23:16]);
        r = s[11:8];
    endtask
    task automatic page(input int a, input logic [7:0] b [], input int off, output bit ok);
        logic [31:0] p0, p, s;
        rd(A_PAGES, p0);
        hdr(8'h40, 8'd65);
        word(32'(a));
        for (int w = 0; w < 64; w++)
            word({b[off + 4*w + 3], b[off + 4*w + 2], b[off + 4*w + 1], b[off + 4*w]});
        do rd(A_PAGES, p); while (p == p0);
        do rd(A_STAT, s); while (s[0]);
        ok = (p[15:0] == p0[15:0] + 16'd1) && (p[31:16] == p0[31:16]);
    endtask

    function automatic logic [31:0] crc32(input logic [7:0] b [], input int off, input int n);
        logic [31:0] c;
        c = 32'hFFFFFFFF;
        for (int i = 0; i < n; i++) begin
            c = c ^ {24'd0, b[off + i]};
            for (int j = 0; j < 8; j++) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        end
        return ~c;
    endfunction
    function automatic logic [7:0] far_pat(input int a);
        return 8'((a ^ (a >> 8)) + 8'h3C);
    endfunction
    function automatic logic [31:0] unswap(input logic [31:0] w);
        logic [31:0] s;
        for (int b = 0; b < 4; b++) for (int i = 0; i < 8; i++) s[8*b + i] = w[8*b + 7 - i];
        return s;
    endfunction

    // bits[] the bitstream padded to pages; recb[] the record's 256-byte page
    logic [7:0] bits [];
    logic [7:0] recb [];
    logic [31:0] recw [0:15];
    task automatic build_record(input logic [31:0] idcode, input bit break_crc);
        recw[0] = 32'h4B525753; recw[1] = 32'd1; recw[2] = 32'(NBIT);
        recw[3] = crc32(bits, 0, NBIT); recw[4] = idcode; recw[5] = 32'h0000_0201;
        recw[6] = 32'd1; recw[7] = 32'd20260925; recw[8] = 32'd120000;
        for (int i = 9; i < 15; i++) recw[i] = 32'd0;
        for (int i = 0; i < 256; i++) recb[i] = 8'hFF;
        for (int i = 0; i < 15; i++) for (int k = 0; k < 4; k++) recb[4*i + k] = recw[i][8*k +: 8];
        recw[15] = crc32(recb, 0, 60) ^ (break_crc ? 32'h1 : 32'h0);
        for (int k = 0; k < 4; k++) recb[60 + k] = recw[15][8*k +: 8];
    endtask
    task automatic load(input bit stop_after_erase, output bit ok);
        logic [31:0] v; logic [3:0] r; bit pok;
        ok = 1;
        wr(A_LEN, 32'(NBIT), v);
        cmd(C_ERASE, r); if (r != R_OK) ok = 0;
        if (stop_after_erase) return;
        for (int p = 0; 256*p < NBIT; p++) begin
            page(256*p, bits, 256*p, pok); if (!pok) ok = 0;
        end
        page(REC, recb, 0, pok); if (!pok) ok = 0;
    endtask

    logic [31:0] v, s;
    logic [3:0]  r;
    bit          ok;
    int          npad;

    initial begin
        for (int a = FAR; a < FAR + 'h10000; a++) flash.poke(a, far_pat(a));
        npad = ((NBIT + 255) / 256) * 256;
        bits = new[npad];
        recb = new[256];
        for (int i = 0; i < npad; i++) bits[i] = (i < NBIT) ? 8'($urandom) : 8'hFF;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // 1
        do rd(A_STAT, s); while (s[0]);
        rd(A_ID, v);      check(v == 32'h00BF2642, $sformatf("FLASH_ID read at reset: %08h", v));
        rd(A_BOOT_ID, v); check(v == 32'h424C0101, $sformatf("BOOT_ID %08h", v));
        rd(A_IMGEND, v);  ok = (v == 32'h3FE000);
        rd(A_RECADDR, v); check(ok && v == 32'(REC), "the layout: IMAGE_END 3FE000, REC_ADDR 3FF000");

        // 2
        cmd(C_QUERY, r); rd(A_STAT, s);
        check(r == R_NO_RECORD && !s[1], $sformatf("QUERY with no record: result %0d, verified %0d", r, s[1]));

        // 3
        wr(A_LEN, 32'd0, v);       cmd(C_ERASE, r); ok = (r == R_BAD_ARG);
        wr(A_LEN, 32'h3FE001, v);  cmd(C_ERASE, r);
        check(ok && r == R_BAD_ARG, "ERASE with a zero length, or past the image's room, refused");

        // 4
        build_record(IDCODE, 0);
        load(0, ok);
        check(ok, "ERASE and every page acknowledged");
        cmd(C_QUERY, r); rd(A_STAT, s);
        check(r == R_OK && s[1], $sformatf("QUERY: result %0d, verified %0d", r, s[1]));
        ok = 1;
        for (int i = 0; i < 16; i++) begin rd(A_REC + 32'(4*i), v); if (v != recw[i]) ok = 0; end
        check(ok, "REC holds the record");
        ok = 1;
        for (int a = FAR; a < FAR + 'h10000; a++) if (flash.peek(a) != far_pat(a)) ok = 0;
        check(ok, "the blocks past the image untouched");

        // 5
        page(FAR + 'h20000, bits, 0, ok);           // somewhere unrelated (erased: fresh)
        rd(A_STAT, s);
        check(ok && !s[1], "a page written after QUERY clears verified");
        rd(A_PAGES, v);
        hdr(8'h40, 8'd3); word(32'h0); word(0); word(0);
        repeat (10) @(negedge clk);
        rd(A_PAGES, s);
        check(s[31:16] == v[31:16] + 16'd1 && s[15:0] == v[15:0], "a page of the wrong length refused and counted");

        // 6
        flash.poke(1234, bits[1234] ^ 8'h10);
        cmd(C_QUERY, r); rd(A_STAT, s);
        check(r == R_IMAGE_CRC && !s[1], $sformatf("a changed bitstream byte: result %0d", r));
        flash.poke(1234, bits[1234]);
        build_record(IDCODE, 1);
        load(0, ok); cmd(C_QUERY, r);
        check(r == R_RECORD_CRC, $sformatf("a record whose own CRC is wrong: result %0d", r));
        build_record(32'h0362D093, 0);               // the Au's xc7a35t
        load(0, ok); cmd(C_QUERY, r);
        check(r == R_BAD_PART, $sformatf("a record for another part: result %0d", r));

        // 7
        build_record(IDCODE, 0);
        load(0, ok); cmd(C_QUERY, r);                // a good image first...
        load(1, ok); cmd(C_QUERY, r);                // ...then a load that stops after ERASE
        check(r == R_NO_RECORD, $sformatf("a load stopped after ERASE leaves no record: result %0d", r));

        // 8
        wr(A_ADDR, 32'h00ABCDEF, v);
        check(v == 32'h00ABCDEF, $sformatf("a write's reply carries the new value (%08h)", v));

        // 9
        @(negedge clk); iprog_req = 1'b1; @(negedge clk); iprog_req = 1'b0;
        repeat (20) @(negedge clk);
        ok = (icap_words.size() == 9);
        if (ok) begin
            logic [31:0] want [0:8];
            want = '{32'hFFFFFFFF, 32'hAA995566, 32'h20000000, 32'h30020001, 32'h00000000,
                     32'h20000000, 32'h30008001, 32'h0000000F, 32'h20000000};
            for (int i = 0; i < 9; i++) if (unswap(icap_words[i]) != want[i]) ok = 0;
        end
        check(ok, $sformatf("iprog: UG470's IPROG with WBSTAR 0 (%0d ICAP words)", icap_words.size()));

        // 10
        check(flash.violations == 0, $sformatf("no model violations (%0d)", flash.violations));

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d", errors);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
