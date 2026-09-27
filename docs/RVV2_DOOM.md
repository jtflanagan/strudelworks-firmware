# DOOM on the RISC-V engine

Status: **2026-09-27, branch `riscv_v2`. DOOM PLAYS ON HARDWARE WITH SOUND, MUSIC AND THE MOUSE:
launched from the Finder off its own volume (hd2); keys from the raw ADB events, the mouse through the
Miscellaneous Tool Set; effects and music (Chocolate Doom's OPL player on DBOPL) mixed on the engine
and played by the IIgs's Ensoniq in stereo - judged good by ear (user). Drawn in enhanced video's
mode 4 (8-bit indexed): at DOOM's cap of 35 frames a second in E1M1 with music, dipping in heavy
scenes (DEMO1 uncapped: median 38.7 fps, the worst frames ~50 ms). D1-D5, S1-S3, M1 and MU1 done.**

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
- **Frame rates on the screen**: DOOM draws "RV dd.d" in the picture's top right corner - the frames it
  committed over the last whole second of TickCount (a true 60 Hz on the card: 604 ticks in ~10 s of
  wall clock), also at `$EE:FE10` in tenths; drawn from the first whole second on, so frame 1 stays
  DOOM's own (the bench's TITLEPIC). DOOM paces itself at 35 tics a second: ~35 in play, above it now
  and then (a frame without a new tic), ~60 on the title page. The host's HUD shows "FPS 60.0" - the
  Pi's on-time refreshes (the host's apple_app.hpp).
- **What the key path shows the host** (bank $EE): `$306` completions (low byte), `$308` the last
  count, `$30A` the log's next place over 256 bytes of answers at `$500` ({count, bytes} end to end),
  and librvgs's `$30C` asks, `$30E` refusals, `$310` the last refusal, `$312` requests given up on.
  On hardware every ask is answered (the ROM completes an empty Talk with count 0), about 85 a second
  while DOOM runs.

## Sound and the mouse (rungs S1-S3, M1)

*(user, 2026-09-27)*: the effects mixed on the engine and played by the IIgs's own Ensoniq; music
later. The mouse the IIgs's, as GS/OS keeps it.

- **The DOC, as the card has it** (`rtl/gs/gs_doc.sv`, KEGS's `doc.c`): in wall time whatever the
  acceleration, the GLU at core speed; a `$00` byte stops a voice; each voice on one side (control bit
  4: set is the right) - so the effects are stereo, a player a side. The accumulator is not readable:
  where the players are is known by a timer's interrupt, not read.
- **Owning voices under GS/OS** - HyperCard IIgs's way: the Sound Tool Set (tool 8, in the
  application's tool list, StartUpTools starting it) keeps the DOC's interrupt; the runtime claims two
  generators it is not using (FFGeneratorStatus `$1108` = 0; SetDOCReg `$1708` writes the type,
  `$08`, and programs the pair halted - its block read off ROM 03 `$FC:D273`: generator word, then
  freq lo, hi, volume, table, control, size per oscillator), installs its vector (SetUserSoundIRQV
  `$1308`; the handler calls it for a type not its own: 8-bit, A the type, CLC RTL) and plays the
  oscillators directly through the GLU. Numbers read off the live function table (tool 8 at
  `$05:8266` under System 6.0.1, FFStartSound patched into RAM - the rest ROM). Generator g's pair is
  ROM 03's table `$FC:CE5E` (0, 16, 8, 24, ...) and the next.
- **The players and the timer**: generator A's pair play 2 KB rings in DOC RAM (`$F000` left, `$F800`
  right: 8 segments of 256) free-running; generator B's first oscillator plays 256 bytes of silence
  (`$E000`, volume 0) free-running with its interrupt on. All at frequency 429 with the resolution one
  above the table's (26320 Hz scans with 32 oscillators: 11026.8 Hz, 0.42 bytes a scan): the timer
  ends exactly every 256 samples the players play - one clock, no drift - and each interrupt the
  runtime (`snd_irq`, `$F1:0044`) copies the next chunk, left and right, into the segment SND_LEAD (3)
  ahead of the players, or silence when none is ready. The runtime's service (`$F1:0048`, call65816:
  on/off) sets all this up and takes it down; the lifecycle's undo turns it off however the program
  ends (D_SND), before ShutDownTools.
