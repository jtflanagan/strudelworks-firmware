`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// uthernet2_tb - the Uthernet II card behind a model of the sequencer's op
// timing and the real message parser, with the tb playing the driver's side
// of the four slot registers and the host's side of the four messages.
// sim/run_uthernet2_tb.sh.
//
// The op model is the TIGHTEST spacing the sequencer allows for an op on
// the peripherals' view (rtl/uthernet2_card.sv, "The data port's timing"):
// the present on clock P, the byte read at P+1 (registered at the present),
// the commit at P+2, and the next op's present at P+4 - the commit's clock
// + 2.  If the card keeps up here it keeps up under the real dispatcher,
// whose gaps are wider; a bus-paced variant is used for a few sequences so
// both regimes see every rule.
//
// THE PROPERTIES, each a way this is or could be wrong:
//
//   * the reset values AppleWin's Reset leaves, byte for byte, and MR reading
//     0 the op after a program sets its reset bit; the pointer surviving it.
//   * the slot registers: A2/A3 undecoded, the pointer readable, auto-increment
//     on and off, the wraps at $6000 and $8000.
//   * RMSR/TMSR: the regions AppleWin's setRXSizes/setTXSizes lay out, the
//     clamp at 8 KB included, read back through Sn_TX_FSR.
//   * OPEN in every mode sets Sn_SR as AppleWin does, clears the pointers,
//     and the U2_CMD carries the registers as the program would read them.
//   * a SEND moves Sn_TX_RD to Sn_TX_WR at once and the U2_TX chunks carry
//     exactly the bytes between them, across the region's wrap, from an
//     unaligned offset, in more than one chunk when long.
//   * a U2_RX lands at Sn_RX_WR - unaligned, across the wrap - adds to
//     Sn_RX_RSR, and the bytes read back through the data port are the
//     host's, including the word the program had held from before.
//   * RECV recomputes Sn_RX_RSR from Sn_RX_RD.
//   * U2_STAT sets Sn_SR and lands the peer's words; CONNECT and LISTEN take
//     the states AppleWin's do; CLOSE clears.
//   * a program's write burst read back through the same pointer logic.
//   * RES' resets the chip and queues a reset command; nothing is claimed
//     for another slot, an override, or a disabled card.
//   * the message bus backpressured at random never corrupts a message.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module uthernet2_tb;
    localparam [7:0] T_U2_CMD  = 8'h28, T_U2_TX = 8'h29, T_U2_RX = 8'h2A, T_U2_STAT = 8'h2B;
    localparam [2:0] SLOT = 3'd1;
    localparam [15:0] R_MR = 16'hC094, R_AH = 16'hC095, R_AL = 16'hC096, R_DATA = 16'hC097;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    integer errors = 0;
    task fail(input [8*120-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    // ---- host -> card: a FIFO the real parser reads -------------------------
    reg  [31:0] rx_mem [0:16383];
    integer     rx_wr = 0, rx_rd = 0;
    wire        rx_rd_en;
    always @(posedge clk) if (rx_rd_en && !rx_empty) rx_rd <= rx_rd + 1;
    // The FIFO's FWFT face, SAMPLED ON THE FALLING EDGE.  As a continuous
    // assign off rx_mem[rx_rd] this is a Verilator trap: the assign is not
    // re-evaluated when the MEMORY is written while the index stands still,
    // so the first word of every message - pushed while rx_rd sits at the
    // empty mark - reads as the stale initial zero and the parser frames on
    // garbage from there (card->host tests pass throughout, which is what
    // makes it look like an RTL bug).  A negedge sample re-reads every half
    // cycle and lands settled data at the posedge the parser reads on, which
    // is what FWFT means.  See sim/README and the same lesson in
    // sim/mockingboard_tb.sv.
    reg         rx_empty;
    reg  [31:0] rx_dout;
    always @(negedge clk) begin
        rx_empty <= (rx_rd >= rx_wr);
        rx_dout  <= (rx_rd >= rx_wr) ? 32'd0 : rx_mem[rx_rd];
    end
    initial begin rx_empty = 1'b1; rx_dout = 32'd0; end
    task push_word(input [31:0] w);
        begin rx_mem[rx_wr] = w; rx_wr = rx_wr + 1; end
    endtask
    function [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction
    wire        msg_valid, pay_valid, unknown_valid;
    wire [7:0]  unknown_type, unknown_len;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;
    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .unknown_valid (unknown_valid), .unknown_type (unknown_type), .unknown_len (unknown_len)
    );

    // The bytes of a U2_RX to send, packed four a word.
    reg [7:0] hbuf [0:4095];
    task send_rx(input [1:0] sock, input integer n);
        integer i, words; reg [31:0] w;
        begin
            words = (n + 3) / 4;
            push_word(hdr(T_U2_RX, words[7:0], {n[11:0], 2'b00, sock}));
            for (i = 0; i < words; i = i + 1) begin
                w = 32'd0;
                if (4*i   < n) w[7:0]   = hbuf[4*i];
                if (4*i+1 < n) w[15:8]  = hbuf[4*i+1];
                if (4*i+2 < n) w[23:16] = hbuf[4*i+2];
                if (4*i+3 < n) w[31:24] = hbuf[4*i+3];
                push_word(w);
            end
            // Let the parser drain it and the card land the last word.
            repeat (words + 8) @(posedge clk);
            #1;
        end
    endtask
    task send_stat(input [1:0] sock, input [7:0] sr, input has_peer, input [31:0] dipr, input [31:0] dport_w);
        begin
            push_word(hdr(T_U2_STAT, has_peer ? 8'd2 : 8'd0, {sr, 6'd0, sock}));
            if (has_peer) begin push_word(dipr); push_word(dport_w); end
            repeat (8) @(posedge clk);
            #1;
        end
    endtask

    // ---- card -> host: the message stream, backpressured at random ------------
    wire [31:0] tx_word;
    wire        tx_valid;
    reg         tx_take = 1'b1;
    reg  [31:0] out_mem [0:65535];
    integer     out_n = 0;
    integer     parse_pos = 0;
    integer     nogap_n0 = 0;
    always @(posedge clk) begin
        tx_take <= ($urandom % 4) != 0;
        if (tx_valid && tx_take) begin
            out_mem[out_n] <= tx_word;
            out_n <= out_n + 1;
        end
    end
    // Wait for the sender to go quiet: nothing offered for a while.
    task drain;
        integer quiet;
        begin
            quiet = 0;
            while (quiet < 40) begin
                @(posedge clk); #1;
                if (tx_valid) quiet = 0; else quiet = quiet + 1;
            end
        end
    endtask
    // Take the next message off the captured stream.
    integer m_type, m_len, m_free, m_pay;
    task next_msg(input [8*40-1:0] what);
        begin
            if (parse_pos >= out_n) begin
                fail({"no message where one was expected: ", what});
                m_type = -1; m_len = 0; m_free = 0; m_pay = parse_pos;
            end else begin
                m_len  = out_mem[parse_pos][7:0];
                m_type = out_mem[parse_pos][15:8];
                m_free = out_mem[parse_pos][31:16];
                m_pay  = parse_pos + 1;
                parse_pos = parse_pos + 1 + m_len;
            end
        end
    endtask
    task expect_cmd(input [1:0] sock, input [7:0] cmd, input [8*40-1:0] what);
        begin
            next_msg(what);
            if (m_type != T_U2_CMD || m_len != 24 || m_free[1:0] != sock || m_free[15:8] != cmd)
                fail({"U2_CMD wrong: ", what});
        end
    endtask
    function [31:0] cmd_word(input integer i);     // word i of the last U2_CMD's payload
        cmd_word = out_mem[m_pay + i];
    endfunction
    // The next U2_TX chunk(s) must carry exactly these bytes.
    reg [7:0] xbuf [0:8191];
    task expect_tx(input [1:0] sock, input integer n, input [8*40-1:0] what);
        integer got, i, cb, words, first; reg [31:0] w;
        begin
            got = 0; first = 1;
            while (got < n) begin
                next_msg(what);
                if (m_type != T_U2_TX) begin fail({"U2_TX missing: ", what}); got = n; end
                else begin
                    cb    = m_free[15:4];
                    words = (cb + 3) / 4;
                    if (m_free[1:0] != sock) fail({"U2_TX socket: ", what});
                    if (m_len != words) fail({"U2_TX length: ", what});
                    if (m_free[2] != first[0]) fail({"U2_TX first flag: ", what});
                    if (m_free[3] != ((got + cb) >= n)) fail({"U2_TX last flag: ", what});
                    for (i = 0; i < cb; i = i + 1) begin
                        w = out_mem[m_pay + i/4];
                        if (w[8*(i%4) +: 8] !== xbuf[got + i]) begin
                            if (errors < 20) $display("  byte %0d: got %02x want %02x", got + i, w[8*(i%4) +: 8], xbuf[got + i]);
                            fail({"U2_TX bytes: ", what});
                        end
                    end
                    got = got + cb; first = 0;
                end
            end
        end
    endtask

    // ---- the DUT ---------------------------------------------------------------
    reg         master_active = 1'b1;
    reg         res_n = 1'b1;
    reg  [2:0]  slot_assign = SLOT;
    reg  [15:0] op_addr = 16'h0000;
    reg         op_rw = 1'b1, op_present = 1'b0, op_commit = 1'b0, op_ovr = 1'b0;
    reg  [7:0]  op_wdata = 8'h00;
    wire        rd_claim, stall;
    wire [7:0]  rd_data;
    wire [3:0]  sock_open;
    wire        cmd_dropped;
    wire [7:0]  cmds, rx_chunks;
    wire [15:0] s0_rsr, s0_fsr;
    uthernet2_card dut (
        .clk (clk), .rst (rst), .res_sync (res_n), .master_active (master_active),
        .slot_assign (slot_assign),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit), .op_ovr (op_ovr),
        .rd_claim (rd_claim), .rd_data (rd_data),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .tx_word (tx_word), .tx_valid (tx_valid), .tx_take (tx_take),
        .stall_o (stall),
        .sock_open (sock_open), .cmd_dropped (cmd_dropped),
        .cmds_o (cmds), .rx_chunks_o (rx_chunks), .s0_rsr_o (s0_rsr), .s0_fsr_o (s0_fsr)
    );
    integer stall_clocks = 0;
    // The sequencer samples the stall REGISTERED (rtl/gs/accel_seq.sv
    // stall_q), so it can present on the clock after a card raises it - the
    // blind spot the card's interlock has to cover.  The op tasks wait on
    // this copy, not on stall itself, or they hide the blind spot.
    reg stall_q = 1'b0;
    always @(posedge clk) stall_q <= stall;
    always @(posedge clk) if (stall) stall_clocks <= stall_clocks + 1;

    // ---- the op model ---------------------------------------------------------------
    // Tight: present at P, the byte at P+1, the commit at P+2, the next
    // present at P+4.  Slow: a bus cycle's spacing.
    reg slow = 1'b0;
    reg last_claim;
    reg [7:0] last_rd;
    // A stream with NO idle clock: present and commit alternate, so
    // (!op_present && !op_commit) is never true.  Not a hypothetical shape -
    // the IIgs sequencer's fast override path presents an op on the clock an
    // override commits (rtl/gs/accel_seq.sv, S_OVR).
    task op_nogap(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                // The sequencer starts no new op while a card holds it:
                // rtl/gs/accel_seq.sv gates fast_ok, ovr_ok, turbo_ok and
                // disp_pay on !stall_q.  A bench that presents through a
                // stall is not modelling the machine.
                while (stall_q) begin
                    op_present = 1'b0; op_commit = 1'b0;
                    @(posedge clk); #1;
                end
                op_addr = 16'hC0B7; op_rw = 1'b1; op_wdata = 8'h00;
                op_present = 1'b1; op_commit = 1'b0;
                @(posedge clk); #1;
                op_present = 1'b0; op_commit = 1'b1;
                @(posedge clk); #1;
            end
            op_commit = 1'b0;
        end
    endtask
    task op(input [15:0] addr, input rw, input [7:0] wdata);
        begin
            while (stall_q) begin @(posedge clk); #1; end
            op_addr = addr; op_rw = rw; op_wdata = wdata;
            op_present = 1'b1;
            @(posedge clk); #1; op_present = 1'b0;
            last_claim = rd_claim; last_rd = rd_data;
            if (slow) repeat (40) @(posedge clk);
            @(posedge clk); #1; op_commit = 1'b1;
            @(posedge clk); #1; op_commit = 1'b0;
            if (slow) begin repeat (50) @(posedge clk); #1; end
        end
    endtask
    task wr(input [15:0] addr, input [7:0] d);
        begin
            op(addr, 1'b0, d);
            if (last_claim) fail("a write was claimed");
        end
    endtask
    task rd(input [15:0] addr, output [7:0] d);
        begin
            op(addr, 1'b1, 8'h00);
            if (!last_claim) fail("a read of the card was not claimed");
            d = last_rd;
        end
    endtask
    task set_addr(input [15:0] a);
        begin wr(R_AH, a[15:8]); wr(R_AL, a[7:0]); end
    endtask
    task wreg(input [15:0] a, input [7:0] d);
        begin set_addr(a); wr(R_DATA, d); end
    endtask
    task rreg(input [15:0] a, output [7:0] d);
        begin set_addr(a); rd(R_DATA, d); end
    endtask
    task check_reg(input [15:0] a, input [7:0] want, input [8*48-1:0] what);
        reg [7:0] d;
        begin
            rreg(a, d);
            if (d !== want) begin
                $display("  $%04x reads %02x, want %02x", a, d, want);
                fail(what);
            end
        end
    endtask
    task check_reg16(input [15:0] a, input [15:0] want, input [8*48-1:0] what);
        reg [7:0] hi, lo;
        begin
            set_addr(a); rd(R_DATA, hi); rd(R_DATA, lo);
            if ({hi, lo} !== want) begin
                $display("  $%04x reads %04x, want %04x", a, {hi, lo}, want);
                fail(what);
            end
        end
    endtask
    task read_ptr(output [15:0] p);
        reg [7:0] hi, lo;
        begin rd(R_AH, hi); rd(R_AL, lo); p = {hi, lo}; end
    endtask

    // Socket register addresses.
    function [15:0] sreg(input [1:0] n, input [7:0] off);
        sreg = 16'h0400 + {6'd0, n, off};
    endfunction

    // ---- the run --------------------------------------------------------------------
    integer i, k;
    reg [7:0]  d;
    reg [15:0] p;
    reg [31:0] w;
    reg [7:0]  saved_rtr0;
    initial begin
        $display("uthernet2_tb: the Uthernet II at slot %0d", SLOT);
        repeat (4) @(posedge clk); #1; rst = 1'b0;
        repeat (4) @(posedge clk); #1;

        // ---- 1. reset values, AppleWin's Reset ------------------------------------
        rd(R_MR, d);   if (d !== 8'h00) fail("MR at reset");
        rd(16'hC090, d); if (d !== 8'h00) fail("$C0n0 does not alias MR");
        wr(R_MR, 8'h03);                       // indirect, auto-increment, for the 16-bit reads
        check_reg(16'h0017, 8'h07, "RTR0 reset");
        check_reg(16'h0018, 8'hD0, "RTR1 reset");
        check_reg(16'h0019, 8'h08, "RCR reset");
        check_reg(16'h001A, 8'h55, "RMSR reset");
        check_reg(16'h001B, 8'h55, "TMSR reset");
        check_reg(16'h0028, 8'h28, "PTIMER reset (the real chip's)");
        check_reg(16'h0009, 8'h00, "SHAR0 reset");
        for (k = 0; k < 4; k = k + 1) begin
            check_reg(sreg(k, 8'h03), 8'h00, "Sn_SR closed at reset");
            check_reg(sreg(k, 8'h06), 8'hFF, "Sn_DHAR0 reset");
            check_reg(sreg(k, 8'h0B), 8'hFF, "Sn_DHAR5 reset");
            check_reg(sreg(k, 8'h16), 8'h80, "Sn_TTL reset");
            check_reg16(sreg(k, 8'h20), 16'h0800, "Sn_TX_FSR = 2 KB at reset ($55)");
            check_reg16(sreg(k, 8'h26), 16'h0000, "Sn_RX_RSR 0 at reset");
        end
        $display("  ok: reset values");

        // ---- 2. the slot registers and the pointer ----------------------------------
        wr(R_MR, 8'h03);                       // indirect, auto-increment
        rd(R_MR, d); if (d !== 8'h03) fail("MR reads back");
        set_addr(16'h0009);
        for (i = 0; i < 6; i = i + 1) wr(R_DATA, 8'h10 + i[7:0]);   // SHAR
        read_ptr(p); if (p !== 16'h000F) fail("the pointer stepped through SHAR");
        read_ptr(p); if (p !== 16'h000F) fail("reading the address registers moves nothing");
        set_addr(16'h4321); read_ptr(p); read_ptr(p); if (p !== 16'h4321) fail("reading the address registers moves nothing (high byte set)");
        set_addr(16'h0009);
        for (i = 0; i < 6; i = i + 1) begin
            rd(R_DATA, d);
            if (d !== 8'h10 + i[7:0]) fail("SHAR reads back through the auto-increment");
        end
        wr(R_MR, 8'h01);                       // no auto-increment
        set_addr(16'h000A);
        rd(R_DATA, d); rd(R_DATA, d);
        if (d !== 8'h11) fail("without AI the pointer stays");
        read_ptr(p); if (p !== 16'h000A) fail("without AI the pointer reads back unchanged");
        wr(R_MR, 8'h03);
        set_addr(16'h5FFF); rd(R_DATA, d); read_ptr(p);
        if (p !== 16'h4000) fail("AI wraps $5FFF -> $4000");
        set_addr(16'h7FFF); rd(R_DATA, d); read_ptr(p);
        if (p !== 16'h6000) fail("AI wraps $7FFF -> $6000");
        set_addr(16'h4FFF); rd(R_DATA, d); read_ptr(p);
        if (p !== 16'h5000) fail("AI does not wrap inside the TX ring");
        $display("  ok: the slot registers, the pointer and its wraps");

        // ---- 3. the regions from RMSR/TMSR -----------------------------------------------
        wreg(16'h001B, 8'h0A);                 // 4 KB, 4 KB, then nothing
        check_reg16(sreg(0, 8'h20), 16'h1000, "TMSR $0A: socket 0 4 KB");
        check_reg16(sreg(1, 8'h20), 16'h1000, "TMSR $0A: socket 1 4 KB");
        check_reg16(sreg(2, 8'h20), 16'h0000, "TMSR $0A: socket 2 nothing");
        check_reg16(sreg(3, 8'h20), 16'h0000, "TMSR $0A: socket 3 nothing");
        wreg(16'h001B, 8'hFF);                 // 8 KB to socket 0
        check_reg16(sreg(0, 8'h20), 16'h2000, "TMSR $FF: socket 0 8 KB");
        check_reg16(sreg(1, 8'h20), 16'h0000, "TMSR $FF: socket 1 nothing");
        wreg(16'h001B, 8'h00);                 // 1 KB each
        for (k = 0; k < 4; k = k + 1) check_reg16(sreg(k, 8'h20), 16'h0400, "TMSR $00: 1 KB each");
        wreg(16'h001B, 8'h01);                 // 2 KB to socket 0, 1 KB to the rest
        check_reg16(sreg(0, 8'h20), 16'h0800, "TMSR $01: socket 0 2 KB");
        check_reg16(sreg(1, 8'h20), 16'h0400, "TMSR $01: socket 1 1 KB");
        wreg(16'h001A, 8'h00);                 // and the RX side: 1 KB each, for the wraps below
        $display("  ok: RMSR/TMSR regions");

        // ---- 4. OPEN socket 0 in MACRAW, and the U2_CMD ------------------------------
        drain; parse_pos = out_n;              // start the message ledger here
        wreg(sreg(0, 8'h00), 8'h44);           // MACRAW + MAC filter
        wreg(sreg(0, 8'h01), 8'h01);           // OPEN
        check_reg(sreg(0, 8'h01), 8'h00, "Sn_CR reads 0 after a command");
        check_reg(sreg(0, 8'h03), 8'h42, "Sn_SR = SOCK_MACRAW");
        if (sock_open !== 4'b0001) fail("sock_open readback");
        drain;
        expect_cmd(2'd0, 8'h01, "OPEN");
        w = cmd_word(0);  if (w[7:0]  !== 8'h03)      fail("U2_CMD common word 0: MR");
        w = cmd_word(2);  if (w[31:8] !== 24'h121110) fail("U2_CMD common word 2: SHAR0-2");
        w = cmd_word(3);  if (w[23:0] !== 24'h151413) fail("U2_CMD common word 3: SHAR3-5");
        w = cmd_word(6);  if (w !== 32'h010008D0)     fail("U2_CMD common word 6: RTR1, RCR, RMSR $00, TMSR $01");
        w = cmd_word(12); if (w !== 32'h42000044)     fail("U2_CMD socket word 0: MR, CR, IR, SR");
        w = cmd_word(13); if (w !== 32'hFFFF0000)     fail("U2_CMD socket word 1: DHAR0-1");
        w = cmd_word(17); if (w !== 32'h00800000)     fail("U2_CMD socket word 5: TTL");
        w = cmd_word(20); if (w !== 32'h00000008)     fail("U2_CMD socket word 8: FSR = $0800, TX_RD 0");
        $display("  ok: OPEN MACRAW and its U2_CMD");

        // ---- 5. a SEND: 100 bytes from $4000 -----------------------------------------
        set_addr(16'h4000);
        for (i = 0; i < 100; i = i + 1) begin xbuf[i] = 8'hA0 + i[7:0]; wr(R_DATA, xbuf[i]); end
        wreg(sreg(0, 8'h24), 8'h00); wreg(sreg(0, 8'h25), 8'd100);   // TX_WR = 100
        check_reg16(sreg(0, 8'h20), 16'd1948, "FSR before the SEND");
        wreg(sreg(0, 8'h01), 8'h20);           // SEND
        check_reg16(sreg(0, 8'h20), 16'h0800, "FSR full again after the SEND");
        check_reg16(sreg(0, 8'h22), 16'd100, "TX_RD moved to TX_WR");
        drain;
        expect_cmd(2'd0, 8'h20, "SEND");
        w = cmd_word(21); if (w[15:0] !== 16'h6400) fail("U2_CMD socket word 9: TX_WR = 100");
        expect_tx(2'd0, 100, "100 bytes");
        $display("  ok: SEND of 100 bytes");

        // ---- 6. a SEND across the 2 KB region's wrap, unaligned, two chunks --------------
        // Fill to offset 1001 first (901 more bytes), send, then 1500 bytes
        // from 1001: they wrap at 2048 and need two chunks.
        set_addr(16'h4064);
        for (i = 0; i < 901; i = i + 1) begin xbuf[i] = i[7:0] ^ 8'h5A; wr(R_DATA, xbuf[i]); end
        wreg(sreg(0, 8'h24), 8'h03); wreg(sreg(0, 8'h25), 8'hE9);     // TX_WR = 1001
        wreg(sreg(0, 8'h01), 8'h20);
        drain;
        expect_cmd(2'd0, 8'h20, "SEND to 1001");
        expect_tx(2'd0, 901, "901 bytes");
        // 1500 bytes: 1047 at 1001..2047, then 453 from 0.  The driver sets
        // the address back at the wrap, as Contiki's does.
        set_addr(16'h4000 + 16'd1001);
        for (i = 0; i < 1500; i = i + 1) begin
            xbuf[i] = (i * 7 + 3);
            if (i == 1047) set_addr(16'h4000);
            wr(R_DATA, xbuf[i]);
        end
        wreg(sreg(0, 8'h24), 8'h09); wreg(sreg(0, 8'h25), 8'hC5);     // TX_WR = 2501 (1001 + 1500)
        check_reg16(sreg(0, 8'h20), 16'd2048 - 16'd1500, "FSR with 1500 bytes queued");
        wreg(sreg(0, 8'h01), 8'h20);
        drain;
        expect_cmd(2'd0, 8'h20, "SEND 1500");
        expect_tx(2'd0, 1500, "1500 bytes across the wrap");
        $display("  ok: SEND across the wrap in two chunks");

        // ---- 7. U2_RX: a frame lands, RSR counts, the bytes read back ---------------------
        // The RX region of socket 0 is 1 KB at $6000.  A 60-byte frame with
        // its 2-byte header: 62 bytes.
        for (i = 0; i < 62; i = i + 1) hbuf[i] = (i == 0) ? 8'h00 : (i == 1) ? 8'd62 : 8'hC0 + i[7:0];
        send_rx(2'd0, 62);
        check_reg16(sreg(0, 8'h26), 16'd62, "RSR after a 62-byte U2_RX");
        if (s0_rsr !== 16'd62) fail("s0_rsr readback");
        set_addr(16'h6000);
        for (i = 0; i < 62; i = i + 1) begin
            rd(R_DATA, d);
            if (d !== hbuf[i]) begin
                if (errors < 20) $display("  rx byte %0d: got %02x want %02x", i, d, hbuf[i]);
                fail("RX bytes read back");
            end
        end
        // RECV with a partial read: RX_RD = 30 -> RSR 32.
        wreg(sreg(0, 8'h28), 8'h00); wreg(sreg(0, 8'h29), 8'd30);
        wreg(sreg(0, 8'h01), 8'h40);
        check_reg16(sreg(0, 8'h26), 16'd32, "RSR after RECV with RX_RD = 30");
        drain;
        expect_cmd(2'd0, 8'h40, "RECV");
        w = cmd_word(22); if (w[15:0] !== 16'h1E00) fail("U2_CMD socket word 10: RX_RD = 30");
        // Read the rest, RECV.
        wreg(sreg(0, 8'h28), 8'h00); wreg(sreg(0, 8'h29), 8'd62);
        wreg(sreg(0, 8'h01), 8'h40);
        check_reg16(sreg(0, 8'h26), 16'd0, "RSR 0 after RECV of everything");
        drain; expect_cmd(2'd0, 8'h40, "RECV 2");
        $display("  ok: U2_RX, RSR, RECV");

        // ---- 8. the held word: the program has read up to the write pointer,
        //         the host appends into that very word, the program must see it.
        // The pointer sits at $603E (62); the word $603C-$603F is held with
        // the old bytes beyond 62.  Append 900 bytes at 62: unaligned, and
        // long enough to wrap at 1024 (62 + 900 = 962 - no wrap yet); then
        // 200 more to wrap.
        for (i = 0; i < 900; i = i + 1) hbuf[i] = (i * 3 + 1);
        send_rx(2'd0, 900);
        check_reg16(sreg(0, 8'h26), 16'd900, "RSR after the second chunk");
        set_addr(16'h6000 + 16'd62);
        for (i = 0; i < 900; i = i + 1) begin
            rd(R_DATA, d);
            if (d !== hbuf[i]) begin
                if (errors < 20) $display("  rx2 byte %0d: got %02x want %02x", i, d, hbuf[i]);
                fail("RX bytes after an append into the held word");
            end
        end
        wreg(sreg(0, 8'h28), 8'h03); wreg(sreg(0, 8'h29), 8'hC2);     // RX_RD = 962
        wreg(sreg(0, 8'h01), 8'h40);
        check_reg16(sreg(0, 8'h26), 16'd0, "RSR 0 at 962");
        for (i = 0; i < 200; i = i + 1) hbuf[i] = (i * 11 + 5);
        send_rx(2'd0, 200);                    // 962..1023 then 0..137
        check_reg16(sreg(0, 8'h26), 16'd200, "RSR 200 across the wrap");
        set_addr(16'h6000 + 16'd962);
        for (i = 0; i < 200; i = i + 1) begin
            if (i == 62) set_addr(16'h6000);
            rd(R_DATA, d);
            if (d !== hbuf[i]) begin
                if (errors < 20) $display("  rx3 byte %0d: got %02x want %02x", i, d, hbuf[i]);
                fail("RX bytes across the region's wrap");
            end
        end
        wreg(sreg(0, 8'h28), 8'h04); wreg(sreg(0, 8'h29), 8'h8A);     // RX_RD = 1162
        wreg(sreg(0, 8'h01), 8'h40);
        check_reg16(sreg(0, 8'h26), 16'd0, "RSR 0 after the wrap");
        drain; parse_pos = out_n;
        $display("  ok: appends into the held word and across the wrap");

        // ---- 8b. a dummy's commit after the window moves nothing ----------------------
        // The driver's dummy was presented inside the window (hidden), and
        // commits after it with its own address: a read of $C063.  The
        // pointer must not step, whatever the last slot op was.
        set_addr(16'h4010);
        rd(R_DATA, d);                          // ptr -> $4011
        op_addr = 16'hC063; op_rw = 1'b1;       // no present: the dummy's commit alone
        @(posedge clk); #1; op_commit = 1'b1;
        @(posedge clk); #1; op_commit = 1'b0;
        @(posedge clk); #1;
        read_ptr(p); if (p !== 16'h4011) fail("a dummy's stray commit stepped the pointer");
        op_addr = 16'hC067; op_rw = 1'b1;
        @(posedge clk); #1; op_commit = 1'b1;
        @(posedge clk); #1; op_commit = 1'b0;
        @(posedge clk); #1;
        read_ptr(p); if (p !== 16'h4011) fail("a second stray commit stepped the pointer");
        wr(R_DATA, 8'h5A);                      // a real write still lands and steps
        read_ptr(p); if (p !== 16'h4012) fail("a real write after the strays steps once");
        $display("  ok: stray commits move nothing");

        // ---- 9. a write burst read back through the pointer ---------------------------
        set_addr(16'h4100);
        for (i = 0; i < 9; i = i + 1) wr(R_DATA, 8'h30 + i[7:0]);
        set_addr(16'h4100);
        for (i = 0; i < 9; i = i + 1) begin
            rd(R_DATA, d);
            if (d !== 8'h30 + i[7:0]) fail("a write burst reads back");
        end
        // Write without AI, then read the same byte.
        wr(R_MR, 8'h01);
        set_addr(16'h4203); wr(R_DATA, 8'h77); rd(R_DATA, d);
        if (d !== 8'h77) fail("a byte written without AI reads back at once");
        wr(R_MR, 8'h03);
        $display("  ok: writes read back");

        // ---- 10. the other modes, U2_STAT, LISTEN, CLOSE ----------------------------------
        wreg(sreg(1, 8'h00), 8'h01);           // TCP
        wreg(sreg(1, 8'h01), 8'h01);           // OPEN
        check_reg(sreg(1, 8'h03), 8'h13, "TCP OPEN -> SOCK_INIT");
        wreg(sreg(1, 8'h0C), 8'd10); wreg(sreg(1, 8'h0D), 8'd0); wreg(sreg(1, 8'h0E), 8'd2); wreg(sreg(1, 8'h0F), 8'd2);
        wreg(sreg(1, 8'h10), 8'h00); wreg(sreg(1, 8'h11), 8'd80);
        wreg(sreg(1, 8'h01), 8'h04);           // CONNECT
        check_reg(sreg(1, 8'h03), 8'h15, "CONNECT -> SYNSENT");
        drain;
        expect_cmd(2'd1, 8'h01, "TCP OPEN");
        expect_cmd(2'd1, 8'h04, "CONNECT");
        w = cmd_word(15); if (w !== 32'h0202000A) fail("U2_CMD socket word 3: DIPR 10.0.2.2");
        w = cmd_word(16); if (w[15:0] !== 16'h5000) fail("U2_CMD socket word 4: DPORT 80");
        send_stat(2'd1, 8'h17, 1'b0, 32'd0, 32'd0);
        check_reg(sreg(1, 8'h03), 8'h17, "U2_STAT -> ESTABLISHED");
        wreg(sreg(1, 8'h01), 8'h10);           // CLOSE
        check_reg(sreg(1, 8'h03), 8'h00, "CLOSE -> CLOSED");
        drain; expect_cmd(2'd1, 8'h10, "CLOSE");
        // LISTEN with a peer arriving.
        wreg(sreg(2, 8'h00), 8'h01);
        wreg(sreg(2, 8'h01), 8'h01);
        wreg(sreg(2, 8'h01), 8'h02);           // LISTEN
        check_reg(sreg(2, 8'h03), 8'h14, "LISTEN -> SOCK_LISTEN");
        send_stat(2'd2, 8'h17, 1'b1, 32'h0501A8C0, 32'h0000D204);    // 192.168.1.5 : 1234
        check_reg(sreg(2, 8'h03), 8'h17, "an accepted LISTEN is ESTABLISHED");
        check_reg(sreg(2, 8'h0C), 8'hC0, "the peer's DIPR0");
        check_reg(sreg(2, 8'h0F), 8'h05, "the peer's DIPR3");
        check_reg(sreg(2, 8'h10), 8'h04, "the peer's DPORT0");
        check_reg(sreg(2, 8'h11), 8'hD2, "the peer's DPORT1");
        drain; parse_pos = out_n;
        // UDP and IPRAW open at once; a virtual-DNS mode does not open.
        wreg(sreg(3, 8'h00), 8'h02); wreg(sreg(3, 8'h01), 8'h01);
        check_reg(sreg(3, 8'h03), 8'h22, "UDP OPEN -> SOCK_UDP");
        wreg(sreg(3, 8'h01), 8'h10);
        wreg(sreg(3, 8'h00), 8'h03); wreg(sreg(3, 8'h01), 8'h01);
        check_reg(sreg(3, 8'h03), 8'h32, "IPRAW OPEN -> SOCK_IPRAW");
        wreg(sreg(3, 8'h01), 8'h10);
        wreg(sreg(3, 8'h00), 8'h0A); wreg(sreg(3, 8'h01), 8'h01);
        check_reg(sreg(3, 8'h03), 8'h00, "a virtual-DNS mode does not open");
        drain; parse_pos = out_n;
        $display("  ok: TCP, UDP, IPRAW, U2_STAT, LISTEN");

        // ---- 11. the bus-paced regime, briefly -------------------------------------------
        slow = 1'b1;
        set_addr(16'h4300);
        for (i = 0; i < 6; i = i + 1) wr(R_DATA, 8'hE0 + i[7:0]);
        set_addr(16'h4300);
        for (i = 0; i < 6; i = i + 1) begin
            rd(R_DATA, d);
            if (d !== 8'hE0 + i[7:0]) fail("bus-paced: a burst reads back");
        end
        check_reg(sreg(0, 8'h03), 8'h42, "bus-paced: Sn_SR");
        slow = 1'b0;
        $display("  ok: bus-paced ops");

        // ---- 12. MR's reset bit, and RES' --------------------------------------------------
        wreg(16'h0017, 8'h11);                 // RTR0 changed
        set_addr(16'h0017);
        wr(R_MR, 8'h80);
        rd(R_MR, d); if (d !== 8'h00) fail("MR reads 0 the op after its reset bit");
        read_ptr(p); if (p !== 16'h0017) fail("the pointer survives the chip's reset");
        rd(R_DATA, d); if (d !== 8'h07) begin $display("  RTR0 reads %02x after the reset", d); fail("RTR0 back to its reset value"); end
        wr(R_MR, 8'h03);
        check_reg(sreg(0, 8'h03), 8'h00, "sockets closed by the reset");
        check_reg16(sreg(0, 8'h20), 16'h0800, "regions back to $55");
        if (sock_open !== 4'b0000) fail("sock_open after the reset");
        drain;
        expect_cmd(2'd0, 8'h00, "reset by MR");
        wreg(sreg(0, 8'h00), 8'h44); wreg(sreg(0, 8'h01), 8'h01);
        check_reg(sreg(0, 8'h03), 8'h42, "reopened after the reset");
        drain; parse_pos = out_n;
        res_n = 1'b0; repeat (5) @(posedge clk); #1; res_n = 1'b1; repeat (3) @(posedge clk); #1;
        check_reg(sreg(0, 8'h03), 8'h00, "RES' closes the sockets");
        rd(R_MR, d); if (d !== 8'h00) fail("RES' clears MR");
        drain;
        expect_cmd(2'd0, 8'h00, "reset by RES'");
        $display("  ok: resets");

        // ---- 12b. the sender under a stream with NO idle clock -----------------------------
        // The sender shares the register file's one read port with the
        // program and waits for a clock the program is not using.  Under a
        // gapless stream there is none, and a sender that only asks stops
        // after the header: the U2_CMD never reaches the host, the host never
        // answers, and the driver polls Sn_SR forever.  It hung a IIgs
        // (2026-09-20).  The bounded wait takes a clock instead; this is the
        // test that says so.
        drain; parse_pos = out_n;
        wreg(sreg(0, 8'h00), 8'h44);           // Sn_MR = MACRAW
        wreg(sreg(0, 8'h01), 8'h01);           // CR = OPEN, which queues a U2_CMD
        nogap_n0 = out_n;
        op_nogap(400);
        // DURING the burst, not after it: a driver polling Sn_SR never stops
        // presenting ops, so there is no "later" for the sender to finish in.
        // A whole U2_CMD is a header and 24 words.
        if ((out_n - nogap_n0) < 25) begin
            $display("  the sender put %0d words out during 400 gapless ops, wanted 25",
                     out_n - nogap_n0);
            fail("the sender starves under a gapless op stream");
        end
        drain;
        expect_cmd(2'd0, 8'h01, "a U2_CMD gets out under a gapless op stream");
        $display("  ok: a gapless op stream does not starve the sender");

        // ---- 13. what is never claimed ----------------------------------------------------
        op(16'hC0A4, 1'b1, 8'h00); if (last_claim) fail("another slot's DEVICE SELECT was claimed");
        op(16'hC194, 1'b1, 8'h00); if (last_claim) fail("an I/O SELECT page was claimed");
        op_ovr = 1'b1; op(R_MR, 1'b1, 8'h00); op_ovr = 1'b0; if (last_claim) fail("an override was claimed");
        slot_assign = 3'd0; op(R_MR, 1'b1, 8'h00); if (last_claim) fail("a disabled card claimed");
        slot_assign = SLOT;
        master_active = 1'b0; op(R_MR, 1'b1, 8'h00); if (last_claim) fail("claimed without the soft core");
        master_active = 1'b1;
        $display("  ok: nothing else is claimed");

        drain;
        if (parse_pos != out_n) fail("unexpected messages left on the stream");
        if (cmd_dropped) fail("a command was dropped");
        $display("stall clocks over the run: %0d", stall_clocks);
        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
`default_nettype wire
