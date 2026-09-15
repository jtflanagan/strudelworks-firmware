Status: 2026-09-14, branch `woz_support`, UNCOMMITTED.  **THE IWM'S 5.25" DRIVES
ARE BIT STREAMS**, the Disk II card's engine and protocol (docs/FLOPPY.md "The track
as bits"): quarter-track heads, a bit platter per drive on the disk's own cell, the
logic state sequencer for reads, a bit per cell for writes after a load, the host's
FD_SEEK {seq, 0, qtr, phase, drive} and FD_TRACK/FD_DIRTY with the bit count, and the
write-protect rule (a bit lands only on a disk unprotected at the landing).  The
24-cycle clear-on-read 5.25" hold below is GONE: it existed because an exactly
periodic nibble stream phase-locked ProDOS's eight-cycle poll against a 7-cycle hold,
and the ten-bit sync nibbles move the phase, so the Disk II's own rule serves.  The
3.5" drive keeps its nibble engine.  BENCH: `sim/run_gs_iwm_write_tb.sh` rewritten for
bit tracks, PASS (quarter track, sense, 48 nibbles through sync gaps, a sector's bits
written and read back, uploads with the bit count, a protected disk untouched, the tab
set mid-burst, motor/flush/eject uploads, four cell phases); `sim/suite.sh gs` 13/13;
`sim/run_boot_gs_tb.sh --fd525=` boots `wave.dsk` (102 seeks) and ProDOS 2.4.3 (118)
to BITSY BYE through the ROM's slot 6 - every half- and quarter-track position is a
seek now - and `--fd35=XMAS_DEMO.po --instrs=16000000 --clks=1200000000` still sees
the demo launch off the 3.5" drive (bank $0E at instruction 3,495,651; 22 seeks, 0
late).  The 5.25" step decision is registered a tick early, as the Disk II
card's (docs/FLOPPY.md "The head"), after build woz3 named that stepper's live
chain at 14 levels.  Build gs_woz_iwm1 (MET +0.003/+0.041, 0 of 96,982) named
a new chain, the drive select to the dispatcher's byte at 15 levels, cut below
("The build, gs_woz_iwm1"): each drive's quarter-track position is a register,
and the 3.5" partial byte's bit count is registered.  Build and hardware pending.
Previous status: 2026-09-14, branch `long_data`, UNCOMMITTED.  **THE IWM'S 5.25" DRIVES WRITE.**
The Disk II card's write model on the IWM (`rtl/gs_iwm.sv`): a data write lands at the
slot under the head, `$FF` in the slot a 40-cycle sync byte skips; bit 7 of the status
byte is the disk's own write protect; a written track goes home as seven FD_DIRTY chunks
with the filling seek's seq, ahead of the next seek, whenever the buffer's claim ends
(a step or select, the motor stopping, an eject, the host's flush).  BENCH:
`sim/run_gs_iwm_write_tb.sh` passes every property (in `suite.sh gs`), and fails the old
filler rule as a negative control.  HARDWARE, bit `gs_iwmwr4` (MET +0.007/+0.007, DDR3
calibrated): `wave.dsk` boots off the IWM 5.25" (17 seeks, 0 late); a cold-booted DOS 3.3
master copy takes `SAVE WTEST` (3 tracks home), `CATALOG` lists it, `RUN WTEST` prints its
line, and the host's image decodes to the same program.  Two faults found on the way:
the 5.25" sense under ENABLE2 (boots hung) and the Disk II `$FF` filler (every sector
complemented and a byte late) - both below.  Gates: `suite.sh gs` 13/13, the writable
`wave.dsk` and the XMAS 3.5" bench boots unchanged.  Since the status below: Arkanoid boots from the 3.5" drive
at the unlimited target on hardware (PLAIN 73.55x, bit `gs_iwm1`).

