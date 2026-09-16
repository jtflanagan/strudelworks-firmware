# The GS Strudelworks Control Panel: our panel in front of the IIgs's own

Status: 2026-09-16, branch `gs_control_panel` (fw off master 67eed4e / host off 5245bdc). **R7 (the desk accessory's way onto a GS/OS disk) is built and on hardware — see R7 below.** **THE LADDER IS FINISHED: R0-R6 ALL PASS ON HARDWARE** (bit `gs_ddr3pin`, TIMING MET wns +0.053 whs +0.045, 0 of 98182; `tools/gs_cp_test.sh` rows columns, colours, type, slots and panel). Our panel is what the machine's Control Panel now IS: it runs on the card's own 65816 out of bank `$E2`, says "strudelworks host is answering", draws the host's real state with the class that says when each setting bites, moves the host's accelerator target from inside the machine and back, shows a refusal as a refusal, and keeps Apple's own panel one Return away in both directions. Two things found on the way and written up below: the PANEL_DMA reply that carried the last disk block (and the bench that passed it twice), and a MET bitstream whose DDR3 never calibrated because the placer had pushed the island out of its clock regions (docs/UBERDDR3.md).  R0 IN SIM: llvm-mos-65816 pinned, `sim/run_gspanel.sh` runs the panel on the card's own 65816 - self-test PASS and v0 (`assets/gspanel.bin`, C) PASS with one stock-panel chain.  R0B ON HARDWARE (bit gs_bram1, fw 2026-09-15 13:05:30, TIMING MET wns +0.076 whs +0.067 fail 0/97633, SRAM): the card's battery RAM readable (debug pair `$C0+k`, GS_CLOCK_STAT 0x154), host `bram [dump]` four-copy report + follower fixes - all four copies agree on the machine (sealed $0B5E, 0 differ); lint clean, `suite gs` 13/13, `suite quick` 31/31, host tests 41/41; the expected-effects table established from the ROM.  Tooling: `screen attr` + MCP inverse marks (text_test 51/51, swmcp 37/37), `tools/gs_menu.py` walks menus by the inverse run.  **2026-09-15: `tools/gs_cp_test.sh` row 1 (Display > Columns, $19) PASSES ON HARDWARE** (bit gs_romhold1, fw 2026-09-15 15:46:49, TIMING MET wns +0.023 whs +0.032 fail 0/97606; the depth tail >= 14 rose 413 -> 559, not yet examined) - the save lands in all four copies; warm reset 80 columns (CSW $C307, $04FB $09); cold reset boots ProDOS 8 in 40 with the setting kept (KEGS does the same with the same 256 bytes); swhost restart then warm reset 80.  On the way: **swhost's exit wrote accel mode 0 under a running GS and ran it off the IIe bus** (the "self-test"/LoRes buzz).  USER RULE: a GS is accel mode 2 with serving on, always - enforced in the host (exit, socket, levels, startup, conf) AND at GS = 1 on the card (both tied; the 65816 held in reset out of a card reset until its ROM has landed).  swhost no longer pushes a landed ROM into a running GS (a push under a running core is the leading, unproven suspect for test E2's runaway; `gs_rom_repush = on` forces it).  The HDMI keep-alive now covers the audio buffer's refill.  The boot beep's scratch is the unlimited target ignoring the ROM's own 1 MHz request (traced) - SHELVED (user).  suite gs 14/14, suite quick 31/31, host tests 41/41.  **The clean start and the never-wedge work are DONE since** (fw ebb96ef / host fbf9f96, docs/CLEAN_START.md CS1-CS7, GS bit `cs16`, fw 2026-09-15 17:41:17, TIMING MET wns +0.010 whs +0.043): a formal ROM load with an ack and a sum per chunk, RES' held at every card reset and every Apple reset until the host's checklist passes, and a link that recovers over itself - LINK_RESET decoded in the parser, the drain/CLKOUT/TX-stall watchdogs, swhost's exit 75 and the launchers that run a whole clean startup on it, none of it needing the UART.  `tools/clean_start_test.sh` PASSES on hardware: 20 swhost restarts with no ROM pushed into a running machine, 20 socket RES' pulses with 20 holds and 20 checklists passed, and the link-reset recovery (512 chunks acked, sum verified, the FT601 re-enumerating, no reload).  **2026-09-15: the ladder's colour rows PASS ON HARDWARE too** (`tools/gs_cp_test.sh`, 0 failures over all four rows) - Display > Text ($1A), Background ($1B) and Border ($1C) set on the stock panel, their effect read out of $C022 and $C034 AND out of the painted frame, and carried through a warm reset, a Ctrl-Command-Reset and a swhost restart.  Host-only, on the same bit (`cs16`), and landed as (fw 09265da / host 1a465a5): the status line gained `tcol=`/`border=` and the tests gained `tools/png_pixel.py`.  **R1 and R2 ARE DONE AND ON HARDWARE since** (fw b1ae276 / host ef39819, GS bit built 2026-09-15 22:08, TIMING MET wns +0.007 whs +0.055 fail 0/98115): the card's banks $E2-$EE mapped as ROM with $EF as their RAM, an absolute MEM_ROM chunk that fills them without disturbing `rom_ok`, and `peek E20000` reading **"SWCP"** - our panel resident in a bank no IIgs has.  Next: R3, the ROM patch and panel v0.  **And row 5, Display > Type ($18), PASSES the same way** - but only after the host was taught what the setting does at all: nothing on the machine's side was missing, the PICTURE was, so this row is a host video feature and not only a test.  **And the slots row ($21-$27) with them** - the ownership question turned out to be settled already, and in the code: the conf owns them because only the host knows which slots have a card in them, so the row tests what the machine really does with a panel slot choice rather than asking for a decision.  `tools/gs_cp_test.sh` now takes a row name, so a row costs a row's time (72 s) instead of the whole ladder's (20 min).

## Context
On the IIgs build every card/host setting (disk images, accel, video, slot cards) is changed by
editing a .conf and restarting swhost. The IIe's host-drawn boot/runtime menus do not work on
the GS (kbd_inject substitution masked at GS=1, no ADB hotkey, apply path never rebuilds
GS_BRAM). Goal: an in-machine panel entered through the IIgs's own Control Panel, running our
65816 code (LLVM C + asm stub) from card-internal extended ROM, asking the host for data and
changes through a service port, chaining to the stock ROM panel for the stock options.

## Decisions (user, 2026-09-15)
- Stock options: CHAIN to the ROM's own panel (one item runs it unchanged; no reimplementation).
- First-cut entries: Ctrl-OA-Esc CDA menu + Ctrl-Option-Reset boot menu.
- C toolchain: llvm-mos-65816 fork (Apache-2.0). Patch point: FF/8FAC (catches both entries).
- Merge `woz_support` to master in both repos first, then branch `gs_control_panel` (lock-step)
  off master. The plan lives in the repo as `docs/GS_CONTROL_PANEL.md`.

## Verified facts the design rests on
- **Patch**: file offset 0x38FAC = `AD 15 C0 48` (LDA $C015/PHA) → `5C lo hi E2` (JML). Only
  referrer of 8FAC is the $E1/0090 vector (FF/7C74); nothing branches into 8FAD-8FB0. Stock
  panel contract = one byte pushed at 8FAF, exit `PLA / BMI / STA $C006 / RTL` (FF/90E5), needs
  D=0, DBR=0. Chain = JSL to `LDA $00C015 / PHA / JML $FF8FB0`, its RTL returns to us.
  Desk Manager (FE/D467): M=X=1, DBR=0, runs the CDA on page 1 (S≈$01FB, ~200 B free, page 1
  restored after). Boot menu (FF/F915): native M=X=1 from emulation code; after our RTL only S
  balance + D=0 matter. **Self-test checksum: COMPENSATED, not bypassed** (user,
  2026-09-15) — see R3.
- **Space**: every void bank ($80-$DF, $E2-$FB) reads physical bank $FB on the card; ROM 3
  probes $F8/0000 for "ROMTOOLS"; $F0 = ROM-disk convention ⇒ use **$E2-$EE ROM, $EF RAM**.
  ROM sizing stops at $80, KEGS maps nothing there.
- **Mailbox transport**: fast writes survive SPARSE (event_merge.sv:152 keeps all but
  `fast_quiet`), so a request block written to $EF is in the host mirror before the doorbell
  write arrives — the HD write path already relies on this (pipeline.cpp:4143-4149). Answers
  must come by override DMA (the loader seam is unsafe for RAM: dline ignores posted writes in
  its splice, dline.sv:258-260).
- **Toolchain**: only package is `llvm-mos-65816_0.0.0+git20260914.f9711be_amd64.deb`
  (apt.indri.studio); lld writes 16-bit operands with the bank byte dropped, so code at $E2xxxx
  and data at $EFxxxx link. SDK's `call-indir.S` (`JMP (abs)` via bank 0) requires D=$0000;
  SDK crt0 copy-data can't cross banks → own crt0, `-nostartfiles`. ca65 objects don't link
  with lld → the stub is LLVM-MOS asm.

