Status: 2026-09-12, branch `gs_emulation`. BENCH: the XMAS demo boots from
the drive and LAUNCHES (bank $0E at instruction 3,427,317 of
`sim/run_boot_gs_tb.sh --fd35=XMAS_DEMO.po --instrs=8000000 --clks=120000000`,
17 tracks fetched, 0 late); `sim/lint.sh` clean; `sim/suite.sh gs` 11/11 with
its boot at the floor; the 65816 battery 981,610 tests 0 failed. HARDWARE:
every IIgs bitstream today, a control rebuild of last night's commit
included, fails DDR3 calibration - not this work, see "On hardware".
Latest build gs_predlate2: TIMING MET +0.008, 0 of 94,744, gates clean,
after the timing cuts below (kept alongside: gs_agukeep at +0.061 as
`build/results/master_top_gs_agukeep.bit`). Host fd35_test 335/335 on the Pi.

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

- **Writes.**  The card drops them and the host marks every disk
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
