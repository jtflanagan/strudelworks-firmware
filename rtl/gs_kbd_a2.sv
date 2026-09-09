`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_kbd_a2 - the Apple IIe's own keyboard, as an ADB device.
//
// The card lives in an Apple IIe, and at GS = 1 the keyboard under the user's
// hands is that machine's.  Nothing reached it before this module: the IIgs
// build stands rtl/kbd_inject.sv down (rtl/master_top.sv, kbd_sub_gs) because
// rtl/gs_io.sv claims $C000 and $C010 for the ADB micro, and the micro's only
// key source was the host's ADB_KEY message - the Pi's USB keyboard.  So the
// real keyboard was electrically present and logically absent.
//
// WHAT THE IOU HANDS OVER IS THE WRONG SHAPE.  The IIe's keyboard encoder has
// already applied shift, control and caps lock and thrown the keycode away:
// what is in the latch is an ASCII byte with the strobe in bit 7.  An ADB
// micro is given the opposite - a KEYCODE and a modifier byte - and makes the
// ASCII itself.  So the byte is run BACKWARDS through the micro's own keymap
// here (rtl/adb_revmap.hex, tools/gen_adb_revmap.py) into the keycode and the
// modifiers that would have produced it, and rtl/gs_adb.sv then makes the
// same byte again forwards.  The generator asserts that round trip for all
// 128 values, so the character the user typed is the character the machine
// reads; what is approximated is everything AROUND the character, and the
// list of what is lost is at the end of this comment.
//
// THE SAMPLE IS A DUMMY CYCLE, AS IT IS ON THE IIe.  The driver fills the bus
// with parked reads while the core runs on the card, and park_kbd points them
// at the keyboard instead of $0000 - rtl/apple_bus_write.sv, and
// rtl/game_port.sv does the same thing for the IIe's closed regime.  A dummy
// is nobody's op, so watching the keyboard costs the machine no cycle, which
// is the standing rule.  This module owns park_addr on the IIgs build and
// walks it:
//
//     $C000  read the latch.  Bit 7 set = a key is waiting.
//     $C010  clear the IOU's strobe, and read ANY KEY DOWN back in bit 7.
//
// THE STROBE IS OURS TO CLEAR HERE, WHICH IT IS NOT ON THE IIe.  There, the
// program's own $C010 rides the bus for exactly this reason (rtl/apple_mmu.sv,
// "$C010 is the real strobe's and rides the bus").  Here gs_io answers $C010
// on the card and the IOU never sees one, so without the walk above the first
// key would latch and stay: the same key pressed twice would be invisible,
// because only bit 7 says "again" and it never falls.
//
// KEY-UP COMES FROM ANY KEY DOWN, WITH A TIMEOUT BEHIND IT.  The IIe's $C010
// returns AKD in bit 7 - a real, live "a key is physically held" - so a
// release can be seen rather than guessed, and gs_adb's hard_key_down,
// $C025 bit 5 and the any-key-down a game polls all follow the user's finger.
// The timeout is there because AKD is sampled on a cycle of the walk and a
// new strobe can land on the $C010 slot, where bit 7 is AKD and not the
// strobe: the key would then be seen by its low seven bits alone, and holding
// a key down for ever on a missed edge is the one failure that wedges a
// machine.  T_HELD frames without the walk agreeing is enough - release it.
//
// AUTO-REPEAT IS THE IIe's, NOT THE MICRO's.  A held key on a IIe re-strobes
// in the keyboard encoder, so repeats arrive here as ordinary presses and
// gs_adb must not add its own on top.  It does not: its repeat fires on
// key_down, which is armed from an event's own modifiers, and a repeat that
// arrives as a fresh press re-arms the delay each time.  The Control Panel's
// repeat setting therefore does not reach the real keyboard.  That is the
// honest behaviour - the rate belongs to the hardware the keys are on.
//
// THE APPLE KEYS ARE REAL AND LIVE.  Open- and Closed-Apple are on the IIe's
// game port at $C061 and $C062, and on a IIgs those two addresses ARE Command
// and Option (KEGS moremem.c: `adb_is_cmd_key_down() || g_paddle_buttons&1`).
// A read of either already reaches the motherboard on this build - gs_io does
// not claim $C06x - so a program that looks there sees the real keys today.
// What has no source is $C025, which is what GS/OS's Event Manager reads, so
// the walk visits both buttons and this module publishes them as a LEVEL that
// gs_adb ORs into $C025.  They are the only modifiers here that are genuinely
// held rather than inferred.
//
// WHAT IS LOST, and it is all of it in the shape of the event and none of it
// in the character:
//
//   * Caps lock cannot be told from shift.  The encoder applies both and
//     sends one byte; an upper-case letter is reported as shift.
//   * A modifier pressed ALONE is invisible.  Shift, control and caps make no
//     strobe, so $C025's shift and control bits only ever appear for the
//     instant of a key that used them.  Command and Option are the exception,
//     above.
//   * There are no function keys, no keypad, no Help and no Home/End - the
//     keyboard does not have them.  Ctrl-Command-Esc (the Control Panel) and
//     Ctrl-Option-Reset (the self-test) are all reachable.
//   * A key that is also a control combination is reported as the KEY: $0D is
//     Return and not control-M, $08 the left arrow and not control-H, $7F
//     Delete and not control-hyphen.  tools/gen_adb_revmap.py sets that rule
//     out in full.
//////////////////////////////////////////////////////////////////////////////////
module gs_kbd_a2 #(
    // The ADB micro's keymap, run backwards: 128 entries indexed by the ASCII
    // byte, each {ctrl, shift, keycode[6:0]}.  tools/gen_adb_revmap.py.
    parameter REVMAP = "adb_revmap.hex",
    // Frames a key may be held with nothing confirming it before it is
    // released anyway.  Four is ~67 ms, shorter than the IIe encoder's own
    // repeat delay, so a missed release cannot outlive the key it belongs to.
    parameter [7:0] T_HELD = 8'd4
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,        // synchronised RES', ACTIVE LOW
    input  wire        enable,          // the walk runs at all (GS && the lever)

    // The presented op, from apple_bus_write, and the bus's byte as every
    // other sampler takes it: data_sync at T_DIN, the clock before op_commit.
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire        op_commit,
    input  wire        op_dummy,
    input  wire [7:0]  data_sync,

    // One pulse a video frame, the machine's own: the held-key timeout.
    input  wire        frame_tick,

    // Where the driver's NEXT dummy reads (rtl/apple_bus_write.sv park_addr).
    output logic [15:0] park_addr,

    // The event, in ADB_KEY's own shape, into rtl/gs_adb.sv beside the host's.
    // One clock; gs_adb registers it and the walk cannot produce another for
    // several bus cycles, so there is nothing to hold off.
    output logic        ev_valid,
    output logic [6:0]  ev_code,
    output logic        ev_up,
    output logic [7:0]  ev_mods,

    // Command and Option as the real keys stand, ORed into $C025 by gs_adb.
    output logic [7:0]  live_mods,

    // Diagnostics, read back through the hierarchy and the status register.
    output logic [7:0] cnt_keys,
    output logic [7:0] cnt_timeouts
);

    // $C025's bits, KEGS's order (adb.c SHIFT_DOWN and friends).
    localparam [7:0] M_SHIFT = 8'h01, M_CTRL = 8'h02;
    localparam [7:0] M_OPT   = 8'h40, M_CMD  = 8'h80;

    (* rom_style = "distributed" *) logic [8:0] revmap [0:127];
    initial $readmemh(REVMAP, revmap);

    // ---- the walk -----------------------------------------------------------
    // Four slots, so the two buttons are visited as often as the keyboard is
    // and the pair a keypress needs - the latch and the clear - are adjacent.
    // W_KEY reads $C000; W_CLR reads $C010, which clears the IOU's strobe and
    // brings AKD back whether or not a key was taken, so the release of a key
    // is seen at the same rate a press is.
    localparam [1:0] W_KEY = 2'd0, W_CLR = 2'd1, W_CMD = 2'd2, W_OPT = 2'd3;
    logic [1:0] slot;

    // Registered, so the driver's address cone sees a flop - rtl/game_port.sv
    // does the same, for the same reason.  It is one clock behind `slot`, and
    // the slot only moves at a dummy's commit with the next dummy many clocks
    // away, so the driver never presents a stale one.
    always_ff @(posedge clk) begin
        if (rst || !enable) park_addr <= 16'hC000;
        else case (slot)
            W_KEY:   park_addr <= 16'hC000;
            W_CLR:   park_addr <= 16'hC010;
            W_CMD:   park_addr <= 16'hC061;
            default: park_addr <= 16'hC062;
        endcase
    end

    // A dummy READ in page $C0.  WHICH slot it answers is decided by op_addr
    // and not by `slot`: a dummy the driver had already presented when the
    // slot advanced belongs to the address it carries.  The walk itself
    // advances on every sample regardless, as rtl/game_port.sv's `odd` does -
    // a duplicate then costs one rotation and never a stall.
    wire smp = op_commit && op_dummy && op_rw && enable &&
               (op_addr[15:8] == 8'hC0);
    wire smp_key = smp && (op_addr[7:0] == 8'h00);
    wire smp_clr = smp && (op_addr[7:0] == 8'h10);
    wire smp_cmd = smp && (op_addr[7:0] == 8'h61);
    wire smp_opt = smp && (op_addr[7:0] == 8'h62);

    // ---- the reverse lookup -------------------------------------------------
    // THE BYTE AT A COMMIT IS data_sync A CLOCK AGO.  data_sync is the bus's
    // byte at T_DIN, the clock before op_commit, so every sampler keeps it -
    // rtl/game_port.sv's data_q is the same register for the same reason.
    logic [7:0] data_q;
    always_ff @(posedge clk) data_q <= data_sync;

    // Combinational on the sampled byte, taken on the clock the event is
    // registered, so nothing downstream reads the ROM again.
    wire [8:0] rv       = revmap[data_q[6:0]];
    wire [6:0] rv_code  = rv[6:0];
    wire       rv_shift = rv[7];
    wire       rv_ctrl  = rv[8];

    // ---- the held key -------------------------------------------------------
    logic       held;
    logic [6:0] held_code;
    logic [7:0] held_left;      // frames before it is released anyway

    // A press is a $C000 sample with the strobe set.  The IIe's encoder
    // re-strobes a held key itself, so a repeat arrives here as a press of
    // the same key and is passed on as one - see the header.
    wire press = smp_key && data_q[7];
    // AKD, from the clear slot: the only live account of a key still down.
    wire akd   = smp_clr && data_q[7];
    wire rel   = smp_clr && !data_q[7] && held;
    wire expire = frame_tick && held && (held_left == 8'd0);

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            slot <= W_KEY;
            ev_valid <= 1'b0;
            ev_code <= 7'd0; ev_up <= 1'b0; ev_mods <= 8'd0;
            live_mods <= 8'd0;
            held <= 1'b0; held_code <= 7'd0; held_left <= 8'd0;
            // The counters are the card's own diagnostics and not the
            // machine's state, so only the card's reset clears them.
            if (rst) begin cnt_keys <= 8'd0; cnt_timeouts <= 8'd0; end
        end else begin
            ev_valid <= 1'b0;

            // THE WALK STOPS, THE KEY STILL HAS TO BE LET GO.  With the
            // lever thrown, the hold engaged or the core no longer driving,
            // no sample will ever confirm or deny the key that is down - and
            // a key stuck down is the one failure that wedges a machine,
            // because gs_adb's hard_key_down feeds $C025 bit 5, the
            // any-key-down a game polls, and the micro's own repeat.  So the
            // release below is reached whether the walk is running or not,
            // and only the walk itself is parked here.
            if (!enable) begin
                slot <= W_KEY;
                live_mods <= 8'd0;
            end else begin
                if (smp) slot <= slot + 2'd1;

                if (smp_cmd) live_mods[7] <= data_q[7];   // Open-Apple  -> Command
                if (smp_opt) live_mods[6] <= data_q[7];   // Closed-Apple-> Option
            end

            begin
                if (press) begin
                    ev_valid <= 1'b1;
                    ev_code  <= rv_code;
                    ev_up    <= 1'b0;
                    // ONLY WHAT THE BYTE SAYS.  Command and Option are NOT
                    // put in the event even though they are known: gs_adb
                    // latches an event's modifiers into c025_val, and these
                    // two are LEVELS - a latched copy outlives the finger,
                    // and the key that let go of both would leave them set
                    // for ever.  They reach $C025 the other way, merged live
                    // at the read from `live_mods`, which is always current.
                    // Caps lock is never claimed either: the encoder folded
                    // it into the character already, and shift is the account
                    // this map can defend.
                    ev_mods  <= (rv_shift ? M_SHIFT : 8'd0) |
                                (rv_ctrl  ? M_CTRL  : 8'd0);
                    held      <= 1'b1;
                    held_code <= rv_code;
                    held_left <= T_HELD;
                    cnt_keys  <= cnt_keys + 8'd1;
                end else if (akd) begin
                    // Still down: the timeout starts again.
                    held_left <= T_HELD;
                end else if (rel || expire || (!enable && held)) begin
                    ev_valid <= 1'b1;
                    ev_code  <= held_code;
                    ev_up    <= 1'b1;
                    // Nothing is still true: shift and control belonged to
                    // the character and are gone with it, and the two levels
                    // are never in an event at all.
                    ev_mods  <= 8'd0;
                    held     <= 1'b0;
                    if (expire || !enable) cnt_timeouts <= cnt_timeouts + 8'd1;
                end else if (frame_tick && held && (held_left != 8'd0)) begin
                    held_left <= held_left - 8'd1;
                end
            end
        end
    end

endmodule
