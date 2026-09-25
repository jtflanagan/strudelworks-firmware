# The boot loader: three stages, a golden image, and the DDR3 fenced out of boot

Status: **PLAN, 2026-09-25, branch `boot_loader` (from fw master 9ddb33d / host master 758bbe7). Nothing
built; no bench, no bitstream.** The design was settled with the user in one session on 2026-09-25;
this document records the decisions and the order of work. It extends REQ_65C02.md 1.10 (a DDR3-free
boot path), which applies to both cards (REQ_65816.md 1.10).

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

- **Three stages, in order, each started by the host.** Nothing advances on its own.
- **The card never times out waiting for the host.** The card is powered from the Pi's USB3 and
  configures long before a cold-booting Pi can talk to it.
- **Once in full operation, all messaging may ride the DDR3 ring.** A wedge is not detected on the
  card: the host notices that the card's heartbeats have stopped and sends LINK_RESET.
- **LINK_RESET is a full reset, sparing nothing.**
- **Development loads go in over JTAG, into flash** (not SRAM), because JTAG works however broken
  the card is. The USB3 path is for user-level image loads at runtime.
- **JTAG is the recovery path of last resort, and it needs no special equipment:** it is the
  Alchitry's ordinary USB cable, plugged into the Pi, driven by the host software. Slow is fine.
- **Golden's protocol is defined once and frozen at release.** It may change while this is fleshed
  out; after release, the host speaks it forever.
- **We know what is in the flash, so a start reloads nothing it does not need to.** Pushing the bit
  on every swhost start was a workaround for not knowing what was already there; QUERY answers that.
- **RES' is not cared about until stage 3 asserts control.** It may glitch during FPGA resets on the
  prototype; accepted until the deadman hardware exists.

## The boot, stage by stage

```
 power-on / LINK_RESET / watchdog / swhost start
        |
        v
 STAGE 1  golden image (flash 0)          link + stage-1 commands only; waits forever
        |  host: QUERY -> match?  -- no -->  LOAD image, QUERY, LINK_RESET (back to stage 1)
        |  yes: BOOT (IPROG to the user image)
        v
 STAGE 2  user image, bootstrap           link + registers on the boot lane, DDR3 calibrates,
        |                                  the Apple held; no DDR3 dependency anywhere
        |  host: reads calibration. Failed -> stop, tell the user, the user decides.
        |  good: OPERATE
        v
 STAGE 3  user image, full operation      ROM push, ring engaged, capture, RES' released;
                                           all messaging rides the DDR3 ring
```

Every reset of every kind lands in stage 1, and the host walks the whole sequence again.

### Stage 1: the golden image

A separate, small design at flash address 0, flashed once over JTAG and never written by the card.
It contains the FT601 link, the message parser, a small register file, the flash executor and the
IPROG primitive. It has no DDR3 and no core, and it drives nothing on the Apple side: every Apple-side
pin is left as an unconfigured FPGA's, the power-on state. RES' is not cared about until stage 3
asserts control (user, 2026-09-25); no effort goes into narrowing the window before the deadman
hardware exists, and with it the Apple holds in reset by itself.

It obeys the silent-until-asked rule (PROTOCOL.md) and waits for the host indefinitely.

**Commands.** Golden speaks the existing framing (PROTOCOL.md: header block, 0-255 payload blocks) and
the existing REG_READ / REG_WRITE / REG_VALUE messages, plus one new host->card type for a flash page.
Its register map is small and frozen at release:

| Command | What golden does |
|---|---|
| identify | answers a register: "stage 1", golden's protocol version, its build stamp, its part |
| QUERY | reads the user region's record; reads the whole image back from flash and computes its CRC32; answers valid (with the record's fields) only if the CRC matches the record. About 0.5 s for 2.2 MB at the 40 MHz read clock. |
| ERASE | unlocks ONLY the user region's blocks (`WBPR 42h`) and block-erases (`D8h`) the blocks the new package needs |
| page | host->card FLASH_PAGE message: one address word + 64 data words (256 B). Golden programs the page (`02h`) and polls BUSY; the host reads a status register (busy / pages done / error) as the acknowledgement before sending the next page. Stop-and-wait: no buffer beyond one page, so the receiver, which has no back-pressure (`ft601_fifo.sv`, "The receiver is assumed never full"), cannot overrun. |
| BOOT | ICAPE2 IPROG with WBSTAR = the user bitstream's address. Refused unless the last QUERY since reset or since the last write said valid. |
| LINK_RESET | IPROG with WBSTAR = 0: golden reloads itself (a full reset, as everywhere) |

