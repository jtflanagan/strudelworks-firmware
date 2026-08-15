# FT601 link protocol

The message framing carried over the FT601, both directions. This is the
framing DERISK.md milestone 3 deliberately left undesigned; the constraint it
was designed around — the 1024-byte termination errata, and the decision that
the transmitter owns it — is recorded there and not repeated here.

## Two facts this design treats as given

**The FT601 buffers internally in 1 KB units. A buffer dispatches when it
fills, or when TX goes idle** (`DS_FT600Q-FT601Q`). So a run of exactly N×1024
bytes leaves an empty buffer behind and produces no short packet, and a host
read posted for more than that never terminates — the errata measured in
DERISK.md. Any other length leaves a partial buffer that dispatches on idle and
terminates the read. The hang condition is therefore exactly "the chip's
current buffer is empty and we stopped sending", and one extra block is the
entire fix. That is the heartbeat.

**Byte order is little-endian, end to end.** A 32-bit fabric word goes onto
`ft_data` unpermuted, and the host reads it with a plain little-endian load.
The reference controller's byte reversal (and the matching swap in
`ft601_probe.c`) is deleted, not inherited — it was a property of pcileech's
wire format, not of the chip.

## Framing

A **block** is 32 bits. Every message is one header block plus 0–255 payload
blocks, so a message is 4–1024 bytes and a maximum-size message is exactly one
FT601 internal buffer.

```
little-endian 32-bit header
  31            16 15      8 7      0
 +---------------+---------+--------+
 |     free      |  type   |  len   |
 +---------------+---------+--------+
```

- `len` — payload blocks, NOT counting the header. 0 = header only. In bits
  [7:0] so the length is the first byte off the wire.
- `type` — message type.
- `free` — type-specific. No fixed meaning at the link layer.

Same header both directions. Messages may straddle bursts, FT601 buffers, and
host reads; the receiver carries parser state across all of them.

### Types

| type | name | meaning |
|---|---|---|
| `0x00` | IDLE | Link filler. Payload, if any, is discarded by the receiver. `len = 0` is the **heartbeat**: the single word `0x00000000`. `len > 0` is defined but currently unused. |
| `0x01`–`0x0F` | — | Reserved for link-layer types: ones the FT601 layer may generate or consume on its own, parseable without application state. |
| `0x10`–`0xFF` | — | Application. |

### Deliberately absent: CRC, sync word, resynchronisation

A lost or duplicated block desynchronises the parser permanently and silently —
with a 16-bit free field nearly any word parses as a plausible header. This is
accepted, not overlooked: engineering effort goes into sync not being lost, and
the situations that would lose it (words dropped on a verified link) were
unrecoverable errors anyway. Do not "fix" this later by adding a sync pattern
without revisiting that decision; the sequence-verified link is the integrity
mechanism.

### But sync must still be ACQUIRED, which is a different problem

Having no resynchronisation assumes framing was established and then lost. A
receiver attaching to a transmitter that is already running has never had it.
There is nothing in a header that distinguishes it from payload, so a receiver
cannot find the first boundary on its own.

**A consumer gets its framing from request/response**: the first block of the
response to a request it made is a header by construction, and from there the
length fields carry it forever. That is the intended acquisition mechanism and
it needs no sync word.

A free-running transmitter has no such anchor, and that is not hypothetical —
the bring-up gateware in `ft601_top` streams from power-on, so a host read
begins mid-frame 15 times out of 16. Measured: the parser read a payload block
as a header and never recovered, 348 sequence breaks and 28 impossible headers
per run, while the gateware's framing was in fact exact.

`ft601_probe` handles this by locking onto the specific header its own test
source emits, confirmed by a second header one frame later. That is sync
acquisition in a test harness that knows its transmitter — **not** a general
mechanism, and not protocol resync. Do not mistake it for one.

Note also that frames and the chip's 1 KB buffer do not stay in phase: a
heartbeat is one block, so every inserted heartbeat shifts the alignment.
Nothing may rely on a USB packet beginning with a header.

## The transmit rule

The transmitter tracks **the fill level of the chip's current internal
buffer**, not the length of its own bursts. Bursts end for reasons that have
nothing to do with whether the chip dispatched, so counting them counts the
wrong thing.

State, all in the `ft_clk` domain:

- `buf_blocks[7:0]` — blocks forwarded into the chip's current buffer.
  Increments on each block actually handed to the chip (the controller's FWD,
  not writes into its skid buffer). Wraps at 256, which is exactly where the
  chip dispatches on fill — so a fill needs no special handling: the wrap to 0
  already describes the fresh empty buffer.
- `sent` — set on any forwarded block, cleared on a dispatch. Distinguishes
  "buffer empty because one just filled" from "buffer empty because the link is
  idle".
- `blocks_left` — blocks remaining in the message being pushed; snoops `len`
  from each header and counts down. Zero means the next block is a header.
- `hb_pending` — a heartbeat is owed but could not be written yet.

A **dispatch** is the chip flushing its current buffer: on fill (the wrap), and
when TX goes idle. TX going idle means *we stop writing while the chip is ready
to accept* — source starvation or an RX turnaround. It does **not** mean TXE#
backpressure: TXE# deasserted is "chip busy", not "TX idle", and 335 MB/s on a
400 MB/s bus proves the chip does not dispatch on those gaps, or throughput
would collapse into tiny packets.

On a dispatch, with `blocks_left == 0` and the TX FIFO empty:

| `buf_blocks` | `sent` | chip state | action |
|---|---|---|---|
| ≠ 0 | — | partial buffer dispatches | none — the read terminates |
| 0 | 1 | empty; last dispatch was a fill | **emit one heartbeat** |
| 0 | 0 | empty; link idle | none — the idle timer covers liveness |

Then `buf_blocks <= 0`, `sent <= 0`.

The injected heartbeat forms a one-block buffer, so the next dispatch falls in
the first row and cannot retrigger: exactly one extra 4-byte packet, only when
the link is genuinely idle on a 1 KB boundary.

### Cases

1. **Voluntary idle, partial buffer.** Dispatches, read terminates. No action.
2. **Voluntary idle, buffer empty after a fill.** The hang. Inject.
3. **Voluntary idle, nothing sent.** Idle link. Idle timer only.
4. **TXE# stall mid-buffer.** Chip busy, no dispatch. `buf_blocks` and `sent`
   untouched; the run resumes into the same buffer. This is why the counter
   must not reset on burst boundaries.
5. **TXE# stall at a buffer boundary** — no free buffer for the next one, the
   common case when the host falls behind. The fill already dispatched;
   `buf_blocks` has wrapped to 0, which correctly describes the new empty
   buffer. No action, no special case.
6. **TXE# stall at a boundary, then the source runs dry before TXE# returns.**
   Case 2 deferred: the condition is true but the write cannot be issued. Set
   `hb_pending`, emit when TXE# allows. The heartbeat rides the normal path and
   waits its turn like any other block.
7. **RX turnaround.** The chip sees TX idle and dispatches. Evaluate the table
   at the transition into RX; any injection defers via `hb_pending` until the
   bus turns back around.
8. **Source stalls mid-message on a boundary.** `blocks_left != 0`, so no
   injection — it would corrupt the frame. The read stalls only until the
   producer resumes, which is bounded by definition: an incomplete message
   means more blocks are coming. A producer that stalls forever is a producer
   bug, and the partial message is lost in the receiver's parser state either
   way.
9. **Anything unmodelled.** The idle timer unsticks it.

### Idle timer

An unconditional heartbeat when nothing has been sent for ~100 µs
(parameterised). Three jobs, and it is worth its ~40 KB/s on a dead link for
any one of them:

- Backstop for every dispatch-detection assumption above being wrong.
- Conventional heartbeat semantics — the host can detect a dead link.
- **It bounds speculative-read latency.** A heartbeat leaves a one-block buffer
  that dispatches as a 4-byte short packet, terminating whatever oversized read
  the host has outstanding. Without it, a speculative read that outruns the
  data waits for the libusb timeout — milliseconds instead of microseconds.

The case-2 injection stays even though the timer would eventually catch it:
immediate is better than 100 µs late.

## Host-side rules

- Never announce a session length that is a multiple of 1024 when reading into
  a larger buffer (the errata's other half; see DERISK.md for the measurement).
  Exact-length reads are exempt — they are satisfied by length and never ask
  the chip to terminate.
- The receive parser must carry state across reads: a message may straddle any
  read boundary.
- IDLE messages are consumed and discarded at the link layer; their payload has
  no meaning.
