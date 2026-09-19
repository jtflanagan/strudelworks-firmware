`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// pb_inject - the pushbuttons, as the host would have them.
//
// Open-Apple, Closed-Apple and the third button are the game port's PB0-PB2,
// read at $C061-$C063 in bit 7.  A button is a LEVEL: the machine reads it
// now, with no latch and no strobe, so there is nothing here the machine
// could consume.  The card holds one word per button from the host -
// hardware, up, or down - and on a read of that button's address merges it
// into bit 7 over the bus's own low seven bits.  "hardware" is a wire: the
// joystick and the keys on the keyboard are what they always were.  See
// docs/KEYBOARD.md.
//
// The same substitution as the keyboard's (rtl/kbd_inject.sv), for the same
// reason: the motherboard drives $C06x, so the card must not.  The core's din
// and the captured event take sub_data on the same tap, and sub_data is a
// function of data_sync - which both consumers sample on that tap - so they
// still agree.  A write from the host that lands mid-cycle decides only
// whether THIS read sees the old level or the new; both are levels the host
// asked for, and no read is ever torn.
//
// NOT DROPPED BY A RESET, unlike the keyboard's key, and deliberately: the
// //e's reset handler reads Open-Apple AFTER RES' releases - Open-Apple-
// Ctrl-Reset is a cold boot, both Apples is the self-test - so an override
// that a reset cleared could never do the one thing Open-Apple is for.  The
// host sets it, the host clears it (and does at exit).  Only the card's own
// reset returns everything to hardware.
//
// WITH THE NATIVE CPU DRIVING there is no din of ours, so master_active low
// makes this a wire, as it makes the keyboard.
//////////////////////////////////////////////////////////////////////////////////
module pb_inject (
    input  wire        clk,
    input  wire        rst,             // the card's reset only
    input  wire        master_active,

    // From the BUTTONS register: two bits per button, PB0 in [1:0].
    //   00 hardware   01 up (bit 7 reads 0)   10 down (bit 7 reads 1)
    input  wire [5:0]  sel,

    // The presented op, and the bus's byte as both consumers sample it.  A
    // dummy is a SAMPLE for rtl/game_port.sv: no override lands on it, so
    // the capture's byte for one is the machine's own.
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire        op_commit,
    input  wire        op_dummy,
    input  wire [7:0]  data_sync,

    output wire        sub_en,
    output wire [7:0]  sub_data,

    // What the bus itself said in bit 7, the last time each button was
    // read: the hardware level the host may be overriding.
    output logic [2:0] hw_level
);

    // $C061, $C062, $C063.
    wire pb_read = master_active && !op_dummy && op_rw && (op_addr[15:2] == 14'h3018) &&
                   (op_addr[1:0] != 2'b00);
    wire [1:0] idx = op_addr[1:0] - 2'd1;
    wire [1:0] want = sel[idx * 2 +: 2];

    assign sub_en   = pb_read && (want != 2'b00);
    assign sub_data = {want[1], data_sync[6:0]};

    always_ff @(posedge clk) begin
        if (rst) begin
            hw_level <= 3'b000;
        end else if (op_commit && pb_read) begin
            hw_level[idx] <= data_sync[7];
        end
    end

endmodule
