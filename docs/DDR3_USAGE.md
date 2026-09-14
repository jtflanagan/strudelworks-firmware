# Using the UberDDR3 interface efficiently

`DERISK.md` answers one question — *is a random read fast enough for the Apple II
bus?* — and answers it well. This document answers the next one: **now that the
DDR3 has to serve more than one client, what does the hardware actually charge
for, and how should the design be shaped around it?**

Everything numeric here is for *this* configuration (2 Gb x16 MT41K128M16,
100 MHz controller / 400 MHz DDR3 = DDR3-800, 4:1, `SPEED_BIN 3`), taken from
`sim/run_params_dump.sh` and from reading `third_party/UberDDR3/rtl/`.

---

## 1. What a DDR3 device actually is

DDR3 is not random-access memory in the sense the name suggests. It is **8
independent banks**, each of which is a 2-D array with **exactly one row buffer**.

For this part: `ROW_BITS 14`, `COL_BITS 10`, `BA_BITS 3`.

```
one row  = 2^10 columns x 16 bits          = 2 KB
one bank = 2^14 rows x 2 KB                = 32 MB
device   = 8 banks                         = 256 MB
```

Each bank is a three-state machine, and the state is *per bank*:

```
        ACTIVATE(row R)              PRECHARGE
  idle ------------------> active(R) -----------> idle
                            |    ^
                            |    |  READ / WRITE (any column of R)
                            +----+
```

The row buffer is the only thing the DQ pins can reach. So:

- To touch any byte, the whole 2 KB row containing it must first be copied into
  that bank's sense amps (**ACTIVATE**). This is destructive to the array.
- Once open, any column of that row is cheap (**READ** / **WRITE**).
- To touch a *different* row of the *same* bank, the open row must be written
  back and the sense amps cleared (**PRECHARGE**) before the next ACTIVATE.
- Different banks are fully independent. **8 rows — 16 KB — can be open at
  once**, and that is a resource this design should be allocating deliberately.

The **command/address bus is shared** by all 8 banks (one command per DDR3
clock), and so is the **DQ bus** (one burst at a time). Bank parallelism buys you
overlapped *row management*, never overlapped *data*.

### The burst is 8, and that is not negotiable

`BL8`, fixed: every READ or WRITE moves 8 beats x 16 bits = **128 bits =
16 bytes**. There is no shorter access. This is why the Wishbone port is 128 bits
wide with a 24-bit address — the Wishbone word *is* the DDR3 burst, and
`wb_addr` is a burst index, not a byte address.

`i_wb_sel` is 16 bits, one per byte, and drives the DM pins. **So a partial write
is free — no read-modify-write.** That is worth knowing explicitly, because RMW
is the usual DDR3 tax and this design does not pay it.

### The timing constraints, and what each one is protecting

| Constraint | Value here | What it protects |
|---|--:|---|
| `tRCD` | 13.75 ns | ACT → RD/WR. Sense amps must settle before the data is readable. |
| `tRP` | 13.75 ns | PRE → ACT. Write-back and precharge of the array. |
| `tRAS` | 35 ns | ACT → PRE. A row must stay open long enough to be restored. |
| `tRC` = tRAS+tRP | 48.75 ns | Full row cycle in one bank. The real cost of thrashing a bank. |
| `tRRD` | 7.5 ns | ACT → ACT, different banks. Limits current draw from charge pumps. |
| `tFAW` | 50 ns | No more than **4** ACTs in any rolling window. Same reason. |
| `tCCD` | 4 nCK = 10 ns | RD → RD. The burst occupies the DQ bus for 4 clocks. |
| `tWTR` | 7.5 ns | Internal write → read turnaround. |
| `tRFC` | 160 ns | REFRESH occupancy. All banks must be precharged first. |
| `tREFI` | 7.8 µs | Average refresh interval. |

`tCCD = 4 nCK` is the one that sets the ceiling: a BL8 burst takes 4 DDR3 clocks
on the DQ bus, so a new READ can issue every 4 clocks and not sooner. At 4:1
that is **exactly one controller clock**, which is why the Wishbone port can
accept one 128-bit word per cycle and why that equals 100 % of the device's
theoretical bandwidth. Nothing is left on the table by the controller's width.

---

## 2. UberDDR3's central trick: static command slots

Each controller clock (10 ns) is serialised into **4 DDR3 command slots** (2.5 ns
each). UberDDR3 assigns one command *type* to each slot, permanently:

```
controller cycle N            controller cycle N+1
+------+------+------+------+ +------+------+------+------+
| ACT  | PRE  | RD   | WR   | | ACT  | PRE  | RD   | WR   |
| nCK0 | nCK1 | nCK2 | nCK3 | | nCK4 | nCK5 | nCK6 | nCK7 |
+------+------+------+------+ +------+------+------+------+
   slot0  slot1  slot2  slot3
```

