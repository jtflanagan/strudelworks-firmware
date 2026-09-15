# The GS Strudelworks Control Panel: our panel in front of the IIgs's own

Status: 2026-09-15, branch `gs_control_panel` (fw off master 67eed4e / host off 5245bdc), PLAN ONLY - no rung started.  Next: R0 (toolchain + CPU-level runner) and R0B (the Control Panel effects ladder, stock panel first).

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
  balance + D=0 matter. Self-test checksum bypass as KEGS: 0x36CB0 `D0 02` → `18 18`.
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

**R0B — Control Panel effects ladder, stock panel first (EARLY; no card/ROM change needed)**
Every panel feature — stock or ours — is only done when its EFFECT is shown, not when a byte
was written. This rung builds the observability and the test, and runs it on the stock panel.
- **Expected effects first**: for each row, establish from ROM 3 disassembly + KEGS what the
  setting is supposed to do and when (e.g. does Display 80 = BRAM $19 bring the machine up in
  80 columns after reset — $E1/02D9 is read at FF/8FA1, find the other readers — and does the
  stock panel draw in 40 or 80 regardless). Several BRAM offsets ($1D, $20, $28, RAM disk) are
  not established in either repo; the table records only verified offsets.
- **Observability today** (BRAM trace, 2026-09-15): the card's clock chip (`rtl/gs_clock.sv`)
  decodes like KEGS; $C033/$C034 are dispatcher-served, never fast reads, and never
  `fast_quiet`-dropped. But nothing can see the card's store: no readback register,
  `bram_ok`/`cnt_strobes`/`cnt_bad` (gs_io.sv:400/408, master_top.sv:946/1893) go nowhere; no
  socket dump of the host follower's image/state/sealed; no per-write log; `load_bram` doesn't
  say why it rejects a file. Only `peek E102C0 256`, the `bram :` log lines and the file.
- **Add**: (fw) a BRAM window register pair (index → byte) + GS_CLOCK_STAT {bram_ok,
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
  - the ROM's RAM copy ($E1/02C0) can be stale against the chip if no RES' followed GS_BRAM,
    so a Control Panel save could reseal over old bytes → bad checksum → ROM defaults on the
    next boot (hypothesis; the four-copy diff settles it).
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

**R2 — extended ROM load**
- `rtl/rom_loader.sv`: MEM_ROM word 0 bit 31 = absolute chunk `{1,15'd0,ppn16}` (no `seen`
  change, counts `xlanded` into MEM_ROM_STAT [23:16]); register `dr_ppn` at msg_end. No new
  message type, seam mux (master_top.sv:2003-2016) untouched. Host refuses ppns outside $E2-$EE.
- Host: key `gs_xrom = assets/gspanel.bin` (host_config.cpp parser + config_reference +
  README), load ≤64 KB multiple of 512, send BEFORE the base ROM in the loop at
  pipeline.cpp:1268-1331, check the `xlanded` delta, `AppleMemory::load_ext_rom` beside
  `load_gs_rom` (apple_memory.cpp:459).
- Bench: `boot_gs_tb` with XROM params sending absolute chunks. HW: MCP `peek E20000` = "SWCP".
- Measure the Nox map + desktop census at unlimited before/after (64 KB = 2 more pages per
  cache set; expected one-off eviction flushes, not a standing loss).

**R3 — ROM patch + panel v0 on hardware**
- `src/gs_rom_patch.{hpp,cpp}`: table `{addr, old[], new[], why}`; verify every old byte, apply
  all or none, refuse ROM 01; JML target from the ext ROM header, no header ⇒ no patch. Call
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

**Later (not in this plan's scope)**: slot cards mb/u2/printer (latch at RES' + GS_BRAM
rebuilt — needs a BRAM resend and a swhost self-restart: BUS_ENABLE 0, `execv`); fd35 runtime
swap (no disk-switched path yet); clean ROM pages (4th wb_arb client, GS.md:1030); the
"ROMTOOLS" $F8 boot hook.

## Verification summary
- Firmware (Verilator only): `sim/gspanel_run_main` runner, `mmu_xlate_gs_tb`, `boot_gs_tb`
  (xrom + PANEL_DMA modes, `--hdv` repeat), `sim/suite.sh battery` + `boot`; every build's WNS
  from `build/wns.sh`, a miss is not green; new deep tails named.
- Host (pi5 cross build, tests on the Pi): `gs_memory_test`, `gs_rom_patch_test`,
  `gs_panel_test`, existing suite; `firmware/build.sh --check` (both ROMs + gspanel).
- Effects ladder `tools/gs_cp_test.sh` (R0B onward): four-copy BRAM diff + per-setting
  effect after each reset path, stock panel first, then every item of ours.
- Hardware (swhost stopped before every load; APPLE ON; verify from the mirror): MCP `status`,
  `peek E20000`, `raw adb 35 82`, `screen`, `key`; changes confirmed by `status`
  (accel/mem/fb/fd) and the conf's written-back keys; census at unlimited after R2.

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
