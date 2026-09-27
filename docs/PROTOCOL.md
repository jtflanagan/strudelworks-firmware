# FT601 link protocol

Status: 2026-09-17, fw 6bb1bfd / host 523ce7c, merged to master; GS bit `gs_telem1` MET wns +0.004, `reg_map_tb` 130 checks, `telem_tb` 23; not on hardware yet): type `0x39` TELEMETRY and `0x8000_0168` TELEM_CTRL added (TELEMETRY.md); the tables brought level with the RTL - types `0x33`, `0x34`, `0x37`, `0x38` and registers `0x8000_0100`-`0x8000_012C`, `0x8000_0160`, `0x8000_0164` were in `rtl/` and the host's `protocol.hpp` but not here.  `rtl/wb_regfile.sv`'s map and the `T_*` localparams are authoritative; this file follows them.

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
| `0x00` | IDLE | Link filler, **both directions**. Payload, if any, is discarded by the receiver. `len = 0` is the **heartbeat**: the single word `0x00000000`. |
| `0x01` | LINK_RESET | Host→card. Header only. Pulls the same lever as the UART's `R` and the watchdog: 1 ms of the link's reset, RESET# to the FT601, the ring and the message layer with it. Decoded in `ft601_msg_rx` as the header is taken, so it needs nothing downstream to be working - it is the recovery path for a link whose TX side, ring or client has stopped, and it exists so that recovery needs no second cable. The card sends nothing back: the reset is the answer, and the card comes up held (START_HELD, cause card reset). See CLEAN_START.md CS4. |
| `0x02`–`0x0F` | — | Reserved for link-layer types: ones the FT601 layer may generate or consume on its own, parseable without application state. |
| `0x10` | SEQ | Card→host. The verified counter stream from `ft601_top`, the link regression vehicle. |
| `0x11` | BUS_ENABLE | Host→card. `free[0]` capture enable, `free[1]` source select (0 synthetic, 1 real bus), `free[2]` sparse (send only `$Cxxx` accesses, writes, the blanking and RES′ edges, with SKIP words counting the rest - see SPARSE.md; real bus only), `free[7:4]` heartbeat period select. All latched at enable. `enable = 0` is the clean stop. |
| `0x12` | BUS_EVENTS | Card→host. Payload is N words, two per RECORD (see "The event record" below): bus cycles (`rtl/apple_bus_read.sv`, tag `0xF`), in sparse mode SKIP records `{0xD, count[27:0]}` in word 0 - that many cycles passed unsent before the next record (SPARSE.md) - and while the core is accelerated (ACCELERATION.md) fast-op records (tag `0xC`, class 1): an op the core took from the card that rode no bus cycle, an op and not a cycle, with SKIPs standing for the dummy cycles in full mode too. `len` is always even; a message never splits a record. |
| `0x13` | BUS_STATUS | Card→host. Overflow flag, enable state, captured count - of RECORDS into the capture FIFO (events and SKIPs alike). |
| `0x14` | REG_READ | Host→card. Payload `[addr]`. Answered with REG_VALUE. |
| `0x15` | REG_WRITE | Host→card. Payload `[addr][data]`. Also answered with REG_VALUE. |
| `0x16` | REG_VALUE | Card→host. Payload `[addr][data]`, answering either of the above. |
| `0x17` | CPU_HOLD | Card→host, **unsolicited**. Header only; `free[0]` = the soft core is held, `free[1]` = by the runtime menu's door rather than at its reset vector. Sent on every change of `held` while a capture is enabled, through the same boundary-respecting slot as a REG_VALUE. See BOOT_MENU.md and RUNTIME_MENU.md. |
| `0x18` | HD_ROM | Host→card. Payload 64 words: the hard disk's 256-byte slot ROM. See HARDDISK.md. |
| `0x19` | HD_DONE | Host→card. `free[7:0]` = the status the EXECUTE port reads once busy clears; payload `[{count, addr}] [size] [bytes…]` to DMA into the Apple, or header only for none. |
| `0x1A` | HD_FETCH | Host→card. Payload `[{count, addr}]`: read bytes out of the Apple's memory. |
| `0x1B` | HD_DATA | Card→host. `free` = count; payload the bytes, answering HD_FETCH. Through the same boundary-respecting slot as a reply, whatever its length. |
| `0x1C` | KBD_EVENT | Card→host, **unsolicited once asked** (KBD_CTRL `notify`). A press on the injected keyboard was resolved, or the lock saw a real key. `free[0]` strobe, `[1]` seen, `[2]` touched, `[3]` lock, `[15:8]` the key resolved last; payload one word `{replaced, flushed, taken, pressed}`. A level, like CPU_HOLD: the words carry the state as it is when they go out. See KEYBOARD.md. |
| `0x1D` | VBL_MARK | Card→host, **unsolicited once asked** (VBL_CTRL `notify`). Header only; `free[0]` = PAL, `free[15:8]` = frame count. Emitted by the capture itself, **between two BUS_EVENTS messages**: the event after it is line 0, cycle 0 of the video scanner. See VBL.md. |
| `0x1E` | FD_ROM | Host→card. Payload 64 words: the Disk II's 256-byte boot ROM. See FLOPPY.md. |
| `0x1F` | FD_TRACK | Host→card. One chunk of a track answering FD_SEEK: payload `[{seq, chunk, qtr, drive}, {bits}]` then up to 252 words of the track's BIT STREAM (byte i = bits 8i..8i+7, high bit first; FLOPPY.md "The track as bits"); `bits` is the track's bit count, 0 = no track at this position; seven chunks make a track, the seventh clears the buffer's STALE. A chunk whose `seq` is not the drive's current one is dropped. |
| `0x20` | FD_SEEK | Card→host, **unsolicited**. Payload `[{seq, 0, qtr, phase[7:1], drive}]`: the head is at quarter track `qtr` (0-159), reached by half-track `phase` (0-79), and the card does not hold what lies there; answer with seven FD_TRACK chunks carrying `seq`. |
| `0x21` | FD_DIRTY | Card→host, **unsolicited**. Payload `[{seq, chunk, qtr, drive}, {bits}]` then up to 252 words: a track the machine wrote to, seven chunks, sent before the FD_SEEK that leaves it. |
| `0x22` | MEM_ROM | Host→card. One chunk of the system ROM for the card's copy (the IIe's 16 KB in 32 chunks, the IIgs's 256 KB in 512): payload `[{chunk}]` then 128 words; in any order. **Taken only while the start hold holds the machine**, and answered with MEM_ROM_ACK (CLEAN_START.md CS2). See MEMORY.md. |
| `0x23` | VIDHD_ROM | Host→card. Payload 64 words: the VidHD's 256-byte slot ROM - the signature software scans for, synthesised by the host. See VIDHD.md. |
| `0x24` | UNKNOWN_TYPE | Card→host, **unsolicited**. Header only; `free[7:0]` = the type of a host→card message the card does not consume, `free[15:8]` = its length. The card skipped that message by its length - framing is intact - and this says so, so the host can log what it sent that the gateware lacks. One pending, the latest wins. |
| `0x25` | MOUSE_MOVE | Host→card. `free[1:0]` = the mouse's buttons (levels, 0 = button 0); payload one word `{dy[15:0], dx[15:0]}`, signed deltas in the mouse's own counts. Applied to the card's position with the program's clamps and raises the movement/button interrupt if the mode asks. See MOUSE.md. |
| `0x26` | MOUSE_ROM | Host→card. `free[2:0]` = chunk; payload 64 words: one 256-byte page of the AppleMouse card's 2 KB firmware ROM. Eight chunks make the ROM, in any order. See MOUSE.md. |
| `0x2D` | PRINTER_ROM | Host→card. Payload 64 words: the parallel printer card's 256-byte slot ROM (AppleWin's Parallel.rom, or the host's synthesis of the output hook). The whole ROM or nothing. See PRINTER.md. |
| `0x27` | NSC_TIME | Host→card. Payload two words: the No-Slot Clock's 64-bit clock register in packed BCD, low word `{hour, minute, second, centisecond}` then high `{year, month, date, day of week}`. Taken whole at the second word; the card keeps no time of its own, the host sends one every centisecond. See NSC.md. |
| `0x28` | U2_CMD | Card→host, **unsolicited**. The Uthernet II: a write to a socket's command register, or a reset. `free[1:0]` the socket, `free[15:8]` the command byte (`$00` reset); payload 24 words: the W5100's common registers `$0000-$002F` then the socket's `$00-$2F`, as bytes, as the program would read them. See UTHERNET2.md. |
| `0x29` | U2_TX | Card→host, **unsolicited**, after a SEND's U2_CMD: the bytes from `Sn_TX_RD` to `Sn_TX_WR`. `free` = `{bytes[11:0], last, first, sock[1:0]}`; payload the bytes packed four a word, up to 255 words a chunk. |
| `0x2A` | U2_RX | Host→card. Bytes to append at a socket's RX write pointer, the W5100's header in front. `free` = `{bytes[11:0], 0, 0, sock[1:0]}`; payload the bytes packed four a word. The card moves `Sn_RX_WR` and adds to `Sn_RX_RSR` at the last word. |
| `0x2B` | U2_STAT | Host→card. `free` = `{sr[7:0], 0, sock[1:0]}`: the socket's `Sn_SR`, at once; payload none, or two words `[DIPR][{MSSR, DPORT}]` (the socket's register words 3 and 4) for an accepted LISTEN's peer. |
| `0x2C` | AUDIO_FRAMES | Card→host, **unsolicited once asked** (AUDIO_CTRL on). The sound on the card (AUDIO.md): n samples at the play rate, **four** words each - `{ay0, spk}`, `{ay2, ay1}`, `{doc_l, ay3}`, `{seq, doc_r}` - the speaker's and each AY chip's box average over one sample window (0..32767), then **the Ensoniq's stereo pair**, and a running sample count. `free` = `{drops[7:0], n[7:0]}`, n = 32; `len` = 4n. It was three words until the DOC arrived (GS.md rung 7); `doc_l`/`doc_r` are SIGNED and centred on zero, unlike the speaker and the AYs, because the DOC's oscillators mix around silence at $80, and they are already panned - an oscillator's control register picks its channel on the card. Zero on a IIe build. A gap in `seq` is that many samples the card's FIFO dropped. |
| `0x2E` | GS_BRAM | Host→card. Payload 64 words: the IIgs's 256-byte battery RAM, four bytes a word, low byte first. Taken ALL OR NOTHING by `rtl/gs_clock.sv` - a partial image is worse than none, because the ROM checksums it, finds it wrong, and writes its own defaults over the slot settings it was shipping. The host sends one at start when `machine = iigs`, naming every slot it has put an emulated card in. See GS.md. |
| `0x2F` | ADB_KEY | Host→card. Payload one word `{16'd0, mods[7:0], is_up, keycode[6:0]}`: one ADB key event, with the modifier byte in `$C025`'s own bit order (1 shift, 2 control, 4 caps lock, `$40` option, `$80` command). THE CARD HOLDS THE KEYMAP, as a real ADB micro does, so what travels is a keycode and not a character: `rtl/gs_adb.sv` turns it into `$C000`'s ASCII with `rtl/adb_keymap.hex` (`tools/gen_adb_keymap.py`, from KEGS's own table) and queues the raw event for a Talk register 0. NOT THE ONLY SOURCE: the Apple's own keyboard feeds the same micro from the card, its ASCII run backwards into a keycode by `rtl/gs_kbd_a2.sv` (`rtl/adb_revmap.hex`, `tools/gen_adb_revmap.py`), with no message involved. See GS.md. |
| `0x30` | GS_TIME | Host→card. Payload one word: seconds since 1904-01-01 in the machine's LOCAL time. THE FEED IS THE CLOCK - the card keeps no time of its own, so `rtl/gs_clock.sv` holds what it was last sent and the host re-sends every second, exactly as it feeds the No-Slot Clock (NSC.md). Local rather than UTC because the Control Panel shows what the chip counts; 1904-01-01 is 2,082,844,800 seconds before the Unix epoch, and a 32-bit count from it runs out on 2040-02-06, which is the real part's limit. Sent before RES' is released so the ROM's first read of `$C033` is of the Pi's clock. See GS.md. |
| `0x31` | FD35_TRACK | Host→card. One chunk of a 3.5" track answering FD35_SEEK: payload `[{seq, chunk, qtr, 0}]`, `[{chunks, 0, nibbles}]`, then up to 252 words of nibbles; `chunks` of them make the track (ten in zone 0), the last to land clears the drive's STALE; a chunk whose `seq` or `qtr` is not the buffer's own is dropped. `qtr` = track * 2 + side, KEGS's numbering. See IWM35.md. |
| `0x32` | FD35_SEEK | Card→host, **unsolicited**. Payload `[{seq, 0, qtr, 0}]`: the 3.5" head is on a track the card does not hold; answer with the FD35_TRACK chunks carrying `seq`.  Asked again after 40 ms if nothing landed. |
| `0x35` | START_HELD | Card→host, **unsolicited, not gated on the capture**. Header only; `free[0]` = held by the card's own reset (power-on, a bitstream load, the link's reset or its watchdog), `free[1]` = held by a RES' the hold did not cause, `free[15:8]` = the count of holds since the card's reset. The whole machine is held - the card drives RES' low - until the host has run its startup checklist and writes START bit 0. Sent on every rising edge of `pending`; a host that attaches to a hold already in place reads START. See CLEAN_START.md. |
| `0x36` | MEM_ROM_ACK | Card→host, **unsolicited**, one per MEM_ROM. Header `{0, 0x36, len=1}`; payload `{sum16[31:16], status[15:12], chunk[11:0]}`. `status` 0 OK - the chunk's 512 bytes have drained into the image and `sum16` is their sum mod 2^16 - 1 OVERRUN (arrived while another chunk drained; dropped, counted in MEM_ROM_STAT), 2 NOT_HELD (the machine is running: a ROM never lands under it; refused), 3 BAD_LEN, 4 BAD_INDEX (the chunk number is past the ROM). A refusal is acked at once. The host sends one chunk, waits for its ack, retries on a timeout or a refusal, and compares ROM_SUM with its own file once rom_loaded is set. See CLEAN_START.md CS2. |
| `0x33` | PANEL_DMA | Host→card. The host's reply to a request our 65816 panel left in its own RAM, carried into the machine by the HD card's DMA write: payload `[{count, addr}] [{0, bank, 0}] [bytes…]`, HD_DONE's shape but not a disk command. Taken only with the HD card idle and nothing of the disk's outstanding; a refusal is counted in PANEL_STAT. See GS_CONTROL_PANEL.md R4. |
| `0x34` | PANEL_BELL | Reserved beside PANEL_DMA for the panel's bell; not decoded. |
| `0x37` | FD35_DIRTY | Card→host, **unsolicited**. A 3.5" track the machine WROTE, going home: payload `[{seq, chunk, qtr, 0}] [{chunks, 0, nibbles}]` then up to 252 words - FD35_TRACK's shape in the other direction. See IWM35.md. |
| `0x38` | FD35_EJECT | Card→host, **unsolicited**. Header only: the MACHINE asked for its 3.5" disk back (the Finder, the ROM's control call). It follows any FD35_DIRTY the card owes, in the same stream. See IWM35.md. |
| `0x39` | TELEMETRY | Card→host, **unsolicited once asked** (TELEM_CTRL enable). The card's registers, once a second, read in one instant under the register cut's hold; the first sample of a run is taken as the Apple's RES' lets go. `free` = `{drops[7:0], layout[7:0]}`; payload `[{epoch[7:0], flags[7:0], 16'd0}] [seq] [microseconds]` then the words of `rtl/telem_map.vh` in its order: registers, and - layout 2 - the debug space's items, each read through DBG_VAL with the sender's own selector on the top's muxes while the host's DBG_SEL stands (85 words in layout 1, `len` = 88; 171 in layout 2, `len` = 174). `flags[0]` RES' was low at the sweep, `flags[1]` a baseline that had to wait for a message already going out. `epoch` counts RES' releases, `seq` seconds since the last one (0 is the run's baseline), `drops` samples skipped because the previous message had not finished. Port 11 of the message bus: above the capture, below the sound. See TELEMETRY.md. |
| `0x3A`–`0xFF` | — | Application, unassigned. |

### The event record (wire format v6, 2026-09-08)

One event is a **64-bit record**, two 32-bit words on the wire, word 0 first;
the host holds it as one `uint64_t` with word 0 in the low half
(`src/protocol.hpp`, "Apple bus event record").  Word 0 keeps every bit
position the 32-bit v5 word had, except the data byte, whose place the
65816's bank byte takes:

```
word 0   [31:28] tag      0xF bus cycle, 0xC fast op, 0xD SKIP
         [27:20] bank     the 65816's bank byte (0 on the IIe)
         [19:16] flags    {vbl, sync, res, rw}
         [15:0]  addr
word 1   [31:24] data
         [23:20] class    0 bus cycle, 1 fast op, 2 a dummy cycle the filter kept
                          (an edge), 3 shadow duplicate, 4 DMA
         [19:16] cpu      {E, M, X, irq-taken} of the cycle (0 on the IIe)
         [15:0]  spare    zero until something earns it
```

A SKIP's word 1 is zero.

**The RISC-V engine's write record, tag `0xB`** (the GS card, docs/REQ_RVVM.md "The
engine-write record"): a store the engine made to the machine's RAM itself, which no
cycle or fast op carries.  An op and not a cycle, like a fast op; the filter always
keeps it and never counts it, and the host's mirror applies it in stream order
(`src/protocol.hpp` `kEngineWriteTag`, `AppleMemory::apply_engine_write`):

```
word 0   [31:28] tag           0xB
         [27:24] enables       bit k: the byte at (word address * 4) + k is written
         [23]    0             reserved
         [22:0]  word address  byte address >> 2: the whole 32 MB of main memory,
                               the lower 16 MB the 65816's, the upper 16 MB the
                               engine's alone (docs/REQ_RVVM.md)
word 1   [31:0]  data          the byte at (word address * 4) + k in bits 8k+7:8k
```

(Until 2026-09-26 word 0 was `{tag, bank[27:20], enables[19:16], addr[15:0]}`, whose two
low address bits were always zero; the repack for 32 MB kept the record 64 bits.)

It enters `rtl/event_merge.sv` in the fast word's slot on a clock no fast word is
kept, and waits for room (the engine holds its next store until the take) rather
than being dropped.  The 24-bit address regime of the IIgs is what
forced the size (the bank has to ride every record), and the record is
uniform for the IIe build too, so every consumer - the capture, the host's
ring, the trace file (version 2, 8-byte records) - has one stride.  A frame is
at most 127 records (254 words + header); `captured` counts records.  The
producers: `rtl/apple_bus_read.sv` (class 0), `rtl/event_merge.sv` (class 1
for a fast op, class 2 stamped on a dummy), `rtl/bus_event_filter.sv`
(SKIPs); `rtl/bus_event_capture.sv` puts the two words on the wire.

The host heartbeat is an **IDLE frame**, not a type of its own — it is the same
four bytes in the other direction, and the card's watchdog is reset by any
well-formed message anyway (see below), so a distinct type would carry no
information.

### Control registers

A 32-bit Wishbone on the card, in a region well clear of DDR3:

```
0x0000_0000 .. 0x0FFF_FFFF   DDR3       (2^24 bursts x 16 bytes = 256 MB)
0x8000_0000 .. 0x8000_FFFF   registers
```

One address bit separates them, so neither has to know the other exists. The
DDR3 bus is **not** reused for this: it is 128 bits wide and its address is a
burst index, which is the right shape for bulk memory and the wrong one for
control registers. `wb_regfile` is a separate 32-bit instance of the same
protocol.

| addr | name | access | meaning |
|---|---|---|---|
| `0x8000_0000` | BUILD_DATE | RO | `YYYYMMDD` as a decimal integer |
| `0x8000_0004` | BUILD_TIME | RO | `HHMMSS` as a decimal integer |
| `0x8000_0008` | CPU_SOURCE | RW bit 0 | which CPU drives the Apple bus; latched at RES' — see BUS_MASTER.md |
| `0x8000_000C` | MB_SLOT | RW bits 3:0 | the Mockingboard's slot, 0 = off, bit 3 a Phasor in it; latched at RES' (`[10:8]`, `[11]`) — see MOCKINGBOARD.md |
| `0x8000_0010` | BOOT_HOLD | RW bit 0, W1 bit 16 | hold the soft core at its reset vector; `arm`, `held`, `runtime`, `release`, `holds` — see BOOT_MENU.md; the release serves the runtime door too — see RUNTIME_MENU.md |
| `0x8000_0014` | HD_SLOT | RW bits 2:0 | the hard disk's slot, 0 = off; latched at RES', never MB_SLOT's; `rom`, `busy`, `execs` — see HARDDISK.md |
| `0x8000_0018` | RESET | W1 bit 0, W bits 31:16 | pulse the Apple's RES' low, for a programmatic Ctrl-Reset; `pulsing`, `pulses` — see BUS_MASTER.md |
| `0x8000_001C` | KBD_INJECT | W bits 6:0, W1 bits 7-8 | a key on the keyboard the soft core reads: `key`, `press`, `drop`; `strobe`, `seen`, `pressed` — see KEYBOARD.md |
| `0x8000_0020` | BUTTONS | RW bits 5:0 | Open-Apple, Closed-Apple and PB2 as the host holds them, two bits each (hardware / up / down); `hw` — see KEYBOARD.md|
| `0x8000_0024` | RING_STATUS | RO | the DDR3 TX ring: `[21:0]` occupancy (lines when engaged, words on the boot lane when not), `[23]` engaged, `[24]` full, `[25]` DDR3 calibrated, `[26]` a message was torn on the bus (sticky), `[30:27]` drain timeouts — see TX_RING.md |
| (the 65C02 card's MINIMUM) | | | On the 65C02 card (rtl/a2/a2_top.sv, wb_regfile's MINIMAL) every counter, census, statistic and debug word reads zero and writes to DBG_SEL, FB_PEEK and the 3.5" drive words are ignored: the stamps, every control and slot word, BOOT_HOLD, MENU_HOLD, START, RESET, ROM_SUM, MEM_CTRL/MEM_STAT/MEM_ROM, KBD_*, BUTTONS, VBL_*, FD_*, FB_CTRL, ACCEL_CTRL/STAT, NSC_CTRL, AUDIO_CTRL/RATE, TELEM_CTRL, LINK_STAT, RING_STATUS/RING_CTRL and DDR3_DBG1..4/EYE0..1 answer as before (docs/CORE_REFACTOR_65C02.md rung 2; what comes back is decided later) |
| `0x8000_0188` | RING_CTRL | RW | `[0]` engage the DDR3 ring (TX_RING.md "The boot lane"). Clear out of every card reset: the card links and answers every register over USB3 with the DDR3 uncalibrated, every message on a direct lane. The host sets it once LINK_STAT says calibrated and before BUS_ENABLE; the ring engages at the next message boundary and reports it in RING_STATUS[23] / LINK_STAT[25]. One way: only a reset clears it |
| `0x8000_0028` | KBD_CTRL | RW bits 1:0 | `lock` the machine's own keyboard out, `notify` ask for KBD_EVENT; `touched`, `taken`, `flushed`, `replaced` — see KEYBOARD.md |
| `0x8000_002C` | MENU_HOLD | RW bits 7:0, W1 bit 8 | the runtime menu's door into the same hold: `enable`, `hotkey`, `trigger`, `menus` — see RUNTIME_MENU.md |
| `0x8000_0030` | VBL_CTRL | W1 bits 1:0, RW bit 2, RW bits 31:16 | the video scanner lock: `start`, `probe`, `notify`, `probe_addr`; `state`, `locked`, `pal`, `busy`, `err` — see VBL.md |
| `0x8000_0034` | VBL_STAT | RO | `[15:0]` mismatches in the last verify pass, `[31:16]` the slip of a re-lock — see VBL.md |
| `0x8000_0038` | VBL_POS | RO | `[14:0]` the cycle within the frame now, `[23:16]` frames, `[31:24]` locks — see VBL.md |
| `0x8000_003C` | FD_SLOT | RW bits 2:0 | the floppy controller's slot, 0 = off; latched at RES', never MB_SLOT's or HD_SLOT's; `rom`, `seeks` — see FLOPPY.md |
| `0x8000_0040` | FD_DRIVE1 | RW bits 21:0, W1 bit 22 | what is in drive 1, live: `inserted`, `wp`, `[10:3]` `cell` (the disk's bit timing in eighths of a cycle, 32 = four; was the nibble count), `tracks`, `flush`; `stale`, `dirty`, `phase` — see FLOPPY.md |
| `0x8000_0044` | FD_DRIVE2 | RW bits 21:0, W1 bit 22 | the same for drive 2 |
| `0x8000_0048` | FD_STAT | W1 bits 1:0 | the controller's switches and its own lateness: `motor`, `drive`, `q6`, `q7`, `late`, `fill_max` — see FLOPPY.md |
| `0x8000_004C` | MEM_CTRL | RW bit 0, W1 bits 9:8 | the memory image: `serve` level (all-or-nothing); W1 clear-counters, invalidate; [23:16] the RamWorks bank register as the shadow holds it (0 after RES'); [27:24] log2 of the cache's sets — see MEMORY.md |
| `0x8000_0050` | MEM_STAT | RO | the MMU shadow's switches [11:0], `image_ready` (the DDR3 is calibrated), `invalidating`, `rom_loaded`, `late_fills` [23:16], `fifo_drops` [31:24] |
| `0x8000_0054` | MEM_HITS | RO | cache hits on reads of RAM |
| `0x8000_0058` | MEM_MISSES | RO | ...and misses |
| `0x8000_005C` | MEM_MISMATCH | RO | reads where the card's byte differed from the bus's (noise until the working set is written; watch for a plateau) |
| `0x8000_0060` | MEM_SERVED | RO | reads answered by the card |
| `0x8000_0064` | MEM_LAST | RO | `{addr16, card byte, bus byte}` of the last mismatch |
| `0x8000_0068` | MEM_DIVERTED | RO | writes to a RamWorks bank the machine does not have, sent out on the bus as reads so the machine's own auxiliary memory is untouched — see MEMORY.md, "The RamWorks" |
| `0x8000_006C` | VIDHD_SLOT | RW bits 2:0 | the VidHD's slot, 0 = off; latched at RES', never MB_SLOT's, HD_SLOT's or FD_SLOT's; `rom` — see VIDHD.md |
| `0x8000_0070` | FB_CTRL | RW bit 0, W1 bit 8 | the floating-bus simulator: `serve` the simulated byte to the core (a level); W1 clear-counters; [22:16] the mode the prediction is built from (`locked`, `text`, `mixed`, `hires`, `page2` as displayed, `col80`, `store80`) — see FLOATING_BUS.md |
| `0x8000_0074` | FB_COMPARED | RO | floating-bus reads compared with the prediction |
| `0x8000_0078` | FB_MISMATCH | RO | ...that disagreed, on ordinary cycles (noise until the screen is drawn; watch for a plateau) |
| `0x8000_007C` | FB_LAST | RO | `{predicted, bus byte, line[8:0], cycle[6:0]}` of the last mismatch on an ordinary cycle (the hole and 80-column counts never overwrite it) |
| `0x8000_0080` | FB_LAST2 | RO | `{addr[7:0] of $C0xx, scanner address[15:0], mode[7:0]}` of the last mismatch |
| `0x8000_0084` | FB_OTHER | RO | `[15:0]` mismatches on screen-hole cycles, `[31:16]` on 80-column cycles — counted apart, see FLOATING_BUS.md |
| `0x8000_0088` | FB_PEEK | RW bits 14:0 | a byte of the side copy: `[14]` 0 = text (`[10:0]` from $0400), 1 = hi-res (`[13:0]` from $2000); `[23:16]` the byte |
| `0x8000_008C` | ACCEL_CTRL | RW bits 1:0, 23:8, 28; W1 bit 31 | the accelerated core (ACCELERATION.md): `[1:0]` mode - 0 off (the core locked to the bus, the old machine to the clock), 1 reads served on the card and every write on the bus, 2 reads and writes on the card; `[23:8]` the target, ops per bus cycle, 8.8 fixed point, 0 = unlimited; `[29]` fronts_dis - 1 bypasses both fronts on the IIgs build: the core takes the dispatcher's byte on both streams and neither front claims, retires or posts, so the machine runs as it did before rung 6 (a diagnosis level, GS.md rung 6); `[28]` swint_dis - 1 keeps the keyboard on the bus and the dummy parked at `$0000` (ACCELERATION.md "The keyboard in the dummies"), a level; `[27]` game_dis - 1 keeps the game port on the bus and the dummies at `$C000` alone (CXXX.md "The game port"), a level; W1 clear the ACCEL_* counters. What is slow is a matter of class alone: every `$Cxxx` access a slot answers rides the bus in every mode. Levels, safe under a running machine - except that leaving mode 2 for mode 0 or serving off runs the machine's stale RAM; the host refuses it |
| `0x8000_0090` | ACCEL_STAT | RO | `[0]` accelerating; `[1]` the core held by the governor; `[3]` the bus owns the op stream; `[7:4]` the sequencer's state; `[15:8]` event-merge overflows (must be 0); `[23:16]` fast ops decided twice; `[24]` the core's reset sequence has not yet reached `$FFFD` on the bus (every op rides the bus until it has - the IIe's MMU infers a reset from that sequence, not from RES′) |
| `0x8000_0094` | ACCEL_FAST | RO | ops served on the card |
| `0x8000_0098` | ACCEL_BUS | RO | the core's ops that rode a bus cycle; (FAST + BUS) / CYCLES is the ratio achieved |
| `0x8000_009C` | ACCEL_CYCLES | RO | bus cycles while accelerating |
| `0x8000_00A0` | ACCEL_WAIT | RO | clocks the core spent waiting to merge |
| `0x8000_00A4` | ACCEL_TURBO | RO | the instruction front's one-clock ops (ISTREAM.md) |
| `0x8000_00A8` | ACCEL_DLINE | RO | the data front's one-clock ops, reads and writes (DLINE.md). Every one of these paid the governor like any other op, so the ratio achieved is (TURBO + DLINE + FAST + BUS) / CYCLES - a display that leaves DLINE out reads a governed 8x as ~5x |
| `0x8000_00AC` | ACCEL_FAST_I | RO | the census of ACCEL_FAST, the dispatcher's ~8-clock ops (ACCELERATION.md "The census"): instruction-stream fetches of any class - the front missed or declined. The seven sum to ACCEL_FAST |
| `0x8000_00B0` | ACCEL_FAST_DRAM | RO | the census of ACCEL_FAST, the dispatcher's ~8-clock ops (ACCELERATION.md "The census"): data reads of RAM class - the data front missed. The seven sum to ACCEL_FAST |
| `0x8000_00B4` | ACCEL_FAST_DLC | RO | the census of ACCEL_FAST, the dispatcher's ~8-clock ops (ACCELERATION.md "The census"): data reads of the language card. The seven sum to ACCEL_FAST |
| `0x8000_00B8` | ACCEL_FAST_DROM | RO | the census of ACCEL_FAST, the dispatcher's ~8-clock ops (ACCELERATION.md "The census"): data reads of the system ROM ($D000-$FFFF). The seven sum to ACCEL_FAST |
| `0x8000_00BC` | ACCEL_FAST_DCX | RO | the census of ACCEL_FAST, the dispatcher's ~8-clock ops (ACCELERATION.md "The census"): data reads of the internal ROM in $C100-$CFFF. The seven sum to ACCEL_FAST |
| `0x8000_00C0` | ACCEL_FAST_WR | RO | the census of ACCEL_FAST, the dispatcher's ~8-clock ops (ACCELERATION.md "The census"): writes. The seven sum to ACCEL_FAST |
| `0x8000_00C8` | GAME_STAT | RO | the game port as the dummy loop last sampled it (CXXX.md "The game port"): `[2:0]` the buttons PB0..PB2, a level each; `[3]` pb_ok, all three sampled; `[4]` pdl_ok, a paddle measurement has completed; `[19:8]` paddle 0's sample, bus cycles from the strobe to the timer's fall (eleven a unit); `[31:20]` paddle 1's |
| `0x8000_00CC` | GAME_STAT2 | RO | `[11:0]` paddle 2's sample; `[23:12]` paddle 3's; `[31:24]` measurements completed, wrapping |
| `0x8000_00D0` | MOUSE_SLOT | RW bits 2:0 | the mouse card's slot, 0 = off; latched at RES', never MB_SLOT's, HD_SLOT's, FD_SLOT's or VIDHD_SLOT's; `[16]` rom loaded, `[17]` IRQ asserted, `[19:18]` the buttons, `[23:20]` the mode byte, `[31:24]` MOUSE_MOVEs applied — see MOUSE.md |
| `0x8000_00D4` | MOUSE_STAT | RO | `{y[15:0], x[15:0]}`: the position as the card holds it |
| `0x8000_00D8` | NSC_CTRL | RW bit 0 | the No-Slot Clock's lever (1 at reset); `[1]` time loaded, `[2]` reading out, `[3]` writes enabled, `[13:8]` comparison bit, `[21:16]` read-out bit, `[31:24]` unlocks — see NSC.md |
| `0x8000_00DC` | NSC_TIME | RO | the time the card holds, low half: `{hour, minute, second, centisecond}` BCD |
| `0x8000_00E0` | NSC_DATE | RO | ...high half: `{year, month, date, day of week}` BCD |
| `0x8000_00E4` | U2_SLOT | RW bits 2:0 | the Uthernet II's slot, 0 = off; latched at RES', never any of the five others'; `[11]` a command was dropped, `[15:12]` the sockets' `Sn_SR != 0`, `[23:16]` U2_CMDs sent, `[31:24]` U2_RX chunks landed — see UTHERNET2.md |
| `0x8000_00E8` | U2_STAT | RO | `{Sn_RX_RSR[15:0], Sn_TX_FSR[15:0]}` of socket 0 |
| `0x8000_00EC` | LINK_STAT | RO | the card's own view of the link, the UART status line's facts over USB3: `[0]` phi0 ticking (the card is in a powered machine), `[1]` capture enabled, `[6:2]` the link's last reset cause (`{TX stalled, no CLKOUT, LINK_RESET, watchdog, UART 'R'}`; the latest wins), `[15:8]` the chip-side snapshot `{txe, rxf, qcount, state}` taken as it fired, `[23:16]` resets so far, `[24]` DDR3 calibrated (RING_STATUS[25] again), `[25]` the ring engaged (RING_STATUS[23] again), `[31]` always set (the register's signature: gateware without it answers zero; since the boot lane an uncalibrated card answers too, so the calibrated bit is no longer the signature). One read answers "is there a link, and is it in a machine". (The UART status line that used to say the same is gone, 2026-09-19: with the ring's boot lane every card answers this register) |
| `0x8000_00F0` | AUDIO_CTRL | RW | the sound on the card (AUDIO.md): `[0]` the AUDIO_FRAMES stream on, `[1]` accepted and inert since 2026-09-14 (it chose the AYs' time base; they run in real time now, MOCKINGBOARD.md "Two sets of books"); readback adds `[16]` = the stream on |
| `0x8000_00F4` | AUDIO_RATE | RW | the sampler's NCO increment, `rate_hz * 2^32 / 1e8`; resets to 1 894 081 (44.1 kHz); the host trims it by ppm to hold its buffer |
| `0x8000_00F8` | AUDIO_STAT | RO | `[15:0]` samples sent, `[23:16]` samples dropped for a full FIFO, `[24]` the FIFO full now |
| `0x8000_00FC` | PRINTER_SLOT | RW bits 2:0 | the printer card's slot, 0 = off; latched at RES', never any other card's; `[16]` rom loaded, `[31:24]` $C0n0 writes seen — see PRINTER.md |
| `0x8000_00C4` | ACCEL_FAST_KBD | RO | the census of ACCEL_FAST, the dispatcher's ~8-clock ops (ACCELERATION.md "The census"): the internalized keyboard reads ($C00x from the parked-dummy latch). The seven sum to ACCEL_FAST |
| `0x8000_0100` | ACCEL_MAPS | RO | MMU map changes (`rtl/apple_mmu.sv` map_changed); cleared with the ACCEL_* counters |
| `0x8000_0104` | ACCEL_IDROP | RO | instruction-front lines a map change took out of service |
| `0x8000_0108` | ACCEL_IREVIVE | RO | ...and lines a later one put back |
| `0x8000_010C` | ACCEL_DDROP | RO | the same pair for the data front |
| `0x8000_0110` | ACCEL_DREVIVE | RO | |
| `0x8000_0114` | MEM_FILLS | RO | pages the page cache filled from the DDR3 — see PAGE_CACHE.md |
| `0x8000_0118` | MEM_FLUSHES | RO | ...and dirty pages written back |
| `0x8000_011C` | MEM_DECLINES | RO | line requests a page was not resident for |
| `0x8000_0120` | MEM_ROM | RO | the ROM load's flow control: `[0]` a chunk is draining, `[15:8]` chunks dropped for arriving during one, `[23:16]` absolute (extended-ROM) chunks landed, `[31:24]` the IIgs shadow duplicate's drops (must be 0) |
| `0x8000_0124` | GS_ADB | RO | the ADB micro's mouse path, `rtl/gs_adb.sv` dbg_stat; zero on a IIe |
| `0x8000_0128` | ACCEL_CORE_CYC | RO | core cycles (vbeam's ticks): the PLAIN acceleration ratio's numerator. Can tick twice a clock: wraps in 21 s at worst |
| `0x8000_012C` | ACCEL_BUS_CYC | RO | raw bus cycles: its denominator |
| `0x8000_0130` | DBG_SEL | RW bits 7:0 | the debug pair's select (GS.md rung 6): `[5:4]` the module - 0 the instruction front, 1 the data front, 2 the page cache, 3 the dispatcher and the top - and `[3:0]` the item; the item lists are the `dbg_val` muxes in rtl/iline.sv, rtl/dline.sv, rtl/page_cache.sv and rtl/master_top.sv.  `[7:6]` = 1 the bank census, 2 the data front's bank table, 3 the IIgs battery RAM (`[5:0]` = k, bytes 4k..4k+3) |
| `0x8000_0134` | DBG_VAL | RO | the selected counter or state snapshot.  From swhost's control socket: `regw 80000130 SEL` then `reg 80000134` |
| `0x8000_0138` | FD35_DRIVE | RW bits 1:0 | the 3.5" drive on the IIgs's IWM, live like FD_DRIVE1: `inserted` (its 0->1 edge is the insertion), `wp`; back: `[8]` stale, `[15:9]` track, `[16]` side, `[17]` the drive's motor, `[18]` the IWM's ENABLE, `[31:24]` seeks — see IWM35.md |
| `0x8000_013C` | FD35_STAT | W1 bits 1:0 | `[7:0]` late (fills after a read; bit 0 clears), `[15:8]` `{phases, q7, q6, drive_sel, apple35_sel}`, `[31:16]` fill_max in MICROSECONDS, seek to last chunk (bit 1 clears) — see IWM35.md |
| `0x8000_0140` | DDR3_DBG1 | RO | UberDDR3 `o_debug1` (our fork): `[4:0]` calibration state (17 = DONE), `[7:5]` lane, `[12:8]` reset-ROM step, `[17:13]` the lane's DQS IDELAY tap, `[22:18]` its DQ tap, `[23]` IDELAYCTRL ready, `[24]` write-late, `[25]` read-early, `[26]` added read pipe, `[31:27]` the highest state reached since the clock locked — see UBERDDR3.md |
| `0x8000_0144` | DDR3_DBG2 | RO | `[7:0]` the controller's own restarts from the alignment search, `[15:8]` restarts from a BIST mismatch, `[23:16]` IDELAYCTRL RDY drops, `[28:24]` the state at the last restart — sticky until the clock unlocks; `[31:29]` the write-level feedback of this calibration attempt: `[31]` sampled, `[30]` lane 1's answer, `[29]` lane 0's (1 = DQS rose while CK was high, i.e. DQS late of the CK edge; 0 = early) — see UBERDDR3.md rung 0 |
| `0x8000_0148` | DDR3_DBG3 | RO | `[5:0]` dqs_start_index, `[11:6]` stored, `[17:12]` target, `[23:18]` original target, `[30:24]` the lane's data start index, `[31]` every lane's write-level sample settled (five equal reads; 0 = a lane's sample timed out) |
| `0x8000_014C` | DDR3_EYE0 | RO | byte lane 0's read data eye: bit t = 1 when the alignment pattern still read back with the lane's DQ IDELAY at tap t (78 ps); measured after every calibration; the calibrated tap (DDR3_DBG1's DQ tap minus one) sits inside the run of ones and its distance to either end is the margin |
| `0x8000_0150` | DDR3_EYE1 | RO | byte lane 1's |
| `0x8000_0154` | GS_CLOCK_STAT | RO | the IIgs clock chip (rtl/gs_clock.sv): `[31]` bram_ok (a whole GS_BRAM landed), `[30:28]` the chip's state (0 idle, 1 time, 2 internal, 3 bram1, 4 bram2), `[27:16]` the machine's battery RAM writes (cleared only by a link reset), `[15:8]` bad strobes, `[7:0]` strobes (both since RES'); zero on a IIe.  Its 256-byte store reads through the debug pair: DBG_SEL `$C0 + k` gives bytes 4k..4k+3, low byte first — see GS_CONTROL_PANEL.md R0B |
| `0x8000_0158` | START | W1 bit 0 | the start hold (rtl/start_hold.sv): `[0]` pending - RES' is driven low, the whole machine waits for the host's checklist; writing 1 releases it - `[1]` cause the card's reset, `[2]` cause a RES' the hold did not cause, `[31:24]` holds since the card's reset.  Values latched at RES' latch at its release too, so what the checklist writes is taken as the hold lets go — see CLEAN_START.md |
| `0x8000_015C` | ROM_SUM | RO | the sum of every system-ROM chunk's bytes as they drained into the image, counted on each chunk's FIRST landing only (a retry after a lost ack does not add); cleared with rom_loaded by a link reset.  The host compares it with its own file once MEM_STAT rom_loaded is set — see CLEAN_START.md CS2 |
| `0x8000_0160` | PANEL_STAT | RO | the host's replies to our 65816 panel (PANEL_DMA): `[3:0]` blocks written into the machine, `[7:4]` messages dropped because the HD card's DMA was busy; four bits each, wrapping — see GS_CONTROL_PANEL.md R4 |
| `0x8000_0164` | FD35_WSTAT | RO | the 3.5" write path (`rtl/gs_iwm.sv`): `[7:0]` loads, `[15:8]` lands, `[23:16]` why the last flush, `[31:24]` flushes — see IWM35.md |
| `0x8000_0168` | TELEM_CTRL | RW bit 0 | `[0]` send a TELEMETRY message a second; clear at the card's reset (silent until asked), and a host that wants a run's baseline sets it BEFORE it releases START. RO `[15:8]` epoch (RES' releases seen), `[23:16]` samples skipped, `[31:24]` messages sent. A bitstream older than telemetry reads 0 here after the write, which is how a host knows to keep polling — see TELEMETRY.md |
| `0x8000_016C` | WIDE_U2_CMDS | RO | 32-bit totals of the event counts that can wrap inside a second (TELEMETRY.md layout 2), each following its narrow source a clock behind by `(now - before) mod 2^n`, cleared with it by the card's reset: U2_SLOT's cmds |
| `0x8000_0170` | WIDE_U2_RX | RO | ...U2_SLOT's rx chunks |
| `0x8000_0174` | WIDE_PRN_WRITES | RO | ...PRINTER_SLOT's writes |
| `0x8000_0178` | WIDE_HD_EXECS | RO | ...HD_SLOT's execs |
| `0x8000_017C` | WIDE_PANEL_DMAS | RO | ...PANEL_STAT's dmas |
| `0x8000_0180` | WIDE_AUDIO_SENT | RO | ...AUDIO_STAT's samples sent |
| `0x8000_0184` | DDR3_DBG4 | RO | UberDDR3 `o_debug4` (our fork), the CK write leveling of UBERDDR3.md rung 2, zero unless the bitstream was built with `CK_PHASE_SHIFT`: `[6:0]` the fine phase-shift step CK is parked at, `[13:7]` byte lane 0's crossing of CK's rising edge, `[20:14]` lane 1's, `[21]`/`[22]` whether each lane crossed inside the sweep, `[23]` the write leveling finished, `[29:24]` the sweep's half width in steps (so the step numbers have a scale: the sweep runs 0..2x that, and the phase it came in on is the middle). A step is 1/56 of the VCO period, 14.88 ps at 1200 MHz

**Every read-only field is read through a shadow flop** (the register cut,
TELEMETRY.md rung 0): a read is one clock older than it was, and a master that
raises the hold and sweeps the map - the telemetry sender - reads one instant
of all of it. What the host wrote reads straight from the register. DBG_VAL's
shadow alone follows through the hold: the sweep reads the debug space through
it while the hold is up, and what the hold freezes there is the words behind
the top's debug mux - its snapshot words and the clock histogram's copies.

Both BUILD words are stamped at synthesis by `build/build.sh` through `build.tcl`'s
`-generic`, so they describe the bitstream rather than whenever it was loaded.
**Zero means unstamped** — a GUI build, or gateware older than this map, which
never answers at all. Either way the host reports "unknown" rather than
rendering it as a date.

Three rules hold for the whole register space, and each exists to avoid a worse
failure than the one it replaces:

- **A read of an unimplemented address returns zero and still acks.** Withholding
  the ack would hang the bridge waiting for a reply that is never coming, and
  the host would see a dead link rather than a bad address.
- **A write to a read-only or unimplemented address is accepted and discarded**,
  and the reply carries what the register reads back *afterwards*. That is the
  cheap way for a host to tell a write that landed from one that did not,
  without a separate status path.
- **Every reply echoes the address it answers**, so replies can be matched to
  requests without assuming they come back in order.

One request is outstanding at a time; a second arriving before the first is
answered is dropped. The host is strictly request-response here, and making
this queue would add a depth and an overflow policy to serve a case that does
not occur. If a host ever does pipeline, the symptom is a missing reply rather
than a wrong one, because of the address echo.

**A reply never lands inside another message.** Every source of messages —
the reply, the card's notices, its application messages (HD_DATA, up to 129
words; FD_DIRTY, up to 254), the capture — is a master on one 32-bit Wishbone bus, and a message
is one burst: CYC held from the header to the last ack. The arbiter
(`msg_arb`) grants per CYC by fixed priority, in that order, and never
pre-empts a burst, which is Wishbone's own rule and is exactly message
atomicity. This matters more than it sounds: with no sync word and no
resynchronisation, an interleaved word does not break the stream loudly, it
makes it plausible and wrong from that point on. A master that drops CYC
mid-message is flagged (RING_STATUS bit 26, `T=1` on the UART).
`sim/reg_map_tb.sv` asserts it directly; `sim/msg_arb_tb.sv` hammers the bus
with random bursts. See `TX_RING.md`.

### The heartbeat period is the link's latency floor

`BUS_ENABLE free[7:4]` sets the card's idle heartbeat period to
`IDLE_TICKS >> n`, latched at enable alongside the source select so it cannot
change mid-capture. **Zero is the card's built-in default**, and that is what
makes this safe to graft onto an existing message: a host that never sets the
field sends zero and gets exactly the behaviour that shipped.

It is worth being able to move because the heartbeat is what *terminates the
host's read*. A 4-byte frame is a short packet, so it ends the bulk transfer and
the host gets its data; without one, an oversized read waits out its libusb
timeout. So the host cannot learn about data sooner than the next dispatch, and
the heartbeat period is the floor on that.

Measured on a live Apple at the default 100 µs, the host sees 12,861
data-bearing reads a second: a 1 KB dispatch every 251 µs (256 blocks at the
Apple's 4.1 MB/s) with two heartbeats between them. Three dispatches per 250 µs
is 12,000/s predicted against 12,861 observed, and 33% carrying the kilobyte
against 31% observed.

Shortening the period cuts the floor and costs two things, both of which want
watching: 4 bytes per heartbeat of bandwidth, and — the one that matters — **one
of the host's posted transfers per heartbeat**, since a short packet ends a
posted read. Ring depth is the host's protection against a scheduling stall, so
this trades latency against stall tolerance. Measure `min_posted` and the
overflow threshold, not just the latency.

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

### The silent-until-asked rule, which makes acquisition free

**A card must emit nothing but IDLE frames until the host asks it for
something.** A heartbeat is a single block, so a stream of heartbeats has a
frame boundary at *every* block boundary: a host attaching at any moment is in
sync with no acquisition step at all, and the first real frame it is sent lands
on a boundary it already knows.

This is why the bus snooper does not start capturing until BUS_ENABLE arrives,
and it is what makes having no resynchronisation safe in practice rather than
merely tolerable. A card that streamed before being asked would put the burden
back on the receiver, which — as measured above — cannot carry it.

The same holds in reverse. The card's receive parser assumes the first block
after a link reset is a header, which is true because the reset clears the
chip's buffers in both directions and the host opens the conversation.

## Two-way control

### Watchdog

While a capture is enabled, the card runs a **1 second watchdog**, reset by
**any well-formed message** — not only by heartbeats. A host that is talking
anyway needs to send nothing extra; the 100 ms IDLE heartbeat exists so that a
host with nothing to say still holds the link open.

**Expiry is treated as loss of sync, and loss of sync is not recoverable.** The
card pulses the FT601's `RESET#` for 1 ms, exactly as the `'R'` command does,
which discards unsent bus events, both async FIFOs, the chip's internal buffers,
and the enable state. The device re-enumerates and the host must reopen it.

A message *received* by the card of a type it does not consume is **not**
loss of sync and does not take that path. The length is in the header whatever
the type, so the card skips the payload by it and framing is kept; it then sends
an UNKNOWN_TYPE notice naming the type and length, and the host logs it. This
replaced a whitelist that reset the link on the first use of any type it
lacked — twice (MEM_ROM, VIDHD_ROM) a missing line in `ft601_msg_rx.sv`
looked exactly like a dead link. Now it looks like what it is.

### Clean disconnect

BUS_ENABLE with `enable = 0` stops a capture without any of the above: the event
FIFO is emptied, the card returns to emitting only heartbeats, and the link, the
USB device and the host's handle all stay up. **This is the path a normal
shutdown must take.** The watchdog reset exists for hosts that die, not for
hosts that finish.

### Overflow

If the event FIFO fills — a host that stopped reading, not a bus that is too
fast, since the link is 30–80× the event rate — the card sets an overflow flag,
**stops capturing**, and sends BUS_STATUS. Capture does not resume until the
host re-enables it.

Stopping is deliberate. A dump with silently dropped events in the middle is
worse than a short one: it claims the machine did something it did not. The
overflow flag makes the gap explicit and terminal, and the host's dump file ends
at a frame boundary.

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
   must not reset on burst boundaries. A stall longer than one idle window is
   the exception — see the idle timer below.
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
9. **Anything unmodelled.** The idle timer unsticks it — on a busy link as
   well as a quiet one, which is the whole of its value as a backstop.

### Idle timer

An unconditional heartbeat when **nothing has been dispatched** for ~100 µs
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

**What restarts it is the load-bearing part.** The quantity is time since the
*host* last received something, so the only events that may restart it are the
two that put a packet on the wire: a fill (the wrap of `buf_blocks`) and a
detected idle dispatch. Not our own TX FIFO going empty, and not a block being
handed to the chip — neither means the host got anything.

An earlier implementation reset the counter on `!fifo_empty`, which reads as
"the link is busy, no need for filler" and is wrong in the one situation the
timer exists for. Every case above is a way of *stopping*, so every case above
leaves the FIFO empty and the timer free to run; the backstop, by contrast,
covers a dispatch that was missed, and a dispatch is missed while data is
flowing. Queued data therefore held down the timer exactly when it was needed,
and the 100 µs bound became however long it took the chip's buffer to fill by
other means — 8 s to 132 s between stalls of ~6 ms each, on a streaming link,
with nothing ever lost. The 4-byte read that ends such a stall is the
signature: the buffer held only the heartbeat, so nothing had been dispatched
for the whole of it.

The timer also **free-runs**: expiry restarts the count rather than latching. A
one-shot is re-armed only by a delivery, which is the very thing whose absence
it reports, so a link that stays undelivered would be poked once and never
again. Free-running, it is poked once per window until something gets through.

The consequence for case 4: a TXE# stall *longer than one window* now leaves a
heartbeat owed, emitted when TXE# returns. That is deliberate — a chip that has
refused data for 100 µs has dispatched nothing for 100 µs — and it costs 4
bytes.

Emission needs only a message boundary (`blocks_left == 0`), not a quiet FIFO.
Waiting for `fifo_empty` to insert is the same mistake in a second place:
it defers the fix until the link goes quiet, when the debt that matters is the
one raised while it is busy. The heartbeat takes priority over real data for
the one cycle it occupies.

## Host-side rules

- Never announce a session length that is a multiple of 1024 when reading into
  a larger buffer (the errata's other half; see DERISK.md for the measurement).
  Exact-length reads are exempt — they are satisfied by length and never ask
  the chip to terminate.
- The receive parser must carry state across reads: a message may straddle any
  read boundary.
- IDLE messages are consumed and discarded at the link layer; their payload has
  no meaning.
