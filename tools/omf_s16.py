#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""omf_s16 - raw 65816 bytes as a GS/OS application (an OMF load file, type S16).

The stub of an application backed by RISC-V (docs/RVV2_INTEROP.md) is
relocation-free - position-independent code, and fixed long addresses into $F1
and $E1 - so its load file is one code segment and no relocation records: the
segment header, one LCONST record with the bytes, an END record.  A second
segment asks for the direct page and stack (KIND $12, "~Direct", reserved space
only): the runtime uses that direct page and stack while the application runs,
toolbox calls included, so it is sized here rather than left to the loader's
default.

The layout is the one GS/OS's own SYSTEM/START carries (read off System 6.0.1,
2026-09-26): a 44-byte fixed header (BYTECNT, RESSPC, LENGTH, -, LABLEN 0,
NUMLEN 4, VERSION 2, BANKSIZE, KIND, -, ORG, ALIGN, NUMSEX, -, SEGNUM, ENTRY,
DISPNAME, DISPDATA), a 10-byte load name, the segment name as a length-prefixed
string, then the body.  KIND $0000 is a static code segment; BANKSIZE $10000
keeps it inside one bank.

  tools/omf_s16.py IN.bin OUT [--name main] [--direct BYTES, default 4096]
"""
import struct
import sys


def _segment(body: bytes, length: int, resspc: int, kind: int, banksize: int, align: int,
             segname: bytes, segnum: int) -> bytes:
    head_len = 44
    names = bytes(10) + bytes([len(segname)]) + segname
    bytecnt = head_len + len(names) + len(body)
    h = struct.pack("<III", bytecnt, resspc, length)        # BYTECNT, RESSPC, LENGTH
    h += bytes([0, 0, 4, 2])                                 # -, LABLEN, NUMLEN, VERSION
    h += struct.pack("<IH", banksize, kind)                  # BANKSIZE, KIND
    h += bytes(2)                                            # -
    h += struct.pack("<II", 0, align)                        # ORG, ALIGN
    h += bytes([0, 0])                                       # NUMSEX (little-endian), -
    h += struct.pack("<HI", segnum, 0)                       # SEGNUM, ENTRY
    h += struct.pack("<HH", head_len, head_len + len(names))  # DISPNAME, DISPDATA
    assert len(h) == head_len
    return h + names + body


def omf_segment(code: bytes, segname: bytes = b"main", segnum: int = 1) -> bytes:
    """The code: one LCONST record, an END record.  KIND $0000, static code."""
    body = bytes([0xF2]) + struct.pack("<I", len(code)) + code + bytes([0x00])
    return _segment(body, len(code), 0, 0x0000, 0x10000, 0, segname, segnum)


def omf_direct(size: int, segnum: int = 2) -> bytes:
    """The direct page / stack segment (KIND $12): no bytes, only its size as
    reserved space; the loader puts it in bank 0 and enters the application with
    D at its start and S at its end."""
    return _segment(bytes([0x00]), size, size, 0x0012, 0x10000, 0x100, b"~Direct", segnum)


def main():
    args = sys.argv[1:]
    name = b"main"
    direct = 4096
    if "--name" in args:
        i = args.index("--name")
        name = args[i + 1].encode("ascii")
        del args[i:i + 2]
    if "--direct" in args:
        i = args.index("--direct")
        direct = int(args[i + 1], 0)
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    code = open(args[0], "rb").read()
    if not code or len(code) > 0x10000:
        sys.exit(f"{args[0]}: {len(code)} bytes - a segment is 1..65536")
    if direct % 256 or not 256 <= direct <= 0x8000:
        sys.exit(f"--direct {direct}: whole pages, 256..32768")
    out = omf_segment(code, name) + omf_direct(direct)
    open(args[1], "wb").write(out)
    print(f"{args[1]}: static code '{name.decode()}' ({len(code)} bytes) + ~Direct ({direct} bytes), {len(out)} bytes")


if __name__ == "__main__":
    main()
