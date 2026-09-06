# Slot 3: the card as the 80-column card (design option, 2026-09-06)

Status: **description only, 2026-09-06, branch cxxx_work; nothing here is
built.**  The user's decision the same day: the VidHD signature page stays
as it is today (section 1, "Today") - this note is kept as the worked-up
option for a services entry.  What DID land from the discussion is the
shared slot: the VidHD and the Uthernet II cohabit slot 3 (UTHERNET2.md,
on hardware 2026-09-06).

The question it started from: the VidHD signature ROM exists only to pass
Total Replay's SHR gate.  Could the same slot 3 page be a proper slot 3
ROM - every entry point a slot 3 card is expected to have - while keeping
the signature?  What does the IIe itself do with a slot 3 ROM?  And where
would a StrudelWorks services entry go?

The user's second observation shaped the answer: "the card has no $C800
expansion ROM" is entirely within our control, and the ROM to serve there
is one the card already holds.  Section 3.

## 1. What the IIe does with slot 3 at reset - from the ROM, not from memory

Disassembled from AppleWin's `resource/Apple2e_Enhanced.rom` (the image the
card carries).  The only two writes to the SLOTC3ROM switch in the whole
16 KB are these, on the reset path (`$FA62` -> `$FBB4` -> `$C100` -> the
internal `$C2xx` init):

    $C2B7  LDA $C062 / BPL       closed-apple held -> JMP $C600 (boot)
    $C2C3  LDA $C061 / BPL $C2E2 open-apple held -> memory wipe, then:
    $C2E2  STA $C00B             SLOTC3ROM ON: $C3xx is the slot 3 card
    $C2E5  JSR $CA89             the test, below
    $C2E8  BNE $C2ED             nonzero -> LEAVE IT ON
    $C2EA  STA $C00A             zero    -> SLOTC3ROM off, internal firmware
    $C2ED  RTS

    $CA89  JSR $F8B7             the slot 3 ID test
    $CA8C  BNE $CA90             no ID -> the auxiliary-memory test
    $CA8E  INY / RTS             ID found -> return nonzero: keep the card
    $CA90  ...                   write $88 to aux $0400 through 80STORE +
                                 PAGE2, read it back, CMP #$88:
                                 zero = aux card present -> switch it off

    $F8B7  STA $C006             INTCXROM off: the slots own $C1-$CF
    $F8BA  LDX #2
    $F8BC  LDA $C305,X           X = 2: $C307 vs $18
    $F8BF  CMP $FC9C,X           X = 0: $C305 vs $38   (table: 38 90 18 84)
    $F8C2  BNE $F8CB
    $F8C4  DEX / DEX / BPL $F8BC
    $F8C8  DEY / BNE $F8BA       (repeats a matching compare Y times)
    $F8CB  STA $C007 / RTS       INTCXROM back on; Z = matched

So the rule, in order:

| slot 3 card's `$C305,$C307` | auxiliary memory | SLOTC3ROM after reset |
|---|---|---|
| `$38,$18` (the Pascal ID) | any | **stays set** - slot 3 is a normal slot |
| anything else | present | cleared - internal 80-column firmware |
| anything else | absent | stays set |

**The user's hypothesis is right, with one correction: it is the motherboard
firmware at reset that decides, not the OS, and it decides on two bytes.**
A card whose page says `$38` at `$Cn05` and `$18` at `$Cn07` is taken for an
80-column card and slot 3 is handed to it, even with the auxiliary card in.
The ID test runs BEFORE the aux-memory test.  Nothing else in the IIe ROM
touches `$C00A`/`$C00B`; ProDOS and Applesoft never do either.

What "handed to it" means: with SLOTC3ROM set the internal 80-column
firmware is out of the map.  `PR#3` enters the card's `$C300`, the CSW/KSW
hooks land in the card's `$C305`/`$C307`, a `$C3xx` access asserts the
slot's I/O SELECT (and no longer sets INTC8ROM), and the IRQ vector
`$C3FA` is the card's.  A card that takes slot 3 has to BE an 80-column
card - or have the firmware's own bytes.

