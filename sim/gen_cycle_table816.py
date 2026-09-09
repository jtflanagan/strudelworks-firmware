#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Hold the 65816 microcode to the published cycle counts.

There is no Klaus Dormann suite for the 65816.  What there is instead is
stronger: SingleStepTests/65816 records, for every opcode, the cycle-by-cycle
BUS ACTIVITY - address, data, and the VDA/VPA/RWB lines - for 20,000 randomised
single-instruction tests, 10,000 native and 10,000 emulated.  A functional suite
tests results and never looks at the bus; this one pins down which address is
driven on every cycle, dummy cycles included, which is the property this project
exists for.

This script does the cheap half of that: it walks the microcode sequencer and
compares the cycle COUNT of every path against the counts observed in the
suite.  It needs no simulator and no RTL, so it catches a mis-sequenced
addressing mode in about a second - before Verilator, and long before Vivado.

    sim/fetch_65816_tests.sh                 # sample the suite (~130 MB)
    python3 sim/gen_cycle_table816.py        # derive + check

Verifying the ADDRESSES as well is the next step and wants a real testbench;
see docs/UCODE816.md for where that stands.
"""

import json
import os
import sys
import collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen_microcode816 as mc                                   # noqa: E402

SAMPLES = os.path.join(HERE, "cpu816_work", "samples")
TABLE = os.path.join(HERE, "cycle_table816.json")


# ---------------------------------------------------------------------------
# Read the observed counts out of the sampled suite
# ---------------------------------------------------------------------------

def load_tests(path, limit=400):
    """The suite's files are one test per line, so a truncated prefix is a
    perfectly good random sample - which is why fetch_65816_tests.sh takes a
    byte range instead of 2.9 GB."""
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip().lstrip("[").rstrip(",")
            if not line.endswith("}"):
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
            if len(out) >= limit:
                break
    return out


def observe():
    """opcode -> {(e, m, x, dl_nonzero): set of cycle counts seen}."""
    table = collections.defaultdict(lambda: collections.defaultdict(set))
    for oc in range(256):
        for mode in ("n", "e"):
            path = os.path.join(SAMPLES, f"{oc:02x}.{mode}.json")
            if not os.path.exists(path):
                continue
            for t in load_tests(path):
                i = t["initial"]
                e = i["e"]
                m = 1 if e else (i["p"] >> 5) & 1
                x = 1 if e else (i["p"] >> 4) & 1
                dl = 1 if (i["d"] & 0xFF) else 0
                table[oc][(e, m, x, dl)].add(len(t["cycles"]))
    return table


# ---------------------------------------------------------------------------
# Walk the microcode
# ---------------------------------------------------------------------------

COND = mc.COND


def cond_value(cond, st):
    """Evaluate a microcode condition under an assumed machine state."""
    e, m, x, dl = st["e"], st["m"], st["x"], st["dl"]
    return {
        COND["ALWAYS"]: True,
        COND["NEVER"]:  False,
        COND["CARRY"]:  st["carry"],
        COND["BRANCH"]: st["taken"],
        COND["PAGE"]:   st["page"],
        COND["DEC"]:    st["dec"],
        COND["M16"]:    m == 0,
        COND["X16"]:    x == 0,
        COND["DL"]:     dl == 1,
        COND["IDX"]:    (x == 0) or st["carry"],
        COND["EPAGE"]:  (e == 1) and st["page"],
        COND["EMU"]:    e == 1,
        COND["NOTEMU"]: e == 0,
        COND["MVDONE"]: st["mvdone"],
    }[cond]


def walk(slots, st, limit=40):
    """Cycles this instruction takes under `st`.

    The opcode fetch itself is the PREVIOUS sequence's trailing sync slot, so
    it is counted here as the leading 1 and the walk stops when it reaches the
    sync that fetches the NEXT opcode.
    """
    n = 1
    i = 0
    while n < limit:
        if i >= len(slots):
            return None
        s = slots[i]
        if s["sync"]:
            return n
        n += 1
        i = i + 1 if cond_value(s["cond"], st) else s["alt"]
    return None


def predict(slots):
    """Every cycle count the sequence can produce, keyed by (e, m, x, dl).

    The free variables - a page cross, a taken branch, decimal mode - are
    enumerated rather than assumed, so the result is a SET per bucket and can
    be compared directly against what the suite showed.
    """
    out = collections.defaultdict(set)
    for e in (0, 1):
        for m in ((1,) if e else (0, 1)):
            for x in ((1,) if e else (0, 1)):
                for dl in (0, 1):
                    for carry in (0, 1):
                        for taken in (0, 1):
                            for dec in (0, 1):
                                st = dict(e=e, m=m, x=x, dl=dl, carry=carry,
                                          taken=taken, dec=dec, page=carry,
                                          mvdone=False)
                                got = walk(slots, st)
                                if got is not None:
                                    out[(e, m, x, dl)].add(got)
    return out


def main():
    if not os.path.isdir(SAMPLES):
        sys.exit("No samples.  Run sim/fetch_65816_tests.sh first.")

    seen = observe()

    # resolve() mutates, so build the ROM once and read the resolved slots back
    resolved = {}
    for oc in range(256):
        if oc in mc.PROG:
            resolved[oc] = mc.resolve(oc, mc.PROG[oc])

    # Four opcodes have no fixed cycle count and cannot be checked this way:
    #   $44 MVP, $54 MVN  - seven cycles PER BYTE MOVED, so what the suite
    #                       records is the length of one randomly-sized block
    #                       move (and the sampled prefix truncates it anyway).
    #   $CB WAI, $DB STP  - they park until an interrupt or a reset arrives,
    #                       so the count is a property of the environment.
    # Excluding them is not a way of hiding a failure: the block-move LOOP is
    # exercised by the trace check, and STP/WAI have one slot each.
    UNCOUNTABLE = {0x44, 0x54, 0xCB, 0xDB}

    bad = []
    checked = 0
    skipped = 0
    for oc in range(256):
        if oc not in resolved or oc not in seen:
            continue
        if oc in UNCOUNTABLE:
            skipped += 1
            continue
        want = predict(resolved[oc])
        for key, counts in sorted(seen[oc].items()):
            # A bucket the suite barely sampled (DL == 0 happens once in 256)
            # is still worth checking, but it cannot rule a count OUT - so the
            # test is that everything OBSERVED is reachable, not that
            # everything predicted was observed.
            checked += 1
            missing = counts - want.get(key, set())
            if missing:
                bad.append((oc, key, sorted(counts), sorted(want.get(key, set()))))

    if "--dump" in sys.argv:
        json.dump({f"{oc:02x}": {"".join(map(str, k)): sorted(v)
                                 for k, v in seen[oc].items()}
                   for oc in sorted(seen)},
                  open(TABLE, "w"), indent=1, sort_keys=True)
        print(f"wrote {TABLE}")

    print(f"checked {checked} (opcode, mode) buckets against the suite, "
          f"{skipped} opcodes not fixed-count")
    if bad:
        print(f"\n{len(bad)} MISMATCHES  (e,m,x,dl): observed -> predicted")
        for oc, key, got, want in bad[:60]:
            print(f"  ${oc:02X} e{key[0]}m{key[1]}x{key[2]}d{key[3]}: "
                  f"{got} -> {want or 'unreachable'}")
        if len(bad) > 60:
            print(f"  ... and {len(bad) - 60} more")
        sys.exit(1)
    print("every observed cycle count is reachable in the microcode")


if __name__ == "__main__":
    main()
