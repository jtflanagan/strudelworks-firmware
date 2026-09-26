# Enhanced video for the IIgs

Status: 2026-09-26, branch `enhanced_video` (fw off master 79bfd94 / host off
6f8e9e9).  Design agreed with the user.  **R0 (the memory map) DONE ON
HARDWARE** (bit `gs_evmap1`, TIMING MET wns +0.018 whs +0.030, 0 of 76940,
stamp 20260926 124715, FLASH): ROM 3 boots GS/OS 6 to the Finder; the panel
loads at $F0 (128 absolute chunks, counted by the card) and its row of
`tools/gs_cp_test.sh` passes, and so does its `nda` row (split 2026-09-26
into `nda`, the installed accessory at work, and `nda_install`, run by name
only): the reinstalled accessory loads, is the current stub, opens from the
Apple menu, its chooser ejects and inserts, R R restarts; from the monitor, stores to $80/1000, $DF/FFFC, $E2/0000
and $EE/1234 read back through the CPU and in the host mirror, and a store to
$F0/0000 is refused (still "SWCP").  Sims: lint clean, `suite quick` 36/36,
`suite gs` 18/18 (map sweep 212.6 M checks / 0).  Host tests 43/47, the four
red being master's own.  The IIe tree (rtl/a2) is not touched by this work
(user, 2026-09-26).  Found on the way: swhost's `mouseat` took `panel_mu_`
twice and deadlocked its control thread since 2026-09-16 (host 3f792ff) -
fixed.  **R1 DONE** (host src/enhanced_video.cpp): the committed state -
per-mode snapshots with dirty-page copies, AUTO at the frame point, the
global commit, RES' clearing - `enhanced_video_test` 47/47 (and mutation-
checked), host tests 44/48 (master's four red); on the live machine, monitor
writes to $E2 gave `ev=1 evlive=1 evg=1 evc=1 evr=1` on the status line and
the refusal in the log, and a RES' took it to `ev=0 evlive=0`.  **R2 DONE
ON HARDWARE** (host src/ev_render.cpp; `ev_render_test` 28/28, every canvas
pixel of a patterned bitmap against a reference, mutation-checked; host tests
45/49): from the monitor, bank $80 filled red and $81 blue, mode 0 a bitmap on
them, the top half of the claim map to mode 0 - the screenshot's top half 100%
red over the monitor's text below; green written into $80 without a commit
left it red, `E2/0010:00` turned it 100% green; a RES' took the canvas away
and the Finder came back.  Next: R3, the text and tile modes.

New video modes for the GS, drawn by the host, living beside the machine's own
video rather than replacing it.  A program writes pixels, cells or tiles into
banks $80-$DF, describes up to three modes in a control bank at $E2, and
claims 8x8 regions of the screen for them; everywhere it does not claim, the
machine's own picture (SHR, or the IIe modes) shows as it always has.

## The rules

- **Write-only.**  A mode is defined entirely by memory the program writes and
  the host mirrors from the stream.  The host never writes anything back, and
  nothing on the card knows what a mode is.  The CPU can read the banks back
  (they are RAM, R0), but no mode depends on it.
- **The canvas is 1280x800**, the SHR picture rect at 1080p (the host's
  `Compositor`, 2x4 over 640x200).  Every mode defines a whole 1280x800 image;
  at 4K the canvas scales 2x like the SHR box does.  The IIe modes' 1120x768
  picture sits inside it at (80,16), so a claim can cover that border band.
- **The legacy picture is the bottom layer.**  Wherever no mode claims a
  region, the machine's own video is drawn exactly as it is today.
- **No transparency** between a mode and what is under it (out of scope).
- **No scrolling** in the first modes; a scrolling mode is a later mode type or
  a retrofit.

## R0: the memory map is ours

Banks above $7F are the card's to define.  The "void bank" (every unpopulated
bank reading one write-protected page at $FB00, writes dropped) was KEGS's
model of a machine without the memory, and this card has it: the DDR3 image is
the 24-bit space one to one, 16 MB.  It is gone, and so is "$E2-$EE is the
extended ROM", which only existed because $F0 was avoided.

