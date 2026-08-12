# Licensing

**Short version:** the gateware is **GPL-3.0-or-later**. Individual files that
stand on their own carry **BSD-2-Clause** so they can be reused elsewhere. Every
file states its own terms in an SPDX header; that header is authoritative, this
document only explains why.

## Why GPL-3.0-or-later

Not a preference — an obligation, and one worth accepting.

The DDR3 controller is [UberDDR3](https://github.com/AngeloJacobo/UberDDR3),
which is GPL-3.0-**or-later** (Angelo Jacobo; `rtl/axi/` additionally carries
Gisselquist Technology copyright, though this project does not build it). A
bitstream containing UberDDR3 is a derivative work of it, so the combined
gateware must be GPL-3-compatible. There is no version of this project that uses
UberDDR3 and is permissively licensed.

`-or-later` rather than `-only` because upstream grants it ("either version 3 of
the License, or (at your option) any later version") and it keeps us compatible
with whatever the FSF publishes next.

It also happens to be the answer that matches the project's intent. "As free as
possible" splits two ways: permissive maximises what the *next* recipient may do
with the code, copyleft maximises what *every* downstream user keeps. This
project wants the second, and is bound to it anyway, so there is no tension to
resolve.

**The alternative, for the record.** The only route to a permissive strudelworks
is not using UberDDR3 — writing a controller from scratch, or going back to the
Xilinx MIG. MIG is *less* free: its licence gives no right to modify or
redistribute the generated core, and modifying the controller's refresh
scheduling is the entire premise of this project (see `docs/DERISK.md`). So
GPL-3-or-later is the freer of the two available paths, not a concession.

## Why some files are BSD-2-Clause anyway

A permissive licence is one-way compatible with the GPL: BSD-2 code can be
combined into a GPL-3 work, and the *combination* is then GPL-3. That means a
file can be BSD-2 and still ship inside a GPL-3 bitstream — and anyone can lift
that single file into a project that is not GPL.

So blanket-GPLing everything would destroy reuse for no gain. Files are marked
GPL-3.0-or-later only where they are genuinely bound to UberDDR3 — where they
instantiate it, or encode its port list, parameter semantics or internal
behaviour. Everything else is BSD-2-Clause.

| File | Licence | Why |
|---|---|---|
| `rtl/ddr3_wrapper.sv` | GPL-3.0-or-later | Wraps `ddr3_top`; encodes its port list and parameter semantics |
| `rtl/au_top.sv` | GPL-3.0-or-later | The top level that forms the combined work |
| `sim/latency_tb.sv` | GPL-3.0-or-later | Instantiates `ddr3_top` directly |
| `sim/params_dump.sv` | GPL-3.0-or-later | Instantiates `ddr3_controller` directly |
| `rtl/clk_gen.v` | BSD-2-Clause | A plain `MMCME2_BASE` instantiation; knows nothing about UberDDR3 |
| `rtl/latency_probe.sv` | BSD-2-Clause | A Wishbone master and a measurement FSM; works against any Wishbone slave |
| `tools/gen_ddr3_xdc.py` | BSD-2-Clause | Standalone; generates constraints from a MIG project file |
| `constr/*.xdc` | BSD-2-Clause | Pin assignments — facts about the board |
| `build/*`, `sim/run_*.sh`, `third_party/fetch_uberddr3.sh` | BSD-2-Clause | Build and run scripts, independent of what they build |

Note the build scripts are permissively licensed *and* are part of the
Corresponding Source the GPL requires us to provide. Those are not in conflict:
Corresponding Source has to be available, not copylefted.

## Hardware is licensed separately, and not under the GPL

The carrier board is **not** a derivative of UberDDR3 — there is no HDL in a PCB
layout. It should not inherit the gateware's licence, and it should not be GPL at
all: the GPL's vocabulary (object code, linking, Corresponding Source) maps badly
onto board artwork, which is exactly why the CERN Open Hardware Licences exist.

When the board lands (milestone 4), it goes in its own directory with its own
`LICENSE`, under **CERN-OHL-S v2** for copyleft consistency with the gateware, or
**CERN-OHL-P v2** if permissive is preferred. Keeping it in a separate directory
with separate terms is what stops the two from blurring together. See `hw/`.

## Two consequences of GPL-3 worth knowing

**Vivado is not a problem.** GPLv3 §1 excludes "System Libraries", including a
"Major Component" such as the compiler used to produce the work. A proprietary
FPGA toolchain falls under that, so we owe recipients our HDL and build scripts —
which are in this repo — and not Vivado.

**Anti-tivoization applies if boards are ever sold.** GPLv3 §6 requires that a
"User Product" shipped with the gateware installed also come with the
Installation Information needed to install a modified version. For an open
project that is probably desirable anyway, but it is a real obligation rather
than a footnote, and it should be decided before anything is sold rather than
after.

## Third-party code

| Source | Licence | Status |
|---|---|---|
| UberDDR3 (`third_party/`) | GPL-3.0-or-later | Fetched at a pinned SHA, not vendored |
| `ref/mig_a.prj` | Xilinx MIG project file | See below |
| `ref/mig_7series_0.generated.xdc` | Xilinx MIG output | See below |

### ⚠ Unresolved: the Xilinx-generated files in `ref/`

`ref/` holds two artefacts copied out of the AppleTini v5 Vivado project: the MIG
settings file, and the XDC MIG generated from it. They are the ground truth for
the Au's DDR3 pinout and the cross-check that keeps `constr/ddr3.xdc` honest.

Their status is genuinely grey. The *content* we depend on is pin assignments —
facts about how the board is wired, and facts are not copyrightable. But the
generated XDC is verbatim Xilinx tool output, and redistributing tool output in a
public repository is not the same as using it in a design.

The clean fix, if this matters: reduce
`ref/mig_7series_0.generated.xdc` to the `port,package_pin` table
`tools/gen_ddr3_xdc.py` actually reads. That is pure fact, preserves the
cross-check exactly, and removes the verbatim copy. It is a small change to the
tool and has not been made yet — flagged rather than done, because it is a
judgement call about how conservative to be, not an engineering question.

### Third-party modules coming in the v5 port (milestone 5)

Checked ahead of time, because one of them is a problem:

- **`via6522.v`** — Thomas Skibo, 2011, BSD-style ("Redistribution and use in
  source and binary forms…"). GPL-compatible. Keep its header intact and it can
  come across as-is.
- **`m6821.vhd`** — OpenCores, John E. Kent. Header says only *"This core adheres
  to the GNU public license"* with **no version stated**. If that resolves to
  **GPL-2-only it is incompatible with GPL-3** and cannot legally share a
  bitstream with UberDDR3. **Pin this down before porting it**, or plan to
  reimplement. Do not assume "GPL" means "GPL-compatible with GPL-3".
- Everything else in AppleTini v5 is jtflanagan's own BSD-2 code and can be
  relicensed at will.
