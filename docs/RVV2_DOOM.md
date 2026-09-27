# DOOM on the RISC-V engine

Status: **2026-09-27, branch `riscv_v2`. DOOM RUNS ON HARDWARE: launched from the Finder off its own
volume (hd2), the title, the demo loop at 35 frames a second (DOOM's own tic rate), the menus and a new
game driven from the keyboard's raw ADB events, and a held arrow walks the marine (D1-D5 done; the
key-loss fix below proven on hardware: every down and up of Esc, three Returns and an arrow arrived).** The SPLASH milestone is done on hardware
(docs/RVV2_INTEROP.md): a GS/OS application whose program runs on the engine in the upper 16 MB,
reads files through GS/OS, calls the toolbox, takes keys and draws on enhanced video. DOOM is the
next goal: the shareware DOOM1.WAD, launched from the Finder, played from the keyboard, drawn on
enhanced video mode 1. Decisions marked *(user)* were the user's, 2026-09-26.

## The base: doomgeneric

`ozkl/doomgeneric` (GPL-2.0, a sibling checkout at `../doomgeneric`): Chocolate Doom's engine behind
six platform functions - `DG_Init`, `DG_DrawFrame`, `DG_SleepMs`, `DG_GetTicksMs`,
`DG_GetKey(pressed, key)`, `DG_SetWindowTitle` - and the C library for everything else (stdio for
the WAD, malloc for its 6 MB zone, strings, a little floating point: soft float on rv32im). Built
with `CMAP256` its screen is 8-bit indices into a 256-colour palette, 320x200.

## The pieces

- **The C library**: picolibc (`sim/build_rvvm_picolibc.sh`, built for exactly our ISA, PIC), with
  librvgs underneath its system calls: `open/read/lseek/close` on GS/OS through the bounce buffer
  (adding SetMark/GetMark), `sbrk` over the application's upper-half heap, the console discarded,
  `exit` through the runtime's lifecycle.
- **The WAD** *(user: a second .hdv)*: a DOOM volume as SmartPort unit 2 (`hd2 =` in the conf -
  the host already serves units 1-8), holding `/DOOM/{DOOM, DOOM.RV, DOOM1.WAD}`. DOOM1.WAD is
  4.2 MB, a ProDOS TREE file: the host's `prodos_fs` writes seedlings and saplings (to 128 KB)
  today and needs tree files (a master index block over index blocks) to build the volume.
- **Keys** *(user: from the ADB itself, not the Event Manager, which reports no releases)*: the
  ADB keyboard's own events. Our ADB micro (`rtl/gs/gs_adb.sv`, KEGS's model) keeps them apart from
  the ASCII queue `$C000` reads: register 0, `{is_up, keycode}`, from both the Pi's keyboard and the
  IIe's (`rtl/gs_kbd_a2.sv`), drained by the micro's Talk-register-0 command for the keyboard. The
  firmware never asks for it (it takes ASCII), so a program can own the stream. The runtime asks
  through the ROM's ADB Tool Set (tool 9) with a completion routine of its own in `$F1` - 65816
  code, not a RISC-V callback - that puts the events in the low block; librvgs hands them to
  `DG_GetKey` as DOOM keys.
- **Video**: each frame's 8-bit screen through the palette to RGB565, into mode 1's banks, and a
  commit; the palette change DOOM makes (damage, pickups) is a new table. Measured: frames a second.
- **Time**: `DG_GetTicksMs` from TickCount (60 Hz; DOOM's game runs at 35 tics a second).

## Rungs

| # | What | Proves |
|---|------|--------|
| D1 | doomgeneric built for the engine with picolibc and librvgs's system calls; run in sim to its first frame | the port: libc, the WAD read through GS/OS's stand-in, the zone in the upper half |
| D2 | the DOOM volume: tree files in `prodos_fs`, a builder for `doom.hdv`, `hd2` in the conf | the WAD where GS/OS reads it |
| D3 | raw ADB keys: the runtime's Talk-R0 service, librvgs's key events, `DG_GetKey` | presses and releases, both keyboards |
| D4 | the frame on enhanced video, frames a second measured | DOOM's title and demo loop on the card |
| D5 | playable on hardware from the Finder | the goal |

Later: sound (the Ensoniq, or the host), speed (the engine's own), misaligned access in the engine if
DOOM needs it (it is compiled for strict alignment first).

## As built (2026-09-27)

- **D1** - `apple/rvvm/doom/`: `app.mk` builds doomgeneric's sources (the upstream list, less its
  platform files) with `CMAP256`, 320x200, on picolibc; `doom_rv.c` is the platform. librvgs's POSIX
  layer (`apple/rvvm/guest/rvgs_posix.c`): `open/read/lseek/close` on GS/OS (SetMark/GetMark added),
  `sbrk` from the image's end to the stack (the stack's size read from the program's own image
  header), the console a line at a time to ECALL write (the runtime discards it without reading it -
  it may lie in the upper half; the bench shows it as `guest|` lines), `rename/mkdir/unlink` fail as on
  a read-only disk, no processes. DOOM.RV is 445 KB, all 1,634 relocations R_RISCV_RELATIVE. In sim
  (`sim/run_rv_app.sh doom`, the WAD served by the stand-in) it initialises completely - W_Init reads
  the WAD's directory through GS/OS ("DOOM Shareware"), R_Init builds the refresh tables, the 6 MB zone
  sits at `$010E_4310` - and draws frames, about 3M cycles (30 ms at 100 MHz) apart. The bench's
  TickCount runs at the card's real rate (60 a second of a 100 MHz clock) so DOOM's own time is the
  card's; the case ends at the first frame that is TITLEPIC through the first palette
  (`--stop-at-video`).
