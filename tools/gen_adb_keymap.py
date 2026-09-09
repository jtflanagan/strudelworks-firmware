#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Generate the ADB micro's keycode->ASCII table from KEGS's own.

The IIgs's ADB microcontroller holds the keymap: a real one turns a keycode
and the modifier state into the ASCII byte $C000 reads, and the ROM never
sees the keycode for that.  So the map belongs on the card, and transcribing
128 rows by hand is exactly the kind of thing that goes wrong quietly - this
reads KEGS's `g_a2_key_to_ascii[][4]` (src/adb.c) and emits the ROM.

Columns, as KEGS uses them (adb_key_event): [0] the keycode, [1] unshifted,
[2] shifted, [3] control - and -1 for "this key has none".  A value with any
of $EF00 set is a SPECIAL key rather than an ASCII one, which is KEGS's own
`hard_key` test, so the flag is carried rather than recomputed.

    tools/gen_adb_keymap.py [--kegs DIR] [--out rtl/adb_keymap.hex] [--check]

One line an entry, 128 of them, each `{ctrl[9:0], shift[9:0], plain[9:0]}` as
30 bits.  A field is {none, special, byte}: `none` is KEGS's -1, and
`special` is its `& 0xef00` test - a function or navigation key, whose low
byte is NOT an ASCII the keyboard register may hand over (F1 is 0x8001, and
$01 is ctrl-A).
"""
import argparse
import os
import re
import sys

DEF_KEGS = "/home/flana/repos/kegs.1.38"


def read_table(kegs):
    path = os.path.join(kegs, "src", "adb.c")
    src = open(path, errors="replace").read()
    i = src.index("g_a2_key_to_ascii[][4] = {")
    body = src[src.index("{", i) + 1:src.index("\n};", i)]
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    # THE BRACES AND COMMAS IN THE TABLE ARE NOT ALL PUNCTUATION: three keys
    # carry '{', '}' and ',' as character literals, so every literal becomes
    # its number before anything is split on either.
    def lit(m):
        t = m.group(1)
        return str(ord(t) if len(t) == 1 else ord(eval("'" + t + "'")))
    body = re.sub(r"'(\\.|[^'\\])'", lit, body)
    rows = []
    for m in re.finditer(r"\{([^{}]*)\}", body):
        parts = [p.strip() for p in m.group(1).split(",") if p.strip()]
        if len(parts) != 4:
            sys.exit("a table entry has %d fields, not 4: %r" % (len(parts), m.group(1)))
        rows.append([int(p, 0) for p in parts])
    return rows


def field(v):
    """Ten bits: {none, special, byte}.

    `none` is KEGS's -1 - this key has nothing in this column.  `special` is
    its `& 0xef00` test: the entry is a FUNCTION key, not an ASCII one, and
    $C000 must not be given its low byte as though it were.  F1 is 0x8001,
    and delivering that as $01 would be ctrl-A.

    TWO THINGS THE MASK IS NOT.  $EF00 leaves BIT 12 OUT, deliberately: the
    $10xx entries (shift-F1, Home, Page Up, the keypad's edges) are NOT
    special by this test and KEGS treats them as ordinary ASCII.  And KEGS
    decides `hard_key` from THE PLAIN COLUMN ALONE (adb_key_event tests
    `[a2code][1]`) and then reads whichever column the modifiers choose - so
    a consumer wanting KEGS's behaviour must look at the PLAIN field's
    special bit, not the chosen one's.  The flag is emitted per column
    because the table has it per column, not because it should be used that
    way.
    """
    if v < 0:
        return 0x200
    return (0x100 if (v & 0xEF00) else 0) | (v & 0xFF)


def build(rows):
    if len(rows) != 128:
        sys.exit("expected 128 entries, KEGS gave %d" % len(rows))
    out = []
    for idx, (code, plain, shift, ctrl) in enumerate(rows):
        if code != idx:
            sys.exit("entry %d names keycode %02x: the table is not indexed by "
                     "keycode any more, and adb_key_event assumes it is" % (idx, code))
        word = (field(ctrl) << 20) | (field(shift) << 10) | field(plain)
        out.append("%08x" % word)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kegs", default=DEF_KEGS)
    ap.add_argument("--out", default=None)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = a.out or os.path.join(root, "rtl", "adb_keymap.hex")
    lines = build(read_table(a.kegs))
    text = "".join(l + "\n" for l in lines)
    if a.check:
        have = open(out).read() if os.path.exists(out) else ""
        if have != text:
            sys.exit("adb_keymap.hex is out of date: rerun tools/gen_adb_keymap.py")
        print("ADB keymap up to date (128 entries)")
        return
    open(out, "w").write(text)
    print("ADB keymap: 128 entries -> %s" % out)


if __name__ == "__main__":
    main()
