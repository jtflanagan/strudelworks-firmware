#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Generate the REVERSE keymap: the IIe keyboard's ASCII back to an ADB key.

The card lives in an Apple IIe, and at GS = 1 that machine's own keyboard is
the one under the user's hands.  What the IOU hands over is an ASCII byte and
a strobe - the encoder has already applied shift, control and caps lock and
thrown the keycode away - but rtl/gs/gs_adb.sv is an ADB micro and wants what an
ADB micro is given: a KEYCODE and a modifier byte, which it then puts back
through its own keymap to make the ASCII again.  So the byte has to be run
backwards through that map first.  See rtl/gs/gs_kbd_a2.sv and docs/GS.md.

THE INVERSE IS NOT UNIQUE and the ambiguity is real, not an artefact: $0D is
Return AND control-M, $08 is the left arrow AND control-H, $7F is Delete AND
control-hyphen, and every digit and letter appears a second time on the
keypad or in one of KEGS's duplicate rows.  Two rules settle it, in order:

  1. ONLY THE MAIN BLOCK.  A keycode below $41 - the keypad starts there, and
     KEGS's duplicate arrow and letter rows are above $60.  A IIe keyboard
     has no keypad, so a keypad code would be a lie about which key was hit.
  2. PLAIN, THEN SHIFT, THEN CONTROL, then the lowest keycode.  This is what
     makes $0D the RETURN KEY rather than control-M: a key that produces the
     byte on its own is a truer account of what the user pressed than a
     modifier combination that happens to land on the same value.

The result is TOTAL: all 128 ASCII values have exactly one answer, with no
ties left inside the winning column.  Both facts are asserted here rather
than assumed, because a change in KEGS's table could break either.

THE ROUND TRIP IS THE ORACLE.  Every entry is fed back through the FORWARD
selection exactly as rtl/gs/gs_adb.sv performs it - KEGS's own column choice,
including its rule that `hard_key` is decided by the plain column alone - and
must reproduce the byte it came from.  A generated table that cannot be
inverted back to itself is the one bug this file exists to prevent.

    tools/gen_adb_revmap.py [--kegs DIR] [--out rtl/gs/adb_revmap.hex] [--check]

One line an entry, 128 of them, indexed by the ASCII byte: nine bits,
{ctrl, shift, keycode[6:0]}.  There is no `none` flag because there is no
`none` case - the generator fails instead of emitting one.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_adb_keymap import read_table, DEF_KEGS      # noqa: E402

# The keypad begins at $41; KEGS's duplicate arrow and letter rows are above
# $60.  A IIe keyboard has neither.
MAIN_BLOCK = 0x41
PLAIN, SHIFT, CTRL = 0, 1, 2
COLNAME = ("plain", "shift", "ctrl")


def has_ascii(v):
    """KEGS's test for a column that carries an ASCII byte at all.

    -1 is "this key has nothing here", and the $EF00 mask marks a function or
    navigation key whose low byte is not an ASCII (F1 is 0x8001, and handing
    $01 over would be control-A).  Bit 12 is left out of the mask on purpose;
    tools/gen_adb_keymap.py explains why.
    """
    return v >= 0 and not (v & 0xEF00)


def forward(row, col):
    """The byte rtl/gs/gs_adb.sv's km_sel would choose for this row and column.

    Transcribed from the module rather than reasoned out, ITS rule included:
    `ev_hard` comes from the PLAIN column alone, so a key whose plain entry is
    a special one delivers no ASCII no matter which column the modifiers pick.
    """
    code, plain, shift, ctrl = row
    if not has_ascii(plain):
        return None
    if col == CTRL:
        return ctrl & 0xFF if has_ascii(ctrl) else None
    if col == SHIFT:
        return shift & 0xFF if has_ascii(shift) else None
    return plain & 0xFF


def build(rows):
    if len(rows) != 128:
        sys.exit("expected 128 entries, KEGS gave %d" % len(rows))

    # Every (keycode, column) that a main-block key can produce, gathered per
    # ASCII byte so the choice below can be made - and audited - in one place.
    cands = {}
    for idx, row in enumerate(rows):
        if row[0] != idx:
            sys.exit("entry %d names keycode %02x: the table is not indexed by "
                     "keycode any more" % (idx, row[0]))
        if idx >= MAIN_BLOCK:
            continue
        for col in (PLAIN, SHIFT, CTRL):
            v = forward(row, col)
            if v is not None:
                cands.setdefault(v, []).append((col, idx))

    out, missing = [], []
    for a in range(128):
        c = sorted(cands.get(a, []))
        if not c:
            missing.append(a)
            out.append(0)
            continue
        col, code = c[0]
        tied = [x for x in c if x[0] == col]
        if len(tied) > 1:
            sys.exit("ASCII $%02X is claimed by %d main-block keys in the %s "
                     "column (%s): the tie-break no longer decides it"
                     % (a, len(tied), COLNAME[col],
                        ", ".join("$%02X" % k for _, k in tied)))
        # The round trip, on the entry actually chosen.
        back = forward(rows[code], col)
        if back != a:
            sys.exit("ASCII $%02X -> keycode $%02X %s -> $%02X: the reverse map "
                     "does not invert the forward one" % (a, code, COLNAME[col], back))
        out.append(((col == CTRL) << 8) | ((col == SHIFT) << 7) | code)

    if missing:
        sys.exit("no main-block key produces ASCII %s: the IIe keyboard can "
                 "send bytes this map cannot name"
                 % " ".join("$%02X" % a for a in missing))
    return ["%03x" % w for w in out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kegs", default=DEF_KEGS)
    ap.add_argument("--out", default=None)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = a.out or os.path.join(root, "rtl", "gs", "adb_revmap.hex")
    lines = build(read_table(a.kegs))
    text = "".join(l + "\n" for l in lines)
    if a.check:
        have = open(out).read() if os.path.exists(out) else ""
        if have != text:
            sys.exit("adb_revmap.hex is out of date: rerun tools/gen_adb_revmap.py")
        print("ADB reverse keymap up to date (128 entries, round trip clean)")
        return
    open(out, "w").write(text)
    n_s = sum(1 for l in lines if int(l, 16) & 0x080)
    n_c = sum(1 for l in lines if int(l, 16) & 0x100)
    print("ADB reverse keymap: 128 entries (%d plain, %d shift, %d control) -> %s"
          % (128 - n_s - n_c, n_s, n_c, out))


if __name__ == "__main__":
    main()
