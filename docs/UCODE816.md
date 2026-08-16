# A microcoded 65816: first stab at the problem space

**Status: exploration, on branch `ucode_65816`. Not on the development plan, and
not expected to be picked up soon.** This document exists so that whoever comes
back to it — probably the person who wrote it, months later — starts from
measurements rather than from scratch.

## The intended use, because it decides everything

This is for the **accelerator**: the core runs with `cyc_en` tied high, one bus
cycle per system clock, against a cache with a hit rate expected to be **well
over 99 %** (that figure is from a previous Apple IIe design; the IIgs number is
unknown). The system clock is **100 MHz**, fixed by the DDR3 controller.

The consequence is that **bus cycles per second is the figure of merit, not
clock frequency**, and the two are the same number only while a microinstruction
takes one clock. A 2.8 MHz IIgs does 2.8 M bus cycles/s; the target is ~100 M/s,
a ~36× multiplier.

Getting this wrong sends you in exactly the wrong direction, and it did during
this investigation — see "the two-clock trap" below.

## The three questions, and the short answers

1. **What verifies a 65816?** SingleStepTests/65816, which checks the bus cycle
   by cycle — strictly more than a functional suite can.
2. **What does one cost?** ~810 LUTs, 181 flops, 8 block RAMs.
3. **How fast, and what limits it?** ~122 MHz out of context. The limit is the
   microcode ROM's 2.1 ns clock-to-out, paid on every path before any logic
   runs, and it did not yield to five successive structural attacks.

---

## 1. Verification

There is no Klaus Dormann functional suite for the 65816. His decimal test
covers the part in 8-bit mode and that is the extent of it, so the assembled
self-checking test program that works for the 8-bit cores is not an option.

