`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// reg_map_tb - the whole register path, from a host message to a reply on the
// wire: ft601_msg_rx -> reg_bridge -> wb_regfile -> tx_arb.
//
// The parts are individually simple and the interesting failures are all in the
// seams, so this drives the real modules end to end rather than any of them in
// isolation.  Two properties are worth more than the rest:
//
//   * a read comes back with the right value AND the address it answered, so a
//     host can match replies to requests
//   * a reply NEVER lands inside another message.  The link has no sync word and
//     deliberately cannot resynchronise, so an interleaved word is not a glitch
//     the parser recovers from - it is a stream that stays plausible and wrong
//     from that point on.  That is the one this file exists for.
//////////////////////////////////////////////////////////////////////////////////

module reg_map_tb;

    localparam integer BUILD_DATE = 20260823;
    localparam integer BUILD_TIME = 143900;

    localparam [7:0] T_REG_READ  = 8'h14;
    localparam [7:0] T_REG_WRITE = 8'h15;
    localparam [7:0] T_REG_VALUE = 8'h16;
    localparam [7:0] T_BUS_EVENTS = 8'h12;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    integer errors = 0;

    // ---- host -> card: a little FIFO the parser reads from --------------------
    reg  [31:0] rx_mem [0:63];
    integer     rx_wr = 0, rx_rd = 0;
    wire        rx_empty = (rx_rd >= rx_wr);
    wire [31:0] rx_dout  = rx_empty ? 32'd0 : rx_mem[rx_rd];
    wire        rx_rd_en;
    always @(posedge clk) if (rx_rd_en && !rx_empty) rx_rd <= rx_rd + 1;

    task push_word(input [31:0] w);
        begin rx_mem[rx_wr] = w; rx_wr = rx_wr + 1; end
    endtask

    function [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction

    // ---- DUTs ---------------------------------------------------------------
    wire        msg_valid, pay_valid, frame_error;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;

    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .frame_error (frame_error)
    );

    wire        wb_cyc, wb_stb, wb_we, wb_ack, wb_stall;
    wire [31:0] wb_adr, wb_dat_w, wb_dat_r;
    wire [3:0]  wb_sel;
    wire [31:0] rsp_addr, rsp_data;
    wire        rsp_valid, rsp_take;

    reg_bridge u_bridge (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_adr (wb_adr), .wb_dat_w (wb_dat_w), .wb_sel (wb_sel),
        .wb_ack (wb_ack), .wb_stall (wb_stall), .wb_dat_r (wb_dat_r),
        .rsp_addr (rsp_addr), .rsp_data (rsp_data),
        .rsp_valid (rsp_valid), .rsp_take (rsp_take)
    );

    wb_regfile #(.BUILD_DATE (BUILD_DATE), .BUILD_TIME (BUILD_TIME)) u_regs (
        .clk (clk), .rst (rst),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_adr (wb_adr), .wb_dat_w (wb_dat_w), .wb_sel (wb_sel),
        .wb_ack (wb_ack), .wb_stall (wb_stall), .wb_dat_r (wb_dat_r)
    );

    // ---- card -> host: capture whatever tx_arb emits -------------------------
    reg  [31:0] src_data = 32'd0;
    reg         src_push = 1'b0;
    wire        src_full;
    wire [31:0] tx_data;
    wire        tx_push;
    reg         tx_full = 1'b0;

    tx_arb u_arb (
        .clk (clk), .rst (rst),
        .src_data (src_data), .src_push (src_push), .src_full (src_full),
        .rsp_addr (rsp_addr), .rsp_data (rsp_data),
        .rsp_valid (rsp_valid), .rsp_take (rsp_take),
        .tx_data (tx_data), .tx_push (tx_push), .tx_full (tx_full)
    );

    reg [31:0] out_mem [0:255];
    integer    out_n = 0;
    always @(posedge clk) if (tx_push && !tx_full) begin
        out_mem[out_n] = tx_data;
        out_n = out_n + 1;
    end

    // ---- helpers ------------------------------------------------------------
    task expect_word(input integer idx, input [31:0] want, input [255:0] what);
        begin
            if (out_mem[idx] !== want) begin
                $display("FAIL: %0s: word %0d = %08x, expected %08x",
                         what, idx, out_mem[idx], want);
                errors = errors + 1;
            end
        end
    endtask

    task do_read(input [31:0] addr);
        begin
            push_word(hdr(T_REG_READ, 8'd1, 16'd0));
            push_word(addr);
            repeat (60) @(posedge clk);
        end
    endtask

    task do_write(input [31:0] addr, input [31:0] data);
        begin
            push_word(hdr(T_REG_WRITE, 8'd2, 16'd0));
            push_word(addr);
            push_word(data);
            repeat (60) @(posedge clk);
        end
    endtask

    integer base;
    integer i;
    integer hdr_at;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        @(negedge clk);

        $display("reg_map_tb: control registers over Wishbone\n");

        // --- case 1 / read BUILD_DATE ----------------------------------------
        base = out_n;
        do_read(32'h8000_0000);
        if (out_n - base != 3) begin
            $display("FAIL: read reply was %0d word(s), expected 3", out_n - base);
            errors = errors + 1;
        end else begin
            expect_word(base + 0, hdr(T_REG_VALUE, 8'd2, 16'd0), "BUILD_DATE header");
            expect_word(base + 1, 32'h8000_0000, "BUILD_DATE address echo");
            expect_word(base + 2, BUILD_DATE,    "BUILD_DATE value");
            $display("  ok: read 0x80000000 -> %0d", out_mem[base + 2]);
        end

        // --- case 2 / read BUILD_TIME ----------------------------------------
        base = out_n;
        do_read(32'h8000_0004);
        expect_word(base + 1, 32'h8000_0004, "BUILD_TIME address echo");
        expect_word(base + 2, BUILD_TIME,    "BUILD_TIME value");
        $display("  ok: read 0x80000004 -> %0d", out_mem[base + 2]);

        // --- case 3 / a hole in the map --------------------------------------
        // Reads zero and still replies.  A slave that withheld ack here would
        // hang the bridge and the host would see a dead link, not a bad address.
        base = out_n;
        do_read(32'h8000_0040);
        expect_word(base + 2, 32'd0, "unimplemented register reads zero");
        $display("  ok: unimplemented address replies with zero");

        // --- case 4 / outside the register region ----------------------------
        // 0x0000_0000 is DDR3 space, not ours; it must not alias onto register 0.
        base = out_n;
        do_read(32'h0000_0000);
        expect_word(base + 2, 32'd0, "DDR3 space does not alias register 0");
        $display("  ok: address outside the region does not alias BUILD_DATE");

        // --- case 5 / write to a read-only register --------------------------
        // Accepted, discarded, and the reply carries what the register still
        // holds - which is how the host tells the difference without a status.
        base = out_n;
        do_write(32'h8000_0000, 32'hDEAD_BEEF);
        expect_word(base + 1, 32'h8000_0000, "write reply address echo");
        expect_word(base + 2, BUILD_DATE,    "read-only register unchanged by write");
        $display("  ok: write to a read-only register leaves it alone and says so");

        // --- case 6 / a reply must not land inside another message -----------
        // The one this file exists for.  A BUS_EVENTS message is streamed while
        // a register read is issued mid-payload; the message must come out whole.
        base = out_n;
        @(negedge clk);
        src_data = hdr(T_BUS_EVENTS, 8'd4, 16'd0); src_push = 1'b1;
        @(negedge clk);
        src_data = 32'h1111_1111;
        @(negedge clk);
        // Request arrives with the payload half emitted.
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_0004);
        src_data = 32'h2222_2222;
        @(negedge clk);
        src_data = 32'h3333_3333;
        @(negedge clk);
        src_data = 32'h4444_4444;
        @(negedge clk);
        src_push = 1'b0;
        repeat (80) @(posedge clk);

        // The five source words must appear consecutively and in order.
        hdr_at = -1;
        for (i = base; i < out_n - 4; i = i + 1) begin
            if (out_mem[i] === hdr(T_BUS_EVENTS, 8'd4, 16'd0)) hdr_at = i;
        end
        if (hdr_at < 0) begin
            $display("FAIL: the BUS_EVENTS message never came out");
            errors = errors + 1;
        end else begin
            expect_word(hdr_at + 1, 32'h1111_1111, "event word 1 follows its header");
            expect_word(hdr_at + 2, 32'h2222_2222, "event word 2");
            expect_word(hdr_at + 3, 32'h3333_3333, "event word 3");
            expect_word(hdr_at + 4, 32'h4444_4444, "event word 4");
            $display("  ok: BUS_EVENTS stayed intact with a reply pending mid-payload");
        end
        // And the reply still arrived, outside it.
        if (out_n - base < 8) begin
            $display("FAIL: the reply was lost, only %0d word(s) out", out_n - base);
            errors = errors + 1;
        end else begin
            $display("  ok: the reply arrived too, %0d word(s) total", out_n - base);
        end

        // --- case 7 / the parser never lost sync -----------------------------
        if (frame_error !== 1'b0) begin
            $display("FAIL: frame_error asserted - a type is missing from hdr_known");
            errors = errors + 1;
        end else begin
            $display("  ok: no frame error; REG_READ and REG_WRITE are known types");
        end

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