Previous status: 2026-09-13, branch `long_data`, UNCOMMITTED.  **THE 5.25" DRIVES ARE ON
THE IWM, AND BOTH VIRTUAL DRIVES RUN ON THE CORE'S CYCLES ALONE** (the user's
rule: a 5.25" nibble 32 cycles, a 3.5" 44.8, no speed request or slowdown).
BENCH: ProDOS 2.4.3 and `wave.dsk` boot off 5.25" drive 1 through the ROM's
internal slot 6 to the BITSY BYE selector (`sim/run_boot_gs_tb.sh --fd525=`,
21 and 17 seeks); the XMAS demo off the 3.5" drive as before (the same 17
seeks, head and last PC); GS/OS 12/0 with its disk unchanged; the ROM boot at
the KEGS floor.  The Disk II card is not built at GS = 1; the host keeps its
floppy service there without a slot ROM (cross-built).  Arkanoid's 3.5" boot
still fails at the unlimited target on hardware (it boots at 2.8), and every
3.5" read is made at the fast speed - so not the speed bit.  The bench does NOT
reproduce that symptom: `boot_gs_tb` fails Arkanoid's IWM boot at BOTH 2.8x
(145 seeks, the head back at track 0, still in the ROM at 8 M instructions) and
unlimited (146) - a difference between the bench's model and the card or host,
not the acceleration effect, and still open.  Build and hardware pending.  (The previous
status - the 3.5" drive booting the XMAS demo on hardware, build
`gs_build_msgfix` - is kept below.)

Previous status: 2026-09-13, branch `gs_emulation`. **HARDWARE: the XMAS demo boots
from the 3.5" drive on the IWM and runs, from a cold reset, with no
keystroke** (`gs_xmas.conf`, `fd = off`, `hd = off`; 40 tracks streamed, 0
late). What was in the way was two other SLOTS, not this chip - see "It
boots" below. Bitstream `gs_build_msgfix`: TIMING MET wns=+0.130 whs=+0.048,
0 of 94,662, 0 undriven, 0 multi-driven, generate scopes clean; it is the
first one whose message-type list knows `0x31`, so the card no longer
announces every track fill as unknown. BENCH: the demo launches (bank $0E at
instruction 3,427,317 of `sim/run_boot_gs_tb.sh --fd35=XMAS_DEMO.po
--instrs=8000000 --clks=120000000`); `sim/lint.sh` clean; `sim/suite.sh gs`
11/11; the 65816 battery 981,610 tests 0 failed. Host fd35_test 335/335 on
the Pi. The DDR3 calibrates (UART D=1 K=17).

# The 3.5" drive: the IWM on the card, the disk on the host

The IIgs's Integrated Woz Machine at `$C0E0-$C0EF` with ONE Sony 800K
drive on it, for the software that boots from a 3.5" disk and reads it
straight through the chip: the FTA demos and their loaders, and later
GS/OS itself from a floppy.  The chip and the drive are `rtl/gs_iwm.sv`
(grown from the stub of GS.md rung 3c); the disk, nibblized whole, is the
host's `src/fd35_service.cpp`, with `src/fd35_nibble.cpp` making the tracks.
The reference is KEGS 1.38's `iwm.c`, function for function; the bench is
`sim/run_boot_gs_tb.sh --fd35=IMAGE`.

## Why

The FTA Christmas demo (`XMAS_DEMO.po`, from the KEGS distribution) plays
Ensoniq music from the first second of its boot, which is what the sound
work (GS.md rung 7) needs a loop around.  Arkanoid's attract mode is
silent.  On the card the demo read one block through the slot-7 SmartPort
and dropped into the monitor: its boot block checks for a IIgs, sets fast
speed, and fetches the rest through the IWM with its own loader, in bank 0
at `$9200-$9690` - a quarter of a million `LDX $C0EC / BPL` polls in the
first 1.5 million instructions of the KEGS trace, with the drive's phases
and `$C031` driven directly.  A believable empty IWM was never going to
carry that; the user's decision (2026-09-12) was to build the drive.

## What KEGS says the drive is

Read out of `iwm.c` before anything was written (the summary is in this
file's history; the numbers are in the RTL's comments):

- **The address is the register.**  `$C0E0-$C0E7` the four phases,
  `$C0E8/9` the IWM's ENABLE, `$C0EA/B` the drive select, `$C0EC/D` Q6,
  `$C0EE/F` Q7; every access, read or write, touches its switch first.
- **The drive's own register** is a four-bit address made of
  `{ph1, ph0, $C031[7], ph2}`.  With Q6 set, bit 7 of the status byte is
  the SENSE line that address selects; a strobe of phase 3 performs the
  ACTION it names.  `$C031` bit 7 is a select bit, NOT the side: the side
  is chosen by the sense reads `$1` (lower head) and `$3` (upper head).
  `$C031` bit 6 chooses the 3.5" drives over the 5.25".
