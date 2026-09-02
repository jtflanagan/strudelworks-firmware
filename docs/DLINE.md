# The dline: 1-clock data

Status: **design agreed; rung 1 is the next work**. Branch `dcache`, both repos,
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

- **Rung 1**: retire plumbing (d_ok/d_commit beside turbo_ok/
  turbo_commit) + the shadow. Smallest surface that proves the whole
  1-clock contract end to end. Measured on the accel bench; expect a
  large bite out of the 59%.
- **Rung 2**: the 4-line CAM.
- **Rung 3**: the write path.
- **Rung 4**: stream buffers, tuned by measurement.
- **In parallel with rung 1: the boot bench for THIS lineage** - a real
  .hdv booted from reset in simulation. The old boot_tb found both
  D$-era bugs and nothing else did; it is written against dead
  interfaces and gets rebuilt, not ported.

Each rung lands only with: the accel battery green under Verilator AND
iverilog, the predict/cancel contract green, a build whose depth report
shows no new deep tail, and the bench's measured x reported against the
32.8x baseline.
