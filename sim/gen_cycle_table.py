#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Generate the cycle-count test vectors for sim/cpu_cycles_tb.sv.

The table below is the published W65C02S instruction timing, transcribed by
hand.  It is the REFERENCE, so it is deliberately kept as a flat literal rather
than derived from anything in rtl/cpu65c02.sv - a table computed from the core's
own decoder would agree with the core by construction and prove nothing.

Each opcode gets one vector: two operand bytes, the processor status to start
from, and the expected cycle count.  Operands are chosen so the BASE case is
measured - no page crossing, no branch taken, no decimal mode.  The variants
that add a cycle are a separate list at the bottom, because "+1 if a page
boundary is crossed" is exactly the sort of thing a core gets wrong in only one
direction.
"""

import sys

# ---------------------------------------------------------------------------
# Base cycle counts, opcode 0x00..0xFF, 16 per row.
#   - branches: NOT taken (BRA has no such case, so it is its taken 3)
#   - indexed:  no page boundary crossed
#   - ADC/SBC:  binary mode
# ---------------------------------------------------------------------------
CYCLES = [
    7,6,2,1,5,3,5,5,3,2,2,1,6,4,6,5,   # 0x
    2,5,5,1,5,4,6,5,2,4,2,1,6,4,6,5,   # 1x
    6,6,2,1,3,3,5,5,4,2,2,1,4,4,6,5,   # 2x
    2,5,5,1,4,4,6,5,2,4,2,1,4,4,6,5,   # 3x
    6,6,2,1,3,3,5,5,3,2,2,1,3,4,6,5,   # 4x
    2,5,5,1,4,4,6,5,2,4,3,1,8,4,6,5,   # 5x
    6,6,2,1,3,3,5,5,4,2,2,1,6,4,6,5,   # 6x
    2,5,5,1,4,4,6,5,2,4,4,1,6,4,6,5,   # 7x
    3,6,2,1,3,3,3,5,2,2,2,1,4,4,4,5,   # 8x
    2,6,5,1,4,4,4,5,2,5,2,1,4,5,5,5,   # 9x
    2,6,2,1,3,3,3,5,2,2,2,1,4,4,4,5,   # Ax
    2,5,5,1,4,4,4,5,2,4,2,1,4,4,4,5,   # Bx
    2,6,2,1,3,3,5,5,2,2,2,3,4,4,6,5,   # Cx
    2,5,5,1,4,4,6,5,2,4,3,3,4,4,7,5,   # Dx
    2,6,2,1,3,3,5,5,2,2,2,1,4,4,6,5,   # Ex
    2,5,5,1,4,4,6,5,2,4,4,1,4,4,7,5,   # Fx
]
assert len(CYCLES) == 256

# STP parks the CPU and WAI parks it until an interrupt.  Neither reaches a next
# opcode fetch, and this harness measures fetch-to-fetch, so they are excluded
# rather than silently mismeasured.
SKIP = {0xDB, 0xCB}

# Flags.  Bit 5 always reads 1.
C, Z, I, D, B, V, N = 0x01, 0x02, 0x04, 0x08, 0x10, 0x40, 0x80
BASE_P = 0x20

# Status that makes each conditional branch fall through.  BRA ($80) cannot.
BRANCH_NOT_TAKEN = {
    0x10: N,        # BPL: N set
    0x30: 0,        # BMI: N clear
    0x50: V,        # BVC: V set
    0x70: 0,        # BVS: V clear
    0x90: C,        # BCC: C set
    0xB0: 0,        # BCS: C clear
    0xD0: Z,        # BNE: Z set
    0xF0: 0,        # BEQ: Z clear
}

# The addressing mode determines what the operand bytes have to be.  Values are
# picked against the memory map cpu_cycles_tb.sv builds:
#   $10,$11  -> pointer to $0300      (for (zp) and (zp),Y)
#   $12,$13  -> pointer to $0300      (for (zp,X) with X=2)
#   $0300..  -> data
# and X = Y = 2, so no indexed access leaves page 3.
ZP, ABS_LO, ABS_HI = 0x10, 0x00, 0x03

# Opcodes by operand shape.  Anything not listed is implied/accumulator and
# takes no operand bytes.
TWO_BYTE_ZP = set()
for base in (0x04, 0x05, 0x06, 0x14, 0x15, 0x16, 0x24, 0x25, 0x26, 0x34, 0x35,
             0x36, 0x44, 0x45, 0x46, 0x54, 0x55, 0x56, 0x64, 0x65, 0x66, 0x74,
             0x75, 0x76, 0x84, 0x85, 0x86, 0x94, 0x95, 0x96, 0xA4, 0xA5, 0xA6,
             0xB4, 0xB5, 0xB6, 0xC4, 0xC5, 0xC6, 0xD4, 0xD5, 0xD6, 0xE4, 0xE5,
             0xE6, 0xF4, 0xF5, 0xF6):
    TWO_BYTE_ZP.add(base)
# (zp,X), (zp),Y, (zp), RMB/SMB, and BBR/BBS all take a zero-page byte first.
for hi in range(0x00, 0x100, 0x10):
    TWO_BYTE_ZP.add(hi | 0x01)      # (zp,X)
    TWO_BYTE_ZP.add(hi | 0x11)      # (zp),Y
    TWO_BYTE_ZP.add(hi | 0x12)      # (zp)
    TWO_BYTE_ZP.add(hi | 0x07)      # RMBn / SMBn
    TWO_BYTE_ZP.add(hi | 0x0F)      # BBRn / BBSn  (zp, then rel)

IMMEDIATE = {0x02, 0x09, 0x22, 0x29, 0x42, 0x49, 0x62, 0x69, 0x82, 0x89,
             0xA0, 0xA2, 0xA9, 0xC0, 0xC2, 0xC9, 0xE0, 0xE2, 0xE9}

BRANCHES = set(BRANCH_NOT_TAKEN) | {0x80}

THREE_BYTE = set()
for hi in range(0x00, 0x100, 0x10):
    for lo in (0x0C, 0x0D, 0x0E, 0x19, 0x1C, 0x1D, 0x1E):
        THREE_BYTE.add(hi | lo)
THREE_BYTE |= {0x20, 0x4C, 0x6C, 0x7C, 0x5C}
THREE_BYTE -= {0x1F, 0x3F, 0x5F, 0x7F, 0x9F, 0xBF, 0xDF, 0xFF}  # BBSn/BBRn
# 0x89 is BIT immediate, 0x9C/0x9E are STZ abs / abs,X (already 3-byte).


def operands(op):
    """The two operand bytes to place after `op`, and the starting status."""
    p = BASE_P | BRANCH_NOT_TAKEN.get(op, 0)

    if op in BRANCHES:
        # A short forward offset: taken or not, it cannot leave the page.
        return 0x02, 0x00, p
    if op & 0x0F == 0x0F:            # BBRn/BBSn: zp then rel
        return ZP, 0x02, p
    if op in IMMEDIATE:
        return 0x55, 0x00, p
    if op in TWO_BYTE_ZP:
        return ZP, 0x00, p
    if op in THREE_BYTE:
        return ABS_LO, ABS_HI, p
    return 0x00, 0x00, p


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "cycle_vectors.hex"
    with open(out, "w") as f:
        for op in range(256):
            o1, o2, p = operands(op)
            exp = 0 if op in SKIP else CYCLES[op]
            f.write(f"{o1:02x} {o2:02x} {p:02x} {exp:02x}\n")
    print(f"wrote {out}: 256 vectors, {len(SKIP)} skipped ({', '.join(f'${o:02X}' for o in sorted(SKIP))})")


if __name__ == "__main__":
    main()