Today: the card's VidHD page carries `$24 $EA $4C $05 $C3 $60`, the ID test
fails, the aux test passes, SLOTC3ROM is cleared, and the page is invisible
until a caller sets `$C00B` - which 4cade does for its scan and clears
again after (`SETC3ROM`/`CLRC3ROM`).

## 2. The page: the internal `$C300` page with the signature pasted in

The internal firmware's `$C300` page begins

    2C 43 CE   BIT $CE43    ($CE43 = $60: bit 6 -> V = 1)
    70 12      BVS $C317    (always)
    38 90 18   SEC / BCC    $C305: Pascal 1.0 output entry, and the reset ID
    B8 50 0C   CLV / BVC    $C307: Pascal 1.0 input entry (CLC), both -> $C317
    01 88      Pascal 1.1 generic signature, device class 8 (80-column)
    4A 50 56 5C  Pascal 1.1 init/read/write/status offsets

and `$C317` is the firmware's one common entry: `STA $067B ... PHP ... PLP /
BVS init / BCC input / output`.  Its three public entries only set V and C.

The VidHD signature is the first three bytes, `24 EA 4C`: `BIT $EA` (zero
page, harmless) and a `JMP`.  It displaces exactly the five bytes of
`BIT $CE43 / BVS $C317`, which nothing else in the 16 KB references (a
byte-aligned search for `$C300-$C304` as an operand finds nothing).  The
`JMP` needs a target that restores V = 1 and reaches `$C317`, six bytes:

    2C 02 C3   BIT $C302    ($4C = 0100 1100: bit 6 -> V = 1)
    4C 17 C3   JMP $C317

The internal firmware is packed - no six free bytes anywhere in `$C800-
$CFFF`, three-byte zero runs at `$C84A` and `$CF37` only - but the `$C300`
page has `00 00` at `$C3F2` followed by a six-byte fragment at `$C3F4`,
`STA $C081 / JMP $FC7A`, that no absolute operand or immediate pair in the
ROM refers to (`$FC7A` is the monitor's slot-ROM helper, not a caller).
So the stub goes at `$C3F2-$C3F7`, two bytes spare at `$C3F8-$C3F9`, and
the page is otherwise byte-identical to the internal one:

| offset | bytes | meaning |
|---|---|---|
| `$00-$04` | `24 EA 4C F2 C3` | VidHD signature; `JMP $C3F2` |
| `$05-$F1` | internal firmware, verbatim | IDs, Pascal entries and offsets, `$C311`/`$C314` vectors, the code |
| `$F2-$F7` | `2C 02 C3 4C 17 C3` | V = 1, then the common entry |
| `$F8-$F9` | free | (services status, section 4) |
| `$FA-$FF` | `2C 15 C0 8D 07 C0` | the IRQ vector stub, verbatim |

Open: whether `$C3F4` is reached by a pushed address (an RTS/RTI trick) -
no static reference exists; a fetch trap on `$C3F4` in the boot bench,
with the internal ROM, over a boot + `PR#3` + 80-column session settles it
(section 6).

## 3. Be the 80-column card: the expansion ROM

The firmware's other 2 KB live at `$C800-$CFFF`.  On the motherboard they
are mapped by INTC8ROM (set by a `$C3xx` access with SLOTC3ROM clear,
cleared by `$CFFF`) or INTCXROM; a card in a slot maps its own 2 KB there
by I/O STROBE' after its own I/O SELECT, released by `$CFFF`.  The card
already holds those bytes: `rtl/apple_mmu.sv` serves `$C800-$CFFE` from
the internal ROM whenever INTC8ROM or INTCXROM is set (its line 133), and
cxxx step 1 put that ROM on the icache.  So the card's expansion ROM costs
no storage and no bytes of its own: it is a SELECT LATCH and a mapping
term.

**The latch** (AppleTini v5_1_3's `soft_switch_manager` c8_select, which
`rtl/slot_switches.sv` deliberately left behind "until a peripheral has a
$C8xx presence"): set by an access to the card's `$C3xx` page while the
page is the card's (INTCXROM clear, SLOTC3ROM set); cleared by any access
to `$CFFF`; and yielding to INTCXROM and INTC8ROM, which the motherboard
wins.  INTC8ROM cannot be set while the card's page is selected (it needs
SLOTC3ROM clear), so the two never fight; the sequence "internal `$C3xx`
access, then SLOTC3ROM set, then card `$C3xx`" leaves both set and the
motherboard drives, exactly as on the hardware.

