# Mockingboard: the VIA pair on the card, the sound on the host

Status: **✅ proven on hardware (Total Replay, megademo; the Phasor and its
SSI-263 speech chips through mb-audit 2026-09-05, the Phasor-with-SSI263
after-reset stages included).**

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

**Served on the card under acceleration (2026-09-04).**  In the closed
regime (CXXX.md "The on-card slots") the VIA accesses at `$Cn00-$CnFF`
are fast ops the card answers itself, no bus cycle; the VIAs see them
through master_top's peripheral view with a synthetic commit that does
not tick the slow clock (fast_tick does, once).  The host's sound gets
the register writes as fast words (`MbAudio::apply_fast`): the write
alone, no time - the chips' cycles stay the bus words'.

## As a Phasor

Applied Engineering's Phasor is the same two VIAs with a second AY-3-8913 on
each, behind a mode register, and the split carries over unchanged: the card
gets the mode register and the VIA decode it changes; the host gets the
second pair of AYs and the chip selects.  `MB_SLOT` bit 3 (readback bit 11)
makes the card in the slot a Phasor, latched with the slot at RES'; from the
host, `phasor = on` or the boot menu's SOUND CARD row.  Everything below is
AppleWin's Mockingboard.cpp (its PhasorIO, IORead/IOWrite and WriteToORB,
with GH#1192's notes from the real card's GAL), which is the reference.

**The mode register** is set by ANY access, read or write, to the slot's
DEVICE SELECT' range `$C0n0-$C0nF` - `$C0C0-$C0CF` in slot 4: A3 set clears
the mode, then A2-A0 are OR'd in.  So `LDA $C0C5` from a Mockingboard-mode
card gives mode 5, `$C0C2` on top of that mode 7, `$C0C8` mode 0 again.
RES' clears it: a Phasor wakes up as a Mockingboard, which is why every
Mockingboard program runs on one.  The accesses are not gated by INTCXROM
(DEVICE SELECT' never is), the card never claims them (nothing on a Phasor
drives the bus there - they read the floating bus), and they are bus cycles
in every acceleration mode: the Mockingboard's `$C0nX` range is not among
the on-card slot ops (CXXX.md), so the host sees each one in the stream
and follows the mode from it, as it follows the VIA writes.

| mode | name | VIA decode of `$Cnxx` |
|---|---|---|
| 0 | Mockingboard | A7 picks the VIA, as above |
| 5 | Phasor native | A4 selects VIA 0, A7 selects VIA 1 - neither, either or both: a write lands in every selected VIA, a read is the OR of them; `$Cn00-$Cn0F` selects none and is not claimed; `$Cn2x/$Cn4x/$Cn6x` are the speech chips' (below) |
| 7 | Echo+ | VIA 1 at every 16-byte offset of the page |
| 1-4, 6 | undefined | nothing answers |

The VIA timers, the interrupts and the core's clock are the Mockingboard's
in every mode.