- **The sense lines**: `$0` step direction, `$2` no disk (1), `$4` not
  stepping (1), `$6` unlocked (1), `$8` motor off (1), `$9` two sides,
  `$A` not at track 0, `$B` not ready (1), `$C` disk switched, `$F` drive
  absent (drive 1 only exists).  **The actions**: `$0/$1` step direction
  inward/outward, `$3` clear disk-switched, `$4` step one track, `$8/$9`
  motor on/off, `$D` eject.
- **The status byte** is `{sense, 0, ENABLE, mode[4:0]}`; the mode
  register is written with Q6 and Q7 set and ENABLE off; bit 0 is LATCH
  MODE, bit 2 "motor off at once" (else ENABLE drops a second after
  `$C0E8`), bit 3 the 2 us bit cell.
- **The data register, in latch mode**: a completed nibble is returned
  ONCE; the read after it sees the next nibble shifting in, bit 7 clear.
  That is `iwm_read_data`'s latch-mode arm, not the fast path the reference
  was traced with - KEGS's default `fast_disk_emul` returns a fresh nibble
  on every read and ignores time.
- **The track**: five zones of sixteen tracks, 12/11/10/9/8 sectors a
  side, interleave 2:1, 400 sync bytes before sector 0 and 54 before the
  rest, `D5 AA 96` + track/sector/side/format/checksum + `DE AA`, five
  sync, `D5 AA AD` + sector + 699 data nibbles (524 bytes 6&2: twelve zero
  tag bytes, then the 512) + four checksum nibbles + `DE AA FF`.  The image
  file is the sectors in qtr-track order (track 0 side 0, track 0 side 1,
  ...).  The bit cell is 2 us, uniform across the zones; KEGS varies the
  track LENGTH in bits to model the spindle's five speeds.

## What the card does

**The platter is a nibble stream**, `nibbles` of them per track (9694 in
zone 0, 6578 in zone 4: `tools/nib35.py` says), in three block RAM tiles of
1024 words (3072 words for the 2560 a zone-0 track needs; the first cut's
four byte lanes of the Disk II's shape took four tiles at 62%, and the
count matters - see "On hardware" below).  KEGS's ten-bit sync bytes
are eight-bit `$FF`s here: the two zero bits only ever mattered to a
bit-level reader, and the data register hides them.  It turns one slot per
nibble time whenever the IWM's ENABLE is on, as KEGS's does.

**Time is the core's**, as the Disk II's is (FLOPPY.md): a nibble is
sixteen ticks with the CPU at 1 MHz and 44.8 with `$C036`'s speed bit set,
counted in fifths of a tick so the fast figure is exact.  A loader's loops
are counted in the CPU's cycles; a platter at wall time would run away from
an accelerated core, or the ROM's bounded sync searches (a `DEY/BNE` ladder
of ~280,000 polls, a second at 2.8 MHz) would expire on a platter that did
not.  The IIgs's beam and timers run at the bus's cadence by the user's
decision of 2026-09-11; the disk is a program-relative device and follows
the program, which is the same rule the 5.25" floppy already keeps.

