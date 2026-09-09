# Apple IIgs on the card: the run sheet

Status: **RUNG 7, THE ENSONIQ, 2026-09-09**: the DOC 5503 is built -
32 oscillators, 64 KB of wave RAM, the modes, and the arrival-ordered
interrupt queue - and "Unclaimed Sound Interrupt" is gone.  WNS +0.022 / WHS
+0.057, 0 of 62,799 failing endpoints; `sim/suite.sh gs` **10/10** (KEGS floor
67,398, unmoved), host 43/43.  **GS/OS still does not reach the Finder**: it
now dies further on, in the ROM's monitor, in banks that do not exist, with
the DOC quiescent - see "What is NOT working".  Before it, RUNG 4b PARTS
7-9**: the Apple's own keyboard types
into the IIgs, A VECTOR PULL COMES FROM THE ROM (which is what was killing
GS/OS), and the ADB mouse is fed.  WNS **+0.140** / WHS +0.057, 0 of 52,524
failing endpoints, `sim/suite.sh gs` **9/9** (KEGS floor 67,398, unmoved),
host 40/40.  GS/OS 6.0.1 now boots past its splash and runs the ROM's
interrupt handlers; it stops at **"Unclaimed Sound Interrupt"**, the Ensoniq
being rung 7 and not built.  The keyboard, in detail: **THE APPLE'S OWN
KEYBOARD TYPES INTO THE IIgs, 2026-09-09**, branch `gs_emulation`, WNS **+0.082** / WHS +0.020, 0 of 52,476
failing endpoints, `sim/suite.sh gs` **9/9** (KEGS divergence floor 67,398,
unmoved).  The IIe keyboard the card lives behind reaches the ADB micro now:
`rtl/gs_kbd_a2.sv` walks the driver's parked dummies over `$C000`, `$C010`
and the two Apple keys, and runs the IOU's ASCII BACKWARDS through the
micro's keymap into the keycode that made it (`tools/gen_adb_revmap.py`, an
inversion that is total and round-trip exact for all 128 values).  PROVEN ON
HARDWARE - both keyboards, the Apple's and the Pi's, into one buffer.
**And GS/OS 6.0.1 draws its splash from the slot-7 SmartPort and then the
core halts**; see "What is NOT working" for the evidence and the lead.
Rung 4a before it built the bitstream itself (`parameter bit GS`,
`build/build.sh --gs`); rung 4b brought first light and the fixes it bought.

Rung 3 before it: **CLOSED, 2026-09-09** - rungs 0, 1, 1b, 2 and 3a-3e all
done (1b proven on hardware; the rest in simulation, which is what those rungs
are).  **THE MACHINE BOOTS AN OPERATING SYSTEM.**  The soft 65816 runs ROM 3
on the card's memory path with the whole chipset answering on the card, finds
the emulated SmartPort in slot 7, reads its boot block, loads ProDOS 2.4.3,
relocates it into the language card and runs it - and an ADB Return pressed
into the micro at ProDOS's BYE selector launches a file:

    S7,D1:/PRODOS.2.4.3
    - BASIC.SYSTEM      !     BITSY  BYE
    RETURN:SELECT   ESC:BACK   TAB,#:NEW VOL

(The key is the bench's, through the same ADB_KEY message the host sends.  The
Pi's own keyboard feeds that message on the host side and is unit-tested
there, but the two have never met: there is no hardware yet.)

Four oracles hold it, and each has found bugs the others could not.  The map
is swept against a model taken from KEGS (3584 maps, 67,092,493 checks, 0
mismatches).  The 65816 is held to SingleStepTests cycle by cycle (981,610
tests, 0 failures).  The trace agrees with KEGS for **67,398 collapsed
instruction events - 202,308 instructions, zero divergence - to the
STARTUP-DEVICE SLOT SCAN**, which is as far as a reference can be one: past it
KEGS boots its own emulated cards and this machine boots the ones it has.  And
the host's memory mirror is replayed against a REAL BOOT of the bench -
1,817,727 ops, 481 written pages, **zero bytes different** - which is the only
one of the four that is not a model arguing with a model.

**NEXT IS RUNG 4: FIRST LIGHT ON HARDWARE.**  `build.sh --gs`, a bitstream,
the text screen on HDMI from $E0, the Control Panel through the Pi's keyboard
and the real IIe one.  **Nothing of the GS has run on hardware yet** and there
is no GS bitstream: everything above is simulation.  The IIe design is
untouched and stays bit-identical at `GS=0`, which the 35-bench battery checks
on every rung.  Branch `gs_emulation` in both repos, taken from master at fw
`62b21ab` / host `98d46d2` (the `memory_refactor` merge).

**KNOWN AND NOT FIXED**, found by the mirror replay: the page cache can hold a
previous tenant's bytes in lines a page never had written - page $0001 took
17,865 writes with the lowest offset ever written $70, and the cache holds
junk below that where DDR3 correctly holds zeros.  Nothing wrote them and
nothing reads them, but cache and backing store disagree there, so an eviction
and refill would change bytes under the machine.  See "the mirror against the
machine" below.

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
| Keyboard: $C000 ASCII + strobe, $C010 clear + any-key-down, $C025 modifiers, 8-deep buffer, auto-repeat from set-config | CARD | 1 | BUILT. Two sources into one buffer: the Pi's evdev keyboard via the ADB_KEY message (keycode, modifier byte, up/down), and the real IIe keyboard from the dummy-cycle $C000 latch, its ASCII run backwards into a keycode by `gs_kbd_a2.sv` + `adb_revmap.hex`. Real game-port buttons as Command/Option, merged into $C025 at the read. See rung 4b part 7. |
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
| $C000/$C010 | served by the ADB model; the dummy cycles keep sampling the real keyboard as an input, and the $C010 in the walk is what CLEARS THE IOU's STROBE - the machine's own $C010 never reaches it (`gs_kbd_a2.sv`) |
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
| 3b | `gs_io.sv`: the IIgs chipset's register faces - ADB micro, the map's own registers, `gs_clock` + battery RAM, VGC, `gs_intc`, the IWM and SCC stubs, the sound GLU face - answered on the card instead of by the backplane | the divergence index moves; `boot_gs_tb`'s floor raised | **DONE 2026-09-09**: the ADB micro, the map's registers and the clock took the index 41,877 -> 66,749 -> 67,398 events, which is the startup-device slot scan and as far as the reference can be one (see below); rung 3c built the rest of the chipset against KEGS's behaviour directly |
| 3c | The rest of the chipset (VGC registers, `gs_intc`, IWM and SCC stubs, the sound GLU face) and the host side: the GS map in the mirror, `machine = iigs`, `gs_rom` | the ROM runs past the chipset with no spin; the host's map agrees with the card's | **DONE 2026-09-09** - see below |
| 3d | `hd_card` in `boot_gs_tb` with the bench playing host, so the scan has something to find | the ROM finds slot 7, runs its firmware and reads blocks | **DONE 2026-09-09** - and the boot block runs; see below |
| 3e | Why the third block read asks for $0203 instead of $0003; then ADB_KEY, `mock_card` speaking a GS stream, the battery RAM shipped down to `gs_clock`, and the mirror replayed against the bench image | the image boots | **DONE 2026-09-09.** The $0203 was an internal cycle (VDA and VPA both low) taken as an access - as a WRITE and as a STROBE - and the eviction pressure that uncovered turned up a real page-cache bug (the shadow duplicate had no P0). ProDOS 2.4.3 boots off the slot-7 SmartPort to its BYE selector and a Return launches a file. The battery RAM ships (GS_BRAM `$2E`) and the ROM believes it; ADB_KEY carries keycodes to a micro that holds the keymap, with auto-repeat; `mock_card` speaks a GS stream (`gs_source.hpp`); and the mirror replays a real boot - 1,817,727 ops, 481 pages, ZERO bytes different - which found three host bugs of its own |
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

## Rung 3d: the slot-7 SmartPort, found and read (2026-09-09)

`sim/boot_gs_tb.sv` now carries `hd_card` in slot 7 with the bench playing
host, transliterated from `boot_tb`.  It is SIMPLER here than there: the GS
build has no on-card slot fast path - `apple_mmu`'s `swi_on` is low, so
`q_slot` never fires - which means the peripherals see the DRIVER's op stream,
and a `$C0Fx` or `$C7xx` access is BUS class riding a real cycle.  That is
what "Your Card" means on this machine, and it needs no `sl_win` window.

Block WRITES are deliberately not modelled: `boot_tb` captures the block from
its reference memory and this bench keeps none, so a write command FAILS the
run rather than writing zeros over the image and calling it a pass.

**IT FINDS THE CARD AND READS FROM IT:**

    ok: the slot-7 SmartPort ROM loaded
    disk: READ block 0 -> $0800 at instruction 625785
    disk: READ block 2 -> $0c00 at instruction 625893
    the disk: 2 blocks read, 0 written, 1 statuses, 4 execs
    slot 7  $C0Fx 2985  $C7xx 532

The scan reaches slot 7, executes the card's firmware out of `$C7xx`, reads
the boot block into `$0800` and jumps into it, and the boot block reads the
volume directory into `$0C00`.  All of that is new.

**AND THEN THE BOOT BLOCK GIVES UP**, at `$00/094D`:

    0944  LDA $0950,Y / STA $05AE,Y / DEY / BPL $0944
    094D  JMP $094D
    0950  "UNABLE TO LOAD PRODOS" (high ASCII)

It copies its own error message to the text page and halts.  **`PRODOS` is in
directory block 3, not block 2** - block 2 holds the volume header,
`VIEW.README`, `BITSY.BOOT` and eleven more, with a next-block pointer to 3 -
so the walk had to follow that pointer, and the instruments say exactly what
happened when it tried:

    disk: EXEC cmd $01 unit $70   READ block 0 -> $0800
    disk: EXEC cmd $01 unit $70   READ block 2 -> $0c00
    disk: EXEC cmd $01 unit $70   REFUSED block 515 -> $0e00 (past the end of the image)

**THE THIRD READ ASKS FOR BLOCK 515, WHICH IS $0203.**  The low byte is right
and the high byte is $02 where it should be $00.  The host model refuses a
block past the end of the image - correctly - and the boot block takes its
error path.  Two things are already ruled out: the blocks that DID arrive are
byte-for-byte correct in the card's memory (`check_landed`, which reads the
page cache and the DDR3 stub the way `boot_tb` does), so neither the DMA nor
shadowing is corrupting them; and the same image with the same `hd_card` boots
on the IIe bench, so the disk path itself is sound.

What remains is how the block number reaches the card's registers on this
machine - the host model assembles it from the `$C0Fx` writes it sees on the
op stream, and a stale or missed high byte would look exactly like this.  That
is rung 3e's first question.  The bench now names every EXEC, every READ and
every REFUSAL with its reason, which is what turned "the boot fails" into a
one-line fact.

## Rung 3e: an internal cycle is not an access (2026-09-09)

The high byte was not stale and was not missed.  **The machine really did
write `$02` into `$47`**, and the instrument that says so is one more line of
the bench: every `$C0Fx` write the driver makes, and every write to the ProDOS
block-driver parameters at `$40-$47`, each with the PC that did it
(`--disktrace`).

    zp:  $0046 <= $02 from 00/0871   ($46 = block 2, $47 = 0)
    disk: READ block 2 -> $0c00
    zp:  $0047 <= $02 from 00/0882      <-- ONE INSTRUCTION, TWO WRITES
    zp:  $0046 <= $03 from 00/0882
    reg: $c0f9 <= $03   reg: $c0f9 <= $02
    disk: REFUSED block 515 -> $0e00

`$00/0882` is `E6 46`, **`INC $46`** - the boot block stepping to the next
directory block.  One instruction, two writes: the new value at `$46`, and the
OLD value at `$47`.  The driver then read the pair back honestly and asked for
`$0203`.

**WHY.**  The 65816 drives R/W LOW through the internal cycle of a
read-modify-write - the 6502's dummy write - and SingleStepTests agrees, so
this is not a core bug in the ordinary sense:

    [60394, 250, 'd--remxl']   read dp
    [60394, 250, '---wemxl']   internal: WRITE, and VDA is LOW
    [60394, 251, 'd--wemxl']   write dp

**VDA IS LOW on that cycle**, so on a real machine no decoder sees it and
nothing is written; its address is not architectural.  This core leaves the
operand's address PLUS ONE there on the M-sized RMWs, because their read slot
is shared with the 16-bit path, which has already stepped forward, and the
8-bit tail steps back a cycle later (`acc_rmw` in `sim/gen_microcode816.py`;
the address mux has no AGU source, deliberately, so the step cannot be moved).
That is legal, and the dispatcher was never given VDA - so it took the bare
R/W and committed the write.  Every `ASL/LSR/ROL/ROR/INC/DEC/TSB/TRB` on
memory in emulation mode was quietly clobbering the byte above its operand.
Not only RAM: the first one the ROM does is at `00/FA64` and would have
written `$01` into **`$C02A`**.

