# The floating bus, simulated

Status: **✅ on hardware, 2026-08-29.** Master build of 19:5x (WNS +0.336 ns,
35.5 of 50 tiles) on a IIe, headless from the Pi: locked at the boot menu
and the lock's and the probe's frames of `$C054` reads - 34,060 of them -
compared with **0 mismatches**; then ProDOS BASIC's PEEK loops at the video
switches, one mode at a time from cleared counters, **0 mismatches in every
mode**: text page 1 (3,000 reads), mixed hi-res page 1 (3,000), full-screen
hi-res page 1 (3,000), hi-res page 2 (1,855), mixed hi-res page 2 (2,125),
text page 2 (2,178). The hi-res copy read back byte for byte equal to the
host's mirror. Then **serving**: `fb on`, 3,000 floating reads handed to the
core from the copy, 0 mismatches, no watchdog trip, and BASIC printed `6*7`
as 42. See "What the machine said" below for the one thing the counts
turned up.

A read of an address nothing drives - a video soft switch, the speaker, the
language card's switches - returns the byte the video scanner fetched during
phi0-low, still on the data bus from the scanner's half of the cycle. That is
the **floating bus**, and software has used it to find the beam since 1982
(VBL.md, "Vapor lock"). Today every such read the soft core makes goes to the
real bus and comes back right. A core running faster than the bus
(MEMORY.md, "The accelerated mode") cannot rendezvous with the machine for
those: the byte it needs is the one the scanner *would* fetch at the core's
own cycle, from memory as the core has written it. This is the piece that
produces that byte - and, on the unaccelerated machine, proves it against the
real floating bus on every floating read, every cycle, in every video mode.

## What is where

```
  op_addr/op_wdata ─► apple_mmu ──cl_pa──► fb_sim: side copy ◄── scan_addr(v, h, mode)
  (every write)        (bank 0 only)         2 KB text, 16 KB hi-res      ▲
                                                   │ the byte           vbl_lock's counter,
                                      monitor ◄────┴────► din_sub       apple_mmu's switches
                                   (vs the bus)          (serve)
```

| piece | file | what it holds |
|---|---|---|
| the scanner formula | `rtl/scan_addr.vh` | Sather's, as AppleWin writes it, for every mode; `include`d by the lock and the simulator |
| the simulator | `rtl/fb_sim.sv` | the side copy, the prediction, the monitor, serve, peek |
| the copy's RAMs | `rtl/fd_bank.sv` | the floppy's true-dual-port template, now with an address width |
| the video switches | `rtl/apple_mmu.sv` | TEXT, MIXED and 80COL shadowed beside the memory switches, on `vid_sw` |
| the position | `rtl/vbl_lock.sv` | the counter's line and cycle, exported as `scan_v`/`scan_h` |
| the registers | `rtl/wb_regfile.sv` | `FB_CTRL`, the counters, `FB_PEEK` (PROTOCOL.md) |

## The side copy

Every write that lands in **main memory's** text pages (`$0400-$0BFF`) or
hi-res pages (`$2000-$5FFF`) is copied into two block RAMs - 2 KB and 16 KB,
one RAMB18 and four RAMB36 - on the same clock the cache takes it. Both pages
of both regions, because a double-buffered game flips to page 2 and reads
the floating bus there.

**The tap is the translated address, never the raw one.** `apple_mmu`
classifies every op and gives its physical address in the image, `cl_pa`,
one clock after it is presented; that address is the write *after* every
soft switch that can redirect it has been applied - 80STORE+PAGE2 steering a
page-1 write to the auxiliary bank (and the hi-res page with HIRES), RAMWRT
sending everything else there, a RamWorks bank register choosing which
auxiliary bank. On a IIe that is the whole set: no switch moves a page-1
write to main's page-2 region, so the 16 address bits are unchanged whenever
the write is in main at all, and the image bank in `cl_pa[23:16]` is the
entire decision. The copy keeps bank 0 and nothing else. A `$0400` write
under 80STORE+PAGE2 goes to aux, which the scanner's main-bank fetch never
shows, and stays out; the same write with 80STORE off goes in. Overrides -
a disk DMA, the lock's fill - are ops too and are copied like any other
(MEMORY.md, "Overrides are ops").