(`ACTIVATE_SLOT 0`, `PRECHARGE_SLOT 1`, `READ_SLOT 2`, `WRITE_SLOT 3` — confirmed
by the params dump.)

Two consequences, and they explain the whole latency result in `DERISK.md`:

**(a) Four different commands can be issued in one controller cycle.** An
ACTIVATE of bank 3, a PRECHARGE of bank 5, a READ of bank 1 and a WRITE of bank 6
can all go out in the same 10 ns. What you *cannot* do is two of the same type —
one ACTIVATE per controller cycle, ever.

**(b) The inter-command delays are measured slot-to-slot, so they mostly vanish.**
`find_delay(delay_nCK, start_slot, end_slot)` returns the number of *extra*
controller cycles needed, given that consecutive cycles already put the slots
`(4 - start_slot) + end_slot` clocks apart:

| Path | Needs | Natural slot distance | Extra cycles |
|---|--:|--:|--:|
| ACT → RD (`tRCD`) | 6 nCK | (4−0)+2 = **6 nCK** | **0** |
| ACT → WR (`tRCD`) | 6 nCK | (4−0)+3 = **7 nCK** | **0** |
| PRE → ACT (`tRP`) | 6 nCK | (4−1)+0 = 3 nCK | **1** |
| ACT → ACT (`tRRD`) | 3 nCK | (4−0)+0 = **4 nCK** | **0** |

**This is why a row miss costs 2 controller cycles instead of 10.** `tRCD` is
absorbed entirely — the READ slot sits 6 clocks after the ACTIVATE slot of the
previous cycle, which is exactly `tRCD`. The slot layout was chosen so that the
pipeline's own natural spacing pays for the DRAM's timing. It is a genuinely
elegant piece of design and it is the reason this controller suits this project.

The measured "random read = 12 cycles, page hit = 10 cycles" falls straight out:

```
page hit:   RD at cycle N                                    -> ack at N+~10
row miss:   PRE at cycle N, ACT at N+2, RD at N+3            -> ack at N+~12
```

---

## 3. The request pipeline, and what it does and does not know

Two stages, plus a read-return pipe.

```
  i_wb_stb ->  [ stage1 ]  ->  [ stage2 ]  ->  cmd slots -> PHY -> DRAM
               row mgmt        RD/WR issue                          |
               PRE / ACT                                            v
                                          o_wb_ack <- shift_reg_read_pipe (6 deep)
                                          o_aux    <-
```

- **`stage1`** owns PRECHARGE and ACTIVATE. It handles row management for the
  current request, *or*, when the current address is near the end of a row,
  for the anticipated next one.
- **`stage2`** owns READ and WRITE. It stalls until the bank it needs is open on
  the right row and the relevant delay counter has expired.
- **`shift_reg_read_pipe`** is `READ_ACK_PIPE_WIDTH = 6` deep. Read data comes
  back through a **single in-order shift register**, with `o_aux` alongside.

### Open-page policy, tracked per bank

```verilog
reg [7:0]           bank_status_q;        // 1 = active
reg [ROW_BITS-1:0]  bank_active_row_q[7:0];
```

Rows are **left open** after an access. A row is only closed when something needs
a *different* row in that same bank. So 8 rows stay open across 8 banks, and any
access landing on one of them is a page hit. **Which 8 rows those are is decided
entirely by your address map and your access order** — that is the lever.

### Anticipation is sequential-only, 5 bursts ahead

```verilog
localparam MARGIN_BEFORE_ANTICIPATE =
      PRECHARGE_TO_ACTIVATE_DELAY   // 1
    + ACTIVATE_TO_WRITE_DELAY       // 0
    + WRITE_TO_PRECHARGE_DELAY;     // 4   => 5

assign wb_addr_plus_anticipate = i_wb_addr + MARGIN_BEFORE_ANTICIPATE;
```

`stage1` computes the bank and row of **`current address + 5`**. If that differs
from the current bank/row, it starts precharging and activating *that* bank now —
50 ns before the request arrives, which fully covers `tRP + tRCD`.

Understand what this is and is not:

- It is **not** a queue lookahead. The controller has no idea what your *actual*
  next request is. It assumes `addr + 5`.
- Therefore it **only helps strictly sequential access**, where the guess is
  right. Sequential streaming crosses bank boundaries with zero stall.
- For random access the guess is wrong, and you get nothing — but you also lose
  nothing, because a miss is only 2 cycles.

### The address map, and the geometry it creates

Default `row_bank_col = 1`, i.e. `{row, bank, col}`:

```
wb_addr[23:10] = row   (14 bits)
wb_addr[ 9: 7] = bank  (3 bits)
wb_addr[ 6: 0] = col[9:3]  (7 bits = 128 bursts = 2 KB)
```