- **The chunks** (librvgs `rvgs_snd_*`): 16 a side in `$EE:1000`/`$EE:2000`, counted by SND_HEAD (the
  program's) and SND_TAIL (the interrupt's) at `$EE:0320`; the engine's writes kill the 65816's L1-D
  rows (rtl/gs/l1d.sv), so the interrupt reads them fresh. The program mixes by the ring's room - the
  DOC's clock paces it; 11026.8 Hz is not 11025, so nothing else may.
- **DOOM** (`apple/rvvm/doom/snd_rv.c`): doomgeneric's sound module (FEATURE_SOUND; an empty
  SDL_mixer.h for i_sound.c's include; a music module that plays nothing): eight channels of the WAD's
  DS lumps as they are (11025 Hz, the DMX padding skipped), volume and separation by SDL's rule, the
  mix clamped to never $00, SND_AHEAD (3) chunks ahead - from each tic's Update and from DOOM's sleeps.
  Latency: up to ~140 ms (3 DOC segments + 3 chunks) - judged good by ear.
- **On hardware**: generators 14 and 13 claimed, ~43 interrupts a second, the mixer 2-3 chunks ahead,
  silence only before DOOM's loop mixes (start-up); left and right as KEGS's channel bit (set = the
  right) - correct by ear, whatever Tech Note #19 says of stereo cards.
- **The mouse** (M1, `doom_rv.c`): ReadMouse `$1703` (mode, status - bit 7 the button - y, x; ROM 03
  `$FE:B0AC`) and PosMouse `$1E03` (x pushed first) back to (160,100) after every move; the moves add
  up and go to DOOM once a tic (G_Responder SETS the motion from an event), a button change at once.
- **The bench**: the stand-in answers FFGeneratorStatus, SetDOCReg (the DOC's registers written as the
  ROM would), SetUserSoundIRQV, ReadMouse and PosMouse; the GLU is modelled (DOC RAM and registers, auto-
  increment); while a timer runs, a shim calls the runtime's vector every 256 samples of the DOC's clock
  as the Sound Tool Set would; RVTEST mixes 12 numbered chunks and `--expect-sound` checks every
  interrupt's 512 writes - the pages SND_LEAD ahead, the chunk whole and in order, or silence - and that
  each launch ends with the vector back, the generators given back and the timer halted.

## Music (rung MU1)

DOOM's music is MUS - MIDI-like - played on an OPL2 with the WAD's GENMIDI instruments. *(user)*: do
the music; the route is the effects' - made on the engine, mixed into the same chunks, played by the
Ensoniq - so its clock is the DOC's too.

- **Whose code**: Chocolate Doom's OPL player (`src/i_oplmusic.c`, with `midifile.c`, doomgeneric's
  `mus2mid.c`) and OPL library (`opl/opl.c`, `opl_queue.c`) with DOSBox's DBOPL (`opl/dbopl.c`), from
  the sibling checkout `../chocolate-doom` at the tag `chocolate-doom-2.2.1` - the last with DBOPL:
  integer, and made at any rate, so at the DOC's 11026.8 Hz directly (3.0's Nuked OPL3 runs at 49716 Hz
  internally, several times the cost). Compiled from there unedited (`apple/rvvm/doom/app.mk`):
  `-Dmusic_opl_module=DG_music_module` makes the player doomgeneric's music module,
  `-Dopl_sdl_driver=opl_rv_driver` makes ours OPL's only driver.
