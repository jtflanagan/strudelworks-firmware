#!/usr/bin/env python3
# strudelworks-firmware
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# SYNTHETIC ROMs FOR THE CLOCK MICROBENCHMARKS (2026-09-20).
#
# boot_gs_tb boots whatever --rom names, so a 256 KB image whose reset vector
# lands in a tight loop runs that loop on the WHOLE accel path - the core, the
# TLB, L1-I, L1-D and the CAM-L2 - with every counter the bench prints and no
# operating system in the way.  Forty seconds a run, against hours for a row
# long enough to reach the Finder: the GS/OS row reaches ~2% of a boot, so it
# measures early boot and nothing else (2026-09-20, the user's call, and the
# hardware census proved it - the row predicted +6.2% where the Finder gave
# +13.9%).
#
#   python3 sim/gen_micro_rom.py OUTDIR
#   sim/run_boot_gs_tb.sh --rom=OUTDIR/mvn_rom.bin --instrs=200000 \
#                         --ref=none --room=0 --tag=mvn
#
# ALWAYS --room=0.  The bench's event-room model back-pressures the stream and
# swamps the measurement otherwise (the same run reads 13.8 clocks a byte with
# it off and 23.1 with it on).
#
# What the MVN image measured on 2026-09-20, and it is the block move's shape
# in one line: 13.8 clocks per byte against a seven-cycle floor, every read at
# gap 3 (the histogram is zero everywhere else), all three fetches a byte
# turbo, ZERO branches the target table did not know - and the overhead is
# drain ~2.0, claim ~1.3, settle ~1.0 (DBR rewritten every iteration) and
# recover ~1.0 (the microcode's PC rewind paying a bubble at the sync) per
# byte.  The copy image is the control: the same 64 KB moved by hand costs
# 66.7 clocks a byte, because every long,X rides the dispatcher.

import sys
import os

# Banks $FC-$FF.  Bank $FF is at 0x30000, so $FF/F000 is 0x3F000 - and bank
# zero's high memory reads ROM at reset, which is where the vector points.
BANK_FF = 0x30000
ENTRY = 0xF000


def rom(code):
    r = bytearray(b"\x00" * 0x40000)
    at = BANK_FF + ENTRY
    r[at:at + len(code)] = code
    r[BANK_FF + 0xFFFC:BANK_FF + 0xFFFE] = ENTRY.to_bytes(2, "little")
    return bytes(r)


# The block move: native, 16-bit, MVN $03,$02 of 64 KB, for ever.  The opcode
# is `54 dst src` - the first operand read is the destination bank (it becomes
# DBR), the second the source's, which is the order the microcode reads them.
MVN = bytes([
    0x18,                    # CLC
    0xFB,                    # XCE            -> native
    0xC2, 0x30,              # REP #$30       -> 16-bit A/X/Y
    0xA9, 0xFF, 0xFF,        # LDA #$FFFF     <- loop: 65536 bytes
    0xA2, 0x00, 0x00,        # LDX #$0000
    0xA0, 0x00, 0x00,        # LDY #$0000
    0x54, 0x03, 0x02,        # MVN dst=$03, src=$02
    0x80, 0xF2,              # BRA loop
])

# The control: the same copy written out by hand, 16 bits at a time.
CPY = bytes([
    0x18,                    # CLC
    0xFB,                    # XCE
    0xC2, 0x30,              # REP #$30
    0xA2, 0x00, 0x00,        # LDX #$0000     <- loop
    0xBF, 0x00, 0x00, 0x02,  # LDA $020000,X  <- inner
    0x9F, 0x00, 0x00, 0x03,  # STA $030000,X
    0xE8, 0xE8,              # INX INX
    0xD0, 0xF6,              # BNE inner
    0x80, 0xF2,              # BRA loop
])

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "sim/boot_work"
    os.makedirs(out, exist_ok=True)
    for name, code in (("mvn_rom.bin", MVN), ("cpy_rom.bin", CPY)):
        p = os.path.join(out, name)
        with open(p, "wb") as f:
            f.write(rom(code))
        print(p)