- **D2** - the host's `prodos_fs` writes tree files (to 16 MB; `tests/prodos_test.cpp`: 128 KB + 1,
  a 5 MB file read back, the 16 MB refusal); `apple/rvvm/make_disk.sh --image doom.hdv --volume DOOM
  --blocks 65535 --apps doom` builds the volume.
- **D3** - raw ADB keys: the runtime's completion at `$F1:0040` (called as ROM 03's ADB interrupt calls
  an AsyncADBReceive completion, read off `$FC/DB0F`: 8-bit, a long pointer to the answer) appends
  each `{is_up, keycode}` to a ring at `$EE:0400` (head `$EE:0300`, tail `$EE:0302`, request
  outstanding `$EE:0304`), reset at every entry; librvgs's `rvgs_adb_event()` asks (AsyncADBReceive
  `$0D09`, command `$C2`) when the ring is empty and hands out events; `doom_rv.c` maps keycodes to
  DOOM keys - arrows and modifiers by keycode, the rest by the ADB micro's own plain ASCII
  (`tools/adb_ascii_h.py` from `rtl/gs/adb_keymap.hex`). In the bench the stand-in answers the micro
  from `--adb-events` and calls the RUNTIME'S OWN completion through a shim, as the ROM would; RVTEST
  checks A and Esc down and up arrive.

- **D4, on hardware** (bit `master_top_gs_20260926_204712`, `rv2_doom.conf` = `rv2_gsos.conf` +
  `hd2 = disks/doom.hdv`): DOOM from the Finder, TITLEPIC, then the demos - 490 frames in 850 ticks
  (14.2 s) = 34.6 frames a second, DOOM's ceiling of 35 tics a second; the first ~270 frames (the title
  page) run at 60.
- **D5, on hardware**: Esc opens the menu, Return steps New Game - episode - skill into E1M1. A
  quarter of the key events were LOST: the runtime's counters and answer log (below) showed every ask
  answered and one answer `[1, $35]` for Esc down - its up never came. ROM 03 hands an ADB answer over
  as the micro's status bits ($FC/DB36): the count byte is the bytes LESS ONE, and a Talk register 0 is
  always two bytes, `[1, first event, second or $FF]`. The completion read one byte, so the second
  event of a Talk that held two (a down and its up 16 ms later, often) was dropped. The bench's
  stand-in wrote the count as 2 - the same misreading - so it passed; it now answers as the ROM does,
  and RVTEST's two-event answers fail the old completion (mutation-checked). With the fix, on
  hardware: `35 B5 24 A4 24 A4 24 A4 3E BE` - every event, no refusals, no requests given up on - and
  Up held between two host commands walks the marine forward in E1M1 (a down and its up inside one
  Talk arrive in one tic and do nothing, as on any keyboard).
- **Fire and use**: doomgeneric binds fire and use to keys of its own (`KEY_FIRE`, `KEY_USE`,
  m_controls.c), not to right control and space as DOOM does, and no config file rebinds them - so
  `doom_rv.c` sends Control as `KEY_FIRE` and Space as `KEY_USE`. On hardware Control fires (50 -> 45).
  The keys: Control fire, Space use, arrows move, Shift run, Option/Command strafe, Esc menu, Return
  select, Tab map, digits weapons.
- **What the key path shows the host** (bank $EE): `$306` completions (low byte), `$308` the last
  count, `$30A` the log's next place over 256 bytes of answers at `$500` ({count, bytes} end to end),
  and librvgs's `$30C` asks, `$30E` refusals, `$310` the last refusal, `$312` requests given up on.
  On hardware every ask is answered (the ROM completes an empty Talk with count 0), about 85 a second
  while DOOM runs.

## Open

- How fast a sim run reaches DOOM's first frame on the application bench (the engine and the 65816
  in Verilator); a faster bring-up path - the reference model running the program with the runtime's
  services emulated at the ECALL - may be worth building for the port's iterations.
