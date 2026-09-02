# The boot bench: the plan

Status: **not started**. Written 2026-09-01 for a fresh session, at the
close of the session that landed dline rung 1 (39.5x, sim and hardware
agreeing). Branch `dcache`, both repos. First thing in any session:
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
   battery, both simulators for the battery, Verilator for the boot
   (iverilog at ~10x slower is a pre-hardware spot check, not a cycle).

## Session discipline (the standing rules, applied here)

- Explain the change and expectation before every run.
- Monitor by progress counters and extrapolation, never timeout-and-retry:
  the bench prints reads/fast/turbo/dline every 2M clocks (accel_tb's
  pattern); known-good rate ~1.1M clk/s.
- Images live where pi.sh's disks live; the runner takes a path, never
  hardcodes one.
