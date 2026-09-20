# The Uthernet II: a W5100 on the card, the Pi's network behind it

Status: **✅ on hardware, 2026-09-05; shares slot 3 with the VidHD since 2026-09-06** (bit WNS +0.178, `$C0B5-7` and `$C300` both answering in 3 by BASIC probe; then the user's own configuration with `u2 = 3` beside the VidHD, tested by the user the same day). `rtl/uthernet2_card.sv`
and the host's `src/uthernet2.cpp` / `src/net_backend.cpp` exist;
`sim/run_uthernet2_tb.sh` passes; the host's `u2_test` passes on the Pi
(ARP, DHCP, UDP, TCP connect and listen through the slirp backend); the
bit builds at WNS +0.118 (LUTs 35.5% -> 40.2%, block RAM 57.5 -> 61.5
tiles). On hardware Contiki's IPCONFIG configured the Apple by DHCP from
slirp at 1x; at 4x the card's pointer stepped on the driver's dummy
commits (below, "What hardware taught"); with that fixed (bit at WNS
+0.090, SRAM) Contiki's IPCONFIG configured the Apple by DHCP at 4x with
two frames each way and nothing dropped, and WGET resolved google.com
through slirp's DNS forwarder and pulled 95 KB through its NAT - the
first Internet traffic on the card. Written after reading AppleWin's
`Uthernet2.cpp` (the project's reference for the Apple side) and the two
drivers that matter (Contiki's `w5100.S`, IP65's `w5100.s`), with the Pi's
side chosen for Linux rather than ported from Windows. The test images are on
the Pi: `disks/contiki-apple2.po` (plus the three `.dsk`s of the same
release), the user's Contiki build with its W5100 driver. `libslirp-dev`
4.8.0 is installed on the Pi and in the cross sysroot.

## The card as the software sees it

The Uthernet II is a WIZnet W5100 behind four bytes of DEVICE SELECT and
nothing else - no ROM, no I/O SELECT page, no interrupt the software relies
on. Only A0 and A1 are decoded, so `$C0n0-$C0n3` alias `$C0n4-$C0n7`:

| address | register |
|---|---|
| `$C0n4` | the W5100's mode register (MR): bit 1 auto-increment, bit 7 reset |
| `$C0n5` | address high |
| `$C0n6` | address low |
| `$C0n7` | data: the byte at the address, which then steps if AI is set |

Behind the data port is the W5100's 32 KB map: the common registers at
`$0000-$002F` (gateway, subnet, MAC, IP, retry, the RX/TX memory splits), four
sockets' registers at `$0400`, `$0500`, `$0600`, `$0700` (mode, command,
status, ports, peer, the TX free size / read / write pointers, the RX size /
read pointer), 8 KB of TX buffer at `$4000` and 8 KB of RX buffer at `$6000`,
split between the sockets by RMSR/TMSR (the reset split is 2 KB each; both
Apple drivers set `$0A`: 4 KB each to sockets 0 and 1). The auto-increment
wraps `$5FFF -> $4000` and `$7FFF -> $6000` (the manual, page 12). The chip
does TCP, UDP and raw IP itself, or hands the program raw Ethernet frames
(MACRAW).

**What Apple II software actually does with it.** Both stacks in the wild
are software stacks: Contiki carries uIP, IP65 is a stack. Each opens socket
0 alone, in MACRAW with the MAC filter (`Sn_MR = $44`), and then lives on
four things: poll `Sn_RX_RSR` until non-zero, read a frame out of the RX ring
through the data port (a 2-byte length then the frame), advance `Sn_RX_RD` and
issue RECV; write a frame into the TX ring, advance `Sn_TX_WR`, issue SEND and
poll `Sn_CR` back to zero. Neither touches an interrupt register; both check
`Sn_TX_FSR` before writing. The chip's own TCP/UDP sockets are the road less
travelled (ADTPro's Uthernet II mode, a few W5100-native tools), and they are
supported because AppleWin supports them and the cost on top of MACRAW is
small - but MACRAW is what the Contiki image will exercise, and it is the
path that has to be right first.

## AppleWin's model, and why its Windows half does not fit

AppleWin's `Uthernet2` is a faithful register model - the memory map, the
pointer arithmetic, the socket state machine - and it is ported here as the
Mockingboard's and the mouse's were: the model in gateware, AppleWin's rules
kept one for one. Its network half is two things:

- **TCP and UDP sockets** become non-blocking BSD sockets on the host: OPEN
  is `socket()`, CONNECT is `connect()` with SYNSENT until the socket is
  writable, SEND is `sendto()`, a read of `Sn_RX_RSR` pulls with `recvfrom()`
  into the RX ring with the W5100's header in front (8 bytes for UDP, none
  for TCP). Portable; kept as is.
- **MACRAW and IPRAW** go through Npcap: the guest's frames are injected onto
  the host's own NIC with the guest's MAC as source, and every frame the NIC
  sees is read back in promiscuous mode and filtered by MAC. That is the
  awkward bridge. It needs a kernel capture driver and administrator rights;
  it cannot work over Wi-Fi at all (an access point drops frames whose source
  MAC is not the station's, and the Pi is on Wi-Fi today - eth0 has no
  carrier); the guest can never reach the host itself (the NIC does not loop
  its own injected frames back); and the host's stack sees the guest's
  traffic as foreign and answers some of it (RST to a TCP SYN for a port it
  owns). AppleWin's answer to the last problem is "virtual DNS", a register
  extension the real card does not have.

So the register model is taken and the bridge is not.

## The split

**The W5100 lives on the card.** Its registers, its 16 KB of ring buffers,
the address pointer and the auto-increment, the socket state machine and the
pointer arithmetic behind OPEN/SEND/RECV/CLOSE - all of it in
`rtl/uthernet2_card.sv`, on the peripherals' view of the op stream like the
mouse (CXXX.md, "The on-card slots"): a bus cycle claimed through
`apple_bus_write`'s data window in mode 0, a fast op served at three clocks
in the closed regime. The reason is the same as for every on-card slot, only
more so: a stack polls `Sn_RX_RSR` in its main loop, six data-port accesses a
poll, forever, and reads a frame a byte at a time; any of that on the bus is
two cycles each, and any of it across USB is a hundred microseconds each.

**The network lives on the host.** Frames and sockets are the Pi's, in
`src/uthernet2.cpp`. The card tells the host what the program asked for, the
host tells the card what came back, and the messages between them are the
only coupling. Specifically **the host mirrors nothing from the capture
stream** - unlike the Mockingboard, which reconstructs its AY from the VIA
writes in the stream. That would be tempting (every write is kept, even
sparse) but it does not work here: the data pointer moves on READS too, and a
driver reads `Sn_RX_RSR` then `Sn_RX_RD` in one auto-incrementing run before
it writes anything, so a mirror needs the reads, and the door drops fast
reads on a sparse capture for exactly the reason we want it to - a Contiki
main loop is a hundred thousand data-port reads a second at 1x and millions
accelerated. The card is authoritative and says what the host needs, when
the host needs it.

### Card -> host

- **`U2_CMD` (`0x28`)**, unsolicited, on every write to a socket's `Sn_CR`
  and on a reset (MR bit 7 or RES'). `free[1:0]` the socket, `free[15:8]` the
  command byte (`$01` OPEN, `$02` LISTEN, `$04` CONNECT, `$08` DISCON, `$10`
  CLOSE, `$20` SEND, `$40` RECV; `$00` for a reset). Payload 24 words: the
  common registers `$0000-$002F` then the socket's `$0400+n*$100 .. +$2F`, as
  bytes, the card's copies at the moment of the command - so the host has the
  MAC, IP, gateway and subnet when it needs them for OPEN, the peer and ports
  for CONNECT and UDP sends, `Sn_TX_RD/WR` for a SEND's length, and `Sn_RX_RD`
  for a RECV, all from one message shape. The card clears `Sn_CR` on the
  same clock (the chip auto-clears it; Contiki polls it back to zero).
- **`U2_TX` (`0x29`)**, unsolicited, after the `U2_CMD` of a SEND: the bytes
  from `Sn_TX_RD` to `Sn_TX_WR` out of the socket's TX ring, in chunks of up
  to 255 words. `free` = `{bytes[11:0], last, first, sock[1:0]}`, so a chunk
  is self-describing and the host reassembles by socket. A MACRAW frame is at
  most 1514 bytes (two chunks); the ring's whole 8 KB is nine. The sender is
  the floppy's FD_DIRTY machine over again: port B of the ring RAM reads the
  next word on the clock the previous is taken, and `msg_master` holds CYC
  across each chunk.

On SEND the card moves `Sn_TX_RD` up to `Sn_TX_WR` at once, so `Sn_TX_FSR`
reads full again immediately - AppleWin's behaviour, which both drivers are
happy with (the real chip frees the space when the frame has left). On RECV
the card recomputes `Sn_RX_RSR = Sn_RX_WR - Sn_RX_RD` (AppleWin's
`updateRSR`), and needs nothing from the host to do it.

### Host -> card

- **`U2_RX` (`0x2A`)**: bytes to append at the socket's RX write pointer,
  with the W5100's header already in front - 2 bytes of length for MACRAW
  (the length includes itself), 4 of source IP + 2 of length for IPRAW, 4 of
  IP + 2 of port + 2 of length for UDP, nothing for TCP - exactly AppleWin's
  `writeDataMacRaw` and friends. `free` = `{bytes[11:0], 0, 0, sock[1:0]}`,
  payload the bytes packed four a word. The card writes them into the ring
  from `Sn_RX_WR`, wrapping in the socket's region, advances `Sn_RX_WR` and
  adds to `Sn_RX_RSR`. The host never sends more than the room it knows: the
  ring's size less what it has appended and not yet seen released by a
  RECV's `Sn_RX_RD` - a conservative view, since the stream of commands
  lags, and it errs toward waiting. A frame that does not fit is dropped
  and counted, as AppleWin drops it.
- **`U2_STAT` (`0x2B`)**: a socket's status from the host. `free` =
  `{sr[7:0], sock[1:0]}`; optional payload two words `{dport, dipr}` when
  a LISTEN accepted a peer (the chip fills `Sn_DIPR/DPORT` then). This is
  how SYNSENT becomes ESTABLISHED or CLOSED, how a peer's close or an error
  shows up (`$00`), and how a LISTEN completes. MACRAW, IPRAW and UDP need
  no status from the host: the card sets `$42`, `$32`, `$22` on OPEN itself,
  as AppleWin does, and the host only says `$00` if `socket()` failed.

Four message types, two each way, and the whole of the network - frames,
sockets, addresses, timeouts - on the side that has a kernel.

### The RTL

- **The rings**: 16 KB as four byte-lane block RAMs of 4 KB (the floppy's
  arrangement), 4 RAMB36 of the Pt's 135 tiles (57.5 in use). Port A is the
  program's: a byte read or written at the data pointer. Port B is the
  host's: a `U2_RX` payload word is four consecutive bytes landing at an
  arbitrary ring offset, which with four lanes is one write per lane at
  `(base>>2)` or `(base>>2)+1` - one clock a word, no FIFO, and the same
  per-lane trick reads a `U2_TX` word from an arbitrary `Sn_TX_RD`. The
  parser delivers at most a word a clock, so the port keeps up by
  construction.
- **The registers**: the 240 bytes the program can address (common `$00-$2F`,
  four sockets' `$00-$2F`) in distributed RAM, read combinationally, with the
  computed ones overlaid: MR, `Sn_SR`, `Sn_CR` (always 0), `Sn_TX_FSR` (from
  `Sn_TX_RD/WR` and the split), `Sn_RX_RSR`, `Sn_TX_RD` and `Sn_RX_WR`
  (the card's). RMSR/TMSR writes recompute each socket's base and size
  (AppleWin's `setRXSizes/setTXSizes`, including the clamp when the splits
  overrun 8 KB). Reads outside the map return 0; the reserved holes are not
  storage.
- **The data port's timing.** A claimed read's byte must be registered at
  present, a clock after the dispatch, with the decision two clocks later
  (the mouse's contract). The byte at the pointer is PREFETCHED: whenever the
  pointer changes - an address write, an auto-increment at commit - port A
  reads the new byte and it is there two clocks later, and a register byte
  is combinational anyway. A program cannot present the next data-port op
  within a clock of the previous commit (the fetch between takes at least
  one), so the byte is there for it. The bench drives the port at the
  sequencer's tightest op spacing (as the No-Slot Clock's does) to prove that
  margin; if it shows a gap, the floppy's `stall_o` route is the fallback -
  hold the core's next op until the prefetch lands - and it is the only
  reason this card would ever hold the core.
- **Where it hangs**: `apple_mmu` q_slot gains a fifth slot register, DEVICE
  SELECT only (`slot_dev`, never a page - the card has no ROM), so the four
  registers are on-card ops in the closed regime and bus cycles in mode 0.
  Never quiet (every data-port access moves the pointer), no settle. The
  door keeps the writes and drops sparse reads as for every slot; nobody on
  the host consumes either.
- **Reset**: RES' and MR bit 7 reset the W5100 as AppleWin's `Reset` does -
  registers to their reset values (`RTR $07D0`, `RCR $08`, splits `$55`,
  `Sn_DHAR` all-ones, `Sn_TTL $80`, `PTIMER $28` - the real value, see
  below), sockets closed, pointers zero - and send `U2_CMD` reset so the
  host drops its sockets. The data pointer survives a RES' (the manual,
  page 10: it is not reset), and is zeroed at the card's own reset.
- **`U2_SLOT`, `0x8000_00E4`**: `[2:0]` desired (RW, 0 off), `[10:8]` active
  (MOUSE_SLOT's contract, latched at RES' and at a boot release, yielding to
  the Mockingboard, the disk, the floppy and the mouse - and SHARING with the
  VidHD, a page-only card against this device-select-only one: 2026-09-06,
  the user's call), `[15:12]` the four sockets' open bits, `[23:16]` `U2_CMD`s
  sent, `[31:24]` `U2_RX` chunks landed, both wrapping. **`U2_STAT`,
  `0x8000_00E8`**: `{sn0_rx_rsr[15:0], sn0_tx_free[15:0]}` - socket 0's two
  numbers, the ones a bring-up session watches.

## The host

`src/uthernet2.cpp` is AppleWin's `Uthernet2` with its memory taken away:
four `Socket`s (fd, status, header size, the RX accounting above), the
command handler switching on `U2_CMD`, the TX reassembly, and behind a
`NetBackend` interface the frames. It runs on its own thread with a
`poll()` over the sockets, the backend's descriptors and an eventfd the
ingest thread kicks when a `U2_CMD`/`U2_TX` lands; outbound `U2_RX`/`U2_STAT`
go through a bounded queue the link's owner drains, as `MouseFeed` does.

**Two frame backends, one interface.**

- **`slirp` (the default).** libslirp is QEMU's user-mode network: it takes
  raw Ethernet frames from the guest and is, to the guest, a whole network -
  ARP, a DHCP server, a DNS forwarder, a gateway - while on the host it is
  nothing but ordinary sockets the Pi already lets any process open. No
  privileges, no bridge, no capture driver; it works over Wi-Fi because no
  foreign MAC ever reaches the air; the guest reaches the Pi itself at the
  gateway's address, the LAN and the Internet through NAT, and DNS through
  the forwarder. The guest is `10.0.2.15/24`, gateway `10.0.2.2` (the Pi),
  DNS `10.0.2.3`, by DHCP or typed into ETHCONFIG; ports the guest serves are
  reachable from outside through forwards (`u2_fwd = tcp:2323:23`, the
  QEMU rule). ICMP works (libslirp answers pings itself). The cost is that
  the guest is NATed: it is not a peer on the LAN, and nothing on the LAN
  can discover it - which is the trade every emulator on a laptop makes,
  and the right default for a card whose users will type an address.
- **`tap:NAME`.** A TAP device the user has made and attached as they like -
  bridged onto the wired eth0 when the cable is in, or routed - gives the
  guest a real presence on the LAN with its own MAC, the way the physical
  card has it. swhost opens `/dev/net/tun` on a device that already exists
  and is owned by its user, so it needs no capability of its own; the
  making is a one-time `ip tuntap add mode tap user strudel name apple2`
  plus a bridge, documented, not automated. This is the road for anyone
  who wants the Apple to be a server on the LAN, and it is wired-only in
  practice, for the same Wi-Fi reason.

Injecting onto the Pi's own NIC - AppleWin's road, `AF_PACKET` here -
is deliberately absent: everything it can do, `tap` does without the
promiscuous-mode traffic and the host-stack fights.

**MACRAW** frames from the card go to the backend as they are (AppleWin's
`sendDataMacRaw`); frames from the backend go to the card if socket 0 is
MACRAW, through the MAC filter when `Sn_MR` bit 6 asks (ours and broadcast -
AppleWin's `receiveForMacAddress`), with the 2-byte header.
**IPRAW** wraps a payload into an IPv4 frame with the socket's protocol/TOS/
TTL (AppleWin's `createETH2Frame`) and hands it to the backend, and unwraps
matching frames coming back (`getIPPayload`); it is how a program pings.
**TCP/UDP** are the host's sockets exactly as in AppleWin, plus LISTEN
(`bind`/`listen`/`accept`, which AppleWin lacks; a low port needs
privilege and says so in the log). The host's own DNS resolves nothing for
the guest - the guest resolves through the backend, as a real card does.

**Config and menus.** `u2 = off | on | auto | SLOT` (auto: 3 - Contiki's,
IP65's and AppleWin's default - unless something is there, else the lowest
free slot), `u2_net = slirp | tap:NAME`, `u2_fwd = ...` repeatable, `u2_dump = PATH`
for bring-up.
An ETHERNET row on both menus with the slot, like MOUSE. `net` on the
control socket for the sockets' states, the counters and the backend.

## Proof

- `sim/uthernet2_tb.sv` (Verilator first): the four slot registers driven the
  way Contiki's driver drives them - reset, MR with AI, SHAR, RMSR/TMSR `$0A`,
  socket 0 MACRAW OPEN; a frame written into TX with the pointer wrapping at
  the region's end, SEND, and the `U2_CMD` + `U2_TX` chunks checked word for
  word on the tx stream; `U2_RX` chunks through the real message parser into
  RX at an unaligned write pointer across the wrap, `Sn_RX_RSR` counted, the
  frame read back through the data port, `Sn_RX_RD` advanced, RECV, RSR zero;
  the auto-increment wraps at `$6000` and `$8000`; `Sn_CR` reading zero; the
  splits' arithmetic against AppleWin's for every RMSR value; MR bit 7. At
  the sequencer's tightest op spacing, per above. `sim/run_reg_map_tb.sh`
  gains `U2_SLOT` and the six-way clash.
- The accel bench and the ProDOS boot bench unchanged (no card in them).
- Host `u2_test`: the W5100 host half against the slirp backend with no
  card: a MACRAW OPEN, a DHCP DISCOVER as `U2_TX`, and the OFFER must come
  back as a `U2_RX` with the right header and a `10.0.2.x` lease; an ARP for
  the gateway answered; a UDP socket's send/receive against a local echo;
  a TCP CONNECT to a local listener through SYNSENT to ESTABLISHED.
- **On hardware**: Contiki from `disks/contiki-apple2.po` - ETHCONFIG
  (W5100, the slot), DHCP, the web browser fetching a page from the Pi at
  `http://10.0.2.2/` (a `python3 -m http.server` there) and one from the
  Internet, IRC or telnet to a real host; at 1x and accelerated. Then an
  IP65 program (Telnet65 or the `ip65` samples) for the second driver.

## What hardware taught

- **A dummy's commit after the window.** The view hides the driver's
  dummies for a slot op's window, but a dummy PRESENTED inside the window
  COMMITS after it, with its own address - `$C063` or `$C067`, the game
  port's probes - and a peripheral that keys on `op_addr[1:0]` at the
  commit under a hit registered at the present sees a read of its data
  port. At 4x that stepped the W5100's pointer between two of Contiki's
  SHAR writes (`00 08 DC A2 A2 A2` landed as `00 08 00 DC A2 A2`, the
  last byte in SIPR: "IP 162.0.0.0"), the socket never opened, and IPCONFIG
  hung on "Requesting..."; at 1x, with no dummies, the same request
  configured the Apple. The card now consumes its hit at the op's own
  commit - one op, one commit - and the bench drives the stray commit. The
  mouse card has the same shape (`dev_read` on `op_addr[1:0]` under
  `hit_dev_q`); its exposure is a stray clear of the PIA's CRB interrupt
  flags, and it is noted here rather than changed.
- **A read of the address registers moved the pointer.** `ptr_moves`
  did not distinguish a write of `$C0n5`/`$C0n6` from a read; the bench's
  pointer checks passed by luck (a zero high byte) until a read after the
  chip's reset showed it.
- **Functions in combinational paths.** iverilog re-evaluates a
  continuous assignment on its arguments only, not on module state a
  called function reads, and an `always_comb` that calls a function with
  a local variable retriggers itself forever; two `always_comb` blocks
  sharing a loop variable do the same. The reset values are a ROM built
  in an `initial`, the overlays are explicit blocks, and functions are
  called from clocked blocks only.
- **A full capture over Wi-Fi at 4x** (~16 MB/s) took the Pi off the
  network; traces for this work are recorded on the Pi's own disk
  (`swtrace --host 127.0.0.1`) and the accesses extracted there.
- **The boot-menu-off flow** with a bare programmatic RES' does not boot
  a disk on this card; the user's flow is the menu, and a test that
  wants a booted machine goes through it (`boot_menu=on`, `continue`).

## What Marinetti and Webber exercised (2026-09-20)

The first real traffic through this card, and the first thing ever to reach the
MACRAW ring's WRAP. Webber 1.1.5 (a IIgs web browser, http only) over Marinetti
on the starter kit image, slirp behind it:

| | frames | bytes | the ring |
|---|---|---|---|
| DHCP alone | 2 tx / 2 rx | 684 / 1,184 | nowhere near it |
| one page | 29 tx / 25 rx | 3,619 / 8,048 | 144 bytes short of the first wrap |
| a second page | 139 tx / 105 rx | 16,749 / **26,778** | **3.3 times round** |

At the end: `s0 rsr 0, unread 0/8192, fsr 8192` - the ring empty and whole, so
`Sn_RX_WR` and `Sn_RX_RD` crossed the 8 KB boundary at least three times with
nothing stranded. 273 commands. DNS, TCP and HTTP all ride above MACRAW in
Marinetti's own software, so the card sees only raw frames either way - the
same shape Contiki gives it, and a great deal more of it.

SLOT 4 IS THE GS's PLACE FOR THIS CARD and it needs no "Your Card" mark: the
Uthernet is DEVICE SELECT only, `hit_dev` decodes $C0n4-$C0n7 from the assigned
slot alone with no SLOTROMSEL term, and the MMU routes the range through
`slot_dev(swi_u2_slot)`. The host was marking the slot anyway, which would have
cost slot 4 the machine's own ADB mouse (and slot 3 its 80-column firmware);
that is fixed in the host's `pipeline.cpp`.

## Deliberately not there

- **Interrupts.** The W5100 has IR/IMR and the card can route INT to the
  slot's IRQ, but neither driver in the wild uses it and AppleWin does not
  model it. If a program appears that does, the mouse's short route is
  there.
  **MARINETTI TESTED AND IT DOES NOT (2026-09-20).** The IIgs's TCP/IP stack
  was the obvious candidate to break this bet - a GS/OS stack that runs under
  the Scheduler had every reason to want an interrupt - so it was run on the
  machine: Ewen Wannop's Uthernet II link layer under Marinetti 3.0b11, from
  his GS/OS starter kit, with the card in SLOT 4. It opens socket 0 in MACRAW,
  writes SHAR, and POLLS, exactly as Contiki and IP65 do. The DHCP handshake
  (DISCOVER / OFFER / REQUEST / ACK, 2 frames each way) completed, and both
  replies were READ OUT of the RX ring - `rsr 0`, `unread 0/8192` - which is
  the proof it found them by polling and not by waiting on an interrupt that
  this card cannot raise.
- **AppleWin's virtual DNS.** A register extension real hardware lacks,
  invented to work around the Npcap bridge's host problem; with slirp the
  guest resolves names itself. `PTIMER` reads `$28` as on the real chip.
- **PPPoE, IPv6.** Not the W5100's, not the Apple's.
- **A mirror on the host.** See "The split".
- **`u2_mac`.** The MAC is always the program's (the driver writes SHAR);
  the key described in an earlier draft was dropped. `u2_dump = PATH`
  exists instead, for bring-up: every frame in and out, as hex.
- **Bridging onto the Pi's NIC.** See "The host".

## Open for the user

1. ~~Default slot when 3 is taken: with `vidhd = 3` in the user's config
   today, `auto` would land the card in slot 1.~~ Settled 2026-09-06: the
   VidHD claims only the `$Cn00-$CnFF` page and the Uthernet II only
   `$C0n0-$C0nF`, so the two share slot 3 - the card's latch, the host's
   config cross-checks, its start-up check and both menus all allow exactly
   that pair, and `auto` lands in 3 with the VidHD there. The Contiki
   disk's config records the slot; ETHCONFIG changes it.
2. `slirp` as the default over `tap`. The design assumes it.
3. Whether `U2_STAT`'s two numbers are the right ones to watch, or socket 0's
   `Sn_SR` and the command count would serve a bring-up better.

## Making it smaller (2026-09-20)

With the card proven on the GS, the next question was what it costs. In the
50T candidate's build it was **2564 LUTs, 1181 flip flops and 4 block RAMs** -
about a tenth of the whole design, and about 7% of a 50T's 32.6k LUTs. Three
cuts, each measured on its own by an out-of-context synthesis of the card at
100 MHz (`build/synth_ooc.sh --top uthernet2_card --src rtl/common/uthernet2_card.sv
--src rtl/common/fd_bank.sv`), with `sim/run_uthernet2_vl.sh` green after each:

| | LUTs | of which logic | LUTRAM | FFs |
|---|---|---|---|---|
| baseline | 2717 | 2499 | 218 | 1158 |
| the fresh bit per word | 2266 | 2048 | 218 | 936 |
| one register read, time-shared | 1863 | 1741 | 122 | 931 |
| the regions walked | 1804 | 1650 | 154 | 882 |

**−913 LUTs, −34%** out of context. Measured in the IIgs build's routed
checkpoint, where the card was **2575 LUTs / 1181 FFs**, the finished work -
the three cuts plus the bounded wait the second one turned out to need
(below) - leaves it at **1889 LUTs / 952 FFs: −686 LUTs, −26%, −229 flip
flops.** The bounded wait itself cost 135 of those LUTs back.

- **The fresh bit per WORD, not per byte.** Four 128-bit vectors - 512 flip
  flops, each with its own lane-qualified clear - said what one vector says:
  a byte lane is never read without the rest of its word being readable. A
  program write into a still-fresh word now stamps the other three lanes with
  their reset constants at the same commit, so the word is whole from then on.
  Same reads, same one-clock reset. No cycles. −451 LUTs, −222 flip flops.
- **One read of the register file, time-shared.** The program reads a byte at
  the pointer and the sender reads the 24 words a `U2_CMD` carries; that was
  the whole overlay built twice - the stored word, the reset constants, the
  four sockets' computed registers. The sender now BORROWS the port on the
  clocks the program is not using it and waits a clock when it loses, which it
  can afford: the program's read is registered at `op_present` and its write
  reads at `op_commit`, and the sequencer's earliest next present is a commit
  plus two, so there is always a free clock in an op. It costs the sender one
  extra clock a word - 48 a command instead of 24, at worst one word per op
  cycle under the tightest stream - and never a clock of the core's.
  −403 LUTs, and the register file's second read port with them (LUTRAM 218
  -> 122). This is the cycles-for-logic trade, and it is the biggest one here.
  **It also hung a IIgs - see below. Asking for a free clock is not enough;
  the wait has to be bounded.**
- **The regions walked, not unrolled.** `region_base(n)` summed n terms and
  `region_size(n)` called it twice more, for four sockets and two registers,
  rebuilt every clock - a dozen adders standing for two bytes that move once
  at setup. A write to RMSR or TMSR (or a chip reset) now kicks a four-step
  walk with one accumulator apiece, and `stall_o` holds the core while it
  runs because the masks are live wiring. `Sn_TX_FSR` follows the same way:
  one subtractor for the socket whose pointers just moved, a clock behind,
  which is exactly the lag the four-at-once form already had. −59 LUTs net.

**Measured and rejected:** collapsing the four per-lane port-B ring addresses
into one shared computer (two adders where the per-lane form builds eight).
It came out **35 LUTs WORSE** - Vivado was already sharing those
subexpressions, and the muxes needed to run one engine for both the host's
append and the sender's read cost more than the adders saved. Reverted.

**A bench trap found on the way.** `sim/uthernet2_tb.sv` modelled the host's
FIFO face as a continuous assign off `rx_mem[rx_rd]`. Verilator does not
re-evaluate that when the MEMORY is written while the index stands still, so
the first word of every message - pushed while `rx_rd` sits at the empty mark
- read as the stale initial zero and the parser framed on garbage from there.
Every card->host test passed throughout, which made it look like an RTL bug in
the receive path. The face is sampled on the falling edge now, which is what
FWFT means anyway. `sim/run_uthernet2_vl.sh` is the Verilator run of the
bench; `sim/run_uthernet2_tb.sh` (iverilog) is kept as the second opinion.

### The sender that waited forever (2026-09-20)

The time-shared read port above shipped with an assumption taken from this
card's own notes: *"a write to the pointer fetches its word on the clock of
the commit that sets it, so the byte is there for the earliest next op the
sequencer can present (the commit's clock + 2)"*. If the earliest next
present is a commit plus two, then every op leaves a clock where the program
is using neither phase, and a sender that asks for one always gets it.

**That is the 65C02 card's sequencer, and the IIgs runs a different one.**
`rtl/gs/accel_seq.sv` raises `u_present` at five sites, and the one in
`S_OVR` presents an op on the clock an override commits, chaining the next -
so through an override run `op_present` and `op_commit` can cover every clock
between them. `x_gets` is then never true, the sender stops after the header,
the `U2_CMD` for a socket's OPEN never reaches the host, the host never
answers, and the driver polls `Sn_SR` for a status that will never come. A
live machine in a tight loop, which is what the user found the first time
they tried to use the card on this bitstream.

Reproduced in the bench (`op_nogap`, a stream where present and commit
alternate so neither is ever both-low): the sender put **1 word out of the 25
it owed** across 400 back-to-back ops.

The fix is that the sender stops merely asking. After 15 clocks of waiting
`x_urgent` joins `stall_o`; the IIgs sequencer gates `fast_ok`, `ovr_ok`,
`turbo_ok` and `disp_pay` on `!stall_q`, so it starts no new op, the op in
flight goes quiet, and the next clock is free. An ordinary stream serves the
sender within three clocks and never reaches the threshold; the worst one
pays 15 clocks a word, bounded, a few microseconds a command - and one held
clock is what the floppy's track fill does routinely.

**Two things the bench had to learn.** It presented ops straight through an
asserted `stall_o`, which no sequencer does, so the hold it was being asked
to prove did nothing there. And the first version of the test checked that a
`U2_CMD` came out *after* the burst, which it always does - the starvation is
that there is no "after" while a driver is spinning. The test now counts the
words the sender lands **during** the gapless stream, and it is
mutation-tested: take `x_urgent` out of `stall_o` and it fails with "the
sender put 1 words out during 400 gapless ops, wanted 25".

**The general lesson:** a cut that makes one part of the card wait on another
part's timing has to name whose timing, and both cards' sequencers have to
agree. `rtl/common` is built by `a2_top` and `gs_top` alike; a contract read
out of the 65C02 card's notes is not a contract the 65816 card has signed.