**Main memory only, by decision.** The auxiliary bank's byte goes to the
80-column card's own latch and never onto the main data bus; AppleWin's
floating bus is `pMain[scanner address]` (`Memory.cpp`, `ReadFloatingBus`).
VBL.md left open whether a IIe's floating bus ever shows the aux byte; the
monitor below keeps a separate count for 80-column cycles, which is where
the answer will show. An aux copy would be another four and a half tiles on
the same tap if it ever does.

**Unwritten bytes are garbage**, by the image's policy (MEMORY.md): the
count climbs until the program has drawn its screen and then stops.

## The prediction

The scanner's position comes in as a line and a cycle - `vbl_lock`'s
counter today; an accelerated design's virtual counter later, through the
same ports - and the mode from the MMU shadow's switches, and
`rtl/scan_addr.vh` turns them into the address the scanner reads:

```
text addressing   when TEXT, or MIXED on the lines the IOU's HIRES TIME is
                  off: V4 && V2 of the vertical state - lines 160-191 and
                  224-261 on NTSC, NOT 192-223 (AppleWin Video.cpp, UTAIIe
                  5-7 P3); on PAL 160-191, 224-255 and 280-311
hi-res otherwise  when HIRES
page 2            when PAGE2 and not 80STORE: with 80STORE the display is
                  page 1 whatever PAGE2 says, which only steers writes
```

The formula is VBL.md's, generalised: A0-A2 from H0-H2, A3-A6 the sum
`H5H4H3 + V4V3V4V3 + 1101`, A7-A9 from V0-V2; text puts the page in A10/A11,
hi-res puts VA-VC in A10-A12 and the page in A13/A14. The lock uses it in
text mode, page 1, and its verify frame is already this comparison in that
one mode; the simulator uses it in all of them. The host's `scanner.hpp`
carries the same transliteration and its `beam_test` holds it against
AppleWin's tables cycle by cycle; the mixed-mode window is the one place
the host's renderer had a shortcut (`line >= 160`, right on every displayed
line and wrong only in blanking, where it draws nothing) and now carries the
IOU's rule beside it.

**Three clocks from a position to its byte.** The address is registered
once before the RAMs' pins, the RAM reads it every clock, and the byte lands
two clocks later. A bus cycle is ~98 clocks and the counter steps one clock
after the data tick, so at the data phase the byte is long settled and the
last write to the copy - clock ~6 of its own cycle - is ninety clocks old. A
virtual counter has to allow the same three clocks.

**No one-cycle offset.** The counter's origin is *defined* by the floating
bus - the byte the lock found at line 0, cycle 0 is `scan_addr(0, 0)`'s -
and it is the IIe's VBL′ pin that runs a cycle early against it (VBL.md,
"What the machine said"), not the byte. A switch flipped by a read takes
effect at the data phase, after the scanner's fetch of that cycle, so the
flipping cycle itself is predicted in the old mode; the machine's IOU does
the same.

## What floats

On a IIe a read of `$C020-$C05F` or `$C070-$C08F` drives nothing onto the
bus: cassette out, the speaker, the utility strobe, the video switches, the
paddle trigger, the language card. Its side effect is the read's own
switch, which still happens - the bus is still driven with the read, serving
or not. Excluded, and why:

- `$C000-$C01F`: the keyboard latch is in bits 6:0 (and `kbd_inject`
  substitutes `$C00x` anyway);
- `$C060-$C06F`: bit 7 is driven by a button or a cassette input;
- `$C090-$C0FF`: a slot's I/O floats only if the slot is empty, which the
  card cannot know - a mask the host sets from its boot configuration would
  be the way to add them;
- `$C100-$CFFF`: ROM, or a card's.

A read a peripheral on the card claims (`slot_rd_claim`) or the keyboard or
the buttons substitute is theirs and never compared. `$C020` is not
side-effect-free - it toggles the cassette output - though nothing notices
with nothing plugged in; a read of `PAGE2 ? $C055 : $C054` is the genuinely
idempotent probe, and the follow-up below wants it.

## The monitor, and what its numbers mean

Serving or not, every floating read while the counter is locked - the
core's and the overrides' alike, so the VBL probe's frame of `$C054` reads
is a frame of comparisons - has its byte compared with the prediction at the
data phase. Three counts:

