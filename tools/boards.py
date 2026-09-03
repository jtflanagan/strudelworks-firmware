# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""The Alchitry boards this design builds for, in one place.

Everything board-specific that the build needs is a lookup here: the Vivado
part, the connector-name -> FPGA-ball table, the MIG project that records the
DDR3 wiring, and which I/O bank is the board's multi-voltage bank.  The two
generators (gen_pin_xdc.py, gen_ddr3_xdc.py) and build/build.tcl (which keeps
its own copy of the part names, checked against this file by gen_pin_xdc.py
--check) all read from here, so adding a board is adding one entry.

The pin tables in ref/ are extracted from Alchitry Labs V2's own source
(hardware/pinout/*.kt), which is the authoritative record of how each board
wires its DF40 connectors to the FPGA.  The MIG projects are Alchitry Labs V2's
library/cores/mig_*.prj, the authoritative record of the DDR3 wiring.
"""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

BOARDS = {
    "au_v2": dict(
        title="Alchitry Au V2 (xc7a35t-ftg256-2)",
        part="xc7a35tftg256-2",
        pins="ref/alchitry_au_v2_pins.tsv",
        mig_prj="ref/mig_a.prj",
        # What MIG itself emitted for the v5 build - a second, independent
        # record of the same pinout, used as a cross-check.  Only the Au has one.
        mig_xdc="ref/mig_7series_0.generated.xdc",
        # Bank whose VCCO is set by VBSEL A/B on the control header (B51..B78 on
        # the Au V2).  Floating VBSEL = 3.3 V.
        mv_banks={34},
    ),
    "pt_v2": dict(
        title="Alchitry Pt V2 (xc7a100t-fgg484-2)",
        part="xc7a100tfgg484-2",
        pins="ref/alchitry_pt_v2_pins.tsv",
        mig_prj="ref/mig_pt_v2.prj",
        mig_xdc=None,
        # B33..B78 on the Pt V2 - a larger multi-voltage bank than the Au's,
        # and one this design's Apple-bus pins fall into.  See docs/PT_PORT.md.
        mv_banks={13},
    ),
}
# Alchitry Labs also carries a table for pre-production ("alpha") Pt V2 units,
# which route the B connector differently.  Deliberately not here: the card
# is a production Pt V2, and a third table is one more thing to pick wrongly.

DEFAULT_BOARD = "pt_v2"


def board(name):
    try:
        return BOARDS[name]
    except KeyError:
        raise SystemExit(f"unknown board {name!r}; known: {', '.join(BOARDS)}")


def pin_table(name):
    """connector pin name -> (fpga ball, bank)."""
    table = {}
    for line in (ROOT / board(name)["pins"]).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        conn, ball, bank = line.split("\t")
        table[conn] = (ball, int(bank))
    return table


def constr_dir(name):
    return ROOT / "constr" / name
