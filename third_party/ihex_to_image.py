#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Intel hex -> a flat 64 KiB memory image, as65's conventions and all.

Two of those conventions are load-bearing, and both were found by requiring a
byte-for-byte match against upstream's own prebuilt image:

  - unused memory inside the used range reads $FF, not $00.  It is what the
    assembler writes and what the suite therefore runs against, and filler is
    not inert: a test that runs off the end lands in it.
  - BELOW the lowest used address the image is $00.  as65's binary simply
    starts there, so those bytes come from whatever pads the front.

Reading the .bin directly instead of this would be simpler and wrong: it begins
at the lowest used address, so treating it as a memory image shifts the whole
program down by that offset - $0A in the 65C02 suite's case, which is not an
error anything reports.
"""

import sys


def main():
    src, dst = sys.argv[1], sys.argv[2]
    mem = bytearray([0xFF]) * 65536
    lo = 0x10000
    for line in open(src):
        line = line.strip()
        if not line.startswith(":"):
            continue
        b = bytes.fromhex(line[1:])
        n, addr, rt = b[0], (b[1] << 8) | b[2], b[3]
        if rt == 0:                      # data
            mem[addr:addr + n] = b[4:4 + n]
            lo = min(lo, addr)
        # rt 1 is EOF; the suite emits no segment or linear-address records.
    for i in range(lo):
        mem[i] = 0x00
    with open(dst, "wb") as f:
        f.write(mem)


if __name__ == "__main__":
    main()