**Latch mode is clear-on-read**: `complete` latches the slot's nibble with
`latch_valid`; a data read returns it and clears the flag; until the next
completes, reads return the shift-in partial.  Without latch mode the
nibble is held for half a nibble time (the 5.25" 7 us hold, scaled).

**The buffer and the host** are FLOPPY.md's design.  A step, a head select
to the other side, or an insertion makes the buffer STALE and sends
`FD35_SEEK {seq, 0, qtr, 0}`; the host answers with `FD35_TRACK` chunks,
each `{seq, chunk, qtr, 0}` then `{chunks, 0, nibbles}` then up to 252
words, written straight into the lanes; the last clears STALE.  While
stale the register serves an LFSR's noise, never the old track, the drive
reports itself STEPPING (sense `$4` = 0) after a step so a driver that
waits to settle waits for the fill, and the accelerated core is held
(`stall_o`, as the Disk II's).  A seek nobody answered is asked again after
`FILL_RETRY_CLKS` (40 ms).  `fill_max` is in microseconds of the card's
clock, not ticks, because the core is held during a fill.

**Drive 2 is empty and answers so.**  The ROM's probe asks drive 2 FIRST
(`$C0EB`, then "disk in place?"), and passes it by only because KEGS's
`drive35[1]` says no disk; a one-drive model that answered "present" to
both selects had the ROM probing the wrong drive, reading two address
fields off it and giving up (the bench found it: the card's first
divergence from the KEGS trace after the motor came on was that one sense
bit).  So the drive's OWN senses and actions - disk present, locked, at
track 0, installed, the step and the head selects - are gated by
`drive_sel`; the STEP DIRECTION and the DRIVE MOTOR are not, because KEGS
keeps them in the IWM's state word shared by both selects, and the ROM sets
the direction with drive 2 selected and reads it back expecting to see it
(the bench's next divergence, one probe later).

**The stub's parts are all still there**: the ENABLE2 handshake for the
SmartPort probe, the empty-5.25" data byte that varies, the mode register.
With `$C031` bit 6 clear the chip answers as it did - no 5.25" drive on
this side; the Disk II is `rtl/floppy_card.sv` in its own slot.

## The virtual drives run in the core's cycles (2026-09-13)

**The user's rule:** a virtual IWM drive ignores every speed request and runs
strictly on the soft core's cycles.  A nibble is a FIXED number of cycles - 32
for a 5.25" drive, 44.8 for the 3.5" - whatever `$C036` asks, with no motor-on
slowdown and no 1 MHz or wall time anywhere in the drive.  The loops a driver
counts in cycles line up by construction, and the load runs at whatever speed
the core is accelerated to.  A wall-time path is for a physical drive, if one
is ever attached.

The 3.5" drive used to follow `$C036` bit 7 as KEGS does (16 cycles at 1 MHz,
44.8 at 2.8).  The fixed figure was measured before it was chosen: every one of
the 3.5" data reads of the XMAS demo's boot (462,279) and Arkanoid's
(1,295,128) was made with bit 7 SET, so the 3.5" drivers run their loops for
2.8 MHz and 44.8 is the cycle count they expect - and for those loaders the fix
changes nothing (the XMAS bench on the new drive: the same 17 seeks and fills,
the same head, the same last PC).  The same measurement says the speed bit is
NOT why Arkanoid's IWM boot fails at the unlimited target: the bench reproduces
that failure (146 seeks, the head back at track 0, still in the ROM at 8 M
instructions) with every read at 2.8 MHz, before and after the change.

## The 5.25" drives (2026-09-13)

`$C031` bit 6 clear selects them: two drives, the Disk II's behaviour behind
the IWM's register face, and on a IIgs the Disk II card is NOT built
(`rtl/master_top.sv` `g_no_fd`) - slot 6's `$C0Ex` is the internal IWM.

- **The heads** are `rtl/floppy_card.sv`'s stepper: the four phases are
  magnets, each drive's head a cog in half-tracks 0..79, and ten cycles after
  the last phase access the selected drive's cog steps one half-track toward
  the one energised neighbour (not at all with both on), while the IWM's
  ENABLE is on.
- **The data register** is the same machinery as the 3.5" side's, at 32 cycles
  a nibble: latch mode hands each nibble out once; without it (the 5.25"
  firmware's) a nibble is held seven cycles, the Disk II's hold, and then the
  next shows shifting in.
- **The 5.25" hold: until the read that takes it, or 24 cycles.**  The first
  cut held a completed nibble the Disk II's seven cycles (`floppy_card`
  `HOLD_TICKS`), and ProDOS 2.4.3 booted its sector 0 and then hung in its boot
  block's reader for ever.  The bench's trace (instruction 1,308,597 on) says
  why: the loop `LDA $C08C,X / BPL` is exactly EIGHT cycles here (the branch
  from `$09FE` back to `$09FB` crosses a page, a fourth cycle in emulation
  mode), the nibble exactly 32 - four polls a nibble, every one landing 7.4
  cycles after the nibble completed, 0.4 past the hold.  After one `D5` the loop
  never saw a byte with bit 7 again (`latch=AA v=1`, the read returning the
  partial `01`).  A real drive never locks like that - ten-bit sync bytes and
  spindle jitter keep the phase moving - but a cycle-exact stream cannot move,
  so the hold has to be longer than any poll loop.  Clear-on-read keeps the
  longer hold from returning a nibble twice to a search that polls again a few
  cycles after a hit (`CMP #$D5 / BNE`); 24 cycles is well before the next
  nibble at 32.  A deliberate departure from the Disk II and from KEGS's
  non-latch arm, forced by the cycle rule.  The 3.5" side is unchanged.
- **The status byte's bit 7** is the drive's write protect (`iwm.c`: `status =
  dsk->write_prot`): the disk's own, from FD_DRIVE1/2, and protected with no disk in.
  UNDER ENABLE2 it is 1 for either side (KEGS: "Read status under enable2: 1"):
  phases 1 and 3 address the SmartPort bus and bit 7 is a device's ACK, which the
  ROM's slot-5 probe polls at `FF/581F`.  The first build with writes left this out;
  a writable 5.25" disk read 0 there, the ROM waited on a device that is not there
  (375,532 polls in the bench) and never booted slot 6 - on hardware "Check startup
  device!" with one seek.  The drives had always read protected, which hid it; the
  boot bench's drives were wired protected too, and are now writable as the host's.
- **Writes (2026-09-14)** are the Disk II card's model (`rtl/floppy_card.sv`).  A data
  write - an odd address with Q7 and Q6 set after the touch, the motor on, not ENABLE2
  (`write_iwm`) - on a writable disk whose track is in the buffer lands the byte at the
  slot under the head, taken at the load because on the IWM the load is the write, and the
  bytes after it in the same burst land CONTIGUOUSLY, each in the slot after the last: a
  byte written slower than 32 cycles is a nine- or ten-bit cell whose extra zero bits no
  reader takes for a nibble, so they take no slot and the burst trails the head a little.
  The first write build used the Disk II card's rule instead - every byte under the head,
  a skipped slot filled with `$FF` - and on the card every sector DOS 3.3's SAVE wrote
  decoded one byte late and complemented (I/O ERROR): RWTS WRITE16 steps 36 cycles from the
  data prologue's `$AD` to the first data nibble, the write starts a fixed time after the
  address field was read so the phase repeats, and at this drive's phase that step crossed
  a slot boundary and put a phantom `$FF` at the head of every data field.  The write bench
  now replays WRITE16's 40/36/32 spacing at all 32 phases.  The buffer's head-side port takes both the
  fills and the stores (a byte-wide write enable); the link side only reads, for the
  upload, so nothing writes a tile from two places.  A written buffer goes home as seven
  FD_DIRTY chunks (`0x21`, `{seq, chunk, track, drive}`) carrying the seq that filled it
  - the host keeps only a track it answered (`fd_service.cpp` on_dirty) - before the
  buffer's claim ends: another track, drive or side wanted, the motor stopping, the disk
  ejected, or FD_DRIVE's flush; a flush while an upload is going out sends the track again
  after it.  `sim/run_gs_iwm_write_tb.sh` checks each, and that a protected disk takes
  nothing.
- **One buffer for whichever drive is in use,** tagged {side, drive, track}.  A
  fill starts only when the SELECTED drive has a disk and the buffer is not its
  track, so `$C031` flicking to an empty 5.25" pair never throws away the 3.5"
  track, and an insertion is remembered until its side is selected.
- **The host is the Disk II's, unchanged.**  A 5.25" drive asks with FD_SEEK
  (`0x20`, `{seq, chunk 0, track, drive}`) on the IWM's link source and takes
  the seven FD_TRACK chunks (`0x1F`, `{seq, chunk, track, drive}` then 252 words,
  152 in the last); FD_DRIVE1/2 (`0x8000_0040/44`) say what is in the drives
  (inserted, write protect, nibbles, tracks) and read back the IWM's stale bits
  and head positions, FD_STAT its seeks, late count and fill maximum.  The host
  (`src/pipeline.cpp`) keeps the floppy service on a IIgs but sends no Disk II
  ROM and sets no slot: `fd1 = IMAGE` puts a disk in drive 1.
- **The bench:** `sim/run_boot_gs_tb.sh --fd525=IMAGE` - `tools/nib525.py`
  nibblizes it exactly as the host's service does (its `--verify` rebuilds
  ProDOS 2.4.3, the DOS 3.3 System Master and `wave.dsk` byte for byte) - with
  no slot-7 SmartPort ROM sent, so the ROM's scan reaches slot 6.

## The build, gs_iwm1 (2026-09-13)

TIMING MET wns +0.038 whs +0.042, 0 of 95,257 failing, max depth 21; synthesis
0 undriven, 0 multi-driven.  The worst path is the instruction front's; the
>= 14 tail (256) is the old families.  **One new chain, named:**
`u_iwm/nib_acc -> u_seq/swi_byte_q`, 13 levels, slack 0.487 - the constant
divide that makes the "bits shifted in so far" of the partial byte
(`nib_acc / 20` or `/ 28`), through the IWM's read byte and `gs_io`'s mux into
the dispatcher's registered byte.  Cosmetic logic on a real path; the fix is to
register the bit count every clock (it only has to look like a byte shifting
in).  A follow-up, not a blocker.  DONE 2026-09-14 (below).

## The build, gs_woz_iwm1 (2026-09-14)

The 5.25" bit engine before its stepper cut: TIMING MET wns +0.003 whs +0.041,
0 of 96,982 failing.  The worst path is the instruction front's want_tag (12
levels).  **One new chain, named:** `u_iwm/drive_sel_reg -> u_seq/swi_byte_q`,
15 levels, slack +0.008.  The selected drive's quarter-track position was
computed live from its cog and pair offset, and that arithmetic fed the
buffer-identity compare, `usable`, the partial byte and the read byte, then
`gs_io`'s mux into the dispatcher's registered byte.

