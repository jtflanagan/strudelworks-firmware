# The runtime menu: holding a running machine, and letting it go

Status: **✅ on hardware, 2026-08-28** - the scripted half. Master build
of 13:43 (WNS 0.827 ns) on a IIe, `tools/menu_test.sh` in strudelworks-host:
the register's knock opens the menu at the Applesoft prompt and inside a
running `FOR` loop, resume puts the program back (the prompt answers, the
loop finishes and prints), injected Escape and Return leave, the floppy
item scrolls and its choice is saved, and RESET from the menu lands in the
boot menu - 73 keys taken, none dropped, `menus=6 resumes=5 mresets=1`.
Then the real key, by hand, the same afternoon: Control-6 at the Apple
opened the menu with nothing reaching the prompt, Escape and a second
Control-6 each resumed, and the reset item took the boot menu - the card
counted `menus=4 resumes=3 mresets=1`, `touched=0`. **Every path is on
hardware.** That run still had the scan (below, "No scan, by decision");
the build without it (14:03, WNS 0.696 ns) ran the scripted half again the
same way - PASS, same tally - and is the one that stays. Each property below has a testbench case behind it too (see
"Verification").

The boot menu (BOOT_MENU.md) stops the soft core at the one moment where
nothing has happened yet. This is the same hold with a second door: a key
combination the machine never sees stops a *running* program at its next
instruction boundary, the host draws a menu with what a running machine can
sensibly change - the floppy drives, to begin with - and one of two items
leaves. **Resume** puts the program back exactly where it was, minus the key
that opened the menu; **reset** pulses RES′ from the held state, so the boot
menu takes over at the vector. No reboot to get in; no reboot to get out
unless that is what was asked for.

The key is **Control-6** - `$1E` on a IIe - which another project already
uses for the same purpose, and which nothing else is likely to. It is a
register setting, not a constant.

## Where the hold is

The boot hold recognises the post-reset opcode fetch as "the core's outputs
show a SYNC and no SYNC has been put on the bus since reset". The runtime
hold takes *any* SYNC, once asked: an opcode fetch is an instruction boundary
with every register defined - the same boundary the core takes interrupts
on - and the core's live outputs show it a cycle before it goes on the bus.
The cycle that would have presented the fetch presents the hold's first read
instead; `cyc_en` is withheld; the core sits with the fetch on its outputs.
On release the next cycle presents that fetch, the opcode comes out of the
machine's own memory, and the program continues. The testbench checks the
resumed loop's fetches land six and three cycles apart, as `INC`/`JMP` do:
no instruction lost, none doubled.

The program's state is untouched because the program never ran: its
registers, its stack, the soft switches, the screen, the Mockingboard's
timers (which keep running; an interrupt they raise is taken at the boundary
on resume, as it would be after a long DMA). What the program *does* see is
time passing on anything outside the core - a real-time clock card, the
paddle timers - which is what a person pausing a machine expects.

## The key the machine never sees

`rtl/kbd_inject.sv` already owns the byte the core reads at `$C000` (the
substitution in KEYBOARD.md: the core's `din` and the captured event, never
the pins). It now knows one real key is the card's. A `$C00x` read that would
have returned the hotkey - a real key, bit 7 set, no injected key ahead of it,
the lock off, the machine not held - returns `{0, last_read}` instead, which
is the IOU's answer to "no key", and pulses `hotkey_hit` for the hold. The
program never sees it, the capture never records it, and `last_read` does
not learn it: it was never handed over.

Its strobe stays set in the IOU, because only a bus access to `$C010` clears
that, and the hold makes one first thing: **a hold the hotkey opened presents
one `$C010` before its first `$C000` read.** Without it the hold's first read
would return the hotkey as the menu's first key, and a host that treats that
key as "leave" would leave at once. A hold the register opened has no such
key and starts reading straight away.

Three cases the testbench pins down:

- **An injected key ahead of it wins.** The program gets the injected key;
  the `$C010` that takes it clears the motherboard's strobe too, and the
  hotkey is gone with it - what that access means. The hotkey is found by
  the next read after an injected key is cleared, not before.
- **Under the lock it is not looked for.** The lock is for a scripted run,
  where a real key is nobody's; the hotkey counts as a `touched` like any
  other, and the host has the register to knock with.
