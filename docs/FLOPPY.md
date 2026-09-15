# The floppy: a Disk II on the card, the disks on the host

Status: 2026-09-14, branch `woz_support`, UNCOMMITTED.  **THE TRACK IS A
BIT STREAM, AND IT READS AND WRITES ON HARDWARE.**  The card's Disk II reads
a track as the head does, a bit per cell through the logic state sequencer,
at the image's own bit timing, at quarter-track positions, and writes a bit
per cell in write mode; every format goes through this one engine, and
`.woz` images (Applesauce, versions 1 and 2) are read and written beside
`.dsk`/`.do`/`.po`/`.nib`.  Hardware, bit `woz2` (MET +0.016/+0.058):
Lode Runner (a protected WOZ1 with quarter tracks) boots and plays at 1x
and at unlimited acceleration; Wizardry boots, its utility makes a scenario
disk onto a Pascal-formatted WOZ (all 280 blocks written by the machine,
560 of 560 sectors decode back), the new scenario boots, and a character
is created and saved.  The first write model wrote only in shift state and
lost the cells that fell in a load's cycle - Wizardry's first attempt
failed on it; the sequencer writes at every cell in write mode, and bench
case 10b sweeps all four cell phases.  Bench: `sim/run_floppy_card_vl.sh`
(Verilator), 48 checks.  Host: `fd_test` 118, the menus' virtual
write-protect tab (P on a FLOPPY row, per image; `fd1_wp`/`fd2_wp`).
Below, "nibble" where the mechanics are described is the OLD engine's
word; see "The track as bits".

> **On branch `page_cache` the two per-drive track buffers became ONE**,
> shared and tagged with whose track it holds — only one drive is ever
> live (the phases and the enable reach the selected drive alone), so a
> drive switch flushes-and-refetches exactly as a head movement does, one
> ~0.5 ms refetch no correct software can notice: everything resyncs on an
> address field after a switch anyway, and a real drive needs up to a
> second of motor first.  Two BRAM tiles returned (docs/PAGE_CACHE.md
> carries the budget); the protocol, the host, and FD_STAT's register
> shape are unchanged — a drive without the buffer simply reports stale.
> The per-drive-buffer mechanics below are historical here.

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
production), a track pre-nibblized in host RAM is seven 1 KB messages down
the same SuperSpeed link the stream comes up - the bytes themselves are
tens of microseconds of wire; what a fill pays is seven per-message
overheads and the notice's round trip (DERISK.md: the link is
latency-bound, not per-byte-bound) - and the answer is written straight
into the card's buffer as it arrives.  (An earlier revision put "~19 MB/s"
here; that figure was the Pi's SD card in the host README's boot-time
analysis, nothing to do with the FT601.) Typically **0.5-1 ms** end to end; the tails
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

**Served on the card under acceleration (2026-09-04).**  In the closed
regime (CXXX.md "The on-card slots") the sixteen switches at `$C0Ex` and
the P5A ROM at `$C6xx` are fast ops the card answers itself, no bus
cycle; the controller sees them through master_top's peripheral view of
the unified stream, with a synthetic commit that does not tick (fast_tick
ticks once for the op, as for every fast op), so the bit-cell timing is
the program's virtual time exactly as before.  The stall on a pending
track fill is unchanged.

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

Two phases to a track, 80 phases, 160 QUARTER-TRACK positions.  Ten cycles
after a phase access the cog is looked at (AppleWin's
`ControlStepperDeferred`): the magnet one phase on pulls the head a half
track up, the one back a half track down, not at all when both are on -
and two ADJACENT magnets energised together (0011, 0110, 1100, 1001) hold
it a quarter track toward the pair instead of moving the phase, an offset
that lasts only while that pair is on.  The position the host is asked for
is `2 * phase + offset`, beside the phase itself, so a host serving a
sector image keeps AppleWin's integer rule (phase >> 1) and a host serving
a WOZ maps the quarter track through its TMAP.  Every position change is a
seek: a half-track step asks for its own position, and the host says what
lies there.  Only while the drive is enabled or still coasting - the
drive's own enable line gates its stepper.  Evaluating once, ten cycles
after the *last* access, is AppleWin's GH#1110 rule in one sentence: two
adjacent magnets dropped in quick succession move nothing.

### The platter

