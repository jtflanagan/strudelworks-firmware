# The boot loader: one image that can replace itself, and the DDR3 fenced out of boot

Status: **2026-09-25, branch `boot_loader` (from fw master 9ddb33d / host master 758bbe7). BL1 DONE in
simulation (`flash_exec`, 25 checks, 8/8 mutants). The golden image was built (TIMING MET) and then
DROPPED by the user the same day - see "History". BL2 ON HARDWARE 2026-09-25: GS build `gs_bl2a` TIMING
MET (28,898 LUTs), flashed over JTAG with its record; identify / QUERY / READ / LINK_RESET (IPROG, the
FT601 re-enumerating) all work over USB3. `suite quick` 36/36, `suite gs` 18/18.** The design was settled with the
user on 2026-09-25; this records the decisions and the order of work. It extends REQ_65C02.md 1.10
(a DDR3-free boot path), which applies to both cards (REQ_65816.md 1.10).

## Why

- **Every bring-up worries about the DDR3.** Starting the link, reading a register, loading the ROM, and
  now reflashing the card all turn out to lean on a calibrated, healthy DDR3 somewhere. The user's
  requirement (2026-09-25): the DDR3 is fenced off. It takes part only after bootstrap is done and the
  design has been allowed into full operation. Nothing the card needs in order to be reached,
  diagnosed, reset or reloaded may depend on it.
- **Loading an image needs the second USB cable.** Today a bitstream goes in over JTAG through the
  Alchitry's FT2232 into the FPGA's configuration memory, and is lost at power-off
  (memory `pi-reboot-wipes-bit`). The user wants users to be able to load different images at runtime
  (for example switching between the 65C02 and 65816 cards) over the FT601 USB3 link alone.
- **A reset should spare nothing.** The link reset today deliberately spares the DDR3 controller
  (`card_link.sv:668-671`: "a watchdog expiry or a host 'R' must not cost a recalibration"), so a wedged
  controller survives it. When something is wrong we do not know what, and we have no way to
  diagnose it, so the reset must put everything back.

## Principles (the user's, 2026-09-25)

- **One image in flash, at address 0.** Every image carries the means to replace itself.
- **Two stages, in order, each advanced by the host.** Nothing advances on its own.
- **The card never times out waiting for the host.** The card is powered from the Pi's USB3 and
  configures long before a cold-booting Pi can talk to it.
- **We know what is in the flash, so a start reloads nothing it does not need to.** Pushing the bit
  on every swhost start was a workaround for not knowing what was already there.
- **Once in full operation, all messaging may ride the DDR3 ring.** A wedge is not detected on the
  card: the host notices that the card's heartbeats have stopped and sends LINK_RESET.
- **LINK_RESET is a full reset, sparing nothing.**
- **Development loads go in over JTAG, into flash** (not SRAM), because JTAG works however broken
  the card is. The USB3 path is for user-level image loads at runtime.
- **JTAG is the recovery path of last resort, and it needs no special equipment:** it is the
  Alchitry's ordinary USB cable, plugged into the Pi, driven by the host software. Slow is fine.
- **The flash protocol is versioned and additive.** Any image must be able to load any other, so the
  flash block's registers and FLASH_PAGE are defined once, may change while this is fleshed out, and
  after release only grow. The host refuses a package whose protocol version it does not speak.
- **RES' is not cared about until stage 2 asserts control.** It may glitch during FPGA resets on the
  prototype; accepted until the deadman hardware exists.

## The boot, stage by stage

```
 power-on / LINK_RESET / watchdog
        |
        v
 STAGE 1  bootstrap, in the image       link + registers on the boot lane; the flash block;
        |                                DDR3 calibrating; the Apple held; waits forever
        |  host: identify.  Not the wanted image?
        |     validate the package, ERASE, pages stop-and-wait, QUERY (the flash's CRC against
        |     the record), LINK_RESET, reconnect, check the build stamp -> stage 1 of the new image
        |  host: read calibration.  Failed -> stop, tell the user, the user decides.
        |  good: OPERATE
        v
 STAGE 2  full operation                ROM push, ring engaged, capture, RES' released;
                                         all messaging rides the DDR3 ring
```

Every reset of every kind lands in stage 1 of whatever image is in flash.