So the linear address space is striped:

```
byte 0x00000 .. 0x007FF   bank 0, row 0      2 KB
byte 0x00800 .. 0x00FFF   bank 1, row 0
    ...                   ...
byte 0x03800 .. 0x03FFF   bank 7, row 0
byte 0x04000 .. 0x047FF   bank 0, row 1      <- 16 KB stride returns to bank 0
```

**A linear sweep changes bank every 2 KB and row every 16 KB**, and the
anticipation logic hides both. This is the mapping you want for streaming, and
it is already the default.

---

## 4. The three costs that actually matter for multi-client use

`DERISK.md` established that access *order* does not matter for latency (bank
interleaving measured identically to sequential). That conclusion is correct and
still holds — **for one client doing one access at a time**. Once there are
several clients and pipelined traffic, three new costs appear that the
single-outstanding latency testbench cannot see.

### Cost 1 — Read/write turnaround, and it is global

```
READ_TO_WRITE_DELAY  = 1   (code adds 1 -> 2 cycles)
WRITE_TO_READ_DELAY  = 3   (code adds 1 -> 4 cycles)
READ_TO_READ_DELAY   = 0
WRITE_TO_WRITE_DELAY = 0
```

And critically, from `ddr3_controller.v` — these are applied to **every bank**,
not just the one being accessed, because they are ODT settling constraints:

```verilog
//the write to read delay applies to all banks (odt must be turned off properly before reading)
for(index=0; index < (1<<(BA_BITS+DUAL_RANK_DIMM)); index=index+1) begin
    delay_before_read_counter_d[index] = WRITE_TO_READ_DELAY + 'd1;
end
```

You cannot escape a turnaround by using a different bank. Consequences:

| Pattern | Cycles per 2 accesses | Effective bandwidth |
|---|--:|--:|
| R R R R … (same direction) | 2 | **1.6 GB/s** |
| W W W W … (same direction) | 2 | **1.6 GB/s** |
| R W R W … (alternating) | ~8 | **~400 MB/s** |

**Batching by direction is the single largest throughput lever in this design,
and it is worth more than any address-map cleverness.**

It is also a *latency* problem, and this is the part that matters most:

> **A write in flight delays the next read by 4 controller cycles = 40 ns.**

The IIgs budget in `DERISK.md` is a 180 ns window with ~60 ns of slack after a
120 ns random read. **A single event-log write issued just before an Apple II
read consumes two thirds of that slack.** This is the same class of problem as
the refresh collision, it is not covered by the refresh gate, and a naive
"arbiter that lets the trace writer in whenever the bus is quiet" design will hit
it constantly.

The fix has the same shape as the refresh fix: the trace writer must only be
granted in windows where the *upcoming* Apple cycle is known not to need DDR3,
with enough margin for the turnaround — i.e. gate it on the same predicate that
drives `i_refresh_ok`, not on "the DDR3 is idle right now".

### Cost 2 — Bank conflicts between clients, and the direction of the harm

Eight open rows are a shared, unmanaged resource. Any client's access to bank B
evicts whatever row another client had open in bank B.

The instinct is to protect the Apple II from the streaming clients. **That is
backwards.** From the measured data, the Apple II's own access pattern is random
over its whole region, so it already takes a row miss on ~83 % of accesses
(RANDOM: 413 of 500 at 12 cycles). It is already paying the miss; another
client's eviction costs it approximately nothing.

The streaming clients are the fragile ones. A trace writer walking linearly
through a region relies on its row staying open — that is what turns 16 bytes per
10 ns into reality. If Apple II accesses keep evicting it, **every burst becomes
a row miss and the writer's throughput drops by ~3x**.

So: **partition banks to protect the sequential clients from the random client.**

The map makes this easy, because `wb_addr[9:7]` *is* the bank. Reserving a bank
means constraining three address bits:

```
trace log owns bank 7:   wb_addr = {row[13:0], 3'd7, col[6:0]}
```

That client then owns 2^14 x 128 x 16 B = **32 MB**, laid out as 2 KB out of
every 16 KB of the linear space — which is invisible to it, because it addresses
its region by incrementing `col` and then `row`, never touching the bank field.
Its row stays open for 128 consecutive bursts (2 KB) regardless of what anyone
else is doing.

#### …but the partition leaks, by about 2 %

The anticipation logic computes `{next_row, next_bank} = (i_wb_addr + 5) >> 7`
and will speculatively PRECHARGE `next_bank` if it holds a different row —
**even though no access to that bank ever happens**. When a client's address is
within 5 bursts of the end of a 128-burst column range, `addr + 5` rolls into
the *next bank number*, and the speculation escapes the partition. A client
confined to banks 0–5 by address construction can still evict bank 6's open row.