Motor on enables the selected drive; motor off, or deselecting it, starts a
coast of `SPIN_TICKS` (1,000,000 cycles, ~1 s: AppleWin's `SPINNING_CYCLES`)
during which it still reads and still steps. A stopped drive holds the
register. Each drive keeps its own position - the BIT under the head - and
turns whether or not anyone reads: the stream is free-running, at the
track's own bit count per revolution (the fill says it), a bit per cell.
The cell is the image's bit timing in eighths of a CPU cycle (`FD_DRIVEn`'s
`cell`, 32 = four cycles, the standard; a WOZ mastered off-speed says 31 or
33): the Disk II's sequencer runs off the Apple's own 2 MHz, so a cell is a
count of cycles, and the platter keeps a fixed-point accumulator (1024 per
cycle, `cell << 7` per bit - AppleWin's `m_extraCycles`, in integers).  The
platter does not reset with the machine.

### The data register, reading

The logic state sequencer, as AppleWin's `DataLatchReadWOZ` has it.  Every
cell the bit under the head enters a four-bit window; the bit the
sequencer sees is the one before it - unless the window is all zeros, when
the MC3470 has nothing to lock on and the sequencer sees noise, a 1 about
30% of the time (WOZ 2.0's rule) - and that bit shifts into the register.
When the register's high bit lands the latch takes it and holds for 7 us,
four off per cell (so through the next cell and the one after, whose
decrement leaves it): eight cycles at the standard timing, and then it
follows the register again, high bit clear, shifting in.  Zeros arriving
while the register is empty extend the hold (GH#662): that is how a 10-bit
sync nibble's two extra zeros are absorbed and how the sequencer realigns
on the next 1 wherever a fill came down under it.  The RWTS's
`LDA $C0EC,X / BPL` loop - seven cycles round - therefore reads every
nibble exactly once: the valid window is eight cycles, the poll grid seven.
The tb checks it: 48 consecutive nibbles by that loop through the sync
gaps, none skipped or repeated, 32 cycles each and 40 for a 10-bit sync;
read every cycle, a nibble is seen for exactly eight and the next shifts
in for exactly twenty-four; ten 10-bit $FF then D5 AA 96 read back through
the gap.  And the noise rule is why the tb's tracks use the 6&2 alphabet:
a nibble with four zeros in a row is not a disk nibble, and reads as one
with a bit flipped.

`$C0nD` samples write-protect into the register as `$FF` or `$00` (AppleWin
saturates it too, GH#1078); the `$C0nE` read that follows delivers it in
bit 7 - the `LDA $C08D,X / LDA $C08E,X` idiom. A drive with no disk, or no
track yet, answers `$80` for the first `0x2EC` cycles after it starts and
noise after that (an LFSR; AppleWin's GH#864/GH#748).

### The data register, writing

A store with Q6 and Q7 set loads the shift register (any address in the
page), and from that first load on (AppleWin's `m_writeStarted`), in shift
state - Q7 set, Q6 clear - every cell writes the register's high bit at
the head and shifts a zero in.  A byte goes out at the cell rate; a
40-cycle $FF writes its eight ones and two zeros; nothing counts nibbles
or fills slots - the bench reads the five sync bytes' fifty bits and the
fifteen data bytes' hundred and twenty back from the upload, bit for bit.
The write ends with write mode, a drive change, a step or the motor
stopping.  What follows is the OLD engine's description, kept for the
$C0nD sense and the write-protect rule, which stand:

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

## The 3.5" drive

The IIgs's IWM has a 3.5" drive of its own now, the same design on a bigger
track: `rtl/gs_iwm.sv`, `docs/IWM35.md`.

## The track as bits (2026-09-14, branch `woz_support`)

The buffer is the same 6656 bytes - 53,248 bits, a WOZ's largest 5.25"
track exactly (13 blocks) - read as a bit stream: byte i holds bits 8i to
8i+7, high bit first, as a WOZ stores them.  The fill's first word names
{seq, chunk, quarter track, drive} as before and a SECOND word carries the
track's bit count; the upload carries both back.  A bit count of zero is a
position with no track (a WOZ's unmapped quarter track): the buffer is
filled, the head reads noise.  The head's position is a bit offset that
persists per drive across seeks and drive switches and wraps at the
track's count (AppleWin rescales it to a new length; here it wraps, a disk's
tracks being within a percent of one another).

The host converts every format to this: a WOZ's tracks go as they are
(strudelworks-host `src/fd_woz.cpp`: INFO, TMAP, TRKS; a write goes back
into the record in place and zeroes the header's CRC, which the format
defines as "not computed"); a sector or nibble image's nibbles go as
bits, eight each, except the self-sync $FF outside an address or data
field, which goes as ten - eight ones and two zeros, what a real INIT
wrote (`fd_nibble.cpp` `bits_from_nibbles`).  A written track comes back
as bits and is read as a sequencer reads it (`nibbles_from_bits`: a byte
completes when its high bit lands, zeros before a byte's first one are
skipped), then denibblized into a sector image or stored into a `.nib`.
The card knows nothing about formats.

Not modelled: AppleWin's track-seam jitter, and its proportional
rescaling of the position across track lengths.

## Not here

- **The IWM's 5.25" side** (rtl/gs_iwm.sv) still has the nibble engine;
  the same bit engine goes there next, so a WOZ plays on the IIgs.  Until
  then the IIgs's 5.25" drives read `FD_DRIVEn`'s cell field as a nibble
  count and are broken on this branch.
- **WOZ writes are rung 2's acceptance test** (Wizardry's scenario disk
  from its master); the engine writes bits already.
- **The 13-sector ROM**, and DOS 3.2's `D5 AA B5`.
- **A neighbour prefetch** (the host filling T+-1 into spare buffers) and
  **DDR3 staging** - the two upgrades, if `fill_max` and `late` say so.
  Under acceleration `late` said so (27 on a 45-second loader at ~90x),
  and the answer there is not a faster fill but the core waiting for it:
  `stall_o` holds the accelerated core while the selected drive's buffer
  is stale (docs/VIRTUAL_TIME.md, "The floppy holds the core"); at the
  bus's pace nothing changes.
- **The latch hold extended by zero bits** (AppleWin's GH#662): 6&2
  nibbles always start with a 1, so it never applies to these images.
