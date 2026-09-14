# The TX ring: a DDR3 buffer behind the FT601, and one door into it

Status: **✅ on hardware, both tops (2026-08-28).** In `master_top` the soft
core boots Total Replay v6.1 from the hard disk through the boot menu, every
word of it - the splash, the CPU_HOLD notice, 71 HD_DATA blocks, the capture
- crossing the ring; and a host killed mid-stall with 8.6 MB in the ring is
reset by the watchdog one period later, ring cleared. The ring is transparent on the real bus - 154 M events over
150 s, the card's count and the host's equal to the event, zero overflow -
and it does its job under a stall: with the host's reads paused for 4 s the
card's own UART showed the ring climbing at the event rate to 940 K lines
(14.4 MB), the host resumed and drained it in under 400 ms, its poll logged a
peak of 993 042 lines, and the capture never stopped. With reads paused
longer than the ring holds, the card did the loud thing: ring full, `O=1`,
capture stopped, count frozen - the overflow rule, now at 32 MB instead of
16 KB. The decisions the design turned on, and how they went, are at the end.

Everything the card says to the host goes out through one FT601 stream, and
today the only elasticity behind that stream is 16 KB of BRAM. That is enough
for a host that keeps up and not for anything else: a host that stalls for
milliseconds overflows the capture, and an accelerated core dumping 4 B per
cycle at 30x has nowhere to put a burst the link cannot take at that instant
(`DDR3_USAGE.md`, "How CPU acceleration changes all of the above"). This puts a
**32 MB DDR3 ring** — one bank, exclusively — between the card's message
sources and the FT601, keeps the **BRAM FIFO in front of the chip** so the link
never sees the DDR3's own stalls, and puts **one arbiter** in front of the ring
so that every present and future source of messages enters it the same way.

Nothing on the wire changes. The host sees the same framing, the same
heartbeat rule, the same overflow semantics — just several seconds of buffer
where it had four kilobytes.

## The shape

```
  reg_bridge   notice   hd_card   capture   (future: video, sync, …)
      |          |         |         |          streams, a word at a time
   msg_master msg_master msg_master msg_master   -> Wishbone masters, CYC held
      |          |         |         |             across the message
      v          v         v         v
  +---------------------------------------------+
  |  msg_arb      32-bit pipelined Wishbone,     |   "which master has the
  |               a grant per CYC, fixed         |    bus" = whose message
  |               priority by port               |    goes into the ring next
  +---------------------------------------------+
                        | one slave: tx_ring, a beat a word
                        v
  +-------------------+       +-------------------+
  |  ring writer      |       |  ring reader      |
  |  pack 4 words     |       |  BRAM receive     |
  |  -> 16 B line     |       |  4:1 unpack, low  |
  |  BRAM staging     |       |  word first       |
  +-------------------+       +-------------------+
        | WB write batches            ^ WB read batches
        v                             |
  +---------------------------------------------+
  |  wb_arb       one Wishbone port, aux-tagged  |   "which DDR3 client
  |               batched grants, round-robin    |    gets the port"
  +---------------------------------------------+
                        |
                        v
               UberDDR3, bank 7 = the ring (32 MB)
                                      |
                                      v
                     TX async FIFO (BRAM, 4096 x 32, as before)
                                      |
                                      v
                  ft601_msg_tx  ->  ft601_fifo  ->  FT601

  rtl/msg_arb.sv  rtl/msg_master.sv  rtl/tx_ring.sv  rtl/wb_arb.sv  rtl/reply_stream.sv
```

Two arbiters, and it is worth being clear that they are different problems:

- **`msg_arb`** decides *whose message* enters the stream — and it is nothing
  but a Wishbone arbiter. A message is a burst; the master holds CYC from the
  header to its last ack; the bus's own rule that a master is not
  pre-empted while CYC is up *is* message atomicity. The arbiter knows
  nothing about frames. This is the "muxing many writers into the ring".
- **`wb_arb`** decides *which DDR3 client* has the memory port this cycle. The
  ring's writer and reader are its first two clients; the Apple's memory and
  host DMA are the ones `DDR3_USAGE.md` §6 already reserves places for.

## What the ring holds: the wire stream, exactly

