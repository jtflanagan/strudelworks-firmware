# The boot menu: holding the machine at its reset vector

Status: **✅ works on hardware.** Master build of 2026-08-24 17:05, on a
IIe: Ctrl-Reset lands in the splash, Return boots. The cold boot moved to
Open-Apple on 2026-08-26 (see "A cold boot, the machine's way") and ran on
hardware the same day: with the disk disabled, continue lands at the
`Apple //e` banner and the Applesoft prompt, not back in the program that
was running.

A menu the machine shows before it boots, without the machine running a byte
of code to show it. (The same hold has since grown a second door - a key
that stops a *running* program for a menu of its own, and lets it go where
it was - which is RUNTIME_MENU.md; the mechanism below is shared.) The card stops the soft core at the one moment where
nothing has happened yet, reads the keyboard on its behalf, and the host - which
already receives every bus cycle to rebuild the display - draws the menu on the
HDMI panel and decides what to do. When it has decided, one register write
lets the boot go on exactly as if nothing had happened.

The first cut was the smallest thing that is a menu - a splash and *press
Return*. It has since grown the settings the machine now has features for:
enable or move the **Mockingboard**, enable or move the **hard disk** and pick
the disk it boots from, and continue. The mechanism is unchanged - the hold,
the keyboard reads, the host drawing the screen - and one thing was added that
the first cut deferred: a **second latch point** so a choice made in the menu
reaches the boot it releases into. See "Choices that take effect this boot".

## Where the hold is, and why it is clean

The soft core is reset with the machine (`cpu_rst = card reset || RES′
asserted`, see BUS_MASTER.md). While RES′ is low the core sits at cycle zero of
its reset sequence, held there every clock; it does **not** loop through vector
fetches. When RES′ releases, the seven cycles run exactly once - two dummy
reads, three stack reads, `$FFFC`, `$FFFD` - and the cycle after the vector's
high byte is the opcode fetch **at** the vector. The core's live outputs show
`sync = 1`, `addr = vector`, and it has not consumed a single byte of the
program.

That is the hold point. It is an instruction boundary with every register
defined - the same boundary the core takes interrupts on - and it is recognised
without reference to the microcode: *the core's outputs are a SYNC, and no SYNC
has been put on the bus since the core was reset.* Only the post-reset fetch
satisfies that, because a core that has fetched once has had a SYNC presented.

**The core is not paused; it is simply not advanced.** It changes state only on
`cyc_en`, so `apple_bus_write` withholds `cyc_en` for every cycle it presents
on the hold's behalf, and the core sits at the fetch with its outputs
unchanged. On release the next cycle presents that fetch, the opcode comes out
of the machine's own ROM, and the boot proceeds. The bus timing never changes -
the same taps, the same one-value-per-cycle discipline - only the *source* of
the presented op does, and that is decided once, at `T_PRESENT`, and remembered
for the cycle (`drv_ovr`). A decision that could change mid-cycle would let
`cyc_en` fire for an op the core never issued, and the core would swallow the
keyboard's byte as its opcode.

## What goes on the bus while held

Keyboard reads, so that every keypress appears in the capture stream the host
already parses. The host needs no new receive path: a `$C000` read event with
bit 7 set *is* a key event, and the key is the low seven bits.

**Not a blind alternation of `$C000` and `$C010`.** That was the first idea and
it loses keys. The keyboard encoder sets the strobe asynchronously, so a key
landing in the microsecond between a `$C000` read and the `$C010` that follows
it has its strobe cleared before any `$C000` read sees it - the ASCII is still
there, bit 7 is not, and the host cannot tell it from an old key. With one
`$C010` for every `$C000` that window is one cycle in two: a coin flip per key.

`rtl/boot_hold.sv` therefore does what the ROM's own `RDKEY` does: read `$C000`
continuously, and read `$C010` **once, only after a `$C000` read that came back
with bit 7 set**. No key can be lost, and each press produces exactly one
`$C000` event with bit 7 set - the strobe is cleared a microsecond later and
only a new press sets it again. The `$C010` read's own data is ignored: on a
IIe it carries the any-key-down flag in bit 7, which is not a keypress.