- **While held it passes through** like any key: the reads are the card's
  own, for the host, and the host may want the same key to mean "leave".

## No scan, by decision

A program that never reads the keyboard can never hand `kbd_inject` the
hotkey, and the first cut had the card read `$C000` on its own account every
millisecond to find it anyway - one bus cycle stolen at an opcode fetch, the
way a one-byte DMA would. That is **gone**. A stolen cycle drifts the core
against the video beam, and a real floppy's critical loops are counted to
the cycle; the machine's timing is not the menu's to spend. Until there is
something considerably more sophisticated that understands the Apple's
realtime obligations, a program that does not read the keyboard cannot be
paused by the key. What is left for it is the register's knock (`menu` on
the socket) or a reset. `boot_hold_tb` case 12 and `kbd_inject_tb` case 26
check the key waits unread and the core loses not one cycle.

## The hard disk comes first

`rtl/hd_card.sv` moves blocks by override cycles of its own, and a runtime
hold can engage with a transfer outstanding - or one can arrive while the
machine is held, when the host answers a command that was in flight. The
driver takes the disk's op over the hold's when both offer one
(`master_top`'s mux, the disk first), and the hold acts only on cycles it
recognises as its own: the presented op is an override read of the address
it was offering - the idiom `hd_card` uses for the same question. A cycle the
disk took neither reads a key nor releases the hold; the core does not move
for either; the two interleave, and a release asked for mid-transfer lands on
the hold's own read after it. A knock while the disk is moving waits for the
transfer to end.

This is a change to the boot hold's arbitration too - it used to come first -
and costs it nothing: `hd_card` is reset with the core, so there is no
transfer to yield to at the vector.

## Reset while held

RES′ resets the core and the hold with it, as it always did. A bounce drops a
runtime hold and the *boot* hold re-engages at the vector, `runtime` clear:
the host sees `held` go 1, 0, 1 and the second 1 is the boot menu. That is
also how the runtime menu's **reset** item leaves: the host pulses RES′ with
the machine held, the hold drops, and the boot hold - if armed - takes over.
A knock while the boot menu is showing is nothing.

## The card's interface

**`MENU_HOLD`, `0x8000_002C`** in `rtl/wb_regfile.sv`:

```
[0]      enable    RW   watch for the hotkey on the program's $C000 reads
[7:1]    hotkey    RW   the key that opens the menu; $1E (Ctrl-6 on a IIe)
                        at the card's reset
[8]      trigger   W1   open the menu now, as the hotkey would; reads as 0
[31:24]  menus     RO   times the runtime door has opened, wrapping
```

`enable` is a level like `BOOT_HOLD.arm`, and the same reasoning applies:
the host's standing wish, unchanged by RES′, cleared by the card's own reset
(the watchdog's included) so a host that has gone leaves no door open that
nobody would answer. `trigger` is the host's own knock - the control socket's
`menu`, a scripted test, a run with the Apple's keyboard locked.

**`BOOT_HOLD`** gains one bit and the release serves both doors:

```
[8]      held      RO   the core is held now
[9]      runtime   RO   ...by the runtime door, not the boot's
[16]     release   W1   let a held core go, whichever door
```

A release from the runtime hold **re-latches nothing**: `MB_SLOT` and
`HD_SLOT` copy `desired` into `active` on a boot release so the menu's choices
reach the boot it lets go; a program resumed mid-run has already decided
about its slots, and a card that moved under it would be exactly the
changeover the reset-latched contract exists to prevent. `reg_map_tb` case 20
checks the runtime release leaves the slots alone and the boot release after
it does not.

**`CPU_HOLD`, type `0x17`** carries `free[1] = runtime` beside `free[0] =
held`. Both move on the same edge in `boot_hold`, so the word never says one
without the other; it is still a level, sent on every edge of `held`, gated
on a capture being enabled. A host attaching to a hold already in progress
reads `BOOT_HOLD` for both bits.

## The host

`strudelworks-host` `src/runtime_menu.cpp`, in the same shape as the boot
menu: a text page drawn through the machine's own renderer, keys out of the
capture stream, a marker in the event ring for the hold's time-of-effect. The
`CPU_HOLD` marker now carries the door; the decoder shows the boot menu or
the runtime menu accordingly. The items:

- **Floppy 1 / Floppy 2** - insert, change or remove an image in either
  virtual drive, scrolled from the `.dsk`/`.do`/`.po`/`.nib`/`.woz` files in
  the disk directory. The card has no floppy controller yet; the selection
  is kept, saved and reported, ready for one. The same two items are on the
  boot menu, so a disk can be inserted before the boot or during the run.
- **Resume** - release; the program goes on where it was.
- **Reset** - pulse RES′; the boot menu, if armed, or a plain reboot.

Keys as the boot menu: arrows or `WASD`, `Return` chooses, `Escape` resumes
from anywhere - and so does **Control-6** pressed again, which the card
passes through while held.

The host writes `MENU_HOLD` at start (`--menu-key`, default `ctrl-6`;
`--menu-key none` shuts the door) and clears it at exit, releasing a hold
in progress first. The control socket's `menu`
knocks through the register, `resume` chooses resume; `status` says which
menu is showing.

## What it does not do, and how it would

- **Draw on the Apple's own screen.** Same answer as BOOT_MENU.md: the
  override input is the shape a host→card op queue would take.
- **A ][+ hotkey.** A ][+ keyboard produces `$36` for Control-6; the
  register takes any 7-bit code, so `--menu-key` can name another.
- **Hold a core parked in `WAI`.** The core implements `WAI` (it parks on
  its own microcode slot until an interrupt arrives, `cpu65c02.sv`), and a
  parked core presents no fetch, so the door stays knocked-on until the
  interrupt wakes it - the Mockingboard's timer, on a machine that has one.
  `STP` is not on the base part. A program that waits this way is rare; if
  it matters, the hold wants a way to engage on a core that is not fetching.
- **Hold with the native 6502 driving.** There is no fetch of ours to stop
  at; the door is gated on `CPU_SOURCE.active` like the boot hold.
- **Actually change a floppy.** The item is the seam; the controller is the
  next thing.
- **Pause a program that never reads the keyboard.** See "No scan": not
  until the card understands the machine's realtime obligations.

## Verification

- `sim/run_boot_hold_tb.sh` cases 9-14: the hotkey holds a running loop at
  its next fetch with a `$C010` first; the core does not move and the loop
  does not count; keys reach the host; released, the fetch is where the
  core was and `INC`/`JMP` continue on their cycle counts; the register's
  knock starts with `$C000`; a key nobody reads pauses nothing and costs no
  cycle; a RES′ hands over to the boot hold; the disk's override goes out over the
  hold, the release waits for the hold's own read after it, and a knock
  during a transfer waits.
- `sim/run_kbd_inject_tb.sh` cases 22-27: eaten on the program's read - no
  read ever returns it, the capture agrees with `din`, `last_read` and the
  counts are untouched, the program resumes and takes the next key; an
  ordinary key with the door shut; a touch under the lock; an injected key
  ahead of it wins; a program that never reads is never paused; passed
  through while held.
- `sim/run_reg_map_tb.sh` case 20: the register's levels, the one-pulse
  trigger, `runtime` in `BOOT_HOLD`, `menus`, and no re-latch on a runtime
  release; case 11's notice carries both bits.

## Bring-up

1. `build/build.sh --master`, load the bitstream to SRAM.
2. `swhost --real --cpu soft --boot-menu --disk-dir disks`, boot the ProDOS
   master copy through the menu (the `kbd_test.sh` pattern).
3. At the Applesoft prompt: Control-6 at the Apple. Expect the runtime
   menu on HDMI, `status` saying `menu=runtime`, and nothing typed at the
   prompt. Arrows through the items; **resume**; the prompt is as it was
   and the next key typed lands.
4. `tools/pi.sh ctl menu` from the desktop: the same menu, no key. `resume`
   likewise.
5. Type `10 FOR I=1 TO 1E9: NEXT` and `RUN`, then Control-6: Applesoft's
   Ctrl-C check reads `$C000` every statement, so the program's own read
   hands the key over. Resume; the loop is still running (Ctrl-C stops it).
6. **Reset** from the menu: the boot menu.
7. `lock on`, Control-6 at the Apple: nothing but `touched=1`; `menu` from
   the socket still works.
