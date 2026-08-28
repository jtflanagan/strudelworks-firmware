# The hard disk: the slot on the card, the disk on the host

Status: **✅ built and simulated; not yet run against hardware.**

A hard disk controller ProDOS can boot from, with the images on the host. The
model is AppleWin's SmartPort HDC (`source/Harddisk.cpp` and its
`firmware/HDD-SmartPort` ROM), the project's reference, split along the seam
this project already has three times over:

- **The card carries what the bus can see** (`rtl/hd_card.sv`): the slot's
  256-byte ROM, and a page of I/O registers of which it answers exactly four
  reads - busy, or the status the host gave it. It does not know what a
  command is.
- **The host carries everything else** (strudelworks-host `src/hd_card.cpp`):
  the register writes it sees in the capture stream - the very bytes
  AppleWin's `IOWrite` receives - the images, and AppleWin's `CmdExecute`.

The one thing neither side can do alone is move a block between the Apple's
memory and an image file, and that is where the soft core being the CPU pays
off: the card stops it and does the transfer over the bus itself.

## What the ROM does

AppleWin's, ported to ca65 with the code left alone (strudelworks-host
`firmware/hdc_smartport.s`; it assembles to exactly AppleWin's binary). The
autoboot ROM sees a block-device signature at `$Cn00`, jumps in, and the
firmware asks the card for a BLK STATUS of drive 1: if there is a disk it loads
block 0 to `$800` and runs it. ProDOS later enters at `$Cn0A` (block calls) or
`$Cn0D` (SmartPort calls), and every call is the same shape: the parameters
are written into a FIFO at `$C0n9` (six bytes, BLK) or `$C0nA` (seven bytes,
SP), and a read of `$C0n0` executes the command and returns the status byte.

```
$C0n0  (r)  EXECUTE, and return status    b7 busy, b6..1 error code, b0 error
$C0n1  (r)  STATUS                        the same byte, again
$C0n2  (w)  command       $00 status $01 read $02 write $03 format; SP ORs in $80
$C0n3  (w)  unit          BLK: DSSS0000 (D = drive, SSS = slot); SP: 0 = controller, 1..
$C0n4/5 (w) memory pointer
$C0n6  (w)  block number low - or the status code, for an SP STATUS
$C0n7  (w)  block number middle
$C0n8  (w)  block number high (SP only: 24-bit blocks)
$C0n9  (r)  image size in blocks, low      (w) the BLK command FIFO
$C0nA  (r)  image size in blocks, high     (w) the SP command FIFO
```

(`n` = slot + 8.) The ROM lives on the host and is **sent to the card** at
start (`HD_ROM`, 64 words): the gateware carries no 6502 code, the firmware
can change without a bitstream, and the host can patch it - `--hd-blk` makes
it a plain two-drive block device for a machine whose ROM will not autoboot a
SmartPort card, exactly AppleWin's `HdcBlockMode2Devices`. Until the ROM has
arrived the card claims nothing, so the slot scan cannot jump into garbage.

## Busy

A read of `$C0n0` is the ROM asking for a command's answer, and the answer is
on the other side of a USB round trip. So the card answers `$80` - busy - and
the ROM's `lda IO_Execute,x / bmi` loop spins on it, exactly as it would on a
real controller with a slow disk, while the CPU runs. When the host's
`HD_DONE` arrives the port reads the status it carried and the loop exits.
The host uses the same edge: the first busy read after a register write is
the EXECUTE, and the first non-busy read is its completion.

**Two things AppleWin never needed.** AppleWin completes every command on the
EXECUTE read itself, so it can treat *every* read of `$C0n0` as an EXECUTE
(of a status command, after the first). This card cannot, because the ROM
polls the same port while it waits - so a read is an EXECUTE only when a
register write (`$C0n2-$C0nA`) has **armed** one since the last EXECUTE, and
a poll otherwise. And the ROM's bootstrap relies on the instant completion:
it issues a BLK STATUS with *no* poll loop and goes straight on to the block
READ. `$80` decodes as "no error" (`lsr; bcs`), so the bootstrap proceeds
regardless and a missing disk is caught by the READ, which does poll - but
the READ's EXECUTE arrives while the STATUS is still busy, and a card that
took every read while busy for a poll would swallow it. So the card counts
EXECUTEs **outstanding** (arming makes them distinguishable), stays busy
until the host has answered the last, and the host answers them in order.
Ordinary drivers poll before their next command and never reach two.