What exists instead is
[SingleStepTests/65816](https://github.com/SingleStepTests/65816):

- **20,000 tests per opcode** — 10,000 native, 10,000 emulated.
- Full processor and memory state before and after each single instruction.
- A **cycle-by-cycle bus trace** of `[address, value, outputs]`, where `outputs`
  carries VDA, VPA, VPB, RWB, E, M, X and MLB.

That last point is why it matters here. A functional suite tests results and
never looks at the bus. This suite pins down **which address is driven on every
cycle, dummy cycles included** — the property a CPU-socket design lives or dies
by, and one an assembled test program cannot see.

**Practicalities.** 512 files (`NN.n.json` native, `NN.e.json` emulated), 2.9 GB
of JSON, no stated licence — so it is fetched, never vendored, the same
treatment UberDDR3 gets. Each test is one line, so a byte-range request returns
a valid random sample: `sim/fetch_65816_tests.sh` pulls ~256 KB per opcode,
about 130 MB, in under ten seconds. `FULL=1` pulls the lot.

**Caveat worth stating plainly.** The SingleStepTests 8088 and 8086 sets are
hardware-generated. The 65816 set carries **no statement of how it was
produced** — its README documents the format and says nothing about provenance,
licensing or known-inaccurate corners. Treat it as a very good second opinion,
not as silicon. Where it and the datasheet disagree, that is a finding, not a
bug to fix silently.

---

## 2. Area

Out-of-context, `xc7a35tftg256-2`, Vivado 2026.1, post-route:

| | 10 ns target | 8 ns target |
|---|---|---|
| Slice LUTs | 748 | 814 |
| Slice registers | 181 | 181 |
| CARRY4 | 38 | 38 |
| Block RAM (RAMB36) | 8 | 8 |
| DSP | 0 | 0 |

```sh
build/synth_ooc.sh --top cpu65816 --src rtl/cpu65816.sv --period 10.0
```

Area is not target-independent — a tighter target buys speed with LUTs — so
quote the target with the number.

**The logic is cheap; the block RAM is the figure to watch.** 8 of 50 tiles is a
real commitment, and it follows directly from addressing the ROM as
`{opcode, ucycle}` with no mapping stage, which is what keeps instruction decode
out of the datapath entirely: there is no decoder in this design at all.

The ROM is 4096 × 66 bits and 1521 words are used — **63 % filler**, with the
deepest opcode needing 11 of the 16 slots the address allocates. Two ways to
shrink it if 8 tiles ever matters: a 12-slot scheme (~25 % off, at the cost of a
non-power-of-two index), or a two-level opcode→base map, which would fit the
1521 real entries in 2048 words and about 5 tiles. Neither buys speed, and the
second costs it.

---

## 3. Speed

Fmax is only derivable from a **missed** constraint — the router stops as soon
as it meets the target, so a met run establishes a floor and nothing more.

### Everything that was tried

All at an 8 ns target, default flow unless noted:

| change | achieved | Fmax | Δ |
|---|---|---|---|
| first draft | 8.675 ns | 115.3 | — |
| delete dead `ld_if` field | 8.211 ns | 121.8 | **+6.5** |
| dual-port successor prefetch | 8.193 ns | 122.1 | +0.3 |
| delete dead `ADDR_AGU`, narrow `bk_a` | 8.184 ns | 122.2 | +0.4 |
| ROM output replication | 8.184 ns | 122.2 | 0.0 |
| *(probe)* ROM output pipelined | *6.382 ns* | *156.7* | *+34* |

Each row is measured against the row above it with the same flow, which is the
only way these are comparable — Vivado is deterministic for identical inputs,
but nothing about a run on one revision predicts a run on another.

Only the first entry was worth anything, and it was a **bug**, not an
optimisation: `ld_if` was a field carried over from an instruction set this one
is not (it existed for BBR/BBS, which the 65816 lacks). It ANDed `cond_met` into
every register's clock enable, and it was set in **0 of 1521**
microinstructions — but Vivado cannot constant-fold a field that arrives from a
block RAM, so `cond_met`, and the AGU carry behind it, sat in the enable path of
nearly every flop in the core. All twenty worst paths ended on a CE pin.

Everything after that was a legitimate structural improvement returning a
fraction of a megahertz. That is the result, not a series of failures.

**Implementation effort is not a lever either.** `--effort high`
(PerformanceOptimized synthesis, ExtraTimingOpt placement, AggressiveExplore
phys_opt) measured **+1.2 MHz on one revision and −0.9 MHz on the next**. It is
noise on this design, which is what a balanced design looks like from the
tool's side too. The flag is kept because it costs nothing to have; do not plan
around it, and do not compare a high-effort run against a default one.

### Why nothing else moved it

**2.125 ns of every ~8.2 ns path is block RAM clock-to-out**, paid before a
single LUT, on every path at once. Behind it the design is *balanced*: with the
sequencer loop removed the top twenty paths became a scatter of unrelated
endpoints — `s`, `a`, `x`, `y`, `d`, `dbr`, `bank`, `pc`, `f_z` — all within
0.15 ns of each other. A balanced design does not respond to point fixes; each
one just promotes the next endpoint.

The probe row bounds what removing the ROM latency would be worth: putting a
pipeline register after the ROM lets Vivado use the block RAM's optional output
register and turns every path from `BRAM → logic → FF` into `FF → logic → FF`.
**156.7 MHz, same 8 block RAMs, no area cost.** It is a bound, not a design — a
bare pipeline insert breaks the sequencer, whose next address depends on the
microinstruction currently executing — but it says the ROM latency is worth
**+34 MHz** and everything else is worth ~1.

### Two things learned about the tools

- **Read the top twenty paths, not the worst one.** At a relaxed target the
  router stops as soon as it meets timing, so the reported worst path is
  whatever happened to be slowest without anyone trying. Two wrong readings of
  this design came from quoting it. `build/synth_ooc.tcl` now emits a top-20
  report for exactly this reason: if the twenty are one shape, fixing that shape
  moves Fmax; if they are a scatter, only a structural change helps.
- **Vivado deduplicates identical ROMs.** Two separate attempts to get a second
  physical copy of the microinstruction word — one via the second BRAM port, one
  via two independently-declared arrays — both came back at *exactly* 8.184 ns
  with 8 block RAMs. Getting a real replica needs `dont_touch` or manual
  primitive instantiation.

### The two-clock trap

Worth recording because it was the wrong answer, confidently given.

Since the ROM latency is worth +34 MHz and the obstacle is that `DO_REG` makes
the read two cycles deep, the obvious move is to let a microinstruction take two
clocks: one to fetch, one to execute. That reaches ~157 MHz and dissolves the
lookahead problem entirely, because the spare clock *is* the latency `DO_REG`
costs.

**It fails the requirement.** Two clocks per bus cycle at 157 MHz is 78 M bus
cycles/s, below the ~100 M/s target. It raises the clock ceiling and lowers the
throughput that actually matters. It would be the right answer for a
socket-replacement core, where `cyc_en` is sparse and only setup margin matters;
it is the wrong answer here.

The general form of the mistake: **"Fmax" and "bus cycles per second" are the
same number only at one microinstruction per clock.** Check which one the
requirement is about before optimising either.

---

## 4. The datapath, and the constraint that shaped it

Microcode earns its place by spreading work across the cycles the instruction
set already grants. The 65816 is generous about this, and the interesting
question is exactly where it stops, because that sets the width of the address
adder:

- **`long,X` decomposes cleanly.** Five cycles flat: cycle 2 reads the address
  high byte and adds `XL` to `ADL`; cycle 3 reads the bank byte and adds
  `XH + carry` to `ADH`. Two 8-bit adds, two cycles.
- **`abs,X` decomposes cleanly.** The low add rides the high-byte read; the high
  add is the fixup cycle the ISA grants for a page cross — or, when `x=0`,
  unconditionally.
- **`(dp),Y` does not.** Six cycles with `DL≠0`, and the bus trace shows the
  pointer's high byte being read in the *same* cycle that produces the final
  effective address: `ADL = MDL + YL` and `ADH = din + YH + carry`, together.
  The one cycle it grants is already spent on the page-cross fixup. `[dp],Y` and
  `(sr,S),Y` are the same shape, and `[dp],Y` carries on into the bank byte —
  a 24-bit chain.

So the AGU is a genuine 16-bit adder with an 8-bit bank incrementer above it.
Per section 3 this cost area and not speed, which was the opposite of the
expectation going in.

**The ALU stays 8 bits wide, and that is not a compromise.** Every 16-bit
*memory* operation already takes two bus cycles because the operand is two
bytes, and the instruction set charges for both — so `ADC #$1234` is two 8-bit
adds in the two cycles it was going to spend anyway. Only operations that are
two cycles *regardless* of width (`INC A`, `ASL A`, the transfers, the 16-bit
half of an RMW) must move sixteen bits at once, and none of those adds an
arbitrary second operand. They get a shift/increment unit: carry chain and
wiring, no operand mux.

### The mode bits do not index the ROM

Instruction length depends on `m`, `x`, `DL` and `e`. Widening the ROM address
with them multiplies it by eight — 64 block RAMs, which does not fit the part.
Instead every mode-dependent cycle is a **conditional slot** the sequencer
skips.

One trap, and it cost the first four wrong sequences: **a condition selects the
successor slot; it does not suppress the microinstruction carrying it.** A cycle
that must be skipped is tested by the slot *before* it.

### What the field audit found

Auditing every symbolic field against the 1521 emitted microinstructions turned
up dead encodings worth removing — and one worth knowing about:

- `addr_sel` never selects `AGU`, `DP` or `AGUSP`. **The live AGU result never
  reaches the address pins**, so the adder is not in the address bus's cone at
  all. Keep it that way.
- `bk_a` never selects `DBR`/`PBR`/`ZERO` — 3 bits became 1.
- `cond` never selects `CARRY`, `PAGE` or `EMU`, and **only 33 of 1521
  microinstructions use a live AGU carry at all** (`IDX` 24, `EPAGE` 9). The
  other 98 % evaluate on registered state. That number is the key to the
  pipelined-sequencer option below.
- Heavy skew everywhere: `lo_a` is `ADL` 91 % of the time, `alu_a` is `DIN`
  94 %, `dout` is `AL` 90 %. Skew does not help timing — static analysis takes
  the worst path through a mux regardless of how often it is used — but it does
  say where a narrower encoding would cost nothing.

---

## 5. Verified, and not

**Verified — cycle structure.** `sim/gen_cycle_table816.py` walks the microcode
sequencer in Python and compares every reachable cycle count against the counts
observed in the suite, bucketed by `(e, m, x, DL≠0)`:

```
checked 1803 (opcode, mode) buckets against the suite, 4 opcodes not fixed-count
every observed cycle count is reachable in the microcode
```

All 252 fixed-length opcodes match across every sampled mode combination. The
four excluded are `$44`/`$54` (MVP/MVN, seven cycles *per byte moved*) and
`$CB`/`$DB` (WAI/STP, which park until the environment wakes them). It runs in
about a second with no simulator and no RTL, which is the point: it catches a
mis-sequenced addressing mode before Verilator and long before Vivado.

**Not verified — everything else.**

- **ALU semantics.** The flag behaviour is a first cut. 16-bit `Z` is
  accumulated across the two passes and `N`/`V`/`C` taken from the high one,
  which is the right shape, but nothing has tested it. Decimal mode, the `BIT`
  variants and the emulation-mode flag corners are all unexercised.
- **Bus addresses.** The suite records them; nothing checks them yet.
- **MVN/MVP addressing.** Deliberately incomplete. The loop structure and the
  seven-cycle period are right and `A` is decremented so it terminates, but a
  block move reads `{srcbank, X}` and writes `{dstbank, Y}` and the bank operand
  mux has no path from `MD` to express that. A field, not a redesign — left out
  rather than half-done because it would change the mux being measured.
- **VDA / VPA / VPB / MLB**, **ABORT**, emulation-mode stack wrapping,
  interrupt vectors.

**A verified skeleton with unverified flesh.** Enough to trust area and speed,
because those follow from the datapath and the ROM geometry. Nowhere near
enough to run code.

---

## 6. If this gets picked up again

In the order that answers the most per unit of work.

**First, size the real problem.** Every number here is out of context. The
OOC→integrated gap is mostly congestion and placement rather than logic, and a
pblock keeping the CPU with its 8 block RAMs, away from the DDR3 datapath,
preserves most of it. That costs no design change and it determines whether any
of the rest is needed. Do this before spending anything.

**Then, if more speed is genuinely required**, three options that are not
variations on each other:

1. **Incremental: ~135–140 MHz for roughly +1000 LUTs.** Move the AGU
   operand-select bits (`lo_a`, `lo_b`, `hi_a`, `hi_b`, `hi_c` — 15 bits) out of
   block RAM into distributed RAM, which reads from a registered address in
   ~1.0 ns against the block RAM's 2.125. Keeps one bus cycle per clock, adds no
   hazards, roughly doubles LUT count.
2. **Structural: ~150 MHz+.** A pipelined microsequencer that fetches the
   microinstruction a cycle ahead so it sits in a fabric flop rather than
   emerging from a block RAM. The blocker is knowing the next condition early,
   and the field audit says that is tractable: only 33 of 1521 microinstructions
   use a live AGU carry. Carry the successor's `cond`/`alt` in each
   microinstruction (+8 bits) and evaluate one step ahead, with those 33 handled
   specially. Real redesign, real hazards, but grounded rather than speculative.
3. **Different axis entirely: drop cycle-accuracy on the cached path.** This
   core spends the 65816's published cycle counts, and on a 99 % cache hit it
   does not have to — nothing is watching the bus. Cycle-accuracy is needed when
   the access is visible to the machine (I/O, video, anything timing-coupled).
   A dual-mode microcode — compressed on the cached path, accurate when the
   access goes to the real bus — plausibly moves the average from ~3.5
   cycles/instruction to ~2. That is **~1.75× effective speed at the same
   clock**, worth more than every Fmax option above combined, and a much larger
   change. It also splits the verification story: the accurate mode against the
   suite, the fast mode against results only.

**And regardless of which**, the highest-value verification step is a
**trace-checking testbench**: drive the core from a suite test's initial state,
run one instruction, compare the full bus trace and final register state. It
verifies addresses, cycle counts and results at once across 20,000 tests per
opcode. It wants VDA/VPA/VPB added first, so the testbench can tell an internal
cycle from a real access.

## Files

```
rtl/cpu65816.sv              the core
rtl/cpu65816_ucode.{vh,hex}  GENERATED by sim/gen_microcode816.py, committed
sim/gen_microcode816.py      the microcode assembler and the opcode table
sim/gen_cycle_table816.py    walks the sequencer, checks it against the suite
sim/fetch_65816_tests.sh     samples SingleStepTests/65816
build/synth_ooc.sh           --effort high, and a top-20 path report
```

Reconstructing the measurements: every row in the section 3 table is a commit on
this branch, and the two probe variants (pipelined ROM output, forced ROM
duplication) are described in section 3 but were not committed — they are
five-line edits to `rtl/cpu65816.sv`.
