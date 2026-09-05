# The mouse: an AppleMouse II card on the card, the Pi's mouse behind it

Status: **✅ on hardware, 2026-09-05.** Bit at WNS +0.014 (the single-clock
first cut missed by 7 ns; see "Across clocks" in the RTL header). The
user's mousetest.po - a lo-res drawing program over the firmware's
SETMOUSE/READMOUSE/SERVEMOUSE - took the Pi's optical mouse and its clicks
in slot 5; injected moves walked MOUSE_STAT's position exactly.
`sim/run_mouse_card_tb.sh` drives the card the way the firmware ROM does
and checks every command against AppleWin's model; `sim/run_reg_map_tb.sh`
covers MOUSE_SLOT's latch and the five-way slot clash.

The AppleMouse II interface card is a 6821 PIA and a 68705 microcontroller
behind a 2 KB firmware ROM. The 6502 sees only the PIA: four registers at
DEVICE SELECT (`$C0n0`-`$C0n3`), port A a byte each way, port B the
handshake - the firmware clocks a command into the 68705 with PB5, clocks
answer bytes out with PB4, and selects which 256-byte page of the ROM
appears at I/O SELECT (`$Cn00`-`$CnFF`) with PB1-PB3. The 68705 owns the
mouse: the position, the clamps, the mode byte, the status byte, and the
interrupt it raises on movement, a button, or its own 60 Hz timer.
AppleWin (`source/MouseInterface.cpp`, `6821.cpp`; the project's
reference) models the PIA and the 68705's protocol in C++; `rtl/mouse_card.sv`
is that model as gateware, and the host supplies the two things the card
cannot: the firmware ROM and the physical mouse.

## Where it hangs

The same place as the Mockingboard (`rtl/mockingboard.sv`): on the
peripherals' view of the op stream - the driver's presented op on the bus,
the unified op for an access served on the card in the closed regime
(CXXX.md, "The on-card slots"; `rtl/apple_mmu.sv` q_slot counts the
mouse's DEVICE SELECT and I/O SELECT as on-card, so its accesses are fast
ops under acceleration like the VIAs'). A claimed read's byte returns
through `apple_bus_write`'s data window. The ROM page is gated by
`rtl/slot_switches.sv` (INTCXROM, and SLOTC3ROM for slot 3); the
device-select registers are never gated, which is the IIe's rule. The
interrupt takes the Mockingboard's short route: `master_top` folds it into
the soft core's `irq_n`. The card exists only while the soft core masters.

**The 60 Hz is the card's own.** The real card's "VBL" interrupt is the
68705's timer, not the video scanner's blanking - that is why the firmware
has a 50 Hz command - so it is a free-running counter here too, of the
CORE's cycles like the VIAs' clocks: 17030 a frame at 60 Hz, 20280 at 50.
At 1x that is 60 Hz of machine time, locked video or not; accelerated, the
frame interrupts come at the core's pace, which is what a program counting
them expects.

## The protocol, as ported

`On6821_B`, one clock after the PIA write latched it (the RTL header, "Across
clocks"). A port B write whose bits 1-5 change:

- **PB5 rising**: the 68705 is ready (PB7 set). **PB5 falling**: the byte
  on port A lands in the buffer. The first byte of a command decides its
  length and the first answer byte (READ fills all five; SERV the reason;
  INIT `$FF`); the last byte of a multi-byte command commits it (CLAMP,
  POS, INIT).
- **PB4 rising**: preparing the next value (PB6 clear). **PB4 falling**:
  the next answer byte onto port A; past the last, the buffer is ready for
  a command.
- PB1-PB3 are the ROM page.

The commands: SET (the mode), READ (position, buttons previous and
current, status), SERV (the interrupt's reason; releases the line), CLEAR
(position and status to zero, the clamps kept - Fantavision), POS, INIT
(home, clamps 0..1023), CLAMP (min above max folds to 0..min+max - Blazing
Paddles), HOME, TIME (60/50 Hz). Every rule is AppleWin's, including the
one that matters most: **READMOUSE clears the status byte's interrupt bits
but not the IRQ line; only SERVEMOUSE releases it** - AppleWin's "abnormal
operation" note, which Contiki depends on.

The PIA itself is VICE's mc6821 as AppleWin carries it: DDR/port select on
CRx bit 2, a data-port read clearing that side's interrupt flags, a write
to a port reaching the 68705 only through the DDR's output bits.

## The mouse itself

`MOUSE_MOVE` (type `0x25`): `free[1:0]` the buttons as levels, one word
`{dy, dx}` of signed deltas. The card adds each delta to its position and
clamps it (AppleWin's SetPositionRel/ClampX/ClampY), takes the button
levels, and runs OnMouseEvent: movement and button interrupts when the
mode asks, the "moved since last READMOUSE" bit kept for the next READ.
The host coalesces motion between its polls of the link and never merges
across a button edge, so a click shorter than a poll still arrives as two
messages. The position lives on the card because the clamps do: a program
sets them through the card, and the host never needs to know them.

## The ROM

2 KB the host loads: `MOUSE_ROM` (type `0x26`), `free[2:0]` the chunk,
64 words each, eight chunks in any order; the card answers nothing until
all eight have landed. Distributed RAM, read combinationally by page and
address and registered at present, the same timing the VidHD's ROM has.
The host vendors AppleWin's `MouseInterface.rom` as `assets/mouse.rom`
(its NOTICE says why); `mouse_rom = PATH` substitutes another.

## The registers

**`MOUSE_SLOT`, `0x8000_00D0`**: `[2:0]` desired (RW, 0 = off), `[10:8]`
active (latched at RES' and at a boot release, VIDHD_SLOT's contract,
yielding to the Mockingboard, the disk, the floppy and the VidHD),
`[16]` rom loaded, `[17]` IRQ asserted, `[19:18]` the buttons, `[23:20]`
the mode byte, `[31:24]` MOUSE_MOVEs applied. **`MOUSE_STAT`,
`0x8000_00D4`**: `{y, x}`, the position - what `accel status` and a
bring-up session look at first.

## Deliberately not there

- **The any-key-down / IIgs registers.** Not this card.
- **A position on the host.** The clamps are the card's; see above.
- **A locked-VBL interrupt.** The card's timer is its own (above); a
  program that wants the real blanking reads `$C019`.
- **Interrupts through the pin.** The soft core is on the near side of
  it; the Mockingboard's argument.