It is infrequent: only the last 5 of every 128 bursts, i.e. the tail of the last
page of each row. The victim pays one extra row miss (2 cycles) and carries on,
which is well under 2 % of its throughput.

So bank partitioning is **a strong statistical improvement, not isolation**.
Worth doing — it removes the common-case eviction — but do not build anything
that requires an open row to be guaranteed.

A reasonable starting allocation:

| Banks | Client | Size | Pattern |
|---|---|--:|---|
| 0–5 | Apple II extended memory | 192 MB | random, latency-critical |
| 6 | Host DMA / bulk staging | 32 MB | sequential, throughput |
| 7 | Bus event trace ring | 32 MB | sequential write, throughput |

The Apple II loses nothing by being confined to 6 banks — it needs at most 8–16 MB
and it is taking row misses either way.

### Cost 3 — Refresh, already solved, with one thing to re-check

> **Removed 2026-09-14 (user decision).** The refresh gate is gone: the patch, the
> `REFRESH_GATE` parameter, `i_refresh_ok` and every `refresh_ok` producer.  It had been
> off since 2026-09-12 (`REFRESH_GATE = 0`) as a suspect in the IIgs bitstreams that
> met timing and never calibrated - it was not the cause, and could not have been (its
> branch needed `final_calibration_done`) - but dead code in the controller was one more
> thing that could perturb the DDR3 logic, and manual refresh no longer buys anything.
> UberDDR3 is now the pinned upstream commit, unpatched; refresh is its own tREFI timer.


`tRFC 160 ns` per `tREFI 7.8 µs` = **2.05 %** of bandwidth nominally, **~4.1 %**
with `REFRESH_GATE` pulling refreshes in at up to twice the nominal rate. That is
a good trade and the reasoning in `DERISK.md` stands.

The one thing to re-examine: the refresh gate assumes free windows are declared
by the Apple bus logic. Once streaming clients exist, **a window that is free of
Apple II traffic is not free of DDR3 traffic**, and `i_refresh_ok` will be
asserting while the trace writer is mid-burst. The gate cuts the `tREFI`
countdown short, and the controller then drains pending requests
(`PRE_REFRESH_DELAY`) before refreshing — so this is a throughput hiccup for the
streaming client, not a correctness problem. But `i_refresh_ok` should probably
become "no Apple access upcoming **and** no streaming burst in flight", so that
refreshes land in genuinely idle cycles rather than chopping up bursts.

---

## 5. The budget, which is the reassuring part

Peak: 128 bits / 10 ns = **1.6 GB/s**, and that is 100 % of what a x16 DDR3-800
device can do (16 bits x 800 MT/s). Realistic sustained sequential, after
refresh: **~1.5 GB/s**.

What the clients actually want:

| Client | Demand | Notes |
|---|--:|---|
| Apple II, IIgs at 2.8 MHz | **45 MB/s** | 2.8 M bursts/s x 16 B — but only 2.8 % of *cycles* |
| Apple II, legacy at 1.023 MHz | 16 MB/s | 1.0 % of cycles |
| Bus event trace, every cycle packed | ~22 MB/s | ~8 B/cycle at 2.8 MHz |
| FT601 USB 3.0 to host | **335 MB/s** measured | the bridge is the limit, not the DRAM |
| **Total** | **~405 MB/s** | **~27 % of sustained** |

**The DDR3 is nowhere near the bottleneck, and it will not become one.** Roughly
3x headroom with every client running flat out, and 30x over the Apple II alone.

That reframes the design problem completely:

> **Do not optimise this for throughput. Optimise it so the Apple II's
> latency-critical access never queues behind anything.**

Throughput is free. Determinism is what has to be engineered.

### How much room is in a free Apple cycle

Because the free windows are known *in advance* (the whole basis of the refresh
gate), streaming work can be scheduled into them as whole batches:

| Machine | Bus cycle | Controller cycles | Usable bursts | Bytes moved |
|---|--:|--:|--:|--:|
| IIgs, 2.8 MHz | 357 ns | 35 | ~25 | **~400 B** |
| Legacy, 1.023 MHz | 978 ns | 97 | ~85 | **~1.3 KB** |

(Allowing ~10 cycles of margin for turnaround, drain, and getting out of the way
before the next Apple access.)

At a 1-in-16 line miss rate, ~15 of every 16 IIgs bus cycles are free, giving
roughly `25 bursts x 15/16 x 2.8 MHz x 16 B` ≈ **1.05 GB/s** available to
streaming clients *without ever contending with an Apple access*. That is more
than double what every other client combined can consume.

### Worked example: a 256-byte icache line fill

