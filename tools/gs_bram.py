#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Build a IIgs battery RAM image for sim/boot_gs_tb.sv to ship to the card.

DELIBERATELY A SECOND IMPLEMENTATION.  The host's is src/gs_bram.cpp and
tests/gs_bram_test.cpp pins it to the ROM's own numbers; this one is written
from docs/GS.md's account of the ROM routines and is what the BENCH ships, so
the two can disagree and be caught.  Both agree with the machine: the defaults
below are the image the ROM writes when it finds no valid checksum, captured
from boot_gs_tb's own dump, and the checksum reproduces the ROM's $2D36/$879C.

THE CHECKSUM, from $FF/BA57:

    LDX #$FA / REP #$20 / CLC / LDA #$0000
    loop: ROL A / ADC $02C0,X / DEX / CPX #$FF / BNE loop / TAX / EOR #$AAAA

The ADC is SIXTEEN BITS WIDE OVER A BYTE ARRAY, so each pass adds the
overlapping pair {b[x], b[x+1]}; and CPX #$FF ends every pass with the carry
CLEAR (X is below $FF throughout), so the ROL rotates in zero every time and
the only carry reaching the ADC is the ROL's own.  The sum goes to $FC/$FD and
its EOR $AAAA to $FE/$FF.

THE SLOTS, from $FF/BB9A: BRAM $21-$27 are slots 1-7, 1 meaning "the slot's
card", with slot 1 ALSO at $58 - and slot 3 can never be given away, being the
IIgs's internal 80-column video.

    tools/gs_bram.py --slots 6,7 --out FILE [--hex FILE]
"""
import argparse

# The image the ROM writes when the checksum is invalid: boot_gs_tb's dump of
# the battery RAM after a run with none shipped.  $60-$FB are untouched, which
# the ROM leaves as $FF, and $FC-$FF are the checksum this script recomputes.
DEFAULTS = bytes.fromhex(
    "000000010000 0d06 0201 0100 0100 0000"
    "0000 0706 0201 0100 0000 0f06 0600 0506"
    "0100 0000 0000 0001 0000 0000 0502 0200"
    "0000 2d2d 0000 0000 0000 0202 0206 0800"
    "0102 0304 0506 070a 0001 0203 0405 0607"
    "0809 0a0b 0c0d 0e0f 0000 ffff ffff ffff".replace(" ", "")
) + b"\xff" * 160

SLOT0 = 0x21          # BRAM $21-$27 = slots 1-7
SLOT1_ALSO = 0x58     # slot 1 is re-derived from here


def checksum(b):
    a = 0
    for x in range(0xFA, -1, -1):
        carry = (a >> 15) & 1          # ROL A, carry in always zero
        a = (a << 1) & 0xFFFF
        word = b[x] | (b[(x + 1) & 0xFF] << 8)
        a = (a + word + carry) & 0xFFFF
    return a


def seal(b):
    s = checksum(b)
    inv = s ^ 0xAAAA
    b[0xFC], b[0xFD] = s & 0xFF, s >> 8
    b[0xFE], b[0xFF] = inv & 0xFF, inv >> 8
    return s


def build(slots):
    b = bytearray(DEFAULTS)
    for s in range(1, 8):
        if s == 3:                     # never the slot's: internal video
            continue
        v = 1 if s in slots else 0
        b[SLOT0 + s - 1] = v
        if s == 1:
            b[SLOT1_ALSO] = v
    return b, seal(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slots", default="", help="slots given to the slot's card, e.g. 6,7")
    ap.add_argument("--out", help="256 raw bytes")
    ap.add_argument("--hex", help="one byte a line, for $readmemh")
    a = ap.parse_args()
    slots = {int(x) for x in a.slots.split(",") if x.strip()}
    b, s = build(slots)
    assert len(b) == 256
    if a.out:
        open(a.out, "wb").write(bytes(b))
    if a.hex:
        open(a.hex, "w").write("".join("%02x\n" % v for v in b))
    print("gs_bram: slots %s Your Card, checksum $%04X" %
          (sorted(slots) or "none", s))


if __name__ == "__main__":
    main()
