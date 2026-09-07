`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// kbd_inject - the keyboard the soft core reads, with the host on it.
//
// The boot hold reads the keyboard for the host; this is the mirror.  The host
// presses a key, and the next read of $C000 the machine makes returns it, bit
// 7 set, exactly as the keyboard encoder would have handed it over - so a
// script can continue the boot menu, drive a launcher, or type at a prompt
// with nobody at the Apple.  See docs/KEYBOARD.md.
//
// A SUBSTITUTION, NOT A CLAIM.  An on-card peripheral answers a read by
// driving the data pins (slot_rd_claim in apple_bus_write), which is safe
// only for an address the motherboard maps to an empty slot.  $C000 is not
// one: the IIe's IOU, or the ][+'s keyboard latch, drives the bus on every
// $C00x read, and a card that drove it too would be fighting the machine.
// So nothing here reaches the pins.  The byte the core latches as din, and
// the byte the capture records, become this module's answer; the wire
// carries whatever the real keyboard says.  That is the SYNC substitution's
// precedent (apple_bus_read's sync_override): logically exact, electrically
// absent.  The driver samples din and the reader samples its event on the
// same fabric clock - T_DIN and DATA_TAP are the same tap - so one
// combinational decision lands identically in the CPU and in the trace, and
// the host's shadow of the machine sees what the machine saw.
//
// THE MODEL IS THE IOU'S OWN: A LATCH AND A STROBE.  The keyboard the machine
// reads is one byte - the last key, with the strobe in bit 7 - and this
// module holds that byte for the soft core with two sources feeding it.
//
//   * `last_read` is the key the machine saw last, real or injected.  A
//     $C00x read that finds no strobe anywhere returns {0, last_read}, which
//     is what the IOU returns after a $C010: the key is still in the latch,
//     the strobe is gone.
//   * A real keypress - the bus's byte with bit 7 set on a $C00x read - is
//     handed to the core as it is and becomes last_read.
//   * An injected key is one latch (`key`) and one strobe, AppleWin's
//     `keycode` and `keywaiting`.  While its strobe is set a $C00x read
//     returns {1, key}, and it becomes last_read.  A press replaces whatever
//     is in the latch, consumed or not: the newest key wins, as it does when
//     two physical keys land before a $C010.  There is no queue; typing a
//     string at the machine's pace is the host's job.
//   * Both ready at once, the injected key wins.  The real one is not lost:
//     its strobe is the motherboard's, still set, and shows through the
//     moment the injected one is cleared - unless the $C010 that clears the
//     injected key clears it too, which is what that access means.
//
// WHAT CLEARS THE STROBE is the IIe's rule as AppleWin models it: any access
// to $C010, or a WRITE to $C011-$C01F.  A read of $C011-$C01F returns a soft
// switch's state over the key and leaves the strobe alone.  A ][+ clears on
// any $C01x read as well; the IIe rule is the safe one to share, because the
// failure the other way - a program polling $C019 for VBL eating an injected
// key - is the one that loses keys.
//
// EVERY PRESS IS RESOLVED EXACTLY ONCE, and the counts say how.  `pressed`
// counts presses; a press leaves the latch by one of four routes, and the
// host, which presses one key and waits for it to be resolved before the
// next, reads them as the acknowledgement it is waiting for:
//
//   taken     a $C010 cleared it after at least one $C00x read returned it:
//             a program got the key.
//   flushed   a $C010 cleared it and nothing had read it: a program cleared
//             the strobe without looking - the Esc pressed as a game
//             launches, eaten by its first $C010.  Gone, unseen.
//   replaced  a second press landed on it first.  Only a host that presses
//             without waiting sees this.
//   dropped   the register's drop, or a RES': a key meant for the program
//             that was running is not owed to the one the reset starts.
//             Not counted separately - it is pressed - strobe - the others.
//
// `changed` pulses on every resolution and on `touched` (below), and the
// link turns that into the KBD_EVENT notice when the host has asked for
// one.  `resolved_key` is the key of the press resolved last, for the
// notice to carry.
//
// THE LOCK.  With `lock` set the machine's own keyboard is suppressed: a
// real keypress neither reaches the core nor updates last_read, and the
// any-key-down flag a IIe returns in bit 7 of a $C010 read is masked too.
// The core sees the injected keys and nothing else, which is what a
// scripted test wants - a stray key at the Apple cannot steer it.  A real
// key that arrives while locked sets `touched`, sticky until the lock is
// next engaged: the record that somebody touched the machine during the
// run.  The motherboard's own strobe is not this module's to clear; a real
// key pressed while locked stays pending there, and is cleared by the next
// $C010 the machine makes - which every injected key it takes provides - or
// shows through when the lock lifts.
//
// ONLY $C00x READS CHANGE, and $C010 reads under the lock.  A write to $C00x
// is a soft switch (80STORE and friends) and its data is the core's; a read
// of $C011-$C01F carries a switch in bit 7, the machine's own.  Neither is
// touched.
//
// A RESET DROPS THE KEY, and keeps last_read: the IOU's latch survives a
// reset too.  So does the register's `drop`.  The counts, the lock and
// `touched` are the card's, not the machine's, and only the card's reset
// clears them.
//
// THE HOTKEY.  One real key is the card's, not the program's: the one that
// opens the runtime menu (docs/RUNTIME_MENU.md).  A $C00x read that would
// have returned it - a real key, bit 7 set, no injected key ahead of it,
// the lock off - returns {0, last_read} instead, the IOU's answer to "no
// key", and pulses `hotkey_hit` for the hold.  The program never sees it,
// the capture never records it, and last_read does not learn it: it was
// never handed over.  Its strobe stays set in the IOU, because only a bus
// access to $C010 clears that, and the hold makes one first thing (see
// boot_hold).  While the hold is on the key passes through like any other:
// the reads are the card's own, for the host, and the host may want the
// same key to mean "leave".  Under the lock a real key is not the
// program's either, so the hotkey is not looked for there - the lock is
// for a scripted run, and the host has the register to knock with.
//
// ONLY THE PROGRAM'S OWN READS.  A program that never reads the keyboard
// never hands the hotkey over, and that is left so: the card does not read
// $C000 on its own account to find it, because that would cost the machine
// a bus cycle, and the machine's timing is not the menu's to spend (see
// boot_hold).
//
// WITH THE NATIVE CPU DRIVING there is no din of ours to substitute into and
// the capture must not lie, so master_active low makes this a wire.
//////////////////////////////////////////////////////////////////////////////////
module kbd_inject (
    input  wire        clk,
    input  wire        rst,             // the card's reset: counts, lock state
    input  wire        cpu_rst,         // the core's: the card's OR RES' asserted
    input  wire        master_active,   // 1 while the card is the CPU

    // From the KBD_INJECT register.  press latches press_key and sets the
    // strobe; drop clears the strobe.  Both are one-clock pulses.  lock is
    // a level, from KBD_CTRL.
    input  wire        press,
    input  wire [6:0]  press_key,
    input  wire        drop,
    input  wire        lock,

    // The hotkey, from MENU_HOLD: look for it at all, and which key.  And
    // from boot_hold: the machine is held, so the reads are the card's.
    input  wire        hotkey_en,
    input  wire [6:0]  hotkey,
    input  wire        held,

    // The presented op, from apple_bus_write: one stable value per bus
    // cycle, and op_commit at its data phase.  data_sync is the bus's byte
    // as both consumers sample it at T_DIN, the clock before op_commit.
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire        op_commit,
    input  wire [7:0]  data_sync,

    // The substitution: while sub_en, the byte the core latches and the byte
    // the capture records is sub_data.  Combinational from the state and the
    // presented op, so both consumers see one answer.
    output wire        sub_en,
    output wire [7:0]  sub_data,

    // ---- the internalized keyboard (docs/ACCELERATION.md) -------------------
    // In the closed regime the driver parks its dummy cycles at $C000
    // instead of $0000, and the byte each one brings back - the real IOU's
    // answer, key and strobe together - lands in a latch here.  A program's
    // $C00x read is then served on the card: int_byte is the decision
    // kbd_byte makes for a bus read, taken against the latch, and int_rd
    // applies the read's bookkeeping (seen, last_read, the hotkey) exactly
    // once, at the op's retirement.  A dummy is a SAMPLE, never a read:
    // none of the read-side state moves on one.  A strobe-clearing bus op
    // clears the latch's bit 7 the way it clears the IOU's, so a $C010
    // followed at once by an internalized $C000 cannot hand the same key
    // over twice.
    input  wire        park_kbd,        // dummies park at $C000 (level)
    input  wire        op_dummy,        // the committed op was a dummy
    output wire        int_ok,          // the latch holds a byte: serving allowed
    input  wire        int_rd,          // one clock: an internalized $C00x read retired
    output wire [7:0]  int_byte,        // ...and its answer
    output wire [6:0]  int_low,         // the latch's low bits, for status reads

    // Read back through the registers, and carried by the notice.
    output logic       strobe,          // an injected key is waiting
    output logic       seen,            // ...and a $C00x read has returned it
    output logic       touched,         // a real key arrived while locked
    output logic [7:0] pressed,         // presses, wrapping
    output logic [7:0] taken,           // resolved: read, then strobed
    output logic [7:0] flushed,         // resolved: strobed unread
    output logic [7:0] replaced,        // resolved: pressed over
    output logic [6:0] resolved_key,    // the key of the press resolved last
    output logic       changed,         // one clock: a count or touched moved
    output logic       hotkey_hit       // one clock: the hotkey was read and eaten
);

    logic [6:0] key;
    logic [6:0] last_read;
    logic [7:0] data_q;                 // data_sync a clock ago: the T_DIN sample
    logic       hot_q;                  // ...and the hotkey decision made on it
    logic       match_q;                // ...and whether its low seven bits are the hotkey
    logic       lock_q;

    // A read of $C000-$C00F is the keyboard; a read of $C010 is the strobe
    // register, any-key-down in bit 7 on a IIe.
    wire kbd_read  = op_rw && (op_addr[15:4] == 12'hC00);
    wire strb_read = op_rw && (op_addr == 16'hC010);
    // Any access to $C010, or a write to $C011-$C01F, clears the strobe.
    wire kbd_clear = (op_addr == 16'hC010) ||
                     (!op_rw && (op_addr[15:4] == 12'hC01));

    // The real byte on the bus is the hotkey, and this is a read that would
    // have handed it to the program.
    wire hot_byte  = hotkey_en && !held && !lock && data_sync[7] &&
                     (data_sync[6:0] == hotkey);

    // What a $C00x read returns: the injected key first, the real one if it
    // is allowed through and is not the card's, the latch otherwise.
    wire [7:0] kbd_byte = strobe                  ? {1'b1, key} :
                          (data_sync[7] && !lock && !hot_byte) ? data_sync :
                                                    {1'b0, last_read};

    // A parked dummy is a SAMPLE: no substitution lands on it, so the
    // capture's byte for a dummy is the machine's own.
    assign sub_en   = master_active && !op_dummy && (kbd_read || (lock && strb_read));
    assign sub_data = kbd_read ? kbd_byte : {1'b0, last_read};

    // The same decision at the data phase, on the byte the core took.  A
    // parked dummy looks like a $C00x read on the op stream and must not
    // move any read-side state.
    wire commit     = op_commit && master_active;
    wire real_q     = data_q[7];
    wire kbd_take   = commit && kbd_read && !op_dummy;

    // ---- the parked-dummy latch ---------------------------------------------
    logic [7:0] real_latch;
    logic       latch_v;
    // Whether the latched key IS the hotkey, decided when the latch was
    // written (match_q rode beside data_q) rather than by a compare on the
    // serve path: that compare - three LUT levels off the MENU_HOLD
    // register - sat on every served $C000 byte's way into the core, and
    // was the design's second-worst family (2026-09-06).  Stale only if
    // the host changes the hotkey while a key sits in the latch, until the
    // next dummy sample - microseconds, at a configuration write.
    logic       latch_hot;
    wire dummy_kbd = commit && op_dummy && park_kbd && op_rw &&
                     (op_addr[15:4] == 12'hC00);
    always_ff @(posedge clk) begin
        if (rst || cpu_rst || !park_kbd) begin
            latch_v <= 1'b0;
        end else if (dummy_kbd) begin
            real_latch <= data_q;
            latch_hot  <= match_q;
            latch_v    <= 1'b1;
        end else if (commit && !op_dummy && kbd_clear) begin
            // The strobe just cleared on the machine; the latch follows,
            // key kept, exactly the IOU's rule.
            real_latch[7] <= 1'b0;
        end
    end

    // The internal serve: kbd_byte's decision against the latch.
    wire int_hot = hotkey_en && !held && !lock && real_latch[7] && latch_hot;
    assign int_byte = strobe                                   ? {1'b1, key} :
                      (real_latch[7] && !lock && !int_hot)     ? real_latch :
                                                                 {1'b0, last_read};
    assign int_ok  = latch_v && master_active;
    assign int_low = int_byte[6:0];
    wire clear_now  = commit && kbd_clear && strobe;
    // A press over a waiting key that is not being cleared or dropped this
    // same clock replaces it.
    wire replace_now = press && strobe && !clear_now && !drop;
    wire drop_now    = (drop || cpu_rst) && strobe && !clear_now;

    // ---- the machine's keyboard: key, strobe, seen, last_read --------------
    always_ff @(posedge clk) begin
        data_q <= data_sync;
        // The hotkey is the card's only when the real byte is what the read
        // returns: an injected key ahead of it is what the program gets, and
        // the hotkey is found by the next read after that one is cleared.
        hot_q  <= hot_byte && !strobe;
        match_q <= (data_sync[6:0] == hotkey);
        if (cpu_rst) begin
            key    <= 7'd0;
            strobe <= 1'b0;
            seen   <= 1'b0;
        end else begin
            if (commit && kbd_clear && !op_dummy) strobe <= 1'b0;
            if (drop)                strobe <= 1'b0;
            if ((kbd_take || int_rd) && strobe)  seen <= 1'b1;
            // Last, so a press in the same clock as a clear is a new key,
            // not a lost one.
            if (press) begin
                key    <= press_key;
                strobe <= 1'b1;
                seen   <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            last_read <= 7'd0;
        end else if (kbd_take) begin
            if (strobe)                           last_read <= key;
            else if (real_q && !lock && !hot_q)   last_read <= data_q[6:0];
        end else if (int_rd) begin
            if (strobe)                                      last_read <= key;
            else if (real_latch[7] && !lock && !int_hot)     last_read <= real_latch[6:0];
        end
    end

    // The hotkey was read and eaten.  A pulse for boot_hold, the card's
    // reset its only reset: the hold that it opens is the card's business,
    // not the machine's.
    always_ff @(posedge clk) begin
        if (rst) hotkey_hit <= 1'b0;
        else     hotkey_hit <= (kbd_take && hot_q) ||
                               (int_rd && int_hot && !strobe);
    end

    // ---- the card's: counts, touched, changed -------------------------------
    always_ff @(posedge clk) begin
        lock_q <= lock;
        if (rst) begin
            pressed      <= 8'd0;
            taken        <= 8'd0;
            flushed      <= 8'd0;
            replaced     <= 8'd0;
            resolved_key <= 7'd0;
            touched      <= 1'b0;
            changed      <= 1'b0;
        end else begin
            changed <= 1'b0;
            if (press) pressed <= pressed + 8'd1;
            if (clear_now) begin
                if (seen) taken   <= taken + 8'd1;
                else      flushed <= flushed + 8'd1;
            end
            if (replace_now) replaced <= replaced + 8'd1;
            if (clear_now || replace_now || drop_now) begin
                resolved_key <= key;
                changed      <= 1'b1;
            end
            // A fresh lock starts a fresh record.
            if (lock && !lock_q) touched <= 1'b0;
            else if (((kbd_take && real_q) || (int_rd && real_latch[7])) &&
                     !strobe && lock && !touched) begin
                touched <= 1'b1;
                changed <= 1'b1;
            end
        end
    end

endmodule
