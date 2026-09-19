# The L1 rethink: a TLB that points into L2

Status: **BUILT 2026-09-19 on the 65C02 card (rungs 4-5: rtl/a2/tlb.sv, l1i.sv, l1d.sv; sims green; L1 = 2,306 LUTs against 9.9k); the data read is THREE clocks, not two (the two-clock launch would sit on d_pred's cone, see l1d.sv's header); design opened 2026-09-18, branch `core_refactor`.** The
requirements it answers to are docs/REQ_65C02.md and docs/REQ_65816.md; this note is the first
design conversation, not a plan of record. The two cards decide their L1 and L2 separately (the
user, 2026-09-18); this idea is offered to both.

## The problem this starts from

The requirements extraction (REQ_65C02.md §5, observation 3) says it plainly: L1 is duplicating
L2's job. Two set-associative caches (8x4 in each L1 side plus a retained set) keep their own
virtual tags, physical page numbers, region indexes and bank-class bits per line, revalidate every
line on every map change, snoop every write, and run their own fill state machines and books, all
in front of a 256 KB page cache that answers any byte in three clocks. On the 65C02 card that
duplication is what does not fit the Alchitry Au (REQ_65C02.md §0): L1 is 9.6k LUTs and 9.4k
flops; L2 is 64 RAMB36 on a part with 50.

An L1 line fill today is a serial chain: miss detect (one clock, from the registered candidate),
the claim and il_req, il_ack (the port arbitration plus a nine-term coherence gate), the page
cache's P0 directory read, P1 eight tag compares to find the way, P2 the row read, il_done three
clocks after the ack, the install, the serve. Six or seven clocks at best, and the L2 runs a full
directory lookup for every 16-byte line although the page's location did not change between one
line and the next. The current design compensates with capacity: enough lines in L1 that the fill
is rare. Capacity is exactly what the Au budget takes away.

## The insight (the user, 2026-09-18): the TLB carries the L2 way

Give L1 a small CAM of translations, and let each entry carry not only the physical page but
**where L2 holds it**: {virtual page (+ bank on the GS), physical page, L2 set, L2 way}. An L1
fill on a TLB hit is then a plain block-RAM read of one known way at one known row: no directory,
no tag compares, no 8:1 way mux, and the LRU bookkeeping can run beside the read instead of ahead
of it. The intent is to **greatly reduce the number of lines L1 keeps and pay for it with a much
smaller fill penalty**.

### What it removes

- **The fill chain.** A way_ram port answers in two clocks. The fill becomes miss detect, address,
  data, serve: three to four clocks against six or seven, and no L2 directory traffic per line.
- **Per-line translation.** A line's tag today is a 12-bit virtual tag, a 16-bit physical page, a
  4-bit region index, a bank byte and two or three class bits. With the TLB it is a TLB index (2-3
  bits) and a line-in-page (4 bits). Every compare in every serve cone gets narrower.
- **Per-line revalidation.** On a map change the valid bit of every L1 line is recomputed from its
  stored region against the new table (rtl/iline.sv:655-694, rtl/dline.sv:660-697). With the TLB,
  the four or eight TLB entries are revalidated instead, and the per-line rv1/rv_ok stages and
  their books go. Two of the four L1 families in the IIe depth baseline are exactly those books.
- **The L2 directory lookup per line.** Once per page per TLB residence instead.

### What it inherits from the L2 directory

The way index is true only while L2 keeps that page in that way, so the TLB takes on the
directory's obligations for the entries it holds:

- **Eviction.** Either L2 broadcasts "set s, way w replaced" and the TLB kills matching entries, or
  **L2 never chooses a way a TLB entry points at as a victim**. The second is the one to take: a
  "referenced" bit per way excluded from the victim choice; when a set already has every way
  referenced, the TLB fill is REFUSED (the page stays on the slow path) rather than an eviction
  forced. With four to eight TLB entries against eight ways per set the refusal is rare, and no
  broadcast path exists to get wrong. This is an invariant worth stating in the requirements once
  agreed: *a pointed-at way is never a victim*.
- **PLRU.** The parallel update works, and can go further: TLB residence IS the recency signal.
  Touch the PLRU only on the directory path (once per page per TLB residence); a direct read
  touches no L2 state at all.
- **The P+2 law and the posted-write FIFO** (REQ_65C02.md §3.2.3, §4.3.1). A direct read of a way
  on the clock a write lands in the same row is a cross-port collision on the block RAM, which the
  primitive leaves undefined. The gate stays: one term (a landing in this row this clock, or a
  posted write pending to this page), not the nine-term il_ack.
- **Map changes.** The five-clock settle stays; what changes is that it revalidates TLB entries,
  not lines. The one-register-stage rule on INTC8ROM and the $Cxxx exclusions stay where they are.
- **Declines.** A TLB miss is the slow path: the ordinary L2 lookup returns the way index and fills
  the TLB. The first line of a page pays once; the other fifteen ride the pointer.
- **Snoops.** Unchanged in kind: a write's physical identity is compared against the TLB entry's
  physical page and the line's line-in-page. Cheaper in width.

### Where it goes further: serve from L2, keep L1 tiny

The bigger question the pointer opens is whether the row needs to be installed in L1 at all.

