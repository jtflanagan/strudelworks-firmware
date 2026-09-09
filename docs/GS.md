# Apple IIgs on the card: the run sheet

Status: **RUNGS 0, 1, 1b, 2 AND 3a DONE; 3b's TRACE GATE MET, 2026-09-09** (1b
proven on hardware; the rest in simulation, which is what those rungs are).
The IIgs memory map is built and swept against a model taken from KEGS: 3584
maps, 67,092,493 checks, 0 mismatches.  **The soft 65816 boots the real ROM 3
on the card's memory path and agrees with KEGS for 67,398 collapsed
instruction events - 202,308 instructions, zero divergence - all the way to
the STARTUP-DEVICE SLOT SCAN**, which is where rung 3's gate put the end of the
comparison: past it KEGS boots its own emulated cards and this machine boots
the ones it has.  **NEXT is the rest of the chipset** (VGC registers,
`gs_intc`, the IWM and SCC stubs), built against KEGS's behaviour directly
rather than against the index, and the card's own slot 6 and slot 7 in the
bench.  Nothing of the GS has run on hardware yet.  Branch `gs_emulation` in
both repos, taken from master at fw `62b21ab` / host `98d46d2` (the
`memory_refactor` merge).  No bitstream yet; the IIe design is untouched and
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

**The pair side stays OUT of the region table.**  On the IIe a region's
answer is a function of the switches alone, which is what lets the table be
one entry per region and lets a front revalidate a held line from a stored
4-bit region index.  On the GS that breaks: bank $00 and bank $01 at $2000
are the same region under the same switches, but they land in different
physical banks and shadow to different destinations ($E0 against $E1).  The
side is therefore applied in `xlate()` AFTER the table lookup - an odd bank
named directly is itself, an even bank goes through the switches - which
keeps `rt_rd_flat` and the fronts' index exactly as they are.  The price is
recorded here rather than discovered later: WHEN THE FRONTS ARE TURNED ON
FOR THE GS (rung 6) the side must join their revalidation index, because a
line filled in bank $01 must not revalidate against bank $00's entry.  The
fronts are off in the GS build until then.

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

