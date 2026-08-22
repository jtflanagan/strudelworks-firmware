# Licensing

**Short version:** everything in this repository is **GPL-2.0-or-later**, with a
single exception (`tools/ft601/ft601_probe.c`, which is GPL-3.0-or-later and has
to be). Every file states its own terms in an SPDX header; that header is
authoritative, this document only explains why.

**The one thing to understand:** the *files* are GPL-2.0-or-later. A *bitstream
built from them* is GPL-3.0-or-later, because it contains UberDDR3. Those are not
in conflict — see below — but they are different answers to different questions,
and conflating them is the easy mistake here.

## Why GPL-2.0-or-later

A deliberate choice, made while the project was still unreleased and every line
of it was copyright jtflanagan alone. Relicensing after publication needs the
agreement of every contributor; before publication it needs nobody's. This was
the moment it was free, so it was taken.

`-or-later` rather than `-only` for two reasons. It lets recipients move the code
forward to whatever the FSF publishes next without coming back to ask. And, more
immediately, it is what makes the UberDDR3 combination legal at all.

## How that squares with UberDDR3

The DDR3 controller is [UberDDR3](https://github.com/AngeloJacobo/UberDDR3),
which is GPL-3.0-**or-later** (Angelo Jacobo; `rtl/axi/` additionally carries
Gisselquist Technology copyright, though this project does not build it). A
bitstream containing UberDDR3 is a derivative work of it and must be
GPL-3-compatible.

GPL-2.0-**or-later** is GPL-3-compatible, precisely because of the "or later".
When these files are combined with UberDDR3, they are taken under GPL-3, and the
combined work is GPL-3.0-or-later. Nothing is violated and nothing needs
restating.

GPL-2.0-**only** would not work. If any file here is ever narrowed to GPL-2-only
it can no longer share a bitstream with UberDDR3. Do not drop the `-or-later`.

What this does and does not buy you:

- **You may** lift any file in this repository into a GPL-2 project, as long as
  you do not also bring UberDDR3.
- **You may not** take a built strudelworks bitstream under GPL-2. As shipped, the
  gateware is GPL-3, and no licence choice made here changes that. The only route
  to a GPL-2-consumable gateware is not using UberDDR3.

**The alternative, for the record.** Replacing UberDDR3 means writing a controller
from scratch or going back to the Xilinx MIG. MIG is *less* free: its licence
gives no right to modify or redistribute the generated core, and modifying the
controller's refresh scheduling is the entire premise of this project (see
`docs/DERISK.md`). UberDDR3 remains the freer of the two available paths.

## The exception: `tools/ft601/ft601_probe.c`

This file is **GPL-3.0-or-later** and cannot be relicensed, because it is not
solely ours to relicense. The `struct ft60x_ctrlreq` layout, and the fact that a
read must be announced on endpoint `0x01` before it appears on `0x82`, are
undocumented by FTDI; they come from the LambdaConcept pciescreamer driver by way
of `ufrisk/LeechCore-plugins` (`leechcore_ft601_driver_linux`, GPLv3, contributed
by Jeremie Boutoille / Synacktiv). Pre-release status is irrelevant to a
third party's copyright.

This is not a problem in practice: `ft601_probe` is a host-side tool, a separate
program from the gateware, and GPL-3 is where the bitstream lands anyway. If the
file ever wants to be GPL-2-or-later like everything else, the session-request
layout is the piece that needs deriving independently — the rest of the file is
already clean. The note at the top of the file says the same thing.

## Hardware is licensed separately, and not under the GPL

The carrier board is **not** a derivative of UberDDR3 — there is no HDL in a PCB
layout. It should not inherit the gateware's licence, and it should not be GPL at
all: the GPL's vocabulary (object code, linking, Corresponding Source) maps badly
onto board artwork, which is exactly why the CERN Open Hardware Licences exist.

When the board lands (milestone 4), it goes in its own directory with its own
`LICENSE`, under **CERN-OHL-S v2** for copyleft consistency with the gateware, or
**CERN-OHL-P v2** if permissive is preferred. Keeping it in a separate directory
with separate terms is what stops the two from blurring together. See `hw/`.

## Two consequences worth knowing

Both of these are properties of the *combined work*, which is GPL-3. They apply
even though the files themselves are GPL-2-or-later.

**Vivado is not a problem.** GPLv3 §1 excludes "System Libraries", including a
"Major Component" such as the compiler used to produce the work; GPLv2 §3 has a
narrower but similar carve-out for components shipped with the operating system.
A proprietary FPGA toolchain falls under the GPLv3 exclusion, so we owe recipients
our HDL and build scripts — which are in this repo — and not Vivado.

**Anti-tivoization applies if boards are ever sold.** This is a GPLv3-only
obligation, and it reaches us through UberDDR3, not through our own licence
choice. GPLv3 §6 requires that a "User Product" shipped with the gateware
installed also come with the Installation Information needed to install a
modified version. For an open project that is probably desirable anyway, but it is
a real obligation rather than a footnote, and it should be decided before anything
is sold rather than after.

## Third-party code

| Source | Licence | Status |
|---|---|---|
| UberDDR3 (`third_party/`) | GPL-3.0-or-later | Fetched at a pinned SHA, not vendored |
| LeechCore-plugins | GPLv3 | Not vendored; `ft601_probe.c` derives protocol details from it |
| `ref/mig_a.prj` | Xilinx MIG project file | See below |
| `ref/mig_7series_0.generated.xdc` | Xilinx MIG output | See below |

### ⚠ Unresolved: the Xilinx-generated files in `ref/`

`ref/` holds two artefacts copied out of the AppleTini v5 Vivado project: the MIG
settings file, and the XDC MIG generated from it. They are the ground truth for
the Au's DDR3 pinout and the cross-check that keeps `constr/ddr3.xdc` honest.

Their status is genuinely grey. The *content* we depend on is pin assignments —
facts about how the board is wired, and facts are not copyrightable. But the
generated XDC is verbatim Xilinx tool output, and redistributing tool output in a
public repository is not the same as using it in a design. This is now a live
question rather than a theoretical one: the repository is public.

The clean fix, if this matters: reduce `ref/mig_7series_0.generated.xdc` to the
`port,package_pin` table `tools/gen_ddr3_xdc.py` actually reads. That is pure
fact, preserves the cross-check exactly, and removes the verbatim copy. It is a
small change to the tool and has not been made yet — flagged rather than done,
because it is a judgement call about how conservative to be, not an engineering
question.

### Third-party modules coming in the v5 port (milestone 5)

Checked ahead of time, because one of them is still a problem:

- **`via6522.v`** — Thomas Skibo, 2011, BSD-style ("Redistribution and use in
  source and binary forms…"). Compatible with both GPL-2 and GPL-3. Keep its
  header intact and it can come across as-is.
- **`m6821.vhd`** — OpenCores, John E. Kent. Header says only *"This core adheres
  to the GNU public license"* with **no version stated**. Moving to
  GPL-2-or-later does **not** clear this. If it resolves to **GPL-2-only** it
  still cannot share a bitstream with UberDDR3, because that bitstream is GPL-3.
  **Pin this down before porting it**, or plan to reimplement. Do not assume
  "GPL" means "compatible with whatever we are building".
- Everything else in AppleTini v5 is jtflanagan's own code and can be relicensed
  at will.