**A FAILED LOAD IS UNRECOVERABLE OVER USB3 (the user, 2026-09-25): the fallback is a JTAG load, and
nothing tries anything cleverer.** The old image does keep running while the flash is rewritten (the
FPGA never reads its flash after configuring), but no path relies on that: once ERASE has run, the
flash holds no valid image until a good QUERY, and a load that stops in between - a failed page, a
killed host, a power cut - is recovered over JTAG (below).

**RECONFIGURATION DROPS THE LINK.** After LINK_RESET every FPGA pin floats (PUDC_B is strapped high)
until the image is up again, and the image pulses the FT601's RESET# for 1 ms, which re-enumerates it.
The host expects the loss: it closes, waits, reopens, and speaks first (silent-until-asked). Then it
reads `BOOT_ID` and the build stamp, and for a load compares the stamp with the record it verified.

### Stage 1: bootstrap

The image comes up as today's card does before the host engages the ring: every register answers on
the ring's **boot lane** (TX_RING.md), the DDR3 calibrates on its own, the soft core is held
(`start_hold`). The flash block (below) is in `card_link`, beside the register file, and depends on
nothing but the link. The host reads LINK_STAT / RING_STATUS / DDR3_DBG1..4; if the DDR3 has not
calibrated, nothing proceeds: the host tells the user and waits for the user's decision. It does not
exit (today `start()` fails and swhost stays down, `pipeline.cpp:1827` -> `main.cpp` exit 1).

### Stage 2: full operation

One host-driven transition, OPERATE, entered only after calibration has been read good: the ROM push,
the ring engage (`RING_CTRL`), BUS_ENABLE, telemetry, and the START release that lets RES' go. From then
on every card->host word rides the DDR3 ring.

The ROM push moves here from before the calibration check. It needs the DDR3 by its nature (the ROM
lives in the image: `rom_loader.sv:170`, `pw_valid = draining && image_ready && in_window`, and
`image_ready = calib_complete`, `page_client.sv:116`), and the host pushes it today before checking
calibration (`pipeline.cpp:1715` vs `:1827`), so an uncalibrated card burns every ROM retry first.

### LINK_RESET: a full reset

LINK_RESET (0x01, already decoded in `ft601_msg_rx` as the header is taken) becomes ICAPE2 IPROG with
WBSTAR = 0 (`rtl/common/iprog.sv`): the FPGA reconfigures from flash, and every register, RAM, MMCM and
the DDR3 controller start as at power-on. The link watchdog's expiry (a host that went silent
mid-capture) takes the same path. The link's two self-recoveries - a CLKOUT that never came back and a
TX side that stopped - keep today's 1 ms soft reset of the link: reconfiguring on them would loop
every half second (and recalibrate the DDR3 each time) while a Pi boots with the FT601 dark.

Cost: about 0.55 s of configuration (2.2 MB at 33 MHz x1) plus calibration. Every swhost start already
is a reset (memory `start-then-reset`).

## The flash block

`rtl/common/flash_ctrl.sv` (it was `rtl/golden/golden_ctrl.sv`) in `card_link`, a second slave beside
`wb_regfile` on the register bus: the addresses 0x8000_0E00-0x8000_0FFF are its, everything else the
register file's (whose read data and ack are flops, so the 2:1 after them is not on its read path).