`sim/boot_hold_tb.sv` presses eight keys at eight offsets across the bus cycle,
straddling the sample point on purpose, and requires each to be seen exactly
once and followed by exactly one `$C010`.

## Release

One register write. It takes effect at the end of a data phase, never in the
middle of one, **and only on a read issued after the request arrived**: after
such a `$C000` read that showed no key, or after the `$C010` that cleared the
one it showed.

The qualification was found by the testbench, not by design. The request lands
at an arbitrary point in a cycle whose `$C000` was sampled microseconds
earlier; a key pressed in between is invisible to that read, and a release
that acted on it would leave the strobe set for the ROM to find. A read issued
after the request cannot miss it. A key pressed *after* the request belongs to
the boot, as it would on any machine.

## The card's interface

**`BOOT_HOLD`, `0x8000_0010`** in `rtl/wb_regfile.sv`:

```
[0]      arm       RW   hold the soft core at its reset vector, at the next
                        reset and every one after, until cleared
[8]      held      RO   the core is held now
[16]     release   W1   let a held core go; reads as 0
[31:24]  holds     RO   times the hold has engaged, wrapping
```

`arm` is **not** reset-latched, unlike `CPU_SOURCE` and `MB_SLOT`, and
deliberately: it is the standing intention "stop at the next boot", which is
exactly what a level that persists across resets expresses. A reset is what it
waits for, not what applies it. Arming a running machine holds nothing until
the next reset - checked.

Every write sets `arm` from bit 0, so a release write says whether to stay
armed: `0x0001_0001` releases and stays armed for the next reset,
`0x0001_0000` releases and disarms. The host writes the second on shutdown, so
a host that exits does not leave the next boot waiting for a host that is not
there.

The hold is gated on `CPU_SOURCE.active`: with the native 6502 driving there is
no fetch of ours to stop at, and a hold that waited for one would wait forever.

**`CPU_HOLD`, type `0x17`**, card→host, header only, `free[0]` = held. Sent
on every change of `held`, through the same boundary-respecting slot in
`msg_arb` that a register reply uses - so it never lands inside a `BUS_EVENTS`
payload (checked in `sim/reg_map_tb.sv`). The word carries the level as it is
when it goes out, so a bounce that flips it twice while a notice waits still
ends with the host knowing the truth.

It is only sent while a capture is enabled: the silent-until-asked rule in
PROTOCOL.md. A host that attaches to a hold already in progress reads `held`
from the register instead, which is why it is there as well.

## Reset bounces

RES′ bounces - it is a switch with nothing debouncing it - and the core is reset
by the level. A bounce after the hold engaged resets the core, drops the hold
with it, and the hold re-engages at the next vector fetch. The host sees `held`
go 1, 0, 1 and must treat every 1 as "start the menu again". Nothing on the
card debounces, because that would be guessing at a timing the motherboard
does not promise.

## The host

`swhost --cpu soft --boot-menu [--hdv ...] [--disk-dir DIR]`. At start the
host arms the hold; on every `CPU_HOLD` with `held = 1` it replaces the
machine's picture with the menu -
drawn through the same text renderer, character ROM and NTSC path as the
machine's own screen, so it looks like the machine drew it - and watches the
event stream for a `$C000` read with bit 7 set and `$0D` in the low seven
bits. On Return it writes the release, and the next frame the ROM draws is the
one that replaces the splash.

**The notice takes effect in stream order, as a marker.** The host's ingest
thread sees messages and events in wire order; its decode thread sees only
the event ring, milliseconds behind. A flag flipped by the notice on arrival
would be checked against events from *before* the hold, and a Return pressed
by a program's poll loop just before Ctrl-Reset would dismiss a menu not yet
shown. So the ingest thread pushes the notice into the ring as a **marker
word** - tag `0x0`, where every event carries `0xF` - at the position it fell
among the events, and the decoder flips its held state exactly there. The
residual imprecision is the card's own message framing: the notice waits for
a boundary, so it can trail the first ≤255 held cycles. That is the general
mechanism on the host for anything whose time-of-effect must be a point in
the stream rather than "soon" (`proto::make_marker`, one kind per message).

