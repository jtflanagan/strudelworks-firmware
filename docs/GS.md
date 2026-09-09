# Apple IIgs on the card: the run sheet

Status: **RUNGS 0 AND 1 DONE, 2026-09-08; next rung 1b (64-bit event records)
and rung 2 (the GS map), independent of each other.** Branch `gs_emulation` in both
repos, taken from master at fw `62b21ab` / host `98d46d2` (the
`memory_refactor` merge). No bitstream yet; the IIe design is untouched and
stays bit-identical at `GS=0`.

The plan itself (inventory, decisions, memory-path design, rung ladder) was
written with the user on 2026-09-08 and is reproduced here so the sheet stands
alone. KEGS 1.38 at `/home/flana/repos/kegs.1.38` is the behavioural
reference; AppleWin stays the reference for the IIe-compatible parts.

## What this is

A soft 65816 runs the GS ROM and GS/OS entirely from the card's 24-bit
physical space, inside the physical Apple IIe, reaching out to the real
backplane only for the `$Cxxx` addresses the IIe actually provides (keyboard
sampling, game port, a physical slot card). The IIe's RAM, ROM and video are
not used; the host draws the GS picture on HDMI as it draws the IIe's.

## Decisions (the user's, 2026-09-08)

| question | decision |
|---|---|
| ROM | ROM 3 first (256 KB, banks $FC-$FF). ROM 01 later as a config key. |
| GS chipset logic | RTL state machines on the card: ADB micro, clock/BRAM, SCC stub, VGC registers, interrupt controller, DOC. The host supplies events and persistence. |
| Build | Separate `--gs` build. A `GS` top-level parameter on master_top / apple_mmu / accel_seq; `build.sh --gs` sets it; the plain build is bit-identical at GS=0 and the IIe battery is the parity check. |
| First milestone | GS/OS 6.0.1 Finder with mouse and keyboard, SHR desktop on HDMI, booted from the slot-7 SmartPort HDC. Sound is the milestone after. |
| Inputs | Pi keyboard + mouse as ADB devices AND the real IIe keyboard (the dummy-cycle $C000 sample) into the same key buffer; Open/Closed Apple from the real game-port buttons. |
| Disks | IWM stub (no 3.5" drive, no SmartPort device, so the ROM's scan ends, as KEGS does) + the existing slot-7 HDC and slot-6 Disk II as "Your Card" slots. 3.5" IWM later. |
| Speed | The governor follows $C036: speed bit clear = 1.0 ops per bus cycle, set = the configured fast target (default 2.8, unlimited allowed). All timers in virtual time. |
| System image | Fetching and building a bootable GS/OS 6.0.1 image is part of the plan. |
| Event record | 64-bit event records, uniform for the 65C02 and the 65816: the 24-bit regime needs the bank on every record; the spare bits find uses as the work proceeds. Done on the IIe build first (rung 1b). |

## ROM images

Imported 2026-09-08 into `strudelworks-host/assets/` (never pushed):

| asset | bytes | md5 | provenance |
|---|---|---|---|
| `apple2gs_rom3.bin` | 262144 | `0b1fb6455a7c0932d5fdd8843c035704` | `Apple IIGS ROM 3 Tenspeed Late 1988 Early 1989 v25.bin`, plain layout (offset 0 = bank $FC, reset vector $FA62 at the end of bank $FF), used as is |
| `apple2gs_rom1.bin` | 131072 | `20a0334c447cb069a040ae5be1d938df` | `Apple IIGS ROM 01 - 342-0077-B.bin` (md5 `56fa9ed32b6d38e62c4d3f1c00937581`) with its two 64 KB halves SWAPPED on import: the dump had bank $FF first. This is the dump KEGS's README warns about. |

KEGS's one ROM 3 patch is copied at load: offset `0x357C9 = 0x00` fixes a
SmartPort routine that writes the IWM status into `$C036` (config.c:1262).
The self-test and speed tests stay unpatched.

## The hardware inventory

"where": CARD = RTL in the `--gs` build, HOST = swhost, REAL = the physical
IIe through a real bus cycle. "M" = milestone (1 GS/OS Finder, 2 sound,
3 later). KEGS files are the behavioural source for each row.

### CPU

| feature | where | M | notes |
|---|---|---|---|
| 65816: all opcodes native + emulation, 16-bit regs, 24-bit address, decimal, MVN/MVP, vectors ($FFE4-$FFEF native, $FFF4-$FFFF emulation, bank 0), E-mode stack wrap, WAI/STP; ABORT unused | CARD | 1 | `rtl/cpu65816.sv` finished and verified per instruction against SingleStepTests/65816 (`sim/fetch_65816_tests.sh` exists). VDA/VPA/VPB added so the bench can tell internal cycles from accesses. |
| Split interface for the fronts (`i_din/d_din`, `cyc_is_i`, `pc_addr[23:0]`, `d_pred[23:0]` + bank class, `p_flags`, `bank_wr`) | CARD | 3 | Not needed for milestone 1: the core rides the ~9-clock dispatcher first (~11 M cycles/s, ~4x a 2.8 MHz GS). |
| $C036 bit 7 speed -> governor target | CARD | 1 | `accel_seq`'s governor already takes ops per bus cycle. |

### Memory (FPI / Mega II)

| feature | where | M | notes (KEGS moremem.c) |
|---|---|---|---|
| Physical layout: RAM $00-$7F (8 MB), Mega II slow RAM $E0/$E1, ROM $FC-$FF, one write-protected VOID page for unpopulated banks $80-$DF/$F0-$FB (reads return its bytes, writes drop, so the ROM's sizing finds 8 MB) | CARD + HOST | 1 | The 16 MB space maps 1:1; RamWorks steering (`RW_BANKS`, $C071/$C073) is off at GS=1. |
| IIe switches applied identically in $00/$01 and $E0/$E1 (ALTZP, RAMRD/RAMWRT, 80STORE/PAGE2/HIRES, LC, INTCXROM/SLOTC3ROM) | CARD + HOST | 1 | Bank classes in front of the region table: PAIR ($00/$01, $E0/$E1), RAM, VOID, ROM. Pair side = `va[16] | aux`. |
| STATEREG $C068 r/w (ALTZP, PAGE2, RAMRD, RAMWRT, RDROM, LCBANK2, ROMBANK, INTCXROM) | CARD + HOST | 1 | One write sets seven existing switch registers. |
| SHADOW $C035: writes to $00/$01 text1/text2/hires1/hires2/SHR/aux-hires also land in $E0/$E1 unless inhibited; bit 6 inhibits I/O + LC in $00/$01 | CARD + HOST | 1 | Second posted write (design below). Bit 6 = the `flat` map MEMORY_REFACTOR.md anticipated; fold off under it. |
| $C036 bit 4 shadow-in-all-banks | CARD + HOST | 3 | One term; NFC Megademo only. |
| $C02D SLOTROMSEL, INTCXROM/INTC8ROM, $CFFF: $C1xx-$C7xx internal ROM vs on-card card vs REAL slot | CARD + HOST | 1 | Extends `q_slot`/`slot_switches.sv`. |
| $C071-$C07F reads return ROM | CARD | 1 | Byte-level override beside `$CFFF` in `xlate`. |
| ROM load 256 KB: MEM_ROM generalised to a physical-page message (`{ppn, half}` per chunk, landed count vs expected) | CARD + HOST | 1 | 512 chunks, host polls MEM_ROM busy instead of sleeping. The loader dirties every ROM page; the first boot flushes them once. |

### Video (VGC)

| feature | where | M | notes (KEGS video.c) |
|---|---|---|---|
| Legacy modes displayed from $E0/$E1 | HOST | 1 | `BeamRender`/`cell_render`/`ntsc` unchanged; `AppleVideo::follow` reads the Mega II banks. |
| SHR 320/640, SCBs $E19D00, palettes $E19E00, fill | HOST | 1 | `shr_render.cpp` already does it from a 64 KB image; the source becomes bank $E1. |
| Per-scanline palette writes (3200 colour) | HOST | 3 | Needs per-line snapshots from virtual time. |
| Border $C034[3:0] | HOST | 1 | Latched, unpainted today. |
| Text/background colour $C022 | HOST | 1 | The TODO at `cell_render.hpp:52`. |
| NEWVIDEO $C029, MONOCHROME $C021, LANGSEL $C02B, CHARROM test $C02C | CARD face + HOST | 1 | Readable on card; the host acts on the writes in the stream. |
| VERTCNT/HORIZCNT $C02E/$C02F | CARD | 1 | From `vbeam.sv` (semantics moremem.c:2172-2277). |
| VBL $C019 with GS polarity | CARD | 1 | |
| Scan-line interrupt (SCB bit 6) | CARD | 1 | 200-bit side copy of SCB bit 6 snooped from writes landing at $E1/$9D00-$9DC7 (the `fb_sim` tap pattern). |
| Frame 262 x 65 = 17030 cycles, 59.92 Hz | CARD | 1 | Same as the IIe; `vbeam`/`vbl_lock` unchanged. |

### Interrupts

| feature | where | M | notes |
|---|---|---|---|
| `gs_intc.sv`: VBL, quarter-second (every 16 frames), one-second (every 60), scan line, ADB data/SRQ/mouse, DOC, SCC stub, Mockingboard, mouse card, real backplane IRQ' | CARD | 1 | Today's IRQ is one AND at `master_top.sv:541`. |
| INTEN $C041, INTFLAG $C046 (read copies b7->b6), CLRVBLINT $C047 (read or write) | CARD | 1 | |
| VGCINT $C023 (enables b1/b2, status b5/b6/b7), SCANINT $C032 | CARD | 1 | |
| NMI | CARD | 3 | Stays tied off. |

### ADB

| feature | where | M | notes (KEGS adb.c) |
|---|---|---|---|
| ADB micro at $C026/$C027: abort, flush, set/clear modes, set config, SYNC (8 bytes on ROM 3), r/w ADB RAM, read modes/config, version (6 for ROM 3), char sets, layouts, reset, send keycode, $12/$13, Listen/Talk reg 0/3 | CARD | 1 | `gs_adb.sv`: FSM + 256 B ADB RAM in LUTRAM. ADB RAM $1400/$1401 read $72/$F7 (self-test checksum). |
| KMSTATUS $C027 bits | CARD | 1 | |
| Keyboard: $C000 ASCII + strobe, $C010 clear + any-key-down, $C025 modifiers, 8-deep buffer, auto-repeat from set-config | CARD | 1 | Sources: Pi evdev keyboard via a new ADB_KEY message (keycode, modifier byte, up/down); real IIe keyboard from the dummy-cycle $C000 latch as ASCII; real game-port buttons as Open/Closed Apple. |
| Mouse $C024: alternating X/Y deltas +-63, button in bit 7 on the Y read; mouse interrupt | CARD | 1 | Pi evdev mouse via the existing MOUSE_MOVE feed. |
| Ctrl-Apple-Reset, Ctrl-Apple-Option-Reset self-test, Ctrl-Apple-Esc Desk Manager (interrupt byte bit 5) | CARD | 1 | The ROM samples $C061/$C062 after reset. |

### Clock and battery RAM

| feature | where | M | notes (KEGS clock.c) |
|---|---|---|---|
| $C033/$C034 protocol: seconds since 1904, test/write-protect regs, BRAM $00-$FF (two address forms); $C034[3:0] is the border | CARD | 1 | `gs_clock.sv`: FSM + 256 B BRAM. Time seeded by the host (the NSC_TIME pattern). |
| BRAM persistence | HOST | 1 | The host mirrors BRAM writes from the stream and reloads at start (`gs_bram` file). All-zero BRAM boots. Preset slots 6/7 = Your Card. |

### Sound

| feature | where | M | notes (KEGS doc.c, sound.c) |
|---|---|---|---|
| Sound GLU $C03C-$C03F: control (RAM/register, auto-increment, volume), data with one-access read delay, 16-bit address | CARD | 1 | Register face at milestone 1: the ROM sizes DOC RAM at boot and reads $E1/$E2. |
| DOC 5503 on card: 32 oscillators, 64 KB sound RAM (16 RAMB36 inside the module, not CPU-addressable), freq/volume/waveptr/control/wavesize, free-run/one-shot/sync/swap, interrupt register $E0, osc-enable $E1, A/D $E2 = $80, scan 894.886 kHz / (osc_en+2) | CARD | 2 | Oscillators on card because their interrupts are music-player timers. L/R into `audio_sampler.sv` as two more channels (one more DSP48). |
| Host mixer: two DOC channels, master volume | HOST | 2 | `card_audio.cpp` `mix_one`; `proto::audio::Sample` grows. |
| Speaker $C030 | CARD | 1 | `speaker.sv` as today. |

### Disk

| feature | where | M | notes |
|---|---|---|---|
| IWM stub $C0E0-$C0EF + DISKREG $C031: phases, motor, drive select, Q6/Q7, mode register, 3.5" status "no drive / no disk", ENABLE2 handshake so the SmartPort scan ends | CARD | 1 | KEGS iwm.c:912-1282. |
| SmartPort HDC slot 7 (existing) boots GS/OS; Disk II slot 6 (existing) | CARD + HOST | 1 | |
| 3.5" drives through the IWM; $C036[3:0] motor-detect speed drop | CARD + HOST | 3 | |

### Serial

| feature | where | M | notes |
|---|---|---|---|
| SCC stub $C038-$C03B: reset values (WR15=$F8, WR11=$08, WR4=$04, DCD A=1 / B=0, tx empty), RR0/RR1/RR3, WR0 pointer protocol | CARD | 1 | KEGS scc.c:110-197. |
| Real serial | HOST | 3 | |

### The real IIe board in GS mode

| access | policy |
|---|---|
| $C000/$C010 | served by the ADB model; the dummy cycles keep sampling the real keyboard as an input |
| $C030 | on card |
| $C061-$C067, $C070 game port | REAL |
| $C058-$C05F annunciators | REAL write-through + on-card AN3 for dhires |
| $C0nX, $Cnxx, $C800-$CFFF, $CFFF for a slot that is neither internal ROM ($C02D) nor on-card | REAL: a physical card in the IIe is a "Your Card" slot |
| everything else in $C000-$CFFF | on card (`gs_io.sv`, a new `CLS_IO` class; cls widens to 3 bits) |
| RAM/ROM | card memory; the bank byte never reaches the IIe pins |
| dummy cycles | continue; the IIe's video and `vbl_lock` keep the frame reference |
| after reset | the card parks the motherboard at INTCXROM=0 / SLOTC3ROM=1 with two bus writes (the "fixed backplane" CXXX.md rejected for the IIe is right for the GS) |

### Host

| feature | notes |
|---|---|
| Wire format v6: 64-bit event record, uniform for the IIe and the GS | The 32-bit event word is full and a 24-bit regime needs the bank on every record. Every event (bus, fast, SKIP) becomes two words. Layout proposal, fixed in `docs/PROTOCOL.md` at rung 1b: word 0 = `{tag[3:0], flags[3:0] (vbl, sync, res, rw), bank[7:0], addr[15:0]}`, word 1 = `{data[7:0], class[3:0] (bus / fast / dummy / shadow-dup / DMA), cpu[3:0] (E, M, X, irq-taken), spare[16]}`. SKIP keeps its 28-bit count in word 0, word 1 spare. The IIe build carries bank = 0. Spare-bit candidates: the vbeam position, the map-change/settle mark, a seam producer id, a cycle-count delta. Full capture doubles to 8 B/cycle (11 MB/s at 1 MHz, 22 MB/s at 2.8 MHz), inside the link and the ring budget in `docs/DDR3_USAGE.md`. |
| `AppleMemory::classify()` GS model | STATEREG, SHADOW, pair banks, ROM $FC-$FF, flat banks. `tests/memory_test.cpp`'s replay harness carries over with a new oracle from the firmware's GS sweep. |
| Config keys `machine = iie | iigs`, `gs_rom`, `gs_speed = normal | fast | unlimited`, `gs_fast_target`, `gs_bram` | config-file-only rule; the runtime menu shows SYSTEM SPEED. |
| ADB input feed | `pi_keyboard`/`pi_keymap` above the ADB_KEY message; MOUSE_MOVE reused. `KeyTypist`'s resolved-count protocol is replaced by the ADB buffer's own flow control. |
| GS/OS 6.0.1 image | fetch Apple's 6.0.1 disk set, build a bootable 32 MB ProDOS volume with the installer under KEGS on WSL, put it in `$PI_DISKS`; the HDC takes .po/.hdv/.2mg already. |
| MCP/control: `machine`, `status` report speed, shadow, statereg | verification from the mirror |

## The memory path, as designed

**Translation.** `apple_mmu`'s query ports grow to 24 bits. Bank classes in
front of the region table: PAIR ($00/$01, $E0/$E1) uses the table with side
`{va[23:17], va[16] | (bsel == AUX)}` (an odd bank named directly is itself);
RAM $02-$7F identity; VOID one write-protected page `{$FB,$00}`; ROM $FC-$FF
identity, cls ROM. The region table splits `R_RAM` into `R_TXT2 $08-$0B`,
`R_HGR2 $40-$5F`, `R_SHR $20-$9F` (bank 1) so SHADOW inhibits per region
(NREG 10 -> 13, `rt_rd_flat` 70 -> 117 bits, the fronts' `rv1` mux 13:1). An
entry gains `sh`. New switch state (SHADOW, CYAREG[4], STATEREG, SLOTROMSEL)
joins `map_q` so `map_changed` and the settle cover it. Under SHADOW bit 6 the
$Cxxx/$Dxxx/$Exxx regions of banks $00/$01 become identity RAM with the fold
OFF (or a `$D000` write lands in page `$C0`).

**SHADOW = a second posted write, not an alias.** An alias (one copy in
$E0/$E1) breaks off-screen drawing with shadowing off and read-back through
bank 0 (double-buffered SHR, hires collision) and every trace compare. Instead
a single holding register at the classified stage captures `{ppn | $E000,
off, data}` for any write with `sh`; it is the seam's fourth producer at the
highest priority, so the drain order is original, dup, next; `d_pending` and
dline's `pending` include `shd_valid` so nothing reads $E0/$E1 past the dup.
Cost ~8 seam clocks per shadowed write, ~40 flops. `fb_sim`'s tap moves to
$E0/$E1 landings.

**Fronts with a bank byte (rung 6, after the Finder).** From the microcode's
bank sources (ZERO, DBR, PBR, DIN, AGU): the ROM and assembly code are
ZERO/DBR-dominated; long addressing (DIN) rides the dispatcher, counted.
Virtual tags stay 16-bit; each line gets two registered valid bits `cv_b0` and
`cv_dbr` recomputed by the existing revalidation stage (the bank compare done
twice); DBR and PBR join `map_q` so a bank-register change is a map change;
the core exports `d_pred_bcls` (ZERO/DBR/OTHER) and `bank_wr`, and
`accel_seq`'s settle takes `bank_wr` as a second trigger (the JSL/PLB hazard).
Wider tags were rejected on the known worst path; per-bank revalidation alone
is unsound.

**Cache pressure.** ROM 3 alone is 1024 pages, the whole 128x8 cache; the GS
working set evicts where the IIe never did. `MEM_FILLS/MEM_FLUSHES` become
the GS performance metric. 256x8 does not fit the block RAM budget (49 free:
65816 microcode 8, DOC RAM 16, small side copies).

## The rung ladder

Each rung: sims green (Verilator), build WNS >= +0.039 with no new deep tail,
then hardware; explain before every run. `GS=0` keeps the IIe battery as the
parity check on every rung that touches shared RTL.

| rung | what | gate | status |
|---|---|---|---|
| 0 | Merge, branch, ROM import, this sheet, KEGS with a per-instruction trace to a file (its `Pc_log` ring streamed) and the clock pinned, so a deterministic reference trace of ROM 3 from reset exists for `trace_diff` | reference trace produced | **DONE** - `tools/kegs/` (patch, `trace_rom.sh`, `decode_trace.py`, README); 5M-instruction ROM 3 trace regenerates in seconds: starts at `00/FA62`, after 5M instructions (7.6M cycles) the ROM sits in the startup-device poll loop at `FF/CFA2..CFDC` calling `E1/0000` |
| 1 | 65816 core complete: ALU/flags/decimal, MVN/MVP, vectors, E-mode stack rules, VDA/VPA/VPB. `sim/run_cpu816_trace.sh` (`cpu816_trace_main.cpp` + `cpu816_tests.py`) drives SingleStepTests cases: state in, one instruction, every cycle's address/direction/data/VDA/VPA/VPB, the count, the final registers and memory. `gen_cycle_table816.py` carries over; the pipeline-equivalence bench is retired (its reference predates the ROM format). OOC synth on the 100T | sampled tests pass with the bus lines compared; OOC WNS >= 0 at 10 ns | **DONE 2026-09-08**: 981,610 tests (1 MB per opcode file, both modes) 0 failures; OOC on xc7a100t-2: 1004 LUTs, 282 flops, 8 RAMB36, 119.9 MHz at a 7.5 ns push. Thirty-odd bugs found and fixed, listed in docs/UCODE816.md. FULL=1 (2.9 GB) not yet run. |
| 1b | Wire format v6, 64-bit event records, on the IIe build first. Card: `apple_bus_read.sv`, `event_merge.sv`, `bus_event_filter.sv` SKIP, `synth_bus_events.sv`, `bus_event_capture.sv`, `tx_ring.sv` (two words per record, whole records per line), `ft601_msg_tx`, `docs/PROTOCOL.md`. Host: `BusEvent`/encode/decode, `SparseFilter`, `TraceWriter` (`.swbt` version bump, old captures readable), `link_parser`, `mock_card`, `demo_source`, every `apply()` consumer. Independent of rung 1 | IIe boot bench and battery unchanged; host tests pass on both capture versions; HW: `mem_test.sh`, `fb_test.sh`, `accel_test.sh` green, mirror mismatches unchanged, full capture at 1 MHz sustained | |
| 2 | GS map on the MMU, bench-only: bank classes, 13 regions, `sh`, the shadow dup register, STATEREG/SHADOW/SLOTROMSEL, `$C071-$C07F`, the VOID page, the MEM_ROM page message. `mmu_xlate_gs_tb`: a KEGS-derived oracle (`setup_pageinfo`/fixups ported) swept over switch states x SHADOW x bank classes x 256 pages, read and write. `mem_integ_tb` gains a cross-bank write, a dup landing, a read-after-shadowed-write ordering check | 0 mismatches; IIe sweep unchanged (16384 maps, 0); battery at GS=0 unchanged | |
| 3 | `--gs` build boots ROM 3 in Verilator: the 65816 through the dispatcher (no fronts), `gs_io.sv` (VGC regs, `gs_intc`, `gs_adb`, `gs_clock`, IWM stub, SCC stub, sound GLU face), `boot_gs_tb` from reset with ROM 3 through the seam, `trace_diff816.py` against the KEGS trace to the startup-device scan. Host: wire v6, GS classify, ROM load, `machine = iigs`, ADB_KEY, mock_card | zero divergence to the scan; the host mirror equals the bench image | |
| 4 | First light on hardware: `build.sh --gs`, load, "Check startup device" / Control Panel via the Pi keyboard and the real IIe keyboard, the text screen on HDMI from $E0, the self-test (Ctrl-Apple-Option-Reset) at the 2.8x governor | self-test pass; Control Panel navigable | |
| 5 | GS/OS Finder (milestone 1): the GS/OS 6.0.1 image built; the slot-7 HDC boots it; SHR from $E1, border, $C022; ADB mouse; BRAM persistence; `tools/gs_test.sh` | Finder desktop on HDMI, a window opens by mouse, screenshot from the mirror | |
| 6 | Speed: the split interface + a predict contract bench; the fronts widened per the design (measured first at GS=1 on the IIe map with the accel battery, then on GS/OS); the `$C036` governor; a census of OTHER-class candidates, `bank_wr` settles, dup waits, fills/flushes | WNS gate; battery 98/0; the IIe build untouched | |
| 7 | Sound (milestone 2): the DOC on card + mixer channels; a SoundSmith/NinjaTracker player against a KEGS recording | audible, interrupts timed | |
| 8 | Later: 3.5" IWM, ROM 01, real serial, 3200-colour palettes, shadow-in-all-banks | | |

## Verification

- `sim/suite.sh` gains `gs` (the GS xlate sweep, a cpu816_trace sample,
  boot_gs); the IIe suites keep their counts. `tools/check_ports.py` and
  `sim/lint.sh` every rung.
- Host: `tests/gs_memory_test` (replay against the GS oracle), `shr_test` for
  the $E1 source, `mock_card` speaks v6; cross-build via the pi5 preset.
- Hardware: `tools/gs_test.sh` in the `*_test.sh` shape (own conf, Apple on,
  wait/idle discipline), asserting on `screen`/`peek` from the mirror; MCP
  `screenshot` for SHR.
- Reference: the KEGS trace for the boot; KEGS on WSL for behaviour questions.

## Risks

- Timing lives in rung 6 (the fronts), which milestone 1 does not depend on.
- Block RAM: 49 RAMB36 free; the 65816 takes 8, the DOC 16, side copies a
  few; ~20 spare. The cache cannot grow; GS working sets will evict.
- The shadow dup doubles seam traffic for shadowed writes; bounded, measured.
- A 65816 in emulation mode is not the 65C02 cycle for cycle; a real slot
  card in the IIe sees a GS-like CPU, which is what a real GS gives it.
- GS/OS image sourcing is host-side work with KEGS as the installer.