Each rung: sims green (Verilator), the build meets timing with no failing
endpoints and no systematic new long-chain problem, then hardware; explain
before every run.  There is no magic slack figure: build-to-build spread on
identical source is tens of picoseconds here, so a particular positive WNS is
placement noise and not a grade.  What is worth reading is the long-chain
census by source register (the user's method), because a chain that meets
timing is still pressure. `GS=0` keeps the IIe battery as the
parity check on every rung that touches shared RTL.

| rung | what | gate | status |
|---|---|---|---|
| 0 | Merge, branch, ROM import, this sheet, KEGS with a per-instruction trace to a file (its `Pc_log` ring streamed) and the clock pinned, so a deterministic reference trace of ROM 3 from reset exists for `trace_diff` | reference trace produced | **DONE** - `tools/kegs/` (patch, `trace_rom.sh`, `decode_trace.py`, README); 5M-instruction ROM 3 trace regenerates in seconds: starts at `00/FA62`, after 5M instructions (7.6M cycles) the ROM sits in the startup-device poll loop at `FF/CFA2..CFDC` calling `E1/0000` |
| 1 | 65816 core complete: ALU/flags/decimal, MVN/MVP, vectors, E-mode stack rules, VDA/VPA/VPB. `sim/run_cpu816_trace.sh` (`cpu816_trace_main.cpp` + `cpu816_tests.py`) drives SingleStepTests cases: state in, one instruction, every cycle's address/direction/data/VDA/VPA/VPB, the count, the final registers and memory. `gen_cycle_table816.py` carries over; the pipeline-equivalence bench is retired (its reference predates the ROM format). OOC synth on the 100T | sampled tests pass with the bus lines compared; OOC WNS >= 0 at 10 ns | **DONE 2026-09-08**: 981,610 tests (1 MB per opcode file, both modes) 0 failures; OOC on xc7a100t-2: 1004 LUTs, 282 flops, 8 RAMB36, 119.9 MHz at a 7.5 ns push. Thirty-odd bugs found and fixed, listed in docs/UCODE816.md. FULL=1 (2.9 GB) not yet run. |
| 1b | Wire format v6, 64-bit event records, on the IIe build first (PROTOCOL.md "The event record"). Card: `apple_bus_read.sv`, `synth_bus_events.sv`, `event_merge.sv` (class 1 fast / 2 dummy), `bus_event_filter.sv` (SKIP = a record), `bus_event_capture.sv` (64-bit FIFO, 127 records a frame, two words each, `captured` in records); the ring and the link move words and needed nothing. Host: `proto::Record`, `BusEvent` + bank/cls/cpu, the parser assembles records and faults on an odd payload, the ring, the trace writer (file version 2, 8-byte records; version-1 files refused), the sparse filter, the sources, the mock card, every `apply()`, the three trace tools; the firmware's two `.swbt` readers likewise. | IIe battery unchanged; host tests pass; HW: `mem_test.sh`, `fb_test.sh`, `accel_test.sh` green, mirror mismatches unchanged, full capture at 1 MHz sustained | **DONE 2026-09-08.** Sims: battery 34/34 (accel_vl 98/0), filter and capture benches reworked, trace self-test passing; host 36/36 on the Pi (`tools/pi_tests.sh`, new: ships and runs the cross-built suite). Build: timing met, 0 failing endpoints, and 28,941 LUTs against 32,179 BEFORE the change - the merge-queue rewrite saved more than the wider record cost. HW: boots to Applesoft and computes correctly at 1x and at 48x; 149,781,258 fast-op records delivered with the mirror's mismatch count frozen and zero merge overflows, drops, torn messages or unknown types. |
| 2 | GS map on the MMU, bench-only: bank classes, 13 regions, `sh`, the shadow dup register, STATEREG/SHADOW/SLOTROMSEL, `$C071-$C07F`, the VOID page, the MEM_ROM page message. `mmu_xlate_gs_tb`: a KEGS-derived oracle (`setup_pageinfo`/fixups ported) swept over switch states x SHADOW x bank classes x 256 pages, read and write. `mem_integ_tb` gains a cross-bank write, a dup landing, a read-after-shadowed-write ordering check | 0 mismatches; IIe sweep unchanged (16384 maps, 0); battery at GS=0 unchanged | **DONE 2026-09-09** - part 1 the scaffolding, part 2 the map itself with its own oracle. Part 1 (2026-09-08): a `GS` parameter; the region set 10 -> 13, splitting text page 2, hires page 2 and the rest of the SHR range out of plain RAM; the entry's new `sh` bit at the TOP so xlate and both fronts decode unchanged; the $C035/$C036/$C068/$C02D registers, inert at GS=0; the four bank classes (PAIR, RAM, VOID, ROM) in `xlate()`. Gate met: IIe sweep 16384 maps / 33,347,584 checks / 0 mismatches, battery 34/34. Part 2 (2026-09-09): the query ports widened to 24 bits, `sh` exported on the classified op and the write query, `$C071-$C07F` reading ROM, the I/O-and-language-card inhibit, and **`sim/mmu_xlate_gs_tb.sv`** - a model written from KEGS's own fixups, not from the RTL, sweeping 12 banks x 256 pages x read/write over all 128 SHADOW states and the language card's: **3584 maps, 67,092,480 checks, 0 mismatches**, with the IIe sweep still 16384/33,347,584/0 and the battery 34/34. The oracle found three bugs in the RTL it was written against - the two windows of the I/O inhibit implemented the wrong way round, a Mega II test written on bank bit 1 (which is 0 for $E0 as it is for $00, so the guard never fired), and the region table's fold inherited by bank classes that have no language card. Part 3 (2026-09-09) closes it: `$C02D` read by the map (a slot page is the INTERNAL ROM's unless its bit is SET, or INTCXROM overrides - so a IIgs comes up with every slot page internal where a IIe comes up with them the slots'; bit 3 IS SLOTC3ROM, one register with the $C00A/B strobe, which is why the IIe's $C3 rule falls out of the IIgs's); the SHADOW DUPLICATE, emitted one clock behind its op down the same path a posted write takes, one deep with a drop counter a bench asserts is zero; and `rtl/rom_loader.sv` parameterised on `N_CHUNKS`/`ROM_PPN0` so one message loads any run of physical pages, with the host's chunk count following the ROM's size. Final: GS sweep **3584 maps, 67,092,493 checks, 0 mismatches** including twelve duplicate-landing cases; IIe sweep 16384/33,347,584/0; battery 35/35; host 36/36 on the Pi. |
| 3a | The machine exists and fetches: the bank byte on the unified op stream and into the classifier's 24 bits, the 65816 on the dispatcher at `GS=1` (no fronts), `sim/boot_gs_tb.sv` booting ROM 3 through the seam, `tools/trace_diff816.py` | the ROM runs; the divergence index measured and pinned; the IIe unmoved | **DONE 2026-09-09** - see below |
| 3b | `gs_io.sv`: the IIgs chipset's register faces - ADB micro, the map's own registers, `gs_clock` + battery RAM, VGC, `gs_intc`, the IWM and SCC stubs, the sound GLU face - answered on the card instead of by the backplane | the divergence index moves; `boot_gs_tb`'s floor raised | **IN PROGRESS**: ADB micro, the map registers and the clock done, 41,877 -> 67,398 events |
| 3c | The rest of the chipset (VGC registers, `gs_intc`, IWM and SCC stubs, the sound GLU face) and the host side: the GS map in the mirror, `machine = iigs`, `gs_rom` | the ROM runs past the chipset with no spin; the host's map agrees with the card's | **DONE 2026-09-09** - see below |
| 3d | **Boot from the slot-7 SmartPort**: the battery RAM preset so `$C02D` marks slot 7 "Your Card" (else its page stays internal ROM and the scan never looks), `hd_card` in `boot_gs_tb` with the bench playing host, ADB_KEY, `mock_card` speaking a GS stream, and the mirror replayed against the bench image | the ROM's scan finds slot 7 and boots the image | |
| 4 | First light on hardware: `build.sh --gs`, load, "Check startup device" / Control Panel via the Pi keyboard and the real IIe keyboard, the text screen on HDMI from $E0, the self-test (Ctrl-Apple-Option-Reset) at the 2.8x governor | self-test pass; Control Panel navigable | |
| 5 | GS/OS Finder (milestone 1): the GS/OS 6.0.1 image built; the slot-7 HDC boots it; SHR from $E1, border, $C022; ADB mouse; BRAM persistence; `tools/gs_test.sh` | Finder desktop on HDMI, a window opens by mouse, screenshot from the mirror | |
| 6 | Speed: the split interface + a predict contract bench; the fronts widened per the design (measured first at GS=1 on the IIe map with the accel battery, then on GS/OS); the `$C036` governor; a census of OTHER-class candidates, `bank_wr` settles, dup waits, fills/flushes | WNS gate; battery 98/0; the IIe build untouched | |
| 7 | Sound (milestone 2): the DOC on card + mixer channels; a SoundSmith/NinjaTracker player against a KEGS recording | audible, interrupts timed | |
| 8 | Later: 3.5" IWM, ROM 01, real serial, 3200-colour palettes, shadow-in-all-banks | | |

## Rung 3a, as built (2026-09-09)

**The bank byte, and where it stops.**  `apple_mmu`'s op path takes an
`op_bank` beside `op_addr` - the query ports were already 24 bits from rung 2,
the presented op was not - and `xlate()` gets the full physical address.  The
one place the bank changes a decision besides the bank classes is `io_page`:
`$C0xx` is the I/O page in a PAIR bank and nowhere else, so bank $02's `$C0xx`
is plain RAM and moves no switch.  `accel_seq` carries `cpu_bank` in, latches
it for a bus op at the decision, and puts it on the unified stream as `u_bank`
and on the fast event as `fev_bank` (the v6 record's bank field, rung 1b).
The IIe callers tie `cpu_bank` to zero, which is exactly what a IIe means when
a 24-bit map is asked - and the parity gate holds it: the IIe sweep is 16384
maps / 33,347,584 checks / 0 and the battery is unchanged.

**Two things rung 2 designed and had not wired**, both found by writing this
rung rather than by review:

- **The IIgs's registers were not in `map_q`.**  `map_changed` and its settle
  watched the IIe's twelve switches, INTC8ROM and the bank register, and not
  SHADOW or SLOTROMSEL - both of which move the map.  They are in it now, and
  the word folds back to the IIe's twenty-one bits at `GS=0` because both are
  constant zero there.
- **The reset sequence has no business on a IIgs.**  `accel_seq` forces the
  seven reset cycles onto the bus so the IIe's own MMU can infer a reset from
  them.  On the GS the card holds the whole map, the motherboard's is not the
  machine's, and `$00/FFFC` is the GS ROM's vector - which is on the card.
  Sending it to the bus would have started the core in the IIe's ROM.
  `accel_seq` takes a `GS` parameter for this one term.

**The bench.**  `sim/boot_gs_tb.sv` is deliberately much smaller than
`boot_tb`: no reference memory, no host model, no disk, because KEGS is a
better oracle than any reference it could keep.  It loads ROM 3 as 512 chunks
into physical bank `$FC` through `rom_loader`, releases reset, and writes one
twenty-byte record per instruction in KEGS's own shape - the registers an
instruction LEFT BEHIND, emitted at the next instruction's fetch, which is
what KEGS logs.  It fails on the things that would mean the machine is wrong
(the ROM not loading, a cache mismatch, a dropped duplicate, a late fill, an
address outside the image) and merely REPORTS a divergence, because at this
rung a divergence is the measurement.

**A wait loop is one event on either side.**  The first honest-looking result
was "100,000 instructions, no divergence" - and 55% of those instructions were
the two at `$FF/FCDC`, a delay loop both machines sit in and cannot agree on
the length of, their cycle models being different.  `trace_diff816.py`
therefore collapses a maximal run repeating with a period of at most sixteen
instructions to one copy before comparing, and reports in EVENTS as well as
instructions.  The event count is the honest measure; the raw count flatters.

**The measurement: 41,877 events.**  Over a 1,000,000-instruction run
(48,212 events) the card and KEGS agree on bank, PC and opcode for the first
41,877 events - card instruction 167,940, reference instruction 110,450 - and
part company here:

    FF/8199  LDX #$2CEC
    FF/819C  DEX
    FF/819D  BEQ $81AB          ; the timeout
    FF/819F  LDA $C027          ; KMSTATUS, the ADB micro
    FF/81A2  AND #$20           ; "the micro has a byte for you"
    FF/81A4  BEQ $819C
    FF/81A6  LDA $C026          ; ...so read it

KEGS reads `$20` and falls through; the card reads the backplane's `$00`,
loops 11,500 times and times out.  So rung 3a ends exactly on the first entry
of rung 3b's list.  `sim/suite.sh gs` pins the floor at 41,877 through
`--floor`, so no later change can quietly take it back; raise it when 3b
moves it.  (With `--regs` the traces differ at instruction 0 for two reasons
that are not bugs: our core does the 65816's three reset stack decrements and
KEGS parks S at `$01FF`, which `TCS` settles five instructions later; and
instruction 1 is `TSB $C029`, whose Z flag is already wrong for want of the
VGC register.)

**And the bench found a bug in rung 2's shadow duplicate, at once.**  One
`late fill` in a million instructions:

    LATE FILL #1: blocked op ppn $e004 off $fb rw 0 posted 1;
                  engine state 1 on ppn $0004

The duplicate was emitted "on the very next idle clock", one clock behind its
own op - and that op had MISSED and started a fill in that very clock.  The
duplicate arrived at the classified stage with the engine busy, was blocked,
and, being a write, ITS BYTE WAS GONE - silently, because the drop happens
downstream of `shd_drop`, which stayed zero throughout.  A posted write waits
for `pw_ready`, the page cache's pipeline clear; the duplicate did not, and
now does.  One term.  The GS sweep is unchanged at 3584 / 67,092,493 / 0 with
its twelve duplicate-landing cases, and the 1M boot run comes back with
`late 0 drops 0`.  This is what the boot bench is for: the case passed every
directed test in the sweep, because the sweep's page cache is never busy.

## Rung 3b, in progress (2026-09-09)

**It reuses the internalized-op path, not a new class.**  The plan called for
a `CLS_IO` and a three-bit class.  It is not needed: the card already has a
path for "a $C0xx op the card answers itself" - docs/CXXX.md's INTERNALIZED
op, which rides `S_FAST` like any fast op, takes its byte from `swi_byte`, and
retires with a SYNTHETIC COMMIT on the unified stream.  `gs_io`'s claim joins
`q_swi` and its byte joins the `swi_byte` mux; the class stays two bits and
nothing widens.  It also means the WRITES to $C02D/$C035/$C036/$C068 keep
landing in `apple_mmu` where they always did, because `accel_seq`'s `u_commit`
is the driver's commit OR the synthetic one - claiming an address changes
where its BYTE comes from and nothing about where its write goes.

**The census is the work list.**  `boot_gs_tb` now counts every $C0xx the ROM
touches, by address and direction, with the instruction number of the first
touch, and prints it.  That is what says which register the machine is waiting
on rather than merely using: at the end of rung 3a the ROM had touched 40
distinct addresses and read `$C027` **11,523 times**, which is the timeout
loop, while `$C033/$C034` - first touched at instruction 191 - were merely
frequent.

**The ADB micro (`rtl/gs_adb.sv`), transcribed from KEGS's adb.c** function by
function, with the function names in the header: the three states (IDLE,
IN_CMD, SENDING), the command table with its argument counts, the answer
queue, the interrupt byte, the 256 bytes of ADB RAM with the ROM self-test's
checksum at $1400/$1401, and the $C027 status composition.  Two ways of
answering are kept apart because the difference is visible to the ROM:
`adb_send_bytes` loads the queue and goes to SENDING, `adb_response_packet`
loads the queue AND an interrupt byte and stays IDLE, which costs a Talk one
extra $C026 read.  Side effects fire on the op's synthetic commit, never on
the read, because `rd_byte` has to be stable across the clocks the dispatcher
takes to serve it.  Result: `$C027` reads fell from 11,523 to 182, the timeout
loop is gone, the ROM reaches bank $00, and the divergence moved 41,877 ->
41,885 - only eight events, but the card and reference INSTRUCTION indices
became identical (110,458 both), which is what says the spin is really gone.

**The map's own registers, read back.**  The next divergence was `BIT $C036` /
`BVC` at $FF/7FF6, testing a bit no one was driving.  `apple_mmu` held CYAREG
and never answered a read of it, and two things about it were wrong: it powered
on at zero where a ROM 3 powers on at **$C0** - bit 7 the speed bit and **bit 6
the POWER-ON STATUS BIT the ROM reads to tell a cold start from a warm one**
(KEGS moremem.c:61, sim65816.c:714) - and a write must clear bit 5
(moremem.c:1713).  The power-on bit also survives RES', KEGS setting it before
`do_reset()`, so CYAREG is now reset by the card's `rst` and not by `res_sync`
- told apart inside the one block that drives it, not split into two writers.
`apple_mmu` exports SHADOW, CYAREG, SLOTROMSEL and a STATEREG composed back
out of its seven switches (KEGS set_statereg's bit order: ALTZP, PAGE2, RAMRD,
RAMWRT, RDROM, LCBANK2, ROMBANK, INTCXROM), and `gs_io` answers $C02D, $C035,
$C036, $C037 (zero on a IIgs) and $C068.  **AND THE SETTLE HAD TO GROW WITH
THEM**: `accel_seq`'s `swi_change` holds the dispatcher for four clocks after
an internalized op that moves a switch, and on the IIgs $C02D, $C035 and $C068
move the map too - $C036 does not, the map never reads it.  Divergence 41,885
-> **66,749 events**, indices identical again (201,635 both).

**The clock chip and battery RAM (`rtl/gs_clock.sv`)**, from KEGS's clock.c.
A serial-ish protocol over two registers: $C033 is a data latch the CPU reads
and writes freely, and $C034 is control - bits 3:0 the BORDER COLOUR, which
has nothing to do with the clock, bit 6 the direction of the next transfer,
and WRITING BIT 7 IS THE STROBE that makes the chip act on what is in $C033.
Bit 7 is not stored, so a read of $C034 never shows it.  Five states, KEGS's
`g_clk_mode`: from IDLE a strobed write carries a command naming the seconds
register, the chip's internal registers, the low battery-RAM addresses, or the
two-byte address form that reaches all 256; the state after does the transfer
and returns to IDLE.  Every byte of battery RAM therefore costs two or three
strobes, which is why the ROM touches $C034 twenty-two thousand times in a
boot.

THE CLOCK IS PINNED, and has to be: `tools/kegs/trace_rom.sh` runs the
reference with `-pintime 3871713600` so its trace is the same every run, and
the card must believe the same seconds or the two disagree about a byte the
ROM checksums.  It does not tick yet for the same reason - a running clock
would make the comparison depend on when the bench started.  Rung 3c gives it
the host's seconds and a virtual-time tick.  The battery RAM is 256 bytes,
zero at configuration, which is what KEGS boots with when its config names no
`bram` lines, so both machines find an invalid checksum and initialise it the
same way.

**The number moved 66,749 -> 67,398, and the census moved more.**  Six hundred
events is a small step, but the shape of the run changed: the distinct $C0xx
addresses the ROM touches fell from 256 to 57, and the ROM began executing in
bank $FC.  It had been in a fallback scan of the whole I/O page; with the
clock answering it is on the normal boot path.  That is the census earning its
place - the divergence index alone would have undersold the step.

**AND THE TRACE HAS REACHED THE SLOT SCAN, WHICH IS WHERE THE REFERENCE
STOPS BEING ONE.**  The loop the run now stops in is at $FF/F9F8-$FA1B: a
pointer walks $C700 down to $C400 and compares `($00),Y` against the signature
table at $FF/FB01 - bytes 1, 3 and 5 against $20, $00, $03.  It is the
STARTUP-DEVICE SLOT SCAN, which is exactly where rung 3's gate said the
comparison ends.

The card reads $C705 = $00 and moves on to $C6; KEGS reads $03 and matches at
$C7.  That is not a bug in the map, and no chipset work will close it.  KEGS
CONSTRUCTS BOTH PAGES (config.c:1163-1190) in a 4 KB "cards" area of its own:

- `g_rom_cards_ptr[0x700 + i] = g_rom_c700[i]` - slot 7 is **KEGS's own
  built-in SmartPort firmware**, a static array in the emulator.  It is not in
  the Apple ROM at all: bank $FF's $C700 is 256 zero bytes.
- `g_rom_cards_ptr[0x600 + i] = g_rom_fc_ff_ptr[0x3c600 + i] ^
  g_rom_c600_rom01_diffs[i]`, plus four more XOR patches for ROM 3 - KEGS
  rebuilds the real Disk II PROM out of the GS ROM and a diffs table so it
  need not redistribute Apple's.

So past the scan the two machines are configured differently BY DESIGN: KEGS
boots its own emulated devices, and this card boots the slot-7 SmartPort HDC
and slot-6 Disk II it already has (docs/HARDDISK.md, docs/FLOPPY.md), whose
ROMs the host sends.  `sim/boot_gs_tb.sv` carries neither yet - it is the
memory path and the chipset, not a machine with cards - which is why $C700
reads zero there.

**THE TRACE HALF OF RUNG 3's GATE IS THEREFORE MET**: 67,398 collapsed events,
202,308 instructions, zero divergence, ending at the startup-device scan.  The
index cannot usefully move further, so the remaining chipset - the VGC
registers, `gs_intc`, the IWM and SCC stubs - is built against KEGS's
behaviour directly rather than against the index, and the next thing the BENCH
needs is the card's own slots in it.

## Rung 3c, as built (2026-09-09)

**The interrupt controller (`rtl/gs_intc.sv`)** is two register pairs that are
not the same machine, and the ROM uses both: the Mega II's `$C041`/`$C046`/
`$C047` for the VBL and quarter-second interrupts, and the VGC's `$C023`/
`$C032` for the one-second and scan-line ones.  Two details are the
reference's and would not have been guessed: `$C046`'s READ IS DESTRUCTIVE -
it copies bit 7 down into bit 6 and clears bit 7, which is how the ROM tells
"an interrupt happened" from "one is happening" - and `$C032` CLEARS BY
WRITING A ZERO to the status bit, the inverted sense.  The timers run from one
pulse per video frame in the machine's own time, so an accelerated program
sees the same number of VBLs per program-second.  The scan-line comparator is
not wired: its enable, status and clear all behave, and nothing sets it.

**The VGC, the SCC stub and the sound GLU face** are latches in `gs_io`, each
named with the KEGS case it came from.  The SCC's reset values are per
channel: RR0 is `$60` with CTS and the transmit buffer empty, plus `$08` for
DCD, and DCD IS ASSERTED ON CHANNEL A AND NOT ON B (`scc.c:128`, `1 - i`) - a
single constant for both would have been wrong.  The sound GLU has the
behaviour: `$C03D` returns the PREVIOUS fetch, not the current one, and both a
read and a write step the 16-bit pointer when `$C03C` bit 5 is set.  There is
no DOC behind it - the oscillators and their 64 KB are rung 7 - so a fetch
reads zero; what the ROM's boot needs is the face.

**AND THE IWM IS NOT OPTIONAL (`rtl/gs_iwm.sv`).**  Running the bench past five
million instructions found the PC had not moved since the first million: the
machine was spinning at `$FF/4720`, writing the IWM's mode register and
reading it back until the low five bits agreed, against a backplane that
answers `$00`.  That loop is unreachable from the trace comparison - it is
long past the slot scan - and only a long run finds it.  **Three things about
this stub had to be read from KEGS rather than reasoned out, and each one cost
a run:**

1. **A seven-bit concatenation into an eight-bit wire.**  `{wr_prot,
   motor_on, mode}` is 7 bits; Verilator zero-extends, so WRITE-PROTECT LANDED
   IN BIT 6 and the ROM's `BMI` tested a bit that was always clear.  KEGS
   composes `((write_prot & 1) << 7) | (state & 0x3f)`, and bit 6 is outside
   that mask - the byte is `{wr_prot, 1'b0, motor_on, mode}`.  `-Wall` caught
   it as WIDTHEXPAND; it would otherwise have looked like a logic bug.
2. **The 3.5" status is a MULTIPLEXER, not a bit.**  The phase lines and
   `$C031` bit 6 select which of sixteen sense lines bit 7 carries, and the
   answers differ - "no disk" is 1, "at track 0" is 0, "not stepping" is 1.
   A single constant is what made the second attempt worse than the first.
   The whole mux is spelled out with the answers a machine with NO 3.5" drive
   gives, which is the decision this programme made; KEGS says a drive 0
   exists because it emulates one, and this says neither does.
3. **The data register must VARY with no disk.**  At `$FF/57B7` the SmartPort
   routine reads `$C08C,X` and waits for a byte with bit 6 clear.  A real IWM
   with no disk still has a head over a spinning surface; KEGS returns
   `((fbit_pos * 25) >> 11) & 0xff` from the head position.  A constant `$FF`
   waits for ever.  A position that advances on every read ends the loop.

**AND ONE OF THOSE RUNS WAS MISREAD.**  Between (1) and (2) the trace appeared
to show the machine executing in banks `$24` and `$A4` - off in unpopulated
RAM - and it had not: the analysis seeked a BYTE offset from the end of a file
the simulator was still writing, so every twenty-byte record decoded shifted
and the banks were fragments of neighbouring fields.  The machine had never
left the ROM.  Read a record-structured file at a record boundary, and take a
size from `os.path.getsize` rather than from `seek(0, 2)` on a live writer.

**THE IWM ONLY HAS TO BE SKIPPED** (the user's, 2026-09-09): the machine boots
from the EMULATED SMARTPORT IN SLOT 7, never from the IWM, so the stub's whole
job is to make the ROM's scan give up and move on.  That settled a question
the first cut got wrong by trying to be faithful.  The ROM waits twice - at
$FF/4717 and $FF/5B71 - for the STATUS BYTE's motor bit to CLEAR, and KEGS
reports the IWM's own motor LATCH there because KEGS has drives for it to
spin.  Reporting the latch spins for ever.  THERE IS NO DRIVE, SO THERE IS NO
MOTOR: bit 5 reads zero, both loops fall through, and the scan moves on.  The
latch is kept - it still gates the data register, as the chip's own does - it
simply is not what the drive's status line reports.  No motor-off timer and no
3.5" motor latch are needed, and building them would have been work in the
wrong place.

**AND $C019 HAD TO COME WITH IT.**  Past the IWM the ROM waits on VBL at
$FF/A5F1, and $C019 is the IIgs's WAY ROUND: bit 7 is set WHILE IN VBL, where
the IIe's is set while NOT (KEGS moremem.c:1044 inverts it for the IIe alone).
`gs_io` answers $C011-$C01F from `apple_mmu`'s status-page byte, with $C019
composed from the beam.

**WHERE IT GETS TO NOW**, and the bench's new SLOT CENSUS says it plainly:

      slot 5  $C5xx    141          first @ 202348
      slot 6  $C0Ex 65734  $C6xx 977620   first @ 202320
      slot 7  $C0Fx 24564  $C7xx     10   first @ 43769

The IWM is skipped and the ROM is in the BOOT SCAN, running the internal
Disk II firmware at $C6xx nearly a million times looking for a 5.25" disk,
finding none, and ending at $FF/A5F1 - the ROM's "no bootable device, wait a
frame and try again" loop.  That is the right end state for a machine with no
boot device, and it is what KEGS does with no disks.

**$C7xx WAS TOUCHED TEN TIMES**, and asking the machine what it had decided
settled why - and corrected a guess.  The bench now dumps the configuration
the ROM settles on, and it says:

    $C02D SLOTROMSEL = $80        slot 7: the SLOT's card
    BRAM $FC-$FF = 36 2d 9c 87

**SLOT 7 IS ALREADY "YOUR CARD" BY THE ROM's OWN DEFAULTS.**  The ten touches
were the scan looking at slot 7's page, finding no signature because the bench
has no card there, and moving on - not the ROM declining to look.  And the
checksum the ROM computed for its own defaults is **$2D36**, which is exactly
the value KEGS had at the rung-3b divergence, with $879C = $2D36 XOR $AAAA
beside it: our clock and battery RAM produce byte-for-byte what the reference
does.

So the battery RAM is not what blocks the slot-7 boot.  What is left is
putting `hd_card` in the bench - rung 3d.

## The battery RAM the host ships (2026-09-09)

The user's decision: **the host ships a battery RAM, and every slot the host
has configured with an emulated card is marked "Your Card"** - the host is the
only thing that knows which those are.  Two things had to be derived from the
machine rather than assumed, and both took being wrong first.

**WHICH BYTES ARE THE SLOTS.**  Found by tracing who writes $C02D - the
routine at $FF/BB9A:

    LDX #$07 / LDA #$00
    ORA $E102E0,X / ASL A / DEX / BNE       ; slots 7..1, one bit each
    AND #$F0                                ; keep only slots 4-7
    LDA $E102E2 / CMP #$01 / ORA #$04       ; slot 2, re-derived
    LDA $E10318 / CMP #$01 / ORA #$02       ; slot 1, from somewhere else
    STA $C02D

The ROM's working copy of the battery RAM is at $E1/$02C0, so $E102E0+X is
BRAM byte $20+X: **BRAM $21-$27 ARE SLOTS 1-7**, and 1 means the slot's card.
The `AND #$F0` throws slots 1-3 away, so slot 1 is taken from **BRAM $58**
instead and slot 2 from **BRAM $22** - both have to be written or the ROM's
two passes disagree.  **SLOT 3 CAN NEVER BE GIVEN TO A SLOT**: the routine has
no term for it, because slot 3 is the IIgs's internal 80-column video.  The
predicted register from the ROM's defaults, $80, matches what it wrote.

**AND THE CHECKSUM, WHICH TOOK THREE TRIES.**  A shipped image whose checksum
is wrong is silently replaced by the ROM's defaults, taking the slot settings
with it.  The routine is at $FF/BA57:

    LDX #$FA / REP #$20 / CLC / LDA #$0000
    loop: ROL A / ADC $02C0,X / DEX / CPX #$FF / BNE loop / TAX / EOR #$AAAA

Two details defeated reading the opcodes, and only walking the bench's own
trace register by register settled them.  The ADC is **sixteen bits wide over
a byte array**, so each pass adds the OVERLAPPING pair {b[x], b[x+1]}.  And
**`CPX #$FF` ends every pass and CLEARS THE CARRY** - X is below $FF
throughout - so the `ROL` rotates in ZERO every time and the only carry
reaching the ADC is the ROL's own.  Modelled that way it reproduces the ROM's
$2D36 and $879C exactly; modelled any other way it does not.  `src/gs_bram.cpp`
in the host is that transcription and `tests/gs_bram_test.cpp` holds it to
those numbers, with a copy of the ROM's slot routine to check the images it
builds.


**The host's half.**  `AppleMemory` gains a `Machine` and a
`classify_gs(bank, addr, rw)` - the four bank classes, the pair-bank side, the
language card in whichever pair, `$C1xx-$CFxx` against SLOTROMSEL, SHADOW's
inhibits and the `$C035` bit 6 window swap - transcribed from the same KEGS
fixups the firmware's oracle came from, and the 16 MB image IS the physical
space on a IIgs, one to one.  `tests/gs_memory_test.cpp` sweeps it against a
SECOND model written as a flat decision tree with no shared helpers, the same
rule as rung 2: twelve banks, 256 pages, read and write, over every SHADOW
state and the language card's.  `machine = iie | iigs` and `gs_rom` join the
config.  Host tests 38/38 on the Pi (the map sweep and the battery RAM's).

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
