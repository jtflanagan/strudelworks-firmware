# The floppy: a Disk II on the card, the disks on the host

A Disk II controller card in a slot of the host's choosing (default 6), with
two drives, for `.dsk`/`.do`/`.po`/`.nib` images. The controller and every
cycle of its timing are in `rtl/floppy_card.sv`; the images, the nibblizing
and the menus are in strudelworks-host. No WOZ yet - see the end.

The reference model is AppleWin's `source/Disk.cpp`, its non-WOZ path, with
one deliberate departure: the data register's timing is taken from
AppleWin's LSS path instead, because that is the physical one, and this card
can afford to be physical - it counts bus cycles.


> **Under acceleration (ACCELERATION.md)** the card's tick is one per op of
> the core rather than one per bus cycle - a fast op the bus never saw ticks
> too, a dummy cycle does not - so the disk turns as fast as the core runs
> and the cycle-counted loops see what they always did. `fill_max` and `late`
> are in those ticks.

## Where the seam is, and why

**Per nibble.** The RWTS reads the register every seven cycles and expects a
new nibble every 32. Nothing off the card can meet that; the nibble must be
in a register, fed from a buffer on the card.

**Per track.** The head moves, and the RWTS reads the new track only after
its own settle delay: DOS 3.3's `SEEKABS` bottoms out at 2.8 + 2.8 ms per
half-step, so at least **5.6 ms** from the track-changing phase write to the
first read; ProDOS is the same class; loaders with their own steppers are
tighter, one or two ms. That is the budget a host has to deliver a track in.

**What the host delivers.** The card's notice reaches the host in tens of
microseconds (README.md's link measurements: 36 us p50, 118 us worst in
production), a track pre-nibblized in host RAM is seven 1 KB messages, ~370
us of wire at the Pi's ~19 MB/s, and the answer is written straight into
the card's buffer as it arrives. Typically **0.5-1 ms** end to end; the tails
(the FT601's 0.5 ms dry spells, the ingest thread's 2 ms design deadline)
are inside the DOS budget and outside a fast loader's.

**What would not fit.** A whole nibblized image is 233-266 KB; the card has
36 RAMB36 free, ~147 KB. One track is 6656 bytes, two RAMB36. So the card
holds a track per drive and the host holds the disks. (Staging whole images
in DDR3 was designed and costed - a host->DDR3 door, a third `wb_arb`
client, a copy engine, ~600 LUTs and three arbiter-facing state machines -
and is held in reserve. The buffer's fill source is the seam; nothing on the
bus side would change.)

**And the card measures its own lateness**, so the decision can be revisited
on numbers: FD_STAT's `fill_max` is the longest fill, head movement to
seventh chunk, in bus cycles; `late` counts the fills that landed after the
machine had already tried to read. Read them after a session of seeking.

## What the card does

### The switches

`$C0n0-$C0nF`, n = slot + 8, every access, read or write, even or odd:

| address | switch |
|---|---|
| `$C0n0/1 .. $C0n6/7` | phase 0..3 off/on - four magnets, the card's, reaching the selected drive |
| `$C0n8/9` | motor off/on |
| `$C0nA/B` | drive 1/2 |
| `$C0nC/D` | Q6: shift/load |
| `$C0nE/F` | Q7: read/write |

Only **even** addresses are claimed on a read, and they return the data
register; odd ones read the floating bus (UTAIIe table 9.1). The 74LS259
that holds the switches is cleared by RES', and so are these.

### The head

Two phases to a track, 80 phases; track = phase >> 1 (AppleWin's
`PhaseToTrack`, integer for non-WOZ). Ten cycles after a phase access the
cog is looked at: it moves toward an energised adjacent magnet, not at all
when both adjacent magnets are on, and only while the drive is enabled or
still coasting - the drive's own enable line gates its stepper. Evaluating
once, ten cycles after the *last* access, is AppleWin's GH#1110 rule in one
sentence: two adjacent magnets dropped in quick succession move nothing.

### The platter