## Memory model of the panel
```
E2:0000  header "SWCP", ver u16, size u16, entry u24; stub (crt0.s) + .text   (PBR=E2)
E2:8000  .rodata + .data init image (LMA, same low-16 offsets as VMA)
EF:0000  page-0 save ($00-$1F), .noinit
EF:8000  .rodata + .data (VMA, MVN-copied each entry)        (DBR=EF while C runs)
EF:C000  .bss, heap, soft stack (top EF:EFF0)
EF:F000  request block {'S', seq, cmd, len16, payload<=250, sum8}
EF:F100  reply block (512 B; status EF:F2FE, seq EF:F2FF lands last)
EF:FFF0  doorbell (write seq)
```
Entry stub: save P/A/X/Y/DBR/D, D=0, CLD, save $00-$1F, save video/IO switches ($C029,
$C035, $C036, $C027 + readbacks $C01A/$C01C/$C01E/$C01F), clear $C027 bit 2 (as stock),
set TEXT/PAGE1/80COL/ALTCHAR; loop { crt init, `jsr main` → 0 quit / 1 stock }; chain =
restore D=0/DBR=0/page 0/$C027, JSL trampoline, re-enter loop; quit = restore all, RTL.
Interrupt flag left as the caller had it. All $C0xx access long ($00C0xx) via asm helpers.

## Step 0 — repos (user, 2026-09-15)
- Both repos are clean on `woz_support`, 0 behind master (fw 3 ahead: ...c0e605e; host 2 ahead:
  ...5844da0). `git checkout master && git merge --no-ff woz_support` in each, with mirrored
  subjects in master's style ("Merge branch 'woz_support': WOZ read+write on hardware, the
  IWM's 5.25\" drives on the bit engine, and the fronts' cuts (GS + IIe MET)"). Open items carried
  onto master as-is: megademo stall on the IIe bit, Clark decimal test (pre-existing). No push.
- `git checkout -b gs_control_panel` in both repos.
- Write this plan as `strudelworks-firmware/docs/GS_CONTROL_PANEL.md` (opens with the
  `Status:` line convention: date, branch, rung reached) and commit it as the branch's first
  commit — firmware only; the host gets no mirror commit for a doc-only change unless the user
  wants lock-step there too. Update memory (a `gs-control-panel` project note + MEMORY.md line;
  mark woz-support / core-fronts-cuts as merged).

## Rungs (each tested alone; explain-before-test; WNS read after every firmware build)

**R0 — toolchain + CPU-level runner (no card/host change)**
- Unpack the .deb to `~/opt/llvm-mos-65816`, archive it with sha256 → `firmware/gspanel/TOOLCHAIN`.
- `strudelworks-host/firmware/gspanel/`: `build.sh [--check]`, `link.ld`, `crt0.s`,
  `sdk/{io.s,text,keys,ui,svc}`, `panel/main.c`, `lint_absolute.py` (objdump: fail on 3-byte
  absolute operands < $0100 and `jmp (` through zp), `test/` native gcc logic tests.
  Output `assets/gspanel.bin` (64 KB, $FF fill), committed; `firmware/build.sh --check` calls it.
- `strudelworks-firmware/sim/gspanel_run_main.cpp`: Verilated `rtl/cpu65816.sv`, reusing
  `sim/cpu816_trace_main.cpp`'s memory model: E2 = binary, EF = RAM, bank 0 RAM (S=$01E0),
  scripted $C000/$C010/$C025, E0/E1 $0400 dumped as 80×24 text, fake doorbell, trap at FF/8FB0
  that plays "stock panel returned". Steps: stub/crt0 (state restored, data copy, entry S) →
  text (aux/main columns, inverse, MouseText) → keys + list widget → chaining → service calls
  incl. timeout. 8-bit codegen first; `+mos-a16` only once the runner is green.

- **PROGRESS 2026-09-15.** Toolchain unpacked and pinned (host `firmware/gspanel/TOOLCHAIN`,
  sha256 6485bf20…, clang 23.0.0git llvm-mos 8be05461). The runner is
  `sim/gspanel_run_main.cpp` + `sim/run_gspanel.sh` (in `suite gs` as `gspanel`, on the
  ca65 self-test `sim/gspanel_selftest.s`; the real image with `--bin`). The panel project is
  host `firmware/gspanel/` (crt0.s, link.ld, sdk/io.s text keys, panel/main.c, build.sh
  `--check`, lint_absolute.py), built into `assets/gspanel.bin` (64 KB, 1307 B of code, header
  entry $E2/000C). v0 in the runner: title, MouseText rule, the two items; Down/Up/Return
  chains to the stock trap once and comes back, Esc leaves; the caller's S/D/DBR/P, page zero
  and switches restored; PASS in 1.50 M cycles (almost all `text_clear`, 1,920 `poke24`s -
  worth a row-at-a-time path later). Entry S is 3 bytes below the caller.
  **The assembler's traps, found here and fixed:** it does not track REP/SEP, so a 16-bit
  immediate is spelled `.byte op` + `.short v` (crt0.s `lda16`/`ldx16`/`ldy16`) - `lda #0`
  after `rep #$30` assembled as two bytes; without `.include "imag.inc"` (`.zeropage
  __rc0..31`) a register operand takes the widest mode, which for LDY/STX is a DBR-relative
  16-bit address (the wrong bank). `mvn #src,#dst`; `jmp $FFxxxx` is JML; callee-saved
  imaginary registers are `__rc20` up; lld writes `X.bin` and `X.bin.elf`.

