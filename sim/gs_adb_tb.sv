`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_adb_tb - the IIgs's ADB microcontroller, driven directly.
//
// WHY A UNIT BENCH.  sim/boot_gs_tb.sv proves the keyboard end to end - a
// Return at ProDOS's selector launches a file - but it cannot reach the
// corners: the micro's auto-repeat delay is FORTY-FIVE VIDEO FRAMES, which is
// most of a boot bench's whole run, and a Talk register 0 answers a command
// the ROM issues only when it feels like it.  Here a frame is a pulse and a
// command is three writes.
//
// THE REFERENCE IS KEGS's adb.c, as the module's is: adb_key_event,
// adb_read_c000, adb_access_c010, adb_kbd_talk_reg0, adb_set_config.  The
// keymap is the card's own (rtl/adb_keymap.hex, from KEGS's table by
// tools/gen_adb_keymap.py), so the characters here are the ones a IIgs types.
//////////////////////////////////////////////////////////////////////////////////
module gs_adb_tb #(parameter KEYMAP = "adb_keymap.hex");

    localparam integer P = 10;

    reg clk = 1'b0;
    always #(P/2) clk = ~clk;

    reg        rst = 1'b1, res_sync = 1'b0;
    reg [7:0]  op_lo = 8'd0, op_wdata = 8'd0;
    reg        op_rw = 1'b1, act = 1'b0;
    reg        frame_tick = 1'b0;
    reg        msg_valid = 1'b0, pay_valid = 1'b0;
    reg [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    reg [31:0] pay_data = 32'd0;
    wire [7:0] rd_byte, c025, cnt_cmds, cnt_unknown;
    wire       irq_data, irq_mouse;

    gs_adb #(.KEYMAP (KEYMAP)) dut (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (op_lo), .op_rw (op_rw), .op_wdata (op_wdata), .act (act),
        .rd_byte (rd_byte), .frame_tick (frame_tick),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .c025_val (c025),
        .irq_data (irq_data), .irq_mouse (irq_mouse),
        .cnt_cmds (cnt_cmds), .cnt_unknown (cnt_unknown)
    );

    integer checks = 0, errors = 0;
    task ok(input string what);
        begin checks = checks + 1; $display("ok: %0s", what); end
    endtask
    task fail(input string what);
        begin checks = checks + 1; errors = errors + 1; $display("FAIL: %0s", what); end
    endtask
    task chk(input [7:0] got, input [7:0] want, input string what);
        begin
            if (got === want) ok($sformatf("%0s = $%02X", what, got));
            else fail($sformatf("%0s = $%02X, want $%02X", what, got, want));
        end
    endtask

    // ---- the machine's side: one op, presented and retired ------------------
    task automatic rd(input [7:0] lo, output [7:0] v);
        begin
            @(negedge clk);
            op_lo = lo; op_rw = 1'b1; act = 1'b0;
            @(negedge clk);
            v = rd_byte;            // combinational on the registered op
            act = 1'b1;
            @(negedge clk);
            act = 1'b0;
        end
    endtask
    task automatic wr(input [7:0] lo, input [7:0] d);
        begin
            @(negedge clk);
            op_lo = lo; op_rw = 1'b0; op_wdata = d; act = 1'b0;
            @(negedge clk);
            act = 1'b1;
            @(negedge clk);
            act = 1'b0;
        end
    endtask

    // ---- the host's side: one ADB_KEY ---------------------------------------
    task automatic key(input [6:0] code, input up, input [7:0] mods);
        begin
            @(negedge clk);
            msg_valid = 1'b1; msg_type = 8'h2F; msg_len = 8'd1;
            @(negedge clk);
            msg_valid = 1'b0; pay_valid = 1'b1;
            pay_data = {16'd0, mods, up, code};
            @(negedge clk);
            pay_valid = 1'b0;
            repeat (4) @(negedge clk);      // the apply waits for a clock with no act
        end
    endtask

    task automatic frames(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk); frame_tick = 1'b1;
                @(negedge clk); frame_tick = 1'b0;
            end
        end
    endtask

    // Both queues empty, so a section starts from a known keyboard: $C010
    // until $C000 has no strobe, and Talks until one answers $80.
    task automatic drain;
        integer k;
        reg [7:0] t;
        begin
            for (k = 0; k < 12; k = k + 1) begin
                rd(8'h00, t);
                if (!t[7]) k = 12;
                else rd(8'h10, t);
            end
            for (k = 0; k < 12; k = k + 1) begin
                wr(8'h26, 8'hC2);
                rd(8'h26, t);
                if (t == 8'h80) k = 12;
                else begin rd(8'h26, t); rd(8'h26, t); end
            end
        end
    endtask

    reg [7:0] v, v2;
    integer   n, reps;

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0; res_sync = 1'b1;
        repeat (4) @(negedge clk);

        // ---- a key, its character, and the strobe ---------------------------
        rd(8'h00, v); chk(v, 8'h00, "$C000 before any key");
        key(7'h00, 1'b0, 8'h00);                       // 'a'
        rd(8'h00, v); chk(v, 8'hE1, "$C000 after 'a' went down");
        rd(8'h10, v); chk(v, 8'hE1, "$C010 answers with the strobe gone and the key still down");
        rd(8'h00, v); chk(v, 8'h61, "$C000 keeps the character with its strobe cleared");
        key(7'h00, 1'b1, 8'h00);
        rd(8'h10, v); chk(v, 8'h61, "$C010 drops bit 7 once the key is up");

        // ---- the modifiers pick the column ----------------------------------
        key(7'h00, 1'b0, 8'h01);                       // shift-A
        rd(8'h00, v); chk(v, 8'hC1, "shift gives 'A'");
        rd(8'h10, v); key(7'h00, 1'b1, 8'h01);
        key(7'h00, 1'b0, 8'h02);                       // control-A
        rd(8'h00, v); chk(v, 8'h81, "control gives $01");
        rd(8'h10, v); key(7'h00, 1'b1, 8'h02);
        key(7'h00, 1'b0, 8'h04);                       // caps lock
        rd(8'h00, v); chk(v, 8'hC1, "caps lock lifts a letter");
        rd(8'h10, v); key(7'h00, 1'b1, 8'h04);
        key(7'h12, 1'b0, 8'h04);                       // caps lock, but a digit
        rd(8'h00, v); chk(v, 8'hB1, "...and leaves a digit alone");
        rd(8'h10, v); key(7'h12, 1'b1, 8'h04);

        // ---- $C025 is the modifier byte -------------------------------------
        key(7'h38, 1'b0, 8'h01);                       // the shift key itself
        chk(c025 & 8'hC7, 8'h01, "$C025 carries shift");
        // The head keeps the last character with its strobe clear, so what
        // says "nothing was typed" is the STROBE and not the byte.
        rd(8'h00, v); chk({v[7], 7'd0}, 8'h00, "a modifier sets no strobe");
        key(7'h38, 1'b1, 8'h00);
        chk(c025 & 8'hC7, 8'h00, "...and lets go");

        drain();
        // ---- Talk register 0 drains the RAW events --------------------------
        // Command $C2: Talk, device 2 (the keyboard), register 0.  The answer
        // is a response packet: the interrupt byte first, then two bytes.
        key(7'h07, 1'b0, 8'h00);                       // 'x' down
        key(7'h07, 1'b1, 8'h00);                       // ...and up
        wr(8'h26, 8'hC2);
        rd(8'h26, v);  chk(v, 8'h81, "a Talk's interrupt byte says two bytes follow");
        rd(8'h26, v);  rd(8'h26, v2);
        chk(v,  8'h87, "the second byte is the key going UP");
        chk(v2, 8'h07, "the first is the key going down");

        // Nothing left: an empty Talk is a zero-byte packet.
        wr(8'h26, 8'hC2);
        rd(8'h26, v); chk(v, 8'h80, "an empty Talk answers $80 and no bytes");

        drain();
        // ---- auto-repeat ----------------------------------------------------
        // The ROM's own default repeat_info is $23: a delay of 45 frames and
        // a rate of 7.  A key held with the machine polling $C000 repeats.
        key(7'h07, 1'b0, 8'h00);
        rd(8'h10, v);                                  // take the first 'x'
        rd(8'h00, v); chk(v, 8'h78, "no repeat before the delay is up: 'x' with no strobe");
        frames(45);
        rd(8'h00, v);                                  // the read that fires it
        repeat (8) @(negedge clk);
        rd(8'h00, v); chk(v, 8'hF8, "the held key repeated: strobe and 'x'");
        chk(c025 & 8'h08, 8'h08, "$C025 bit 3 says a key is available");
        rd(8'h10, v);
        chk(c025 & 8'h08, 8'h00, "...and $C010 clears it");

        // It keeps repeating at the rate, and stops when the key goes up.
        reps = 0;
        for (n = 0; n < 6; n = n + 1) begin
            frames(7);
            rd(8'h00, v);
            repeat (8) @(negedge clk);
            rd(8'h00, v);
            if (v[7]) begin reps = reps + 1; rd(8'h10, v); end
        end
        if (reps >= 5) ok($sformatf("it went on repeating at the rate: %0d of 6", reps));
        else fail($sformatf("only %0d of 6 repeats at the rate", reps));

        key(7'h07, 1'b1, 8'h00);
        rd(8'h10, v);
        frames(90);
        rd(8'h00, v);
        repeat (8) @(negedge clk);
        rd(8'h00, v); chk(v[7], 1'b0, "a key that is up does not repeat");

        drain();
        // ---- a delay of zero turns repeat off -------------------------------
        // set-config (command $06) takes three bytes; the third is the timing,
        // and a high nibble of 4 means never.
        wr(8'h26, 8'h06); wr(8'h26, 8'h23); wr(8'h26, 8'h00); wr(8'h26, 8'h43);
        key(7'h07, 1'b0, 8'h00);
        rd(8'h10, v);
        frames(200);
        rd(8'h00, v);
        repeat (8) @(negedge clk);
        rd(8'h00, v); chk(v[7], 1'b0, "a delay of zero never repeats");
        key(7'h07, 1'b1, 8'h00);

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: gs_adb_tb ran away");
        $finish;
    end
endmodule