Motor on enables the selected drive; motor off, or deselecting it, starts a
coast of `SPIN_TICKS` (1,000,000 cycles, ~1 s: AppleWin's `SPINNING_CYCLES`)
during which it still reads and still steps. A stopped drive holds the
register. Each drive keeps its own position - the slot under the head and
the bit cell within it - and turns whether or not anyone reads: the stream
is free-running, at the drive's own `nibbles` per revolution (6384 for a
sector image, AppleWin's `NibblizeTrack` output; 6656 for a `.nib`). The
platter does not reset with the machine.

### The data register, reading

A nibble is 32 cycles, eight 4 us bit cells. When the last bit lands the
register takes the nibble, high bit set, and **holds it for seven cycles**;
after that it shows the next nibble shifting in, high bit clear
(`next >> (8 - bits_in)`). AppleWin's LSS path does exactly this
(`m_latchDelay = 7`, `DataLatchReadWOZ`), and it is why the RWTS's
`LDA $C0EC,X / BPL` loop - seven cycles round - reads every nibble exactly
once: the valid window is eight cycles, the poll grid seven. The tb checks
both: 64 nibbles read by that loop are consecutive, none skipped or
repeated, in 63 x 32 cycles; read every cycle, a nibble is seen for exactly
eight and the next shifts in for exactly twenty-four.

`$C0nD` samples write-protect into the register as `$FF` or `$00` (AppleWin
saturates it too, GH#1078); the `$C0nE` read that follows delivers it in
bit 7 - the `LDA $C08D,X / LDA $C08E,X` idiom. A drive with no disk, or no
track yet, answers `$80` for the first `0x2EC` cycles after it starts and
noise after that (an LFSR; AppleWin's GH#864/GH#748).

### The data register, writing

A store with Q6 and Q7 both set loads the register - the 74LS323's LD, any
address in the page - and the `$C0nC` access that follows is the shift: that
is when the byte lands in the track, at the slot under the head. A 10-bit
self-sync `$FF` takes 40 cycles and so skips a slot; the card fills the
skipped slot with `$FF`, which is what the two extra zero bits were, so a
track written at the machine's pace - a DOS `INIT` - stays contiguous with
nothing to fix up afterwards (AppleWin needs its `FormatTrack` machinery
for this; a free-running position does not). Write-protected, or stopped:
nothing lands.

### The buffer, and the host

One track per drive, 6656 bytes in four byte lanes (`rtl/fd_bank.sv`, true
dual-port BRAM: the bus side a byte at a time, the link side a word at a
time), two RAMB36 each. The nibble the register will take next is refreshed
into a register every few clocks, so the read path never waits on the RAM.

A head movement into another track, a disk inserted, or a switch to a drive
whose buffer holds another track (with one buffer per drive that is the
exception, not the rule) makes the buffer **stale** and sends **FD_SEEK**
`{drive, track, seq}`. The host answers with seven **FD_TRACK** chunks of
252 words (the seventh 152), each `{seq, chunk, track, drive}` then the
nibbles, written straight into the buffer; the seventh clears stale. While
stale the register serves noise, **never the old track**: a late host makes
the RWTS keep looking for an address field, which it retries, rather than
find one with the wrong track number, which it treats as a seek error.
`seq` is bumped per seek; a chunk with any other seq is dropped, so a late
answer to a superseded seek changes nothing.

A buffer that was written to is **dirty**. Before its track is left - a
head movement, a drive ejected, a spin-down with the buffer dirty, or the
host's `flush` bit - it goes back as seven **FD_DIRTY** chunks, the same
shape, **before the FD_SEEK** for the new track, so the host has the whole
written track before it could be asked for it again. The host denibblizes
and writes the file; the card has already forgotten the track.

Card->host messages are a sixth `msg_arb` source in `card_link`, below the
hard disk's and above the capture: rate-bounded by the machine's own head
movements and writes, as `msg_arb`'s ordering rule requires.

### Never a stolen cycle

The floppy raises no override and withholds no `cyc_en`, ever (the tb
counts overrides over the whole run: zero). A real floppy's loops are
counted to the cycle, and a card that took one to fetch a track would break
the timing the track is read with. Everything the host is involved in
happens beside the read stream.

## Registers and messages

See PROTOCOL.md for the tables. In brief:

- **FD_SLOT** `0x8000_003C` - the slot, latched at RES' and at a boot
  release like HD_SLOT; yields to both MB_SLOT and HD_SLOT; `rom`, `seeks`.
- **FD_DRIVE1/2** `0x8000_0040/44` - what is in the drive, **live**: a
  runtime menu changes a disk under a running program. `inserted` (its 0->1
  edge is the insertion; eject first to change a disk), `wp`, `nibbles`,
  `tracks`, `flush` (W1); `stale`, `dirty`, `phase` back.
- **FD_STAT** `0x8000_0048` - `motor`, `drive`, `q6`, `q7`; `late` and
  `fill_max`, each with a W1 clear.
- **FD_ROM** `0x1E` host->card, 64 words: the 256-byte P5A boot ROM, loaded
  from a file on the host (Apple's, vendored as strudelworks-host's
  `assets/disk2.rom` under the licensing exception its NOTICE records - the
  same bytes AppleWin ships). Until it has arrived the card claims nothing.
- **FD_TRACK** `0x1F` host->card, **FD_SEEK** `0x20` and **FD_DIRTY** `0x21`
  card->host, as above.

## What it costs

Against the build before it (the VBL lock's): +873 LUTs (7720 of 20800,
37%), +499 flip-flops (5660 of 41600), +4 block RAM tiles (18 of 50 - the
eight track-buffer lanes as RAMB18s, inferred as true dual-port RAM), the
boot ROM as 11 RAM64Ms.  Timing met at 100 MHz.

## On hardware, 2026-08-28

First power-up of the design, on the //e with the Pi 5 host, slot 6, the
hard disk off so the slot scan reaches the floppy:

- **DOS 3.3 System Master boots** to the `]` prompt on the first try;
  `CATALOG` lists it; ProDOS 2.4.2 boots to Bitsy Bye and names `S6,D1`.
- **Writes**: `SAVE FDTEST` dirtied three tracks, the host wrote three back,
  the file on the host shows the new catalog entry, T/S list, data sector
  and VTOC and nothing else changed; after a fresh boot `LOAD FDTEST` /
  `RUN` printed the program from the track the machine wrote.
- **Two drives**: `CATALOG,D2` on a second image; a runtime-menu swap of
  drive 1 mid-run cost exactly one seek and `CATALOG,D1` listed the new disk.
- **Lateness**: `fill_max` 489-574 bus cycles (~0.5 ms) across the DOS boot,
  the ProDOS boot and the swap; `late` 0 everywhere.  A 24 M-cycle bus
  trace of the DOS boot (0 gaps) shows 68 head movements and the RWTS's
  shortest gap from a track change to its first `$C0EC` read at 37,477
  cycles - 37 ms, seventy times the fill.  The 5.6 ms in the budget above
  was the worst case of the stepping tables; the RWTS is far lazier.
- **A loader of its own**: the Cycle-Counting Megademo (deater) streams the
  whole disk through its own routines - 209 seeks - and runs; fill max
  518, late 0.
- One host bug found and fixed on the way: a disk swap's eject word was
  overwritten by the insert's before the card saw it, so no edge, no stale,
  and the old track stayed in the buffer (the seek count not moving was the
  tell).  The words are a queue now.

## Tested by

`sim/run_floppy_card_tb.sh` - the scripted CPU behind the real driver,
receiver and arbiter, the tb playing the host; every property in this
document is a check there. `sim/run_reg_map_tb.sh` case 12b for the
registers. And the hardware above.

## Not here

- **WOZ.** Bit-level tracks, quarter tracks, the jitter. The buffer would
  become a bit stream and the position a bit counter; the seam is the same.
- **The 13-sector ROM**, and DOS 3.2's `D5 AA B5`.
- **A neighbour prefetch** (the host filling T+-1 into spare buffers) and
  **DDR3 staging** - the two upgrades, if `fill_max` and `late` say so.
- **The latch hold extended by zero bits** (AppleWin's GH#662): 6&2
  nibbles always start with a 1, so it never applies to these images.
