# Mockingboard: the VIA pair on the card, the sound on the host

Status: **✅ built and simulated; not yet run against hardware.**

A Mockingboard is two 6522 VIAs the CPU talks to at `$Cn00-$CnFF`, each wired
to an AY-3-8913 sound chip the CPU cannot see: VIA port A is the AY's data
bus, port B carries its control pins (PB0 = BC1, PB1 = BDIR, PB2 = RESET',
BC2 strapped high). Every note ever played through one is, from the bus's
point of view, a sequence of VIA port writes.

That splits exactly along the seam this project already has:

- **The card carries the VIAs** (`rtl/mockingboard.sv`, wrapping the same
  `rtl/via6522.v` that ran in real machines under AppleTini v5_1_3). That is
  the half the bus can see, and it is what makes software believe the slot is
  populated: registers read back, T1 counts down, the T1 interrupt fires at
  the programmed period.
- **The host synthesises the AYs** (strudelworks-host `src/mb_audio.cpp`).
  It already receives every captured cycle to rebuild the display; the VIA
  writes are in that same stream, so it rebuilds the AY registers from them
  and runs the tone/noise/envelope generators at the machine's own 1.023 MHz,
  resampled out through ALSA. Nothing on the card makes a sound; nothing on
  the host is guessed.

## Only while mastering

In AppleTini v5 the card sat in a slot impersonating a peripheral against a
real 6502, driving the data bus at the peripheral's tap. Here the card's soft
core IS the CPU (see BUS_MASTER.md), so the Mockingboard hangs off
`apple_bus_write`'s presented op instead: it watches the address the card
itself is driving, and hands its read data back to be emitted in the CPU's
own data window. With the native 6502 driving, nothing can put a byte on the
bus at the peripheral's moment, so the module holds its VIAs in reset. If a
snoop-mode Mockingboard is ever wanted, v5's `bus_emit` timing is the
reference - it is a second drive path with different taps, not a variation of
this one.

The byte still goes out the pins and comes back through the level shifters
and the reader's synchroniser, so the CPU's `din` and the captured event both
carry what a real slot card would have driven, and the host needs no special
case to see it.

## The soft-switch gate

`$C400-$C4FF` is not always the slot 4 card. With INTCXROM set the
motherboard ROM owns all of `$C100-$CFFF` - and a IIe boots that way - so a
card that answered unconditionally would drive against the ROM's own output
buffer. `rtl/slot_switches.sv` (shared with the hard disk's slot ROM, see
HARDDISK.md) therefore tracks the two switches that gate I/O SELECT', from
the same driven ops:

| switch | set/clear | effect tracked |
|---|---|---|
| INTCXROM | `$C007` / `$C006` (write) | set → the whole of `$C1-$CF` is motherboard ROM |
| SLOTC3ROM | `$C00B` / `$C00A` (write) | clear → `$C3xx` is motherboard ROM regardless |

Carried from v5_1_3's `soft_switch_manager.sv`, cut down: the `$C8xx`
expansion-ROM select and the `$CFFF` release were deliberately left behind,
because neither a Mockingboard nor the 256-byte SmartPort ROM has a `$C8xx`
presence. A future card with one brings that logic back as its own module.

The one invariant that keeps the machine alive, asserted over the whole run
of `sim/mockingboard_tb.sv`: **the data bus is never driven on a read the
card has not claimed.**

## Enabling it

`MB_SLOT`, `0x8000_000C`: bits 2:0 the slot to answer as (0 = off, the
default), bits 10:8 what was latched. The same latched-at-RES' contract as
CPU_SOURCE and for the same reason scaled down - slot cards are discovered at
boot, so a reset is when the answer may change. Gated by CAN_MASTER, so a
snoop build reads back `desired` honestly and `active` stays 0.

From the host: `mb = 4` in the configuration file (or the boot menu's row),
then Ctrl-Reset. Slot 4 is where Mockingboard software looks first. The key
does both halves: writes the
register, and starts the AY reconstruction and the ALSA output
(`--audio-dev` to pick the device; an unopenable device is reported and the
stats still track whether software is playing).

**Pick an empty slot.** The card claims read cycles by driving the bus where
the motherboard maps a slot; a physical card in that slot would drive too,
and the soft-switch gate cannot know it is there.

## Interrupts take the short route

A real Mockingboard pulls the slot's IRQ' line. This card's CPU is on the
near side of that pin, so the VIA IRQs are OR'd straight into the soft core's
`irq_n` in `master_top` - the same argument as `drv_sync`: logically the same
signal, electrically absent. Physical cards still interrupt through the pin,
which is ANDed in (active low) unchanged. The VIA timers count the CORE's
cycles - one tick per op the core completes, which is one per phi0 cycle
with the core at the bus's pace and one per fast op under acceleration
(`op_dummy`/`fast_tick`, the floppy's arrangement) - so a T1 period is a
period in the core's time, the rate every music player's arithmetic and
every detection routine's instruction count assumes. See
`docs/ACCELERATION.md`.

## What is deliberately not there

- **AY register reads.** The card's VIA port A inputs are tied low (as they
  were in v5_1_3), so reading back PSG state returns zeroes; the host could
  not answer through the CPU's data path anyway. No known player needs it.
- **The SSI-263 speech chip** of a Mockingboard C. Different part, different
  protocol, its own module if ever wanted.
- **Stereo beyond the board's own split.** Chip 0 is the left channel, chip 1
  the right, which is the Mockingboard's wiring; there is no mixdown knob.

## Verifying it

```
sim/run_mockingboard_tb.sh    # card: VIAs behind the real driver, ~2 s
sim/run_reg_map_tb.sh         # card: MB_SLOT's latched contract
```

and in strudelworks-host, `mb_test`: the VIA-to-AY protocol (latch above 15
deselects, functions act only from inactive, DDRB gates the control pins),
the soft-switch gate again from the host's side, and the synthesis itself - a
tone programmed as period 284 must come out of the sample stream within 2% of
the datasheet's `phi0 / (16 * 284)`.