A 256-byte, naturally-aligned cache page is 16 bursts. Because `wb_addr[6:0]` is
the column field (128 bursts = 2 KB), an aligned 256 B block **always lies
entirely within one row of one bank** — 8 pages per row, no straddling possible.
Alignment buys the containment for free.

So all 16 bursts after the first are page hits in an open row, at
`READ_TO_READ_DELAY = 0`, i.e. **one 16-byte burst per controller clock**:

| | First ack | Last ack | Total | Effective rate |
|---|--:|--:|--:|--:|
| First burst is a row miss | ~12 cy | +15 cy | **270 ns** | 948 MB/s |
| Row already open (previous page, same row) | ~10 cy | +15 cy | **250 ns** | 1.02 GB/s |

Three things follow:

- **Critical-word-first is free.** All 16 bursts are page hits in the same row, so
  they can be issued in any order — fetch the burst holding the requested byte
  first and wrap. The wrapped sequence makes the `addr + 5` guess wrong, but a
  wrong guess that stays inside the same row is a no-op, so it costs nothing.
- **A fill occupies most of a IIgs bus cycle.** 270 ns of 357 ns. The first word
  lands at 120 ns and meets the 180 ns deadline, but the tail leaves only ~87 ns
  before the next address-valid. That margin does **not** survive a refresh
  landing mid-fill (~300 ns) or a write turnaround in front of it (+40 ns). The
  fill must therefore be part of the same scheduling predicate as refresh, not
  independent of it. On legacy machines (978 ns) there is no issue.
- **1 fill in 8 trips the anticipation leak** above, because the last page of each
  row is the one whose tail speculates into the next bank.

### Worked example: the bus event capture ring

Capture is 32 bits per Apple bus cycle in full-dump mode, or 64 bits per event
when filtering to video writes and similar. A 32 MB ring — one dedicated bank —
buffers against host consumption stalls.

| Mode | Rate | Bursts/s | % of DDR3 cycles | 32 MB holds |
|---|--:|--:|--:|--:|
| Full dump, IIgs 2.8 MHz (4 B/cy) | 11.2 MB/s | 700 K | **0.7 %** | **2.9 s** |
| Full dump, legacy 1.023 MHz | 4.1 MB/s | 256 K | 0.26 % | 7.8 s |
| Filtered, 8 B/event, max store rate | ~7.5 MB/s | 470 K | 0.47 % | 4.3 s |

(The 65816 sustains at most about one store per 3 cycles — `STA dp` — so the
filtered mode really is the lower data rate despite the wider record.)

Capture therefore costs **under 1 % of DDR3 cycles**. Bandwidth is a non-issue.
The entire problem is scheduling and granularity.

#### Two levels of buffer, each for a different problem

- **BRAM staging, a few KB — absorbs the gap between free DDR3 windows.**
  Microseconds. 4 KB = 1024 events = **366 µs** of IIgs full-rate capture, i.e.
  1024 consecutive cache misses with no free window, which cannot occur.
- **DDR3 ring, 32 MB — absorbs host consumption stalls.** Seconds.

Sizing either for the other's job is the mistake. All 50 BRAM tiles are free.

#### Coalescing is the whole game

A 32-bit event against a 16-byte burst is 4x write amplification *and* one DDR3
transaction per bus cycle — which puts a write in front of the Apple II's read
almost every cycle, and `WRITE_TO_READ` is 40 ns out of ~60 ns of IIgs slack.
Coalescing in BRAM to whole 16-byte lines (4 events, or 2 filtered) removes both
problems. Both record sizes pack into 16 bytes with no straddling.

Only ever flush whole lines; keep the remainder in BRAM. Byte enables would make
a partial burst correct (no RMW), but it wastes a burst for no reason, and at
4 B/cycle a line completes every 4 bus cycles anyway.

#### The interleave

**Flush only inside a bus cycle already known to be a cache hit** — the same
predicate that drives `i_refresh_ok`. That is what makes the scheme safe: hit or
miss is decidable before the cycle needs the DDR3, so a miss can never arrive
mid-flush. This matters because **an accepted Wishbone request cannot be
cancelled**; a miss landing mid-flush would queue behind the remaining writes
plus turnaround (up to ~320 ns) and blow the deadline outright.

Budget inside one free IIgs cycle: 35 controller cycles, less 4 for write→read
turnaround and ~6 for start/stop margin = **~25 bursts = 400 bytes**.

Against a 4 B/cycle fill rate, break-even is `4 / 400` = **one free bus cycle in
100**, against an expected ~15 in 16. About 94x margin.

#### Priority by deadline, not by importance

| Client | Deadline | Class |
|---|--:|---|
| Apple II | 180 ns | hard |
| Refresh | 7.8 µs | hard — silent corruption |
| Trace flush | ~366 µs (BRAM depth) | soft |
| Host drain | ~2.9 s (ring depth) | soft |

