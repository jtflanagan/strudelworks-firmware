# The dline: 1-clock data

Status: **rung 1 DONE and on hardware** (fw e9170ab: 39.5x, sim and the
user's hardware observation agreeing); **the boot bench BUILT AND GREEN
2026-09-02** (docs/BOOT_BENCH.md: both images, both modes, traces
identical mode 0 vs mode 2). **Next: rung 2.** Branch `dcache`, both repos,
cut from the merged master (page cache + istream front + carry gift, all
hardware-proven). The old acceleration-branch D$ plan (its DCACHE_PLAN.md)
is explicitly NOT the basis for this work: it solved a cache-hierarchy
problem this architecture no longer has.

## The target, and why it is the target

**1-clock data, by the user's decision; fall back only if completely
infeasible.**

Measured on the accel bench (mode 2, unlimited, 32.8x): fast data ops are
8,342 ops at ~9.3 clocks - **59% of ALL clocks**. Turbo ifetch is 27%, bus
ops 13.5%. On this mix, data at 2 clocks is ~62x and at 1 clock ~70x;
past that the 181 bus ops are the wall, and that is soft-switch territory,
out of scope here.

## What the architecture already provides

- **`d_pred` (rtl/cpu65c02.sv, proven)**: the next data cycle's address
  and direction, exported a cycle early BY CONSTRUCTION - the next
  microinstruction's addr_sel is in this cycle's ROM read, and every data
  source it picks is a register whose next-state value this cycle
  computes. Contract-checked over both Klaus suites: 53.6M data cycles,
  ALL named a cycle early but the 3 the $5C NOP's live-AGU cycle owns,
  zero wrong claims. The lead time for the lookup is therefore free.
- **The page cache is authoritative and tagless for main**: there is no
  miss train and no L2 protocol - a "fill" is a read of memory that
  cannot miss.
- **The line-row port already exists**: `il_req/il_aux/il_bank/il_line ->
  il_ack/il_ok/il_row[127:0]` hands back a whole 16-byte line, granted on
  clocks the op path is idle. iline fills through it today; the dline
  arbitrates onto the same port.
- **The iline patterns**: registered-candidate serve that self-guards
  (candidate == actual or no serve), per-entry snoop, flash-clear on map
  change, the turbo_ok/turbo_commit books-and-leash contract.
- The core's `d_din` port and D view exist and are waiting.

## The design

Four parts, smallest serve cone first.

### 1. The zp/stack shadow (rung 1)

512 B LUTRAM: physical MAIN pages 0 and 1, 32 lines x 16 B, one valid FF
per line, claimed lazily (a miss falls back to the dispatcher and starts
the line's row-read; second touch hits). Serve qualifier is two
REGISTERED bits beside the registered `d_pred`: address in $00xx/$01xx,
and the effective zp/stack maps main (ALTZP off).

The property that makes this the best real estate in the design: **the
shadow never invalidates for map reasons.** Its identity is physical main
pages 0/1; ALTZP only DIVERTS traffic to aux, it never changes what main
holds. The only writers besides the core are DMA and the host, and they
are snooped (below). The old locality numbers put zp at ~54% and stack at
~2% of fast data ops - half the data stream served unconditionally at one
clock, with zero CAM pressure.

Aux zp/stack get NOTHING special (user decision): much, much less
important; they ride the dispatcher.

### 2. The CAM (rung 2)

**4 lines** (user decision; grow only on measured evidence), FF tags +
LUTRAM data, iline's shape: tags carry the physical identity (main/aux +
bank), lookup is against the registered `d_pred`, fills ride il_row
grants, per-entry snoop, flash-clear on map change. Serves RAM-class
reads that the shadow does not own. $Cxxx is never here, by class.

One serve the I side never had, free of charge: **`LAST` and `FIXUP`
dummy re-reads always hit** - the dummy re-reads the previous cycle's
address, whose byte is still in the serve register. Every CMOS dummy
cycle is one clock with no storage at all.

### 3. Writes: splice + post (rung 3)

A write retires in one clock by SPLICING into whatever holds the address
(shadow, CAM line, stream buffer) and POSTING to the page cache through a
small FIFO that drains on port-A grants - in the turbo regime the op path
is idle, so drain is ~1/clock and a few entries ride out even a
STA/DEX/BNE loop. The laws:

- **The event is emitted at RETIRE, never at drain** - the host mirror
  sees program order. Write duty is low, which is what keeps per-op write
  events inside the link budget; **1-clock data reads emit NO events**
  (same reason turbo ifetches do not: reads change no host state).
- **Read-after-write: the dispatcher fallback waits for FIFO-empty.**
  A dline miss must not read the page cache past a posted write still in
  flight. Fallbacks are multi-clock already; this costs nothing.
- **Map changes wait for FIFO-empty.** Every map-changing op is a $C0xx
  bus op (~98 clocks); the FIFO is long empty before its data phase, so
  the stall is a one-term guard, not a cost. Stated as a law anyway: the
  old stab's first hardware failure was a mapping-state-vs-in-flight-
  store race.
- **DDR3 write-back stays eventually consistent for free**: a posted
  write landing after a page snapshot re-dirties the page and it flushes
  again.

### 4. Streams (rung 4)

**Stream buffers BESIDE the CAM, not inside it** - poisoning made
structurally impossible rather than policed. One or two line buffers;
sequential fills ride them; a line is promoted into the CAM only on
REUSE (second touch). Detection is a same-line-and-advancing comparator
on the d_pred stream; the prefetch of line+1 rides the same il_row
grants. Whether one buffer or two (a copy loop's src streams; its dst is
writes, which do not fill) is a bench question.

## The laws (carried or new; break none)

1. **The serve verdict is a registered compare against registered
   state.** d_pred is registered at the edge; the whole data cycle
   belongs to the lookup. Never serve in the address's own clock.
2. **The books are never shed.** Every 1-clock retire pays the governor
   and pulses op_tick, through the same contract turbo_commit keeps.
3. **Write events are never dropped, and never reordered** against the
   op stream the host applies.
4. **Everything that mutates the image behind the core's back snoops
   everything that holds bytes**: DMA and host writes hit the shadow, the
   CAM, the stream buffers and the posted FIFO (kill or splice; a kill is
   always safe).
5. **Reset discipline**: control state only; reset never a live gate in a
   serve cone.
6. **Depth audit on every build** (build/depth.sh runs itself now); no
   serve cone chains two arithmetic events - the carry-gift rule,
   design-wide.

## Phasing and proof

Each rung lands only with: the accel battery green under Verilator AND
iverilog, the boot bench green on both images (from rung 2 on), the
predict/cancel contract green, a build whose depth report shows no new
deep tail, and the bench's measured x reported against the 32.8x
baseline.

### Rung 1 - the retire plumbing + the shadow: DONE (fw e9170ab)

39.5x from 32.8x; 4,461 of 8,342 dispatcher data ops at one clock (53% -
the old zp+stack locality number, found again). Three lessons paid for,
each a comment in rtl/dline.sv where it bit: ONE explicit write port per
LUTRAM or the array flop-izes; nothing reads or decides on d_pred's late
cone - register the address and the prediction's validity only, evaluate
everything else THROUGH the serve cycle from registers; and a registered
claim's one-clock lag must be fenced (the fc_q||claim_q retire gate)
against serve_hit rising mid-stall, or a settled dispatcher and a fresh
retire double-serve one cycle. Every rung below inherits all three.

### The boot bench, before rung 2: DONE (2026-09-02)

docs/BOOT_BENCH.md. Rung 1's nastiest bug was caught by review, not by a
bench; rungs 2-4 are snoop/kill/ordering machinery, exactly the species
only a real boot has historically caught. Built and green on both
images, both modes; from here every rung runs it beside the accel
battery (Verilator for the boot; iverilog is a pre-hardware spot check).

### Rung 2 - the 4-line CAM

RAM-class reads outside the shadow's pages. The shape:

- 4 entries (user's number; grow only on measured evidence): FF tags
  carrying PHYSICAL identity - {aux, bank, folded off[15:4]} - one
  LUTRAM for data with the one-write-port discipline, round-robin
  replacement until rung 4 refines insertion.
- **The MMU grows a d-side query port** - the mirror of iline's
  p_addr/p_cls/p_aux/p_off - classifying d_pred combinationally so the
  physical tag registers beside dq_addr at the edge. This is the rung's
  one genuinely new surface, and it is also what rung 3 needs to stamp
  posted writes, so it is built here.
- The lookup joins serve_hit: shadow range serves the shadow, else the
  4-way tag compare. Watch the depth report - the compare adds ~2-3
  levels to serve_hit's cycle-rooted cone, and if it pushes the din-mux
  or retire cones out of the bulk, the rung-1 split applies again
  (register the compare verdict per entry, not the composite).
- Fills ride the rung-1 claim engine, extended with a target select
  (shadow row or CAM entry); arbitration order stays iline > dline.
- Coherence: per-entry snoop of classified writes (splice when the write
  port is free, else kill - a kill is always safe); flash-clear on
  map_changed exactly as iline does (tags are physical, but a fill's
  folding was captured under the map of its day - iline's rule, kept);
  inval clears everything.
- Aux and LC reads come along for free if the classification says RAM -
  measure before special-casing anything (aux zp/stack explicitly get
  nothing, the user's decision).

Expect most of the remaining ~3,900 dispatcher data reads to move;
bench somewhere near 50x.

### Rung 3 - writes: splice + post

A mode-2 data write retires in one clock: splice into whatever holds the
address (shadow, CAM, stream buffer - the write-port arbitration again),
push {physical stamp from the rung-2 query port, data} onto a small
posted FIFO, emit the event AT RETIRE. The laws, now enforced in RTL
rather than prose:

- A write retires ONLY when the event merge has room - write events are
  never dropped, never reordered, so ev_room gates the retire itself
  (reads stay best-effort).
- The retire qualifier excludes anything the classifier diverts
  (RamWorks divert writes are bus reads, never fast) and every $C0xx by
  class; mode 1 keeps writes on the bus by mode.
- The FIFO drains on port-A idle grants in order, dirtying pages through
  the existing write path; classification travels IN the FIFO entry
  (stamped at retire, under the map of that instant), never re-derived
  at drain.
- FIFO-empty terms: the dispatcher's fallback dispatch, every
  map-changing bus op, and the override release (S_HELD's exit) all
  wait for it - the read-after-write, TLB-flush and DMA orderings from
  the design section, each one term.
- Snoops check the FIFO too (or ride the FIFO-empty waits; whichever
  the boot bench proves simpler-correct).

Expect the write population (~10% of ops) to move; the dispatcher is
then bus-ops-only. Bench toward ~60x.

### Rung 4 - streams

One or two line buffers BESIDE the CAM; a same-line-and-advancing
comparator on the d_pred stream detects; prefetch of line+1 rides the
claim engine at lowest priority; a buffer's line enters the CAM only on
SECOND touch, which is what makes poisoning structurally impossible.
Buffers are snooped and killed like every other holder. This rung is
tuned by measurement: counters first (stream hits, prefetches,
promotes), a streaming section added to sim/accel.s, the boot bench as
regression, and one-versus-two buffers decided by the numbers, not by
argument. This is the tail toward the ~70x ceiling, past which the bus
ops are the wall and out of scope.