**THE FIX** is one wire, at the place a 65816 system has always put it:

    wire cpu_rw_eff = cpu_rw | ~cpu_vda;

and everything downstream of the core - the dispatcher, `apple_bus_write`, the
map's classify query, `gs_io`'s - takes THAT, never the raw pin.
`rtl/cpu65816.sv`'s header now states the contract so rung 4's `master_top`
wires it the same way.  The bench counts what the gate stops (250 in a
900,000-instruction run) and prints the first few.

**WHY 981,610 CPU TESTS DID NOT SEE IT.**  Because the harness modelled a
machine that does not exist: it applied `if (!rw) mem[addr] = dout` on every
cycle, internal ones included, and then compared only the addresses the suite
itself lists - and the suite lists only what the reference touched, so a write
to dp+1 landed in no list and was never looked at.  `cpu816_trace_main.cpp`
now uses **VDA as its write enable**, the way a real system does; compares
VDA/VPA/VPB **by default** (they were an option, and they pass - the write
enable is only worth what the flags are worth); and fails a test that writes
any address the reference does not write.

**THE SECOND HALF: A READ IS A STROBE TOO.**  The write was only one
direction.  An internal cycle was still being presented as a READ at that
same stale address, and `$C0xx` reads are strobes.  Two instructions after
ProDOS's `LDA $C082` (read the ROM), an internal cycle carrying **`$C083`**
switched the language card back to RAM, and `JSR $FE84` read `$00` from empty
LC RAM and BRKed.  The same mechanism was strobing `$C08C` after `$C08B` and
`$C02A` after `$C029`.

So the rule is stated once, at the top of the machine, and `accel_seq` is told:
`cyc_int` (VDA and VPA BOTH low - an operand fetch has VDA low too, so VDA
alone is not the test) takes a new `S_NULL` arm in `S_DECIDE`, AFTER the
governor is paid and BEFORE `needs_bus`.  The cycle costs its credit and
retires with **no op on the stream, no bus cycle, and no access of any kind**.
The address going to `apple_bus_write` is parked at `$0000` besides, in the
same idiom and for the same reason as that module's dummy, so mode 0 on real
hardware puts nothing dangerous on the backplane either.

## Rung 3e, part 2: the shadow duplicate had no P0 (2026-09-09)

Suppressing those cycles changed which pages the cache evicts, and that turned
up something much worse underneath.  **32 of the ROM's 1024 pages came back
from DDR3 as zeros**, and the machine fetched `$00` from one of them at
`$FF/F882`.

Four instruments, each one narrowing it:

1. **The ROM oracle.**  Banks `$FC-$FF` ARE the ROM, so every byte the core
   reads from one must be the byte in the file.  `ff/f882 gave $00 where the
   image has $f4`, at instruction 178,776.
2. **The page sweep.**  32 pages wrong, all NOT RESIDENT - so it is what DDR3
   gave back, not a corrupt line in the cache.
3. **The write-back census**, per physical page.  Every bad page had been
   given exactly **32** line writes: flushed TWICE, and still wrong.
4. **The flush oracle**, in the DDR3 stub: a write-back of a ROM page that is
   not the image is a bad flush, caught at the clock it is issued.  It wrote
   **all zeros**.

Then the engine's own history for one page said it outright:

    eng 401422:  fill ppn $fc7c, victim $0000 clean, set 4 way 01   <- the load
    eng 5880386: fill ppn $0004, victim $fc7c DIRTY, set 4 way 01
    eng 5880469: fill ppn $e004, victim $fc7c DIRTY, set 4 way 01   <- AGAIN
    BAD FLUSH at 5880533: ROM page $fc7c wrote $00

The same page is the victim twice, in the same way, 83 clocks apart - and the
directory was innocent: watching `dir[way0][set4]` shows it cleared at
5880386, retagged to `$0004` at 5880448, cleared again at 5880469.  It said
`$0004`.  The ENGINE said `$fc7c`.

**THE CAUSE.**  `apple_mmu` sets `cl_valid` for a shadow duplicate exactly as
it does for a posted write - but `page_cache`'s entrant term is
`e_any = op_present || pw_take || il_ack`, **and there is no term for the
duplicate**.  So no P0 ever ran for it: the directory was never read for ITS
page, and the hit compare, the victim, the victim's tag and dirty bit, and the
row its byte lands in all belonged to whatever op went before.  The cache has
counted this since it was written - `cnt_ppn_clash`, "a `cl_*` whose page is
not the one P1 read the directory for" - and nothing had ever looked at it:

    ppn_clash 56   shadow duplicates taken 56

Exactly equal.  Every duplicate was a clash.  It is GS-only, which is why the
IIe battery never saw it: the IIe emits no duplicates and that counter has sat
at zero since the day it was added.

**THE FIX.**  `apple_mmu` exports the duplicate's entrant (`shd_take_o`,
`shd_ppn_o`, `shd_off_o`) and `page_cache` takes it as a fourth term in
`e_any` with its own `en_ppn`/`en_ln`, and in `e1_op`; `il_ack` excludes it as
it already excludes `pw_take`, so two entrants never share a P0.  After it:
`ppn_clash 0`, the ROM intact all 256 KB, every write-back carrying the
image's bytes, and every byte read from `$FC-$FF` the image's.

**WHY THE PRESSURE WAS THERE AT ALL**, and worth fixing separately: ROM 3 is
256 KB, the page cache is 128 sets x 8 ways x 256 B = 256 KB, and the ROM's
page numbers hash to **exactly 8 pages in every one of the 128 sets**.  It
fills the cache perfectly before a single byte of RAM.  Worse, the loader
writes it through the posted-write seam, so all 1024 pages are DIRTY for ever
and only ~32 KB of it is ever in DDR3: every RAM page the machine touches
evicts a dirty ROM page and pays a 16-beat write-back of bytes that cannot
have changed.  The map DOES write-protect the ROM against the machine
(`gs_rom` banks classify `wr = 0`, so `cl_wr_image` is low and an ordinary
write lands nowhere); it is only the loader's posted writes that get in, by
design.  Making those pages CLEAN - the ROM in the backing store, the cache
holding it read-only - would remove 1024 permanently-dirty pages and all of
that write-back traffic.  Not done.

## Rung 3e, part 3: the IWM had to be skipped, not modelled (2026-09-09)

With both halves of the internal cycle fixed, the machine stalled at
**`$FF/57BC`** - 93,630 reads of `$C0EC` and no exit:

    57B7  LDA $C08C,X      ; X = $60, so $C0EC
    57BA  AND #$40
    57BC  BNE $57B7        ; spin while bit 6 is SET

**That was not a regression, it was the machine being honest.**  The loop used
to end because the internal cycle after each `LDA $C0EC` read `$C0ED`, and
`$C0ED` FLIPS Q6, so the next read returned `status_byte`, whose bit 6 is
clear by construction.  The same artefact was setting the phase lines and the
motor: the census shows them going as it goes - `$C0EC` 69 -> 93,630 reads,
`$C0ED` 69 -> 4, `$C0E9` 23 -> 4, `$C0E7` 38 -> 3.

The state at the stall is `q7 = 1, q6 = 0, enable2 = 0` (`phases 0011`), which
is the HANDSHAKE arm without ENABLE2 - and that arm returned a **constant
`$C0`**.  The reference says why that is wrong: KEGS's `read_iwm` case `0x02`
starts from `0xc0` and CLEARS BIT 6 (`status & 0xbf`) as soon as the head has
moved more than eight bits past the last bit written - **bit 6 is the WRITE
UNDERRUN**, and on a machine with nothing writing it is always clear.  A
constant `$C0` says "a write is in progress and keeping up", for ever.

The reference trace settles it outright: **KEGS visits `$FF/57B7` ONCE in five
million instructions and reads `$80` there**, falling straight through to a
bounded `DEY`/`BEQ` retry.  So `gs_iwm`'s handshake without ENABLE2 is `$80`,
by the same argument as the motor above - there is no drive, so there is
nothing to underrun (docs/GS.md's decision: the IWM's only job is to be
SKIPPED; it is never modelled as a drive, and the machine boots from the
emulated SmartPort in slot 7).

## Rung 3e: THE IMAGE BOOTS (2026-09-09)

    ---- the text screen (main page 1) ----
      |S7,D1:/PRODOS.2.4.3                     |
      |----------------------------------------|
      |A VIEW.README       !                   |
      |- BITSY.BOOT        !                   |
      |- QUIT.SYSTEM       !                   |
      |- BASIC.SYSTEM      !     BITSY  BYE    |
      ...
      |RETURN:SELECT   ESC:BACK   TAB,#:NEW VOL|

The IIgs ROM scans, finds the slot-7 SmartPort, reads its boot block, loads
PRODOS, relocates it into the language card and runs it, and ProDOS's BYE
selector is on the text screen naming the volume on **S7,D1** - the emulated
card.  55 blocks read, 54 checked intact where the machine looks for them, the
ROM still the image in all 256 KB, and no op reaching the cache without its
own directory read.  `sim/boot_gs_tb.sv` reads the text page out of the card's
memory the way the host's `screen` does, so the machine says this itself.

## Rung 3e: the keys arrive (2026-09-09)

**ADB_KEY (`0x2F`)**, host→card, one word an event:
`{mods[7:0], is_up, keycode[6:0]}`.  **THE CARD HOLDS THE KEYMAP**, as a real
ADB micro does - a real one turns a keycode and the modifier state into the
byte `$C000` reads, and the ROM never sees the keycode for that - so what
travels is a keycode and not a character.

