# The printer card: a parallel interface's slot on the card, the printer on the network

Status: **PROVEN ON HARDWARE 2026-09-07, branch `printer`** (both repos) -
rtl/printer_card.sv, PRINTER_SLOT `0x8000_00FC`, PRINTER_ROM `0x2D`; build
WNS +0.039; quick 28/28, accel 95/95, host tests green (printer_test 27/27 on
the Pi); tools/printer_test.sh PASS: a ProDOS boot, `PR#1` / two `PRINT`s /
`PR#0`, the spool read back, then the same job delivered to the Windows host's
LPD-shared LaserJet (job 321, 142 bytes).  Standard slot: 1.

## What AppleWin's card is, and so what this one is

AppleWin's `ParallelPrinter.cpp` is the Apple Parallel Interface Card as
software sees it, which is very little:

- **`$Cn00-$CnFF`**, the slot ROM: the firmware `PR#n` hands the output hook
  to.  AppleWin's is `Parallel.rom`, the real card's 256 bytes.
- **`$C0n0`**, the output register: every WRITE is one byte to the printer,
  masked to seven bits.
- **`$C0n0-$C0nF`**, any READ: `$FF`, "ready" - the status AppleWin returns
  and its firmware is happy with.

Bytes go to a spool file; after ten seconds without one the file closes
(the job is over) and, optionally, goes to a printer.  Options: the idle
limit, filter unprintables, append rather than overwrite.

## The card's half (rtl/printer_card.sv)

The VidHD's shape - a slot ROM page the host loads (PRINTER_ROM, 64 words,
the whole ROM or nothing) - plus the Uthernet II's device-select claim: reads
of `$C0n0-$C0nF` answer `$FF`.  The ROM page is gated by rtl/slot_switches.sv
as every on-card slot ROM is; DEVICE SELECT' never is.

**The writes are not claimed at all.**  A write to `$C0n0` lands nowhere on
a real card's bus either (the card takes the byte off the data bus by
itself), and the host's capture carries every `$Cxxx` access whatever the
mode (rtl/bus_event_filter.sv); under acceleration the slot's accesses are
fast ops (rtl/apple_mmu.sv `q_slot`, `swi_prn_slot`) whose words the door
keeps.  So the host's printer half takes the bytes from the stream exactly as
the Mockingboard's host half takes its register writes - nothing buffered,
nothing lost, no message from the card.  PRINTER_SLOT's `[31:24]` counts the
writes the card saw, a sign of life.

PRINTER_SLOT is U2_SLOT's contract - desired `[2:0]`, latched into `active`
at RES' and at a boot release, `[16]` the ROM is loaded - and the printer is
the newest card, yielding to all six of the others (it holds both a ROM page
and a device-select range, so it shares with none).

## The host's half (strudelworks-host src/printer_card.*)

- `apply()` on the decoder's thread: a write to `$C0n0` is a byte, masked to
  seven bits, into the SPOOL (`printer_file`, AppleWin's Printer.txt),
  filtered if `printer_filter`, appended if `printer_append`.
- A worker thread watches the idle clock: `printer_idle` seconds without a
  byte close the job and DELIVER it - kept as the file (`printer_dest =
  file`), or sent to a network printer as one LPD job (`printer_dest =
  lpd://HOST[:PORT]/QUEUE`; a client of our own, so the Pi needs no print
  system).  For a printer the text is made a printer's: CR becomes CR LF and
  the job ends with a form feed so the last page comes out.  The network
  never sits on the decoder.
- The ROM: `printer_rom = assets/parallel.rom` (AppleWin's Parallel.rom,
  git-ignored like every ROM but the three NOTICE explains).  When the file
  is absent the host SYNTHESISES the output hook: 31 bytes at `$Cn00` that
  find their slot from the return address of a JSR to a known RTS, send A to
  `$C0n0`, and return with A, X and Y as they were.  `$Cn01` is not `$20`,
  so no disk-controller scan mistakes it.
- `printer = auto` puts the card in slot 1 when nothing named is there; the
  boot menu has a PRINTER row like the other cards' (the legend moved down a
  row to make room).  `swctl status` / the startup banner report the slot,
  the card's readback and the host half's books.

## The Windows side (one-time, elevated PowerShell)

The LaserJet is on the Windows host's USB.  Windows shares it by LPD:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Printing-Foundation-LPDPrintService -All -NoRestart
Set-Service -Name LPDSVC -StartupType Automatic
Start-Service -Name LPDSVC
Set-Printer -Name "hp LaserJet 1320 PCL 5" -Shared $true -ShareName "hp1320"
New-NetFirewallRule -DisplayName "LPD Print Service (TCP 515)" -Direction Inbound -Protocol TCP -LocalPort 515 -Profile Private -Action Allow
```

Then `printer_dest = lpd://192.168.1.155/hp1320` in swhost.conf.  A raw job
from the Pi (`lpd_test.py`, kept with the session's notes) printed on
2026-09-07 before any of this was built.  The DISM feature name differs by
Windows version; `Get-WindowsOptionalFeature -Online | Where FeatureName
-like "*Print*"` finds it.

## Proof

- Lint 58/58 (the card added), the whole top linted for ports.
- `sim/suite.sh quick`, the accel battery and the boot bench: the MMU's new
  slot input is tied off in the benches; nothing else in their path moved.
- The build: timing as the gate, as always.
- On hardware: `PR#1` from BASIC, `PRINT "HELLO"`, `PR#0`, ten seconds, a
  page out of the LaserJet; tools/printer_test.sh types it and checks the
  spool from the Pi.
