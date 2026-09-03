# The dline: 1-clock data

Status: **rungs 1-3 DONE and ON HARDWARE** (2026-09-02).  **Rung 4
(streams) is DEFERRED** by the user's decision: the next work is the
$Cxxx plan (docs/CXXX.md) - what in $C000-$CFFF can be served fast, as one
plan rather than piecemeal - because a trace of wave.dsk's end loop showed
its cycles going to dispatcher-served instruction fetches in the $C3xx
firmware (AUXMOVE), not to the bus.
- Rung 1 (fw e9170ab): the zp/stack shadow, 39.5x, sim and HW agreeing.
- Rung 2 (fw 2e85924): the 4-line CAM + last-byte serve, 45.2x on the
  bench, virtual-tag serve, on HW.
- Rung 3 (fw 00fc407): writes at one clock, splice + post - **68.9x on
  the bench** (from 45.2x), build WNS +0.018; **ON HARDWARE 2026-09-02**
  (fw 8c59006 in SRAM, host 9239498): wave.dsk's main section 80x
  unlimited, its end loop 22x, and a governed 8x reads 8.00 in both.
- **ACCEL_DLINE (fw 8c59006, host cd7bfe7/9239498)**: the "8x configured,
  5.2x shown" the user saw was a MISMEASUREMENT - the dline's one-clock
  ops paid the governor but never reached a register, so the host's
  (turbo + fast + bus) / cycles left out about a third of all ops under
  rung 3.  0x8000_00A8 now exports the dline's retires and the host sums
  them (ratio, HUD, status line `adline=`).  The HUD's rotation wrap had
  to grow with the list.
- **SMC fill-window fix (fw 95a5911), HW-PROVEN**: hunting a long-standing
  HGR corruption / Moon-Patrol-at-accel lockup ([[hgr-corruption-hunt]] in
  memory) turned up a coherence hole in the page cache's shared fill port
  (il_ack), NOT in the dline itself: a store reaches the banks at P+3, the
  front snoops an in-flight fill at P+1, but P+2 was open - a fill reading
  there took the pre-write byte and nothing restarted it, so self-modifying
  code (compiled sprites) fetched stale. il_ack now holds off P+2 for the
  fill's own physical line. Proven on HW at 4x/full-capture with a trace
  coherence oracle: 1877 stale reads at $3CF5 -> 0, user visually clean.
  Rung 3's posted-write path builds on this same fill port, so keep the
  P+2 law in mind. WNS +0.048.
- Boot bench BUILT AND GREEN (docs/BOOT_BENCH.md): both images, both
  modes, traces identical mode 0 vs mode 2. Runs per rung, Verilator.
- New sim coverage in sim/accel.s (fw 95a5911): an interrupt storm over
  the data front (Mockingboard-shaped timer IRQ interposing on every op),
  HGR page-flipping under it, and an SMC-into-a-hot-line sweep. None
  reproduce the P+2 race (cycle-exact prefetch phase, not craftable from
  asm), but they close real coverage gaps; wait_passes timeout raised to
  120M for the heavier program.
- Host: a **BUS CAPTURE** menu row toggles sparse/full read-write capture
  live ([[bus-capture-menu]]) - the tool that made the tracing possible.

**NEXT: the $Cxxx plan (docs/CXXX.md), then rung 4 - streams.** Branch `dcache`, both repos,
cut from the merged master (page cache + istream front + carry gift, all
hardware-proven). The old acceleration-branch D$ plan (its DCACHE_PLAN.md)
is explicitly NOT the basis for this work: it solved a cache-hierarchy
problem this architecture no longer has.

NOTHING PUSHED OR MERGED: the dcache branch holds boot bench (7d97feb),
rung 2 (2e85924), the SMC fix + coverage (95a5911) on firmware, and the
BUS CAPTURE menu (92379e0) on host. Measured accel on the bench: 45.2x
(rung 2); the rung-1/2 ratios are per docs; HW at 4x for the corruption
hunt (the artifact sweet spot), max/unlimited otherwise.

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

### Rung 2 - the 4-line CAM: DONE AND ON HARDWARE (2026-09-02)

**On HW (fw 2e85924 built, ran; the SMC fill-window fix fw 95a5911 rides
on the same bit now proven clean at 4x).** The virtual-tag serve lesson
(below) held; no dline coherence bug surfaced - the corruption chased
this session was the page cache's fill port (il_ack P+2), fixed there,
not in the dline. Original sim result:


45.2x from 39.5x on the bench (56 checks, 0 errors, both simulators,
both sweeps); boot bench green on both images both modes with the
traces identical mode 0 vs mode 2 (CAM live on real boots: ~92k serves
on the nox boot, ~23k on ProDOS; the last byte ~600-1000); predict
contract green; build WNS +0.059 / WHS +0.048.  NOT yet on hardware.

The one lesson this rung paid for: **the serve compares VIRTUAL tags.**
The first build put the MMU classify plus a 21-bit x 4 physical
compare in serve_hit, whose cone ends in cyc_en and therefore in every
candidate register's enable - 16 levels, WNS -0.689.  Because the CAM
flash-clears on every map_changed, one virtual line is one physical
line under an unchanged map and the class it entered with still holds,
so the serve needs a 12-bit virtual compare and nothing else; the
physical tags stay beside it for the snoops (writes arrive physical),
and the fill trigger's classify registers one clock behind a freshness
bit (claims are lazy by design).  The last-byte serve's class guard is
virtual for the same reason: exclude $Cxxx whole, and every map
concern already clears the register.  WATCHPOINT: the serve-byte cone
(dq_addr -> shadow row read / CAM row mux -> d_din) is the WNS path at
+0.059, 14 levels - the next rung must not lean on it.

The shape as planned, and as built:

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

### Rung 3 - writes: splice + post: DONE IN SIM (2026-09-02)

**68.9x from 45.2x on the bench** (mode 2 unlimited, sweep 49): 43,911
writes retired in one clock, 422 clocks of room-wait among them, 6
posted writes drained through the aux miss engine (RamWorks pages not
resident at the drain), every read the reference's byte, image equal to
the reference, the machine's memory stale as it must be.  The accel
battery green under Verilator, both sweeps (63 checks); the boot bench
green on both images in mode 2, traces identical to mode 0 for the whole
mode-0 prefix (1.97M / 1.96M ops), 1.0M / 1.28M writes posted and every
one drained.  iverilog is OUT of the loop by the user's decision
(2026-09-02): it was taking hours per sweep for no finding, and is a tool
for a specific problem now, not a gate.  Build: **WNS +0.018** (WHS
+0.066), LUTs 19,886 / 20,800 (95.6%), BRAM 49/50, depth report's tail
unchanged in shape.  NOT yet on hardware.

**WATCHPOINT, sharpened.** The WNS path is still the serve-byte cone -
now vt_reg (a CAM tag) -> chit -> the CAM byte mux -> d_din -> ... ->
dq_byte / dq_addr, 14 levels at +0.018 - and its far end is
instructive: from d_din it runs through the core's din mux into the
MICROCODE ROM ADDRESS (rtl/cpu65c02.sv, `uaddr_alt = {din, 3'd0}` under
f_sync), through the LUTROM tree (~5 levels) to uc_next, n_asel and
d_pred, and back into dq_addr's D.  An opcode fetch is a PC-sourced
cycle - the I stream, i_din - by construction, so the d_din leg of that
mux can never be the live one on a SYNC cycle: the loop is a
functionally false path that static timing cannot know is false.  The
margin lever, when it is wanted: source the ROM address (and ir /
int_brk) from i_din under f_sync instead of din, which takes the data
front's byte out of the ROM tree entirely.  A core change; proposed,
not made, in this rung.

**MADE, 2026-09-02** (the $Cxxx step 2 work, docs/CXXX.md): three
builds in a row failed on exactly this loop (-0.360, -0.098, -0.071)
after the fast-op census added flops near the fronts - placement noise
against a zero-margin cone - so the lever was pulled: `uaddr_alt`, `ir`
and `int_brk` take i_din under f_sync.  The core suites (Klaus, predict,
cycles, IRQ, 65816 equivalence) are unchanged, as they must be.

As built (rtl/dline.sv, with the seams in rtl/apple_mmu.sv,
rtl/page_cache.sv, rtl/accel_seq.sv, rtl/iline.sv, rtl/event_merge.sv):

- **The retire is VIRTUAL and register-rooted.** A write below $C000 is
  RAM class and lands in the image under every map, so the retire
  qualifier is dq_wv (a registered write prediction), dq_addr[15:14] !=
  11, a registered "bank register is zero" bit, wr_en (turbo_en AND mode
  2, registered in the sequencer), the posted FIFO's room and the
  merge's room.  NO classify cone reaches the retire (the rung-2 lesson,
  applied before it could bite).  LC writes and writes under a non-zero
  RamWorks bank ride the dispatcher as before.