`tools/gen_adb_keymap.py` generates `rtl/adb_keymap.hex` from KEGS's own
`g_a2_key_to_ascii[][4]`, 128 entries of `{ctrl, shift, plain}` each
`{none, special, byte}`.  Generated rather than transcribed, and it earned
that twice over: **three rows carry `'{'`, `'}'` and `','` as character
literals**, which breaks any naive split of the table, and KEGS's `& 0xef00`
special-key mask **leaves bit 12 out on purpose** (the `$10xx` entries - Home,
Page Up, the keypad's edges - are ordinary ASCII to it) while `hard_key` is
decided from **the plain column alone** and then whichever column the
modifiers choose is read.  Both are written down beside the flag.

`gs_adb` gains what the micro has always had beside its command port: the
ASCII buffer `$C000` reads head-first with bit 7 the strobe, the raw event
queue a Talk register 0 drains two bytes at a time (a RESET travels alone),
`$C010` as an ACCESS - a write to it clears the strobe too - and `$C025`,
which is the host's modifier byte with the micro's own "a key is available"
and "no hard key is down" bits.  `gs_io` claims `$C000` and `$C010` now.  An
event WAITS for a clock with no `act`: the apply and the command machine both
touch the raw queue, and this module keeps one writer for its state.

NOT YET: KEGS's auto-repeat and its "read five times with keys pending, toss
one" nudge, both of which want the frame count; the decision table asks for
auto-repeat from set-config and it is a rung of its own.

**THE PI'S KEYBOARD FEEDS IT** (host `src/pi_adbmap.hpp`, `ac2aa39`).  Not
`PiKeymap`: that one produces the IIe's ASCII, and this side must send a
keycode.  The Apple keys are MODIFIERS there and not game-port buttons - on a
IIgs they are Option and Command, which the micro reports and the Control
Panel reads - while Caps Lock still toggles on the host, the device being
grabbed, and Control-Pause is still the reset a PC keyboard has no key for.
`adbmap_test` holds that table to 184 checks; the other half of the journey,
keycode to character, is the card's keymap and is gated here.

**IT WORKS, END TO END.**  Booted to ProDOS's BYE selector, pressed Return
(ADB keycode `$24`) and let it up:

    ok: keycode $24 reached the keyboard: $C000 reads $8d, $C025 $00
      |ProDOS 2.4.3 is a minor update.         |
      |Changes from ProDOS 2.4.2:              |
      |- Thunderclock driver updated for       |

`$8D` is `$0D` with the strobe.  The machine took it, launched `VIEW.README`
and put the release notes on the screen.  `--key=CODE:AT[:MODS]` presses one
at an instruction number.

The landing check had to get MORE honest to say that.  While the boot is a
read-then-jump a block is still the host's when the next command goes out;
once an operating system is running it reads a block into a buffer, WORKS ON
IT, and only then asks for the next thing.  So a block the machine has written
to is skipped and counted rather than failed - and the DMA's own writes, which
carry `u_ovr`, are not the machine's.  95 blocks read, 91 intact, 3 touched.

## Rung 3e: the mirror against the machine, and rung 3 closed (2026-09-09)

The last two items, and the strongest oracle in the programme.

**`mock_card` SPEAKS A GS STREAM** (host `src/gs_source.hpp`).  Every other
source there is a IIe - bank 0, sixteen bits of address - so the host's GS
paths never saw a record at all.  This one puts the four bank classes, the
Mega II pair and the registers that move the map on the wire, and
`gs_stream_test` drives `MockCard` from it, reads the words back through the
REAL link parser, and applies them to the mirror as a IIgs: 15 checks that the
bank byte survives framing and that the mirror writes the banks it is told to.

**THE MIRROR REPLAYED AGAINST THE MACHINE** (`tools/gs_mirror_test.sh`).
`boot_gs_tb --mirror=DIR` writes every op the core retires - plus the host's
own DMA, which never goes near the core and which a replay has to be told -
in the host's own 64-bit record shape, and the physical pages the machine
wrote with a BIT-MASK of which bytes it wrote.  The host's `AppleMemory`
replays the one and is held to the other, on the Pi.

    1,817,727 ops replayed, 481 written pages compared, 0 pages and 0 bytes differ

**ONLY THE MASKED BYTES ARE COMPARED, and that is not a weakening.**  A byte
the stream never wrote has no agreed value: the mirror starts at zero and the
card's cache starts at whatever its way was left holding.  Comparing those
compares two arbitrary choices rather than two maps.  The bench's own page
$0001 shows why - 17,865 writes landed on it and the LOWEST OFFSET EVER
WRITTEN WAS $70, yet the cache holds a previous tenant's bytes below that,
where DDR3 correctly holds zeros.  Nothing reads them and nothing wrote them,
but the cache and the backing store disagree there, so an eviction and refill
would change them under the machine.  Worth a rung of its own; it is not a
map disagreement and the oracle should not pretend it is.

**IT FOUND THREE HOST BUGS**, none of which any sweep could have:

1. **`apply()` threw the bank away.**  It called the IIe's two-argument
   `classify(addr, rw)`, so on a IIgs every bank's writes went to bank 0:
   banks $02-$7F and $E0/$E1 empty, bank 0 full of other banks' bytes.
2. **The shadow duplicate was computed and never performed.**  `classify_gs`
   set `l.sh` and `apply()` only ever wrote once, so the Mega II banks never
   received anything.
3. **The IIgs registers were never tracked from a stream.**  `sw_.shadow`,
   `sltrom` and STATEREG were only ever written by the map sweep's
   `set_switches_for_test` - so a GS stream left SHADOW at zero, no route
   inhibited, and text page 2's writes shadowed over a fill the machine had
   put in $E0.

That is what the sweeps cannot do.  `gs_memory_test` argues this mirror
against a second model and `mmu_xlate_gs_tb` argues the card's against a
KEGS-derived oracle; both are models arguing with models.  This one takes a
boot that actually happened.

## Rung 3e: the battery RAM ships (2026-09-09)

The host built a correct image at 6ba6eb2 and had no way to hand it over.
Now it does: **GS_BRAM (`0x2E`)**, host→card, the whole 256 bytes as 64 words,
taken ALL OR NOTHING by `rtl/gs_clock.sv` - a partial image is worse than
none, because the ROM checksums it, finds it wrong, and writes its own
defaults over the slot settings it was shipping.

The battery RAM became FOUR BYTE-WIDE BANKS chosen by the index's low two
bits.  A message word carries four bytes, one a clock, and the link will not
wait; a byte-wide array cannot take four writes in a clock and four banks can,
one each.  The machine still sees one 256-byte battery RAM - its index picks
the bank with its low two bits and the entry with the rest.

The host sends one at start when `machine = iigs`, naming every slot it has
put a card in - the floppy, the VidHD, the mouse, the Uthernet II, the
printer, the hard disk and the Mockingboard - because the host is the only
thing that knows which those are.  `machine` had never been plumbed past the
config file; it is now.

**IT WORKS, and the ROM says so.**  Shipping an image that names slots 6 and 7:

    ok: the host's battery RAM landed whole in the card's clock chip
      $C02D SLOTROMSEL = $c0  (a SET bit gives that page to the slot)
        slot 6: the SLOT's card
        slot 7: the SLOT's card
    ok: the ROM kept the host's battery RAM: it checksummed and believed it

`$C02D` came out `$C0` where the ROM's own defaults give `$80` - slot 7 alone.
The second check is the one that matters: an image the ROM does not believe is
silently replaced, so "it did not rewrite it" is the whole proof.

**OFF BY DEFAULT, and it has to be.**  KEGS boots with an all-zero battery RAM
when its config names no `bram` lines, so the ROM finds an invalid checksum on
both machines and initialises it the same way.  Ship one and the two part
company at once - correctly, and not at the floor.  `--bram=6,7` opts in;
`sim/suite.sh gs` does not, and the floor is unmoved at 67,398.

`tools/gs_bram.py` builds the bench's image and is DELIBERATELY a second
implementation of the host's `src/gs_bram.cpp`, written from this sheet rather
than from that code.  Both agree with the machine: `--slots 7` reproduces the
ROM's own image byte for byte, checksum `$2D36` / `$879C` included.

The landing check had to learn the language card to say it: ProDOS DMAs blocks
to `$DC00`, and `$D000-$DFFF` folds onto physical `$Cx` in bank 1 with `altzp`
choosing the aux bank, so the LC state is captured as each block lands and the
check uses it.

The end-of-run landing check went with it.  Rung 3d could snapshot `$0800` at
the end because the boot stalled there; a boot that gets going relocates over
it, so each block is now checked at the moment the machine asks the card for
the next thing - still the machine's newest, and 38 of the 39 get checked.

## Rung 4a: the machine reaches the top level (2026-09-09)

Everything above rung 4 was a bench.  `master_top` - the file that is actually
built into a bitstream - had never had a 65816 in it, never instantiated
`gs_io`, and never asked `apple_mmu` or `accel_seq` for anything but a IIe.
Rung 4a puts the machine in the top level.

**ONE TOP LEVEL, ONE PARAMETER.**  `master_top` takes `parameter bit GS`, and
every GS term folds to a constant at `GS = 0`.  The 65C02 and the 65816 are
the two arms of a generate; so are the two fronts and their absence.  The
choice is made in one place and nothing downstream knows which machine it is
serving.

**WHAT THE REST OF THE BOARD SEES IS NOT THE CORE'S PINS.**  `cpu_addr`,
`cpu_bank` and `cpu_rw` are now the EFFECTIVE op, and at `GS = 1` the
65816's internal cycle - VDA and VPA both low - is parked at `$000000` as a
read before anything downstream decodes it.  This is the wiring rung 3e's
bench found the hard way, and the bench's own comment asks for it by name:
handed on raw, that cycle is a write in the middle of a read-modify-write and
a strobe in the middle of a `$C0xx` read, and it cost that bench both halves
of a boot.

**THE FRONTS ARE NOT BUILT AT `GS = 1`.**  `iline` and `dline` are the IIe's;
rung 6 widens them for the 24-bit space.  At `GS = 1` the core takes the
dispatcher's cycle enable and the dispatcher's byte directly, and the thirty-
odd seams the two fronts drive are tied still in the generate's other arm -
which is also what makes room on the die for the 65816 and the chipset.

**THE IIe's `$Cxxx` APPARATUS STANDS DOWN.**  `sw_int` is `!GS && ...`, so
`apple_mmu`'s own internalization and the on-card slot fast path are off and
the peripherals see the driver's op stream, as they did before docs/CXXX.md's
closed regime - which is what "Your Card" means on this machine, and what the
bench proved.  `gs_io`'s claim joins `q_swi` and its byte the serve mux, in
the shape sim/boot_gs_tb.sv uses.  The keyboard latch, the button injector and
the floating-bus simulator stand down at the substitution mux: each answers
for `$C0xx` addresses a IIgs decodes differently, and a substitution on top of
an internalized op is a second authority for the same byte.  The No-Slot Clock
too - a IIgs has a clock of its own and no reason to look for one hiding
behind a slot ROM.

**THE BEAM FREE-RUNS.**  `vbl_lock` finds the IIe's beam by writing a picture
into the motherboard's text page and reading the floating bus back.  A IIgs's
video is the card's and the host's and there is nothing on the backplane to
lock to, so at `GS = 1` the lock takes no override cycle, `virt` is forced on,
and `vbeam` is told it is locked and notifying from reset.

**THE CLOCK IS THE HOST'S FEED.**  `gs_clock`'s `cur_time` was loaded from a
parameter at card reset, which on hardware is before the host has connected.
It now also takes a **GS_TIME** message - one word, seconds since 1904-01-01,
type `$30` - and the host re-sends it every second, exactly as it feeds the
No-Slot Clock, because the card has no oscillator of its own to count.
Nothing ticks in RTL, deliberately: a clock that advanced here would make the
bench's comparison against a recorded trace depend on when the run started,
and the bench sends no GS_TIME at all - which is why the floor is unmoved.
The conversion is LOCAL time to the Macintosh epoch (`gs_now_1904`), because
the Control Panel shows what the chip counts; `gs_bram_test` holds it to the
same 3,871,713,600 that `tools/kegs/trace_rom.sh` pins KEGS's clock to.  A
32-bit count from 1904 runs out on 2040-02-06, which is the real part's limit.

**`build.sh --gs`** is `--master` with the parameter set: its own Vivado work
directory (sharing one with `--master` would let a IIe project's state stand
in for a IIgs build's), its own source-list additions, and its own bitstream
name - `build/results/master_top_gs.bit`, so a IIe bit and a IIgs bit can sit
side by side and neither can be mistaken for the other.  `run_build.sh --gs`
adds the 65816's microcode and the ADB keymap to the pre-flight and tags the
log `gs_`.

**AND THE TOP LEVEL IS LINTED NOW, at both machines.**  master_top was on
sim/lint.sh's "not linted, deliberately" list because it instantiates Xilinx
primitives, an XPM macro and UberDDR3's top, and Verilator can resolve none of
them - which left a mistyped connection or an undriven wire in the top level
to be found by Vivado, after a fifteen-minute elaboration.  `sim/stubs/prims.v`
gives the linter the port names and nothing else, and `sim/lint.sh` now
elaborates the whole design twice, once per value of `GS`, in about a second.
The arm that is not being built is the one that rots, so both are checked on
every lint.  The stubs are never in a synthesis source list; if one disagrees
with the real primitive, Vivado still says so.

**A IIgs CANNOT BE TYPED AT THE WAY A IIe CAN**, and the rung's own gate is
what found it.  The control socket's `type` - which every `*_test.sh` and the
MCP tools use - goes to `key_typist.hpp`, which handshakes with the card's
keyboard latch key by key: a KBD_PRESS, an ack, a KBD_EVENT saying the machine
resolved it.  A IIgs has no such latch.  Keys reach an ADB micro as raw
KEYCODE events, its queue is eight deep, and it sends nothing back.  So the
IIgs's path is a PACED QUEUE and not a handshake: `PiAdbmap::from_ascii` turns
the character into the key that makes it plus the modifiers held while it is
pressed, and one event goes out every 16 ms - about a frame, a fast human, and
far slower than the ROM drains its queue.  A script that wants to know the
machine READ the key waits on the mirror (`wait_for_text`), which is what it
should have been doing anyway.

`from_ascii` is written from the keyboard, not by inverting the evdev table:
that one says which ADB code a physical key is, and this one has to say which
key AND WHETHER SHIFT IS HELD, which the other cannot know.  So they are two
tables and `adbmap_test` presses every unshifted character through BOTH and
compares the code - 244 checks now, up from 184.  Return is the RETURN KEY and
not Control-M, deliberately: the ROM looks at keycodes and the Control Panel
navigates by them.

**THE SPEED SWITCH IS THE MACHINE'S, NOT THE HOST'S.**  `$C036` bit 7 is the
IIgs's high-speed bit and the ROM, the Control Panel and every disk routine
drive it.  The governor now follows it: bit CLEAR gives exactly 1.0 ops per
bus cycle, because a program that cleared it believes it is on a 1 MHz Apple
II and has timed its loops for one; bit SET gives whatever the host asked for
in ACCEL_CTRL.  Running a slow-mode program at the fast target is not
"faster", it is wrong - the ROM's own self-test measures things.  The plan
listed this as a milestone-1 row and it had not been built; the gate for this
rung names it ("the self-test at the 2.8x governor"), which is what found it.

**THE `GS = 0` PARITY GATE.**  Battery **35/35** (`accel_vl` 98 checks, 0
errors), `gs` **7/7** with `boot_gs` still AT FLOOR at 67,398, host **40/40**
on the Pi.  The build: **TIMING MET, wns +0.012, whs +0.015, 0 failing
endpoints of 65,196**; 26,821 LUTs, 18,640 flops, 86 of 135 block RAM tiles.
There is no magic slack figure here and +0.012 against the previous +0.027 is
fifteen picoseconds, which is inside this board's build-to-build spread on
identical source.

**THERE IS NO VALID UTILISATION COMPARISON, and saying so is the point.**  The
last LUT count this sheet records is rung 1b's 28,941, which predates rungs 2
and 3 - and those grew the region table from ten entries to thirteen, added
four registers and the shadow duplicate, all of them live at `GS = 0` as well.
The last bitstream's own `utilization.rpt` was overwritten by this build, so
the number it would have given is gone.  26,821 against 28,941 is therefore
two rungs of drift and one parameter, not a measurement of either.  The
structural check stands in its place and is the one that matters: the `GS = 0`
netlist synthesises `cpu65c02`, `iline`, `dline` and `iscan` and no `gs_io` or
`cpu65816`, with `GS` bound to `1'b0` at every level - which is what "the
plain build is unchanged" actually asserts.

**A FINDING FROM THAT BUILD, and it is not this rung's.**  The depth census
reports 142 new deep-tail endpoints.  Thirty-three are the generate blocks'
renames - `u_iline` is `g_fronts.u_iline` now and `u_cpu` is `g_65c02.u_cpu`,
the same silicon under a new name - and those are expected and were predicted
before the build ran.  **The other 109 are inside `card_link`**: 82 into
`u_filter`, 8 into `u_merge`, 7 into `u_capture`, 8 into `u_ring`, 3 into
`u_wb_arb`, 1 into `u_regfile`.  Nothing in this rung can reach them: every
`GS` term added here is `GS && x`, `!GS && x` or `GS ? a : b` with `GS` a
literal, which folds during ELABORATION, before synthesis sees it.  `build/depth_baseline.txt` was last written at
fw `8bdc601`, which is BEFORE rung 1b rewrote the merge queue, the filter and
the capture for the 64-bit record; rung 1b's build gate reported timing and
utilisation and did not re-save the baseline.  So the reading is that the
baseline went stale two rungs ago and this build is the first to say so.
THAT IS AN ARGUMENT AND NOT A MEASUREMENT, so it is settled by building the
unmodified branch head and diffing the two censuses rather than by re-saving
the baseline over the question.

**THE FIRST IIgs BITSTREAM (2026-09-09, `build/results/master_top_gs.bit`).**
`build/run_build.sh first_light --gs`: **TIMING MET, wns +0.045, whs +0.060,
0 failing endpoints of 52,100.**  20,953 LUTs (33% of the Pt), 13,054 flops,
**94 of 135 block RAM tiles** and 2 DSPs.  Synthesis: 0 errors, 0 critical
warnings.  The netlist is the design: `cpu65816`, `gs_io`, `gs_adb`,
`gs_clock`, `gs_intc`, `gs_iwm` synthesised; `cpu65c02`, `iline`, `dline` and
`iscan` at ZERO instances; all four memory-init files - the 65816's three
microcode ROMs and the ADB keymap - read at elaboration.  Block RAM is the
number to watch: 41 tiles free, and rung 7's DOC wants 16 of them.

Route was not easy and the log says so: the first pass ended at WNS -0.111 and
the incremental placement pass brought it back to +0.045.  A build that has to
be rescued is one to watch rather than one to celebrate, so the first
long-chain census is recorded here even though there is nothing yet to compare
it against - **max depth 22, 1,559 paths at >= 10 levels, 134 at >= 14**.

`build/wns.sh` learned two things from grading it.  It names
`master_top_gs.bit` for a IIgs log instead of quoting the IIe bitstream's name
and mtime - the same stale-results confusion `build/build.sh` takes such care
over.  And it does NOT diff a IIgs census against `build/depth_baseline.txt`:
that baseline is the IIe's, and a design with a different core, no fronts and a
chipset the IIe never had would show its every difference as a regression.
The census is printed and nothing is called new until the IIgs has a baseline
of its own, which it gets when the design settles rather than now.

## Rung 4b: first light, and what it found (2026-09-09)

The bitstream loads, the link comes up with the GS stamp, the card reports
itself a IIgs (CPU_SOURCE bit 17), the host ships ROM 3 as 1024 physical pages
and says so, and **the 65816 comes out of reset and executes 2,530,109
instructions off the card's memory path**.  Then it leaves it.  The machine
does not reach a screen.

ONE REAL DEFECT AND TWO MISREADINGS, and the misreadings are written down
because both were said out loud before they were checked.  The pattern in both
was the same: a counter at zero was taken for a mechanism failing, when the
mechanism was fine and the zero meant something narrower.

**1. THE RUNAWAY.**  Two samples of `accel status` a minute apart:
instruction fetches frozen at 2,530,109, RAM at 90,972 and writes at 158,667 -
all three UNCHANGED - while bus ops went from 67.9M to 124.6M and keyboard
polls from 9.26M to 17.0M.  A core that executes no new on-card fetch but
keeps taking bus cycles is fetching its loop OVER THE BACKPLANE, from a page
the map calls BUS class, and `CX 61` says next to nothing in `$Cxxx` is being
served from the internal ROM.  The bus-to-keyboard ratio is about 7:1, which
is the shape of a three-or-four-byte poll loop.  So the ROM got somewhere it
should not have and is running whatever the physical IIe returns.

**2. THE TRACE RECORDED NOTHING, and the reason is NOT the sparse filter.**
`tools/pi.sh trace --seconds 3 --reset` wrote **0 words**.  The first reading
of that was that the filter discards a IIgs's stream, and it is WRONG - said
here because it was said out loud before it was checked.  The filter's keep
rule is `!sparse || on_edge || in_io || !in_rw` (`bus_event_filter.sv:138`):
`in_io` is the address's top nibble being `C`, which is bank-blind and so
still true on a IIgs, and every write is kept regardless.  And the counters
agree that the stream flowed: `skips=965,182` SKIP words standing for
`skipped=3,436,731` cycles, `mgaps=0`, `mlost=0`, and a `peek` of `$0400` came
back with real bytes rather than the `--` an unseen byte shows - which the
mirror can only have learned from the stream.

So the stream reaches the host.  What did not work is the TRACE ARMING: the
recorder arms and waits for the next RES', and the machine was already running
when it was asked, so the RES' it was waiting for is the one that never came.
That is a procedure question, not a gateware one, and the next attempt arms
the trace BEFORE the machine is started rather than after.

The blank `$E0` text screen therefore still stands as unexplained, and is not
excused by a blind mirror.

**3. THE CARD CALLS THE IIgs's MESSAGES UNKNOWN, and that is a lie rather
than a loss.**  `card: unknown message type 0x30 (len 1) skipped ... is the
bitstream older than this host?`, `unk=36`.  The first reading was that the
message is dropped and the clock never fed - WRONG, and recorded as wrong for
the same reason as the one above.  `ft601_msg_rx.sv` fires `msg_valid` and
delivers the payload REGARDLESS of `hdr_known`; `unknown_valid` is only a
notice.  So GS_TIME lands, and so have GS_BRAM and ADB_KEY all along - which
is why rung 3e's battery RAM worked on the bench with the same module.

What was actually wrong is the whitelist, and all THREE of the IIgs's types
were missing from it - `$2E` and `$2F` since rung 3.  The notice they printed
is exactly backwards ("the gateware does not consume" a type it does consume,
"is the bitstream older than this host" when it is newer), and a stream of
them buries the notices that mean something.  Fixed in rung 4b.

**WHAT THE BENCH HAS THAT THE MACHINE DOES NOT: A BACKPLANE THAT SAYS $00.**
`sim/boot_gs_tb.sv:186` is `data_pin = data_oe ? data_drive : FLOAT_BYTE`,
and FLOAT_BYTE is `8'h00`.  Every `$C0xx` address `gs_io` does not claim, and
every slot page, reads back ZERO on the bench and reads back WHATEVER THE REAL
IIe DRIVES on hardware.  That is not a wiring mistake, it is the largest real
difference between the machine that boots ProDOS in simulation and the machine
that ran away on the board, and the candidates in order of how cheaply each
can be tested:

- **`$C061`-`$C063`, the Apple keys.**  The GS ROM reads them at startup to
  decide whether Option or Command is held - which is the door to the self
  test and the Control Panel.  `gs_io` does not claim them, so on hardware
  they are the physical IIe's GAME PORT, and a game port with nothing plugged
  into it FLOATS.  A floating input that reads as pressed sends the ROM down a
  path the bench has never taken.  This is the decision the plan recorded
  ("Open/Closed Apple from the real game-port buttons") meeting an input that
  is only defined when something is plugged in.
- **`$C050`-`$C05F`, the video switches.**  The map snoops the op stream so
  the EFFECT happens either way, but the byte a READ returns is the IIe's
  floating bus rather than the IIgs's.
- **The slot pages.**  `$C02D` decides which are the internal ROM's and which
  the backplane's; on the bench the backplane's are zeros, on hardware they
  are whatever cards are in the machine.
- **`$C030`.**  Unclaimed, so a real cycle to the motherboard's speaker.

None of these is confirmed.  The instrument that confirms one is a bus trace
compared against the bench's, and the next hardware session arms the recorder
BEFORE starting the machine rather than after (see above).

**AND A DESIGN QUESTION THE HARDWARE ASKED.**  The user reports HORRIBLE NOISE
FROM THE SPEAKER while the machine runs away.  That is not a side issue, it is
the design working as written: every `$C0xx` address `gs_io` does not claim
rides a REAL CYCLE TO THE MOTHERBOARD, and `$C030` is the IIe's speaker.  A
65816 looping at a megahertz through garbage that lands anywhere in `$C03x`
toggles the physical speaker on every pass.  Whether or not the runaway is
fixed, `$C030` reaching the motherboard at all is probably wrong - the IIgs's
speaker is the card's and the host's (rung 7), and a runaway core driving the
real one is a bad failure mode to have designed in.

**WHAT THIS RUNG DOES NOT HAVE, and should be read as a risk.**  No bench
instantiates `master_top` - not on the IIe either.  Every bench in sim/ builds
the machine itself "as master_top wires it", so the top level's own wiring has
never been simulated on either machine; on the IIe that gap has been closed by
years of hardware, and on the IIgs it has not been closed at all.  The first
GS bitstream is therefore the first time this wiring runs anywhere, and the
capture path is the instrument for it: `apple_bus_read` is instantiated in the
GS build exactly as in the IIe's, so a driven cycle can be CHECKED against
`sim/boot_gs_tb.sv`'s trace rather than inferred.

## Rung 4b, part 2: the fixes first light bought (2026-09-09)

**THE MIRROR WAS NEVER TOLD WHICH MACHINE IT WAS, and that was the blank
screen.**  `AppleMemory::set_machine()` exists, `classify_gs` exists, the
SHADOW duplicate exists - and NOTHING IN THE HOST EVER CALLED set_machine, so
`machine_` sat at its `IIe` default and every op was classified by the IIe's
map.  Bank $00 filled correctly, `$E0` and `$E1` were never written at all,
and the display - which reads `$E0` on a IIgs - drew a screen of `$00`s, which
is a screen of `@`.  One line in `Pipeline::configure`, host only, no
bitstream.  Confirmed on the machine: the text page went from `@` to spaces
the moment it landed.

This is the shape of the whole rung's mistakes: a piece that was BUILT and
TESTED (`gs_memory_test` sweeps `classify_gs` against a second model and
passes) but never WIRED.  The oracles all passed because they call
`classify_gs` directly; only the live path went through the selector.

**$C03x MUST NOT REACH THE BACKPLANE, and the user heard why.**  Two separate
faults with one symptom - bursts of noise on a IIgs boot:

- `rtl/speaker.sv` decoded `$C030-$C03F` as the speaker.  That is CORRECT for
  a IIe, whose decode is partial in real hardware.  On a IIgs those are
  separate registers and `$C03C-$C03F` is the SOUND GLU - and the capture
  caught the ROM writing `$C03D` **65,465 times** clearing the DOC's 64 KB of
  sound RAM at startup.  Sixty-five thousand speaker toggles.  Now
  parameterised on `GS`: the IIgs decodes `$C030` alone.
- `gs_io` did not claim `$C030`, so it rode a REAL CYCLE to the motherboard -
  and the machine this card lives in decodes `$C030-$C03F` for its own
  speaker, partially, as real hardware does.  Every other address in the range
  was already claimed; claiming this one closes it, and nothing in `$C03x` is
  ever presented to the bus again.  The card's speaker model still sees it,
  because it watches the fast event and not the backplane.  The claim does not
  move the reference: `$C030` reads back `$00`, which is what the bench's stub
  backplane returned for it, and `boot_gs` is still AT FLOOR at 67,398.

**THE CARD CALLED ITS OWN MESSAGES UNKNOWN.**  All three IIgs types were
missing from `ft601_msg_rx`'s whitelist - `$2E` and `$2F` since rung 3.
Nothing was lost (an unknown type is still decoded and delivered) but every
one printed "the gateware does not consume" about a type it does consume, and
a stream of them buries the notices that mean something.

**THE `$C036` GOVERNOR**, which the plan listed as a milestone-1 row and which
had never been built: the speed bit clear now gives exactly 1.0 ops per bus
cycle.  A program that cleared it has timed its loops for a 1 MHz machine.

**AND A LEAD ON THE BLANK SCREEN, from the user.**  The IIgs's video is
chosen by registers a IIe does not have, and `shr_active()` is
`gs_video() && (newvideo & $C0) == $C0` - with `gs_video()` now always true on
a IIgs, `$C029` alone decides whether the host renders Super Hi-Res from `$E1`
or a legacy mode from `$E0`.  **The one image that works is the one that
forces VidHD/SHR**; the ones that are blank are legacy.  That is the signature
of the host being stuck in SHR while the machine draws hi-res.

The reset path itself is NOT the fault, which was checked before the lead was
believed: both `AppleVideo::reset_switches` and `AppleMemory::reset_switches`
assign `sw_ = Switches{}` on a detected RES', clearing `newvideo`, `shadow`
and `sltrom`; the fast event carries the RES' level in bit 17
(`event_merge.sv:111`) and the filter keeps every cycle where it changes, so a
reset reaches the host even on a machine that is 99.6% fast ops.  What is not
yet known is what `$C029` actually holds when the screen is blank.

So the status line now says: `gs=`, `newvideo=`, `shr=`, `shadow=`, `sltrom=`.
"The screen is blank" then splits into "the machine drew nothing" and "the
host is rendering the wrong thing" without another boot to find out which.

## Rung 4b, part 3: the page-2 lead (2026-09-09)

Nox boots and plays - DHGR and HGR both correct - but a screen that has been
drawn once and left alone shows GARBAGE, while anything the program redraws
comes good.  The user's observation is the one that named it: **"the tiles
which are static are the ones which remain garbage"**.  That is not a
rendering fault.  A renderer that picked the wrong page or the wrong mode
would be wrong about the whole frame, every frame; content that heals when
rewritten means THE HOST'S MIRROR HOLDS BYTES THE MACHINE NEVER WROTE.

Everything else was ruled out first, by measurement:

- **The `$E0`/`$E1` SHADOW is faithful** - bank $00 and bank $E0 are
  byte-identical over TEXT1 (1024/1024), HGR1 (8192/8192) and HGR2
  (8192/8192), with matching non-zero counts.  **THIS TEST WAS NOT SUFFICIENT
  AND IS RECORDED AS SUCH**: it proves the duplicate copies faithfully, not
  that the source is right.  A write the host never received is missing from
  BOTH banks and they still agree perfectly.
- **The switch models agree**: `msw=hsw=e30` (card and mirror), and the
  display's own word `vsw=8c` - hires, page2, page2_displayed - agrees with
  them.  `vsw` was added for this and it earned its keep by killing the
  hypothesis it was built to test: the display DOES follow the page flip.
- **SHR is not involved**: `shr=0`, `newvideo=01` throughout.
- **The program double-buffers**: the two hires pages hold different pictures
  (4100 of 8192 bytes in common), which is why the static right-hand menu
  panel is pixel-identical between a good frame and a garbage one and only the
  animated map differs.

**THE LEAD.**  `fbpeek` compares the CARD's side copy of the display pages
against the host's mirror, and the split is sharp:

    $2000 (HGR page 1):   0 of 256 differ
    $4000 (HGR page 2): 102 of 256 differ

with the mirror holding bytes where the card holds zeros ($4000: card `00`,
mirror `40`).  Two pages the host treats identically, and only one is right.

**CAVEAT, stated rather than buried**: the card's side copy is the IIe
floating-bus simulator's (`rtl/fb_sim.sv`), so how faithfully it tracks page 2
at `GS = 1` is itself unverified.  The 0-vs-102 split is a strong signal, not
a proof, and the next step is to confirm it against something that is not
fb_sim - the `gs_mirror_test` replay is the instrument that already found
three host bugs of exactly this kind at rung 3e.

**WHERE TO LOOK FIRST.**  The capture shows `$C004`/`$C005` - RAMWRT off/on -
written **80,541 and 24,691 times** in seven seconds: the program toggles
auxiliary memory around every write burst.  The aux halves of the two pages
are lopsided in the mirror (`$E1` HGR1 4,207 non-zero, HGR2 2,718), and DHGR
interleaves main and aux, so a page whose aux half is half-populated renders
as exactly the smear seen.  A host whose RAMWRT state is momentarily out of
step with the card's puts a write on the wrong side.  Ordering between the
FAST path and the BUS path is the thing to check: at `GS = 1` the machine is
98.7% fast ops while `$C004`/`$C005` ride the bus, so a switch change and the
writes it governs travel by different routes.

NOT the accelerator: the flashing persists with the governor holding the
machine at 1x (`accel ratio=1`, measured 0.96x, "held by the governor" - which
is also the first confirmation that the `$C036` governor works).
## Rung 4b, part 4: two holes found by reading, not by testing (2026-09-09)

The user stopped the live testing and named the invariant instead: **every
write, every soft switch, and - in a full capture - every read, must go out
over the capture, perfectly serialized.**  Both of the following came from
reading the capture path against that sentence.  NEITHER HAS BEEN RUN: the
machine was unplugged before the tests could execute, so what follows is
"compiles and is argued", not "passes".

**1. FULL CAPTURE WAS NOT FULL** (`rtl/event_merge.sv`).  The two halves of
the same stream disagreed about what "full" means:

    bus_event_filter:  keep      = !sparse || on_edge || in_io || !in_rw
    event_merge (was): fast_keep = ... || (!fast_quiet && (!sparse || ...))

On the bus side `!sparse` is a TOP-LEVEL term, so a full capture keeps every
cycle.  On the fast side it sat INSIDE the `!fast_quiet` conjunction, so an op
apple_mmu marked quiet was dropped even when the host had asked for
everything.  The lesser problem is that a full capture which silently omits
ops is not one.  The greater is what "quiet" means: `q_swi_quiet` is the
CARD'S OPINION that the op changes no switch (`qi_c05x && qi_same5`, or a
`$C00x` write with `qi_same0`), and that is only safe while the card's switch
state and the host's ALREADY AGREE.  Once they have diverged, suppressing the
op suppresses the very event that would have corrected the host - so a
divergence STICKS instead of healing at the next touch.  `!sparse` is now a
top-level term on both sides.

**2. THE DISPLAY HAD NO STATEREG, and this is very likely the flashing**
(`src/apple_video.cpp`).  `$C068` moves SEVEN switches with one write, three
of which are AppleVideo's: PAGE2, RAMRD, RAMWRT.  `AppleMemory` has the case
and follows it correctly.  **`AppleVideo` had no case for `$C068` at all** -
and `AppleVideo` is the object the DISPLAY draws from: `page2_displayed()`
picks the page, `ramrd`/`ramwrt` pick the bank a write belongs to.

So a IIgs that moves the displayed page through STATEREG rather than
`$C054`/`$C055` moved it in the memory mirror and NOT in the display, and the
display went on drawing the other page until something touched `$C054`/`$C055`
directly.  On screen: static content stale, redrawn content correct - which is
exactly how the user described it ("the tiles which are static are the ones
which remain garbage"), and why `msw`/`hsw` could agree perfectly while the
picture was wrong.  `vsw` was added to see that difference and is what made
the split visible.

**THE USER'S POINT ABOUT INTERRUPTS is why it was so pervasive**: the IIgs
firmware's interrupt handler saves and restores machine state THROUGH
STATEREG, because it is one read and one write instead of a dozen strobes.
`$C068` is therefore written many times a second on any machine taking
interrupts, and every one of those writes was invisible to the display.  The
display's PAGE2 was not merely stale after an explicit flip; it was being
left behind continuously.

It is a IIgs-only case and gated as one: `gs_video()` would be too generous,
because a VidHD in a IIe takes the video registers but does not give the
machine a state register.  `tests/video_test.cpp` gains
`test_statereg_moves_the_displayed_page` - the display follows PAGE2 both
ways, RAMRD/RAMWRT carry, a IIe ignores `$C068` even with a VidHD, and a READ
of it moves nothing.

**WHAT THE EARLIER TESTING COULD NOT HAVE FOUND, and why.**  The mirror replay
passes on both a ProDOS boot (1,817,727 ops, 481 pages, 0 bytes) and a Nox
boot (8,326,642 ops, 510 pages, 0 bytes, and 39 pages written in bank $01 so
the auxiliary path IS exercised) - because the replay checks `AppleMemory`,
which was right.  The bug was in `AppleVideo`, which no oracle covers.  That
is the same shape as the `set_machine` bug earlier in this rung: a piece that
is built and swept, and a live path that never reaches it.

## Rung 4b, part 5: the bank never reached the host (2026-09-09)

The user's question was the right one - "how are some events not getting
forwarded, or getting forwarded with bad data?" - and the answer is the
second.  `rtl/event_merge.sv`, building a fast op's record:

    wire [63:0] fast_word = {fast_data, CLS_FAST, 4'd0, 16'd0,
                             T_FAST, 8'd0, vbl_level, ..., fast_addr};
                                     ^^^^^
Word 0's `[27:20]` is **the 65816's bank byte** (docs/PROTOCOL.md, "The event
record").  It was a hardwired `8'd0`, and `event_merge` had no bank input at
all.  So **every fast op reached the host labelled bank $00** - and at
`GS = 1` that is 98.7% of everything the machine does.

The whole chain existed except its last link.  `accel_seq` computes the bank
and drives `fev_bank`; `master_top` declares `fev_bank` and takes it from the
dispatcher; and then it goes nowhere - `card_link` had no `fast_bank` port to
pass it through.  master_top's own comment said so in as many words and was
never revisited: *"NOTHING TAKES IT ON THIS BUILD, and that is right: the v6
record has the field but card_link's fast port is sixteen bits and a IIe's
bank is always zero, so the merge hardwires it."*  True at rung 1b, which
built the record on the IIe; wrong from rung 3a, which put a 65816 behind it.

**WHY NO ORACLE COULD SEE IT.**  `tools/gs_mirror_test.sh` replays the
BENCH's op stream, and `sim/boot_gs_tb.sv --mirror` writes those records
DIRECTLY in the host's shape - it never passes through `event_merge`.  So the
replay's banks were right and the hardware's were zero, and the replay passed
on both a ProDOS boot and a Nox boot (8,326,642 ops, 510 pages, 0 bytes) while
the machine on the bench drew a corrupted screen.  The oracle bypassed the
faulty code.  That is the third time this rung that a piece was built, swept
and not WIRED (`set_machine`, `AppleVideo`'s STATEREG, this), and the pattern
is worth naming: every one was found by looking at the live path, and none by
a test.

**HOW IT REACHES THE SCREEN.**  A write the machine makes in bank $E0, $E1 or
$01 arrives as a write to bank $00 at the same offset.  The host puts the byte
in bank $00 - where it does not belong - and then, if that offset is a display
page, its own SHADOW derivation copies it into $E0 as well.  So a byte the
machine wrote somewhere else appears in the picture, stays there because
nothing rewrites it, and the machine itself is unaffected because the CARD
used the real bank.  Machine fine, display corrupt, damage permanent until
overwritten: which is what was reported.

Fixed: `fast_bank` added to `event_merge` and `card_link`, connected in
`master_top` from `fev_bank`, tied to zero in `snoop_top` and in the benches
that drive the merge directly.  At `GS = 0` it is a constant zero and the IIe
build is unmoved.

**CONFIRMED ON HARDWARE 2026-09-09** (fw stamp 14:53:38, TIMING MET wns
+0.193 whs +0.031, 0 of 52,319 endpoints): with the bank on the record, **Nox
Archaist's party menu draws CLEANLY** - the map, the ship, the party names,
the health bars and the prompts, frame after frame, with only the animated
water tiles moving between them.  It is the same screen that had been
alternating between correct and garbage all afternoon.  The machine was never
wrong; only the picture was.

## Rung 4b, part 6: the SHR stride, and $C029 (2026-09-09)

**THE GARBLED SHR WAS AN 80-PIXEL SHEAR PER ROW.**  The user named it from the
screen - "the lines are basically getting interlaced" - and the arithmetic
agrees exactly.

`AppleApp::Config::vidhd_possible()` was `vidhd_slot != 0 || boot_menu`, and
that is what decides whether the SHR TEXTURE AND VIEWPORT are created at
start-up (`apple_app.cpp:64`).  With `vidhd = 0` and `boot_menu = off` it was
false, so `shr_tex_` (640x200) was never made and `vp_shr_` never placed -
while the PUBLISH side had been changed this rung to `(vidhd_on_ ||
cfg_.iigs)` and was sending 640x200 frames anyway.  `tex_for()` requires
`shr_tex_.texture() != 0`, got zero, and fell back to the 560x192 Apple
texture.  `TextureLayer::upload`'s size check then PASSED - 384,000 >= 322,560
- and uploaded the SHR buffer with a 560-PIXEL STRIDE OVER 640-PIXEL ROWS.
Eighty pixels of shear a row, accumulating down the screen, with the colours
perfectly correct because the RGB triples themselves were untouched.

A IIgs HAS A VGC ON THE MOTHERBOARD: SHR is always possible there, with no
card in any slot.  The predicate says so now.

**HOW IT WAS FOUND, because the method is the point.**  The buffer was dumped
from a frozen machine and RENDERED OFFLINE by the same arithmetic
`shr_render` uses - `$2000 + 160*y` in, `y*640*3` out - and came out as a
perfect Prince of Persia title screen.  That single test proved the data
right, the algorithm right, and therefore the fault downstream of both, in one
step and with no hardware.  Everything before it had been chasing the data.

**AND A CORRECTION TO THIS SHEET'S OWN METHOD.**  Before that, the same
screenshot was asked for repeatedly on the grounds that a "matched instant"
was needed - when the screen NEVER showed a clean frame, so any screenshot was
matched and the evidence was already in hand.  The user said so.  A hypothesis
that cannot distinguish two outcomes is not worth a measurement.

**$C029, three faults, from KEGS.**  Found while chasing the above and real
independently of it:

- the card's write masked `& $A0` and **discarded bit 6** (linearise), so a
  program that turned linear addressing on and read it back was told it had
  not.  KEGS splits the register - `g_c029_val_some = val & 0x41`, the video
  state takes `val & 0xa0` - and the read recombines them, so the byte read
  back is `val & $E1` (moremem.c:1085,1616).  The card stores that now.
- the card's reset was `$01`.  KEGS's is `g_c029_val_some = 0x41`
  (moremem.c:53): **linearise is SET at power-on**.
- the host required bits 7 AND 6 to render SHR at all - AppleWin's
  `VidHDCard::IsSHR`, which is the rule for a VidHD IN A IIe.  On a IIgs SHR
  is BIT 7 ALONE (`BIT_ALL_STAT_SUPER_HIRES = 7`, defcomm.h), and bit 6 is
  read back and never consulted for the picture - `g_c029_val_some` appears
  nowhere else in KEGS.  Two machines, two references: the pair for a VidHD,
  bit 7 for a IIgs.

None of the three was the garbling, and saying so matters: Total Replay writes
`$C1` and had `shr = 1` throughout.

Build: TIMING MET wns +0.036 whs +0.051, 0 of 52,296 endpoints.

## Rung 4b, part 7: the Apple's own keyboard (2026-09-09)

The machine this card lives in has a keyboard, and until this step it reached
nothing.  Everything the IIe build uses to read it stands down at `GS = 1`,
each for a good reason, and the three together left the real keyboard
electrically present and logically absent:

* `sw_int` is `!GS && ...`, so `park_kbd` was low and the driver's dummy
  cycles parked at `$0000`.  The card never looked at the IOU's latch.
* `kbd_sub_gs`/`pb_sub_gs` stand `kbd_inject` and `pb_inject` down, because
  `gs_io` claims `$C000` and `$C010` for the ADB micro before a bus cycle is
  ever presented - a substitution on top of that would be a second authority
  for the same byte.
* `gs_adb`'s only key source was `word_key`, the host's `ADB_KEY` message.

The decision table (`Inputs`, and the keyboard row of the chipset table) has
asked for this since the plan was written.  It is `rtl/gs_kbd_a2.sv` now.

### The byte is the wrong shape, and the map inverts

The IIe's encoder has already applied shift, control and caps lock and thrown
the keycode away: what is in the latch is an ASCII byte with the strobe in
bit 7.  An ADB micro is given the opposite - a keycode and a modifier byte -
and makes the ASCII itself.  So the byte is run BACKWARDS through the micro's
own keymap and forwards again.

**THE INVERSE EXISTS AND IS EXACT**, which was not obvious before it was
computed.  `tools/gen_adb_revmap.py` inverts KEGS's `g_a2_key_to_ascii` under
two rules - only main-block keycodes (below `$41`; the keypad starts there and
KEGS's duplicate rows are above `$60`), then plain before shift before control
- and the result is TOTAL: all 128 ASCII values have exactly one answer, with
no tie left inside the winning column, and every one of them reproduces its
own byte when fed back through the forward selection.  56 are plain, 47 need a
synthesized shift, 25 a synthesized control.  The generator asserts totality,
uniqueness and the round trip rather than assuming any of them, because a
change in KEGS's table could break all three - the same argument as
`gen_adb_keymap.py`, and see [[oracle-from-the-reference]].

The tie-break is what makes the answers right rather than merely consistent:
`$0D` is the RETURN KEY and not control-M, `$08` the LEFT ARROW and not
control-H, `$09` Tab, `$1B` Esc, `$7F` Delete.  A key that produces a byte on
its own is a truer account of what the user pressed than a modifier
combination that happens to land on the same value.

### The walk, and the strobe nobody was clearing

`gs_kbd_a2` owns `park_addr` at `GS = 1` and walks four slots: `$C000` (the
latch), `$C010` (the clear), `$C061` and `$C062` (the Apple keys).  A dummy is
nobody's op, so the whole thing costs the machine no cycle - the standing
rule.

**THE TWO BUILDS PARK ON `$C000` FOR OPPOSITE REASONS.**  On the IIe it is a
SHORTCUT: the program's `$C00x` read would have reached the IOU anyway and the
sample lets the card answer without the cycle.  On the IIgs it is the ONLY
PATH, and that difference has a consequence the IIe build never has to think
about.  There, the program's own `$C010` rides the bus on purpose
(`apple_mmu.sv`, "`$C010` is the real strobe's and rides the bus"), so the
program clears the IOU itself.  Here `gs_io` answers `$C010` on the card and
the IOU never sees one: without the `$C010` in the walk the first key would
latch and stay, and **the same key pressed twice would be invisible**, because
only bit 7 says "again" and nothing would ever clear it.

That same read pays for itself twice: on a IIe, `$C010` returns ANY KEY DOWN
in bit 7, so the release of a key can be SEEN rather than guessed, and
`gs_adb`'s `hard_key_down`, `$C025` bit 5 and the any-key-down a game polls
all follow the user's finger.  A four-frame timeout stands behind it, because
a new strobe landing on the `$C010` slot is seen by its low seven bits alone
and a key stuck down for ever is the one failure that wedges a machine.

**AUTO-REPEAT IS THE IIe's, NOT THE MICRO's.**  A held key re-strobes in the
IIe's own encoder, so repeats arrive as ordinary presses and `gs_adb` must not
add its own on top - it does not, because its repeat arms from an event's
modifiers and a fresh press re-arms the delay each time.  The Control Panel's
repeat setting therefore does not reach the real keyboard, which is the honest
behaviour: the rate belongs to the hardware the keys are on.

### The Apple keys are the only modifiers that are really held

Open- and Closed-Apple are on the IIe's game port, and on a IIgs `$C061` and
`$C062` ARE Command and Option (KEGS `moremem.c`: `adb_is_cmd_key_down() ||
g_paddle_buttons & 1`).  A direct read of either already reached the
motherboard on this build - `gs_io` does not claim `$C06x` - so a program
looking there saw the real keys before this step.  What had no source was
`$C025`, which is what GS/OS's Event Manager reads.

**THEY ARE MERGED AT THE READ, NOT WRITTEN INTO `c025_val`** - a distinction
the bench found the hard way.  `gs_adb` latches an event's modifier byte into
`c025_val`, and these two are LEVELS: put them in the event and the latched
copy outlives the finger, so the key that let go of both left them set for
ever.  So `gs_kbd_a2`'s event carries only the shift and control the reverse
map inferred, and `c025_rd` (the port is renamed, because what leaves the
module is what `$C025` reads) joins `live_mods` in at the read, always
current.

### What is lost, and it is all in the shape of the event

Not in the character - the round trip is exact.

* Caps lock cannot be told from shift; the encoder applies both and sends one
  byte, so an upper-case letter is reported as shift.
* A modifier pressed ALONE is invisible: shift, control and caps make no
  strobe, so `$C025`'s shift and control bits appear only for the instant of a
  key that used them.  Command and Option are the exception.
* No function keys, no keypad, no Help, no Home/End - the keyboard has none.
  Ctrl-Command-Esc (the Control Panel) and Ctrl-Option-Reset (the self-test)
  are all reachable.

### The lever, and what the benches say

`ACCEL_CTRL[28]` - `swint` on the host - is reused rather than spent on a new
bit: on both machines it means "stop reading the real keyboard on the
dummies", and on a IIgs the Pi's USB keyboard goes on working with it off.
The boot hold excludes the walk for the reason it excludes the IIe's.

* `sim/gs_kbd_a2_tb.sv` (31 checks) is the pair driven together from a MODEL
  IOU, because separately neither module says anything useful - the claim
  worth checking is that the byte comes back, and it is only visible across
  the two.  The headline case sweeps **all 128 ASCII values** through the IOU
  and out of `$C000`.  That is the generator's claim made of the silicon: a
  table that inverts and an implementation that does not is exactly the gap a
  generator's self-check cannot see.
* It found three real faults in the first run, all in the code and none in
  the table: the Command/Option latching above; a held key that was dropped
  SILENTLY when the walk stopped (the lever, the hold), leaving `gs_adb`'s
  `hard_key_down` stuck high with no up event to clear it - the release now
  fires whether the walk is running or not; and a stale raw-event queue,
  which was the bench's own fault.
* `sim/gs_adb_tb.sv` gained the two sources sharing one buffer, which is what
  the decision table asked for, and the level/latch distinction above.
* `sim/suite.sh gs` is **9/9**, with `adb_revmap` and `gs_kbd_a2` added and
  the KEGS divergence floor UNMOVED at 67,398 - the new source is inert when
  nothing drives it.

The host needs no change: the path is entirely on the card.  Only `swint`'s
help text and its config comment say what the bit means on a IIgs.

### ON HARDWARE (2026-09-09)

`build.sh --gs` **TIMING MET: WNS +0.082, WHS +0.020, 0 of 52,476 failing
endpoints**; 21,107 LUTs (+154 over rung 4b for the reverse ROM and the walk),
BRAM unchanged at 94 of 135.  The route needed the post-route physical
optimisation to land it - routing ended at -0.024 with ONE failing endpoint in
`clk_ctrl_raw`, which physopt cleared to +0.082 - the same shape as rung 4a,
where the first placement pass missed and the incremental one recovered.

Loaded, and Total Replay v6.1 boots to its title screen with 519 games, so
**the walk did not disturb the machine**: the dummies now put `$C000`,
`$C010`, `$C061` and `$C062` on the backplane where they used to put `$0000`,
and nothing minded.  **THE USER CONFIRMS BOTH KEYBOARDS WORK** - the Apple's
own and the Pi's, into the one buffer.

**A PROCEDURE ERROR WORTH RECORDING, because it cost a false alarm.**  The
first load looked like a total regression: a screen of NULs whatever was
chosen to boot, no Pi keyboard, and a beep at the wrong pitch.  None of it was
the gateware.  `swhost` had been started with a BARE `start`, which reads the
user's `swhost.conf` - `machine = iie` - so the host sent the IIe's ROM and the
banner said so in as many words, and I read past it:

    cpu : MACHINE MISMATCH: the bitstream is an Apple IIgs (build.sh --gs)
          and this host is configured for an Apple IIe (machine = iie)

...along with `ROM not loaded on the card`.  The 65816 had no ROM 3, which is
the whole of it: the NUL screen, the hang, the beep, and the Pi keyboard doing
nothing (the host was sending IIe ASCII into `kbd_inject`, which stands down
at `GS = 1`).  `gs=0` in the status line says the same thing in one field.
The rule the session already carries - name the config, and check WHICH image
booted - covers this exactly; so does reading the banner that is handed back.
A restart WITHOUT a fresh bitstream then hit the known no-register failure on
top of it, which is its own entry under "What is NOT working".

## Rung 4b, part 8: a vector pull comes from the ROM (2026-09-09)

**GS/OS 6.0.1 boots to its splash and the machine dies on its first
interrupt.**  The lead written up above - that `gs_io.sv` wires
`.irq_scan (1'b0)`, so the VGC's scan-line interrupt can never fire - was
WRONG, and reproducing the failure in `sim/boot_gs_tb.sv` from the same
`system6.hdv` said so in one screen.  The bench is `--hdv=` plus
`--watch=A:B`, and the watch is unambiguous:

    cyc 907532: 0001f6 rw=0 dout=$c7   push PCH
    cyc 907532: 0001f5 rw=0 dout=$8c   push PCL
    cyc 907532: 0001f4 rw=0 dout=$a1   push P
    cyc 907532: 00fffe rw=1 din=$00    vector low  = $00
    cyc 907532: 00ffff rw=1 din=$00    vector high = $00
    cyc 907532: 000000 sync=1          -> $0000

An IRQ arrives while slot 7's firmware is busy-polling its EXECUTE port,
three bytes go on the stack, the emulation-mode vector is fetched from BANK
$00 and both bytes read `$00`.  The machine spends the rest of the run in
zero page - `ORA` / `SBC` / `ADC` / `BRK` at `$0000`-`$0006`, exactly 100,000
times in the last 400,000 instructions, the `BRK` returning through the same
dead vector.  **From the outside that looked like a HALT**, which is what the
hardware's frozen counters had suggested; it is not, it is a crash.

**A IIgs IS NOT A BARE 65816.**  The part forces PBR to zero for every vector
fetch and `rtl/cpu65816.sv` does exactly that, correctly.  The MACHINE does
not: its FPI watches the VP' pin and takes the vector from BANK $FF, the ROM,
so the handlers survive whatever the language card happens to be showing at
`$00/$FFxx`.  KEGS is explicit - every vector in `instable.h` and
`sim65816.c` is written as a full 24-bit `$FF/FFxx` address, and
`moremem_fix_vector_pull()` masks it back down to bank $00 ONLY when
`SHADOW[6]` is set, the bit that makes `$C000-$FFFF` in banks $00/$01 plain
RAM with no I/O and no language card.  **The default is the ROM and the RAM
is the exception**, which is the opposite way round from the bare part.

GS/OS trips it because it puts the language card in RAM-read mode early - the
bench reports "bank1, RAM read, write enabled" while the SmartPort is still
loading - and from that moment `$00/$FFFE` is uninitialised RAM.  The IIe
build never saw it: its vectors are the ROM's because the language card is
usually showing ROM, and nothing on that machine redirects.

`vpb` already existed on the core, correct, and `master_top.sv` was throwing
it away (`.vpb ()`).  The redirect is made at THE ONE PLACE THE BANK IS
FORMED, beside the `cyc_internal` parking and for the same reason: the map,
the page cache, the event stream and the host's mirror all read the bank from
that wire, and a redirect they could not see would put the host's model of
memory at odds with the card's.  `sim/boot_gs_tb.sv` makes the same redirect
at the same point, with the comment saying so.

**AFTER**: the same run reaches 3,000,000 instructions across **470 distinct
PCs** in the ROM's handlers with bus traffic climbing steadily, where before
it had four PCs and frozen counters.  `sim/suite.sh gs` is 9/9 and **the KEGS
divergence floor is UNMOVED at 67,398** - which is right, and worth saying
why: early in the ROM's boot the language card is still showing ROM, so bank
$00 and bank $FF read the same bytes there, and KEGS applies the same
redirect anyway.

## Rung 4b, part 9: the ADB mouse (2026-09-09)

Milestone 1 wants the Finder with a mouse, and `gs_adb.sv` had `mouse_valid`
and `mouse_coord` as stubs with the comment "the mouse, not yet fed".
`$C024` already routed into the micro (`gs_io`'s read mux falls through to
`adb_rd`), so what was missing was the model.

Transcribed from KEGS's `mouse_read_c024`, MINUS its host-side shortcuts: the
`em_active` block that reaches into GS/OS's own cursor variables at
`$E1/0190` and pokes them is an emulator's shortcut, not something the
hardware does, and the hide/warp-pointer handling is its window's.  What is
left is the chip.

**THE MODEL IS INVERTED, DELIBERATELY.**  KEGS keeps ABSOLUTE positions
(`g_mouse_a2_x`, and `delta = target - a2_x`) because its mouse comes from a
window with coordinates.  Ours arrives as the Pi's evdev DELTAS already, so
what is kept here is THE MOTION NOT YET HANDED OVER - the same quantity
KEGS's subtraction computes, from the other end.  What software observes, a
stream of deltas clamped to +-$3F with the button on the Y read, is
identical.

The details that matter: `$C024` alternates X and Y and `mouse_coord` is also
`$C027` bit 1, so a program can find its place; each read hands over at most
$3F and KEEPS THE REST, so a fast movement is metered out rather than lost;
bit 7 is the button and only on the Y read (KEGS sets it unconditionally on
the X read - "mouse button not down on x coord rd"); and the register reads
ZERO with ADB mode bit 1 set or when the mouse's own address no longer
matches the one the micro polls.

`MOUSE_MOVE` ($25) needed no change - it already carries signed deltas and
the button levels, the same message `rtl/mouse_card.sv` takes for the IIe's
AppleMouse - so only `msg_free` had to come down through `gs_io`.

**ON A IIgs THERE IS NO MOUSE CARD**, so the host separates the card from the
feed: `mouse_on_` is the slot-5 AppleMouse and `adb_mouse_on_` is the
MOUSE_MOVE feed, and only the feed is armed at `machine = iigs`.  No slot, no
ROM, no slot-clash check.  `mouse = off` still turns it off.

`sim/gs_adb_tb.sv` is **46 checks**: the clamp (100 goes over as $3F then 37,
nothing lost), negative deltas in seven bits, the button only on Y,
accumulation when two moves arrive before a read, and the off-gate.  It also
caught something that was the RULE WORKING rather than a bug: the
auto-repeat section's set-config leaves `mouse_ctl_addr` at 2 while the mouse
is at 3, and the module correctly reported the mouse as absent.

**OPEN, found on the way, not fixed**: `gs_adb`'s main sequential block puts
`frame_tick` ahead of the `act` cases in one if/else chain, so a register
access landing on the same clock as a frame tick is dropped.  It is
pre-existing (it affects `$C010` and `$C026` the same way) and rare - one
clock in ~17,000 - but it is real.

## Rung 7: the Ensoniq (2026-09-09)

GS/OS booted past its splash once the vector pull was fixed, and then the
screen began flashing **"Unclaimed Sound Interrupt"**.  The user's call: don't
stub it, build the chip.

**WHY A FACE COULD NEVER HAVE WORKED.**  $C03C-$C03F were four latches that
read back what the ROM wrote, with the data port answering $00 to everything.
Register $E0 is the DOC's interrupt register and **BIT 7 CLEAR MEANS AN
INTERRUPT IS PENDING** (doc.c:769, "Clear IRQ on read of e0, if any irq
pend"), so a face answering zero claims oscillator 0 is interrupting, for
ever.  GS/OS's dispatcher believed it, found nobody to claim it, and said so.
This is the IWM's constant $C0 from rung 3e exactly - a stub whose one
constant happens to mean "I need attention" - and the lesson repeats: a stub's
default is not neutral, it is an assertion.

### The scan, and where the "+2" comes from

The 5503 services ONE OSCILLATOR PER SLOT at `DOC_SCAN_RATE` = 28.63636 MHz /
32 = 894886.25 Hz, and an oscillator's own rate is that over `osc_en + 2`.
With the usual 32 enabled that is 26320 Hz, the IIgs's familiar sample rate.
So `rtl/gs_doc.sv` has no per-oscillator timer: one NCO, one slot counter
running `0 .. osc_en + 1`, and the last two slots do nothing - they are the
chip's refresh slots, which is what the `+ 2` IS.  At 100 MHz a slot is ~112
clocks, room enough for the register read, the wave fetch and the multiply.

### The accumulator, and the check that confirms it

Each oscillator has a 24-bit accumulator and its slot adds `freq`.  The byte
played is at `index = acc >> (17 - sz + res)` masked to `sz` bits, where
`sz = ((wavesize >> 3) & 7) + 8` and `res = wavesize & 7`, based at
`(waveptr << 8) & ~(size - 1)`.  KEGS carries the same arithmetic folded into
its own SND_PTR_SHIFT fixed point together with the host's audio rate;
unfolded it is that.  The table plays through once, so the end is

    acc >= (1 << (17 + res))

**and that is what says the model is right**: at `res = 7`, `sz = 15` - the
largest table at the finest resolution - the end is `1 << 24`, exactly the
accumulator's width.  It fills the register the chip has, at the corner, with
nothing left over.  A wrong shift would not do that.

### Two ways to stop, and they are not the same

`doc_sound_end`'s `can_repeat`: a fetched byte of ZERO is the wavetable's
terminator (can_repeat = 0), and running the accumulator out means the table
was played to its end (can_repeat = 1).  Then, with `mode = (ctl >> 1) & 3`:

- mode 0 free-running with can_repeat: **start again**.  That is how a held
  note is made, and it does not halt.
- mode 3, **or the partner in mode 3**: swap.  "If either this osc or it's
  partner is in swap mode, treat the pair as being in swap mode" (doc.c:311,
  credited to Ian Schmidt), with the exception that a one-shot which hit a
  zero byte just stops (credited to Olivier Goguel).  Neither is guessable
  from the datasheet; both come from the reference.
- otherwise halt.

### THE INTERRUPT IS A QUEUE, NOT A BIT VECTOR

The part a reasonable implementation gets wrong.  **$E0 does not name the
lowest-numbered interrupting oscillator; it names the OLDEST.**  KEGS keeps
`has_irq_pending` as a 1-based ARRIVAL RANK and renumbers the survivors when
one is removed from the middle (`doc_remove_sound_irq`'s loop).  A bit vector
with a priority encoder answers differently the moment two oscillators
interrupt out of index order, and software servicing them in turn sees the
wrong one.  So it is a real queue here, compacted on removal.  The bench
makes oscillator 9 finish before oscillator 8 and checks $E0 says 9.

**And every FETCH of $E0 clears the head** - so a register read, which costs
two fetches because of the chip's one-access read delay, consumes TWO
interrupts.  The bench asked the wrong question before it was written that way
round, and the answer is the chip's, not a bug.

### The output

The byte is unsigned with silence at $80, so the sample is `(byte - 128) * vol`
- one multiply, asked for as a DSP48 by name (the user's steer: take the
slices).  Control bit 4 picks the channel and the channel's low bit is the
stereo side, so each slot adds to a running left/right pair and the scan's
wrap latches them.

`rtl/audio_sampler.sv` box-averages the pair, but **not on the shared
multiplier walk**: the DOC's mix is signed where everything else there is an
unsigned magnitude, and two decimal orders wider.  It has two DSP48s of its
own.  It does need the box - the scan completes at up to ~298 kHz with few
oscillators enabled, above the 44.1 kHz Nyquist.

The wire format grew from three words a sample to four
(`{doc_l, ay3}`, `{seq, doc_r}`): 706 kB/s where it was 529, on a link that
runs at 335 MB/s.

### And it is not what crashes GS/OS

Worth recording, because the chip was built to fix a crash and did not fix
the one that follows it.  With the DOC in, "Unclaimed Sound Interrupt" is
gone and GS/OS's sound driver initialises against a real chip - and the
machine then dies further on, in the ROM's monitor, with BRK and COP traps in
banks that do not exist.  The bench's end-of-run dump settles the DOC's part
in it:

    the Ensoniq: osc_en 32, ends 0, irqs 0, queue 0, irq 0, ctl $C03C=9d

**No oscillator ever ran and no interrupt was ever raised.**  A swap pair
ping-ponging over dead wave tables was the theory - the unit bench shows the
pair really does hand back and forth for ever, which is KEGS's behaviour and
not guarded against - but it is not what is happening here.  The DOC is
quiescent while the machine dies.

`dump_doc` in `sim/boot_gs_tb.sv` is the instrument that said so, and it took
two wrong turns to reach it: treating a build that MET TIMING as a suspect
(it met timing; that is the whole of it), and reading "the sim is clean" from
a 3M-instruction run that never got as far as GS/OS starting an oscillator.
A counter at zero is only evidence once the run reaches the code that would
move it.

### Gates

`sim/gs_doc_tb.sv` is **21 checks**: $E0 with nothing interrupting, $E1's
`((val & $3E) >> 1) + 1`, the register round trip and the read delay, the wave
RAM, halt-on-zero with its interrupt, the free-running loop, the swap
handover, and the arrival-ordered queue.  `sim/suite.sh gs` **10/10** with the
KEGS divergence floor UNMOVED at 67,398.  The audio bench caught the wire
format change and was rebased with it (a 32-sample message is 128 words now,
and the stall test's FIFO holds DEPTH/4 samples where it held DEPTH/3).  Host
`card_audio_test` **43/43**, including that a negative DOC channel stays
negative - a path treating the pair as unsigned would put a very loud positive
value there.

## What is NOT working, as of the end of rung 4b

Said plainly, because the first write-up of this rung claimed more than it
had - and then the bank fix (part 5) closed both of the things that were
wrong.  **Nox Archaist boots, plays, and draws its menus cleanly.  Total
Replay v6.1 boots to its title screen** - 519 games, the artwork correct,
waiting for a key - where an hour earlier it "locked up quickly".  Neither
needed a fix of its own; both were the same missing bank byte.  The `In Use/` fence and the host's own log
confirm the image mounted is the one named (`unit 1: Total Replay v6.1, 65535
blocks`), so the failure is the machine's and not the disk's.

Also open:

- **GS/OS 6.0.1 DIES IN THE ROM's MONITOR (2026-09-09), the rung-7 crash.**
  **CHASED TO A DEADLOCK ON THE VBL INTERRUPT, not yet to its cause.**  What
  the bench's new `dump_intc` says at the hang:

        the interrupt controller: irq 1, taken 61; $C041=09 $C023=09 $C046=08;
        pending vbl 1 .25s 0 1s 0 scan 0; adb 0 doc 0

  The VBL interrupt is RAISED AND NEVER CLEARED - `p_vbl` stuck at 1, the
  line into the core stuck high.  `taken` counts RISING edges, so 61 in 7M
  instructions means the handler ran and cleared it sixty-one times and then
  stopped: the line went up a sixty-second time and stayed.  `$C047`'s clear
  path is correct (a read or a write drops `p_vbl` and its INTFLAG bit), so
  nothing is touching $C047 any more.
  Meanwhile the machine spins in a REAL ROM ROUTINE at $FF/C973-C99B, entered
  by an ordinary `JSR` from $FF/764F, which retries by calling ITSELF at
  $C99B (`20 78 C9`) and never returns - so every pass pushes two more bytes
  and the stack walks down out of page one, through page zero and into the
  I/O page.  The `$C02D <= $c9` the log reports is NOT the ROM setting
  SLOTROMSEL: it is a stack push landing on it, the high byte of the return
  address $C99D.  That is what puts BRK/COP traps in impossible banks on the
  screen.
  **The loop polls RAM ONLY** - $24/$25, $21/$22, $2C/$2D, $8C/$8D, $AC/$AD,
  $047B, $021170, no I/O at all - and runs with `P=37`, bit 2 SET, so
  INTERRUPTS ARE MASKED while it waits for a flag only a handler could set.
  Whatever stops the handler running is the bug; the deadlock and the stack
  runaway are both downstream of it.
  **AND THE INTERRUPT DEADLOCK IS DOWNSTREAM, NOT THE CAUSE** - the next
  instrument said so and reversed the reading:

        ...the line last went UP at instruction 6619795 and last came DOWN at
        6597309; $C047 acknowledged 60 times, last at 6597309

  The handler was still running and acknowledging normally at 6,597,309,
  which is 400,000 instructions INTO the runaway.  So interrupts kept being
  serviced while the stack marched, and only stopped once the marching stack
  had destroyed the state the handler needs.  The recursion is the cause; the
  stuck VBL is its consequence.

  **THE LOOP IS ENTERED AT INSTRUCTION 5,415,646**, by an ordinary
  `JSR $C978` from `$FF/CDF4`, reached moments after an `RTI` at `$FF/BF7D` -
  on the way out of an interrupt handler.  It enters with `S=$0141` and
  `Y=$8100`; by the end `Y` is `$C99D`, the return address the runaway has
  been scribbling everywhere.  The routine compares `$24/$25` against `$047B`
  and `$21/$22` and retries, which has the shape of a list or handle walk
  that never reaches its terminator.
  **THE DIVERGENCE IS FOUND, AT INSTRUCTION 618,514**, by set-difference
  against a KEGS trace of THE SAME IMAGE (`s7d1 =` in the config; 20M
  instructions).  Every `(bank, PC)` KEGS visits is a set; the first of ours
  that is not in it is a `SEC`/`RTS` error return at `$FF/4821`, reached by a
  `BMI` at `$FF/480A` that KEGS does not take.  The N flag comes from

        $FF/497E: BIT $C0ED     ; IWM Q6 high
        $FF/4981: LDA $C0EE     ; Q7 low -> the IWM STATUS register

  and the two machines answer it differently, at the same moment in the boot
  (KEGS instruction 618,526, ours 618,511):

        KEGS  $2F / $AF, alternating   bit 7 varies, BIT 5 SET (motor on)
        ours  $8F, always              bit 7 stuck 1, bit 5 clear

  KEGS's sense bit ALTERNATES as the ROM steps the phase lines - it is
  walking the 3.5" status multiplexer - where ours is a constant.
- **FIXED on the way (2026-09-09): $C031's two bits were the wrong way
  round.**  `iwm.h` is explicit - `IWM_BIT_C031_APPLE35SEL` is **6** and
  `IWM_BIT_C031_CTRL` is **7** - and `gs_io` had `apple35_sel` on bit 7 and
  `c031_ctrl` on bit 6.  So whenever the ROM asked for the 3.5" path (it
  writes `$C031 = $40`), `apple35_sel` read low and the status register
  answered from the 5.25" arm, a constant write-protect of 1.  `gs_iwm`'s own
  comment asserted the wrong bit while citing the right constant by name.
  The suite is unmoved by the fix (10/10, floor 67,398) and it does not by
  itself change the boot - because of the next item.
- **STILL OPEN, and the next link**: with the swap fixed, `$FF/4981` still
  reads `$8F`, because our IWM's MOTOR LATCH is 0 where KEGS's is 1.
  KEGS gates the whole multiplexer on `if(state & IWM_STATE_MOTOR_ON)` and
  returns a flat 1 with the motor off - which is exactly the arm we take.  So
  the mux never walks.  This runs into the standing decision recorded in
  `gs_iwm.sv`: bit 5 of the status byte reports NO MOTOR on purpose, so that
  the ROM's motor-wait loops at $FF/4717 and $FF/5B71 fall through.  Note
  KEGS keeps TWO motor bits - `IWM_STATE_MOTOR_ON` gates the mux,
  `IWM_STATE_MOTOR_ON35` is what case $08 reports - and we have one.  That
  distinction is probably the whole of it.

  Past the splash and past the sound driver now, it traps into the monitor
  with BRK and COP in banks $83, $18, $80 and $CF - banks with no RAM behind
  them, where `apple_mmu`'s void page reads `02 40`, which disassembles as
  `COP $40`.  So something is JUMPING into nonexistent memory.  The stack
  pointers in successive traps march down page one ($01C1, $01AB, $017F,
  $0164, $0137, then a wild $3278), which is the shape of an interrupt storm
  eating the stack rather than of a single wild jump.  **NOT the DOC** (ends
  0, irqs 0 - see rung 7) and **NOT the mouse** (the same failure with
  `mouse = off`).  **IT REPRODUCES IN THE BENCH IN ~3 MINUTES**:
  `sim/run_boot_gs_tb.sh --instrs=7000000 --ref=none --hdv=.../system6.hdv`
  ends with the monitor's own register dump on the text screen, the same one
  the panel shows, and the machine spinning in a ROM loop at $FF/C978-C99B
  with bus traffic and cache fills frozen since ~6.2M instructions.
- **GS/OS 6.0.1 REACHES ITS SPLASH AND THE CORE HALTS (2026-09-09).**  Tried
  for the first time this session, from `disks/system6.hdv` on the slot-7
  SmartPort with `gs_os.conf`: the machine draws **"Welcome to the IIgs /
  System 6.0.1"** in SHR, correctly, and then stops with the progress bar
  empty.  IT IS NOT SLOW AND IT IS NOT LOOPING.  Two `accel` samples thirty
  seconds apart are byte-identical in EVERY core-side field - `2327065` fast
  ops, `23212` bus ops, `2892238` wait clocks, `I 1900155`, `RAM 146266`,
  `KBD 6314` - while `cycles` runs on from 18.5M to 55.3M.  The core retired
  nothing at all, and `wait` frozen with it says it is not stalled on a
  memory fill either: it is not asking.  That is the signature of `WAI`,
  which `rtl/cpu65816.sv` implements by parking the microcode on itself
  (`cpu65816.sv:673`) until an interrupt arrives - or of `STP`.
  **THE LEAD, not yet a diagnosis**: `rtl/gs_io.sv:310` wires
  `.irq_scan (1'b0)`, so the VGC's scan-line interrupt CANNOT FIRE, and
  `gs_intc`'s own header names its trigger as the thing not built.  VBL, the
  quarter-second and the one-second ARE implemented and the ADB's interrupt
  IS wired (`irq_adb`), so the scan line is the one an interrupt-driven boot
  could be waiting on for ever.  Proving it wants a trace saying which PC the
  core parked at, which is a rung of its own.  (Stale comment found on the
  way: `gs_adb.sv`'s header still lists "the wiring of irq_data/irq_mouse
  into gs_intc" as missing.  It is not - `gs_io.sv:310` does it.)
- A PHYSICAL Ctrl-Reset does not engage the boot hold, though a programmatic
  one does - both confirmed on the machine, no explanation yet.
- After a swhost restart WITHOUT a fresh bitstream, the card answers no
  register at all - `ring`, `card`, `accel` and the memory readback all come
  back "unknown", and the `ddr=0` the status line shows is a CONSEQUENCE of
  that silence and not a calibration failure.  It cannot be one: `ddr3_rst_n`
  is synchronised from the BOARD's reset pin, not from card_link's `rst`, so
  a host `cmd_reset` never touches the DDR3 controller (card_link.sv:533).
  This is the link failing to resync, and the workaround for now is a fresh
  bitstream before every run.  Not known whether the IIe build is the same;
  the first write-up of this called it a DDR3 fault, which it is not.
- The `GS = 0` build is 1,109 flops and 2,362 LUTs SMALLER than the
  unmodified branch head built the same day, with identical module lists (87
  each) and `master_top.sv` the only differing source.  Parked at the user's
  direction: if something is missing it will show in testing.

## Verification

- `sim/suite.sh gs` is **9/9**: the microcode check, the ADB keymap's
  `--check` and the REVERSE keymap's (which asserts its own totality,
  uniqueness and round trip), `gs_adb` (the micro driven directly, 28
  checks), `gs_kbd_a2` (the IIe's keyboard through the micro from a model
  IOU, 31 checks, all 128 ASCII values), the cycle table, a `cpu816_trace`
  sample, the GS map sweep, and `boot_gs` against the KEGS trace with the
  floor at 67,398 events.  The IIe suites keep their
  counts - the battery is 35/35 on every rung. `tools/check_ports.py` and
  `sim/lint.sh` every rung.
- Host: **40/40 on the Pi**. `gs_memory_test` (the map against a second
  model), `gs_bram_test` (the battery RAM against the ROM's own checksum),
  `adbmap_test` (evdev to ADB keycodes), `gs_stream_test` (`mock_card`
  speaking a GS stream through the real link parser into the mirror),
  `shr_test` for the $E1 source; cross-build via the pi5 preset.
- **The mirror against the machine**: `tools/gs_mirror_test.sh` runs the boot
  bench with `--mirror`, ships the op stream and the written pages to the Pi
  and replays them through `AppleMemory`.  Not in the default suite - the
  stream is tens of megabytes - and the only oracle here taken from a boot
  that actually happened.
- Hardware: `tools/gs_test.sh` in the `*_test.sh` shape (own conf, Apple on,
  wait/idle discipline), asserting on `screen`/`peek` from the mirror; MCP
  `screenshot` for SHR.
- Reference: the KEGS trace for the boot; KEGS on WSL for behaviour questions.

## Risks

- Timing lives in rung 6 (the fronts), which milestone 1 does not depend on.
- Block RAM: 49 RAMB36 free; the 65816 takes 8, the DOC 16, side copies a
  few; ~20 spare. The cache cannot grow; GS working sets will evict.
- The shadow dup doubles seam traffic for shadowed writes; MEASURED at 2.0% of
  ops and 21% of writes on a boot (2026-09-09), most of it one SHR clear.  The
  duplicate is kept rather than aliasing the two address regions to one
  memory: aliasing cannot express `$C035` turning a region off, gets the
  direction wrong (a write to $E0 does not appear at $00), and would put us
  off the KEGS reference that every oracle here is built from.
- The page cache can leave a previous tenant's bytes in lines a page never had
  written (see the status block).  Not a map disagreement; its own rung.
- A 65816 in emulation mode is not the 65C02 cycle for cycle; a real slot
  card in the IIe sees a GS-like CPU, which is what a real GS gives it.
- GS/OS image sourcing is host-side work with KEGS as the installer.
