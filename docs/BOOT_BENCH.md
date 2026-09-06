# The boot bench: the plan

Status: **BUILT AND GREEN, 2026-09-02; a Phasor in slot 4 and a scripted
key since 2026-09-06** (sim/boot_tb.sv,
sim/run_boot_tb.sh, tools/trace_diff.py). All four proof runs pass at 2M
bus cycles under Verilator (~2.5 min each, ~1.4M clk/s): the ProDOS 2.4.3
.po and nox_los.HDV, each at mode 0 and mode 2 unlimited - zero bad
reads, zero monitor mismatches, image == reference every bank, and the
mode-0 vs mode-2 traces architecturally IDENTICAL for the full mode-0
prefix on both images (1.97M / 1.96M ops).  The trace starts at the
first SYNC after the boot reset releases; everything before it (the
core free-running against a half-loaded ROM, the in-reset $0000
cycles) is bench artifact and is excluded by design.  Updates against
the old bench this transliterated: the host model matches the
config-file-era host - a write's block is captured from the reference
through the read map at the EXECUTE (the real host reads its mirror,
src/pipeline.cpp, and never sends HD_FETCH), and HD_DONE bytes land by
bus DMA through the override path so the reference follows the unified
stream with nothing applied by hand.  Not modeled: the event merge and
the host mirror (ev_room tied high, as accel_tb ties it); rung 3's
write-events-at-retire law will want the real merge wired in.
Branch `dcache`, both repos. First thing in any session:
`git status` both repos and commit anything old (the standing rule).

## What it is

A testbench that boots a REAL operating system from a REAL .hdv inside the
simulator: the machine of accel_tb, the real 16K IIe ROM, hd_card in its
slot with the testbench playing the host, reset released, the Autostart ROM
scanning the slots, ProDOS coming up - under whatever acceleration MODE and
TARGET name - with accel_tb's program-order reference memory checking every
byte the core reads and a per-op trace written to a file so two checkouts'
runs diff to the first divergence.

## Why it exists (the record, so nobody relitigates it)

The accel battery proves phases with a DESIGNED program; a boot is millions
of ops of unchoreographed traffic. On the old acceleration branch, BOTH
D$-era bugs - the zp/stack-store map-change race (fw b24fa34) and the
invalidated-line resurrection (fw e4984d5) - passed every directed test and
were caught ONLY by this bench booting real images. Rung 1's own
double-serve race (the fc_q||claim_q gate in rtl/dline.sv) was caught in
code review; no bench flagged it. Review is not a process. The remaining
dline rungs - the CAM's snoops and kills (rung 2), posted writes (rung 3),
stream buffers (rung 4) - are exactly the bug species this bench catches,
so it gets built BEFORE rung 2 goes deep.

## What exists to steal from (reference, not cherry-pick)

The old bench is on the `acceleration` branch and CANNOT be ported - it
instantiates mem_cache-era interfaces that no longer exist - but its
structure is proven and most of it transliterates:

- `git show acceleration:sim/boot_tb.sv` - the architecture: the header
  documents the trace format (two 32-bit words per retired op:
  {clk32} then {flags8, data8, addr16}, flags = rw/sync/commit bits;
  cross-checkout diffs compare addr/rw/data/sync only) and the host model
  (hd registers mirrored off the driver's op stream exactly as the real
  host decodes them, commands answered from the .hdv through the real
  ft601_msg_rx path, HOST_DELAY clocks after EXECUTE, block writes DMA'd
  out through HD_FETCH).
- Since 2026-09-06 the bench also carries `mockingboard` as a Phasor in
  slot 4 (MB_SLOT; `--mb-slot=0` for none), its IRQ into the core, and a
  key it presses once: `--press=ASCII` presses that key when row 4 of the
  text page starts with "SELECT" (PRESS_ROW/PRESS_AT) - mb-audit's menu.
  `sim/run_boot_tb.sh sim/boot_work/mb-audit.po --mode=2 --target=256
  --cycles=9000000 --clks=900000000 --verilator --press=65` runs the audit
  under acceleration at 1x (~14 min); it reproduced the Mockingboard's
  claim bug (docs/MOCKINGBOARD.md, "The claim is one commit's").  The
  reference model does not know an injected key sits in the status page's
  low bits, so `BAD fast read $c01f` lines and a `reads_bad` count are
  expected on such a run.