- **A write that cannot retire yet WAITS, it does not miss.** w_serv
  alone claims the dispatcher; the FIFO's and the merge's room gate only
  the retire.  Both free themselves within a few clocks (the drain, the
  merge's pop cadence), so a write never pays the dispatcher's price.
- **The stamp, registered at retire (spl_*):** the MMU query's {aux,
  bank, folded off} for the registered candidate - the map of that
  instant - plus the byte.  Everything after the retire is rooted here.
- **The splice is one clock after retire, from spl_*:** shadow row RMW,
  CAM per-entry write, in-flight claim abort, and the SAME register is a
  second snoop port into iline (ws_*) with its own compare set OR'd
  behind the existing ones (a mux in front would have sat in kill_now's
  cone).  The store into the very next opcode is exactly one clock from
  its fetch, which is why the snoop cannot wait for the drain.  Splicing
  a clock late is ISA-safe (a write is an instruction's last cycle, or a
  push followed by a push or a vector fetch) and CHECKED by a simulation
  assertion in the RTL rather than fenced live: the live fence (a 16-bit
  compare in serve_hit) cost 0.3 ns in the cyc_en cone on the first
  build, WNS -0.275, for logic the ISA makes dead.
- **The post drains through the MMU's classified stage.** The FIFO's
  head (pw_*) is taken into cl_* with cl_posted set on a clock the page
  cache's whole pipeline is clear (pw_ready); the page cache then runs
  its ordinary write path - P2 decision, P3 bank write, the aux miss
  engine when the page is not resident - with `busy` ignoring the posted
  stages (turbo retires continue around the drain) and `decided`
  silent.  One posted write in the pipeline at a time, ~4 clocks each.
  Nothing is re-derived: the stamp is copied, cls forced RAM.  The dline
  ignores the posted write when it comes back round (cl_posted) - it was
  spliced at retire; iline snoops it a second time, harmlessly.
- **`pending` is the one ordering term:** spl_v OR FIFO non-empty OR a
  3-clock shift register after each take (P1..P3).  It gates the
  dispatcher's dispatch (both branches, and disp_pay), S_HELD's entry and
  exit, and EVERY il_ack - the P+2 law generalized to the FIFO's depth,
  as (a) in the plan above.  The grant-clock race (a fill granted on the
  retire clock read the banks pre-write) is closed by the retire+1 snoop
  restarting iline's fill and aborting the dline's claim.
- **The write's event is never dropped:** its retire waits for
  event_merge's fast_room_w, a REGISTERED "room >= 6" registered once
  more in the dline (with the FIFO's room, one slot in hand), whose
  margin covers the three edges between sampling and the word's arrival;
  readers (tev, the dline's reads) now shed at a live "room >= 7", one
  higher, so in a saturated turbo run the room hovers where writes never
  wait.  (HW-confirmed: aovf stays 0.)  The
  accel bench instantiates the real merge as an observer (the producers'
  ev_room stays high so every read is still checked): zero write words
  dropped across 307k, and a phase with the room withheld at random
  proves the wait path.
- **The testbenches take posted writes from the front's event** (they
  never ride the unified stream): the reference update, the PASS/fail
  and IRQ arm/ack hooks all watch both paths.  sim/accel.s grew wrtest
  (a push burst deeper than the FIFO, a fresh line written and read
  straight back, the zero page byte by byte) and the store-into-the-
  next-opcode/operand cases in smctest.

The plan, as written before the build:

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
- **THE FILL-PORT P+2 LAW (learned the hard way this session, fw
  95a5911).** A posted write does not reach the banks the clock it
  retires; there is a pipeline between retire and the bank write, and a
  fill (iline's or the dline's) that reads the banks inside that window
  takes the pre-write byte. The page cache now holds il_ack off the
  write's P+2 for the write's own physical line - but rung 3 lengthens
  the write's life (retire -> FIFO -> drain -> banks), so the window
  widens. The posted FIFO must either (a) make il_ack/il_ok see a line
  with a posted write still in flight as "not yet servable" (block the
  fill until the drain lands, the P+2 law generalized to the FIFO's
  depth), or (b) forward the posted byte into the fill's row. Do NOT
  assume the single-cycle P+2 fix covers a multi-entry FIFO; it does
  not. This is the same hazard as the read-after-write FIFO-empty wait,
  seen from the instruction/fill side.

Expect the write population (~10% of ops) to move; the dispatcher is
then bus-ops-only. Bench toward ~60x.  (Measured: 68.9x.)

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