| Banks     | What                                                        |
|-----------|-------------------------------------------------------------|
| $00-$7F   | RAM, the machine's (the ROM sizes it; sizing stops at $80)  |
| $80-$DF   | RAM, ours: the enhanced video banks                         |
| $E0/$E1   | the Mega II                                                 |
| $E2-$EF   | RAM, ours: $E2 the video control bank, $EF the panel's RAM  |
| $F0-$FF   | ROM space, identity-mapped, read-only: ours from $F0 (the   |
|           | panel), the machine's ROM at its top ($FC for a ROM 3)      |

- Shadowing-in-all-banks ($C036 bit 4) stays below $80: our banks are not
  RAM the ROM sized.
- The panel (host `firmware/gspanel`) moves from $E2 to $F0; its RAM and
  mailbox stay at $EF.  Absolute MEM_ROM chunks (rom_loader) take $F0-$FB.
- **The NDA stub installed on a GS/OS disk before R0 looks for "SWCP" at
  $E2/0000 and must be reinstalled** from the new build.
- Proof on hardware: the panel runs from $F0, ROM 3 boots unchanged with our
  image at $F0, and a write to bank $80 reads back.

## The control bank, $E2

| Offset        | What                                                       |
|---------------|------------------------------------------------------------|
| `$0000`       | ENABLE: bit 0 turns the compositing on                     |
| `$0001`       | GLOBAL COMMIT: any write latches ENABLE and the claim map  |
| `$0010+32*n`  | mode n's descriptor, n = 0..2 (claim values 1..3)          |
| `$1000-$1F9F` | the claim map                                              |
| `$4000`, `$8000`, `$C000` | mode n's 16 KB control window                  |

A descriptor:

| Byte   | What                                                           |
|--------|----------------------------------------------------------------|
| `+0`   | COMMIT: any write commits this mode (below)                    |
| `+1`   | mode type, 0 = off                                             |
| `+2`   | flags: bit 0 AUTO (the host commits this mode every VBL)       |
| `+3`   | first bank ($80-$DF)                                           |
| `+4`   | bank count                                                     |
| `+5..` | the mode's own parameters                                      |

The host validates a descriptor at its commit: the banks must lie in $80-$DF.
A bad one turns that mode off and is logged once.  Two modes may name the same
banks.  Banks are allocated by the program, not by anything here.

**The claim map**: 160x100 regions of 8x8 canvas pixels, 2 bits each, 40
bytes a row, 100 rows.  The leftmost region of a byte is bits 7:6 (SHR 640
order).  00 is the legacy picture; 01, 10, 11 are modes 0, 1, 2.  A region
claimed by a mode that is off or has never committed shows the legacy picture.

## Commit: the host flips the pages

There is no page 1 / page 2 in the machine's memory.  The program draws into
the one live copy, and the host keeps what is shown:

- **Live**: the host's mirror, written by every streamed write.
- **Committed**: per mode, the host's own copy of the mode's banks and its
  control window.  The renderer reads only this.

A write to a mode's COMMIT is acted on at its place in the stream, on the
decode thread: the mode's live state is copied to its committed state, so the
snapshot holds every write before the commit and none after.  Only pages
written since the mode's last commit are copied (a dirty bit per 256-byte page
per mode); the first commit, or one that changes the mode's banks, copies all.
A mode's 1280x800 layer is re-rendered only when its commit count moves, and
the compositor puts the latest layers over the legacy frame at display rate.
AUTO commits the mode at every IIgs VBL, for a program that does not want to
manage commits.  The global COMMIT does the same for ENABLE and the claim map.

Every RES' and every swhost start clears ENABLE and every committed state on
the host.

## The first modes

Pixels are RGB565, little-endian (a 16-bit store writes one pixel): bits
15-11 red, 10-5 green, 4-0 blue.  What fits in the 16 KB control window goes
there; what does not goes in the banks.

