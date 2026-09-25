#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""mkpkg - an image package from a bitstream (docs/BOOT_LOADER.md, "The record and the package").

    tools/mkpkg.py build/results/master_top_gs.bit [--stamp YYYYMMDD HHMMSS | --log LOG]

Writes three files beside the .bit:

    <name>.bin   the raw bitstream (the .bit's data field; what goes at flash 0)
    <name>.rec   the record sector: 4 KB, the 64-byte record then FF (what goes at 0x3FF000)
    <name>.pkg   the package for the USB3 loader: the record sector, then the bitstream

The record's build stamp must be the one the image reports (BUILD_DATE / BUILD_TIME),
so it comes from --stamp or from the build log's "build stamp: YYYYMMDD HHMMSS" line.
"""
import argparse
import re
import struct
import sys
import zlib
from pathlib import Path

REC_MAGIC = 0x4B525753          # "SWRK"
REC_VERSION = 1
FLASH_PROTOCOL = 1
SECTOR = 4096
IMAGE_END = 0x3FE000

IDCODES = {"7a100t": 0x13631093, "7a50t": 0x0362C093, "7a35t": 0x0362D093}
BOARDS = {"pt_v2": 1, "au_v2": 2}
MACHINES = {"iie": 1, "gs": 2}


def read_bit(path):
    """The .bit's fields: {'a': design, 'b': part, 'c': date, 'd': time}, and the data."""
    b = path.read_bytes()
    i = 0
    n = struct.unpack(">H", b[i:i + 2])[0]; i += 2 + n          # the 9-byte magic
    i += 2                                                      # 0x0001
    fields = {}
    while i < len(b):
        key = chr(b[i]); i += 1
        if key == "e":
            n = struct.unpack(">I", b[i:i + 4])[0]; i += 4
            return fields, b[i:i + n]
        n = struct.unpack(">H", b[i:i + 2])[0]; i += 2
        fields[key] = b[i:i + n].rstrip(b"\0").decode("ascii", "replace"); i += n
    sys.exit("mkpkg: no data field in " + str(path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bit", type=Path)
    ap.add_argument("--stamp", nargs=2, metavar=("DATE", "TIME"))
    ap.add_argument("--log", type=Path)
    a = ap.parse_args()

    fields, data = read_bit(a.bit)
    part = fields.get("b", "")
    idcode = next((v for k, v in IDCODES.items() if part.startswith(k)), None)
    if idcode is None:
        sys.exit(f"mkpkg: no IDCODE known for part '{part}'")
    if len(data) > IMAGE_END:
        sys.exit(f"mkpkg: {len(data)} bytes of bitstream exceed the image's room ({IMAGE_END})")

    board_file = a.bit.with_suffix(".board")
    board = board_file.read_text().strip() if board_file.exists() else "pt_v2"
    machine = "gs" if a.bit.stem.endswith("_gs") else "iie"

    if a.stamp:
        date, time = int(a.stamp[0]), int(a.stamp[1])
    elif a.log:
        m = re.search(r"build stamp: (\d{8}) (\d{6})", a.log.read_text(errors="replace"))
        if not m:
            sys.exit(f"mkpkg: no 'build stamp:' line in {a.log}")
        date, time = int(m.group(1)), int(m.group(2))
    else:
        sys.exit("mkpkg: give --stamp DATE TIME or --log BUILD_LOG (the stamp the image reports)")

    words = [REC_MAGIC, REC_VERSION, len(data), zlib.crc32(data) & 0xFFFFFFFF, idcode,
             BOARDS.get(board, 0) | (MACHINES[machine] << 8), FLASH_PROTOCOL, date, time] + [0] * 6
    head = struct.pack("<15I", *words)
    record = head + struct.pack("<I", zlib.crc32(head) & 0xFFFFFFFF)
    sector = record + b"\xff" * (SECTOR - len(record))

    stem = a.bit.with_suffix("")
    Path(str(stem) + ".bin").write_bytes(data)
    Path(str(stem) + ".rec").write_bytes(sector)
    Path(str(stem) + ".pkg").write_bytes(sector + data)
    print(f"{a.bit.name}: part {part} idcode {idcode:08x}, board {board}, machine {machine}, "
          f"{len(data)} bytes crc {words[3]:08x}, stamp {date} {time:06d}")
    print(f"  -> {stem.name}.bin (flash 0), {stem.name}.rec (flash 0x3FF000), {stem.name}.pkg (USB3)")


if __name__ == "__main__":
    main()