**The cut.** Each drive's quarter-track position is a register (`qtr_d5`),
written by the step with the position the registered step decision already
computed.  The Disk II card's `qpos` is its twin and got the same register.
The partial byte's bit count (`bits_in`, the old `nib_acc / 28` divide) is
registered a clock late, which a byte shifting in cannot show.  Benches: the
floppy card 50/50, `gs_iwm_write` PASS, `sim/suite.sh gs` 13/13.  The boots
match the pre-cut runs line for line: `wave.dsk` 102 seeks and ProDOS 2.4.3 118
seeks to BITSY BYE off the 5.25" drive, and the XMAS demo off the 3.5" drive
launches at the same instruction, 3,495,651, with 22 seeks and 0 late.

**Build gs_woz_iwm3, with the cut:** TIMING MET wns +0.038 whs +0.043, 0 of
97,020 failing, max depth 22.  The drive-select chain is gone: the IWM's worst
path is now 11 levels at +1.176 (the drive select into a track buffer's write
enable).  What remains at 12 levels or more is the instruction front, the
65816's microcode address and its IR fan-out into the dline, all older families.

## Registers and messages

- **FD35_DRIVE** `0x8000_0138` - `inserted` (RW, its 0->1 edge is the
  insertion), `wp` (RW); `stale`, `track`, `side`, `motor35`, `motor`,
  `seeks` back.
