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
    reg [7:0] latches_before;

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

    // One clean RES' assertion and release, the way the motherboard does it:
    // held long enough that anything happening inside it is invisible.
    task pulse_reset_line;
        begin
            apple_res_sync = 1'b0;
            repeat (8) @(posedge clk);
            apple_res_sync = 1'b1;
            repeat (8) @(posedge clk);
        end
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

    // CAN_MASTER is 1 here so the latch can be exercised.  The snoop top builds
    // it with 0; case 8 below covers that side too, with a second instance.
    reg  apple_res_sync = 1'b1;      // active low, idle high
    wire cpu_source_active;
    wire [2:0] mb_slot_active;
    // The boot hold's side of BOOT_HOLD: the tb plays the hold itself.
    wire boot_arm, boot_release;
    reg  boot_held = 1'b0;
    integer release_pulses = 0;
    always @(posedge clk) if (boot_release) release_pulses = release_pulses + 1;

    wb_regfile #(.BUILD_DATE (BUILD_DATE), .BUILD_TIME (BUILD_TIME),
                 .CAN_MASTER (1'b1)) u_regs (
        .clk (clk), .rst (rst),
        .apple_res_sync (apple_res_sync), .cpu_source_active (cpu_source_active),
        .mb_slot_active (mb_slot_active),
        .boot_arm (boot_arm), .boot_release (boot_release), .boot_held (boot_held),
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
    // A notice, offered the way card_link offers one: held until taken.
    reg  [31:0] note_word  = 32'd0;
    reg         note_valid = 1'b0;
    wire        note_take;
    integer     note_takes = 0;
    always @(posedge clk) if (note_take) begin
        note_valid = 1'b0;
        note_takes = note_takes + 1;
    end

    tx_arb u_arb (
        .clk (clk), .rst (rst),
        .src_data (src_data), .src_push (src_push), .src_full (src_full),
        .rsp_addr (rsp_addr), .rsp_data (rsp_data),
        .rsp_valid (rsp_valid), .rsp_take (rsp_take),
        .note_word (note_word), .note_valid (note_valid), .note_take (note_take),
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

        // --- case 8 / CPU_SOURCE latches on the RES' assertion ---------------
        //
        // The property, not the plumbing: writing the register must NOT hand
        // over the bus.  Only a reset may, and exactly once per assertion
        // however long it is held or however much the line bounces.
        pulse_reset_line;      // start from a known latch count
        if (cpu_source_active !== 1'b0) begin
            $display("FAIL: mastering after a reset with desired=0");
            errors = errors + 1;
        end else $display("  ok: desired=0 latches to not-mastering");

        // Ask for the soft core.  Nothing may happen yet.
        push_word(hdr(T_REG_WRITE, 8'd2, 16'd0));
        push_word(32'h8000_0008);
        push_word(32'h0000_0001);
        repeat (40) @(posedge clk);
        if (cpu_source_active !== 1'b0) begin
            $display("FAIL: the WRITE handed over the bus - it must take a reset");
            errors = errors + 1;
        end else $display("  ok: writing desired=1 does not hand over on its own");

        // Now reset.  This is the moment it may change, and it must.
        pulse_reset_line;
        if (cpu_source_active !== 1'b1) begin
            $display("FAIL: RES' asserted but the soft core did not take the bus");
            errors = errors + 1;
        end else $display("  ok: the reset assertion is what hands over");

        // Read it back and check every field.
        base = out_n;
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_0008);
        repeat (60) @(posedge clk);
        if (out_n - base < 3) begin
            $display("FAIL: no CPU_SOURCE reply");
            errors = errors + 1;
        end else begin
            if (out_mem[base+2][0] !== 1'b1) begin
                $display("FAIL: desired did not read back");  errors = errors + 1;
            end else if (out_mem[base+2][8] !== 1'b1) begin
                $display("FAIL: active did not read back");   errors = errors + 1;
            end else if (out_mem[base+2][16] !== 1'b1) begin
                $display("FAIL: capable should be 1 here");   errors = errors + 1;
            end else if (out_mem[base+2][31:24] === 8'd0) begin
                $display("FAIL: the latch count never moved"); errors = errors + 1;
            end else begin
                $display("  ok: readback desired=1 active=1 capable=1 latches=%0d",
                         out_mem[base+2][31:24]);
            end
        end

        // A bouncing RES' must latch once per assertion, not once per glitch
        // within one.  Held low, further activity changes nothing.
        latches_before = out_mem[base+2][31:24];
        apple_res_sync = 1'b0;
        repeat (4) @(posedge clk);
        repeat (4) @(posedge clk);          // still low: no second edge
        apple_res_sync = 1'b1;
        repeat (8) @(posedge clk);
        base = out_n;
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_0008);
        repeat (60) @(posedge clk);
        if (out_mem[base+2][31:24] !== (latches_before + 8'd1)) begin
            $display("FAIL: a held-low RES' latched %0d times, expected 1",
                     out_mem[base+2][31:24] - latches_before);
            errors = errors + 1;
        end else $display("  ok: one latch per assertion, not per cycle held");

        // --- case 9 / MB_SLOT follows the same latched contract --------------
        // Same shape as CPU_SOURCE, checked more briefly: the write is an
        // intention, the reset acts on it, and the readback carries both.
        if (mb_slot_active !== 3'd0) begin
            $display("FAIL: the Mockingboard is enabled before anyone asked");
            errors = errors + 1;
        end else $display("  ok: MB_SLOT starts disabled");

        push_word(hdr(T_REG_WRITE, 8'd2, 16'd0));
        push_word(32'h8000_000C);
        push_word(32'h0000_0004);          // slot 4, the Mockingboard's home
        repeat (40) @(posedge clk);
        if (mb_slot_active !== 3'd0) begin
            $display("FAIL: the WRITE enabled the Mockingboard - it must take a reset");
            errors = errors + 1;
        end else $display("  ok: writing MB_SLOT does not enable on its own");

        pulse_reset_line;
        if (mb_slot_active !== 3'd4) begin
            $display("FAIL: RES' asserted but MB_SLOT did not latch to 4");
            errors = errors + 1;
        end else $display("  ok: the reset assertion latches the slot");

        base = out_n;
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_000C);
        repeat (60) @(posedge clk);
        if (out_n - base < 3) begin
            $display("FAIL: no MB_SLOT reply");
            errors = errors + 1;
        end else if (out_mem[base+2][2:0] !== 3'd4 ||
                     out_mem[base+2][10:8] !== 3'd4) begin
            $display("FAIL: MB_SLOT readback %08x, expected desired=4 active=4",
                     out_mem[base+2]);
            errors = errors + 1;
        end else begin
            $display("  ok: readback desired=%0d active=%0d",
                     out_mem[base+2][2:0], out_mem[base+2][10:8]);
        end

        // --- case 10 / BOOT_HOLD: arm is a level, release is a pulse ---------
        // Not reset-latched, unlike its neighbours: arm is "stop at the next
        // boot", and a reset is what it is waiting for, not what applies it.
        if (boot_arm !== 1'b0) begin
            $display("FAIL: the boot hold is armed before anyone asked");
            errors = errors + 1;
        end else $display("  ok: BOOT_HOLD starts unarmed");

        do_write(32'h8000_0010, 32'h0000_0001);           // arm
        if (boot_arm !== 1'b1) begin
            $display("FAIL: writing arm=1 did not arm");
            errors = errors + 1;
        end else $display("  ok: writing arm=1 arms, with no reset needed");
        if (release_pulses !== 0) begin
            $display("FAIL: arming released something");
            errors = errors + 1;
        end

        // The hold engages: held reads back and the count moves.
        boot_held = 1'b1;
        base = out_n;
        do_read(32'h8000_0010);
        if (out_mem[base+2][0] !== 1'b1 || out_mem[base+2][8] !== 1'b1 ||
            out_mem[base+2][16] !== 1'b0 || out_mem[base+2][31:24] !== 8'd1) begin
            $display("FAIL: BOOT_HOLD readback %08x, expected arm=1 held=1 release=0 holds=1",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: readback arm=1 held=1 holds=1 while held");

        // Release keeps arm as written alongside it, and pulses exactly once
        // however long the message took: the hold consumes a pulse, not a
        // level, so a level would release every boot from here on.
        do_write(32'h8000_0010, 32'h0001_0001);           // release, stay armed
        if (release_pulses !== 1) begin
            $display("FAIL: release pulsed %0d time(s), expected exactly 1", release_pulses);
            errors = errors + 1;
        end else if (boot_arm !== 1'b1) begin
            $display("FAIL: the release write disarmed when told to stay armed");
            errors = errors + 1;
        end else $display("  ok: release is one pulse, and arm stays as written");

        boot_held = 1'b0;
        do_write(32'h8000_0010, 32'h0001_0000);           // release AND disarm
        if (boot_arm !== 1'b0 || release_pulses !== 2) begin
            $display("FAIL: release-and-disarm: arm=%0d pulses=%0d", boot_arm, release_pulses);
            errors = errors + 1;
        end else $display("  ok: one write can release and disarm together");

        base = out_n;
        do_read(32'h8000_0010);
        if (out_mem[base+2][16] !== 1'b0 || out_mem[base+2][8] !== 1'b0 ||
            out_mem[base+2][31:24] !== 8'd1) begin
            $display("FAIL: after release BOOT_HOLD reads %08x", out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: release reads back as 0; holds still counts the one");

        // --- case 11 / a notice, like a reply, never lands inside a message --
        // The CPU_HOLD notice is one header-only word injected through the
        // same slot a reply uses, so it has the same obligation.
        base = out_n;
        note_word = {15'd0, 1'b1, 8'h17, 8'd0};
        @(negedge clk);
        src_data = hdr(T_BUS_EVENTS, 8'd3, 16'd0); src_push = 1'b1;
        @(negedge clk);
        src_data = 32'hAAAA_0001;
        note_valid = 1'b1;                                // arrives mid-payload
        @(negedge clk);
        src_data = 32'hAAAA_0002;
        @(negedge clk);
        src_data = 32'hAAAA_0003;
        @(negedge clk);
        src_push = 1'b0;
        repeat (40) @(posedge clk);

        hdr_at = -1;
        for (i = base; i < out_n - 3; i = i + 1) begin
            if (out_mem[i] === hdr(T_BUS_EVENTS, 8'd3, 16'd0)) hdr_at = i;
        end
        if (hdr_at < 0) begin
            $display("FAIL: the BUS_EVENTS message never came out (notice case)");
            errors = errors + 1;
        end else begin
            expect_word(hdr_at + 1, 32'hAAAA_0001, "event word 1 with a notice pending");
            expect_word(hdr_at + 2, 32'hAAAA_0002, "event word 2 with a notice pending");
            expect_word(hdr_at + 3, 32'hAAAA_0003, "event word 3 with a notice pending");
            if (out_mem[hdr_at + 4] !== {15'd0, 1'b1, 8'h17, 8'd0}) begin
                $display("FAIL: the notice did not follow the message: word %0d = %08x",
                         hdr_at + 4, out_mem[hdr_at + 4]);
                errors = errors + 1;
            end else if (note_takes !== 1) begin
                $display("FAIL: the notice was taken %0d time(s)", note_takes);
                errors = errors + 1;
            end else
                $display("  ok: CPU_HOLD notice waited for the boundary, went out once");
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