- **The driver** (`opl_rv.c`): Chocolate Doom's SDL driver without SDL - the callback queue timed in the
  samples made, the two timers modelled (OPL_Detect), DBOPL at the DOC's rate; the mixer asks for each
  chunk's samples (`opl_rv_fill`), running each callback at its sample. OPL_Delay's wait (a condition
  variable the SDL thread would signal) runs the next callback at once (`compat/SDL.h`: one thread, the
  mutexes nothing) - only detection waits.
- **What else it needed**: `/tmp/` in the program's own memory (librvgs's `rvgs_posix.c`: the player
  writes the song as a MIDI file and reads it back); `compat/SDL.h`, `SDL_endian.h`, `SDL_mixer.h`
  (Chocolate Doom's own headers are found first by its files: they match doomgeneric's where it
  matters - the music module's struct identical, `boolean` 4 bytes either way).
- **The mix** (`snd_rv.c`): the OPL's 16 bits x MUS_GAIN (20) into both sides, the effects at
  SFX_GAIN/4 (3/4); DOOM's music volume is the player's (its channel levels). DBOPL peaks ~800-1400 at
  the default slider (DOOM's report `$EE:FE14` writes, `$EE:FE18` the second's peak): >> 8 was
  inaudible, x8 quiet, x20 with the effects at 3/4 a good balance by ear (user); the loudest passages
  reach the clamp - louder needs the DOC's level at the host (docs/AUDIO.md), not more gain here.
- **On hardware**: the title's and the demos' music heard (user). The cost: 29.5 frames a second in
  the demos against ~35 without music - DBOPL takes about a sixth of the engine. The mix is topped up
  after every frame as well as in DOOM's sleeps (a busy DOOM seldom sleeps: ~0.5% silent chunks before).

## Speed (2026-09-27)

- **Where the engine's time goes** (`sim/profile_doom.sh`, new): DOOM built to warp into E1M1, or
  with `--demo` to play DEMO1 as fast as it draws (`-timedemo`: a tic a frame, no cap), run on the
  application bench; every clock charged to the oldest instruction not yet retired (the runner's
  `--profile`: its stalls and the 65816's service of its events land on it), summed by function from
  the ELF; `--frame-log` gives each frame's cycles.
- **Found, E1M1 with music** (31 fps in sim, 29.5 on the card): the renderer 58%, getting the frame
  out 23% (the RGB565 conversion and stores 16.6%, doomgeneric's copy of each frame 5.9%), the music
  4.6%, TickCount 4.2%, the effects' mix 2%. Not floating point: DBOPL's floats are its tables at
  set-up.
- **Done**: *(user)* an 8-bit indexed enhanced video mode, **mode 4** (docs/ENHANCED_VIDEO.md; the
  host's renderer): DOOM's frame as it draws it - 16,000 stores a frame of four indices, the palette
  (256 x {R, G, B, 0}, a full 8 bits a channel) only when DOOM changes it. And doomgeneric's copy
  gone: DG_ScreenBuffer is pointed at DOOM's own frame, librvgs's memcpy returns at once for a copy
  onto itself (memset a word at a time too). Frame out 16.6% -> 5.1%; E1M1 with music at DOOM's cap
  (36.7 frames a second in sim's window, 35 on the card - "quite a bit better", user).
- **DEMO1, uncapped** (6 s of the card, 224 frames): median 25.8 ms (38.7 fps); 60 frames over the
  28.6 ms tic, 24 over 33 ms, the worst ~50 ms - the dips. There the music is ~12% (the demo's song
  keeps more OPL voices busy), TickCount 7%, the effects' mix 3.6%, stdio's byte-at-a-time fread of
  the WAD ~3.5%.
- **Not done**: *(user)* reading ticks without calling the toolbox (a heartbeat task counting into
  $EE was built and taken out: no toolbox call is to be replaced so that GS/OS never sees it).
  Still open: the WAD's reads straight to `read()`, the effects' mix by channel, the music's rate.

## Open

- How fast a sim run reaches DOOM's first frame on the application bench (the engine and the 65816
  in Verilator); a faster bring-up path - the reference model running the program with the runtime's
  services emulated at the ECALL - may be worth building for the port's iterations.