- **FD35_STAT** `0x8000_013C` - `late` (W1 bit 0 clears), `ctl` =
  `{phases, q7, q6, drive_sel, apple35_sel}`, `fill_max` in us (W1 bit 1).
- **FD35_TRACK** `0x31` host->card, **FD35_SEEK** `0x32` card->host, as
  above; a seventh `msg_arb` source in `card_link`, below the floppy's.
- Host: `fd35 = PATH` in the configuration; the image is fenced in
  `In Use/` like the floppies'.

## It boots (2026-09-13)

The demo boots from the 3.5" drive on the IWM, from a cold reset, with no
keystroke: `gs_xmas.conf` with `fd = off`, `hd = off`, `fd35 =
disks/XMAS_DEMO.po`.  Two things in the machine's SLOTS had to go first, and
neither was in this chip.

**Slot 6 was a Disk II, and slot 6 is the IWM.**  The host makes the Disk II
card whenever a menu could later want one - `want_fd = asked || boot_menu ||
runtime_menu` - so `fd = off` did NOT mean off: the runtime menu alone put a
Disk II in slot 6, and `floppy_card`'s claim on $C0Ex is the internal IWM's
own address range, the clash docs' "Not here" section had already named.  The
symptom was that the boot failed DIFFERENTLY on each reset: sometimes the ROM
never engaged the drive at all (motor never on, `FD35_STAT` ctl = 0) and the
scan fell through to BASIC; sometimes the motor came on, the head went to
track 0, and the machine sat at the ROM 3 splash for ever.  `PR#5` from the
BASIC prompt booted the disk perfectly throughout, which is what said the
drive was not the problem.  Fixed in the host: a menu no longer conjures the
card on a IIgs (`pipeline.cpp`, `want_fd`); asked for explicitly, it is still
made, because the clash is then the user's to have.

**Slot 7 was a SmartPort with no unit.**  `hd = 7` with `hd1` empty installs
the controller anyway - "the controller answers, with no disk behind it" - and
with the battery RAM's startup set to Scan the ROM tries slot 7 first, boots
it, and hangs at the splash.  This is the same failure the bench had found
from the other side (a slot-7 ROM with no unit answered the boot read and the
ROM crashed into an empty block), which is why the bench sends none.  `hd =
off` in the GS confs until a SmartPort with zero units declines its boot.