**The mapping**: `$C800-$CFFE` reads answered from the internal ROM when
(INTCXROM | INTC8ROM | slot3_c8_selected).  For the core this is one more
term in the condition that already exists.  `$C3xx` reads with SLOTC3ROM
set: the card's page (section 2) - today `vidhd_card`'s host-loaded 256
bytes, driven on the bus as a claimed cycle.

**Under acceleration.**  The rule (CXXX.md step 5) is that a slot is
hardware and rides the bus, the on-card peripherals excepted.  The bytes
here are the motherboard's own, and the firmware's output loop runs
through them on every character; leaving them bus cycles would make
80-column text the slowest thing on the machine whenever slot 3 is live.
The honest reading of the rule is that `slot3_c8_selected` is another
name for INTC8ROM as far as the fetch path is concerned - same bytes,
same ROM - and the `$C3` page is a second 256-byte ROM the icache can hold
(host-loaded, like the mouse's and the HDC's pages on the on-card list).
Mode 2 only, as every internalization is.  A decision for the user; the
slow version works first.

**What software sees.**  From power-on, slot 3 is a card with the Pascal
ID: SLOTC3ROM stays set (section 1), `PR#3` enters the card's `$C300`,
the stub sets V and the firmware runs - from the card's page and the
card's expansion ROM, which are the motherboard's bytes.  Interrupts take
the card's `$C3FA` stub (proven in slot 3 by mb-audit, 2026-09-06).  4cade
finds the signature at `$C300` with SLOTC3ROM set, as it scans, and
Total Replay's own `CLRC3ROM` afterwards hands `$C3xx` back to the
internal page - whose bytes are the same, so nothing changes but which
ROM is driving.  Nobody trampolines, nobody is emulating anything: the
card is the 80-column card, with the firmware Apple wrote for it.

**Variant: patch the internal image instead.**  The host loads the
internal ROM too (`mem_rom_loaded`).  Pasting the signature and the stub
into the internal `$C300` page would make the card's page and the
internal page identical, the switch state irrelevant everywhere, and
the signature visible even to software that never sets `$C00B`.  The
cost: the internal ROM is no longer AppleWin's byte for byte (the IIe's
self-test checksums it, and it is the reference the boot bench diffs
against).  Prefer the pristine internal ROM and a separate card page;
the variant is there if the extra 256-byte icache home turns out to be
the hard part.

**Rejected on the way: a trampoline.**  Without the expansion ROM the
page could hand every entry to the internal firmware by `STA $C00A`
placed so the fall-through in the internal ROM is `$C317` (the `$C3FA`
stub's trick), Pascal offsets included.  It works on paper and it is the
worse design: fragile under any firmware change, SLOTC3ROM ends up
clear after the first `PR#3` so the page goes dark again, and it exists
only to avoid an expansion ROM the card can serve for free.

## 4. The services entry

The firmware fills the page and the 2 KB; there is no room for a 6502
routine of ours in slot 3, and none is needed.  Three ways to get a
request across, in the order they should be weighed:

**(a) The SmartPort controller that already exists.**  The hard disk's
slot ROM is a SmartPort HDC (HARDDISK.md), its STATUS `GETDIB` already
answers `STRUDELWORKS SP`, and every call already crosses to the host
(busy-polled EXECUTE port, DMA for the data).  A vendor STATUS/CONTROL
code on unit 0 is a services entry with zero new RTL, a calling
convention every ProDOS programmer knows (`JSR entry / !byte cmd /
!word params`), and a host handler.  Its only cost is that it lives in
the disk's slot, not slot 3.

**(b) A mailbox in the slot 3 page.**  The 80-column firmware never
writes to its own page, so writes to `$C3F8-$C3FF` are free for the card
to latch at `op_commit` (`vidhd_card` already watches writes for
`slot_switches`): a command byte, a buffer address, parameters - posted
to the host as a message.  The host answers INTO THE APPLE'S RAM at the
named buffer, through the hard disk's existing DMA path, and flips a
status byte the caller polls at `$C3F8` (one of the two spare bytes;
VIDHD_ROM is accepted at any time and a 32-bit word lands atomically,
or a two-byte register replaces the ROM bytes there).  New: a message
type each way, ~40 lines in `vidhd_card`, the host handler, and the DMA
reuse.  Latency one stream round trip.  The page's writes are bus cycles
in the closed regime today, fine for something called by hand.

**(c) Device select `$C0B0-$C0BF`.**  A proper register set, no page
tricks - and the one range that collides with an Uthernet II in slot 3,
which is where this thread began.  Not for slot 3; kept for a slot of
its own if a "StrudelWorks card" ever gets one.

Software finds the machine by name, the way 4cade finds an Appletini:
`GETDIB` already says `STRUDELWORKS SP`.  Slot 3 needs no ID string.

## 5. Total Replay without a VidHD

4cade has TWO SHR-card gates today (`src/4cade.init.a`): the VidHD
signature in any slot, and - added by qkumba in 2026 - an Appletini
(`src/hw.appletini.a`), matched like this, slot 7 only:

1. `$C705 == $03` and `$C707 == $00` - the ProDOS block-device ID bytes;
2. the SmartPort entry is `$C700 + ($C7FF) + 3`, called with `STATUS`
   (command 0), unit 0 (the controller), status code 3 (`GETDIB`),
   buffer `$0280`; carry set (any error) = not found;
3. the nine bytes at `$0289` compared with `Appletini`, case-sensitive,
   plain ASCII: the controller's DIB is 8 bytes (device count, 7
   reserved), a length byte, then the 16-character name - so `$0289` is
   the name's first character, and only its first nine are looked at.