Trace capture feels like the second-priority client, but refresh's deadline is
47x more urgent and its failure mode is silent. **Rank refresh above trace.** It
costs the trace nothing — refresh is 160 ns per 7.8 µs.

#### The drain is a read stream against the same bank

Feeding the FT601 means reading the ring, and mixing that with ring writes pays
turnaround both ways. Worse, head and tail are far apart by design, so they sit
in **different rows of the same bank** — a direction switch costs a
precharge/activate (2 cy) *on top of* the turnaround (4 cy).

Use hysteresis: in any free bus cycle do either writes or reads, never both, and
hold a direction across several free cycles. Switching every free cycle costs
6/25 ≈ 24 %; switching every 8 costs ~3 %. In steady state the drain rate equals
the capture rate (~0.7 % of cycles), so this only bites during post-stall
catch-up at FT601 line rate.

If both ever need to be hot at once, stripe the ring across two banks in
alternating 2 KB chunks so head and tail usually land in different banks. Almost
certainly over-engineering — noted because it is the only way to actually avoid
the conflict rather than amortise it.

#### Overflow must be explicit, and must be signalled

In full-dump mode the timestamp is **implicit in position** — that is precisely
why 32 bits suffices. So a dropped event corrupts the timebase of every record
after it. On overflow the ring must write a **gap marker carrying an explicit
cycle count** so the host can resynchronise; a silent gap in a bus trace is worse
than no trace.

Head-drop (overwrite oldest) suits "what led up to now"; tail-drop suits "what
happened after the trigger". Either is defensible, but it has to be a decision
and it has to reach the host.

### How CPU acceleration changes all of the above

Everything above assumes the FPGA races the host bus to a hard 180 ns deadline.
Under **CPU acceleration** — the core runs from cache and, when it needs host
interaction, stalls until the host bus comes around, transacts, and disconnects —
that deadline disappears. The DDR3 stops being a hard-realtime device and becomes
a bandwidth-shared one. Let `A` be the acceleration factor over the IIgs'
2.8 MHz.

#### What relaxes

- **The refresh gate stops being load-bearing.** A collision costs the core
  ~300 ns of stall rather than a wrong answer. Still wanted for a
  non-accelerated passthrough mode; no longer what gates the project.
- **Free-window prediction goes away**, replaced by a priority arbiter plus
  direction batching.
- **Row-miss latency stops mattering.** The 120 ns result that justified UberDDR3
  over MIG was a deadline argument; under acceleration it is an IPC argument, and
  a much weaker one.

#### What binds: the FT601, not the DDR3

Full capture at 4 B per core cycle is `A x 11.2 MB/s`, so the host link sets the
ceiling directly. `DERISK.md` milestone 3 measured **335.4 MB/s** sustained
FPGA→host, sequence-verified, through WSL's USB/IP tunnel — a floor rather than a
ceiling in its own terms, within 7 % of native reports for the same chip. The
target host is a **Raspberry Pi 5**, not yet measured, so 335 MB/s is used here
as a ceiling.

| FT601 sustained | A | f_cpu | DDR3 load¹ |
|---|--:|--:|--:|
| **335 MB/s** (measured, WSL) | **29.9** | **84 MHz** | 885 MB/s (59 %) |
| 250 MB/s | 22.3 | 62 MHz | 660 MB/s (44 %) |
| **175 MB/s** (queue depth 1) | **15.6** | **44 MHz** | 462 MB/s (31 %) |
| 100 MB/s | 8.9 | 25 MHz | 264 MB/s (18 %) |

¹ capture writes + drain reads + cache fills at 1 % miss, 256 B lines.

At 335 MB/s three ceilings converge: FT601 gives `A ≈ 30`, fabric Fmax gives
roughly `A ≈ 30–35` (the DDR3 controller closes at 100 MHz with +1.9 ns), and the
DDR3 sits at 59 %. Nothing is badly mismatched, so no single fix buys much.

#### The Pi 5 risk is queue depth, not host CPU

The link is **latency-bound, not per-byte-bound**: 172→335 MB/s from queue depth
1→4, then flat while latency grows linearly. Per-byte host cost is low, so the
Pi 5's weaker cores matter less than they appear to. The specific risk is that
Pi 5 USB3 sits behind RP1 on a PCIe 2.0 x4 hop x86 does not have, raising
per-URB latency — so a **deeper queue may be needed to reach the same rate**.

The depth-1 row above is the one that matters: if the Pi can only keep one
transfer in flight, **the acceleration ceiling halves**, from A≈30 to A≈16. At
that point the FT601 is clearly binding with the fabric half idle, and trace
compression or fetch filtering starts to pay for itself.