- **`FB_MISMATCH`** on ordinary cycles. Noise until the screen is drawn;
  a count that keeps climbing under a settled program is the finding.
- **`FB_OTHER[15:0]`** on cycles whose scanner address is a screen hole
  (`$x78-$x7F` of a 128-byte stride, about one cycle in eight). The copy
  follows the firmware writes that go there like any other, but they are
  the one place the lock's fill never writes, so they are counted apart
  rather than allowed to drown the count above.
- **`FB_OTHER[31:16]`** on 80-column cycles, where the scanner fetches main
  and auxiliary memory in the same cycle and which byte floats is the
  question VBL.md left open. Measured, not assumed.

`FB_LAST` carries the position of the last mismatch - the line and cycle,
the predicted and the bus byte - and `FB_LAST2` the I/O address that was
read, the scanner address the prediction came from, and the mode bits it was
built with, so a wrong cycle can be named and reproduced.

## Serve

`FB_CTRL.serve` substitutes the prediction for the bus's byte in the core's
`din` and in the captured event, through the route the keyboard uses
(`din_sub`; the mux in `master_top.sv` has a fourth input, disjoint from the
other three by the exclusions above). Never on an override - the probe's
reads must stay real - never while unlocked, never on an 80-column cycle
until the count above has spoken. The bus is still driven; the monitor still
compares. A level, like `MEM_CTRL`'s, safe under a running machine. The host
watches it: a mismatch count that moves between two polls taken while
serving turns serve off and says so (`fbtrips=`), because a core being
handed bytes the machine disagrees with is better off with the bus.

This is the accelerated core's byte, proven on the real machine before there
is one.

## The card's interface

Seven registers in `rtl/wb_regfile.sv` (PROTOCOL.md has the table):

```
FB_CTRL      0x8000_0070   [0] serve RW; [8] cnt_clr W1; [16] locked, [17] text,
                           [18] mixed, [19] hires, [20] page2 as displayed,
                           [21] col80, [22] store80 RO
FB_COMPARED  0x8000_0074   floating reads compared
FB_MISMATCH  0x8000_0078   ...that disagreed, on ordinary cycles
FB_LAST      0x8000_007C   {predicted[7:0], bus[7:0], line[8:0], cycle[6:0]}
FB_LAST2     0x8000_0080   {addr[7:0] of $C0xx, scanner address[15:0],
                            mode: hole, col80, store80, page2, hires addressing,
                            text addressing, MIXED, TEXT}
FB_OTHER     0x8000_0084   [15:0] hole mismatches, [31:16] 80-column mismatches
FB_PEEK      0x8000_0088   [14:0] RW an address in the copy ([14] 0: text,
                           [10:0] from $0400; 1: hi-res, [13:0] from $2000);
                           [23:16] RO the byte there
```

The peek reads the copy through the write port's idle clocks - a write is at
most once per bus cycle - so a host can check the copy against its own
mirror of the machine's memory. The host's `swctl fbpeek ADDR [LEN]` does
exactly that, one register round trip per byte, and lists the differences.

## Decisions, and why

**The video switches live in `apple_mmu`.** It already decodes `$C05x` at
the data phase, read or write, with the reset that holds every switch at
the IOU's power-on state while RES′ is low, and MEMORY.md promises the
switches are shadowed there. `sw_state` was not widened - `MEM_STAT[11:0]`
and the host's mirror carry its packing bit for bit - so TEXT, MIXED and
80COL come out on a port of their own.

**Two RAMs, not one.** Text and hi-res are different shapes at different
addresses; two block RAMs with the hi-res bit choosing between them is one
mux, and each page pair is a contiguous index (`{A11, A9:A0}` and `{A14,
A12:A0}`), so nothing subtracts.

**The screen holes are counted, not excluded.** The copy is right about
them whenever the firmware wrote them through the bus, and a program that
parks state there and reads the floating bus during blanking would see the
difference; but a mismatch there is a different finding from one on a
displayed byte, and deserves its own number.

**The floppy's RAM template, parameterised, rather than a third copy.** The
two-process true-dual-port shape is what Vivado infers a TDP block RAM from
and what `sim/lint.sh` already knows to lint with `-Wno-MULTIDRIVEN`.