The ring stores the **framed 32-bit stream** as it would have gone to the TX
FIFO — headers and payload, in order, four words per 16-byte DDR3 line. Not
raw events. Three reasons:

- The framing already exists. `bus_event_capture` already stores-and-forwards
  whole frames out of its own BRAM; `hd_card` already emits a header and a
  counted payload. The ring is a pipe, not a second framer.
- Order in equals order out, so the stream leaving the ring is well-formed by
  construction, and everything downstream — `ft601_msg_tx`'s boundary
  tracking, the heartbeat rule, the host parser — is untouched.
- It is the only representation every future source shares. A video
  snapshot, a trace sync record and a register reply have nothing in common
  except that each is a message.

There is **no bypass, and no fallback**. Every word goes through the DDR3
even when the ring is empty and the link idle. A dynamic bypass would save
~300 ns against a link whose latency floor is the 100 µs heartbeat, and would
buy an ordering hazard — words in flight to the DDR3 racing words on the
short path — for it. A static one, a build without the ring, was considered
and rejected: the DDR3 is going to carry far more than this, and a board
whose DDR3 will not train is a broken board, not a configuration. What such a
board gets is a diagnostic — `D=0` on the UART status line, and bit 25 clear
in `RING_STATUS` — not a link.

## Lines, and the partial-line problem

The writer only ever writes **whole 16-byte lines** — that is the whole game
per `DDR3_USAGE.md` ("Coalescing is the whole game"): one burst per line, no
byte enables, no read-modify-write, the writer strictly sequential so the row
stays open for 128 lines.

The cost is that a message tail can leave a partial line: a 3-word register
reply, or a 256-word frame that started one word into a line. A partial line
left in the packer never reaches the host, and a reply is exactly the thing
the host is blocked on.

**Pad to the line with IDLE words.** Type `0x00`, `len = 0` — the word
`0x00000000` — is already defined in `PROTOCOL.md` as link filler both
directions, discarded by the receiver, and it is the very word the heartbeat
already inserts. So when the packer has held a partial line for `FLUSH_TICKS`
with nothing new arriving, **and the stream is at a message boundary**, it
appends up to three IDLE words and writes the line. Properties that fall out:

- After any flush the stream is line-aligned, so a 256-word `BUS_EVENTS`
  frame — 64 lines exactly — that follows a flush needs no padding at all.
  At the Apple's event rate that is the common case: frames arrive whole
  every 250 µs with idle between them.
- Padding only happens at a boundary, because inside a message the next word
  is coming by definition (`PROTOCOL.md` case 8), and the flush simply waits.
- Cost on the wire is ≤ 12 bytes per flush, and a flush only happens when the
  link has gone quiet — the same moments the heartbeat already spends 4 bytes.
- Padding never creates a short USB packet on its own; it sits inside the
  chip's buffer like any other block. Dispatch and heartbeat behaviour are
  unchanged.

`FLUSH_TICKS` of ~100 (1 µs) is the right order: it bounds the added latency
of a lone reply at ~2 µs including the DDR3 round trip, against a USB round
trip measured in tens of microseconds.

The alternative — word-granular pointers, byte-enabled partial writes, and
re-writing a line when its remaining words arrive — is correct too, and it is
what to reach for if padding ever becomes measurable. It is not the first
cut: it doubles the pointer logic, needs `wb_sel`, and needs the reader to
know how many words of the last line are real.

## The ring

Bank 7, whole. With `wb_addr = {row[13:0], bank[2:0], col[6:0]}` the ring is
addressed by a **21-bit line index** `p`:

```
wb_addr = { p[20:7], 3'd7, p[6:0] }         2^21 lines x 16 B = 32 MB
```

The writer walks `p` upward, changing row every 128 lines. It never touches
the bank field, so no other client's row is ever evicted by it — except by
the `addr + 5` anticipation leak `DDR3_USAGE.md` describes, which costs a
neighbour one row miss per 128 lines and matters to nobody yet.

Pointers are 22 bits — one wrap bit above the index — so full and empty are
distinguishable. `occupancy = wptr - rptr` in lines. Both pointers and both
clients live in `clk_ctrl`, which *is* the controller clock, so there is no
crossing anywhere in the ring; the only crossing in the path is the TX async
FIFO, where it already was.