**The instruments that answered it**, none of which needed a rebuild:
`swctl reg 0x80000138` (FD35_DRIVE: inserted, wp, stale, track, side, motor,
seeks) and `reg 0x8000013C` (FD35_STAT: fill_max, ctl = {phases, q7, q6,
drive_sel, apple35_sel}, late).  A boot the ROM never attempted reads ctl = 0
and the motor off; a boot it attempted reads the motor on and the seek count
climbing.  `accel`'s fast-by-kind census names a wait: the machine that had
"partly loaded" was 209 M keyboard reads in thirty seconds with I, RAM and ROM
frozen - a keyboard poll, not a crash.

**The false notice is gone.**  The card announced every track fill as "unknown
message type 0x31 ... is the bitstream older than this host?"  The list in
`ft601_msg_rx.sv` had been fixed at 21:59 on 09-12 and the loaded bitstream
built at 19:45, so the card in the machine genuinely predated its own fix.
Rebuilt: TIMING MET wns=+0.130, whs=+0.048, 0/94662 failing, 0 undriven, 0
multi-driven, generate scopes clean.  The notice never cost anything - the
link fans `app_msg_*` to every consumer ungated, and `hdr_known` decides only
what to report - but it buried the notices that mean something, and a card
that lies about its own messages is not a card you can debug on.

## On hardware (2026-09-12)

