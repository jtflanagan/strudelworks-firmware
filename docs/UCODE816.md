# A microcoded 65816: what it costs, and what can verify it

**Status: exploration, on branch `ucode_65816`. Not on the development plan.**

This branch exists to answer three questions that had no answers, so that a
decision about a 65816 core can be made against numbers instead of guesses:

1. What verifies a 65816?
2. What does a cycle-accurate one cost in area on the `xc7a35t`?
3. How fast does it run, and what limits it?

Short answers: **SingleStepTests/65816, which checks the bus cycle by cycle**;
**757 LUTs, 181 flops, 8 block RAMs**; and **~122 MHz, limited by the microcode
sequencer loop** - specifically by the block RAM's clock-to-out plus the AGU
carry that the loop's conditions test live.

---

## 1. Verification

There is no Klaus Dormann functional suite for the 65816. His decimal test
covers the part in 8-bit mode and that is the extent of it, so the assembled
self-checking test program that works for the 8-bit cores is not an option here.

What exists instead is
[SingleStepTests/65816](https://github.com/SingleStepTests/65816), and it checks
more than a functional suite can:

- **20,000 tests per opcode** — 10,000 native, 10,000 emulated.
- Full processor and memory state before and after each single instruction.
- A **cycle-by-cycle bus trace** of `[address, value, outputs]`, where `outputs`
  carries VDA, VPA, VPB, RWB, E, M, X and MLB.

That last point is the one that matters for this project. A functional suite
tests results; it never looks at the bus. This suite pins down **which address
is driven on every cycle, dummy cycles included**, which is precisely the
property a CPU-socket accelerator lives or dies by and precisely what an
assembled test program cannot see.

**Practicalities.** 512 files (`NN.n.json` native, `NN.e.json` emulated), 2.9 GB
of JSON, no stated licence — so it is fetched, never vendored, the same
treatment UberDDR3 gets. Each test is one line, so a byte-range request returns
a valid random sample: `sim/fetch_65816_tests.sh` pulls ~256 KB per opcode,
about 130 MB, in under ten seconds. `FULL=1` pulls the lot.

**Caveat worth stating plainly.** The SingleStepTests 8088 and 8086 sets are
hardware-generated. The 65816 set carries **no statement of how it was
produced** — its README documents the format and says nothing about provenance,
licensing, or known-inaccurate corners. Treat it as a very good second opinion,
not as silicon. Where it and the datasheet disagree, that disagreement is a
finding, not a bug to fix silently.

---

## 2. Area

Out-of-context synthesis, `xc7a35tftg256-2`, Vivado 2026.1, post-route, 10 ns
target:

| | cpu65816 | share of part |
|---|---|---|
| Slice LUTs | 757 | 3.6 % |
| Slice registers | 181 | 0.4 % |
| CARRY4 | 38 | — |
| F7 / F8 muxes | 22 / 3 | — |
| Block RAM (RAMB36) | 8 | 16 % |
| DSP | 0 | — |

Reproduce with:

```sh
build/synth_ooc.sh --top cpu65816 --src rtl/cpu65816.sv --period 10.0
```

Note that area is not target-independent: resynthesising against a tighter
target buys speed with LUTs, so quote the target alongside the number. The same
core at an 8 ns target comes out at 821 LUTs rather than 757.

**The logic is cheap; the block RAM is the figure to watch.** 757 LUTs is
nothing on this part. 8 of 50 block RAMs is a real commitment, and it is a
direct consequence of the ROM being addressed by `{opcode, ucycle}` with no
mapping stage — which is what keeps instruction decode out of the critical path
entirely, since there is no decoder in the design at all.

The ROM is 4096 × 68 bits and only 1521 words are used: **63 % is filler.** The
deepest opcode needs 11 slots of the 16 the address allocates. Two levers exist
if 8 BRAMs is ever the problem:

- a 12-slot addressing scheme (11 is the true maximum), saving ~25 %, at the
  cost of a non-power-of-two index;
- a small opcode → base-slot mapping ROM, which shrinks it much further but
  reintroduces a decode stage.

Neither was needed to get these numbers, and per the timing result below,
neither would buy speed.

---

## 3. Speed

Fmax is only derivable from a **missed** constraint — the router stops as soon
as it meets the target, so a met run establishes a floor and nothing more. Both
rows below are 8 ns targets, missed:

| revision | target | achieved | Fmax |
|---|---|---|---|
| with the `ld_if` enable gate | 8.0 ns | 8.675 ns | 115.3 MHz |
| **without it** (current) | 8.0 ns | **8.211 ns** | **121.8 MHz** |

**~122 MHz**, hold comfortable throughout (WHS +0.165 ns). Vivado is
deterministic for identical inputs, so the pair above is a clean A/B on one
change rather than two samples of a noisy process — but note that comparing runs
across *different* revisions of the source is not, and an earlier revision
measuring 8.432 ns is not evidence about either row here.

### What limits it

**Read the top twenty paths, not the worst one.** At a relaxed target the router
stops as soon as it meets timing, so the reported worst path is whatever
happened to be slowest without anyone trying — it is not the binding
constraint. Two successive misreadings of this design came from quoting it.

Pushed to 8 ns, the top twenty paths were all the same shape: microcode ROM
output → **a register clock-enable pin** (`pc_reg[8]/CE`, `adl_reg[*]/CE`,
`x_reg[*]/CE`). The cause was a vestigial `ld_if` field that ANDed `cond_met`
into every register's clock enable so a conditional slot could suppress its own
write-backs. **Nothing in the 65816 needs it** — it existed for BBR/BBS, which
this instruction set does not have, and it was set in 0 of 1521
microinstructions. Vivado cannot see that, because `ld_if` arrives from a block
RAM whose contents it will not constant-fold, so `cond_met` — and the AGU carry
it depends on — sat in the enable path of nearly every flop in the core.

Deleting the field: **8.675 ns → 8.211 ns, 115.3 → 121.8 MHz**, same design
otherwise, for a net reduction in logic.

With that gone the limiter is the **sequencer loop**, and its composition is
worth writing down because it says what to do next:

```
uc_reg/DOADO       2.125 ns   BRAM clock-to-out, 28% of the path, before any logic
  → f_lo_b         0.918 ns   route, fanout 16
  → lo_b 8:1 mux   3 LUT levels
  → CARRY4 x3                 the AGU low adder
  → cond_met → ucyc_next → uc_reg/ADDRARDADDR
Data Path Delay: 7.646 ns (logic 3.568 ns 46.7%, route 4.078 ns 53.3%)
```

So the AGU *is* in the critical path after all — not as arithmetic feeding an
address, but because `COND_CARRY`/`COND_IDX`/`COND_PAGE` test its carry out
*live*, and the next ROM address cannot be formed until that resolves.

Levers, in descending order of what they are worth:

1. **The ROM's optional output register is not being used.** Vivado says so
   directly (`Synth 8-7052`), and it costs 2.125 ns of a 7.6 ns path — 28 %,
   spent before a single LUT. Enabling `DO_REG` would cut it to roughly 0.4 ns.
   The obstacle is that it adds a cycle of read latency, and the opcode-fetch
   address is `{din, 0}` — din only resolves at the *end* of the cycle, so it
   cannot be presented a cycle early. Resolving that (a separate fast path for
   slot 0, or a pipelined sequencer) is the one change that could plausibly
   reach ~150 MHz. Everything else is worth tenths of a nanosecond.
2. **Take the operand mux out from in front of the adder.** The condition waits
   on an 8:1 `lo_b` mux *then* an 8-bit add. Computing the carry for the two
   operands that conditions actually test (X and Y) in parallel and muxing the
   1-bit results afterwards trades two cheap adders for ~3 levels and ~1 ns of
   mux-and-route ahead of the carry chain.
3. **Spend the free ROM bits.** The word is 68 bits and 8 RAMB36 in a
   4096-deep configuration provide 72, so **4 bits are free**. Each can replace
   a decode: `hi_pass` is currently an equality compare on `f_fl`, and
   `op_wide` a comparison of the 5-bit `f_wb` against six constants — both sit
   in the datapath and both could be direct ROM bits.
4. **Fanout and placement.** Route is 53 % of the path. The BRAM's second port
   can read the same address purely as a physically-separate replica of hot
   control bits, which costs no extra block RAM.

Note that shrinking the ROM helps none of this and would hurt, since a mapping
stage lands directly on the loop.

**Caveat for planning.** These are out-of-context numbers. Dropped into a design
that is also placing UberDDR3 and the FT601 datapath, routing gets worse, and
route is already the majority of this path. Treat ~122 MHz as an upper bound on
what integration will show, not a budget.

---

## 4. The datapath, and the one constraint that shaped it

The governing rule for a core like this is that **no microinstruction should
contain an arithmetic path longer than necessary**, because the whole reason to
microcode it is that the instruction set already grants cycles in which to
spread work out. The 65816 grants a great many — but not always the one you
want, and it is worth being precise about where it does not, because that is
what sets the AGU's width:

- **`long,X` decomposes cleanly.** Five cycles flat: cycle 2 reads the address
  high byte and adds `XL` to `ADL`; cycle 3 reads the bank byte and adds
  `XH + carry` to `ADH`. Two 8-bit adds, two cycles, no wide chain needed.
- **`abs,X` decomposes cleanly.** The low add rides the high-byte read; the high
  add is the fixup cycle the ISA grants for a page cross — or, when `x=0`,
  unconditionally.
- **`(dp),Y` does not.** Six cycles with `DL≠0`, and the bus trace shows the
  pointer's high byte being read in the *same* cycle that produces the final
  effective address: `ADL = MDL + YL` and `ADH = din + YH + carry`, together.
  The one cycle the mode grants is already committed to the page-cross fixup.
  `[dp],Y` and `(sr,S),Y` are the same shape, and `[dp],Y` carries on into the
  bank byte as well — a 24-bit chain.

So the AGU is a genuine 16-bit adder with an 8-bit bank incrementer above it.
Per section 3, this turned out to cost area and not speed.

**The ALU stays 8 bits wide, and that is not a compromise.** Every 16-bit
*memory* operation takes two bus cycles because the operand is two bytes, and
the instruction set charges for both — so `ADC #$1234` is two 8-bit adds in the
two cycles it was already going to spend. Only operations that are two cycles
*regardless* of width (`INC A`, `ASL A`, the transfers, the 16-bit half of an
RMW) must move sixteen bits at once, and none of those adds an arbitrary second
operand. They get a shift/increment unit: carry chain and wiring, no operand mux.

### The mode bits do not index the ROM

An instruction's length depends on `m`, `x`, `DL` and `e`. The obvious move —
widening the ROM address with the mode bits — multiplies it by eight, to 64
block RAMs, which does not fit the part at all. Instead every mode-dependent
cycle is a **conditional slot** the sequencer skips. The ROM stays
`{opcode, ucycle}`.

One trap, and it cost the first four wrong sequences: **a condition selects the
successor slot; it does not suppress the microinstruction carrying it.** A cycle
that must be skipped has to be tested by the slot *before* it. This is why the
native-mode PBR push in the interrupt sequence is gated from the operand read
rather than from itself.

---

## 5. What is verified, and what is not

**Verified — cycle structure.** `sim/gen_cycle_table816.py` walks the microcode
sequencer in Python and compares every reachable cycle count against the counts
observed in the suite, bucketed by `(e, m, x, DL≠0)`:

```
checked 1803 (opcode, mode) buckets against the suite, 4 opcodes not fixed-count
every observed cycle count is reachable in the microcode
```

All 252 fixed-length opcodes match, across all sampled mode combinations. The
four excluded are `$44`/`$54` (MVP/MVN, seven cycles *per byte moved*) and
`$CB`/`$DB` (WAI/STP, which park until the environment wakes them) — none has a
fixed count to check.

This runs in about a second with no simulator and no RTL, which is the point: it
catches a mis-sequenced addressing mode before Verilator and long before Vivado.

**Not verified — everything else.** In rough order of effort to close:

- **ALU semantics.** The flag behaviour is a first cut. 16-bit `Z` is
  accumulated across the two passes and `N`/`V`/`C` taken from the high one,
  which is the right shape, but nothing has tested it. Decimal mode, the `BIT`
  variants and the emulation-mode flag corners are all unexercised.
- **Bus addresses.** The suite records them; nothing checks them yet. This is
  the valuable next step and the reason to have picked this suite.
- **MVN/MVP addressing.** Deliberately incomplete. The loop structure and the
  seven-cycle period are right and the count in `A` is decremented so it
  terminates, but a block move reads `{srcbank, X}` and writes `{dstbank, Y}`
  and the bank operand mux has no path from `MD` to express that. Adding one is
  a field, not a redesign — but it changes the mux this exploration is
  measuring, so it was left out rather than half-done.
- **VDA / VPA / VPB / MLB.** Not implemented. A trace-checking testbench wants
  them, since the suite distinguishes an internal cycle from a data read.
- **ABORT**, and the emulation-mode stack-wrapping corners.
- **Interrupt vectors.** Native and emulation vectors are distinguished in the
  RTL but untested.

The honest summary: **a verified skeleton and unverified flesh.** Enough to
trust the area and speed numbers, because those are set by the datapath and the
ROM geometry rather than by whether a flag is right. Nowhere near enough to run
code.

---

## 6. If this were to continue

In the order that retires the most risk per unit of work:

1. **A trace-checking testbench.** Drive the core from a suite test's initial
   state, run one instruction, compare the full bus trace and final register
   state. Highest value by a distance: it verifies addresses, cycle counts and
   results at once, across 20,000 tests per opcode.
2. **Add VDA/VPA/VPB**, without which that testbench has to ignore the
   distinction between an internal cycle and a real access.
3. **Fix what it finds** — expect failures to cluster in the ALU flag corners
   and the emulation-mode stack.
4. **Only then** consider the ROM size, and only if 8 BRAMs is actually a
   problem, since shrinking it does not buy speed.

## Files

```
rtl/cpu65816.sv              the core
rtl/cpu65816_ucode.{vh,hex}  GENERATED by sim/gen_microcode816.py, committed
sim/gen_microcode816.py      the microcode assembler and the opcode table
sim/gen_cycle_table816.py    walks the sequencer, checks it against the suite
sim/fetch_65816_tests.sh     samples SingleStepTests/65816
```