| Address | Name | |
|---|---|---|
| 0x8000_0F00 | BOOT_ID | RO `{0x424C "BL", protocol version, stage}` |
| 0x8000_0F04 | BOOT_PART | RO the IDCODE the image was built for; a package must match it |
| 0x8000_0F08 | FLASH_CMD | W start a command `[3:0]`; reads back the last |
| 0x8000_0F0C | FLASH_ADDR | RW READ's address |
| 0x8000_0F10 | FLASH_LEN | RW ERASE's bitstream length, READ's length |
| 0x8000_0F14 | FLASH_STAT | RO `[0]` busy `[1]` verified `[4:2]` executor error `[11:8]` result `[23:16]` commands finished |
| 0x8000_0F18 | FLASH_PAGES | RO `[15:0]` pages programmed `[31:16]` pages refused |
| 0x8000_0F1C | FLASH_ID | RO the JEDEC ID (read at reset) |
| 0x8000_0F20 | FLASH_CRC | RO the CRC32 of the last read (zlib's) |
| 0x8000_0F24/28 | IMAGE_END / REC_ADDR | RO the layout |
| 0x8000_0F40+ | REC[0..15] | RO the record as the last QUERY read it |
| 0x8000_0E00+ | BUF[0..63] | RO the executor's 256-byte buffer |

Commands: 1 ID; 2 QUERY - read the record at REC_ADDR (magic, version, its own CRC, the part), then the
bitstream from 0 for the record's length, and compare its CRC32 (about 0.5 s for 2.2 MB); 3 ERASE -
unlock, erase the record's block FIRST, then the blocks covering FLASH_LEN bytes from 0; 5 READ -
FLASH_LEN bytes from FLASH_ADDR into the CRC, the first 256 into BUF. Results: OK, EXEC, NO_RECORD,
RECORD_CRC, IMAGE_CRC, BAD_PART, BAD_ARG, PAGE_REFUSED, BUSY.

FLASH_PAGE (host -> card, 0x40, len 65): `[flash address] [64 words, little-endian bytes]`, programmed
when it arrives if nothing runs, else refused and counted. The host sends one and reads FLASH_PAGES
until a count moves: stop-and-wait, so the receiver's lack of back-pressure (`ft601_fifo.sv`, "The
receiver is assumed never full") never matters, and no new card->host message type is needed (memory
`new-message-types-need-routing`). Any ERASE or page clears `verified`.

## The flash

The part is a Microchip **SST26VF032B** on both the Au V2 and the Pt V2 (4 MB; JEDEC ID `BF 26 42`;
Au from Alchitry's forum and their loader, Pt from the SST26 pin names on U3 in the Pt schematic;
the image reads the ID at reset anyway). Datasheet DS20005218E.

- **It powers up write-protected.** Its block-protection register is volatile and resets to "all
  write-locked" (`5555_FFFFFFFF_FFFFFFFF`; the datasheet's footnote prints a third word). An erase or
  program aimed at a locked block is ignored (5.18). ERASE unlocks with `WBPR 42h` and confirms it with
  `RBPR 72h`.
- **Every erase costs about the same:** sector (`20h`, 4 KB), block (`D8h`: 8 KB x4 then 32 KB at the
  bottom, 64 KB x62, 32 KB then 8 KB x4 at the top) and chip (`C7h`) are 18 / 18 / 35 ms typical. ERASE
  walks the real block map with `D8h`: a 2.2 MB image is about 40 blocks, under 1 s. Chip erase is
  never used.
- **Programming is the floor:** 256 B pages at 55 us + 3.75 us/byte, about 1 ms per page; a 2.24 MB
  Pt image is about 9 s.
- `03h` read is limited to 40 MHz; the executor runs clk/4 (25 MHz) and samples MISO late, at the end
  of SCK's high phase, because SCK leaves through STARTUPE2 with some ns of delay.
- In x1 SPI, D02 is WP# and D03 is HOLD#: driven high.
- CCLK is reachable only through STARTUPE2 `USRCCLKO`; the first 3 clocks after configuration are
  swallowed (the executor sends 8). FCS_B and D00-D03 are ordinary user I/O after configuration (Pt:
  FCS_B T19, D00-D03 P22 R22 P21 R21, from Alchitry Labs' PtV2TopPin.kt; `constr/pt_v2/flash_pins.xdc`).

### Layout

```
0x000000              the bitstream (Vivado's raw .bin), up to IMAGE_END
0x3FF000 - 0x3FFFFF   the record (one 4 KB sector in the top 8 KB block; the rest of it FF)
```

The record cannot sit in front of the bitstream: configuration reads from address 0 and scans for the
sync word, and arbitrary record bytes there are a risk nobody needs. At the top it is written LAST by
both writers, so a load that stops early leaves no valid record - ERASE clears it first. The whole
flash below it is the image's: even an uncompressed 100T bitstream (3.8 MB) fits.

### The record and the package

The record's 64 bytes (little-endian words): `w0` magic 0x4B525753 ("SWRK"), `w1` record version 1,
`w2` bitstream length, `w3` its CRC32, `w4` IDCODE, `w5` `[7:0]` board `[15:8]` machine, `w6` the flash
protocol version, `w7` BUILD_DATE, `w8` BUILD_TIME, `w9..w14` zero, `w15` CRC32 of `w0..w14`.

The build emits a package beside the `.bit`: the record, then the bitstream, as one file for
distribution. The host validates it before ERASE (the part against BOOT_PART, the protocol version, the
record's CRC, the bitstream's CRC, the machine against the swhost conf it will restart with - memory
`name-the-conf`), writes the bitstream at 0 and the record at REC_ADDR.

### Writers

- **Development and recovery (JTAG):** openFPGALoader, two writes in order: the bitstream at `-o 0`,
  then the record at `-o 0x3FF000`. Read in openFPGALoader v0.12.0's source (sibling clone
  `~/repos/openFPGALoader`): `-o` passes to the flash write (`src/xilinx.cpp:689-696`); a flash write
  of a `.bin` is raw, not bit-reversed (`xilinx.cpp:579-580`); it erases only the written range, in
  4 KB sectors, because its SST26 entry has block erase off (`src/spiFlashdb.hpp:250-261`,
  `src/spiFlash.cpp:182-235`); it sends the global unlock first (`spiFlash.cpp:356-363`); afterwards it
  resets the FPGA, which boots the image. Expect 30-40 s. Slow is fine.