**R0B — Control Panel effects ladder, stock panel first (EARLY; no card/ROM change needed)**
Every panel feature — stock or ours — is only done when its EFFECT is shown, not when a byte
was written. This rung builds the observability and the test, and runs it on the stock panel.
- **Expected effects — ESTABLISHED 2026-09-15 from the ROM 3 disassembly** (the ROM's
  routines, not forum lists; unverified rows marked):
  - *How BRAM moves.* `TOREADBR` FF/B970 reads all 256 bytes from the chip into $E1/02C0,
    range-checks them (table FF/8371) and the checksum; any failure → FF/B925 writes the
    defaults (FF/83C5 = the host's `kDefaults`) into the copy and `TOWRITEBR` FF/B94E writes
    the WHOLE block back. The checksum covers $00-$FB (the X=$FA pass reads $FB).
    Vector $E1/0094 `TOBRAMSETUP` = FF/BB7A: re-reads the chip (BBD7 → B970), applies
    display/volume/speed/cursor/keyboard, and applies the SLOTS only when called with carry
    clear (only the cold-reset path does; every ROM caller of the vector sets carry).
  - *When.* The chip is re-read and applied on EVERY reset (FA62 → … → FF/BACF), on every
    CDA-menu entry (FE/C9E8), and on Control Panel entry and exit — so the "stale RAM copy"
    hypothesis below is retired: the copy is fresh whenever the panel saves.
  - *A save* (Return, FF/91E5-9242) writes the WHOLE block via `JSL $E10080`; Escape only
    re-reads the chip, discarding edits. Edits apply live while in the panel.

  | BRAM | setting | applied | observable after the event |
  |---|---|---|---|
  | $18 | type 0 colour / 1 mono | BC45 | `$C021` bit 7; `$C029` bit 5.  **MEASURED 2026-09-15** (the ROM's own bytes: `LDA $02D8 / ROR / ROR / STA $C021 / ROR / ROR / TSB $C029`, with FF/BC24's `TRB $C029` and `CLC` ahead of it deciding the carry) - and the effect is not in the text screen at all: the pair kills the colour in HI-RES and DOUBLE HI-RES, and nowhere else |
  | $19 | columns 0=40 / else 80 | reset: FF/FA7F → FA24, if the visible $C3 ROM has the $38/$18 ID → `JSR $C300` with $98 = PR#3; NOT in BB7A. **MEASURED 2026-09-15 (card + KEGS agree):** a WARM reset gives 80 columns; a COLD start (power-on or Ctrl-Command-Reset) that boots ProDOS 8 ends in 40 columns with $19 still $01 in all four copies and the panel still saying 80 | warm reset: 80-character `screen` rows, CSW `$C307` / KSW `$C305`, 80STORE on, `$04FB` = **$09**; cold boot into ProDOS 8: 40 columns, CSW `$FDF0`, `$04FB` $FF |
  | $1A/$1B | text / background colour | BC12 | `$C022` = $1A<<4 \| $1B.  **MEASURED 2026-09-15** (host `status`): applied the moment the key is pressed in the panel, again out of the chip at every reset, and the frame really is painted in them |
  | $1C | border | BC24 | `$C034` low nibble.  **MEASURED 2026-09-15**: same, and it is the whole frame's clear colour - the margin around the picture is it and nothing else |
  | $1D | 0=60 Hz / 1=50 Hz | BC2F | `$C02B` bit 4 (bits 7-5 = $29) |
  | $1E | volume 0-14 | BBEE | `$C03C` low nibble, `$E1/00CA` |
  | $1F | bell PITCH (not volume) | only when the bell rings, FF/9A6D | `$E1/016D` after a bell |
  | $20 | speed 0 normal / 1 fast | BBE3 | `$E1/0138` bit 7 (reliable); `$C036` bit 7 lazily |
  | $21-$27 | slots (0 built-in) | COLD reset only (BB9B); $23≠0 → `STA $C00B` on every reset (BBCD) | `$C02D` (bits 7-4 ← $27-$24, bit 2 ← $22==1, bit 1 ← $58==1); `$E1/0139`.  **MEASURED 2026-09-15** on slot 5: saved, a WARM reset leaves `$C02D` at `80`, a COLD one takes it to `a0`.  The panel shows a slot's built-in name for 0 (Printer, Modem, Mouse Port, Smart Port, Disk Port by slot) and "Your Card" for 1 |
  | $28 | startup 0 scan / 1-7 slot | cold start only, FF/FAE1 | which `$Cn00` boots; `$07F8` = `$Cn`. Values ≥8 UNVERIFIED |
  | $29, $2A-$2D, $2F-$31 | language, layout, repeat, keyboard modes | BC2F / ADB micro | `$C02B` bits 7-5; the rest ADB-only |
  | $2E | cursor flash | C3EA | `$E1/0145` |
  | $34/$35, $36-$38 | date format; RAM disk | — | UNVERIFIED |

  - *The stock panel's own columns.* ~~From Ctrl-OA-Esc it is 80-column hardware whatever $19
    says~~ NOT SO on hardware (2026-09-15, from BASIC): the CDA menu and panel draw 40 wide
    while $19 = $00 and 80 wide (the 40-column frame centred) once $19 = $01 is saved, cold
    boot included; KEGS draws them 80 wide with $19 = $01 too. The Desk Manager gives the
    caller's 40 columns back on exit. From the boot menu
    (Ctrl-Option-Reset '1') $19 decides: FF/8FA1 sends ESC through $C300 only if $19≠0.
  - *Corrections to our own notes.* Slot 3 CAN be given to a card: $23≠0 selects the card's
    $C3 ROM through $C00B (gs_bram.hpp/GS.md say it cannot — true only of $C02D).
- **A lead for the unconfirmed report (hypothesis, not evidence):** with $19 = 80, every
  reset does `JSR $C300` if the $C3 ROM the machine sees carries the $38/$18 Pascal ID. If
  slot 3's page belongs to a card whose ROM passes that check but is not 80-column firmware
  ($23≠0, or a card answering at $C3), a reset jumps into it — a crash to the monitor is the
  natural result. The ladder's $19 row runs with slot 3 internal and with a card in slot 3.
  NOT REPRODUCED 2026-09-15 with slot 3 internal: $19 = $01 through two Ctrl-OA-Resets (host
  Open-Apple override + RES') - ProDOS 8 booted each time, no monitor. Slot 3 with a card: not
  yet run.
- **Observability today** (BRAM trace, 2026-09-15): the card's clock chip (`rtl/gs_clock.sv`)
  decodes like KEGS; $C033/$C034 are dispatcher-served, never fast reads, and never
  `fast_quiet`-dropped. But nothing can see the card's store: no readback register,
  `bram_ok`/`cnt_strobes`/`cnt_bad` (gs_io.sv:400/408, master_top.sv:946/1893) go nowhere; no
  socket dump of the host follower's image/state/sealed; no per-write log; `load_bram` doesn't
  say why it rejects a file. Only `peek E102C0 256`, the `bram :` log lines and the file.
- **BUILT 2026-09-15 (sim-green, not yet on HW — needs a GS bit):** the card's store reads
  through the debug pair (DBG_SEL `$C0+k` = bytes 4k..4k+3) and GS_CLOCK_STAT `0x8000_0154`
  {bram_ok, state, machine writes, bad, strobes}; the host's `bram [dump]` socket command
  (four copies, seals, the differing bytes), follower RES'/gap handling + counters, a
  `bram    : $NN old -> new` log line per changed byte, `read_bram_file` reasons. Lint clean,
  `suite gs` 13/13, `suite quick` 31/31, host tests 41/41 on the Pi. SHADOW bit 6 on the
  follower is NOT done (it needs the mirror's SHADOW state; rare).
- **ON HARDWARE 2026-09-15** (gs_bram1, `gs_nox.conf`): `bram` shows all four copies sealed
  at $0B5E, 0 bytes differ, GS_CLOCK_STAT "image landed yes"; a visit to the CDA menu, the
  stock Control Panel and its Display page (Escape, nothing saved) took the card's strobe
  count 4 → 68 with 0 machine writes - the ROM reads the chip on those entries and exits and
  writes nothing, as the disassembly says.
- **The stock panel's keys, as seen on hardware** (driven with `tools/gs_menu.py`, every key
  checked against the inverse run):
  - The CDA menu and the Control Panel both REOPEN ON THE ITEM LAST CHOSEN (after a quit,
    Quit). Down at the bottom does not wrap; Up moves. Return opens, Escape cancels a page.
  - CDA menu (under Nox): Control Panel, Alternate Display Mode, Visit Monitor, Memory
    Peeker, Quit.
  - Control Panel: Display, Sound, System Speed, Clock, Keyboard, Slots, Printer Port, Modem
    Port, RAM Disk, Mouse, (blank), Quit. The clock box shows the host's time.
  - Display page: Type, Columns, [Screen Colors] Text, Background, Border, Standards, Hertz;
    the selection starts on Type; "Select: ←→↑↓  Cancel: Esc  Save: Return".
- **Add** (as planned): (fw) a BRAM window + GS_CLOCK_STAT {bram_ok,
  strobes, bad, state} in wb_regfile; (host) socket/MCP `bram` = four copies byte for byte —
  card store (register walk), follower image, `gs_bram` file, ROM working copy $E1/02C0-03BF —
  each with its checksum/sealed state (checksum routine as FF/BA57, `bram_checksum`) and a
  diff; follower anomaly counters + a per-write log line (addr old→new); `load_bram` rejection
  reason. Host tests extend `tests/gs_bram_test.cpp`.
- **Known holes to fix in this rung** (from the trace, file:line verified by the agent):
  - the follower ignores RES' mid-transfer (`gs_bram.cpp:141-185`; card clears its FSM at
    `gs_clock.sv:223`) and ring gaps (only `mem_` hears them, pipeline.cpp:4024-4030);
  - the follower treats banks $00/$01 as I/O under SHADOW bit 6, the card doesn't
    (protocol.hpp:1800 vs gs_iopage.vh:16);
  - GS_BRAM writes words into the store as they arrive, so "all or nothing" isn't
    (gs_clock.sv:154-158);
  - `build_bram` forces slot bytes $21/$22/$24-$27/$58 from the conf on every start
    (gs_bram.cpp:103-115), so a stock-panel slot choice never survives a swhost restart
    (decide: conf wins vs panel wins — the panel work makes the conf the owner of card slots);
  - ~~the ROM's RAM copy ($E1/02C0) can be stale against the chip~~ RETIRED by the ROM: the
    chip is re-read on every reset, CDA-menu entry and Control Panel entry/exit.
- `tools/gs_cp_test.sh` (host repo, own conf): for each setting in a table {BRAM byte,
  new value, stock-panel key path, observable effect after reset}: drive the stock panel by
  ADB keys (`adb 35 82`, arrows, Return), leave it, diff the four copies, then reset along each
  path — socket reset, Ctrl-OA-Reset, swhost restart (with and without the MCP start's RES'
  pulse) — and check (a) the byte survived in all four copies and every copy is sealed, (b) the
  effect is visible from the mirror (e.g. soft-switch readbacks / $C022 / $C034 / $C036 /
  $C02D after boot), (c) the machine boots to the expected screen (`wait_for_text`).
  Controls: a known-harmless change (Display = Monochrome, GS.md:2972) and the same change
  after a Ctrl-Reset before opening the panel. First rows: Display columns ($19), colours
  ($1A-$1C), then slots ($21-$27) once their conf-vs-panel ownership is decided.
- **BUILT 2026-09-15: `tools/gs_cp_test.sh`, row 1 = Display > Columns ($19).** Own conf
  `gs_cp_test.conf` (ProDOS 8 on a copy of `po_master.po` as hd1, `gs_cp_bram.bin` removed first). Steps, every menu selection read from the inverse run: the defaults ($00 in card,
  follower and ROM copy; the FILE IS ABSENT until the machine first saves - swhost writes it
  only then); 40 columns, CSW $FDF0; Ctrl-Command-Esc → Control Panel → Display → Columns →
  Right until it reads 80; before Return only the ROM copy has $01; after Return $01 in all
  four, sealed, 0 differ; still 40 columns before a reset; warm reset → 80 (CSW $C307, 80STORE,
  $04FB $09); cold reset (Open-Apple override + RES') → ProDOS in 40, $01 kept, the panel reads
  80, Esc leaves nothing written; swhost restart → card/follower/file $01 from the file, warm
  reset → 80. Parsers (`bram dump` per-copy bytes, seals, differ; screen width; CSW) checked
  against captured replies. The reference for the cold result is KEGS with the same 256
  bytes and disk (memory note `kegs-headless`: Xvfb, F1 = Command).
  Side finding: starting swhost on a conf with `hd=off` rewrote $27 to $00 in card/follower/ROM
  while the file kept $01 - the `build_bram` hole above, provoked by changing confs.
- **BUILT AND GREEN ON HARDWARE 2026-09-15: rows 2-4, Display > Text ($1A),
  Background ($1B), Border ($1C).**  Host-only - no firmware change and no
  rebuild; the run is on the clean-start bit `cs16` (fw 2026-09-15 17:41:17).
  *New observability.*  The status line carries `tcol=` ($C022, text
  foreground in the high nibble and background in the low) and `border=`
  ($C034's low nibble) straight out of AppleVideo's own latches
  (apple_video.cpp:93/95, published in pipeline.cpp's decode) - the two
  registers the frame is actually painted from - so a colour's effect is
  readable without a screenshot.  And `tools/png_pixel.py` reads pixels out
  of a screenshot with nothing but zlib (swhost writes 8-bit RGB, filter 0):
  a point prints "X Y R G B", a rectangle the three colours commonest in it.
  *What the row does.*  On the Display page, with every selection read from
  the inverse run and every colour read back by NAME after each key (the
  sixteen are the ROM's own list, at file offset $387xx, and the name shown
  IS the index that lands in the battery RAM):
  - **the defaults** are $1A=0F, $1B=06, $1C=06 - white on medium blue, a
    medium blue border - put there by the ROM out of the chip at reset:
    `tcol f6 border 6`, and the frame's margin 100% (7,168,225).
  - **an edit is LIVE, with nothing saved and no reset.**  Text = Yellow took
    $C022 to `d6` while still on the page.  At that moment only the ROM's
    working copy holds it ($E1/02C0's $1A = 0D); the card's store and the
    follower still read 0F.  This is the difference from Columns, which does
    nothing at all until a reset.
  - **Escape cancels it on the screen too.**  Escape from the page put
    $C022 back to `f6` and left all four copies 0F/06/06, 0 bytes differing -
    the ROM re-reads the chip, so a cancelled page is cancelled everywhere.
    (Escape lands on the Control Panel's LIST, not back in the program - the
    test's `open_display_page` exists because of that.)
  - **saved** (Yellow on Black, an Orange border): `tcol d0 border 9` live,
    and $1A=0D, $1B=00, $1C=09 in all four copies, every copy sealed, 0
    bytes differing.
  - **the picture, which is the point**: the margin 100% (249,86,29) orange
    and the picture 97% black with 2% (220,205,22) yellow - the machine's own
    repaint, in the colours just chosen.
  - **through every reset**: a warm reset, a Ctrl-Command-Reset (ProDOS boots
    again in 40 columns) and a swhost restart with a warm reset after it.
    Each time FF/BB7A applied all three again out of the chip - `tcol d0
    border 9` - the bytes survived in every copy, and the picture was the
    same.
  *Two things the panel does by itself*, neither of them ours: the Display
  page's `Standards:` item flips to No the moment a colour leaves its
  standard value and back to Yes when it returns (a MouseText marker beside
  each item tracks the same thing per row); and both menus reopen on the
  item chosen last, which is why nothing here counts keys.
  *What the test rig needed.*  `scanlines = none` in the test's own conf, so
  a text picture has EXACTLY two colours in it and the two commonest are the
  pair; and the screen filled with a `CATALOG` before every picture check,
  because a blank screen is one colour and proves only the background.  The
  border needs neither: it is the clear colour, so the margin is it whatever
  is on screen.
  *Seen once, not reproduced (recorded, not claimed).*  A screenshot taken
  after a swhost restart once showed a frame full of inverse `@` that the
  mirror did not have (`screen` showed the real blank screen) - the cold
  mirror's zeros, apparently still on the beam canvas.  Running the same
  sequence again afterwards gave a picture 100% background, agreeing with
  the mirror.  The ladder repaints before every picture check, so no row
  depends on the answer.
- **BUILT AND GREEN ON HARDWARE 2026-09-15: row 5, Display > Type ($18) -
  and the host feature the row turned out to need.**  The rows above were
  tests over behaviour the host already had.  This one is not: the machine
  was writing the registers all along and the host was throwing them away,
  so nothing on the screen ever changed and by the rule the setting could
  not be done.  What the row needed built first:
  - *The facts, from the ROM's own bytes* (FF/BC45): `LDA $02D8 / ROR / ROR
    / STA $C021 / ROR / ROR / TSB $C029` - the Type byte rolled into $C021's
    bit 7 and then into $C029's bit 5, with FF/BC24's `A9 20 / TRB $C029`
    and `CLC` immediately before it clearing bit 5 and settling the carry.
    So Colour writes $C021 = $00 and leaves bit 5 clear; Monochrome writes
    $80 and sets it.  Both registers carry the one setting.
  - *What it means*, from KEGS (the GS oracle): `video.c` joins the two into
    one `monochrome` term and adds it to a line's state ONLY under
    `ALL_STAT_HIRES`, so it takes the colour out of HI-RES AND DOUBLE HI-RES
    and out of nothing else - text keeps $C022's two colours, lo-res keeps
    its own.
  - *The host side.*  `AppleVideo` now latches $C021 beside the other IIgs
    video registers and answers `gs_mono()` for either bit; the status line
    says `mono=`.  The picture: `Ntsc::decode_lines` takes a per-line "force
    black and white" mask that beats both the burst and the text colours,
    and the frame path builds it from the kinds the beam actually drew -
    hi-res and double hi-res lines only.  Tests: `ntsc_test` (a marked line
    loses its colour though the burst was up, an unmarked one keeps it, and
    a burstless line is still the text pair's), `video_test` (either bit is
    the ask, a reset clears it, a read moves nothing, a plain IIe has no
    such register).  Host tests 41/41 on the Pi.
  - *Proven on the machine before the panel was ever opened*: `POKE
    49185,128` on a green hi-res screen took the picture from three greens
    to 50% black and 49% white, and `POKE 49185,0` brought the greens back.
  - *Then the row itself.*  A green hi-res screen (HGR with the text window
    turned off by hand - NOT HGR2: the Columns row leaves the machine in 80
    columns, where 80STORE makes PAGE2 the aux switch and HGR2 writes a page
    the screen is not showing, which came up black); Type = Monochrome on
    the stock panel takes `mono` to 1 and `newvideo` to `61` on the
    keystroke; the save puts $18 = 01 in all four copies, 0 differing; the
    TEXT screen is still yellow on black inside an orange border, which is
    KEGS's rule holding on hardware; the hi-res picture is 50% black and 49%
    white.  A warm reset, a Ctrl-Command-Reset and a swhost restart each
    bring it back out of the chip, and setting Type back to Color returns
    the same three greens the row started with.
  *The cell-drawn types, and a claim withdrawn.*  This was first written up
  as "not done, and deliberately" for the `idealized` and `rgb` types
  (cell_render.hpp, which draws from the bytes rather than the signal).  That
  was scope dressed up as a principle, and the user asked what the references
  actually do there.  They answer flatly: **KEGS has no other kind of
  renderer** - its hi-res goes through `g_dhires_convert`, a palette indexed
  by dot pattern, which is the idealized style exactly, and the monochrome
  term is applied inside it (`color = 0xf` per lit dot); and AppleWin, though
  it has no $C021 to honour, carries "a real 560x192 monochrome mode" in
  `RGBMonitor.cpp`, in its byte-drawn RGB-card renderer.  A cell renderer
  doing monochrome is what both of them do, so there was no exception to
  claim.  `CellRender::render` now takes the ask and draws a hi-res or double
  hi-res line straight from the dots, white and black, one pixel each, with
  the vertical blend (a colour monitor's treatment) left off those lines;
  text and lo-res are untouched, as everywhere else.  `cell_test` covers it,
  and `tools/gs_cp_test.sh` checks both types on the machine.  SHR stays out
  of the setting's reach, which is where KEGS leaves it too.
- **GREEN ON HARDWARE 2026-09-15: the slots row ($21-$27), and the ownership
  question answered by the code rather than by a decision.**  This plan
  carried "decide: conf wins vs panel wins" as an open item.  It is not open:
  `pipeline.cpp` restates the conf's slot bytes into the battery RAM at every
  start and says why in the comment - *"the Control Panel's settings persist,
  the slots are the host's"* - because the host is the only thing that knows
  which slots have a card behind them, and a slot marked Your Card with
  nothing there sends the ROM hunting for it ("Check startup device!", a
  failure the same comment records).  So the row tests what the machine
  actually does with a panel slot choice, on slot 5 (the test's conf uses
  none of it; slot 6 is the internal IWM, which is the slot that comment was
  written about), with `$C02D` read out of the status line's `sltrom=`:
  - saved like any other setting - $25 = 01 in all four copies, 0 differing;
  - **a WARM reset does not apply it**: `sltrom` stays `80`.  This is the
    ROM's "cold reset only" (BB9B, carry clear) shown rather than quoted;
  - **a COLD reset does**: `sltrom` `a0`, slot 5's bit;
  - **the next swhost start restates the conf's**: card and follower back to
    00 while the file still holds the 01 the machine saved, and a cold reset
    after it is `80` again.
  The panel shows a slot's built-in name for 0 - Printer, Modem, Mouse Port,
  Smart Port, Disk Port, by slot - and "Your Card" for 1.  What is still NOT
  possible is a panel slot choice that survives a restart; that needs the
  conf written back and swhost restarted under the machine, which is the
  "Later" item at the end of this plan and unchanged by any of this.
- **The test rig, after a day of paying for it (2026-09-15).**  Two lessons,
  both cheap and both expensive to have missed:
  - *`tools/gs_cp_test.sh` takes a row name.*  It only ever ran end to end
    from a wiped battery RAM, so every fix to the row being written re-proved
    the rows in front of it: seven full runs in a day, 15-25 minutes each, to
    add two rows.  Named rows (`columns colours type slots`) run against the
    battery RAM the last full run left - which is where nearly all the state
    a row needs actually lives - and the bare command still runs the whole
    ladder from scratch, which is the run the numbers here come from.  The
    slots row alone: 72 seconds.
  - *Keys typed at a prompt are queued, so do not screenshot on a timer.*
    The row that checks a monochrome machine still draws TEXT in its two
    colours types `TEXT` and then samples the picture; on one run it sampled
    the hi-res screen the step before had left, which is black and white, and
    read that as the text screen drawn wrong.  It had passed the run before
    by winning the race.  Both `repaint` and `hires_fill` now wait on the
    machine's own video switches (the status line's `vsw`, bit 0 TEXT and
    bit 2 HIRES) instead of sleeping.
- **FOUND AND FIXED 2026-09-15 (host, uncommitted): swhost's exit ran a live GS off the bus.**
  The ladder's first two runs failed only at the swhost-restart step: the warm reset after the
  restart booted ProDOS from disk (40 columns), and the user saw a LoRes screen with a speaker
  buzz ("a self-test?") the moment swhost came back. Isolated on the machine, one variable at a
  time, each run a swhost stop/start + a warm reset 6 s later: nothing before it (A′), the
  button override alone (B1), a Ctrl-OA-Reset alone (B3), a Desk Manager visit alone (B2) - all
  warm; **a Ctrl-OA-Reset THEN a panel visit (B4) - the runaway.** Test D wrote the exit path's
  own register by hand with swhost up: `regw 8000008C 0` (ACCEL_CTRL mode 0) under that state
  went to LoRes + burst within 2.5 s and restoring mode 2 did not bring it back.
  **Cause:** `Pipeline` exit wrote accel mode 0 whenever a conf had set accel (pipeline.cpp, "the
  core back at the bus's pace"); mode 0 hands the 65816 to the bus (accel_seq.sv "MODE 0 IS THE
  OLD MACHINE TO THE CLOCK"), and on a GS that bus is a IIe backplane without the GS's memory
  or ROM. Some states survive it (idle loops the IIe's own ROM happens to carry), which hid it.
  Not the battery RAM (all four copies agreed throughout), not a stuck Apple key (no reset was
  involved in D). **USER RULE: a GS is in accel mode 2, 100% of the time.**
  **Fix (host):** no mode-0 write at exit on a GS; `set_accel` refuses modes 0/1 on a GS;
  `set_levels` cannot lower mode or serving; startup forces mode 2 + serving even under `keep`,
  and a first MEM_CTRL readback no longer lowers the serve level on a GS; the conf refuses
  `accel = off|reads` and `mem = off` with `machine = iigs` (`keep` = all/on). Tests:
  `config_test` +9 (164), `accel_test` IIgs case (69); host 41/41 on the Pi. **On hardware:** B4
  on the fixed host - accel control stayed `00000002` through the restart, frames Text40 (not
  LoRes), the warm reset returned to `]` in 80 columns with no disk read.
  **And on the card (bit gs_romhold1, built 2026-09-15):** the card's own reset (host 'R' or
  the link watchdog, card_link.sv `apple_rst = rst`) set ACCEL_CTRL mode 0 and MEM_CTRL serve 0
  as it released the 65816.  Now at GS = 1 (wb_regfile.sv) the mode resets to 2 and ignores
  writes, and serving resets on and ignores writes (user: the //e's bus cannot carry the GS's
  24-bit space, so bus RAM is nonsense for reads and writes alike - revisit for a IIgs slot);
  and master_top.sv holds the 65816 in reset (`gs_rom_hold`, registered) until rom_loader's
  `rom_ok`, which only a card reset clears.  boot_gs_tb mirrors the hold and checks that no
  instruction is fetched before the ROM lands.  On the machine: `regw 8000008C 0` reads back
  `00000002`, `regw 8000004C 0` keeps serving, and the machine stays at its prompt.
  Also found: **swhost pushed the ROM on every start, into a running GS** (the loader's posted
  writes were meant to run before the machine does).  Test E2 (Ctrl-OA-Reset, panel visit,
  swhost restart) ran away with 21.5 MB of events in 1.6 s while the link stayed healthy
  (UART R=0 L=0 K=17); test F (the same with no push) was clean; a forced-push control was
  clean too.  Over four runs a push went wrong only when the 65816 was actively running (a
  busy event stream).  swhost now skips the push when MEM_STAT `rom_loaded` is set; the formal
  load replaces this.
  Also seen: a swhost restart without a reload once left the card answering no register at
  all (GS.md's known resync failure) - a reload of the same bit cleared it.
- Gate: the ladder green on the stock panel before R3 puts our panel in front of it.
- Same table grows a column for our panel from R5 on (SET_ITEM → same checks, plus `status`
  and the conf's written-back key).

**R1 — map classes (fw + host)**
- Host bug first: `protocol.hpp:879` MEM_ROM overruns read `>>16`, card packs them at [15:8]
  (wb_regfile.sv:1082) → `>>8`.
- `rtl/apple_mmu.sv`: `gs_xrom(bk)` = $E2-$EE → the gs_rom arm (:1002; CLS_ROM, wr=0,
  identity); `gs_void` = bank ≥ $80, not $Ex, not ROM (:646); $EF falls into the plain-RAM arm
  (:1013). No rom_ok term. `src/apple_memory.cpp` classify_gs (:327-352) same; resolve the
  existing void mismatch (host one page vs card whole bank $FB) while there.
- **No VidHD on the GS** (user, 2026-09-15: GS software knows it has SHR etc., nothing needs a
  faked VidHD). Host: on machine=gs the `vidhd` key is refused with a message
  (host_config.cpp:293/490), no synthesised ROM (pipeline.cpp:915-949), no "Your Card" BRAM
  mark (pipeline.cpp:1193), VIDHD_SLOT written 0 (:1223), and the SHR publish path confirmed not
  to depend on `vidhd_on_` on the GS (GS.md:1791-1833). Firmware: `vidhd_card` tied off at GS=1
  (`slot_assign` 0 / claim gated, master_top.sv:2327, the slot read mux :889-892) — one less
  claim term in that mux; read WNS. The panel never shows a VidHD row.
- Tests: `sim/mmu_xlate_gs_tb.sv` (model :184/:191, add banks $E2/$EE/$EF),
  `tests/gs_memory_test.cpp` (:60-75, :160). Doc: GS.md memory table (~:287).

- **BUILT 2026-09-15, sim-green.**  The map has the card's banks on both
  sides: $E2-$EE is CLS_ROM, read-only and identity-mapped, $EF is a plain
  RAM bank written like any other, and both are carved out of what was void,
  leaving $DF and $F0 void as before - so the ROM's memory sizing, which
  stops at $80, never meets them, $F0 stays the ROM-disk convention and $F8
  keeps its "ROMTOOLS" probe.  `sim/mmu_xlate_gs_tb.sv` sweeps five more
  banks ($DF, $E2, $EE, $EF, $F0) beside the twelve: 3584 maps, 95,108,621
  checks, 0 mismatches, with `apple_mmu`'s own assertion - the shallow
  prefetch ppn against xlate's - quiet throughout.  `tests/gs_memory_test.cpp`
  the same on the host, against the model written the other way round.  Lint
  clean at GS=0 and GS=1, `suite quick` 33/33, `suite gs` 14/14, host tests
  41/41.  **BUILT AND LOADED** (fw 2026-09-15 21:04:25, GS bit `master_top_gs`):
  TIMING MET wns +0.007 whs +0.051 fail 0/98021 - level with the clean-start
  bit's +0.010, so the read mux the VidHD left is not on the critical path
  and the tie-off bought nothing measurable.  The machine boots on it and
  `tools/gs_cp_test.sh` is green over all six rows, which is the regression
  an RTL change under everything needs; R1 has no positive hardware check of
  its own, because a read of $E2 proves nothing until R2 puts a ROM there.
  *The depth tail could not be read honestly here*: `build/depth_baseline.txt`
  is ONE file shared by the GS and IIe builds, last saved at 12:00, so its
  "NEW DEEP TAIL: 340 endpoints" compares this build with a baseline from
  another variant and names nothing.  A per-variant baseline would be needed
  before that number means anything - NOT done, and flagged to the user.
  **Two bugs found on the way, both of them silent:**
  - *MEM_ROM overruns were unreadable.*  `mem_rom_overruns` read [23:16],
    which the card leaves zero; the count is at [15:8]
    (`wb_regfile.sv` `mem_rom_rd = {drops, 8'd0, over, 7'd0, busy}`).  So
    `mem_report` could never say a ROM chunk had been dropped however many
    the card counted - a diagnostic that had never once been able to fire.
  - *The void was the CARD's bug, not the host's.*  This plan carried the
    mismatch as "host one page vs card whole bank $FB" without saying which
    was right.  KEGS says: `fixup_any_bank_any_page(..., BANK_BAD_MEM,
    BANK_BAD_MEM)` points every unpopulated page at ONE shared 256-byte
    dummy (moremem.c).  The host folded to $FB00 and was right; the card
    passed `va[15:8]` through and answered from 256 different pages of bank
    $FB - and its own comment said "reads answer from one write-protected
    page" the whole time.  Now folded to page 0 in both the xlate arm and
    the shallow prefetch path (they must agree or the `$error` fires), which
    also keeps every void read on one cache line instead of scattering it.
    *Neither of these was going to be caught by two models agreeing*: the
    host's two expressions agreed with each other because both came from the
    host's idea, and the card's two agreed with each other for the same
    reason.  It took reading the oracle.
- **No VidHD on the GS, done.**  `machine = iigs` with any `vidhd` is now a
  configuration error rather than something honoured downstream
  (`config_test` +5, 169), so no synthesised ROM, no "Your Card" mark and no
  VIDHD_SLOT can follow from it; the SHR path already asked the machine and
  not the card (`vidhd_on_ || cfg_.iigs`).  On the card `vidhd_card` is no
  longer built at GS=1 at all - one fewer claim term in the slot read mux,
  which is on the read path.

**R2 — extended ROM load**
- `rtl/rom_loader.sv`: MEM_ROM word 0 bit 31 = absolute chunk `{1,15'd0,ppn16}` (no `seen`
  change, counts `xlanded` into MEM_ROM_STAT [23:16]); register `dr_ppn` at msg_end. No new
  message type, seam mux (master_top.sv:2003-2016) untouched. Host refuses ppns outside $E2-$EE.
- Host: key `gs_xrom = assets/gspanel.bin` (host_config.cpp parser + config_reference +
  README), load ≤64 KB multiple of 512, send BEFORE the base ROM in the loop at
  pipeline.cpp:1268-1331, check the `xlanded` delta, `AppleMemory::load_ext_rom` beside
  `load_gs_rom` (apple_memory.cpp:459).
- Bench: `boot_gs_tb` with XROM params sending absolute chunks. HW: MCP `peek E20000` = "SWCP".

- **BUILT 2026-09-15, sim-green.**  A MEM_ROM whose first word has BIT 31 set
  is an ABSOLUTE chunk: its low sixteen bits are the physical page its 512
  bytes land on, instead of an index counted from the loader's base.  No
  second message type, no second seam, and nothing about the base ROM moves -
  an absolute chunk is not one of the `seen`, never joins `rom_sum`, and
  **never satisfies `rom_ok`**, which is what the start hold waits on.  It is
  counted on its own in `xlanded`, which lands in MEM_ROM_STAT's [23:16] -
  the field the host was wrongly reading as overruns until R1 fixed it.
  Refusals are the CARD's, not only the host's: a page outside $E2-$EE, or
  any absolute chunk at all on a IIe build (`ABS_EN` off), is acked BAD_PPN
  and lands nothing.
  *Host*: a `gs_xrom = PATH` key, IIgs only (a IIe has no bank $E2 to put it
  in); the file read as whole 512-byte chunks and given to the mirror so a
  `peek` of $E2/0000 can answer; and the send placed BEFORE the machine's own
  ROM, so `rom_ok` is the last thing to become true.  The acked retry loop is
  NOT duplicated - it came out of the startup path into
  `Pipeline::send_rom_chunks`, so both ROMs get identical retry, timeout and
  sum checking - and the load is verified against the card's `xlanded` delta.
  *One bank for now*, $E2, though the map reserves $E2-$EE: `xlanded` is
  eight bits, 64 KB is exactly 128 chunks, and a bigger panel would wrap the
  counter and make the delta check a lie.  Widen the counter with the range.
  *Tests*: `sim/rom_loader_tb.sv` - an absolute chunk lands at the page named,
  spans exactly the two pages, is acked with the sum of the bytes sent and
  named by the low twelve bits of its page, counts in `xlanded`, stays out of
  `rom_sum`, and **leaves `rom_ok` false** (checked before the base ROM is
  whole, which is the only place that property can still be seen); $EE taken,
  $E1 and $EF refused.  Lint clean GS=0/GS=1, `suite quick` 33/33, `suite gs`
  14/14, host tests pass.
- Measure the Nox map + desktop census at unlimited before/after (64 KB = 2 more pages per
  cache set; expected one-off eviction flushes, not a standing loss).

**R3 — ROM patch + panel v0 on hardware**
- **The self-test checksum is COMPENSATED, not bypassed** (user, 2026-09-15).
  The plan used to copy KEGS and patch the test out (0x36CB0 `D0 02` →
  `18 18`).  That disables a real integrity check for the life of the
  machine, and it is not necessary.  MEASURED, the routine and the numbers
  both: FF/6CCC is a 16-bit `ADC` sum with the carry chained, walking every
  even offset of each of banks $FC-$FF (`LDY #$FFFF`, `ADC ($FD),Y`, Y -= 2,
  the last word at 0), and FF/6CAD compares the total against a CONSTANT,
  `CMP #$1234`.  **The stock ROM 3 sums to exactly $1234** - Apple built it
  to hit that - so the patched image can be made to hit it too.  Proven in
  Python over the real file: patching FF/8FAC to `5C 0C 00 E2` takes the sum
  to $A223; writing $7010 into one spare word restores it to $1234, and the
  ROM then passes its own self-test with the test itself untouched.  Two
  iterations to converge, because a changed word can change how many carries
  the chain makes.
  *Open*: WHICH spare word.  The demonstration used 0x35400, inside a
  650-byte run of $00 in bank $FF, on the assumption that a run that long is
  padding - likely, but not shown.  Either establish that nothing reads it,
  or find the ROM's own correction word (there must be one: the sum did not
  come to $1234 by luck).  The correction is a single word wherever it goes,
  so moving it is free.
- `src/gs_rom_patch.{hpp,cpp}`: table `{addr, old[], new[], why}`; verify every old byte, apply
  all or none, refuse ROM 01; JML target from the ext ROM header, no header ⇒ no patch.
  The checksum correction is computed from the patched image, not hard-coded:
  a table entry whose value is "whatever makes the sum $1234 again". Call
  site pipeline.cpp:786-791 between `load_gs_rom_file` and `mem_.load_gs_rom`; unpatched copy
  sent if the ext load fails. Fix the stale "NO PATCH" comment (fd_service.cpp:447) and GS.md.
- Panel v0: a two-item menu (Standard Control Panel / Quit), plus entry S/D/P logged to EF:F3xx.
- Tests: `tests/gs_rom_patch_test.cpp` (wrong bytes refused, all-or-none, asset bytes).
  HW: `adb 35 82` → Control Panel → our menu (`screen`) → Standard → stock panel → back to ours
  → Quit → program resumes; Ctrl-Option-Reset → '1' → same; peek EF:F300 for stack headroom.

**R4 — PANEL_DMA on the card**
- `rtl/hd_card.sv`: new type 0x33 PANEL_DMA, payload as HD_DONE (`[{count,addr}] [{bank<<16}]
  [bytes]`), accepted only when GS && master_active && idle && no HD command outstanding
  (else consumed + drop counted), reuses S_DMA_W without touching `outstanding`; FSM reset
  also stays up for `GS && master_active`. `ft601_msg_rx.sv:67-106` type list; register
  R_PANEL_STAT 'd85 = 0x8000_0154 {dmas, drops}. PROTOCOL.md rows (+ reserve 0x34 PANEL_BELL).
  Override mux (master_top.sv:875-888) untouched.
- Bench: boot_gs_tb with a synthetic reset ROM (`CLC XCE JML $E20000`) + a test ext ROM doing
  request → doorbell → poll → copy reply to $E0/0400; bench host model answers like its
  HD_DONE model; repeat with an `--hdv` boot to prove HD `outstanding` untouched.

- **BUILT 2026-09-15, sim-green.**  PANEL_DMA is type $33, taken by `hd_card`
  and written with the DMA it already has: the same payload shape as an
  HD_DONE's, the same seam, and nothing new into the machine's memory.  It is
  NOT a disk command - `outstanding` never moves - and the card takes one only
  at GS = 1, only while the core owns the bus, only with that card idle and
  nothing of the disk's in flight.  Refused, it is consumed whole (so its
  words cannot be read as the next message's) and counted; PANEL_STAT
  (0x8000_0160 - the plan's 0x154 had been taken by GS_CLOCK since) carries
  {drops, blocks}.  $34 is reserved for the panel's bell and not decoded.
  Tested in `sim/hd_card_tb.sv`, which already runs twice - as a //e and as a
  IIgs - so the refusal on a //e and the acceptance on a IIgs are the same
  test run two ways.
  **Two things found building it:**
  - *The state machine was held in reset unless the HD CARD was enabled* - a
    slot assigned AND its ROM loaded.  A panel reply could never have been
    written on a machine configured with `hd = off`, which has nothing to do
    with the panel.  It now runs whenever a IIgs core owns the bus.
  - *The first refusal test forced the refusal by dropping `master_active`* -
    which resets that block, and with it the counter the test was checking.
    It now sends a second PANEL_DMA while the first is still draining, which
    is the race the host has to space its replies around anyway.
  **FOUND ON HARDWARE 2026-09-16: the panel's reply was the last DISK BLOCK.**
  The first hardware run said "no host is answering" while every counter said
  otherwise: the service logged `call 1: cmd $01 seq $01 -> status $00`, and
  PANEL_STAT counted the block written.  What was AT $EF/F100 was a ProDOS
  directory - "BLANK", the test volume's name.  The cause is this rung's own:
  a PANEL_DMA latched the address, the count and the bank and started the
  card's DMA write, but `host_wr` - which stores the host's payload words
  into the staging buffers - tested `word_done` alone, so the panel's 128
  data words went nowhere and the DMA faithfully wrote whatever the last disk
  read had left in those buffers.
  **The bench had not caught it because it checked WHERE the bytes went, not
  WHAT they were** - addresses, bank, count, ordering, all correct, all
  beside the point.  And the first data check added still passed, because it
  expected `pat_a`, which is what the DISK test writes and therefore exactly
  what the stale buffers held: *a test whose expected value is what the bug
  leaves behind is not a test*.  The panel's payload now has a pattern of its
  own, and the check was confirmed to FAIL without the fix before being
  trusted (16 of 16 bytes wrong, first $03 where $A5 was sent).
  Also found on the way: `svc_call`'s wait was `unsigned int`, which is
  SIXTEEN BITS on this target - the timeout could not be lengthened by
  raising the constant, because 60000 was already near the type's ceiling.
  It is a nested count now.
  **And a cut it forced (2026-09-15).**  The first build of R4 MISSED by two
  picoseconds - wns -0.002, one endpoint of 98126 - on
  `g_fronts.u_iline/want_tag_reg[1][4] -> f_reg_reg[2]`, which is nothing R4
  touched: the design had been at +0.007 and +0.001 on the two builds before
  it, and R4's logic shifted placement just enough to tip the instruction
  front's own critical path over.  A miss is not green and does not get
  loaded, and the chain is now named, so it was cut rather than worked
  around.  The promote at F_IDLE was doing tag -> `pick` -> `p_tag` -> ARRAY
  INDEX -> `f_reg`: a late mux choosing an INDEX and only then reading.  All
  four tag sources are registers, so `p_reg_sel` reads the CAM row four ways
  at once and the late signals choose between four-bit RESULTS - identical by
  construction, since `p_tag[2:0]` is exactly the selected source's low bits,
  and the same late-select that worked for the microcode's dual-arm fetch
  (docs/UCODE816.md).  Only that field: the other three latched on that line
  are not on the failing path and reading them four ways would cost more than
  it buys.

**R5 — host GsPanelService**
- `src/gs_panel_service.{hpp,cpp}`: detection in the decode loop after `mem_.apply(e)`
  (pipeline.cpp:~4070) on a write to $EF/FFF0 → copy $EF/F000-F0FF from `mem_` → worker →
  `pop_outgoing` drained on the ingest thread beside fd35 (pipeline.cpp:3136) only while an
  added `HdService::idle()`. Callback interface to Pipeline (testable without it).
- Commands: HELLO, GET_ITEM, SET_ITEM (returns class), LIST_IMAGES kind/page (`list_images`,
  disk_dir.hpp:71), SAVE_CONF (`update_config` via `Pipeline::save_choices`, pipeline.cpp:2893,
  extended with hd1/fd35), APPLY. Bad sum → BADSUM, panel retries ×3; loop-count timeout →
  "host not answering" (Standard Control Panel still works).
- Wire-up per the 4-edit pattern: protocol.hpp:38, link_parser.cpp:128-141 (host→card only
  needs send), CMakeLists test registration (:158-169). `tests/gs_panel_test.cpp`: fake
  mirror, bad sum, LIST paging on a temp dir, SET classes. HW: panel shows HELLO's version.

- **BUILT 2026-09-15, sim-green.**  The panel writes its request to $EF/F000
  and rings $EF/FFF0; both are ordinary writes and the card sends them in
  order, so the request is in the mirror before the doorbell and is read
  straight out of the image - no round trip, nothing to wait for.  The answer
  is one PANEL_DMA of 512 bytes to $EF/F100, written in address order, so the
  LAST byte to land is the sequence at $EF/F2FF.  That byte is the entire
  handshake.  Replies are offered one at a time and only while
  `HdService::idle()`, because the card refuses one that lands on a busy card.
  `GsPanelService` knows nothing of Pipeline - every question is a callback -
  so `tests/gs_panel_test.cpp` drives it with a fake and no card, link or
  machine.  Beyond the happy path it pins: a bad checksum is answered BADSUM
  rather than acted on; **a doorbell rung twice for one sequence re-sends the
  answer but does NOT do the work again**, so a lost reply can never move a
  setting twice; and a refused change comes back with the item as it really
  is and the reason, which is what the panel shows.
  The panel's half is `sdk/svc.c`: build, sum, ring, and poll the sequence
  byte with a BOUNDED wait - a host that is not there is not fatal, the panel
  says so and the stock panel is still one Return away.  The runner's doorbell
  now models the service instead of echoing the request, and `suite gs` runs
  the real image against it (`gspanel_svc`).

**R6 — the real pages**
- Disks: fd1/fd2 LIVE via `apply_floppies` (pipeline.cpp:2119); hd1 AT RESET via
  `hd_svc_->request_image` + reset (hd_service.cpp:132-135 swap rule).
- Accelerator mode/ratio, card memory, floating bus: LIVE via `set_levels`/`flush_levels`
  (pipeline.cpp:2821-2887), rules from `src/menu_levels.hpp`.
- Video type/scanlines: LIVE (host only). Save: SAVE_CONF writes the user's conf in place.
- Each row shows its class ("now" / "at reset" / "after restart").
- An item is done only with its row in `tools/gs_cp_test.sh` green: set it from our panel by
  keys, check the effect on the machine (`status`, mirror, `screen`), the conf write-back, and
  that it survives the reset path its class promises.

- **BUILT 2026-09-15, sim-green.**  The panel's page is the host's rows and
  then its own two (Standard Control Panel, Quit).  **Every row prints WHEN it
  bites** - "now", "at the next reset", "when swhost restarts" - beside the
  value, because which one it is cannot be guessed from the setting's name,
  and a panel that changes something without saying when is worse than none.
  Left and right step a choice: the host is TOLD, and answers with the item as
  it now really is, which is what the panel draws - never what it asked for.
  A refusal comes back with the reason and is printed.  The rows so far:
  Speed (the accelerator's target, live), Monitor and Scan lines (live, the
  host's own), Floating bus (live; a IIgs refuses "watched" - the //e
  backplane cannot answer for the GS's memory), Hard disk 1 (at the next
  reset, chosen from the disk directory), Save to the conf, Apply now.
  `suite gs` walks it: `gspanel_set` presses Right twice and checks the panel
  shows the value the MODEL sent back.
  Also fixed: `firmware/gspanel/build.sh` reported the first `.text` line of
  the map as the image size, so adding code read as a SHRINK from 1307 bytes
  to 706.  It prints the real extents now.

- **On hardware the panel said "no host is answering" while the host had
  answered** (fw c041e30 / host dce72d2).  PANEL_STAT read `00000001` and the
  log said `panel : call 1: cmd $01 seq $01 -> status $00`, but `$EF/F100`
  held a ProDOS directory block from the test volume: the reply was addressed
  right and never written.  `host_wr` in hd_card qualified the staging write
  with the disk path's `word_done` alone, so a PANEL_DMA's words advanced the
  index and wrote nothing, and the DMA landed whatever the staging buffers
  still held.  **The bench had a PANEL_DMA case and passed it twice over**: it
  checked WHERE the DMA landed and not WHAT, and the data check added next
  used `pat_a` - the same pattern the stale disk buffers held, so the bug
  reproduced the expectation.  The lesson is the general one: a payload check
  must use a pattern the wrong source CANNOT produce.  It now writes
  `pat_p(i) = $A5 ^ ((i*3) & $FF)`, and was verified to fail with the fix
  removed ("16 of 16 panel bytes wrong at $F100, first $03, want $a5").

- **Proving it on the card was then blocked by the DDR3, not by the panel.**
  The rebuilt bit MET timing at +0.003 and never calibrated (`K=00 M=0E
  X=FF`).  Two bitstreams proven on hardware were loaded as controls and came
  up `D=1`, so the board was acquitted; the difference was that slice pressure
  had pushed 261 cells of the DDR3 wrapper out of the two clock regions beside
  its IO bank.  `constr/pt_v2/ddr3_place.xdc` pins the island there.  Written
  up in docs/UBERDDR3.md, "Where the census's conclusion ran out".  The pinned
  build (`gs_ddr3pin`, MET **+0.053** / +0.045, 0 of 98182 - better than the
  +0.003 it replaced) calibrates first time, `D=1 K=17 M=17 X=00`, with the
  eye, the tap and the DQS index reading the census's own values.

- **R4, R5 and R6 ARE DONE AND ON HARDWARE** (fw c041e30 + the pblock / host
  dce72d2, bit `gs_ddr3pin`).  Ctrl-Command-Esc, Control Panel, Return - and
  the machine draws **"strudelworks host is answering"** over the host's real
  state: Speed MAX, Monitor COLOR MONITOR, Scan lines NONE, Floating bus
  served, Hard disk 1 `po_gscp.po`, each with the class that says when it
  bites.  Every value there came back over the doorbell; none of it is in the
  machine.  **The effect is shown, not the label**: Left on Speed draws 32X
  because the HOST said 32X, and the host's own `atarget=` goes 0.000 ->
  32.000 -> 0.000 with it.  A refusal is shown as one - a IIgs pressed towards
  the //e's watched floating bus comes back "served", because the backplane
  cannot answer for the GS's memory.  And the chain is live in both
  directions: "Standard Control Panel" opens Apple's own (its clock reading
  1:03 AM 9/16/26), whose Quit returns to ours redrawn from the host, whose
  Quit returns to the Desk Accessories menu - exactly what the stock panel's
  Quit does.

- **`tools/gs_cp_test.sh panel` is the row, and it PASSES** - R6's own rule was
  that an item is done only with its row green.  It also fixed a measurement:
  the first cut sampled `atarget=` one second after the key and read the
  PREVIOUS target, then read this one after the next key.  The host decides
  the answer the panel draws before it pushes the level down to the card
  (measured 3.0-3.5 s).  The row waits for the effect instead of sleeping for
  it, and prints how long it took - a fixed sleep would have made the verdict
  depend on which side of that gap it landed.  The four stock rows now reach
  Apple's pages THROUGH our panel, so every full run walks the chain as well;
  `columns` re-run that way still passes end to end, resets, restart and all.

**Later (not in this plan's scope)**: slot cards mb/u2/printer (latch at RES' + GS_BRAM
rebuilt — needs a BRAM resend and a swhost self-restart: BUS_ENABLE 0, `execv`); fd35 runtime
swap (no disk-switched path yet); clean ROM pages (4th wb_arb client, GS.md:1030); the
"ROMTOOLS" $F8 boot hook.

**R7 — the desk accessory (host only; 2026-09-16)**

The IIgs's other kind of accessory: a New Desk Accessory (NDA) is a file GS/OS loads from
`System:Desk.Accs` at startup and lists under the Apple menu of every desktop program. It cannot
replace the Control Panel (it is loaded far too late to choose a boot disk, and only desktop
programs have an Apple menu), but it is the right shape for the friendlier disk chooser the user
asked for. What is built so far is the way ONTO the disk; the chooser itself (the window in the
card's ROM) is the next rung.

*User decisions (2026-09-16):* a stub on the disk, the accessory proper in the card's ROM; the
stub is installed from our own panel — from the ROM's Option-Reset menu, before GS/OS has the
volume — into the boot image if it is a GS/OS disk and not already there.

- **The stub** (`firmware/gspanel/nda/stub.s` → `assets/swnda.bin`, 138 bytes): the NDA header
  (four routine pointers as 4-byte longs, period $FFFF, event mask $FFFF, the menu line
  `"--Strudelworks Disks\H**"` NUL-terminated — layout taken from System 6's own DESKMAKER and
  CONTROLPANEL, not from memory) and four routines that check for `SWCP` + header version ≥ 2 at
  `$E2/0000` and `JML` to `$E2/0010/14/18/1C`; without the card they return 0 in A/X/Y (an Open
  returning no window is allowed since System 4.0). **No absolute address in the code:** the
  loader puts the segment anywhere; the one subroutine is called `PER ret-1 / BRL` (the first cut
  used JSR and jumped into bank $04 of a System 6 boot in KEGS).
- **The file** (`src/gs_nda.cpp`): OMF v2.1, one code segment — LCONST of the stub, a 3-byte
  cRELOC per header pointer, END; type $B8, aux = stub format version (1). "Installed" = the bytes
  on the disk are exactly what would be written now; anything else with the name is "older" and
  replaced.
- **The writer** (`src/prodos_fs.cpp`): enough ProDOS to find `SYSTEM/DESK.ACCS`, create a
  seedling/sapling or a directory (growing a subdirectory by a block), read a file back, remove
  one, format a fresh volume for the tests. Entry numbers count the header as 1 (a System 6
  DESK.ACCS, ninth file in SYSTEM, says parent entry 10).
- **The rule** (`HdExecutor::touched`): nothing is written into a disk the machine has read or
  written since its last reset — GS/OS caches directories and the bitmap, and a file written
  under it would be lost or its blocks handed to another file. The panel refuses with the reason
  from a running GS/OS; from Option-Reset → 1 the disk is untouched and the install runs. Every
  look at and write into the image is a job on the disk thread (`HdService::run`), never on the
  ingest thread; the panel's row reads a copy and polls a BUSY flag until the job is done.
- **Suitable** = a ProDOS volume with `SYSTEM/START.GS.OS` and `SYSTEM/DESK.ACCS`, not
  write-protected, with room.

*Proven:* host tests `prodos_test` 79/79, `gs_nda_test` 58/58 (OMF parsed back independently);
**KEGS** boots System 6 with the stub installed, lists "Strudelworks Disks" in the Finder's Apple
menu, and choosing it on a machine without the card does nothing; **hardware** (host on the
`gs_ddr3pin` bit, no firmware change): from GS/OS the row reads `not on GSHARDDRIVE` and I is
refused; from Option-Reset → 1, I → `on GSHARDDRIVE` (log `desk accessory -> gsnda`), the file is
in the image, and the next boot's memory holds the menu line in bank $04 ($04/FD7E, $04/FCFE on the next run) — the loader took the
file. Panel sim walks (suite gs: gspanel_svc/set/wp/eject) PASS on the new panel image.
Ladder row: `tools/gs_cp_test.sh nda` (install refused / installed / loaded / removed) **PASSES on hardware** (2026-09-16).

*Next:* header version 2 with the four JML vectors in `crt0.s`; the chooser NDA itself in `$E2`
(a window with a drive pop-up, the image list from the host's `kPanelList`, Insert/Eject; 3.5"
eject through GS/OS's own driver — `DControl` — before the host swaps the image; the hard disk
as "choose and restart"); a second mailbox or SEI around the ROM-side routines so the CDA cannot
interrupt an NDA call mid-request.

## Verification summary
- Firmware (Verilator only): `sim/gspanel_run_main` runner, `mmu_xlate_gs_tb`, `boot_gs_tb`
  (xrom + PANEL_DMA modes, `--hdv` repeat), `sim/suite.sh battery` + `boot`; every build's WNS
  from `build/wns.sh`, a miss is not green; new deep tails named.
- Host (pi5 cross build, tests on the Pi): `gs_memory_test`, `gs_rom_patch_test`,
  `gs_panel_test`, existing suite; `firmware/build.sh --check` (both ROMs + gspanel).
- Effects ladder `tools/gs_cp_test.sh` (R0B onward): four-copy BRAM diff + per-setting
  effect after each reset path, stock panel first, then every item of ours.  Where a
  setting only shows in the PICTURE, `tools/png_pixel.py` reads the pixels out of a
  screenshot (zlib only, no image library on either machine) and the host's `tcol=`
  and `border=` say what the machine wrote to $C022 and $C034.
- Hardware (swhost stopped before every load; APPLE ON; verify from the mirror): MCP `status`,
  `peek E20000`, `raw adb 35 82`, `screen`, `key`; changes confirmed by `status`
  (accel/mem/fb/fd) and the conf's written-back keys; census at unlimited after R2.

## Tooling debt: screen observation (user, 2026-09-15)
The text screen as scripts see it (`TextRender::screen_text` → socket `screen` → MCP
`screen` / `wait_for_text`, `pi.sh ctl screen`, every `tools/*_test.sh` that greps it) folded
inverse, flashing and MouseText into plain letters: a highlighted menu item was
indistinguishable from the rest, and I twice pressed Return on the CDA menu's "Quit" believing
Control Panel was selected. The narrow fix (2026-09-15): `screen attr` (one attribute row per
text row) and the MCP screen tool marking inverse runs, `wait_for_text(inverse=True)`.
The screen's COLOURS had the same hole and are now readable two ways (the colour
rows above): `tcol=`/`border=` in the status line for what the machine wrote, and
`tools/png_pixel.py` over a screenshot for what was painted.
**Still to do:** audit every test and tool that keys on the screen (`tools/*_test.sh`,
`menu_test.sh`, `gs_test.sh`'s Control Panel walk, swmcp callers, the host unit tests over
`screen_text`) for checks that cannot actually observe what they claim - selections,
highlighted rows, cursor positions - and decide whether plain `screen` should carry the
attributes by default. Any menu-driving step in this plan verifies the selection from the
inverse run before pressing Return.

## Risks
- UNCONFIRMED user report (2026-09-15, not reproduced, not evidence): after setting Display to
  80 columns in the stock panel and rebooting, the GS got into a state where Ctrl-OA-Reset
  dropped straight into the monitor; cleared by booting from the boot-mode menu. The user also
  noticed the Control Panel itself stayed 40 columns (may be normal). R0B's ladder is where
  this either reproduces or is retired.
- Fork is young/SNES-oriented: 8-bit codegen first, runner diff-tested; fallback upstream
  llvm-mos `-mcpu=mosw65816` 8-bit.
- Page 0 $00-$1F exposed to interrupt handlers while C runs (same exposure as the stock panel);
  fallback D in page 1 + a D-independent `__call_indir`.
- Stream drops lose request writes: checksum + retry. PANEL_DMA vs HD_DONE collision: host gate
  + card drop counter.
- Timing: only a bank compare in the MMU class chain, a registered `dr_ppn`, and message-decode
  terms in hd_card — nothing on the fronts/dispatcher; WNS read each build.
- swhost restart while the panel runs re-sends ROM under it: don't; iline snooping of loader
  writes unverified.