**This is measurable now, with no new RTL.** `tools/ft601/ft601_probe` builds on
aarch64 as-is (libusb only, no D3XX — see the Makefile) and already sweeps depths
`{1, 2, 4, 8, 16}`, reporting MB/s, latency, CPU %, timeouts and errors, with
`DERISK.md`'s guide to reading the sweep. The WSL run flattened at depth 4; 8 and
16 are already covered, which is where a higher-latency host would need to reach.
Running the existing probe against the existing bitstream settles the number that
every other budget here depends on.

**The 1024-byte errata does not apply to capture.** It requires the host to
expect more than arrives, and a high-rate trace stream is continuous by
construction — the same reason no 335 MB/s run ever tripped it. It remains a
problem for bounded request/response, not for streaming.

**Direction batching becomes mandatory, not an optimisation.** At A=20 capture
and drain are 14 M bursts/s *each way*. Perfectly batched: 28 % of controller
cycles. Thrashed per burst (~4x): **112 %, over budget before cache fills.**

#### Acceleration breaks the implicit timestamp

32 bits suffices for full dump only because position implies time — every host
bus cycle is 357 ns. **An accelerated core's cycles are not uniform**: it stalls
on cache misses, host rendezvous, and DDR3 contention. So either record stall
cycles (inflating the trace to say nothing), or add explicit timestamps — 64-bit
records, **halving A to 9–18**.

The cheap fix is a **periodic sync record**: one 8-byte timestamp per 256 events
is ~3 % overhead, giving ordering from position and absolute time from the sync
points. Standard in ETM/RISC-V trace formats, and it preserves the 32-bit fast
path. Design it in from the start — retrofitting a timebase into a trace format
is miserable.

Going further, trace compression (branch taken/not-taken bits, indirect targets
only, no sequential fetches) routinely achieves 10–100x on execution traces and
would remove the FT601 bound entirely. Substantial logic, but it is the only
lever that makes 100 % capture cheap rather than dominant.

#### Video: snapshot, do not stream

| Approach | Rate | Scales with A? |
|---|--:|---|
| Forward every video write (8 B/event) | ~3.7 MB/s x A | **yes** — 75 MB/s at A=20 |
| Snapshot dirty SHR regions per scanline | **1.9 MB/s** | **no** |

200 lines x 60 Hz x 160 B = 1.92 MB/s; per-frame full-32 KB comes to the same
number. ~40x cheaper at A=20 and, crucially, **constant in A** — video stops
budgeting against acceleration entirely.

Per-scanline rather than per-frame is what preserves raster fidelity, which
Apple II software leans on heavily. This presumes the FPGA owns the display
timing model; if the host still drives the display, the timing relationship needs
separate thought.

#### Two capture modes, very differently bounded

| Mode | Bound | Duration |
|---|---|--:|
| Live trace, drained to host | FT601 → **A ≤ 18–36** | unlimited |
| Burst capture to ring, drain after | DDR3 only → **A ≤ ~67** | **2.86/A s** — 143 ms at A=20 |

For debugging, 143 ms at full fidelity and no FT601 constraint often beats an
unlimited stream at half the clock. It also removes drain reads during capture,
halving DDR3 traffic and eliminating direction switching outright.

#### The resource conflict that probably decides the ceiling

At A=20 and 224 MB/s, a 4 KB BRAM staging buffer fills in **18 µs** — comparable
to `tREFI`, which is uncomfortably tight. It wants 64–128 KB.

But the A35T has **225 KB of BRAM total, and the cache competes for the same
pool** — and the cache is what produces the >99 % hit rate that makes
acceleration work at all. Spending 128 KB on trace staging leaves under 100 KB
for caches, raising the miss rate and increasing DDR3 fill traffic.

That circularity — trace staging and cache bidding for the same BRAM, with the
cache determining how much DDR3 traffic exists to schedule — is likely the real
ceiling on acceleration on this part. Ahead of the DDR3, and possibly ahead of
the FT601.

### What the linear throughput could actually be used for

- **Deep bus tracing.** 256 MB at ~22 MB/s packed = **~11 seconds** of every-cycle
  65816 trace (address, data, RWB/VDA/VPA/MX flags). Unpacked at one burst per
  cycle it is 45 MB/s = ~5.7 s. **Pack records into 16-byte lines in BRAM and
  flush whole lines** — it doubles the capture depth and, more importantly, makes
  the writer sequential and batched instead of one scattered burst per event.
  All 50 BRAM tiles (~225 KB) are currently free.
- **Full RAM snapshot / rewind.** An 8 MB IIgs state is 5 ms of sequential DDR3
  writes. Continuous rewind buffers, save-states, and diffing become cheap.
- **Video capture or framebuffer.** IIgs super-hires is 32 KB; at 60 Hz that is
  2 MB/s — noise. Even 1080p60 RGB scan-out (373 MB/s) fits.