The card's HDC passes 1 and 2 today (AppleWin's SmartPort firmware, unit 0
status list built in `hd_card.cpp`) and fails 3 on purpose: its name is
`STRUDELWORKS SP`.  Renaming the controller `Appletini` would pass and is
not on the table - the point is a name of our own.  A small
upstream change - a third name and an ID byte, the Appletini precedent
exactly - makes Total Replay show SHR art with no VidHD signature
anywhere.  That is the "other kind of gating": nothing pretends to be a
card it is not.  It needs upstream acceptance and a release; the
signature works today without anyone's permission, so both coexist for a
while.

## 6. What changes, if chosen

- **host**: `synth_vidhd_rom` becomes a page builder: in slot 3, the
  internal `$C300` page from the ROM image with `$00-$04` and `$F2-$F7`
  replaced; in any other slot today's image (signature + IRQ stub only -
  the Pascal ID in another slot would be believed by Pascal and by
  anything that scans for an 80-column card).  The slot-clash rule
  becomes range-aware (page owner vs device-select owner) so the
  Uthernet II may share slot 3 and its `auto` keeps its slot 3 default
  with the VidHD there (UTHERNET2.md open item 1).
- **firmware**: the c8 select latch (its own module, as `slot_switches`
  promised), the `$C800-$CFFE` mapping term in `apple_mmu`, and the
  card driving those reads on the bus (or serving them on the icache,
  section 3, user's call).  Option 4(b) is new RTL in `vidhd_card` and
  a message type; 4(a) is host-only.
- **tests**, in order: `vidhd_card_tb` - the reset-time ID read
  (`$C305`/`$C307` with INTCXROM clear, SLOTC3ROM set), c8 select on a
  `$C3xx` access, `$C800` answered, `$CFFF` release, INTC8ROM/INTCXROM
  precedence; the boot bench (`sim/boot_tb.sv`, the real ROM from reset)
  with the page in slot 3 - `$C017` bit 7 set after reset, `PR#3` then
  80-column text on the mirror, an IRQ while the page is live, a fetch
  trap on `$C3F4` never firing; on HW Total Replay's SHR art, `PR#3`,
  mb-audit in slot 3.

## 7. Open

1. ProDOS's MACHID 80-column bit: which `$C30x` bytes it reads.  The page
   is the internal one at `$05-$10`, so it should be satisfied whichever
   ROM is mapped; verify from the ProDOS 8 source before building.
2. `$C3F4`: dead by every static test; the fetch trap in the boot bench
   is the dynamic one.
3. `$C800` on the icache (mode 2) or on the bus: the user's call, after
   the slow version boots.
4. Option 4(a) vs 4(b) for the services entry.