The splash covers the machine's own picture entirely, on purpose: at the vector
the ROM has not run, so what is on the text page is whatever was there before
the reset, in whatever video mode was last set - on a II+ RESET does not touch
the mode flip-flops - and there is no reason to show it. A monitor plugged
into the Apple itself shows exactly that during the hold; the menu exists only
on HDMI. That is the one thing this first cut gives up.

## The menu, and what it sets

The host draws the menu into a text page of its own and reads keys out of the
same capture stream (strudelworks-host `src/boot_menu.cpp`). The items:

- **Mockingboard** - off, or the slot it answers as.
- **Hard disk** - off, or the slot it answers as.
- **Boot disk** - which image the disk serves as unit 1, scrolled from the
  files in the disk directory (`--disk-dir`), matched case-insensitively
  because the images are a mix of `.hdv` and `.HDV`.
- **Continue boot.**

The two slots may not coincide - the card makes the disk yield, but the menu
does not offer the clash: cycling a slot skips the one the other holds. (The
one exception, 2026-09-06: the VidHD and the Uthernet II may share a slot,
the one holding the ROM page and the other the device-select range; the
menu lets those two rows coincide and nothing else.) Keys
are the arrow keys where the machine has them and `WASD` where it does not
(a ][+ has no up/down arrows), uppercased so caps lock is irrelevant; `Return`
or `Escape` continues the boot from anywhere.

**Selections persist.** The `BootMenu` object outlives the resets, so a
Ctrl-Reset re-enters the hold showing what was set last. They are also written
to a defaults file at boot (`--boot-config`, default `boot_menu.conf`) and
loaded at startup, so they survive a restart of swhost. The disk is stored by
name, not index, so it survives the directory listing changing.

## A cold boot, the machine's way

Continuing from the menu always cold-boots: the machine was reset to enter
it, so it is going to boot fresh regardless, and a cold start is what runs
the slot scan that auto-boots a disk - the card's when one is enabled, a
physical controller when not. The first cut of this had the hold DMA-write
zeros over `$3F3`/`$3F4` before releasing, so the reset handler's
`PWREDUP == SOFTEV+1 EOR $A5` check failed - the card reaching into the
machine's RAM with knowledge of its ROM's private convention. It does not
any more. **The host holds Open-Apple down across the release** through
`BUTTONS` (KEYBOARD.md): the //e's reset handler reads `$C061` after RES′
releases, decides "cold" itself, and everything that follows is what a
person holding Open-Apple-Ctrl-Reset gets. The host writes the button down
before the release and back to hardware 50 ms after it - generous cover for
the handler's reads, which are over within a millisecond or two, and
harmless to what follows, which does not read Open-Apple. The hold itself
is back to being purely keyboard reads until told to go.

