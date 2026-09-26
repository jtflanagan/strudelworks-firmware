# The Alchitry Pt V2 port

Status: **✅ on hardware, 2026-09-03.** `master_top` built for the Pt
(WNS +0.136 / WHS +0.059, 17.6k of 63.4k LUTs, 53 of 135 BRAM tiles), flashed,
and run against the live Apple with swhost on the Pi: FT601 link at SuperSpeed,
DDR3 ring, event capture (8k events in the first 8 s), every register readback
(build stamp, ring, CPU source, accel, slots) - all on the relocated pins.
The one lesson of the bring-up is below under "flash first".

The card moves from the Alchitry Au V2 (Artix-7 XC7A35T, ftg256) to the
Alchitry Pt V2 (Artix-7 XC7A100T, fgg484).  Same carrier (AppleTini v5.2),
same Ft+ V2, same connector side.  This note records what the port is, how the
pin map was derived so it can be re-derived, and what has to be checked on the
bench before the first Pt build is trusted.

## What changes, and what does not

| | Au V2 | Pt V2 |
|---|---|---|
| Part | `xc7a35tftg256-2` | `xc7a100tfgg484-2` |
| Oscillator | 100 MHz, pin N14 | 100 MHz, pin W19 (MRCC) |
| DDR3 | MT41K128M16JT-125, bank 15 | **same device**, bank 15, different balls |
| Flash | QSPI | 32 Mbit QSPI |
| USB | FT2232HQ: ch A JTAG, ch B UART (0403:6010) | **same** |
| Connectors | DF40, V2 pinout (A3..A78, B3..B78) | **same pinout, both sides**; we use the top side only |
| Multi-voltage bank | bank 34 = B51..B78 | **bank 13 = B33..B78** |

Nothing in `rtl/` changes.  `clk_gen.v` starts from the same 100 MHz;
`ddr3_wrapper.sv` pins the same MT41K128M16 geometry and timing (the Labs Pt
MIG project is the Au project with a different part and different pins,
verified by diff); bank 15 is an HR bank on both, so `ODELAY_SUPPORTED = 0`
and the 90-degree clock stay.  The board's on-board USB is the same FT2232H, so
`load.sh`, `report.sh` and the UART all carry over.

What does change is every `PACKAGE_PIN`, and the build's idea of the part.

## How the pin map was derived

The Ft+ and the carrier are wired to **connector pins** (A41, B33, ...), and
the Alchitry V2 connector pinout is the same on the Au V2 and the Pt V2.  So
the port is a lookup: connector pin -> FPGA ball, from each board's table.

The tables are Alchitry's own.  Alchitry Labs V2 (the IDE) carries them as
Kotlin enums, `hardware/pinout/AuV2Pin.kt` and `PtV2TopPin.kt`; those were
extracted verbatim into
`ref/alchitry_*_pins.tsv` (commit 3f13eb9 of Alchitry-Labs-V2).  The DDR3
pins come from the same source's `library/cores/mig_pt_v2.prj`, copied to
`ref/mig_pt_v2.prj`, the same way the Au's came from the v5 MIG project.

The existing Au XDCs were then turned *back* into connector names using the
Au V2 table (`constr/pins/*.pins`), and the per-board XDCs are generated from
those (`tools/gen_pin_xdc.py`, `tools/gen_ddr3_xdc.py`).  Checks that hold,
all by script on 2026-09-03:

- The regenerated **Au V2** constraints are property-for-property identical
  to the hand-maintained ones they replace (350 `PACKAGE_PIN`/`IOSTANDARD`/
  `SLEW`/`IN_TERM` properties across the four files), so the Au build is unchanged by the port.
- `constr/pins/ft601.pins` is pin-for-pin identical to Alchitry's own
  `ft_plus_v2.acf` (the Ft+ V2 element definition).
- The Pt DDR3 pins in `ref/mig_pt_v2.prj` agree with `PtV2TopPin.kt` on all
  48, and all 48 are in bank 15; the Au's agree with `AuV2Pin.kt` and with
  the MIG-generated XDC.
