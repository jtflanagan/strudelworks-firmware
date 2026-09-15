# Clean start and a link that never wedges

Status: 2026-09-15, branch `gs_control_panel` (fw ebb96ef / host fbf9f96, not pushed), CS1-CS7 DONE AND PROVEN ON HARDWARE (GS bit `cs16`, MET wns +0.010 whs +0.043): the ladder passes 20/20/D.  `suite quick` 33/33, `suite gs` 14/14, `start_hold_tb` 15 checks, `rom_loader_tb` 13 checks, `tx_ring_tb` and `ft601_msg_rx_tb` with their new cases; GS build `cs12` (CS1+CS2) MET wns +0.046 whs +0.025, build `cs16` (CS1-CS6) running.  CS7's hardware ladder is the remaining rung.  Two user requirements (2026-09-15): every board reset and every Apple reset runs a clean startup checklist from a known place of control; and the link never wedges - every state recoverable without a power cycle or a bitstream reload.

## Why

- **A reset left the machine in an unknown state, and it cost a day.**  swhost's exit wrote accel
  mode 0 under a running IIgs (fixed, e617605/831ce7e); swhost pushed the ROM into a running
  machine on every start (interim skip in place; a push under a running 65816 is the leading,
  unproven suspect for test E2's runaway - docs/GS_CONTROL_PANEL.md).  The ROM load itself is a
  polled busy flag with a blind 300 us fallback: no ack per chunk, no completion check, no retry
  (host `pipeline.cpp`, "THE CHUNKS ARE PACED").
- **The link sometimes answers no register after a swhost restart** (GS.md "What is NOT
  working"; seen again 2026-09-15), and only a bitstream reload clears it.  The watchdog was
  meant to restore state, but: a swhost restart resets nothing on the card; the watchdog is kicked
  only by host->card traffic (`card_link.sv` `kick = msg_valid`), so a dead card->host direction
  never fires it while any swhost heartbeats; the TX ring's outstanding-ack counters
  (`tx_ring.sv` `wr_out`/`rd_out`) have NO reset, so one lost DDR3 ack silences the ring until
  configuration; the FIFO reset waits for 16 running FT601 clocks and has no retry if the clock
  does not come back; and the only full link reset reachable today is the UART 'R', which is on
  the PC's cable, not the Pi's.

## Principles (the user's)

- **RES' is the one blessed place to steal cycles.**  Holding the CPU in reset until the startup
  checklist is done interrupts nothing.  While running, the card may pause off the bus; never
  between back-to-back real bus cycles (memory `no-stolen-cycles`).
- **The ROM goes in only while the CPU is held.**
- **Start from a known place of control, every time**: a power-on, a bit load, a link reset, a
  watchdog, a swhost restart and every Apple RES' all end in the same checklist.
- **A recovery never needs a reload or a power cycle.**  Anything that does is a bug.

## Pieces that exist (file:line from the 2026-09-15 research)

- `rtl/rom_loader.sv`: MEM_ROM 0x22 chunks, a one-chunk staging buffer, the window-gated drain,
  `seen`/`rom_ok`, overruns; all cleared by `apple_rst` (= the link reset).  MEM_STAT[15]
  rom_loaded, MEM_ROM_STAT {busy, overruns}.
- Card->host: `msg_master` adapters into a fixed-priority `msg_arb`, then `tx_ring`
  (`card_link.sv:1277-1378`); CPU_HOLD / `kbd_notice.sv` are the one-pending level-notice
  patterns; UNKNOWN_TYPE is the one notice not gated on `capture_enable`.  A new type is the
  4-edit pattern on the host (protocol.hpp, link_parser.cpp, link_session, pipeline.cpp) plus
  `hdr_known` for host->card types (`ft601_msg_rx.sv:102-109`).
- Holds: `boot_hold.sv` parks the core at its first fetch AFTER the reset sequence (not in reset);
  `gs_rom_hold` (e617605) holds the 65816 in reset out of a card reset until `rom_ok`.
- RES': `apple_res_sync`; `cpu_rst = apple_rst || !apple_res_sync || gs_rom_hold`; the host sees
  RES' as event bit 17 and counts it (`rst` in the frame line).  A card reset has no event.
- Host startup order (`Pipeline::start`): build stamp, CPU_SOURCE, slot registers + slot ROMs,
  battery RAM + time (GS), NSC, ROM, MEM_CTRL, FB_CTRL, ACCEL_CTRL, BOOT_HOLD, MENU_HOLD,
  KBD_CTRL, BUS_ENABLE last.  A card reset clears all of it; a RES' clears only the reset-latched
  slot copies (and the MMU's switches, via the vector).

## Design

### CS1 - the start hold (firmware)
- `start_pending`: SET by the card's reset (`apple_rst`: power-on, bit load, link 'R', watchdog)
  and by every RES' assertion (`apple_res_sync` low); CLEARED only by a host write of
  START_RELEASE.  Cause bits latched {card reset, RES'} and an 8-bit count of holds.
- While pending, the SOFT core is held in reset: `cpu_rst |= start_pending`.  It replaces
  `gs_rom_hold`.  The native 6502 (CPU_SOURCE not active) is never held - a IIe with no host
  still runs on its motherboard.
- The hold lasts past RES' de-assertion; on release the core runs its reset sequence as today, so
  the IIe's MMU reset rides the bus and `boot_hold` (if armed) still parks at the first fetch.
- Register START_STAT {pending, cause_card, cause_res, count} and START_RELEASE (W1, refused -
  no effect - while RES' is still low).
- Notice START_HELD (card->host, header-only, one pending, like CPU_HOLD but NOT gated on
  capture: a host that has just opened must hear it).  Sent when `start_pending` rises.
- Benches: `boot_gs_tb` / `boot_tb` gain a host model that answers START_HELD; a held core fetches
  nothing (the existing `held_fetches` check, generalised); a RES' mid-run re-holds; release with
  RES' still low is refused.

### CS2 - the formal ROM load (firmware + host)
- Card: MEM_ROM is REFUSED unless `start_pending` (the CPU is held).  Every MEM_ROM gets a
  MEM_ROM_ACK notice {chunk, status: ok / overrun / not-held / bad-length / bad-index, sum16 of the
  512 bytes as they drained}, sent when the drain finishes (or at once for a refusal).  A running
  32-bit sum of every landed byte, cleared with `seen`, in a register (ROM_SUM).
- Host: send chunk k, wait for its ACK (timeout 100 ms), retry up to 3 times on a timeout or a
  non-ok status, compare sum16 with its own; after the last chunk read MEM_STAT rom_loaded and
  ROM_SUM and compare with the file.  Any failure is a hard error with the chunk and the reason
  in the log and `status`.  No blind pacing.  The busy poll goes away.
- The same ack pattern for the slot ROMs and GS_BRAM is a follow-up, not this plan (they are
  small and single-message; their `loaded` flags are checked in CS3).

### CS3 - the host startup checklist - DONE
The design above had the host re-initialising the card in place, differently for each cause.  What
was built is simpler and has one path instead of three: THE STARTUP IS THE CHECKLIST, and anything
it cannot honour from here ends the process so the startup runs again from the top.  A half
re-initialised session is exactly the unknown state this rung exists to abolish, and there is no
way to write "the full re-init" twice - once in `start()` and once beside it - and keep them the
same for a year.

- `Pipeline::drive_start` (on the drive loop, never blocking the ingest thread) is a two-state
  machine over polls.  A hold arrives (START_HELD, or START read at startup); it asks the card what
  its memory image holds (MEM_STAT) and releases ONLY when the ROM is there.  RES' holds the whole
  machine still meanwhile, which is the one moment the card may take its time (the user's rule:
  RES' is the blessed place to steal cycles).
- Cause RES', ROM present: released, with the ms held in the log.
- Cause RES', ROM absent, and this host has one: `want_restart` - only a whole startup sends a ROM,
  with its acks and its sum (CS2).
- Cause the CARD's own reset, mid-session: `want_restart` - the ring, the link counters and every
  register this host wrote are back at their defaults.
- No answer to the checklist within 200 ms: `want_restart`, and the link's health watch (CS4) is
  what can actually do something about it.
- `want_restart` logs the reason and `main` exits **75**; `tools/pi.sh` and `tools/swmcp/server.py`
  start swhost again on that code, bounded at ten in a row and said out loud.  Nothing else changes
  meaning: any other exit ends the session as before.
- swhost start with nothing pending: the machine is running - the ROM is not sent (CS2's rule) and
  only the host's own levels are written.
- Tests: `tests/accel_test.cpp` `test_clean_start` on the mock (which gained `queue_start_held`,
  `start_pending` and `forget_rom`): released after the check, the empty-image restart with the
  reason naming the ROM, the card-cause restart, and the machine left held in both.

### CS4 - a link reset the host can always reach (firmware + host) - DONE
- LINK_RESET (`0x01`), host->card, header only: `rtl/ft601_msg_rx.sv` raises `link_reset_req` as the
  header is taken - before any consumer downstream, so nothing that might be the stuck thing is in
  the path - and `card_link` ORs it into `link_reset_trigger` beside the UART's 'R' and the
  watchdog.  In `hdr_known`, and its own bit in LINK_STAT's cause field.  Bench: `ft601_msg_rx_tb`
  ("LINK_RESET asked for the reset, once", framing kept, a known type).
- Host (`Pipeline::drive_link_health`, `LinkSession::send_link_reset`): every register reply stamps
  `last_reply_ns`.  1 s of silence -> a LINK_STAT read of its own; 2 s -> a LINK_RESET; 3 s more
  with nothing back -> give up on the session and exit for a clean start (CS3's path).  Each step
  is logged.  No UART anywhere in it.

### CS5 - state no reset reached (firmware) - DONE
- `rtl/tx_ring.sv`: the drain waits for the acks still out, and waited for a lost one FOREVER - a
  reset that never finished draining left the ring, and every register reply behind it, silent
  until the FPGA was configured again.  Now `DRAIN_TICKS` (100 ms at 100 MHz) ends it: `wr_out` and
  `rd_out` go to zero, both decrements are guarded against wrapping below zero so a late ack
  changes nothing, and the timeouts are counted in STATUS `[30:27]`.  Bench: `tx_ring_tb` phase 3c,
  a memory model that eats a batch and answers none of it.
- `rtl/card_link.sv`: the FT601's CLKOUT after a reset.  `fifo_rst` waits for 16 of its edges, and
  a chip whose session engine stopped during the reset stops CLKOUT with it - there is then no
  clock there to notice with.  So the control side watches instead: the FIFO release crosses back
  to `clk_ctrl`, and 50 ms without it pulls the reset again, the wait doubling each attempt to
  ~800 ms so an unplugged chip is not reset forty times a second.  Its own cause bit.

### CS6 - a watchdog that sees both directions (firmware) - DONE
- The wedge this project has actually seen reads TXE# high with words waiting: the chip takes
  nothing, for ever, and the link watchdog cannot see it because the HOST is still talking and
  still kicking it.  `rtl/card_link.sv` counts a word offered to a full TX FIFO with nothing pushed
  in between: two seconds of that is a stopped chip, not a slow one, and pulls the same lever.  Two
  seconds is well past anything the host does - it drains the link continuously - so a healthy
  session never approaches it.  Its own cause bit.
- The host's heartbeat keeps kicking the RX side as today.

### CS7 - the hardware ladder (host `tools/clean_start_test.sh`) - DONE, PASS on hardware 2026-09-15
The script is in the host repo and drives rungs A-D below (`RESTARTS=` and `RESETS=` shorten it;
named rungs run alone: `tools/clean_start_test.sh A C`).  It needs the Pi up, this bitstream
loaded and the Apple on, and it reads everything from the mirror (`ctl screen`) and swhost's log.
Rung D pulls the new `ctl linkreset` lever: the host asks the CARD to reset its link over the link
itself, which ends the session - swhost exits 75 and the launcher runs a whole clean startup.  That
lever is also the manual recovery a person can use with no UART in the room.

**The run (GS bit `cs16`, 2026-09-15): PASS.**
- A: the machine came up on the ROM the card already held (`rom     : already on the card, the
  machine running - not sent`) - the fresh-card load is rung D's business, below.
- B: **20 restarts**, and not one pushed a ROM into a running machine.
- C: **20 socket RES' pulses, 20 holds, 20 checklists passed** - each
  `start   : held by a RES' (hold N since the card's reset)` followed by
  `start   : checklist passed (the ROM is in the card's image), released after 0 ms`.
- D: the whole recovery, end to end and with no UART and no reconfiguration:

      link    : LINK_RESET asked for over the control socket
      restart : the link stopped answering and did not come back from a LINK_RESET - leaving for a clean start
      Exiting 75: a launcher that watches for it starts a whole clean startup.
      rom     : 512 chunks acked (0 retries), sum $01A6841A verified, held by the card's reset

  The FT601 re-enumerated across it (bus 4 addr 41 -> addr 42) and the machine booted again.

**What the ladder cost to get right**, because none of it was the firmware: the launcher's restart
loop was written inline and became a shell loop inside tmux inside ssh inside a double-quoted
string - the LOCAL shell ate its `$n`, `pi.sh start` died with "n: unbound variable", and the
machine sat with no swhost at all until it was rewritten as `tools/swhost_run.sh`, one file shipped
to the Pi and quoted once.  The launcher also truncated the log on every start, destroying the
evidence of the session that had just ended; it rotates to `run.log.prev` now.  And three "the
machine is dead" failures were all the test's own eyes: a machine held in reset shows a screenful
of inverse `@`, ProDOS's whole screen is a single `]` that an `[A-Za-z]` test rejects, and after a
restart `screen` reads the host's MIRROR, which a quiet machine has written nothing into however
alive it is - so liveness is the bus-event count, not the screen.

1. Bit load -> swhost start -> START_HELD (card reset) -> checklist -> boot.  The ROM is sent with
   acks; the log line says so.
2. 20 swhost restarts back to back, each followed by a warm reset and a screen check: count
   auto-recoveries (LINK_RESET used) and failures (target 0).
3. 20 socket RES' + 5 Ctrl-OA-Resets: each a RES' checklist, ms held, the machine back at its
   prompt.
4. Forced watchdog (a host that goes silent) and a forced LINK_RESET: the next swhost start
   recovers through the ladder and CS3 with no reload.
5. `tools/gs_cp_test.sh` PASS; a IIe spot check (boot, RES', swhost restart) if the IIe build is
   in scope.
- Firmware gate for every rung: lint, `suite gs` + `suite quick` + the touched benches, a GS build
  with its WNS read (and a IIe build if in scope).

## Decisions (user, 2026-09-15)
1. **The IIe build too.**  CS1-CS3 on both builds; a IIe build and IIe hardware steps join CS7.
2. **Recovery is entirely independent of the UART.**  The UART may be used to debug the recovery;
   once it works nothing in it may need the UART.
3. **A FULL hold on both machines.**  The future board plugs into the CPU socket and has no
   physical CPU at all; today's work-with-the-CPU paths are vestiges.  So while a checklist is
   pending the whole machine is held - the motherboard CPU (native 6502) included, no exception
   for a IIe without a host.

### What decision 3 changes in CS1
- **The hold drives RES' low** for as long as `start_pending`, through the card's open-drain RES'
  driver (today's RESET-register pulse, `res_drive`): the motherboard CPU, the slot cards and the
  soft core are all held together, and the release is an ordinary RES' rising edge.
- **Which RES' edges count.**  `start_pending` is set by a card reset and by a RES' assertion
  that the HOLD ITSELF did not cause - an external Ctrl-Reset or power-on, or the host's own
  RESET pulse (an Apple reset the host asked for runs the checklist too).  The hold's own drive is
  masked, or it would re-arm itself for ever.
- **CPU_SOURCE and the other RES'-latched state** must latch on the release edge exactly as on any
  RES', so the soft core takes the machine after a checklist.
