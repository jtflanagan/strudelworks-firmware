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
| `0x00` | IDLE | Link filler, **both directions**. Payload, if any, is discarded by the receiver. `len = 0` is the **heartbeat**: the single word `0x00000000`. |
| `0x01`–`0x0F` | — | Reserved for link-layer types: ones the FT601 layer may generate or consume on its own, parseable without application state. |
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
| `0x1F` | FD_TRACK | Host→card. One chunk of a track answering FD_SEEK: payload `[{seq, chunk, track, drive}]` then up to 252 words of nibbles; seven chunks make a track, the seventh clears the buffer's STALE. A chunk whose `seq` is not the drive's current one is dropped. |
| `0x20` | FD_SEEK | Card→host, **unsolicited**. Payload `[{seq, 0, track, drive}]`: the head is on a track the card does not hold; answer with seven FD_TRACK chunks carrying `seq`. |
| `0x21` | FD_DIRTY | Card→host, **unsolicited**. Payload `[{seq, chunk, track, drive}]` then up to 252 words: a track the machine wrote to, seven chunks, sent before the FD_SEEK that leaves it. |
| `0x22` | MEM_ROM | Host→card. One chunk of the IIe's 16 KB system ROM for the card's copy: payload `[{chunk[4:0]}]` then 128 words; 32 chunks make the ROM, in any order. See MEMORY.md. |
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
| `0x2C` | AUDIO_FRAMES | Card→host, **unsolicited once asked** (AUDIO_CTRL on). The sound on the card (AUDIO.md): n samples at the play rate, three words each - `{ay0, spk}`, `{ay2, ay1}`, `{seq, ay3}` - the speaker's and each AY chip's box average over one sample window (0..32767) and a running sample count. `free` = `{drops[7:0], n[7:0]}`, n = 32; `len` = 3n. A gap in `seq` is that many samples the card's FIFO dropped. |
| `0x2E` | GS_BRAM | Host→card. Payload 64 words: the IIgs's 256-byte battery RAM, four bytes a word, low byte first. Taken ALL OR NOTHING by `rtl/gs_clock.sv` - a partial image is worse than none, because the ROM checksums it, finds it wrong, and writes its own defaults over the slot settings it was shipping. The host sends one at start when `machine = iigs`, naming every slot it has put an emulated card in. See GS.md. |
| `0x2F` | ADB_KEY | Host→card. Payload one word `{16'd0, mods[7:0], is_up, keycode[6:0]}`: one ADB key event, with the modifier byte in `$C025`'s own bit order (1 shift, 2 control, 4 caps lock, `$40` option, `$80` command). THE CARD HOLDS THE KEYMAP, as a real ADB micro does, so what travels is a keycode and not a character: `rtl/gs_adb.sv` turns it into `$C000`'s ASCII with `rtl/adb_keymap.hex` (`tools/gen_adb_keymap.py`, from KEGS's own table) and queues the raw event for a Talk register 0. NOT THE ONLY SOURCE: the Apple's own keyboard feeds the same micro from the card, its ASCII run backwards into a keycode by `rtl/gs_kbd_a2.sv` (`rtl/adb_revmap.hex`, `tools/gen_adb_revmap.py`), with no message involved. See GS.md. |
| `0x30` | GS_TIME | Host→card. Payload one word: seconds since 1904-01-01 in the machine's LOCAL time. THE FEED IS THE CLOCK - the card keeps no time of its own, so `rtl/gs_clock.sv` holds what it was last sent and the host re-sends every second, exactly as it feeds the No-Slot Clock (NSC.md). Local rather than UTC because the Control Panel shows what the chip counts; 1904-01-01 is 2,082,844,800 seconds before the Unix epoch, and a 32-bit count from it runs out on 2040-02-06, which is the real part's limit. Sent before RES' is released so the ROM's first read of `$C033` is of the Pi's clock. See GS.md. |
| `0x31`–`0xFF` | — | Application, unassigned. |

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

A SKIP's word 1 is zero.  The 24-bit address regime of the IIgs is what
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
| `0x8000_0024` | RING_STATUS | RO | the DDR3 TX ring: `[21:0]` occupancy in lines, `[24]` full, `[25]` DDR3 calibrated, `[26]` a message was torn on the bus (sticky) — see TX_RING.md |
| `0x8000_0028` | KBD_CTRL | RW bits 1:0 | `lock` the machine's own keyboard out, `notify` ask for KBD_EVENT; `touched`, `taken`, `flushed`, `replaced` — see KEYBOARD.md |
| `0x8000_002C` | MENU_HOLD | RW bits 7:0, W1 bit 8 | the runtime menu's door into the same hold: `enable`, `hotkey`, `trigger`, `menus` — see RUNTIME_MENU.md |
| `0x8000_0030` | VBL_CTRL | W1 bits 1:0, RW bit 2, RW bits 31:16 | the video scanner lock: `start`, `probe`, `notify`, `probe_addr`; `state`, `locked`, `pal`, `busy`, `err` — see VBL.md |
| `0x8000_0034` | VBL_STAT | RO | `[15:0]` mismatches in the last verify pass, `[31:16]` the slip of a re-lock — see VBL.md |
| `0x8000_0038` | VBL_POS | RO | `[14:0]` the cycle within the frame now, `[23:16]` frames, `[31:24]` locks — see VBL.md |
| `0x8000_003C` | FD_SLOT | RW bits 2:0 | the floppy controller's slot, 0 = off; latched at RES', never MB_SLOT's or HD_SLOT's; `rom`, `seeks` — see FLOPPY.md |
| `0x8000_0040` | FD_DRIVE1 | RW bits 21:0, W1 bit 22 | what is in drive 1, live: `inserted`, `wp`, `nibbles`, `tracks`, `flush`; `stale`, `dirty`, `phase` — see FLOPPY.md |
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
| `0x8000_008C` | ACCEL_CTRL | RW bits 1:0, 23:8, 28; W1 bit 31 | the accelerated core (ACCELERATION.md): `[1:0]` mode - 0 off (the core locked to the bus, the old machine to the clock), 1 reads served on the card and every write on the bus, 2 reads and writes on the card; `[23:8]` the target, ops per bus cycle, 8.8 fixed point, 0 = unlimited; `[28]` swint_dis - 1 keeps the keyboard on the bus and the dummy parked at `$0000` (ACCELERATION.md "The keyboard in the dummies"), a level; `[27]` game_dis - 1 keeps the game port on the bus and the dummies at `$C000` alone (CXXX.md "The game port"), a level; W1 clear the ACCEL_* counters. What is slow is a matter of class alone: every `$Cxxx` access a slot answers rides the bus in every mode. Levels, safe under a running machine - except that leaving mode 2 for mode 0 or serving off runs the machine's stale RAM; the host refuses it |
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
| `0x8000_00EC` | LINK_STAT | RO | the card's own view of the link, the UART status line's facts over USB3: `[0]` phi0 ticking (the card is in a powered machine), `[1]` capture enabled, `[4:2]` the link's last reset cause (`{0, watchdog, UART 'R'}`), `[15:8]` the chip-side snapshot `{txe, rxf, qcount, state}` taken as it fired, `[23:16]` resets so far, `[24]` DDR3 calibrated (RING_STATUS[25] again). One read answers "is there a link, and is it in a machine"; the UART is for the card that answers no register at all |
| `0x8000_00F0` | AUDIO_CTRL | RW | the sound on the card (AUDIO.md): `[0]` the AUDIO_FRAMES stream on, `[1]` the AYs clocked by the real bus's phi0 rather than the core's time; readback adds `[16]` = the stream on |
| `0x8000_00F4` | AUDIO_RATE | RW | the sampler's NCO increment, `rate_hz * 2^32 / 1e8`; resets to 1 894 081 (44.1 kHz); the host trims it by ppm to hold its buffer |
| `0x8000_00F8` | AUDIO_STAT | RO | `[15:0]` samples sent, `[23:16]` samples dropped for a full FIFO, `[24]` the FIFO full now |
| `0x8000_00FC` | PRINTER_SLOT | RW bits 2:0 | the printer card's slot, 0 = off; latched at RES', never any other card's; `[16]` rom loaded, `[31:24]` $C0n0 writes seen — see PRINTER.md |
| `0x8000_00C4` | ACCEL_FAST_KBD | RO | the census of ACCEL_FAST, the dispatcher's ~8-clock ops (ACCELERATION.md "The census"): the internalized keyboard reads ($C00x from the parked-dummy latch). The seven sum to ACCEL_FAST |

Both are stamped at synthesis by `build/build.sh` through `build.tcl`'s
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