The first bitstream (four-lane buffer; LUTs 58.8%, 114 of 135 block RAM
tiles; TIMING MET +0.001, 0 undriven, generate scopes clean) **never
calibrated its DDR3**: the UART's `D=0 K=00` on two loads - the controller's
calibration state IDLE, which UberDDR3 leaves only when the IDELAYCTRL is
ready and the power-up sequence has run - while the IIe bit loaded between
them read `D=1` at once.  GS.md "The retained set and the DDR3" has the
precedent: the two IIgs builds that failed this way were the two largest,
with static timing clean in all of them, and the mechanism is not known
(the user's power-budget note - the Pt on the Pi's 0.9 A USB ceiling - is
one candidate, since the failures track size and not slack).  The second
bitstream (the three-tile buffer, MET +0.030, 113 tiles) failed the same
way - so not placement.  Power was ruled out on the Pi's side
(`usb_max_current_enable=1`, no over-current in dmesg).  **The control:
last night's commit 13146b4, which ran GS/OS and Arkanoid on this card this
morning, rebuilt unchanged in a worktree (MET +0.006) and loaded - `D=0
K=00` as well.**  So it is the environment of the afternoon, not the RTL of
either build: the one thing known to differ from the morning is that the
Apple was ON then (the host's status counted cycles) and appears OFF now
(the UART's cycle count sits at zero under every bit).  The card is
USB-powered, but a Pt in a slot may well take its DDR3's current from the
slot's rail when the Apple is on - the IIe bit, a third smaller, calibrates
on USB alone.  Next: the Apple on, then any of the three bits.

## The timing cuts made while the card was down (2026-09-12)

With the hardware blocked, the user asked for the long logic chains
(`build/results/logic_depth.rpt`, the DDR3's own left alone) and had two
families cut; the tools for it are new: `build/chains.tcl` (the cells of
every deep chain, `-match`, `-min`) and `build/chains_detail.tcl`
(`report_timing` per hop with fanout and route, `-to ENDPOINT`), both run on
the routed checkpoint under the Vivado work directory.  Two lessons first:
the DDR3's manual refresh gate (`ddr3_wrapper.sv` REFRESH_GATE) was turned
off by the user's decision, the controller refreshing as designed; and
identical RTL builds to different WNS run to run (+0.008 to +0.061 across
these five builds), so the census by source register is the signal, never
the number.

**Family 1, the map to the page cache.**  The way address was 12 LUT
levels at 0.03 ns: 1.6 ns of logic and 7.7 ns of ROUTE (fanout 311 into
the 64 way block RAMs, plus a 1.9 ns hop from the MMU's column to the
RAM's).  `apple_mmu.sv` now forms the whole physical page number a second
time from a three-level cone (`pf_ppn`: the page byte folds only in `$Dxxx`
of a pair bank per the registered R_LCD bit, the I/O-inhibit swap of
`$C/$D`; the bank byte from aux / the LC read and write enables / `$Cxxx`
reads as ROM / the GS pair, flat and void arms) with a simulation `$error`
against `xlate`'s answer - the cut needed BOTH bytes, since the set hash is
`ppn[6:0] ^ ppn[13:7]`.  Sweeps: IIe 33.3 M and GS 67.1 M translations, 0
mismatches, the assertion silent.  Way address 12 levels / 0.03 ns -> 7 /
1.51; directory 13 / 0.76 -> 8 / 2.06; no map-to-cache chain at 10 levels
or more remains.

**Family 2, the 65816's address generator into the data front.**  The
sequencer's state -> the late operand select -> the CPU's `din` -> the low
adder -> the high adder -> the bank's plus-or-minus-one -> the data front's
predicted address: 21 levels at 0.18 ns (bank register 20 / 0.06, the
keyboard-page compare 19 / 0.07).  Three steps, each proved on the full
SingleStepTests battery (981,610 tests) and `sim/suite.sh gs`:
(1) the high half's sum formed before the low carry, the carry choosing
between the sum and its increment - which Vivado silently undid, folding
"carry ? sum+1 : sum" back into a carry-in (the per-hop trace showed the
chain unchanged), so (2) the candidates carry `(* keep = "true" *)`, the
first such attributes in the design: after the low carry-out, two LUTs
instead of two LUTs and three CARRY4 hops; the bank register out of the
deep tail; the tail at >= 14 levels 1055 -> 244; and (3) the predicted
address's bank and high bytes each formed twice, as if the high half
carried and as if it did not, from carry-free copies of the load muxes
(`adh_nx`, `s_nx`, `bank_c/bank_nc`), and chosen ONCE by the carry
(`pred_hi`/`pred_bk` in `cpu65816.sv`, a simulation `$error` against the
plain mux).  Result (gs_predlate2): data-front address 21 levels / 0.18 ns
-> 15 / 1.12; keyboard compare 19 / 0.07 -> 15 / 0.49; bank register off
the list; the deepest chain in the design 22 -> 18 levels.  What leads the
census now is the sequencer's state into the microcode ROM read (16
levels, 0.04-0.36 ns) - the late select at the head of the CPU's cycle,
which is the design and was not touched - and the instruction front's
`exp_q -> i_byte_q` at 15 / 0.08.

## Tested by

- `tools/nib35.py IMAGE --check`: every sector of every track of the image
  encodes and decodes back (1600 of 1600 for the XMAS demo).
- `sim/run_boot_gs_tb.sh --fd35=IMAGE --instrs=8000000 --clks=120000000`:
  the demo's boot through the IWM; the milestone is the first instruction
  fetched from bank `$0E`, which is where the FTA loader puts the demo
  proper.  KEGS gets there at instruction 1,499,453 with its instant-nibble
  disk and a slot-7 firmware that jumps straight to slot 5; the card gets
  there at 3,427,317: the ROM times out on slot 6 first (a million
  instructions of the internal Disk II firmware), the platter turns at its
  real rate, and the launch is asynchronous - the loader enables the VGC
  scan-line interrupt when it has its seven sectors, and the interrupt's
  handler on the `$E1/0028` hook JSLs to `$0E/8800`.  The bench had to
  learn three things for this: the disk goes in after `boot_go` (shared
  message pins), no slot-7 ROM without a slot-7 image (the host sends
  none), and the chipset's write tap must see the SCBs (`--fd35-trace=N`
  and the "SCB write"/"VGC write"/"scan-line interrupt" lines are the
  instruments).  With `--ref=sim/boot_work/xmas/xmas.kegs.trc` the
  comparison is blind past the slot scan, as always.
- `sim/lint.sh`; `sim/suite.sh gs` (the plain boot still at its floor).
- Host `fd35_test`: the nibblizer against its own decoder on a patterned
  image, and the service's chunks for a seek.

## Not here

- **3.5" writes.**  The card drops them and the host marks every 3.5" disk
  write-protected; sense `$6` says locked.  The write path is the IWM's
  async handshake (mode bit 1, a byte per handshake) into the buffer, then
  the Disk II's dirty-track return, then a denibblizer on the host
  (`fd35_nibble.cpp`'s decoder is most of it).
- **A second drive**, eject, the disk-switched flag.
- **The 5.25" side of the chip.**  With a Disk II in slot 6 on a IIgs the
  two claims of `$C0Ex` (`gs_io`'s and `floppy_card`'s) have not been
  reconciled; the GS confs run with `fd = off`.
- **Both sides of a cylinder in the card.**  A side switch costs a refetch;
  a second buffer would hold the other side.
- **A boot menu row and a runtime-menu swap** for the 3.5" drive (the
  user's next ask).