## What proves it

| | what it settles |
|---|---|
| `sim/run_fb_sim_tb.sh` | the real reader, driver, core, hold, lock and MMU shadow around `fb_sim`, against an Apple whose scanner is Sather's counters and whose floating bus is that scanner's byte in **every** mode, with the IIe's write steering: nothing compared before the lock; both text and both hi-res pages written through the bus and read back byte for byte through the peek; a frame of floating reads in text and hi-res on both pages, mixed hi-res on both, and page 2 under 80STORE, on NTSC and PAL, every cycle compared and none wrong; a byte changed behind the copy counted exactly as often as the scanner fetches it - an ordinary byte in `FB_MISMATCH`, a hole in `FB_OTHER`'s low half, anything in 80 columns in its high half, nowhere else; writes steered to aux by 80STORE+PAGE2, +HIRES, RAMWRT and a RamWorks bank never entering the copy while the same writes to main do; serving: the core's reads substituted, the events carrying the byte, the bus still the machine's - shown with the machine's floating bus dead, where the core still sees the picture and the monitor counts every read; nothing substituted on the probe's overrides or in 80 columns; the counters clearing |
| `sim/run_vbl_lock_tb.sh` | the lock unchanged with the shared formula: the same 25 checks |
| `sim/run_reg_map_tb.sh` | the seven registers end to end from a REG_WRITE: the level, the pulse, the readback, the peek's address and byte |
| `sim/lint.sh` | every module, `fb_sim` included |
| the host's `tools/fb_test.sh` | on the **real machine**: the lock at the boot menu, the probe's frame compared with 0 mismatches, text page 2 filled through the bus, then one 3,000-PEEK loop per mode from cleared counters - text and hi-res on both pages, mixed on both - with 0 mismatches each, the copy against the host's mirror through `fbpeek`, then serving with BASIC still running and the count flat. One mode per loop, and nothing on the control socket while the machine is busy: see the script's header |

## Numbers

In the master build of 2026-08-29: **+434 LUTs (9060 of 20800, 44 %),
+4.5 block RAM tiles (35.5 of 50: 31 RAMB36, 9 RAMB18)** - the hi-res copy
four RAMB36, the text copy one RAMB18 - setup WNS **+0.336 ns** (the worst
path is still the DDR3 controller's reset fanout), hold **+0.058 ns**.

## What the machine said

The first run on the machine counted thousands of mismatches in the page-2
modes and none in the page-1 modes, and `FB_LAST` named every one: the
scanner on a text line of a mixed frame, or in text page 2, reading
`$08xx-$0Bxx` - Applesoft's program and variable space - where the copy
predicted `00` and the RAM held whatever ProDOS had left there. That is the
unwritten-copy policy doing exactly what MEMORY.md says it does: the copy
knows only the bytes written since the card was loaded, the ROM's `HOME`
had rewritten text page 1 after the load and nothing had rewritten page 2.
The mixed text window is 70 of 262 lines, and 26 % of the reads mismatched.
A monitor fill of `$0800-$0BFF` through the bus settled it: every page-2
mode then compared clean. The lesson for the accelerated core is the one
the image already carries - a program that reads the floating bus over
memory it never wrote is reading garbage on the real machine too - and
the lesson for the monitor is that its count is only meaningful once the
screen it is reading has been written since the load.

`FB_LAST` first latched hole mismatches too, and showed a screen hole every
time something interesting had happened; it now describes the last
ordinary mismatch only, which is what found the above in one read.

## Not here, deliberately

- **The accelerated core**, and its virtual scanner counter: this module
  takes the position on ports for that reason.
- **Aux memory and the 80-column byte.** Counted, not modelled; see above.
- **`$C090-$C0FF`.** A host-set mask of empty slots, when something wants it.
- **The ][+'s blanking.** It adds `$1000` in text mode during horizontal
  blanking; the card serves a IIe (`scanner.hpp` says the same).
- **A runtime probe.** The VBL probe runs from the boot hold only; a probe
  from the runtime hold of `PAGE2 ? $C055 : $C054` would be side-effect
  free and would verify a running game's mode on every cycle of a frame.
  The monitor on the game's own reads covers the same ground meanwhile.