**On the host** (strudelworks-host `src/mb_audio.cpp`) the mode changes
three things.  The write decode, as in the table.  The chip selects: in
modes 5 and 7 port B's PB4 (active low) selects the VIA's first AY and PB3
its second, either or both; in mode 0 the first AY alone and the bits are
ignored - a Mockingboard's wiring.  And the AY clock: doubled in native
mode (AppleWin's clock scale factor 2), so the chips tick every 4 phi0
cycles instead of every 8 and every period register means half what it
meant.  In native mode the GAL's cross-effects are modelled too: a LATCH to
the first AY deselects the second, a LATCH to the second selects both and
gives the first the same register, and a WRITE to the first also writes a
selected second; RESET' low resets both of a VIA's AYs whatever the mode or
the selects (GH#1197).  VIA 0's pair is the left channel, VIA 1's the right,
each pair summed at full level - not AppleWin's 2/3, which made a Phasor in
Mockingboard mode a third quieter than the Mockingboard and was heard as
such on 2026-09-05; six voices flat out clip at the rail instead.  A
Mockingboard ticks two chips, a Phasor four - the sound is the decoder's
biggest per-cycle cost, so the extra pair is only paid for when asked.

**Not there.**  The Echo+ disk's TMS5220 detection, which AppleWin also
leaves out.

## The speech chips (2026-09-05)

A Phasor has two sockets for the SSI-263, Silicon Systems' phoneme
synthesiser, and both are populated here.  The split is the Mockingboard's
again.  The card (`rtl/ssi263.sv`, one per socket, behind `mockingboard`)
carries what the bus can see: the registers' effect on D7 and on A/!R, and
above all WHEN a phoneme completes - software times it (Willy Byte's
detection, mb-audit's speech tests, every speech ISR), and a completion
that waited on the host would fail them.  The host (strudelworks-host
`src/ssi263.cpp`) carries the sound: AppleWin's recorded phoneme samples,
played from the same register writes in the stream, by the same engine on
the same cycle count, so the sound and the interrupt agree.

AppleWin's SSI263.cpp is the reference, and the timing is AppleWin's rather
than the datasheet's: AppleWin does not model the chip's duration
arithmetic (the RATE register), a phoneme lasts as long as its recorded
sample, and since the host can play nothing else the card completes when
that sample would run out.  A phoneme is a length in 22050 Hz samples
(AppleWin's table, 62 entries, phoneme 1 playing as 2 and 0 a silent pause
as long as 2), consumed one per output sample at DUR 0, one plus an extra
every fourth at DUR 1, two at DUR 2, four at DUR 3 (always four in frame
mode); then a leadout of a tenth of the length, then it plays again unless
the chip was powered down meanwhile.  Output samples run at 22050 per
1020408 core cycles - MACHINE time, as the VIA timers count it, so a
detection routine that waits N cycles for D7 sees the same answer at any
acceleration.

| the bus | what happens |
|---|---|
| write `$Cn4x` / `$Cn2x` / `$Cn6x` (register A2-A0) | the primary chip / the secondary / both, in Mockingboard and native modes; not Echo+.  A4 and A7 are not looked at, so in Mockingboard mode `$Cn4x` also writes VIA 0, as on the real card |
| read `$Cn2x`/`$Cn4x`/`$Cn6x` with A4 = A7 = 0 | native mode only: D7 (the chip's request flag), the other bits low; claimed.  In Mockingboard mode `$Cn4x` reads VIA 0 |
| write reg 0, 1 or 2; CTL=1 | clears D7 and the request; CTL=0 and regs 4-7 do not |
| CTL high-to-low | the function and interrupt enable from DR1:0 as it stands; the phoneme starts |
| a phoneme completes | D7 set (unless powered down); A/!R asserted if DR1:0 was not 00 at the last CTL high-to-low |
| A/!R in Mockingboard mode | the socket's VIA's CA1 - the primary's to VIA 1, the secondary's to VIA 0 - a negative edge, IFR bit 1 under PCR bit 0 = 0; IER bit 1 makes it the IRQ |
| A/!R in native mode | straight to the 6502's IRQ' (the short route, with the VIAs'); not to CA1 |
| A/!R in Echo+ or an undefined mode | nowhere; the chip plays on |
| RES' | an SSI263AP: power-down, registers at power-on, nothing playing (the P variant that plays through a reset is not modelled) |

The VIAs' CA1 inputs, tied low before, now idle high and follow the chips;
so a mode change into Mockingboard mode with a request already up raises
the flag by itself, which AppleWin's SetCardMode does by hand.  A plain
Mockingboard (`phasor` clear) has no sockets and the chips sit in reset.

The phoneme lengths are generated from AppleWin's SSI263Phonemes.h
(strudelworks-host `tools/gen_ssi263_phonemes.py`, which also writes the
host's sample asset) and baked into both halves; the host's loader checks
the asset against them.

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
default), bit 3 a Phasor in it rather than a Mockingboard; bits 10:8 and 11
what was latched. The same latched-at-RES' contract as CPU_SOURCE and for
the same reason scaled down - slot cards are discovered at boot, so a reset
is when the answer may change. Gated by CAN_MASTER, so a snoop build reads
back `desired` honestly and `active` stays 0.

From the host: `mb = 4` (and `phasor = on` for a Phasor) in the
configuration, or the boot menu's MOCKINGBOARD and SOUND CARD rows, then
Ctrl-Reset. Slot 4 is where Mockingboard software looks first. The host
does both halves: writes the register, and starts the AY reconstruction and
the ALSA output (`audio_dev` picks the device; an unopenable device is
reported and the stats still track whether software is playing).

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

## AY register reads, and the timer flags' tick (2026-09-05)

mb-audit's first runs on the card found two things, both on the card side.

**The AYs read as missing.**  An AY's registers can be read back through
the VIA - port A set to input, port B given the PSG READ function - and
that is how mb-audit (and a real chip's driver) finds a chip: write the
three tone registers, read them back.  The VIAs' port A inputs were tied
low, so every chip read as absent.  The user's call: put the chips there.
`rtl/ay_pair.sv` sits behind each VIA with two YM2149 cores
(`rtl/YM2149.sv`, a2fpga's, BSD 3-clause, by way of aty) whose CHANNEL
outputs are left open - the generators prune away and what is left is the
register file and the bus protocol, the chip exactly as the bus sees it -
and the Phasor's GAL around them, ported from aty's mockingboard.sv (PB4/PB3
selects in native and Echo+ modes, the native-mode cross-effects, RESET' to
both).  Port A floats high when no chip drives it, as AppleWin has it.
Still no sound on the card: the host synthesises it from the same writes.

**The timer flags were a cycle late.**  mb-audit test 6522:F reads IFR
without an interrupt on exactly the (N+2)th cycle after the T1C-H write and
expects the flag; the VIA raised it on the reload tick after the underflow,
a cycle late.  Test 6522:3 pins the counter itself - a read on cycle W+k
after the write sees N-(k-1), the state at the end of the PREVIOUS cycle -
which is what the existing arrangement gives (the byte registered at the
op's present, the tick at its commit), so the tick stays where it was and
only the flag moved: T1's and T2's interrupt flags now set on the tick that
takes the counter from $0000 to $FFFF (`rtl/via6522.v` irq_t1_set,
irq_t2_set).  The bench holds the flag to the cycle: clear on W+N+1, set
on W+N+2.

**...and a same-cycle clear loses to it.**  mb-audit test 6522:14 subtest 2
loads T2 so that its $0000 -> $FFFF tick falls on the very cycle of a write
clearing IFR's T2 bit, and expects the interrupt; the VIA gave the clear
priority and the interrupt was lost (the audit timed out waiting).  AppleWin's
UpdateIFR clears then sets, so the set wins; the VIA does the same now, for
both timers (a T1C-H/T2C-H write on that tick is not a set at all: it loads).
The one-cycle-later case, where the clear does win, is the subtest mb-audit
disabled because real hardware fails it.

**The timer latches survive RES'.**  mb-audit's after-reset test (the one
that asks for a Ctrl-Reset) writes T1L before the reset and expects it back
after; the VIA reset its latches to $FF.  The datasheet: reset clears every
internal register except the T1/T2 counters, the latches and the shift
register.  The T1 and T2 latches now carry a power-on value only, and the
controls (ACR, PCR, DDRs, IER, IFR) clear as before.  With the boot menu
on, a Ctrl-Reset re-enters the hold and continuing forces a cold boot, so
that stage is run with `boot_menu = off`.

## What is deliberately not there

- **A Mockingboard C's SSI-263.**  The speech chips come with the Phasor
  only; the plain Mockingboard here is a Sound II.  Nor the SC-01 (Votrax)
  AppleWin keeps on a Mockingboard's first VIA.
- **Stereo beyond the board's own split.** Chip 0 is the left channel, chip 1
  the right, which is the Mockingboard's wiring (a Phasor's second pair
  follows its VIAs); there is no mixdown knob.

## Verifying it

```
sim/run_mockingboard_tb.sh    # card: VIAs behind the real driver, ~10 s
sim/run_ssi263_tb.sh          # card: one speech chip at the real sample rate, ~2 s
sim/run_reg_map_tb.sh         # card: MB_SLOT's latched contract
```

The card bench's second half is the Phasor: the mode register from reads
and writes of `$C0Cx`, the three decodes, the OR'd read, the unclaimed
offsets, RES' clearing the mode - and the standing invariant over all of it.
Between the two halves: the T1 flag cycle-exact at N+2, and the AY register
read-backs (a Mockingboard's chip, an undriven port, the widths, register
14, RESET'; the Phasor's second chip in native mode).  Then the speech
chips with their sample clock shortened to one per bus cycle: the primary
through VIA 1's CA1 and the secondary through VIA 0's, the repeat, the
disable, D7 readable in native mode with the direct interrupt, the writes
that clear it and the ones that do not, the request carried into
Mockingboard mode and dropped in Echo+, RES'.  `ssi263_tb` has the chip
alone at the real rate: 22050 ticks in 1020408 cycles exactly, a phoneme's
length under each DUR and in frame mode, the leadout and repeat, power-down
mid-phoneme.

and in strudelworks-host, `mb_test`: the VIA-to-AY protocol (latch above 15
deselects, functions act only from inactive, DDRB gates the control pins),
the soft-switch gate again from the host's side, and the synthesis itself - a
tone programmed as period 284 must come out of the sample stream within 2% of
the datasheet's `phi0 / (16 * 284)`; then the Phasor: the mode register, a
Phasor in Mockingboard mode being a Mockingboard, the native decode, the two
AYs per VIA with the GAL's cross-effects, Echo+, and the same tone at twice
the pitch under the doubled clock; then the speech chips: the write decode,
the engine's timing against the card's numbers, and the samples reaching
the mix.

**mb-audit** (`disks/mb-audit-v1.60.po` on the Pi), the reference test
suite for the Mockingboard and its clones, is the hardware proof: it
identifies the card, exercises the VIAs' timers and interrupts, the AYs and
the Phasor's modes, and reports what it found.