- **User loads (USB3):** the image's own flash block: ERASE under 1 s, about 9 s of pages, 0.5 s QUERY.

### Recovery

- A USB3 load that fails for any reason, or an image that configures but cannot reflash itself:
  JTAG, with the ordinary Alchitry USB cable (from the Pi, in the finished product).  No retry
  path, no resynchronisation: a host killed mid-message would leave the card's parser inside
  that message, and LINK_RESET - the only framing recovery - boots the half-written flash.  That
  is accepted, not worked around.

## RES' and the deadman

The prototype cannot hold RES' through an FPGA reconfiguration; glitches during resets are accepted.
The planned deadman hardware: a MOSFET holds RES' low from the moment the Apple powers on, until the
FPGA actively releases it with a GPIO driven high. The deadman input is pulled down (it must work with
the 3V3 rail dead), and PUDC_B is strapped high on the board (verified by the user), so every user pin
floats during configuration and the deadman holds. The release is a static level; a toggling release
was considered and rejected as overkill. Power-on and IPROG leave the pin unconfigured (held); stage 1
never drives it; OPERATE's START release drives it high. A future snoop-capable card needs a different
class of support: most likely a board jumper that disables the deadman.

## What exists today (audit, 2026-09-25, on master)

Already DDR3-free on the boot lane: the FT601 controller, both async FIFOs, the RX parser, `reg_bridge`,
`reg_front`, `wb_regfile`, the notices, `start_hold`, the telemetry sweep, DDR3_DBG1..4 and the eye
registers, the slot ROMs in LUTRAM.

Leaks and conflicts this plan removes:

1. **The ROM push needs the DDR3** and runs before the calibration check (stage 2 above).
2. **An engaged ring never lets go except by reset;** a `RING_CTRL=0` write reads back 0 but the ring
   stays engaged (`tx_ring.sv:303`, `wb_regfile.sv`). Only a reset leaves stage 2 now, so a
   disengage write should be refused loudly rather than silently ignored.
3. **The link reset spares the DDR3 controller** (`card_link.sv:668-677`). LINK_RESET = IPROG supersedes it.
4. **`clk_ctrl` is CLKOUT0 of the DDR3's MMCM** (`clk_gen.v:89`). DDR3 clocking work moves the clock
   the link runs on; the control plane should get its own clock from the 100 MHz oscillator.
5. **The host has no way to stay up without the DDR3,** and the mock always reports calibrated
   (`mock_card.cpp`), so the uncalibrated path is never tested.
