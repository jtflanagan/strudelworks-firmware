#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""wad_pic_png - one picture lump out of a DOOM WAD, as an indexed PNG.

The RISC-V splash (docs/REQ_RVVM.md) shows DOOM's title screen; its source is
the WAD's own TITLEPIC drawn through PLAYPAL's first palette.  The PNG is
written as 8-bit indexed with that palette, so the decoder on the engine sees
exactly the WAD's pixels and does the RGB565 conversion itself.  The WAD and
anything drawn from it stay outside the repo (the shareware licence covers the
unmodified package only).

A picture lump is DOOM's patch format: width, height, left and top offsets
(four int16), then one uint32 offset per column to a list of posts - each post
a top delta, a length, a pad byte, that many palette indices and a pad byte,
ended by $FF.  Pixels no post covers are transparent; a full-screen picture
covers them all, and any it does not are left as index 0 and reported.

  tools/wad_pic_png.py WAD OUT.png [LUMP, default TITLEPIC]
"""
import struct
import sys

from PIL import Image


def lumps(wad):
    magic, count, dir_at = struct.unpack_from("<4sii", wad, 0)
    if magic not in (b"IWAD", b"PWAD"):
        sys.exit(f"not a WAD (magic {magic!r})")
    out = {}
    for i in range(count):
        at, size, name = struct.unpack_from("<ii8s", wad, dir_at + 16 * i)
        out[name.rstrip(b"\0").decode("ascii")] = wad[at:at + size]
    return out


def picture(lump):
    w, h, _, _ = struct.unpack_from("<hhhh", lump, 0)
    cols = struct.unpack_from(f"<{w}I", lump, 8)
    pix = bytearray(w * h)
    covered = bytearray(w * h)
    for x, at in enumerate(cols):
        while lump[at] != 0xFF:
            top, n = lump[at], lump[at + 1]
            for i in range(n):
                y = top + i
                if y < h:
                    pix[y * w + x] = lump[at + 3 + i]
                    covered[y * w + x] = 1
            at += n + 4
    return w, h, bytes(pix), covered.count(0)


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__.strip().splitlines()[-1])
    wad = open(sys.argv[1], "rb").read()
    name = sys.argv[3] if len(sys.argv) == 4 else "TITLEPIC"
    ls = lumps(wad)
    if name not in ls:
        sys.exit(f"no lump {name}")
    w, h, pix, holes = picture(ls[name])
    img = Image.frombytes("P", (w, h), pix)
    img.putpalette(ls["PLAYPAL"][:768])
    img.save(sys.argv[2], optimize=True)
    print(f"{name}: {w}x{h}, {len(set(pix))} colours used, {holes} uncovered pixels -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
