# hw — the CPU-socket carrier board

Nothing here yet. This is milestone 4; see [../docs/DERISK.md](../docs/DERISK.md)
for why it comes after the DDR3 work rather than before.

## This directory is licensed separately from the rest of the repo

The gateware is GPL-3.0-or-later because it links UberDDR3. **A PCB layout is not
a derivative of a Verilog DDR3 controller**, so the board does not inherit that,
and it should not be GPL in any case — the licence is written about software and
its terms map badly onto board artwork.

When the board lands, it gets its own `LICENSE` file in this directory, under one
of:

- **CERN-OHL-S v2** — strongly reciprocal, the hardware analogue of the GPL.
  Consistent with the gateware's copyleft intent. The default choice.
- **CERN-OHL-P v2** — permissive, if wider reuse matters more than reciprocity.

Do **not** apply CERN-OHL to the gateware or GPL to the board. Keeping the two
in separate directories with separate `LICENSE` files is what keeps the boundary
unambiguous. See [../LICENSING.md](../LICENSING.md).

## What goes here

Per `docs/DERISK.md` milestone 4, the carrier is the only new PCB in the project:
an Apple II slot card carrying the Alchitry Au + Ft+ stack, with a 2×20 header to
a ribbon and a DIP-40 plug in the host's CPU socket.

Do not re-derive the connector work — appletini-mega already settled it:

- `~/repos/appletini-mega/docs/cpu_socket_pinout.md` — full 6502 / W65C02S /
  W65C816S pinouts side by side, and the pins whose direction flips between parts
  (DIP 1, 3, 5, 35, 36, 38).
- `~/repos/appletini-mega/components/AppleII/CPUBus_Header_2x20_DIP40/` — a 2×20
  header whose pads are numbered in DIP perimeter order. That numbering is what
  deleted an entire socket-side breakout board; it is worth reusing rather than
  rediscovering.
- `~/repos/appletini-mega/modules/cpu_pinmap.zen` — the pin map as data.