**1 - Bitmap 320x200 RGB565, 4x** (2 banks).  Rows 0-99 in the first bank,
100-199 in the second, 640 bytes a row from offset 0 (no row crosses a bank).

**2 - Text 160x100, 8x8 glyphs** (1 bank, 1:1).  Cell (c, r) at
`2*(r*160 + c)` in the bank: the glyph byte, then the attribute byte (high
nibble the foreground index, low nibble the background index), so one 16-bit
store writes a cell.  Control window: the font at `$0000`, 256 glyphs x 8
rows, bit 7 the leftmost pixel; the 16 foreground colours at `$0800` and the
16 background colours at `$0820`, RGB565.

**3 - Tiles 80x50, 16x16** (1-96 banks, 1:1).  The map at the front of the
first bank: cell (c, r) at `2*(r*80 + c)`, a 16-bit tile index, $0000-$1F3F.
The tiles from `$2000`: tile n at byte offset `$2000 + 512*n` from the first
bank's start, i.e. bank `first + ((($2000 + 512*n) >> 16)`, 16 rows of 16
pixels.  A tile never straddles a bank; the first bank holds 112, every other
128 (12,272 over all 96).  An index past the mode's banks draws black.  No
control window.

## Where the host does the work

- The mirror ($80-$DF and $E2 writable, R0) and the dirty pages: `AppleMemory`.
- The commits: the decode thread, at the COMMIT's place in the stream.
- The rendering: a CPU renderer on its own thread, from committed state, so
  the decode thread (the bottleneck under acceleration) pays only for the
  copies.  It is testable in `swlink` against golden images and a
  `screenshot` keeps working.  A GPU decode is an optimisation for later, if
  measured to be needed.
- The composite: the existing GLES compositor, the claim map as a 160x100
  mask texture choosing between the legacy texture and the modes' layer.  No
  scanline effect on claimed regions.

## The risk to measure first

A full-screen RGB565 redraw is 128,000 byte writes, one 8-byte record each:
about 1 MB of stream a frame, 7.7 M records/s at 60 fps.  The card's merge
drains about 33 M records/s, so the card is not the limit; the Pi's decode
thread might be (full capture already saturates it under acceleration).  The
text and tile modes write only what changes.  If the bitmap rate is poor, the
fallback is docs/DDR3_USAGE.md's "Video: snapshot, do not stream": the card
holds the banks since R0, and the host pulls a committed mode's dirty pages
instead of receiving every write.

## Rungs

- **R0** - the memory map above: card (`apple_mmu`, `rom_loader`, the GS
  tree only), host (`classify_gs`, the ROM patch's entry range, the panel's send),
  the panel relinked at $F0, the benches and tests on the new map, a bit, and
  the hardware proof.
- **R1** - the host mirror of the video banks, dirty pages, COMMIT / AUTO /
  the global commit, the reset clearing; unit tests.  AUTO commits at the
  host's frame point (emit_frame, the beam entering blanking), which on a
  IIgs is every frame of real bus time.  The status line carries `ev=`
  (ENABLE latched), `evlive=` (bit n = mode n drawn), `evg=` / `evc=` (global
  and mode commits) and `evr=` (refusals).
- **R2** - the renderer thread, the compositor's mask, mode 1; golden-image
  tests.  As built: EvCanvas (its own thread, woken every 2 ms to look at the
  generations) copies a mode whose generation moved out from under the
  commits' lock, draws it into a 1280x800 RGB layer, and puts the layers
  together through the claim map into one RGBA canvas; the GL thread uploads
  a new canvas when there is one and draws it over the Super Hi-Res box
  after the legacy pass, discarding alpha 0 - so the legacy frame, scanlines
  and border included, is untouched wherever nothing is claimed.  A
  screenshot reads the panel back, canvas included.
- **R3** - modes 2 and 3.
- **R4** - a 65816 test program (llvm-mos, as the panel) on hardware: all
  three modes at once over the legacy desktop, and the bitmap throughput
  measured.