`sim/hd_card_tb.sv` runs that bootstrap shape: the first `HD_DONE` leaves the
port busy, the second releases it with *its* status, and the core is shown
running - not paused - the whole time.

**A host that never answers** - dead, or not running the disk - would leave
the ROM spinning forever. So busy times out at 2 s and the port reads
AppleWin's own "no device connected" status (`$51`): the ROM gives up on the
slot and the machine boots from the next one. The host waits *less* than
that for anything it needs from the card (1 s for a fetch), so a live host
always answers first. The race that leaves: a host stalled for over 2 s
sends an `HD_DONE` the card would take for the answer to the *next* EXECUTE.
An ingest thread stalled that long has overflowed the card's FIFO and lost
the capture already, so nothing was added to protect against it.

## DMA, both ways

The one moment the CPU is stopped. The card raises the driver's override -
the boot hold's mechanism, extended to writes in `apple_bus_write` - with the
address stepping and, for bytes going *in*, R/W low: one bus cycle per byte,
at the machine's own pace, the data driven in the window the core's own write
would use, and the core simply not advanced for exactly those cycles, wherever
in its poll loop it happened to be. 512 bytes is half a millisecond, which is
the same figure AppleWin charges. Every byte moved is a captured event, so the
host's display shadow sees a block land in memory as ordinary writes: a
picture file read straight into `$2000` shows up on the panel.

The card has one buffer and no queue, so an `HD_DONE` or `HD_FETCH` arriving
*during* a DMA would be lost. The host spaces its answers: after an `HD_DONE`
that carries bytes, `HdService::pop_outgoing` holds the next message back for
the time that DMA takes plus a margin. Only the bootstrap ever has two
commands outstanding, and only its first - the STATUS, which carries nothing -
can complete while the second is still owed.

- **Into the Apple** (a block read, or a SmartPort status list): `HD_DONE`
  carries the bytes and where to put them, the card writes them, then completes
  the read with the status.
- **Out of the Apple** (a block write): the host sends `HD_FETCH` naming the
  bytes; the card reads them into its buffer, sends them back as `HD_DATA`, and
  stays busy; the host writes the image and sends the `HD_DONE` that clears
  it. Two round trips, which is still faster than a real drive.

The host refuses a DMA that touches `$C000-$CFFF`, as AppleWin does (its
`memwrite[page]` is null there); the card would drive it. Everything else goes
where the machine's own MMU sends it - a read into language-card RAM lands in
language-card RAM - which is better than AppleWin, not worse.

## The messages

| type | name | direction | payload |
|---|---|---|---|
| `0x18` | HD_ROM | host→card | 64 words: the 256-byte slot ROM |
| `0x19` | HD_DONE | host→card | `free[7:0]` = status. `[0]` = `{count[31:16], addr[15:0]}`, `[1]` = `{0, size[15:0]}`, `[2..]` = the bytes. Header-only = status, no bytes. |
| `0x1A` | HD_FETCH | host→card | `[0]` = `{count[31:16], addr[15:0]}` |
| `0x1B` | HD_DATA | card→host | `free` = count; ⌈count/4⌉ words |

Bytes pack little-endian into words, byte 0 in bits `[7:0]`, as everything on
this link does. `size` is what `$C0n9/$C0nA` read back afterwards - the ROM
reads them after a BLK STATUS, so the host sends the unit's size with every
completion and the card latches it.

`HD_DATA` goes out through `msg_arb`'s application port: an application message of
any length, streamed a word at a time, its length snooped from its own header
so the arbiter knows nothing about the type. Lowest priority of the three - a
130-word block is the one that can make a register reply wait - and once
started it goes out whole, never inside a capture frame
(`sim/reg_map_tb.sv` case 13 checks that).

An `HD_DONE` or `HD_FETCH` arriving with nothing outstanding is consumed and
ignored, so a late one cannot corrupt the status and size a later command
reads back.

## The register

**`HD_SLOT`, `0x8000_0014`** in `rtl/wb_regfile.sv`:

```
[2:0]    desired   RW   the slot the disk answers as; 0 = off
[10:8]   active    RO   what was latched at the last RES' assertion
[16]     rom       RO   the slot ROM has been loaded
[17]     busy      RO   a command is outstanding: the port reads busy
[31:24]  execs     RO   EXECUTE reads taken, wrapping
```

`MB_SLOT`'s contract - slot cards are discovered at boot, so a reset is when
the answer may change - and one more rule: **the two slots may not coincide**.
Both peripherals claim read cycles in their slot's ranges, and two claimants
for a cycle would both drive the bus. The disk yields, latching `active = 0`
when the Mockingboard has the same slot asked for; the host checks the
readback and refuses the clash on its own command line first. Slot 7 is where
ProDOS looks for a hard disk first and is the default.