**The reader may only read what has been acked.** UberDDR3 issues in order,
but the safe statement is the one that does not depend on that: the writer
counts write acks and publishes `wptr_committed`, and the reader's occupancy
is measured against that. Write acks arrive a few cycles after acceptance; a
line is invisible to the reader for that long and no longer.

**Wrap is free.** The ring's end is a row boundary in bank 7 like any other;
the writer's address arithmetic wraps `p` and nothing else changes.

## The writer

```
words in  ->  4:1 packer  ->  line staging FIFO (BRAM, 256 lines = 4 KB)  ->  WB writes
```

The staging FIFO is what absorbs the DDR3 being busy — a refresh (160 ns), a
reader batch (~1 µs), or, later, an Apple access window the arbiter is holding
for. `DDR3_USAGE.md` sizes it: 4 KB is 366 µs of IIgs full-rate capture,
"1024 consecutive cache misses with no free window, which cannot occur". One
RAMB36.

The writer asks `wb_arb` for the port when it has a **batch** ready — `BATCH`
lines staged (64 = 1 KB, one FT601 buffer) — *or* when the flush timer has
expired with anything at all staged. Given the port, it issues one write per
cycle for the batch and releases. Back pressure to `msg_arb` is the staging
FIFO's `full`; when the ring itself is full (occupancy at its ceiling) the
writer simply stops taking lines, the staging FIFO fills, and the sources see
`full` — which is what they see today when the TX FIFO fills.

## The reader

```
WB reads  ->  receive FIFO (BRAM, 256 lines = 4 KB)  ->  4:1 unpacker  ->  TX async FIFO
```

The mirror of the writer. Read acks land in a line-wide receive FIFO; an
unpacker walks each line **low word first** — the order the packer put them
in — and pushes into the TX async FIFO, which stays exactly what it was:
4096 x 32, so "TX runs deep on purpose" (`card_link.sv`) still holds and the
message layer's dispatch detection is untouched. (An asymmetric 128-in/32-out
XPM FIFO would have saved the unpacker, at the cost of betting the stream on
the primitive's word order; the unpacker is a dozen lines and the FIFO stays
a known quantity.)

The reader asks for the port when the ring has acked data **and** the receive
FIFO has room for a whole batch *counting what is already in flight* — an ack
with nowhere to land would be a lost line. It issues `BATCH` reads back to
back — 64 lines, page hits after the first, one per cycle — and the acks land
~12 cycles later. A 1 KB batch takes ~80 cycles to fetch and 2.56 µs for the
FT601 to drain, so the ring, not the FIFO, is where data waits.

The reader reads **only up to `committed`**, the count of the writer's acks,
and never a partial batch short of it unless that is all there is.

## `wb_arb`: the DDR3 port

Batched grants, round-robin among equals, aux-tagged acks:

| client | now | later |
|---|---|---|
| Apple memory | — | a strict-priority slot **above** the rotation, gated by the free-window predicate, never speculated against |
| refresh | (controller's own) | already above the streams per `DDR3_USAGE.md` |
| ring reader | ✓ port 0 | |
| ring writer | ✓ port 1 | |
| host DMA | — | in the rotation |

A grant is a **batch**, not a cycle: the client holds the port until it has
issued its batch, then lets go for a cycle so the rotation can turn. That is
the direction hysteresis `DDR3_USAGE.md` asks for, without a separate
mechanism: the two ring clients are both in bank 7 but in different rows, so
every switch between them costs a precharge/activate *and* a read↔write
turnaround — ~6 cycles — and at 64-line batches that is under 10 % of a
stream running flat out, and ~0 % at the Apple's rate, where each side wants
the port for 1 µs every 250 µs.

Round-robin rather than reader-first: neither side can starve the other,
which is the property that matters when the reader is catching up at line
rate and the writer's 4 KB of staging is all that stands between a burst of
events and an overflow. The reader is self-throttling anyway — it asks only
with room for a batch, and the FT601 makes that room at 2.56 µs per batch.

Acks are routed by the `wb_aux` tag the request carried, not by "whoever
holds the grant", so a grant can change while acks are still in flight
without any client seeing another's data.

**Requests are never cancelled, and `cyc` is the OR of every client's.**
UberDDR3 aborts every outstanding ack the cycle `i_wb_cyc` goes low, so a
client holds its `cyc` from its first request to its last ack. On the link's
reset a client drops `stb`, keeps `cyc` until its outstanding acks have
returned, and only then resets its pointers — and it does that in a *drain*
state of its own that outlives the reset, so a reset shorter than the acks
in flight cannot leave a late write ack counting into a zeroed ring or a
late read ack dropping a stale line into the receive FIFO (`tx_ring_tb`
proves it with a 3-cycle reset mid-batch). The link's reset lasts 1 ms and a
batch drains in under 1 µs, so in practice the ring is empty long before
reset releases; the drain makes that a convenience rather than a
requirement. The controller itself is **not** reset by the link's reset,
only by the clock-lock reset, because recalibration is not something a
watchdog expiry should cost.

> **Removed 2026-09-14 (user decision).** The refresh gate is gone: the patch, the
> `REFRESH_GATE` parameter, `i_refresh_ok` and every `refresh_ok` producer.  It had been
> off since 2026-09-12 (`REFRESH_GATE = 0`) as a suspect in the IIgs bitstreams that
> met timing and never calibrated - it was not the cause, and could not have been (its
> branch needed `final_calibration_done`) - but dead code in the controller was one more
> thing that could perturb the DDR3 logic, and manual refresh no longer buys anything.
> UberDDR3 is now the pinned upstream commit, unpatched; refresh is its own tREFI timer.


`refresh_ok` is tied low until an Apple client exists. That is upstream
behaviour and is safe (`ddr3_wrapper.sv`).

## `msg_arb`: the message bus

A **32-bit pipelined Wishbone bus** — STB/STALL, the form the DDR3 port and
`wb_regfile` already use — with N masters and one slave, `tx_ring`. A
message is one burst: the master asserts CYC for the header, keeps it
through the last payload word and its ack, and drops it. Wishbone puts no
upper bound on a linear burst, and its rule that the arbiter does not take
the bus from a master while CYC is asserted is exactly "a message is never
torn". The arbiter therefore needs no knowledge of the frame format at all:
it grants per CYC, routes each ack to the master that owned the beat, and
inserts a one-cycle CYC-low bubble between bursts so the slave can tell one
from the next.

**Priority is the port index, fixed**, decided at the grant — the cycle the
bus goes from idle to held. The ordering rule that makes fixed priority safe
rather than a starvation trap:

> Every source above the capture must be **rate-bounded by something outside
> the card** — a host request it is answering, a bus event it is reporting —
> so it can never saturate. The one continuous source, the capture, is last.

That is the old `tx_arb` order — reply, notice, application, capture — kept,
and it stays true of anything on the roadmap: a video snapshot is bounded by
the frame rate, a sync record by the event count. If a second *continuous*
source ever appears, the fix is round-robin among the continuous class below
the bounded one, and the arbiter is the one place to put it. Worst case a
reply waits behind one maximum-size burst: 256 cycles, 2.56 µs.

**`msg_master` is the adapter** for a source that produces a stream rather
than speaking Wishbone: it raises CYC when a word is offered, streams the
message as a write burst, and drops CYC after the last ack. It is the one
place on the master side that reads the protocol, and only to know where its
own message ends. The existing sources — `reply_stream`, the notice,
`hd_card`, `bus_event_capture` — plug in through one each and are otherwise
untouched. A source that speaks Wishbone itself needs none of this, and may
hold CYC across several messages to send them together.

**The guard.** Atomicity now rests on every master holding CYC for its whole
message. Today's all do; the one that someday will not is a bug, and the
slave catches it: `tx_ring` still snoops the length out of each header — it
needs the boundary for padding anyway — and a CYC that drops with payload
still owed sets a sticky **`torn`** bit, `RING_STATUS[26]`, and `T=1` on the
UART line. The stream is wrong from that point regardless; the flag is what
lets the cause be found. `reg_map_tb` still asserts a reply never lands
inside a message; `msg_arb_tb` drives raw Wishbone masters at the arbiter
and checks the contract; `tx_ring_tb` tears a message on purpose and checks
the flag.

## Overflow: unchanged in kind, moved in scale

`PROTOCOL.md`'s overflow rule stands: a full buffer means the host stopped
reading; the card sets the flag, **stops capturing**, and sends `BUS_STATUS`.
The mechanism is untouched — `bus_event_capture` still trips on its own 2048-
event FIFO — but that FIFO now sits behind a 32 MB ring instead of a 16 KB
one. The threshold moves from ~2 ms of host stall to:

| capture rate | 32 MB holds |
|---|--:|
| legacy Apple, 4.1 MB/s | ~8 s |
| IIgs, 11.2 MB/s | ~2.9 s |
| accelerated 30x legacy, ~120 MB/s | ~270 ms |

The last row is the reason the ring exists: at 30x the FT601 (335 MB/s) is
not the bound but a host scheduling hiccup is, and 270 ms is the difference
between "the trace survived the hiccup" and "the trace ended". It is also the
number the host should be able to *see*, which is the one new register:

| addr | name | access | meaning |
|---|---|---|---|
| `0x8000_0024` | RING_STATUS | RO | `[21:0]` occupancy in lines; `[24]` ring full; `[25]` DDR3 calibrated; `[26]` a message was torn on the bus (sticky); the rest reserved |

This is the hook for the throttling idea already noted for accelerated
dumping: the host can slow the core against ring occupancy rather than
discovering the overflow after the fact.

What is **not** changing: a ring that fills stops the capture just as a full
FIFO does now. Head-drop (overwrite oldest) is a different product — "what
led up to now" — and `DDR3_USAGE.md` is right that it must be an explicit
decision with a gap marker the host can see. It is not this change.

## Bringing the DDR3 into the link builds

This is the part that is not a module: the controller had only ever been
built into `au_top`.

- `snoop_top` and `master_top` carry the DDR3 pins through to `card_link`,
  which owns the controller; `build.tcl` adds `ddr3_wrapper.sv` and
  `constr/<board>/ddr3.xdc` to both. `clk_gen` already made the clocks.
- `BIST_MODE` is 0 in the link builds. It was left at 1 in `au_top` "until
  the board is trusted"; 123 million error-free accesses later it is, and a
  memory test at every power-up would hold the link for seconds while the
  host waits for its first reply. Calibration alone is milliseconds.
- The controller's reset is the clock-lock reset, as in `au_top` — never the
  link reset (above).
- Until `calib_complete`, the writer accepts nothing and every source sees
  `full`. At power-up the host is not attached yet, so nothing waits on it.
  A calibration that never completes is a dead link, and the UART status
  line — now `C=… E=x O=x P=x D=x T=x … K=xx` — says so with `D=0` and, since 2026-09-11, where the controller's calibration state machine stands in `K` (UberDDR3's `state_calibrate`; `17` is DONE) — as does
  RING_STATUS bit 25 for a host that can still ask. `T` is the torn-message
  flag.
