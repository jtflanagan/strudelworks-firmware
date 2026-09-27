#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""omf_s16 - raw 65816 bytes as a GS/OS application (an OMF load file, type S16).

The stub of an application backed by RISC-V (docs/RVV2_INTEROP.md) is
relocation-free - position-independent code, and fixed long addresses into $F1
and $E1 - so its load file is one code segment and no relocation records: the
segment header, one LCONST record with the bytes, an END record.

The layout is the one GS/OS's own SYSTEM/START carries (read off System 6.0.1,
2026-09-26): a 44-byte fixed header (BYTECNT, RESSPC, LENGTH, -, LABLEN 0,
NUMLEN 4, VERSION 2, BANKSIZE, KIND, -, ORG, ALIGN, NUMSEX, -, SEGNUM, ENTRY,
DISPNAME, DISPDATA), a 10-byte load name, the segment name as a length-prefixed
string, then the body.  KIND $0000 is a static code segment; BANKSIZE $10000
keeps it inside one bank.

  tools/omf_s16.py IN.bin OUT [--name main]
"""
import struct
import sys


def omf_segment(code: bytes, segname: bytes = b"main", segnum: int = 1) -> bytes:
    head_len = 44
    names = bytes(10) + bytes([len(segname)]) + segname
    body = bytes([0xF2]) + struct.pack("<I", len(code)) + code + bytes([0x00])   # LCONST, END
    bytecnt = head_len + len(names) + len(body)
    h = struct.pack("<III", bytecnt, 0, len(code))          # BYTECNT, RESSPC, LENGTH
    h += bytes([0, 0, 4, 2])                                 # -, LABLEN, NUMLEN, VERSION
    h += struct.pack("<IH", 0x10000, 0x0000)                 # BANKSIZE, KIND: static code
    h += bytes(2)                                            # -
    h += struct.pack("<II", 0, 0)                            # ORG, ALIGN
    h += bytes([0, 0])                                       # NUMSEX (little-endian), -
    h += struct.pack("<HI", segnum, 0)                       # SEGNUM, ENTRY
    h += struct.pack("<HH", head_len, head_len + len(names))  # DISPNAME, DISPDATA
    assert len(h) == head_len
    return h + names + body


def main():
    args = sys.argv[1:]
    name = b"main"
    if "--name" in args:
        i = args.index("--name")
        name = args[i + 1].encode("ascii")
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    code = open(args[0], "rb").read()
    if not code or len(code) > 0x10000:
        sys.exit(f"{args[0]}: {len(code)} bytes - a segment is 1..65536")
    out = omf_segment(code, name)
    open(args[1], "wb").write(out)
    print(f"{args[1]}: one static code segment '{name.decode()}', {len(code)} bytes of code, {len(out)} bytes")


if __name__ == "__main__":
    main()