6. **Stale comments** say every word rides the ring with no path around it: `card_link.sv:26-31`,
   the `rom_loader`/`page_client` notes on where memory lives, `docs/UBERDDR3.md` ("answers no
   register"), `docs/TX_RING.md` (the UART), REQ_65C02.md 1.10 ("Today this is not so").

## What this changes elsewhere

- **Booting's semantics change** (user, 2026-09-25). CLEAN_START.md's principle "A recovery never needs
  a reload or a power cycle" is reworded there: LINK_RESET *is* a reload, from flash, by the card
  itself; what stays is that no recovery needs a human or a second cable.
- **CLEAN_START.md CS1's "a IIe with no host still runs on its motherboard"** dates from the
  snoop-only testing days and was already overridden by that document's decision 3. It is marked there
  as a development heuristic.
- **CLAUDE.md, `build/load.sh`, `build/load_card.sh`, the `fw-load` skill:** "SRAM, volatile" becomes a
  flash write of the bitstream and its record (BL3). `load.sh` has `FLASH_OFFSET` already.
- **The card survives a Pi reboot** once flashed (memory `pi-reboot-wipes-bit` goes stale).

## Rungs

Each rung is explained before it runs; a bench failure is a finding; a bitstream that misses timing
stops the work.

- **BL0 - this plan** and the REQ_65C02.md 1.10 amendment. Done, fw 6c1c2ed; revised for one image.
- **BL1 - the flash executor, in simulation.** **DONE 2026-09-25 (sim), fw 609ba2e.** `flash_exec`
  runs OP_ID / OP_UNLOCK (WBPR then an RBPR compare) / OP_ERASE / OP_PROG / OP_READ (CRC32 = zlib's,
  first 256 bytes into the buffer), with its own address fence, eight dummy clocks after reset, and
  every BUSY poll bounded. `sst26_model` is written from the datasheet and strict: protection, WEL,
  BUSY, whole-byte commands, 40 MHz reads, HOLD#/WP#. The bench: 25 checks including "123456789" ->
  CBF43926, a stuck BUSY -> E_TIMEOUT, a dropped WBPR -> E_BPR. Mutants killed: 8 of 8. Since: MISO is
  sampled late (STARTUPE2's delay), the page buffer is four 64 x 8 LUTRAM lanes (it had been 6.5k
  LUTs of flops), and the block map is the chip's real one (the whole flash is now the image's).
- **BL2 - the flash block in the card.** `flash_ctrl` + `iprog` in `card_link`, STARTUPE2/ICAPE2, the
  flash pins on the tops, LINK_RESET and the watchdog to IPROG, FLASH_PAGE a card type, `BOOT_ID`.
  `flash_ctrl_tb` (golden_tb's checks, moved). A Pt build of a card. On hardware: the image and its
  record written over JTAG; `swboot identify` / `query` / `read`; `swboot reset` reconnects to the
  same image.
  **DONE 2026-09-25 on hardware** (fw build `gs_bl2a`, stamp 20260925 162826, TIMING MET, 28,898
  LUTs). `flash_ctrl_tb` 18 checks. `tools/mkpkg.py` made `.bin` / `.rec` / `.pkg`; openFPGALoader
  wrote the 2,766,884-byte image at 0 (about 90 s with --verify) and the record at 0x3FF000. Then,
  over USB3 with `swboot` on the Pi: FLASH_ID `bf2642` - the Pt V2's flash IS the SST26VF032B,
  until then inferred from the schematic - and the SPI path through STARTUPE2 works; QUERY before
  the record: NO_RECORD; after it: OK, the card's CRC of the whole image matching mkpkg's
  (`ed6a7453`), 0.91 s round trip; READ of the record back byte for byte; LINK_RESET: the Pi's
  kernel logged `USB disconnect, device number 4` then `new SuperSpeed USB device number 5` 0.35 s
  later, and `swboot` reconnected on its first try to the same stamp. LINK_RESET no longer pulls
  the soft reset, so the re-enumeration is the reconfiguration's. swhost on this image (the
  Pi's swhost is master's, byte for byte): with `gs_nox.conf` the IIgs boots fine (the user's
  check). A first run with a conf derived from the stale `gs_swhost.conf` came up broken - wrong
  graphics, constant noise, no keys - because it crossed swhost's behaviour for one soft core with
  the bit's for the other; that was the conf, not the image (memory `conf-must-match-the-bit`).
  Nox, though, was broken on this image - and on master's since 60f485c, the 65816 binding-loop
  retime (bisected; docs/CORE_REFACTOR_65816.md Status). The retime is reverted on this branch;
  the flashed image is now `gs_unretime1` (stamp 20260925 171833, TIMING MET), and Nox's title and
  menu are right.