- **Timing.** `master_top` closes at +0.21 ns and `snoop_top` at +0.15, and
  in both the critical path is `ft_txe` into the FT601 controller in the
  `ft_clk` domain — untouched here. The controller closed at +1.9 ns on its
  own in `au_top`. The risk is congestion rather than a specific path, and
  the order of bring-up below is chosen so it is measured on the smaller
  design first.
- **BRAM:** +1 tile for the staging FIFO. The TX FIFO's 4 tiles are
  reshaped, not added. `snoop_top` uses 7 of 50 today.

## What is proven, and what is not yet

Simulation, all passing:

- `sim/msg_arb_tb.sv` — four raw Wishbone masters issuing random-length
  bursts with random STB gaps, against a randomly stalling slave: every
  message whole and in its master's order, priority honoured at every grant,
  every beat acked to its owner, a CYC-low bubble between every two bursts.
  `reg_map_tb`, `bus_snoop_tb` and `hd_card_tb` — the ones that found the
  boundary bugs on hardware — run through `msg_master` and the bus,
  unchanged in what they assert.
- `sim/tx_ring_tb.sv` — the ring and `wb_arb` against a memory that keeps
  the controller's rules and applies a write only when it acks it. Word-exact
  through many wraps of a 1024-line ring; padding only at boundaries; the
  ring reports full and holds the source off with the sink stopped, then
  drains in order; a reset mid-stream, with cyc held through it, and a clean
  stream after — including a 3-cycle reset that ends with acks still in
  flight; and a master that drops CYC mid-message, flagged torn.