This is a //e mechanism. A ][+ has no Open-Apple, so an Autostart ROM
warm-starts as it always did; the DMA route that worked there is in the
history (`boot_hold`'s `S_COLD_A/B`) if it is ever wanted back.

## Choices that take effect this boot

`MB_SLOT` and `HD_SLOT` latch their `active` value at the RES′ *assertion* -
which, by the time the hold engages at the first opcode fetch, is already in
the past. So a choice made in the menu would not reach the boot it is about to
release into. The first cut named the fix and deferred it: *"either the
release path gets its own latch point, or the menu says press Reset."* It now
has the latch point.

`wb_regfile` re-latches `MB_SLOT.active` and `HD_SLOT.active` from `desired` on
the **boot-hold release** as well as on a reset assertion (`boot_relatch`) -
and only the boot hold's: a release from the runtime hold leaves them alone,
for the reason the reset-latched contract exists (RUNTIME_MENU.md). So the
sequence is: the host writes `MB_SLOT`/`HD_SLOT` `desired` during the hold,
then writes the release, and the same write copies `desired` into `active`
before the core is let go. The slot-clash rule applies at both latch points -
the disk yields the Mockingboard's slot at a release too. `CPU_SOURCE`
deliberately does **not** re-latch here: switching the driving CPU mid-hold is
the one changeover this design keeps to a reset. Checked by
`sim/reg_map_tb.sv` case 14.

The host side spans three threads, and the machine being quiescent during a
hold is what makes it simple (strudelworks-host `src/pipeline.cpp`
`drive_apply`). The **decode** thread, which owns the menu and the audio
reconstruction, sets the Mockingboard's slot and writes the defaults file the
moment "continue" is chosen, then posts a request. The **ingest** thread,
which owns the transport, drives the rest over a few polls: it asks the
**disk** thread to open the chosen boot image as unit 1, points the host-side
controller at the new slot, writes `MB_SLOT` and `HD_SLOT`, and writes the
release. A few polls of latency cost nothing against a machine that is parked.

## The scanner is found while the machine is parked

The hold is also when the card finds the video scanner (VBL.md): the host
writes `VBL_CTRL.start` on every `CPU_HOLD` from the boot door, and for the
next sixty milliseconds the cycles the hold would spend on keyboard reads
are the detector's instead - seven soft-switch accesses, 960 writes that
fill the text page with a picture the ROM is about to clear anyway, then
reads of the floating bus until the frame is found. `vbl_lock`'s override
sits above the hold's in `master_top`'s mux, and the hold acts only on
cycles it recognises as its own, so the two interleave the way the disk's
DMA and the hold already do. A key pressed meanwhile waits in the IOU's
latch. The host does not release the hold while the detection is running
(`Pipeline::drive_apply` waits at its register phase). The runtime door
never runs it: a program's memory is not the card's to write.

## What it still does not do, and how it would

- **Draw on the Apple's own screen.** The same hold, plus a host→card queue of
  bus ops presented in place of the keyboard reads - writes to `$0400-$07FF`
  and the mode switches - would put the menu on the machine's monitor too. The
  driver's override input is already the shape that needs; only the source of
  `ovr_addr` changes. Every op sent comes back as a captured event, so the
  capture stream is the acknowledgement and no flow-control message is needed.
- ✅ **Be driven without the Apple's keyboard.** A key the host presses
  through `KBD_INJECT` is what the hold's own `$C000` reads return, so an
  injected Return continues the menu; see KEYBOARD.md. The host's
  `continue` command does the same without a key.
- **Switch the driving CPU.** Handing the bus back to the native 6502 is the
  one changeover kept to a reset, so it is not a menu item; `CPU_SOURCE` does
  not re-latch at a release.
- ✅ **Be reached without a reset.** Control-6 on a running machine holds it
  at its next instruction boundary for a runtime menu, whose *reset* item
  is the way back here: RUNTIME_MENU.md. The floppy items are on both.
- **A mock.** `MockCard` does not model `BOOT_HOLD` or `CPU_HOLD`, so the menu
  cannot be seen without the card. The mock would need to answer the register,
  emit the notice on arm, and turn its event source into keyboard polls - a
  modest change, when it is wanted.

## Verification

- `sim/run_boot_hold_tb.sh` - the real core, the real driver and the hold
  against a bus with a ROM at the vector and a keyboard: unarmed is a wire;
  armed, the fetch cycle becomes a `$C000` read with the core still showing the
  fetch; eight keys at eight offsets each seen once; the any-key-down bit is
  not a key; release lands on the fetch and the program runs; release with a
  key pending clears the strobe first; a RES′ bounce re-engages; arming
  mid-run waits for the reset; disarmed boots straight through.
- `sim/run_reg_map_tb.sh` - the register, the one-pulse release, the
  release-and-disarm write, and the notice never landing inside a message.
- `sim/run_bus_write_tb.sh` and `sim/run_mockingboard_tb.sh` - unchanged
  behaviour with the override idle.
- The hard disk's override now comes *first* in `master_top`'s mux (it used
  to be the hold's), because a runtime hold can have a transfer outstanding;
  the boot hold never does - `hd_card` is reset with the core - so nothing
  here changes. `boot_hold_tb` case 14 covers the interleaving.
