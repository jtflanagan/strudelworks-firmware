# The No-Slot Clock: a DS1216 under the ROM, the Pi's clock behind it

Status: **✅ on hardware, 2026-09-05.** Bit at WNS +0.009 (SRAM). The user's
No-Slot Clock utility disk and A2Desktop both find the clock and read the
Pi's time from it.
`sim/run_no_slot_clock_tb.sh` drives the part at the sequencer's tightest op
spacing through the real message parser and checks every rule against
AppleWin's model; `sim/run_reg_map_tb.sh` covers NSC_CTRL / NSC_TIME /
NSC_DATE; the accel bench and the ProDOS boot bench are unchanged by it
(137.9M ops, 0 bad).

The Dallas DS1216 "SmartWatch" is a socket that sits between a ROM and its
board and steals nothing: it watches the ROM's chip enable, A0, A2 and R/W,
and a program talks to it through ordinary reads of the ROM. In a IIe it
goes under the CD ROM, so it hears every access to the internal ROM's
pages. A read with A2 high resets its comparison; 64 accesses with A2 low
clock the bit on A0 into a 64-bit comparison register; when those 64 bits
are the key `$5CA33AC55CA33AC5` (LSB first) the clock register fills with
the time and the next 64 reads with A2 high return it, one bit a read on
D0, LSB first: centiseconds, seconds, minutes, hours, day of week, date,
month, year, a packed-BCD byte each. 64 accesses with A2 low in that window
set the clock. AppleWin's `NoSlotClock.cpp` (Nick Westgate; the project's
reference) models the part in C++; `rtl/no_slot_clock.sv` is that model as
gateware, and the host supplies the one thing the part cannot: the time.

## The user's rule

**The card ignores a program that sets the clock.** The 64 writes are
counted exactly as AppleWin counts them ("simulate writes, but our clock
register is read-only"), the window ends, and the time stays the host's.
The host's time is the Pi's local time, which is NTP's when the Pi syncs
(it does, `systemd-timesyncd`), in the Pi's time zone - set to
`America/Chicago` on 2026-09-05.

## Where it hangs

Not on the peripherals' view (the mouse's, the Mockingboard's): those are
slot cards, and a claimed read's byte goes onto the bus through the driver.
The clock's reads are of the MOTHERBOARD's ROM, which drives the bus itself
in mode 0, so the card must not drive against it. Instead:

- **Where it listens** is the MMU's map. `apple_mmu` answers `q_nsc` for
  the address the core has up (`nxt_addr`): the internal ROM's `$C3` page
  while that page is the internal ROM's (INTCXROM set, or SLOTC3ROM
  clear), or its `$C8` page while the internal ROM is there (INTCXROM or
  INTC8ROM). Those are the two pages AppleWin models, taken from the
  card's own map - so the `$C8` case includes the INTC8ROM latch AppleWin's
  `IsPotentialNoSlotClockAccess` leaves out: with it set the internal ROM
  IS at `$C800`, and a real part under the CD ROM sees the access. Every
  mode, serving or not: the part is under the ROM, not a serve.
- **Where it steps** is the unified op stream (`accel_seq u_*`): the op's
  eligibility is captured at its present from the live map, and the state
  moves at the op's commit - the driver's for a bus op, the sequencer's
  `fast_tick` for a fast one. Reads and writes alike, as AppleWin's
  `Write()` does; overrides (a hold's, the disk's) and dummies are nobody's.
  A FETCH is not an access: AppleWin runs fetches past its I/O handlers,
  and the 80-column firmware lives in this very page; the icache never
  wakes the part.
- **Where it acts** is `master_top`'s `cpu_din`, the byte the core takes
  from the sequencer - the bus's in mode 0, the ROM image's for a fast op,
  a switch's for an internalized one. For a read of the clock (enabled,
  the clock's page, A2 high) D0 is the ring's current bit; the other seven
  bits are whatever served them, which is what a real part leaves on a
  floating bus and what AppleWin's `ReadBit` does to `data`. One LUT on
  one bit, behind the part's registered verdict. Never the bus, never the
  capture: the host's mirror sees the ROM byte, and a ROM read changes no
  memory.

**Across clocks.** The verdict (`sub`, `sub_bit`) is a pair of flops off
the live address and the registered state. The core takes a byte no sooner
than three clocks after it presented (settled + dispatch + the cache's
serve; a bus cycle is ten), and the state moves at the commit, two clocks
before the next op's earliest byte - so a one-clock-late verdict is never
seen. `sim/no_slot_clock_tb.sv` models exactly that tightest spacing.

## The time

`NSC_TIME` (type `0x27`), two words: the register as the part holds it,
low half then high - `{hour, minute, second, centisecond}` then `{year,
month, date, day of week}`, packed BCD, day of week 1 = Sunday (AppleWin's
convention; the 1991 utilities' too). The card takes it whole at the
second word, so an unlock never sees half an update, and copies it into
the part's clock register at each unlock. **The host sends one every
centisecond** (`drive_clock` on the ingest thread: three words a hundred
times a second, nothing on the fast wire) **and the card keeps no time of
its own** - no counter, no calendar, no time zone, nothing to drift. Until
the first message lands the part never unlocks: a driver finds no clock
rather than year 00.

## The registers

**`NSC_CTRL`, `0x8000_00D8`**: `[0]` enable (RW, 1 at the card's reset -
harmless, it answers nothing without a time), `[1]` time loaded, `[2]` the
clock register is being read out, `[3]` writes enabled (no mismatch
pending), `[13:8]` the comparison's bit index, `[21:16]` the read-out's,
`[31:24]` unlocks, wrapping - what a bring-up session watches while a
driver runs. **`NSC_TIME`, `0x8000_00DC`** and **`NSC_DATE`, `0x8000_00E0`**:
the time the card holds, as sent.

## Deliberately not there

- **The II/II+ placement ($F8xx, under the F8 ROM).** AppleWin's GH#827
  case; this is a IIe.
- **`$D000-$DFFF`.** The CD ROM is there too when the language card's RAM
  is not read-enabled, so a real part hears those accesses; no driver uses
  them and AppleWin does not model it.
- **`$C1`, `$C2`, `$C4`-`$C7` with INTCXROM.** Also the CD ROM on a real
  IIe; AppleWin's two pages are what drivers use.
- **A time on the card.** Above: the feed is the clock.
- **A reset on RES'.** AppleWin resets the part on a power cycle only
  ("SmartWatch reset - whether tied to system reset is component
  specific"); here the card's reset and the lever do it.