A status register with a busy bit and a completion count is the acknowledgement for every command,
so no new card->host message type is needed (memory `new-message-types-need-routing`).

**The load sequence (host):** identify -> QUERY -> if the record matches the wanted image, BOOT. Otherwise
validate the package (below) -> ERASE -> pages, bitstream first, record sector last -> QUERY (must say
valid) -> LINK_RESET -> identify -> QUERY -> BOOT. A failure anywhere leaves golden running and the
host retries from the start; nothing is lost but the user image.

The host does not read the image back itself: the record carries the host's CRC of the bitstream and
golden checks the flash against it, which is the end-to-end check.

### Stage 2: bootstrap inside the user image

After BOOT the user image configures and comes up in the state the card is in today before the host
engages the ring: the link and every register answer on the ring's **boot lane** (TX_RING.md; built
2026-09-18 for REQ 1.10), the DDR3 calibrates on its own, and the soft core is held (`start_hold`).

The host reads LINK_STAT / RING_STATUS / DDR3_DBG1..4. If the DDR3 has not calibrated, nothing
proceeds: the host tells the user and waits for the user's decision. It does not exit (today
`start()` fails and swhost stays down, `pipeline.cpp:1827` -> `main.cpp` exit 1).

### Stage 3: full operation

One host-driven transition, OPERATE, entered only after calibration has been read good:
the ROM push, the ring engage (`RING_CTRL`), BUS_ENABLE, telemetry, and the START release that lets
RES' go. From then on every card->host word rides the DDR3 ring.

The ROM push moves here from before the calibration check. It needs the DDR3 by its nature (the ROM
lives in the image: `rom_loader.sv:170`, `pw_valid = draining && image_ready && in_window`, and
`image_ready = calib_complete`, `page_client.sv:116`), and the host pushes it today before checking
calibration (`pipeline.cpp:1715` vs `:1827`), so an uncalibrated card burns every ROM retry first.

### LINK_RESET: a full reset

LINK_RESET (0x01, already decoded in `ft601_msg_rx` as the header is taken) becomes ICAPE2 IPROG with
WBSTAR = 0, in both golden and the user image. The FPGA reconfigures from flash: every register, RAM,
MMCM and the DDR3 controller start as at power-on, and the card lands in stage 1. The card's link
watchdog expiry (`link_watchdog.sv`, a host that went silent mid-capture) and the other causes that
feed today's reset stretcher (`card_link.sv:520`: no FT601 clock, TX stalled) take the same path.

Cost: golden's configuration (a small image, well under 0.5 s) plus the user image's (2.2 MB at
33 MHz x1, about 0.55 s) plus calibration. Every swhost start already is a reset (memory
`start-then-reset`); it becomes this one.

The wedge detector is the host: its existing silence detection (`drive_link_health`,
`pipeline.cpp`) sends LINK_RESET. No card-side DDR3 progress watchdog.

## The flash

The part is a Microchip **SST26VF032B** on both the Au V2 and the Pt V2 (4 MB; JEDEC ID `BF 26 42`;
Au from Alchitry's forum and their loader, Pt from the SST26 pin names on U3 in the Pt schematic;
golden reads the ID first anyway). Datasheet DS20005218E.

- **It powers up write-protected.** Its block-protection register is volatile and resets to "all
  locked". Every erase or program aimed at a protected block is ignored (datasheet 5.18). Golden
  unlocks only the user region's blocks with `WBPR 42h`, never the global unlock `98h`, so its own
  blocks stay locked and a bug in golden's address arithmetic cannot erase golden.
- **Every erase costs about the same:** sector (`20h`, 4 KB), block (`D8h`, 64 KB in the middle of
  the chip, 8 and 32 KB in the bottom and top 64 KB) and chip (`C7h`) are 18 / 18 / 35 ms typical.
  Chip erase takes no range and is ignored if any block is protected, so **it is never used.**
  Golden block-erases a 2.25 MB package in 36 operations, about 0.65 s.
- **Programming is the floor:** 256 B pages at 55 us + 3.75 us/byte, about 1 ms per page; a 2.24 MB
  Pt image is about 9 s. Faster SPI does not help.