- **Host-side bulk transfer.** The FT601 is the constraint at 335 MB/s measured.
  The DRAM can keep it saturated with ~78 % of its bandwidth still spare.

---

## 6. Recommended structure

> **Built (2026-08-28), see `MEMORY.md`:** the Apple's memory image is DDR3
> bank 0 behind `rtl/mem_cache.sv`; `rtl/mem_client.sv` is the strict-priority
> client of `rtl/wb_arb.sv`, pre-emptive rather than window-gated, and drives
> `i_refresh_ok` from the bus cycle's position; the ring's batches are 32 lines
> so one begun in the client's window is over before the next cycle.

There is **no second data port** — `SECOND_WISHBONE` is a 32-bit, 7-bit-address
memory-mapped *debug/calibration* interface, not a data path. Arbitration is
yours to build.

```
   Apple II bus logic ---+
                         |     strict priority
   refresh gate ---------+---> [ arbiter ] ---> single Wishbone port
                         |      + aux tag
   trace writer ---------+
   host DMA -------------+
```

Four rules, in order of how much they matter:

1. **Strict priority to the Apple II, and never speculate against it.** A request
   accepted by the controller cannot be cancelled or reprioritised. The arbiter
   must not start a streaming burst unless the next Apple access is known to be
   at least the burst length plus turnaround away. The predicate already exists —
   it is the one driving `i_refresh_ok`.

2. **Batch by direction.** Never interleave single reads and writes. Accumulate
   trace records in BRAM and flush them as a run of writes; do host DMA reads as
   a run of reads. This is worth ~4x on streaming throughput and 40 ns of Apple
   II slack.

3. **Partition banks.** Give each sequential client its own bank via
   `wb_addr[9:7]`, so the Apple II's random traffic cannot evict its open row.
   Protecting the streaming clients, not the latency client.

4. **Use `i_aux` to demux.** `AUX_WIDTH` is 4, so 16 client IDs. Tag each request;
   `o_aux` comes back with `o_wb_ack` and routes the data home. Acks are strictly
   in order through a single shift register, so a FIFO of IDs would also work —
   but `aux` is already wired and costs nothing.

Add a **line buffer in front of the Apple II path** (already flagged as milestone
2b). Since a 16-byte burst is paid for regardless, caching it turns ~15 of every
16 sequential instruction fetches into zero DDR3 accesses. That is not primarily
a performance win — it is what *generates* the free windows that rules 1 and 2
depend on. The line buffer is load-bearing for the whole scheduling scheme.

---

## 7. Open questions — things this document asserts but has not measured

- **Throughput has never been simulated.** `sim/latency_tb.sv` runs one
  outstanding request at a time by construction, so every number in sections 4
  and 5 about sustained bandwidth, turnaround cost, and bank-conflict cost is
  derived from the RTL and the timing constants, **not measured**. A pipelined
  throughput testbench — keep `stb` asserted, count acks per 1000 cycles, sweep
  {all-read, all-write, alternating} x {sequential, random, bank-partitioned} —
  would confirm or kill all of it in an afternoon and is the obvious next
  simulation task.

- **`tFAW` is not implemented in UberDDR3.** Zero occurrences in
  `ddr3_controller.v`; only `tRRD` is modelled, as
  `ACTIVATE_TO_ACTIVATE_DELAY = 0`. That permits an ACTIVATE every controller
  cycle (10 ns), whereas `tFAW` permits 4 per 50 ns — a sustained average of
  12.5 ns. So the controller's floor is *below* what the spec allows.

  In practice it looks unreachable: the 2-stage pipeline serialises a row miss
  into PRE(N), ACT(N+2), RD(N+3), so back-to-back misses produce an ACTIVATE
  about every 3 cycles (30 ns), comfortably inside `tFAW`. The anticipation path
  only fires once per 128 bursts when streaming. And the existing latency runs
  report `tRFC` violations but never `tFAW`, which is consistent.

  It is worth *proving* rather than assuming, because the failure mode is silent
  data corruption on real hardware and free to detect in simulation: the Micron
  model does check it (`ddr3.sv:1427`, `TFAW = 50000` for the 2 KB-page
  DDR3-800 bin). The pipelined-random case of the throughput testbench above
  would exercise exactly the pattern at risk.

- **The `i_refresh_ok` predicate needs revising** for multi-client use, per
  section 4, cost 3.

- The `+1` added to `READ_TO_WRITE_DELAY` and `WRITE_TO_READ_DELAY` is marked
  `NOTE TO SELF: why plus 1?` in upstream. It is conservative, so it is safe, but
  it is 10 ns of turnaround that may not be necessary. Not worth touching until
  the throughput testbench exists to show whether it matters.