- `sim/tx_ring_ddr3_tb.sv` — the same ring on UberDDR3 and the Micron model.

Hardware, in this order, each step checkable on the last:

1. ✅ **`snoop_top`, synthetic source.** The synthetic generator's 24-bit
   sequence is the only content the host can *verify*, and that is what
   distinguishes a ring that reorders or drops from one that works. The UART
   line must say `D=1 T=0` first. Then the real bus, then a deliberate host
   stall (`swhost` paused) to watch the ring climb and the capture survive
   it: `swhost` polls RING_STATUS four times a second and shows it as
   `ddr N` on its status line, `ring=… ring_peak=… ddr=… torn=…` from
   `swctl status`, and a `ring :` line in its startup and exit summaries.
2. **`master_top`.** ✅ Total Replay boots through the ring; HD_DATA and the
   boot-hold notice have gone through it by then. Timing: `master_top` closed
   at +0.21 ns before the controller joined it, in the `ft_clk` domain this
   change does not touch; the master build will say whether the congestion
   moved it.

The `snoop_top` build with the ring and the controller in it (2026-08-28):
**WNS +0.908 ns** (`ft_clk` +0.908, `clk_ctrl` +1.898), 4450 LUTs (21 %),
4025 registers, **11 of 50 BRAM tiles** (7 before: +1 staging, +1 receive,
+2 the controller's), 137 IOBs — up from 895 LUTs and 7 tiles, which is the
controller, and comfortably inside the part.

## What the hardware taught

- **A stop must drain, or it is a death.** A host that sends `BUS_ENABLE 0`
  and then fails to read what is queued leaves the backlog in the ring for
  the *next* session to sit behind - measured as 1.28 M stale lines ahead
  of a fresh capture, whose first words were the previous session's
  `BUS_STATUS`. The clean stop used to disarm the watchdog at once; now the
  card disarms it **only once the ring is empty**. The stop's own
  acknowledgement is the last thing queued, so a host that reads everything
  disarms it the moment it has, and a host that walks away is reset like a
  host that died - which is what it is, to the card.
- **The host cannot report its own stall.** Its ring poll goes out during
  the stall, but the reply queues behind the backlog and arrives only when
  the host is reading again - correct, and useless for watching it happen.
  The UART line carries `R=xxxxxx`, the ring's occupancy in lines, for
  exactly that reason: it is the observer that is not stalled.
- `swctl pause MS` is the stall on demand: reads stop, heartbeats and the
  ring poll continue. A stop cancels a pause, so a shutdown always drains.

## Decisions, as taken

1. **Padding with IDLE words**, not byte-enabled partial lines. Taken.
2. **No fallback.** A build without the ring was proposed as an A/B control;
   rejected — the DDR3 is the plan, a board that cannot train it is unfit, and
   the fallback is the diagnostic on the UART. `msg_arb` alone was still
   built first, as the migration rung that changes no bitstream behaviour.
3. **Uniform N-port `msg_arb`** replacing `tx_arb`'s three special ports.
   Taken, then taken further: the ports became a **32-bit Wishbone bus** with
   a grant per CYC, so the arbiter is standard and protocol-agnostic and the
   atomicity is the bus's. `msg_master` adapts the stream-shaped sources;
   `tx_ring` keeps the length snoop as a guard.
4. **Overflow stays in the capture**, with RING_STATUS added. Taken, with the
   reason stated plainly: it is a can't-happen, and can't-happens still have
   to be detected so that whatever let them happen can be engineered out.
5. **Batch 64 lines, flush 1 µs**, staging and receive 4 KB each. Taken, all
   parameters of `tx_ring`.
6. **A receive FIFO and an unpacker**, not an asymmetric XPM FIFO — the TX
   FIFO's word order stays something this design controls.