- `03h` read is limited to 40 MHz (`0Bh` goes to 104 MHz, an option if QUERY's 0.5 s ever matters).
- In x1 SPI, D02 is WP# and D03 is HOLD#: golden drives both high.
- CCLK is reachable only through STARTUPE2 `USRCCLKO`; the first 3 clocks after configuration are
  swallowed. FCS_B and D00-D03 are ordinary user I/O after configuration (Pt: D00-D03 = P22 R22 P21
  R21, `ref/alchitry_pt_v2_pins.tsv`; FCS_B to be confirmed from the pinout).

### Layout (Pt)

```
0x000000 - 0x0FFFFF   golden (1 MB reserved until its real size is known; JTAG-written, stays locked)
0x100000              user package: record sector (4 KB)
0x101000              user bitstream (raw .bin)
          - 0x3EFFFF  end of the user region: 0x2F0000 = 2.94 MB for record + bitstream
0x3F0000 - 0x3FFFFF   unused (the top 64 KB is 8 and 32 KB blocks)
```

The user region starts on a 64 KB boundary above the bottom 64 KB stretch and ends below the top one,
so it is all uniform 64 KB blocks for golden's `D8h`. The size ceiling (about 2.9 MB against today's
2.24 MB compressed Pt image; a full 100T bitstream is 3.8 MB uncompressed) was accepted by the user.
If golden builds under 512 KB, the user region can start at 0x080000. The Au gets its own golden and
its own numbers.

### The package

`build.sh` emits, next to the `.bit`, one file that both writers put at the user offset:

```
+0x0000  record, one 4 KB sector (the rest FF):
           magic, record version
           bitstream length, CRC32 of the bitstream
           part / IDCODE, board, machine (IIe / GS), golden-protocol version it expects
           build stamp (the one BUILD_DATE reports)
           CRC32 of the record itself
+0x1000  the bitstream: Vivado's raw .bin, not the .bit with its header
```

BOOT jumps to +0x1000. The record's position does not change the cost of trusting it: whoever writes
the package and in whatever order, golden checks the data against the record on every QUERY.

The host validates a package before ERASE: the part, the board, the golden-protocol version, and
that the machine matches the swhost conf it will restart with (memory `name-the-conf`).

### Writers

- **Development and recovery (JTAG):** `openFPGALoader -c ft2232 --fpga-part xc7a100tfgg484 -f
  -o 0x100000 --verify <package>`. Read in openFPGALoader v0.12.0's source (sibling clone
  `~/repos/openFPGALoader`): `-o` passes to the flash write (`src/xilinx.cpp:689-696`); a flash write
  of a `.bin` is raw, not bit-reversed (`xilinx.cpp:579-580`); it erases only the written range, in
  4 KB sectors, because its SST26 entry has block erase off (`src/spiFlashdb.hpp:250-261`,
  `src/spiFlash.cpp:182-235`); it sends the global unlock before writing (`spiFlash.cpp:356-363`) but
  touches nothing outside its range; afterwards it resets the FPGA, which boots golden. Expect about
  30-40 s (560 sector erases alone are about 10 s). Slow is fine. Golden itself is written once the
  same way with `-o 0`.
- **User loads (USB3):** golden, as above: about 0.65 s erase + 9 s programming + 0.5 s QUERY.

### Recovery

- A USB3 load that fails part-way (power cut, dropped link, host crash): golden is untouched and
  QUERY says invalid; the host reloads.
- A user image that configures but does not work: power-on and LINK_RESET always land in golden, so
  the host loads a different image. No JTAG.
- A user image that fails to configure (CRC or IDCODE error): user images are built with
  `BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE`, so the FPGA falls back to address 0, golden
  (Xilinx XAPP1247). Golden refuses BOOT on an unverified image, so no barrier images or watchdog
  timer settings are needed.
- Golden itself broken: JTAG, from the Pi, with the ordinary Alchitry USB cable.

## RES' and the deadman

The prototype cannot hold RES' through an FPGA reconfiguration; glitches during resets are accepted.
The planned deadman hardware: a MOSFET holds RES' low from the moment the Apple powers on, until the
FPGA actively releases it with a GPIO driven high. The deadman input is pulled down (it must work
with the 3V3 rail dead), and PUDC_B is strapped high on the board (verified by the user), so every
user pin floats during configuration and the deadman holds. The release is a static level; a toggling
release was considered and rejected as overkill.

With it, every reset path is safe with no special handling: power-on, IPROG and fallback leave the
pin unconfigured (held); golden and stage 2 never drive it; the OPERATE transition's START release
drives it high.

