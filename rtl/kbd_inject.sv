`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// kbd_inject - a key from the host, on the keyboard the soft core reads.
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
// the byte the capture records, become the host's key; the wire carries
// whatever the real keyboard says.  That is the SYNC substitution's precedent
// (apple_bus_read's sync_override): logically exact, electrically absent.
// The driver samples din and the reader samples its event on the same fabric
// clock - T_DIN and DATA_TAP are the same tap - so one combinational decision
// lands identically in the CPU and in the trace, and the host's shadow of the
// machine sees what the machine saw.
//
// THE MACHINE'S OWN SEMANTIC, AND NOTHING MORE.  One key latch and one
// strobe - AppleWin's `keycode` and `keywaiting`.  A press replaces whatever
// is in the latch and sets the strobe, consumed or not: the newest key wins,
// as it does when two physical keys land before a $C010.  There is no queue.
// Typing a string at the machine's pace is the host's job: press, watch the
// strobe clear, press the next - which is also how AppleWin's own injection,
// its clipboard paste, hands a program one character per strobe clear.
//
// WHAT CLEARS THE STROBE is the IIe's rule as AppleWin models it: any access
// to $C010, or a WRITE to $C011-$C01F.  A read of $C011-$C01F returns a soft
// switch's state over the key and leaves the strobe alone.  A ][+ clears on
// any $C01x read as well; the IIe rule is the safe one to share, because the
// failure the other way - a program polling $C019 for VBL eating an injected
// key - is the one that loses keys.  That same access clears the machine's
// own strobe too, which is simply what the access means.
//
// ONLY $C00x READS CHANGE.  A write to $C00x is a soft switch (80STORE and
// friends) and its data is the core's; a read of $C010-$C01F carries
// any-key-down or a switch in bit 7, the machine's own.  Neither is touched.
//
// A RESET DROPS THE KEY: a press meant for the program that was running is
// not owed to the one the reset starts.  So does the register's `drop`.
//
// WITH THE NATIVE CPU DRIVING there is no din of ours to substitute into and
// the capture must not lie, so master_active low makes this a wire.
//////////////////////////////////////////////////////////////////////////////////
module kbd_inject (
    input  wire        clk,
    input  wire        rst,             // the card's reset: counters
    input  wire        cpu_rst,         // the core's: the card's OR RES' asserted
    input  wire        master_active,   // 1 while the card is the CPU

    // From the KBD_INJECT register.  press latches press_key and sets the
    // strobe; drop clears the strobe.  Both are one-clock pulses.
    input  wire        press,
    input  wire [6:0]  press_key,
    input  wire        drop,

    // The presented op, from apple_bus_write: one stable value per bus
    // cycle, and op_commit at its data phase.
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire        op_commit,

    // The substitution: while sub_en, the byte the core latches and the byte
    // the capture records is sub_data.  Combinational from the latch, the
    // strobe and the presented op, so both consumers see one answer.
    output wire        sub_en,
    output wire [7:0]  sub_data,

    // Read back through the register.
    output logic       strobe,          // a key is waiting, not yet consumed
    output logic [7:0] taken            // strobes the machine consumed, wrapping
);

    logic [6:0] key;

    // A read of $C000-$C00F is the keyboard.
    wire kbd_read = op_rw && (op_addr[15:4] == 12'hC00);
    // Any access to $C010, or a write to $C011-$C01F, clears the strobe.
    wire kbd_clear = (op_addr == 16'hC010) ||
                     (!op_rw && (op_addr[15:4] == 12'hC01));

    assign sub_en   = master_active && strobe && kbd_read;
    assign sub_data = {1'b1, key};

    always_ff @(posedge clk) begin
        if (rst) begin
            taken <= 8'd0;
        end else if (op_commit && master_active && kbd_clear && strobe) begin
            taken <= taken + 8'd1;
        end
    end

    always_ff @(posedge clk) begin
        if (cpu_rst) begin
            key    <= 7'd0;
            strobe <= 1'b0;
        end else begin
            if (op_commit && master_active && kbd_clear) strobe <= 1'b0;
            if (drop)                                    strobe <= 1'b0;
            // Last, so a press in the same clock as a clear is a new key,
            // not a lost one.
            if (press) begin
                key    <= press_key;
                strobe <= 1'b1;
            end
        end
    end

endmodule
