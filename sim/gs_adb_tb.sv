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
    reg [15:0] msg_free = 16'd0;
    reg [31:0] pay_data = 32'd0;
    reg        loc_valid = 1'b0, loc_up = 1'b0;
    reg [6:0]  loc_code = 7'd0;
    reg [7:0]  loc_mods = 8'd0, live_mods = 8'd0;
    wire [7:0] rd_byte, c025, cnt_cmds, cnt_unknown;
    wire       irq_data, irq_mouse;

    gs_adb #(.KEYMAP (KEYMAP)) dut (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (op_lo), .op_rw (op_rw), .op_wdata (op_wdata), .act (act),
        .rd_byte (rd_byte), .frame_tick (frame_tick),
        // The IIe's own keyboard, driven here as a second source into the one
        // buffer; sim/gs_kbd_a2_tb.sv drives it through rtl/gs_kbd_a2.sv from
        // a model IOU, which is where the reverse keymap is proved.
        .loc_valid (loc_valid), .loc_code (loc_code), .loc_up (loc_up),
        .loc_mods (loc_mods), .live_mods (live_mods),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .c025_rd (c025),
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

    // ---- the card's side: one event from the IIe's keyboard -----------------
    task automatic loc_key(input [6:0] code, input up, input [7:0] mods);
        begin
            @(negedge clk);
            loc_valid = 1'b1; loc_code = code; loc_up = up; loc_mods = mods;
            @(negedge clk);
            loc_valid = 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    // ---- the host's side: one MOUSE_MOVE ------------------------------------
    // The buttons ride in the header's spare field, the deltas in the word.
    task automatic mouse(input signed [15:0] dx, input signed [15:0] dy,
                         input btn);
        begin
            @(negedge clk);
            msg_valid = 1'b1; msg_type = 8'h25; msg_len = 8'd1;
            msg_free = {14'd0, 1'b0, btn};
            @(negedge clk);
            msg_valid = 1'b0; pay_valid = 1'b1;
            pay_data = {dy, dx};
            @(negedge clk);
            pay_valid = 1'b0;
            repeat (4) @(negedge clk);
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

    // $C027 is status only - reading it moves nothing - but rd_byte is
    // COMBINATIONAL ON THE REGISTERED OP, so presenting the address and
    // sampling in the same breath returns the byte for the op BEFORE it.  A
    // function cannot wait; this has to be a task with a clock in it.
    task automatic rd27(output [7:0] v);
        begin
            @(negedge clk);
            op_lo = 8'h27; op_rw = 1'b1;
            @(negedge clk);
            v = rd_byte;
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

        drain();
        // ---- THE TWO KEYBOARDS SHARE ONE BUFFER -----------------------------
        // The host's ADB_KEY and the IIe's own keyboard (rtl/gs_kbd_a2.sv)
        // are two sources into the same micro, which is what docs/GS.md asked
        // for: whichever the user reaches for, the machine reads $C000.
        loc_key(7'h01, 1'b0, 8'h00);                   // 's', from the card
        key(7'h07, 1'b0, 8'h00);                       // 'x', from the host
        rd(8'h00, v); chk(v, 8'hF3, "the card's key is first in the buffer");
        rd(8'h10, v);
        rd(8'h00, v); chk(v, 8'hF8, "...and the host's is behind it");
        rd(8'h10, v);
        loc_key(7'h01, 1'b1, 8'h00); key(7'h07, 1'b1, 8'h00);

        // The IIe's keyboard has no caps-lock of its own to report, so an
        // upper case letter arrives as shift and the forward map lifts it.
        loc_key(7'h00, 1'b0, 8'h01);
        rd(8'h00, v); chk(v, 8'hC1, "a card key with shift types a capital");
        rd(8'h10, v); loc_key(7'h00, 1'b1, 8'h00);

        // ---- the real Apple keys are merged at the read ---------------------
        // They are LEVELS on the IIe's game port, not events, so they never
        // enter c025_val: a latched copy would outlive the finger.
        live_mods = 8'hC0; @(negedge clk);
        chk(c025 & 8'hC0, 8'hC0, "$C025 shows the real Apple keys");
        live_mods = 8'h00; @(negedge clk);
        chk(c025 & 8'hC0, 8'h00, "...and stops showing them at once");

        // ---- THE MOUSE ($C024) ----------------------------------------------
        // FIRST PUT THE CONFIG BACK.  The auto-repeat section above issues a
        // set-config whose first byte is $23, and adb_set_config reads the
        // mouse's controller address out of its high nibble - so the micro is
        // now polling a mouse at address 2 while the mouse is still at 3, and
        // a mouse the micro is not polling reads ZERO.  That is KEGS's rule
        // and this module's, and finding it here is the rule working: send
        // $32, the reset pairing (mouse 3, keyboard 2), and the mouse is back.
        wr(8'h26, 8'h06); wr(8'h26, 8'h32); wr(8'h26, 8'h00); wr(8'h26, 8'h23);

        // One coordinate a read, X first, and the byte is {button, delta}:
        // bit 7 is the button ONLY on the Y read - KEGS sets it unconditionally
        // on the X read ("mouse button not down on x coord rd").
        mouse(16'sd10, 16'sd20, 1'b0);
        rd27(v2); chk(v2 & 8'h80, 8'h80, "$C027 says the mouse has data");
        rd(8'h24, v); chk(v, 8'h8A, "the X read: bit 7 set, delta 10");
        rd27(v2); chk(v2 & 8'h02, 8'h02, "...and $C027 bit 1 now says Y is next");
        rd(8'h24, v); chk(v, 8'h94, "the Y read: button up (bit 7), delta 20");
        rd27(v2); chk(v2 & 8'h80, 8'h00, "caught up: the data is no longer valid");

        // A negative delta is the same seven bits, two's complement.
        mouse(-16'sd3, -16'sd1, 1'b0);
        rd(8'h24, v); chk(v, 8'hFD, "a negative X delta is -3 in seven bits");
        rd(8'h24, v); chk(v, 8'hFF, "...and -1 in Y, button still up");

        // THE CLAMP, and what it means: a big move is handed over $3F at a
        // time and the REST IS KEPT, so nothing is lost - it just takes more
        // reads.  100 = 63 then 37.
        mouse(16'sd100, 16'sd0, 1'b0);
        rd(8'h24, v); chk(v, 8'hBF, "a big move is clamped to $3F");
        rd(8'h24, v);                                  // the Y half
        rd27(v2); chk(v2 & 8'h80, 8'h80, "...and the rest is still owed");
        rd(8'h24, v); chk(v, 8'hA5, "the next X read hands over the other 37");
        rd(8'h24, v);
        rd27(v2); chk(v2 & 8'h80, 8'h00, "...and now it is caught up");

        // The button, on the Y read, and it keeps the data valid until the
        // machine has actually seen it.
        mouse(16'sd0, 16'sd0, 1'b1);
        rd27(v2); chk(v2 & 8'h80, 8'h80, "a button press alone is data");
        rd(8'h24, v); chk(v, 8'h80, "the X read shows no button and no motion");
        rd(8'h24, v); chk(v, 8'h00, "the Y read: bit 7 CLEAR means button down");
        rd27(v2); chk(v2 & 8'h80, 8'h00, "...and the press has been delivered");

        // Motion that arrives before the last was read ACCUMULATES: the
        // machine is owed all of it.
        mouse(16'sd5, 16'sd0, 1'b1);
        mouse(16'sd7, 16'sd0, 1'b1);
        rd(8'h24, v); chk(v, 8'h8C, "two moves before a read are added, not replaced");
        rd(8'h24, v);

        // ADB mode bit 1 turns the mouse off: the register reads zero.
        // Command $04 is set-modes, one argument.
        wr(8'h26, 8'h04); wr(8'h26, 8'h02);
        mouse(16'sd9, 16'sd9, 1'b0);
        rd(8'h24, v); chk(v, 8'h00, "with the mouse off $C024 reads zero");
        rd27(v2); chk(v2 & 8'h80, 8'h00, "...and it has no data to offer");
        wr(8'h26, 8'h05); wr(8'h26, 8'h02);             // clear-modes, back on

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
