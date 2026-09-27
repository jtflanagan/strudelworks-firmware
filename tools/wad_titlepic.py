#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""wad_titlepic - DOOM's title screen out of a WAD, as a PNG (the SPLASH
application's resource, docs/RVV2_INTEROP.md rung I5): TITLEPIC, a 320x200
patch (columns of posts), through PLAYPAL's first palette, written as an 8-bit
palette PNG; and, for sim/run_rv_app.sh, the RGB565 picture a right decoder and
blit leave in the video banks.  Nothing made from the WAD goes into git.

  tools/wad_titlepic.py WAD OUT.PNG [OUT.565]
"""
import struct
import sys

from PIL import Image


def lumps(wad):
    magic, n, dirofs = struct.unpack("<4sII", wad[:12])
    if magic not in (b"IWAD", b"PWAD"):
        sys.exit("not a WAD")
    out = {}
    for i in range(n):
        ofs, size, name = struct.unpack("<II8s", wad[dirofs + 16 * i:dirofs + 16 * i + 16])
        out.setdefault(name.rstrip(b"\0").decode(), wad[ofs:ofs + size])
    return out


def patch_pixels(p):
    w, h = struct.unpack("<HH", p[:4])
    px = [0] * (w * h)                            # (a title picture covers every pixel)
    for x in range(w):
        ofs = struct.unpack("<I", p[8 + 4 * x:12 + 4 * x])[0]
        while p[ofs] != 0xFF:
            top, n = p[ofs], p[ofs + 1]
            for k in range(n):
                px[(top + k) * w + x] = p[ofs + 3 + k]
            ofs += n + 4
    return w, h, px


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__.strip().splitlines()[-1])
    L = lumps(open(sys.argv[1], "rb").read())
    pal = L["PLAYPAL"][:768]
    w, h, px = patch_pixels(L["TITLEPIC"])
    im = Image.new("P", (w, h))
    im.putpalette(pal)
    im.putdata(px)
    im.save(sys.argv[2])
    if len(sys.argv) == 4:
        out = bytearray()
        for i in px:
            r, g, b = pal[3 * i], pal[3 * i + 1], pal[3 * i + 2]
            out += struct.pack("<H", ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
        open(sys.argv[3], "wb").write(out)


if __name__ == "__main__":
    main()