- Every ball the Pt constraints use exists on `xc7a100tfgg484` in the bank
  the Labs table says (checked against Vivado's package-pin database), and
  the two clock inputs land on MRCC pins: the oscillator on W19
  (`IO_L12P_T1_MRCC_14`) and `ft_clk` on H4 (`IO_L12P_T1_MRCC_35`, via A41).
  The FT601 clock goes through an `IBUF` + `BUFG` (`rtl/ft_clk_buf.v`), which
  needs a clock-capable pin; it has one on both boards.

`build/build.sh` runs both generators' `--check` before every build, so a
stale or hand-edited XDC fails the build rather than placing pins arbitrarily.

## Bank 13's VCCO

(The card is a production Pt V2.  Alchitry Labs also carries a table for the
pre-production "alpha" units, whose B connector is routed differently; that
table is deliberately not in this repo.)

The nine Apple-bus signals in bank 13 work - the capture ran against the live
machine - so VCCO is 3.3 V as reasoned below.  The reasoning stays, because a
carrier revision that ties either VBSEL pin would take exactly those nine
signals with it, and nothing in the build can notice.

**Bank 13's VCCO.**  On the Pt V2 the multi-voltage bank is bank 13, which
is B33..B78 - and this design's `apple_addr_pin[13..15]`, `apple_rw_pin`,
`apple_res_pin`, `apple_irq_pin`, `apple_rdy_pin`, `apple_dma_pin` and
`tini_5v_pin` sit on B33..B45.  On the Au V2 those same connector pins were in
fixed 3.3 V banks.  Bank 13's VCCO is selected by two control-header pins,
VBSEL A (pin 38) and VBSEL B (pin 40):

| VBSEL A | VBSEL B | VCCO |
|---|---|---|
| floating | floating | 3.3 V |
| low | low | 3.3 V |
| low | high | 3.3 V |
| high | low | 1.8 V |
| high | high | 2.5 V |

The AppleTini v5.2 carrier connects nothing to J2-38 (its net is named `VBSEL`)
or J2-40 (named `+2.5V`, after the Pt schematic draft it was drawn from, where
pin 40 was a 2.5 V output; on the production Pt it is VBSEL B).  Both are
single-pad nets in the production netlist, so both float and bank 13 comes up
at 3.3 V, which is what `LVCMOS33` on those pins needs.  The generated
`constr/pt_v2/apple_bus_pins.xdc` marks every bank-13 pin with a comment to
that effect.  **Measure VCCO on bank 13 before connecting the Apple**: if a
future carrier revision ties either VBSEL pin, those nine signals are the ones
that stop working.

## Building and loading

```sh
build/build.sh --master                    # Pt V2 (the default)
build/build.sh --master --board au_v2      # the Au, as before
build/load.sh build/results/master_top.bit # board read from master_top.board
```

`build/build.tcl` writes `<top>.board` beside every bitstream; `load.sh` reads
it to pick the loader arguments (`-b alchitry_au` on the Au; openFPGALoader
0.12 has no Pt definition, so `-c ft2232 --fpga-part xc7a100tfgg484` on the
Pt, the same cable and the part whose spiOverJtag bridge it ships).  The
IDCODE check in openFPGALoader refuses a bitstream for the other part.

## Flash first - the first Pt load MUST be a flash, not an SRAM load

Proven the hard way on 2026-09-03.  Three JTAG SRAM loads of `master_top` in a
row (fresh board, then a reload with the Apple off, then one with it on) all
came up looking healthy on the UART - clocks locked, `D=1` DDR3 calibrated,
BUS_ENABLE from the host taken (`E=1`), phi0 seen (`P=1`) - and were all
wedged the same way: the TX ring held **one line from the moment of
configuration** (`R=000001`) that never drained, so not one register reply
reached the host ("firmware: unknown", every slot readback unknown), and the
capture overflowed at 2048 events (`O=1`) with the host seeing zero.  The
ring's first DDR3 write is never acked: it is the Au's documented cold-JTAG
DDR3 problem (README.md, docs/DERISK.md) wearing a different face.

    openFPGALoader -c ft2232 --fpga-part xc7a100tfgg484 -f build/results/master_top.bit

and the reset openFPGALoader issues after flashing brought it up clean:
`R=000000 L=0`, every readback answered, events flowing.  A power cycle was
not needed.  SRAM loads after that are expected to work, as on the Au.

The bitstream properties were first `CONFIGRATE 33`, `SPI_BUSWIDTH 1`, the
ones proven by flashing the Au V2.  Since 2026-09-25 they are Alchitry Labs'
`66` and `4` for both boards (`constr/pins/board.pins`), which depends on the
flash being the SST26VF032BA (docs/BOOT_LOADER.md, "The flash"); proven on
the Pt the same day (GS build x4cfg1, stamp 20260925 211711: booted from flash
in x4, link up, System 6 to the Finder).

## Left for later

- `constr/ft601.xdc` constrains only `ft_rxf`/`ft_txe` as inputs; the 32
  `ft_data` and 4 `ft_be` inputs have no input delay on either board
  (check_timing reports 50 input ports without one).  Measured on the routed
  Pt design with the same 6.5/7.0 ns numbers the two constrained inputs use:
  setup slack +2.06 ns, hold +4.77 ns (Au: +2.49 / +4.29), so they are fine,
  but they are fine by luck of placement, and the constraint should be added.
- On the 35T, Vivado had been silently demoting two `sync_fifo` memories
  (`bus_event_capture` `fq`, 2K x 32, and `tx_ring` `u_stage`, 256 x 128) to
  LUT RAM despite `ram_style = "block"`: synth log "[Synth 8-5835] Resources
  of type BRAM have been overutilized. Used = 106, Available = 100."  That
  cost ~2.1k LUTs of memory plus ~460 of read mux and put the Au at 97 % LUT
  fill.  On the Pt they are block RAM (49 -> 53 tiles) and the netlist is
  what the RTL says.

## What the 100T buys

The design fit the 35T at 49 of 50 BRAM tiles (`docs/PAGE_CACHE.md`), with
the microcode pushed into LUTROM and the two floppy drives sharing one track
buffer to make it fit, and `docs/CXXX.md` banks the switch port, the
language-card write path and the streams "until the larger FPGA card
arrives".  The 100T has 135 BRAM tiles and 63k LUTs against the 35T's 50 and
20k.  None of that is spent by this port - it is the same netlist on a bigger
die - but it is what the port is for.

## Files

```
tools/boards.py                    the board table: part, pin table, MIG project, MV bank
tools/gen_pin_xdc.py               constr/pins/*.pins -> constr/<board>/{board,ft601_pins,apple_bus_pins}.xdc
tools/gen_ddr3_xdc.py              ref/mig_*.prj     -> constr/<board>/ddr3.xdc  (now per board)
ref/alchitry_{au_v2,pt_v2}_pins.tsv   connector pin -> ball, bank (from Alchitry Labs V2)
ref/mig_pt_v2.prj                  the Pt's DDR3 wiring (from Alchitry Labs V2)
constr/pins/{board,ft601,apple_bus}.pins          the connector-named sources
constr/{au_v2,pt_v2}/              generated, committed, --check'd on every build
constr/ft601.xdc, apple_bus.xdc    board-neutral timing / false paths (pins removed)
build/build.tcl, build.sh          -board / --board, part from the board, constr/<board>/
build/synth_ooc.tcl                -board, same table
build/load.sh                      loader arguments from <bitstream>.board
```