The slot ROM is gated the way the Mockingboard's page is: `$Cnxx` is
motherboard ROM when INTCXROM is set (and `$C3xx` when SLOTC3ROM is clear),
tracked from the driven ops by `rtl/slot_switches.sv`, which both peripherals
now share. DEVICE SELECT' (`$C0nx`) is not gated by either switch.

## On the host

```
swhost --real --cpu soft --hdv PRODOS.hdv [--hdv MORE.2mg ...] [--hd 7] [--hd-blk]
```

Up to eight images as SmartPort units 1..8 (ProDOS drives 1..4 through the
block entry). `.hdv` and `.po` are raw blocks and grow when written past their
end, as AppleWin's do; `.2mg` honours its header's size and lock flag and does
not grow. A read-only file is a write-protected disk. The host writes
`HD_SLOT`, sends the ROM, and reads the register back for the banner; at exit
it clears `desired`, so a card left behind by a host that quit stops answering
at the next reset rather than stalling every command until the timeout. Then
Ctrl-Reset.

Three threads touch it, on three seams. The **decode** thread runs the
controller in stream order - a command *is* the sequence of writes before its
EXECUTE - and hands each EXECUTE out as an `HdCommand`. The **disk** thread
(`src/hd_service.cpp`, on the general core with the logger and the trace,
because it blocks on files) runs it against the images and queues the answer.
The **ingest** thread, which alone owns the transport, sends it, and hands an
arriving `HD_DATA` back to the disk thread. Nothing is shared but the queues.

## What is deliberately not there

- **AppleWin's 512-cycle busy** after a block moves. The round trip is the
  busy time here, and the same poll loop absorbs it.
- **Reads of `$C0n2-$C0n7`.** AppleWin returns the registers; the card returns
  the floating bus. The ROM never reads them.
- **The v1 firmware's NEXT BYTE port** (`$C0n8` read). The card does not answer
  it; the SmartPort ROM does not use it.
- **`FixupUnitNum`**, which only the v1/v2 firmware needs.
- **A `$C8xx` expansion ROM.** The SmartPort firmware fits in 256 bytes, which
  is why AppleWin's was the right model: nothing here needs the `$CFFF`
  arbitration the Mockingboard also left behind.
- **A mock.** `MockCard` accepts the three messages and answers a fetch with
  zeros, so the host's plumbing is testable; it is never busy and keeps no ROM.
  The card's behaviour is in `sim/hd_card_tb.sv`.

## Verifying it

```
sim/run_hd_card_tb.sh        # card: the real core polling busy, a block in, a block out
sim/run_reg_map_tb.sh        # card: HD_SLOT, and HD_DATA never inside a message
sim/run_boot_hold_tb.sh      # card: the other override still works alongside
sim/lint.sh
```

`hd_card_tb` runs the real core, driver, receiver and arbiter against a bus
model, with the tb as the host: the ROM reads back and follows INTCXROM; an
armed EXECUTE read answers busy at once and the core keeps running; two
commands issued back to back, the bootstrap's way, are both taken and the
first answer leaves the port busy; an `HD_DONE` with 512 bytes pauses the core
and lands them at `$2000` as 512 contiguous override writes before the port
stops reading busy; an `HD_FETCH` reads 512 bytes as 512 unclaimed override
reads and they arrive as one `HD_DATA` with a capture message intact around
it; an unarmed read is a poll; an unanswered command times out with `$51`; a
late `HD_DONE` changes nothing; a RES' while busy drops it and the machine
boots.

In strudelworks-host, `hd_test`: the image formats, the controller's FIFOs and
unit selection against AppleWin's rules, `CmdExecute` on real files (reads,
growth, the I/O-page refusal, the 25-byte DIB with its ID string, every error
code), the message layouts, the disk thread's two-round-trip write and its
timeout, and the mock taking the messages without dropping the link. And
`firmware/build.sh --check`, which proves the committed ROM is its source.

## Bring-up, when it happens

The order that finds the most with the least: `--hdv` an image with
`tools/pi.sh trace out.swbt --reset`, and look for the slot scan reading `$C700`, the FIFO
writes to `$C0FA`, and the poll loop's run of `$C0F0` reads ending in a
status.
The `disk` line at exit says how many EXECUTEs the decoder saw against how many
completed; a gap between them is a command the host did not answer. Nothing here
has been on a wire yet.
