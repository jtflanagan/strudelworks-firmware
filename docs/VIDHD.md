# The VidHD: a slot ROM on the card, Super Hi-Res on the host

A VidHD is a video card for any Apple II: it snoops the bus, keeps its own
copy of the machine's memory, and outputs HDMI - including the IIgs's
320x200 and 640x200 Super Hi-Res (SHR) modes, drawn from auxiliary memory
`$2000-$9FFF` whenever the IIgs's NEWVIDEO register (`$C029`) asks for
them. Software written for it - Total Replay, 4cade - shows SHR artwork on a
IIe if it finds one. strudelworks is the same shape of thing: a card that
sees every cycle and a host that draws. So a VidHD here is very nearly free,
and this note says which parts go where.

The reference model is AppleWin's `source/VidHD.cpp` (partial VidHD support:
SHR only), and its behaviour is what the two repositories reproduce.

## How software finds one

By reading the slot ROMs. 4cade's `HasVidHDCard` scans `$C700` down to
`$C100` for three bytes, `$24 $EA $4C` - the first three bytes of the real
card's firmware - with SLOTC3ROM set for the duration so that slot 3, where a
VidHD usually sits, is visible past the IIe's own 80-column firmware. AppleWin
does not carry a ROM image at all: its VidHD answers `$Cn00-$Cn02` with those
three bytes and floats the rest.

That is all the bus can see of a VidHD. It has no device-select registers
(`$C0n0-$C0nF`), no expansion ROM (`$C800`), and it never answers a READ of
the IIgs video registers - software that reads `$C029` on a IIe gets the
floating bus, and software written for a VidHD knows not to (4cade's
`PreSHRMode` comment). The WRITES go out on the bus unanswered, as they would
with no card in the machine, and the card watches them.

## What the card does: `rtl/vidhd_card.sv`

A 256-byte slot ROM, and nothing else. The host loads it with VIDHD_ROM (type
`0x23`, 64 words, the whole ROM or nothing - the floppy's rule); the card
answers `$Cn00-$CnFF` reads from it, gated by `rtl/slot_switches.sv` exactly
as the hard disk's and the floppy's ROMs are, so slot 3 is the card's only
while SLOTC3ROM is set and INTCXROM clear. VIDHD_SLOT (`0x8000_006C`) names
the slot with HD_SLOT's contract: written any time, latched at the next RES'
(or a boot-hold release), and it yields to the Mockingboard, the hard disk and
the floppy alike - a clash latches 0, and the host checks the readback.

The card never takes a cycle and never drives one it did not claim. Master
builds only, like every peripheral here: a watching build has nothing to
answer with.

The ROM's contents are the host's business. strudelworks-host synthesises
one - `$24 $EA $4C`, then `JMP $Cn05` to an `RTS` at `$Cn05`, then zeros - so
the signature is there and the bytes are harmless if anything ever executes
them (`PR#3` with SLOTC3ROM set lands on the JMP and returns). `vidhd_rom`
substitutes a dump of a real card's first page, which is only ever the
signature as far as the machine is concerned, since there is no `$C800` space
to reach the rest of it.

## What the host does

Everything visible. The host already holds a mirror of auxiliary memory: the
memory image's MMU shadow (`rtl/apple_mmu.sv`, MEMORY.md) puts every aux write
in image bank 1 with the RAMWRT and 80STORE rules, and the host's own display
mirror (`apple_video.cpp`) follows the same rules from the event stream. SHR
lives at aux `$2000-$9FFF`, all of which is plain RAMWRT territory bar the
`$2000-$3FFF` corner that 80STORE+HIRES can steer. Nothing new is needed for
the pixels to arrive.

The mode register arrives the same way. The sparse capture's keep rule
(SPARSE.md) sends every `$Cxxx` access whatever else it drops, so a `$C029`
write reaches the host's decoder in every capture mode, and the host latches
it - along with `$C022`, `$C034` and `$C035`, which a VidHD accepts and this
one ignores, as AppleWin does. SHR is on when bits 7 and 6 of NEWVIDEO are
both set (enable, linearise), and the host draws the frame at each frame
boundary from its mirror: 200 lines of 160 bytes, a scanline control byte per
line at `$9D00`, sixteen palettes at `$9E00`. The switch between SHR and the
IIe's own modes happens on the next frame, not the next cycle - the beam
renderer keeps walking the legacy picture underneath, so there is nothing to
clear on the way back.

Only auxiliary bank 0 is watched. Software that selected another RamWorks
bank and then drew SHR would be drawing where a real VidHD does not look
either.

## Where the seam is

The card knows the signature; the host knows what a VidHD is. That split is
deliberate: nothing in the gateware would change to render a border colour, a
different SHR variant, or the VidHD's own text modes, and a real card's
firmware page can be tried without a rebuild.
