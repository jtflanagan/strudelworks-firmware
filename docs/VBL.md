# VBL: finding the beam, and never losing it again

Status: **✅ on hardware, 2026-08-28.** Master build of 15:24 (WNS 0.975 ns)
on a IIe, headless from the Pi: at the first boot menu the card locked -
NTSC, **0 mismatches** over the 15,920 compared cycles of the verify frame,
slip 0 - and the marks then ran through the boot and the `Apple //e` banner
at exactly 17,030 events apart, 4,129 of them without one out of place. A
second Ctrl-Reset re-locked with slip 0. And the probe of `$C019` gave the
one measurement the lock could not make for itself; see "What the machine
said" below.

The card needs to know where the Apple's video scanner is - which cycle of
which line - and it needs to know it to the cycle, for as long as the machine
runs. The host wants it to frame its picture on the machine's own frames
instead of on an arbitrary count (strudelworks-host `pipeline.hpp` has been
saying "the phase is arbitrary for now" since the display first worked); a
runtime interrupt, a VBL for a machine that has none, a beam-racing
diagnostic - everything that wants the beam wants the same number.

**Not from the VBL soft switch.** The //e has one at `$C019`; the ][ and ][+
have nothing, and this card is meant to serve them; the //c's is a different
polarity in a different place, and the IIgs's is a register. A method that
depends on the machine's own idea of VBL is a method that has to be rewritten
per machine. The floating bus, by contrast, has behaved the same way on
every Apple II since 1977, and is what software has used to find the beam on
all of them.

## Vapor lock

Sather's *Understanding the Apple II* (chapter 5) describes it and Bob
Bishop's *Have an Apple Split* (1982) used it first: while phi0 is low the
video scanner reads a byte of display memory, and a CPU read of an address
nothing drives - a video soft switch, an empty slot's I/O page - returns
that byte, still on the data bus from the scanner's half of the cycle. Put
a known picture in memory, read the floating bus, and the byte says where
the beam is. Software does this with a 6502 that can read once every seven
cycles or so, and has to be clever: a screen full of one byte with one
different one somewhere, and a search that narrows in over several frames.

**This card reads the floating bus on every cycle.** The soft core is the
machine's CPU (BUS_MASTER.md) and an override cycle can be any read at all
(BOOT_MENU.md, HARDDISK.md), so the card can present a read of `$C054` on
17,030 consecutive cycles and get the scanner's whole frame back as a byte
stream, in order, with nothing missing. There is no narrowing in. The frame
is found on the first pass through it, and the second pass says whether it
is an NTSC frame or a PAL one, and after that a counter that ticks once per
phi0 cycle knows where the beam is until the card is reset.

## When it runs, and why then

**During the boot hold, automatically, and only then.** The method needs a
known picture in the text page and known soft switches, which means writing
a kilobyte of the machine's memory and touching seven switches - things a
card may do to a machine that is parked at its reset vector about to cold
boot, whose ROM is about to clear that same page, and may not do to a
running program. The runtime hold (RUNTIME_MENU.md) is a running program
stopped mid-thought; its memory is not the card's to write, so the card
refuses a `start` from that door. And it steals no cycle from anything,
ever: the counter is a passive listener once it is set.

The lock survives a reset. RES′ resets the core, the hold and the disk, but
the scanner is not on the RES′ line - it has been free-running since power
on - and the counter is clocked by phi0 edges alone, so it follows the
scanner through any number of Ctrl-Resets. The host runs the detection at
every boot menu anyway, because it costs 60 ms of a parked machine and a
second detection that agrees with the first is worth knowing about: the
register reports the **slip**, the difference between where the old counter
was and where the new lock put it. Zero is the expected answer.

## The picture, and what the scanner shows of it