- **BL3 - the package and the development load.** `build.sh` writes the record and the package;
  `load.sh` / `load_card.sh` write the bitstream and then the record into flash by default; the
  `fw-load` skill follows. openFPGALoader's time measured.
  **DONE 2026-09-25 on hardware, except the build-side packaging, which runs at the next build.**
  build.tcl writes `<bit>.stamp` beside `.board`; `tools/mkpkg.py` reads it by default (else
  `--stamp`, else `--log`); `run_build.sh` runs mkpkg after every card build. The JTAG load
  script writes the flash by default - the image at 0, then `<bit>.rec` at 0x3FF000, both with
  `--verify` - refuses a bit with no record before touching the board, and keeps `--sram` for a
  volatile load; `load_card.sh` passes `--sram` through; the `fw-load` skill and CLAUDE.md say
  so. Measured: **93 s** for both writes of the 2.84 MB GS image (`gs_unretime1`); then swboot
  identify (stamp 171833) and QUERY OK. After any JTAG load the first swhost start leaves the
  native 6502 driving; the second latches the soft core (pre-existing, noted in the skill).
- **BL4 - the user load over USB3.** `swboot load` + `swboot reset`: switch between a IIe and a GS
  image and back.  (A killed load is JTAG's - the user, 2026-09-25 - so there is no retry to test.)
  **DONE 2026-09-25 on hardware.** With swhost
  stopped, over USB3 alone, `swboot load PKG --reboot` on the Pi: GS -> IIe (`bl4iie`, stamp
  174631, TIMING MET): ERASE 805 ms, 9,882 pages in 15.1 s (~1.5 ms each with the round trip),
  QUERY 809 ms, LINK_RESET, reconnect, stamp confirmed - 18.2 s in all; then swhost on the user's
  IIe conf (now `machine = iie`) reached Nox's map with the Mockingboard playing (the user's
  check). IIe -> GS (`gs_unretime1`, stamp 171833): 20.3 s, the same shape, and System 6 up.
  Found on the way: run_build.sh's packaging compared the bit against the log's mtime, which is
  always newer (the log is appended to the end); it compares against the build's start now.
- **BL5 - swhost's start.** identify -> compare with the conf's image -> load if needed -> reconnect;
  reconnect after LINK_RESET as an expected loss.
  **DONE 2026-09-25 on hardware (host).** The conf key `image = PATH.pkg`: at start, before any
  session or reader thread, swhost asks the card for BOOT_ID and its stamp; the same stamp as the
  package's record is `image : ... is the image in flash`; a different one is loaded over USB3,
  LINK_RESET, reconnected, the new stamp checked, `image : ... LOADED over USB3: erase / program /
  query ms`, and the start carries on.  Refused before anything is written: a package for the
  other machine than the conf's `machine` (`... is a IIe image and the conf says machine = iigs`),
  another part, no room, an image without the flash block.  The host's flash code is one file,
  src/flash_boot.{hpp,cpp}, shared with swboot.  On the Pt: GS in flash -> no load; the crossed conf
  refused; the IIe package loaded by swhost itself (program 15.2 s) and Nox came up; the GS package
  loaded back and System 6 came up.  Still true after any new image: the first start leaves the
  native 6502 driving and a second start latches the soft core.
- **BL6 - the stage 1 / stage 2 fence.** The host: calibration read before anything that needs the
  DDR3, OPERATE as one step, stay up and report on a failed calibration, the mock's uncalibrated mode.
  The card: a `RING_CTRL` disengage write refused loudly; BOOT_ID's stage 2 after OPERATE.
- **BL7 - the control clock off the DDR3's MMCM.**
- **BL8 - the deadman release,** when the hardware exists.

## History

- **The golden image (2026-09-25, dropped the same day).** The first design had a separate golden
  bitstream at flash 0 - link, registers, flash executor, IPROG, nothing else - that always booted
  first, waited for the host, and IPROGed to the user image. Built for the Pt (`golden_bl2c`): TIMING
  MET, 1,833 LUTs, and a 1.27 MB compressed bitstream. A compressed Artix bitstream drops only
  frames that are wholly empty, and golden's pins span the die (the FT601's placement blocks sit at
  both edges, the flash on bank 14, the clock on W19), so almost no frame was empty. That left the user
  image about 2.4 MB of the 4 MB flash, some 8% above today's Pt image. The user judged the approach
  fragile: what golden bought was automatic recovery from a load killed mid-write and from an image
  that cannot reflash itself, and both are rare enough for the JTAG path. Its stage-1 register map and
  bench became the card's flash block.