The core's prediction exports (i_pred, d_pred: REQ_65C02.md §2.1.4) are one cycle ahead. A
block-RAM read launched at prediction time lands one clock too late for a one-clock core cycle,
but exactly on time for a two-clock one. So on a TLB hit, **a data read the small L1 does not hold
can be served straight from the L2 row at two clocks with nothing installed**: no claim, no fill,
no line. That is the GS's two-clock read today (rtl/dline.sv:866-885), but as the miss path for
everything rather than the hit path. Against the current miss costs (7.7 clocks on the
dispatcher, more for a line fill), two clocks is close enough to one that the number of L1-D lines
stops mattering much: the rung-4 capture (docs/DLINE.md:640-661) said a 4-way CAM misses 64% of
the reads it could see, and at two clocks a miss that is a small tax, not the wall it was.

On the instruction side the linear predictor can run two ahead for straight-line code, so two or
three 16-byte line buffers in flops plus the next-line prefetch through the pointer keep one clock
per fetch, and a branch into a resident page pays the two-clock read once.

What is left of L1 is then the one-clock accelerators:
- two or three line buffers per side (the two slots iline has today, without their tags);
- the zp/stack shadow (512 B of LUTRAM; it serves half of all data ops and is cheap);
- the last byte, for the CMOS LAST/FIXUP dummy re-reads (one register, no storage);
- branch resolution from registered truth, as today;
- the posted-write FIFO and the splice into whatever is held.

The candidates to drop: the retained set and the scanner, the second cache with its own tags in
L1-D, the last row, the bank table, and every per-line copy of the map.

### The constraint to count before believing it

way_ram has two ports: A is the op path and the landing writes, B is the miss engine's fill and
flush beats. Direct reads from both L1 sides, posted writes and fills all want those two ports.
With line buffers the instruction side needs one row read per sixteen fetches; the data side one
read per data op the small L1 does not hold (30-40% of ops today); posted writes one landing each;
the engine sixteen beats per fill and per flush. That fits on paper and wants counting from a
capture, and the engine's beats are the other tenant on port B. A third read port is not
available on a RAMB36 without duplicating the array.

### What it means for each card

- **65C02 card.** The Au budget (REQ_65C02.md §0) is the driver: L1 shrinks to the accelerators
  above, L2 shrinks to what the block RAM allows, and the fill penalty is what makes the small L1
  tolerable. The never-evict property is replaced by "a pointed-at way is never a victim".
- **65816 card.** The same pointer, keyed by {bank, page}, dissolves the bank-class problem
  (cvz/cvd/cvo, the OTHER-class table, the pair-bank special cases) by construction: any page in
  any bank is a TLB entry like any other. The two-clock read it already pays becomes the design
  rather than the exception. Decided separately, per the user; offered here.

## The sizes: picked, not modelled (the user, 2026-09-18)

A capture model would burn time and tokens finding a number the range already bounds; the sizes
are PICKED, and the first build measures them. For the 65C02 card:

| structure | pick | why |
|---|---|---|
| TLB | 8 entries, LRU, {vpage, ppn, L2 set, L2 way, region, valid} | a 6502 program's live pages at an instant: one or two of code, a few of data, the screen it draws, a ROM page under a JSR; pages 0/1 go through the shadow and need no entry; ~40 flops and an 8-bit compare per lookup side per entry; 8 keeps the referenced-way rule from pinning a whole set |
| L1-I | 2 line buffers, next-line prefetch through the pointer | the pair iline has today minus its tags; 99.3% of fetches at one clock as measured; with a 3-4 clock fill the retained set and the scanner have nothing left to save |
| L1-D | the zp/stack shadow (512 B LUTRAM) + the last row (one 128-bit register) + the last byte | the shadow serves half of all data ops; the last row catches the second byte of a 16-bit read; the last byte is the CMOS dummy re-reads; everything else is served from the L2 row at two clocks; no cache, no tags, no bank table |
| L2 | 64 sets x 6 ways = 384 pages = 96 KB = 24 RAMB36 (4 per way) | the Au has 50; the link, ring and peripherals keep ~21; a 64 KB program with the language card (~272 pages) is wholly resident; a 128K double-hires program (512 pages) is three-quarters resident and misses to DDR3 at ~30 clocks; six ways is a non-power-of-two the tree-PLRU already handles (exercised at ten) |

The 65816 card picks its own later; the same shapes with 16 TLB entries and a 128-set L2 are the
starting guess there.

## Open questions

1. Does the TLB serve replace L1-D's cache entirely, or does a handful of lines (the last row
   generalised) still pay? The model answers this.
2. The referenced-way rule under a small L2: how often does a set fill with referenced ways, and
   is a refused TLB fill (slow path for that page) acceptable there, or does the TLB need to give
   up an entry?
3. Writes: does a TLB-hit write land directly in the known way (a landing on port A, one clock,
   no classify cone: REQ_65C02.md §3.1.5 already requires that below $C000), which would let the
   posted-write FIFO shrink or go?
4. The instruction side's two-ahead prediction across a line boundary and a taken branch: what the
   penalty is, and whether the branch target's page is usually TLB-resident (it is the same page
   for a short branch).
5. Whether the TLB is one structure shared by both sides or one per side; sharing halves the
   entries' cost and doubles the port pressure on the CAM.