- `git show acceleration:sim/run_boot_tb.sh` - the runner: takes
  IMAGE.hdv, --mode/--target/--cycles, --verilator, --tag; hex-converts
  the ROM (../strudelworks-host/assets/Apple2e_Enhanced.rom), the slot ROM
  (assets/hdc_smartport.bin) and the image for $readmemh. Drop the old
  chicken-bit flags (--dcache-off etc.) - this lineage has none and the
  user builds without fallbacks by policy.
- `sim/accel_tb.sv` on THIS branch - the DUT wiring to copy verbatim: the
  full current subsystem (cpu65c02 + iline + dline + accel_seq +
  apple_mmu + apple_rom + page_cache + apple_bus_write + boot_hold + the
  machine model), already master_top-shaped. The boot bench is accel_tb's
  machine with the program swapped for the hd boot path and the trace
  writer added.
- The reference-model rule from the old bench, kept exactly: **the
  reference follows all completion data** - it executes using the bytes
  the DUT actually completed with, so a divergence localizes to the FIRST
  wrong op instead of cascading.

## What is genuinely new on this lineage

- hd_card sits in accel_tb at slot 5 as a ROM-only prop today; the boot
  bench needs the real `rtl/hd_card.sv` instantiated and its host half
  modeled (the old bench's host model transliterates; check it against
  src/hd_card.cpp for anything the config-file-era host changed).
- The trace flags byte should carry this lineage's retire taxonomy:
  bus/fast/turbo/dline (and later CAM/stream) - one bit each - so a
  divergence names which serve path produced the wrong byte.
- dline counters at the end of the run: serves/claims/splices printed and
  sanity-checked (a boot that never serves zp is a wiring failure).

## Milestones and proof obligations

1. **Mode 0 control**: the image boots with acceleration off; the trace is
   the baseline. (Wall time is the worst here: ~2M bus cycles = ~196M
   clocks, ~3 min at Verilator's ~1.1M clk/s.)
2. **Mode 2 unlimited**: same image, same milestone, zero reference
   mismatches, and the mode-0 vs mode-2 traces diff clean on
   addr/rw/data/sync per op (acceleration must not change WHAT the
   program does, only when).
3. **Boot-completion detection**: the old bench's milestone check,
   transliterated (a known ProDOS-arrival signature - the check the old
   bench used is in its source; reuse it rather than inventing one).
4. **Two images**: the ProDOS master and nox_los (the second image is
   what found the resurrection bug - one image is not coverage).
5. From then on: **the boot bench runs per dline rung** beside the accel
   battery, both simulators for the battery, Verilator for the boot.
   MEASURED 2026-09-02: Verilator ~1.4M clk/s (a full 2M-cycle boot
   ~2.5 min; the four-run matrix ~10 min in parallel); iverilog ~36k
   clk/s - ~40x slower here, not the battery's ~10x, because the
   bench's tb side (the pin-level machine model, the reference arrays,
   the per-op trace) is all interpreted under vvp.  A full iverilog
   boot would be ~90 min, so the POLICY (user-agreed 2026-09-02) is:
   the boot cycle is Verilator-only; two-simulator RTL coverage comes
   from the accel battery, which runs both simulators per rung; and
   ONE 300k-cycle iverilog boot smoke (~14 min, PASS 2026-09-02) runs
   in the background per rung before a bitstream, costing no attention.

## Session discipline (the standing rules, applied here)

- Explain the change and expectation before every run.
- Monitor by progress counters and extrapolation, never timeout-and-retry:
  the bench prints reads/fast/turbo/dline every 2M clocks (accel_tb's
  pattern); known-good rate ~1.1M clk/s.
- Images live where pi.sh's disks live; the runner takes a path, never
  hardcodes one.