Text mode, 40 columns, page 1, main memory: `TEXT` on, `MIXED` off, `PAGE2`
off, `HIRES` off, `80STORE` off, `80COL` off, `RAMWRT` off. The first five
exist on every Apple II; the last three are //e writes to `$C00x`, which a
][+ decodes as nothing at all. Then row *r* of the 24 text rows is filled
with the byte `$C1 + r` - `A` on row 0 to `X` on row 23, so a monitor on the
Apple shows what the card did, in letters - and the eight **screen holes**
at `$x78-$x7F` in each 128-byte stride are left alone. Peripheral cards keep
state in those and the detector never depends on their contents.

What the scanner reads in that mode, per Sather and AppleWin's
`VideoGetScannerAddress` - the project's reference, and where this module's
formula is checked against. A displayed line `L` shows text row `L/8`; call
`s = (L/8) mod 8` its stride (which 128-byte slice of the page the row is
in) and `g = L/64` its group (which 40-byte third of the slice):

```
lines 0-63     HBL    row 16+s, columns 24-39 (column 24 twice), then the
                      8 hole bytes of stride s              25 cycles
lines 64-127   HBL    row s, columns 16-39 (16 twice)       25 cycles
lines 128-191  HBL    row 8+s, columns 16-39 (16 twice)     25 cycles
any of them    shown  the row's 40 bytes                    40 cycles
VBL lines      HBL    row 16+s, columns 16-39 (16 twice)    25 cycles
               shown  the 8 hole bytes of stride s, then
                      row s, columns 0-31                   40 cycles
```

where a VBL line's stride is `((L-192)/8) mod 8` for the first 64 of them,
and the lines the vertical preset adds after those - six on NTSC, fifty-six
on PAL - repeat stride 7 (NTSC) or strides 1 to 7 (PAL). The scanner's
address is a function of a horizontal counter and a vertical one, and the
low four bits of the "column" are a *sum* of bits from both - which is why
the horizontal blanking cycles read from another row's tail, and why the
lines of vertical blanking, where the vertical counter has both of its top
bits set as no displayed line does, read the holes and then a row's first
32 bytes. `rtl/vbl_lock.sv` carries the formula in `scan_addr`, and
`sim/vbl_lock_tb.sv` carries an *independent* one: the counters themselves,
as Sather draws them, a 7-bit H that presets from `$00` to `$40` and a 9-bit
V that presets from `$1FF` to `$FA` (NTSC) or `$C8` (PAL), with the address
bits picked off them. The two derivations agreeing on every non-hole cycle
of a frame, on both standards, is what the testbench checks.

## Finding the origin

The origin is **line 0, cycle 0**: the first horizontal-blanking cycle of
the first displayed line, the cycle where H is `$00` and V is `$100`. What
the floating bus shows around it is distinctive:

```
cycle    -32 .. -1     32 × 'H'    row 7's first 32 bytes: the last VBL line's shown part
           0 .. 16     17 × 'Q'    row 16, columns 24-39, column 24 twice: line 0's HBL
          17 .. 24      8 holes
          25 .. 64     40 × 'A'    row 0: line 0 shown
          65 .. 81     17 × 'Q'    line 1's HBL
          82 .. 89      8 holes
          90 .. 129    40 × 'A'    row 0 again: line 1 shown
```

The detector's first pass watches for **32 `H`s followed by a `Q`**, and on
seeing one starts the scanner model at (0, 0) and checks the next 129 bytes
against it, holes excepted. That is the whole acquisition. The pre-filter
is in fact unique in the frame: row 7's bytes are shown in a run of 32 only
on the eight VBL lines of stride 7 and the lines the preset repeats after
them, and every one of those is followed by row 23's blanking bytes - except
the last, which is followed by line 0. But the 130-cycle check is kept, and
the testbench's holes are chosen to justify it: it is what makes the
contents of the holes provably irrelevant, because the model never asks
about a hole, and it is what will say so, in the mismatch count, if a
machine's blanking differs from the model's in some way the pre-filter
happens not to see.

**The second pass measures the period.** The model keeps counting from the
origin. At cycle 17,030 it checks two lines against lines 0 and 1 again; if
they match, the frame is 262 lines and the machine is NTSC. If not, it waits
for cycle 20,280 and checks there; a match is PAL. Neither is an error, and
the detector says which. Then a **third pass** runs one whole frame against
the model with the period known, counting mismatches on every non-hole
cycle - 15,920 of them on NTSC - and reports the count. The lock does not
depend on it; it is the number that says how well the model describes this
particular machine, and a ][+ that differs from a //e in some blanking
cycle would show up there before it showed up anywhere else.

Sixty milliseconds, all told, with the machine parked and the keyboard
reads suspended for the duration. A key pressed meanwhile waits in the
IOU's latch; the hold's reads find it afterwards.

## The counter

Three numbers, advanced on every phi0 cycle whether the card is mastering
or not: the line (0..261 or 0..311), the cycle within it (0..64), and the
cycle within the frame (0..17,029 or 0..20,279). They are set once, at the
end of the second pass, and thereafter only count. The scanner's own
counters are not in the RES′ domain and neither is this one.

A cycle is a phi0 cycle. The Apple stretches one cycle in 65 by two 14 MHz
periods to keep its colour burst in phase; it is still one phi0 cycle, and
the reader's taps count from phi0 edges, so nothing here notices.

## Telling the host, to the cycle

The host counts events as cycles (one event per phi0 cycle, never a gap,
that is the whole contract of the capture), so what it needs is one thing:
which event was line 0, cycle 0. A register cannot say that - the host has
no way to relate "now" on the card to a position in a stream it reads
milliseconds later - and a notice through the message bus lands at the next
message boundary, which can be 255 events after the fact (BOOT_MENU.md's
CPU_HOLD lives with that; this cannot). Two things say it.

### The bit

**Bit 19 of every event word is the counter's vertical blanking level**: 1
on lines 192 and up, 0 on the 192 displayed lines, 0 until the lock is set.
`rtl/apple_bus_read.sv` samples `vbl_lock`'s `vbl_level` with the data on
the clock it registers the event - the counter steps one clock later, on
`data_tick`, so on that clock it still describes the cycle being recorded.
The first event with the bit set is line 192, cycle 0; the first with it
clear again is line 0, cycle 0; and the 4,550 (NTSC) or 7,800 (PAL) events
between the two say which frame it is. A host attaching mid-stream is
placed at the next edge with no notice at all, a trace file carries the
beam's position in every word, and the host draws the picture cycle by
cycle from the bus alone (strudelworks-host `beam_render.hpp`).

The bit is where the v5 wire format kept the IIgs's M2B0 pin, which is
never high on any machine this card serves (DERISK.md: 33.5 M cycles, not
one) and which nothing ever read; the pin is still synchronised and no
longer recorded. **It is not gated by `notify`**: it is a level in a word
the host already asked for, not a message, and the silent-until-asked rule
is about messages. A watching build (`snoop_top`) has no lock and ties it
low, so its bit 19 reads 0 exactly as m2b0 always did.

**Defined as AppleWin defines VBL′.** `NTSC_GetVblBar` is `vert < 192` on
the same count that generates the scanner address, and this counter is that
count (the origin is the floating bus's), so the bit is `v >= 192` with no
correction. The IIe's own VBL′ pin is one cycle ahead of both - "What the
machine said", below - and a feature that wants the pin's timing subtracts
one; the bit follows the model.

### The mark

So the capture is cut. `rtl/bus_event_capture.sv` takes a **mark** alongside
each event; the marked event's index is remembered, and when the framer
reaches it the BUS_EVENTS message in progress ends *before* it, a one-word
**VBL_MARK** notice (type `0x1D`) goes out, and the next BUS_EVENTS message
begins with the marked event. The notice is therefore exactly where the
origin is, and the host's marker mechanism - the ingest thread pushes it
into the event ring at its wire position - puts it in front of the decoder
between the last event of one frame and the first of the next. It costs one
extra header per frame, eight bytes in seventeen thousand.

`free[0]` of the notice says PAL, `free[15:8]` is a frame count, so a host
can see a missed one. The mark is raised only while the host has asked
(`notify` in VBL_CTRL): the silent-until-asked rule (PROTOCOL.md). A host
that has not asked sees a stream identical to today's.

**What the host does with both.** Its decoder walks the scanner with the
events - each cycle's byte fetched through the switches as they stood on
that cycle and drawn where the beam was - and the bit's edges and the marks
*place* the walk; a placement that finds it elsewhere is a slip, counted.
The frame is handed on when the beam enters vertical blanking, not at the
origin: a program that draws during VBL and spills into the displayed lines
is caught mid-draw by a snapshot at line 0, and caught finished by one at
line 192; a program that finishes inside VBL looks the same from either.
The period comes from the bit (the length of the blanking) and from the
marker's `free[0]`, so a PAL machine frames at 20,280 without being told.

## The card's interface

Three registers in `rtl/wb_regfile.sv`:

**`VBL_CTRL`, `0x8000_0030`**

```
[0]      start      W1   run the detection: needs the boot hold; reads as 0
[1]      probe      W1   read probe_addr on every cycle for one frame: needs
                         the lock and the boot hold; reads as 0
[2]      notify     RW   mark the origin in the capture stream (VBL_MARK)
[7:4]    state      RO   0 idle, 1 switches, 2 fill, 3 acquire, 4 period,
                         5 verify, 7 probe
[8]      locked     RO   the counter is set
[9]      pal        RO   312 lines, not 262
[10]     busy       RO   a detection or a probe is running
[15:12]  err        RO   the last run's result: 0 ok, 1 refused (not held
                         at the reset vector, or not mastering), 2 no
                         signal (no origin found in two frames), 3 no
                         period (neither 17,030 nor 20,280), 4 aborted (the
                         hold dropped mid-run), 5 probe refused (not locked)
[31:16]  probe_addr RW   the address `probe` reads; $C019 at reset
```

**`VBL_STAT`, `0x8000_0034`**, read-only: `[15:0]` mismatches in the last
verify pass, `[31:16]` the slip, signed - the old counter minus the new
lock, 0 on a first lock and expected to stay 0.

**`VBL_POS`, `0x8000_0038`**, read-only: `[14:0]` the cycle within the
frame now, `[23:16]` frames counted since the lock, `[31:24]` locks, both
wrapping. A live position is racy by nature; it is there to show the
counter moving.

**`VBL_MARK`, type `0x1D`**, card→host, header only, `free[0]` PAL,
`free[15:8]` the frame count. Emitted by the capture between the last event
of one frame and the first of the next - see above - and only while
`notify` is set and a capture is enabled.

### The probe

`probe` is a floating-bus dumper with a known phase: for one period the
card reads `probe_addr` on every cycle, and with `notify` on the host sees
every byte in the capture stream with a VBL_MARK somewhere in the run, so
each read has a line and a cycle. The address that makes it worth having is
`$C019` on a //e: bit 7 is the machine's own VBL′, and where it falls and
rises relative to the card's origin is the one measurement that checks the
model against a signal the card did not derive from it. `$C054` dumps the
raw scanner sequence for the host to compare with its own copy of the
formula. Neither is used by the lock; both are how it gets believed.

## What the machine said

The `$C019` probe on the IIe, one frame of reads placed by the marks:
**VBL′ is low on 4,550 cycles - seventy lines exactly - from line 191,
cycle 64 through line 261, cycle 63.** That is one cycle *before* the
card's origin at each end. AppleWin's model has the two coincide (its
`VideoGetVblBar` and `VideoGetScannerAddress` take the same cycle count),
so this is a fact about the hardware the emulator does not carry: the
byte on the floating bus during a cycle belongs to the scanner state one
cycle behind the state that the IOU's VBL′ reports during the same
cycle - or, put the other way, the counters step in the middle of the
cycle, after the address was used and before the switch is read.

The origin stays where the floating bus puts it. That is the observable
this method rests on and the one every Apple II shares; VBL′ is a IIe
reading, kept here as a calibration: **the IIe's VBL′ = card lines 192-261,
one cycle early.** A feature that wants to reproduce the IIe's switch to
the cycle subtracts one.

## What is not here

- **Nothing on the ][+ has been tried.** The formula is the //e's and the
  ][+'s text-mode addressing is the same by every account; the hi-res
  blanking quirk the ][+ has is in a mode this never uses. The verify count
  is where a difference would show.
- **The 80-column firmware's screen holes.** Untouched, by design, and
  excluded from every comparison; but a card whose firmware *writes* a hole
  during the 60 ms of detection is not a case the testbench plays.
- **Aux memory.** The pattern goes to main memory and the scanner reads main
  memory in 40-column modes. Whether a //e's floating bus shows the aux byte
  in any configuration this sets up is answered by the mismatch count, not
  assumed.
- **Nothing here has run on hardware with the bit yet.** The level and the
  bit are checked in `sim/vbl_lock_tb.sv` against the testbench's scanner
  on every cycle of NTSC and PAL frames, with the m2b0 pin tied high to
  prove it is no longer recorded; the host's decoder frames on the bit in
  its tests.  The marks were proven on the machine on 2026-08-28; the bit
  comes from the same counter.

## Verification

- `sim/run_vbl_lock_tb.sh` - the real core, driver, hold and detector
  against an Apple whose scanner is Sather's counters and whose floating
  bus is that scanner's byte: refused when not held or held at runtime;
  the seven switches then 960 writes of the right bytes to the right
  addresses and no hole touched; locked on an NTSC machine with the
  origin, the period and zero mismatches, marks on exactly the origin
  cycles, the counter agreeing with the tb's scanner on every cycle of
  several frames, the VBL level high on exactly the scanner's lines 192
  and up and never before the lock, and bit 19 of every event the real
  reader emits equal to it with the m2b0 pin held high; the same on PAL;
  a second detection with slip 0; a reset mid-detection aborting it and
  leaving the earlier lock alone; the probe of `$C019` reading exactly
  one frame and showing VBL′ low on lines 192 up. The holes hold `A`, `H`
  and `Q`.
- `sim/run_bus_snoop_tb.sh` - a marked event cuts the frame before it, the
  notice is one word between the two, conservation holds, and a mark under
  back pressure waits its turn.
- `sim/run_reg_map_tb.sh` - the three registers: pulses, levels, readback.
