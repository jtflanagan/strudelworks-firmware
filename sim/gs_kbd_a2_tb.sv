`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_kbd_a2_tb - the Apple IIe's own keyboard, through the ADB micro and out.
//
// THE TWO MODULES TOGETHER, because separately neither says anything useful.
// rtl/gs_kbd_a2.sv turns the IOU's ASCII into a keycode and modifiers, and
// rtl/gs_adb.sv turns those back into ASCII: the claim worth checking is that
// THE BYTE COMES BACK, and it is only visible across the pair.  So this bench
// puts a model IOU on one end and reads $C000 on the other, and the headline
// case sweeps ALL 128 ASCII VALUES through the round trip.
//
// tools/gen_adb_revmap.py already asserts that inversion over KEGS's table.
// This is the same claim made of the SILICON: that the ROMs were generated
// consistently, that the walk samples the byte on the right clock, and that
// the modifiers the reverse map infers pick the column the forward map needs.
// A table that inverts and an implementation that does not is exactly the gap
// a generator's self-check cannot see.
//
// THE MODEL IOU is the IIe's, and only the parts the walk touches: one latch
// with the strobe in bit 7, set by a keypress; a read of $C000 hands it over;
// a read of $C010 hands over ANY KEY DOWN in bit 7 instead and clears the
// strobe.  `akd` is driven by the bench, because on a real IIe it is the
// user's finger.  The two Apple keys are levels at $C061 and $C062.
//
// THE WALK IS DRIVEN AS THE DRIVER DRIVES IT: park_addr is read back from the
// module and presented as a dummy read, with the byte on data_sync the clock
// BEFORE op_commit - which is where rtl/apple_bus_write.sv puts it and what
// the module's data_q register exists to catch.
//////////////////////////////////////////////////////////////////////////////////
module gs_kbd_a2_tb #(parameter KEYMAP = "adb_keymap.hex",
                      parameter REVMAP = "adb_revmap.hex");

    localparam integer P = 10;

    reg clk = 1'b0;
    always #(P/2) clk = ~clk;

    reg        rst = 1'b1, res_sync = 1'b0, enable = 1'b1;
    reg [15:0] op_addr = 16'd0;
    reg        op_rw = 1'b1, op_commit = 1'b0, op_dummy = 1'b0;
    reg [7:0]  data_sync = 8'd0;
    reg        frame_tick = 1'b0;

    wire [15:0] park_addr;
    wire        ev_valid, ev_up;
    wire [6:0]  ev_code;
    wire [7:0]  ev_mods, live_mods, cnt_keys, cnt_timeouts;

    gs_kbd_a2 #(.REVMAP (REVMAP)) u_kbd (
        .clk (clk), .rst (rst), .res_sync (res_sync), .enable (enable),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .op_dummy (op_dummy), .data_sync (data_sync),
        .wall_tick (frame_tick),
        .park_addr (park_addr),
        .ev_valid (ev_valid), .ev_code (ev_code), .ev_up (ev_up),
        .ev_mods (ev_mods), .live_mods (live_mods),
        .cnt_keys (cnt_keys), .cnt_timeouts (cnt_timeouts)
    );

    // ---- the machine's side of the ADB micro --------------------------------
    reg [7:0]  op_lo = 8'd0, op_wdata = 8'd0;
    reg        adb_rw = 1'b1, act = 1'b0;
    wire [7:0] rd_byte, c025;

    gs_adb #(.KEYMAP (KEYMAP)) u_adb (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (op_lo), .op_rw (adb_rw), .op_wdata (op_wdata), .act (act),
        .rd_byte (rd_byte), .wall_tick (frame_tick), .c000_ext (1'b0), .c000_byte (),
        // THE POINT OF THE BENCH: the micro's keys come from the card here,
        // not from a host message, and the message ports are held quiet.
        .loc_valid (ev_valid), .loc_code (ev_code), .loc_up (ev_up),
        .loc_mods (ev_mods), .live_mods (live_mods),
        .msg_valid (1'b0), .msg_type (8'd0), .msg_free (16'd0), .msg_len (8'd0),
        .pay_data (32'd0), .pay_valid (1'b0),
        .c025_rd (c025), .irq_data (), .irq_mouse (),
        .cnt_cmds (), .cnt_unknown ()
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

    // ---- the model IOU ------------------------------------------------------
    reg [7:0] latch = 8'h00;        // the key, strobe in bit 7
    reg       akd   = 1'b0;         // a key is physically held
    reg       oa    = 1'b0, ca = 1'b0;

    task automatic iou_press(input [6:0] a);
        begin latch = {1'b1, a}; akd = 1'b1; end
    endtask

    // One dummy cycle at whatever the walk asked for, answered by the IOU.
    task automatic dummy;
        reg [7:0] b;
        begin
            @(negedge clk);
            op_addr = park_addr;
            case (park_addr[7:0])
                8'h00:   b = latch;
                8'h10:   b = {akd, latch[6:0]};
                8'h61:   b = {oa, 7'd0};
                default: b = {ca, 7'd0};
            endcase
            // data_sync is the bus's byte at T_DIN, the clock before the
            // commit: the module's data_q is what catches it.
            data_sync = b; op_rw = 1'b1; op_dummy = 1'b1; op_commit = 1'b0;
            @(negedge clk);
            op_commit = 1'b1;
            if (park_addr[7:0] == 8'h10) latch[7] = 1'b0;   // the access clears it
            @(negedge clk);
            op_commit = 1'b0; op_dummy = 1'b0;
            // The event lands a clock later and gs_adb applies it on a clock
            // with no `act`; give it room.
            repeat (4) @(negedge clk);
        end
    endtask

    // A whole rotation of the walk, so every slot is visited.
    task automatic walk(input integer n);
        integer k;
        begin for (k = 0; k < n * 4; k = k + 1) dummy(); end
    endtask

    // ---- the machine reading the micro --------------------------------------
    task automatic rd(input [7:0] lo, output [7:0] v);
        begin
            @(negedge clk);
            op_lo = lo; adb_rw = 1'b1; act = 1'b0;
            @(negedge clk);
            v = rd_byte;
            act = 1'b1;
            @(negedge clk);
            act = 1'b0;
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

    reg [7:0] v, v2;
    integer   n, bad;

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0; res_sync = 1'b1;
        repeat (4) @(negedge clk);

        // ---- THE ROUND TRIP, ALL 128 VALUES ---------------------------------
        // The IOU is given an ASCII byte; the machine must read the same one
        // back out of $C000 with the strobe set.  Every failure is named, and
        // the count is the check, so one broken entry does not print 128
        // lines.
        bad = 0;
        for (n = 0; n < 128; n = n + 1) begin
            iou_press(n[6:0]);
            walk(2);
            rd(8'h00, v);
            if (v !== {1'b1, n[6:0]}) begin
                bad = bad + 1;
                if (bad <= 6)
                    $display("   $%02X came back as $%02X", n[6:0], v);
            end
            rd(8'h10, v);
            akd = 1'b0;
            walk(2);
        end
        if (bad == 0) ok("all 128 ASCII values survive the round trip through the IOU");
        else fail($sformatf("%0d of 128 ASCII values did not survive the round trip", bad));

        // ---- the modifiers the reverse map inferred -------------------------
        // A capital is reported as shift; a control character as control.
        // Caps lock is never claimed - the encoder folded it in already, and
        // shift is the account this map can defend (rtl/gs_kbd_a2.sv).
        iou_press(7'h41);                              // 'A'
        walk(2);
        chk(c025 & 8'h07, 8'h01, "a capital arrives as shift");
        rd(8'h00, v); chk(v, 8'hC1, "...and reads back as 'A'");
        rd(8'h10, v); akd = 1'b0; walk(2);

        iou_press(7'h03);                              // control-C
        walk(2);
        chk(c025 & 8'h07, 8'h02, "a control character arrives as control");
        rd(8'h00, v); chk(v, 8'h83, "...and reads back as $03");
        rd(8'h10, v); akd = 1'b0; walk(2);

        // ---- the keys that are keys, not control combinations ---------------
        // Return is the RETURN KEY and not control-M, the left arrow is the
        // ARROW and not control-H: tools/gen_adb_revmap.py's tie-break, seen
        // from the machine's side through a Talk register 0.
        drain_talk();
        iou_press(7'h0D);
        walk(2);
        chk(c025 & 8'h07, 8'h00, "Return needs no modifier");
        rd(8'h00, v); chk(v, 8'h8D, "Return reads back as $0D");
        rd(8'h10, v);
        // Command $C2: Talk, device 2, register 0 - the raw event queue.
        adb_wr(8'h26, 8'hC2);
        rd(8'h26, v); chk(v, 8'h81, "a Talk after Return says two bytes follow");
        rd(8'h26, v); rd(8'h26, v2);
        chk(v2, 8'h24, "the down event names keycode $24 - the Return KEY, not control-M");
        akd = 1'b0; walk(2);
        drain_talk();

        drain_talk();
        iou_press(7'h08);
        walk(2);
        rd(8'h00, v); chk(v, 8'h88, "the left arrow reads back as $08");
        rd(8'h10, v);
        adb_wr(8'h26, 8'hC2);
        rd(8'h26, v); rd(8'h26, v); rd(8'h26, v2);
        chk(v2, 8'h3B, "...and names keycode $3B - the ARROW, not control-H");
        akd = 1'b0; walk(2);
        drain_talk();

        // ---- THE STROBE IS CLEARED, SO THE SAME KEY TWICE IS TWO KEYS -------
        // The whole reason the walk visits $C010: on this build the machine's
        // own $C010 is answered on the card and the IOU never sees one, so
        // without the clear bit 7 would stay set and the second press would
        // be invisible.
        iou_press(7'h5A); walk(2); rd(8'h00, v); chk(v, 8'hDA, "'Z' the first time");
        rd(8'h10, v);
        iou_press(7'h5A); walk(2); rd(8'h00, v); chk(v, 8'hDA, "'Z' again is seen again");
        rd(8'h10, v); akd = 1'b0; walk(2);

        // ---- ANY KEY DOWN holds the key, and its release lets go ------------
        iou_press(7'h71);                              // 'q', and held
        walk(2);
        rd(8'h00, v); chk(v, 8'hF1, "'q' arrives");
        rd(8'h10, v); chk(v[7], 1'b1, "$C010 says a key is still down");
        walk(4);
        rd(8'h10, v); chk(v[7], 1'b1, "...and goes on saying so while AKD holds");
        akd = 1'b0;
        walk(2);
        rd(8'h10, v); chk(v[7], 1'b0, "AKD falling releases the key");

        // ---- ...and the timeout releases it if AKD is never seen ------------
        // The one failure that would wedge a machine is a key stuck down, so
        // it is released anyway.  The walk is stopped so nothing can confirm
        // it, and the frames run out.
        iou_press(7'h77);                              // 'w'
        walk(1);                                       // enough for the press
        rd(8'h00, v); chk(v, 8'hF7, "'w' arrives");
        rd(8'h10, v);
        n = int'(cnt_timeouts);
        frames(8);                                     // ...and no dummy at all
        repeat (8) @(negedge clk);
        rd(8'h10, v); chk(v[7], 1'b0, "a key nothing confirms is let go anyway");
        if (cnt_timeouts != n[7:0]) ok("...and it is counted as a timeout");
        else fail("the timeout did not count");
        akd = 1'b0; walk(2);

        // ---- the Apple keys are levels, and they are $C025's ----------------
        // On a IIgs $C061 and $C062 ARE Command and Option (KEGS moremem.c),
        // and what GS/OS reads is $C025.  They are the only modifiers on this
        // keyboard that are genuinely held rather than inferred.
        oa = 1'b1; ca = 1'b0; walk(2);
        chk(c025 & 8'hC0, 8'h80, "Open-Apple is Command in $C025");
        oa = 1'b0; ca = 1'b1; walk(2);
        chk(c025 & 8'hC0, 8'h40, "Closed-Apple is Option");
        oa = 1'b1; ca = 1'b1; walk(2);
        chk(c025 & 8'hC0, 8'hC0, "both at once");
        // ...and a key pressed while they are held carries them.
        iou_press(7'h6F);                              // Command-Option-'o'
        walk(2);
        rd(8'h00, v); chk(v, 8'hEF, "a key under both still types its character");
        chk(c025 & 8'hC0, 8'hC0, "...with both modifiers still set");
        rd(8'h10, v); akd = 1'b0; oa = 1'b0; ca = 1'b0; walk(2);
        chk(c025 & 8'hC0, 8'h00, "letting go of both clears them");

        // ---- ...and so does the lever, with a key down ----------------------
        // Throwing the chicken bit stops the samples for good, so the key
        // that was down at the time can never be confirmed either.
        akd = 1'b0; walk(2);
        iou_press(7'h65);                              // 'e', and held
        akd = 1'b1;
        walk(2);
        rd(8'h00, v); chk(v, 8'hE5, "'e' arrives, and is held");
        rd(8'h10, v); chk(v[7], 1'b1, "...a key is down");
        enable = 1'b0;
        repeat (8) @(negedge clk);
        rd(8'h10, v); chk(v[7], 1'b0, "throwing the lever lets the held key go");
        enable = 1'b1; akd = 1'b0; walk(2);

        // ---- the lever ------------------------------------------------------
        // ACCEL_CTRL[28] on the host; with the walk off the keyboard is not
        // connected, which is what a chicken bit has to mean.
        enable = 1'b0;
        repeat (8) @(negedge clk);
        chk(park_addr[7:0], 8'h00, "with the walk off the park is the keyboard's own default");
        iou_press(7'h5A);
        walk(2);
        rd(8'h00, v); chk(v[7], 1'b0, "a key pressed with the walk off reaches nothing");

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    task automatic adb_wr(input [7:0] lo, input [7:0] d);
        begin
            @(negedge clk);
            op_lo = lo; adb_rw = 1'b0; op_wdata = d; act = 1'b0;
            @(negedge clk);
            act = 1'b1;
            @(negedge clk);
            act = 1'b0;
        end
    endtask

    // Talks until one answers $80: the raw queue empty, so the next section
    // starts from a known keyboard.
    task automatic drain_talk;
        integer k;
        reg [7:0] t;
        begin
            for (k = 0; k < 12; k = k + 1) begin
                adb_wr(8'h26, 8'hC2);
                rd(8'h26, t);
                if (t == 8'h80) k = 12;
                else begin rd(8'h26, t); rd(8'h26, t); end
            end
        end
    endtask

    initial begin
        #20_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