A future snoop-capable card (the Apple's own CPU running, the card watching) needs a different class
of hardware support: most likely a board jumper that disables the deadman, set by a card intended to
run snoop-only.

## What exists today (audit, 2026-09-25, on master)

Already DDR3-free on the boot lane: the FT601 controller, both async FIFOs, the RX parser, `reg_bridge`,
`reg_front`, `wb_regfile`, the notices, `start_hold`, the telemetry sweep, DDR3_DBG1..4 and the eye
registers, the slot ROMs in LUTRAM.

Leaks and conflicts this plan removes:

1. **The ROM push needs the DDR3** and runs before the calibration check (stage 3 above).
2. **An engaged ring never lets go except by reset;** a `RING_CTRL=0` write reads back 0 but the ring
   stays engaged (`tx_ring.sv:303`, `wb_regfile.sv`). Under this plan only a reset leaves stage 3, so
   a disengage write should be refused loudly rather than silently ignored.
3. **The link reset spares the DDR3 controller** (`card_link.sv:668-677`: its reset is the clock
   lock only). LINK_RESET = IPROG supersedes this.
4. **`clk_ctrl` is CLKOUT0 of the DDR3's MMCM** (`clk_gen.v:89`). Nothing breaks today, but DDR3
   clocking work (write-leveling phase shifts, a frequency plan) moves the clock the link runs on.
   The control plane should get its own clock from the 100 MHz oscillator.
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
  snoop-only testing days and was already overridden by that document's decision 3 (a full hold on
  both machines). It is marked there as a development heuristic.
- **CLAUDE.md, `build/load.sh`, `build/load_card.sh`, the `fw-load` skill:** "SRAM, volatile" becomes
  a flash write of the package to the user region.
- **The card survives a Pi reboot** once flashed (memory `pi-reboot-wipes-bit` goes stale).

## Rungs

Each rung is explained before it runs; a bench failure is a finding; a bitstream that misses timing
stops the work.

- **BL0 - this plan** and the REQ_65C02.md 1.10 amendment.
- **BL1 - the flash executor, in simulation.** A module on STARTUPE2 (USRCCLKO) with the SST26
  command set: read ID, WBPR (partial unlock), D8h block erase, 02h page program, 03h read, BUSY poll,
  and a CRC32 engine over a read range. A behavioural SST26 model for the bench (protection that
  ignores writes, erase and program times scaled down). Gate: ID, a protected block's erase ignored,
  erase/program/read-back of a page, the CRC of a region.
- **BL2 - golden, built and flashed.** `golden_top.sv`: FT601 link, parser, the stage-1 register map,
  the executor, ICAPE2 IPROG. A host-side stage-1 client (a small tool first, swhost later). Gate on
  hardware: identify answers; QUERY on an empty user region says invalid; LINK_RESET reloads golden.
- **BL3 - the package and the development load.** `build.sh` writes the package; `load.sh` /
  `load_card.sh` write it with `openFPGALoader -o`; the `fw-load` skill follows. Gate: a JTAG load,
  QUERY valid, BOOT, today's user image comes up and runs today's startup; openFPGALoader's time
  measured.
- **BL4 - LINK_RESET = IPROG in the user image,** and swhost's start becomes identify / QUERY / BOOT.
  Gate: the CS7-style ladder (20 swhost restarts, 20 LINK_RESETs, each back to a running machine).
- **BL5 - the user load over USB3.** ERASE and FLASH_PAGE in golden, the host's validation and
  stop-and-wait load, swhost restarting with the image's conf. Gate: switch between a IIe and a GS
  image and back; a load killed mid-way leaves QUERY invalid and golden answering.
- **BL6 - the stage 2 / stage 3 fence.** The host: calibration read before anything that needs the
  DDR3, OPERATE as one step, stay up and report on a failed calibration, the mock's uncalibrated mode.
  The card: a `RING_CTRL` disengage write refused loudly. Gate: a card held uncalibrated (a bench,
  then hardware if a way to force it exists) answers everything in stage 2 and never enters stage 3.
- **BL7 - the control clock off the DDR3's MMCM.** Its own clock for the link and registers. Gate:
  timing met on the Pt; the BL4 ladder again.
- **BL8 - the deadman release,** when the hardware exists: one GPIO, driven high only by the OPERATE
  transition's START release.

The user decides the order at each rung; BL1 to BL5 are the boot loader proper, BL6 and BL7 the fence.
