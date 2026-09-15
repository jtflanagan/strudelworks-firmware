#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""A 5.25" floppy image, nibblized track by track the way the HOST does it.

A PORT OF strudelworks-host's floppy path, which the bench plays when it
plays host: src/fd_nibble.cpp / src/fd_nibble.hpp (encode62, nibblize_track,
skew_track and the physical->logical sector table - themselves ported from
AppleWin's source/DiskImageHelper.cpp, GPL-2.0-or-later, (C) 1994-1996
Michael O'Brien, (C) 1999-2001 Oliver Schmidt, (C) 2002-2005 Tom
Charlesworth, Michael Pohoreski, Nick Westgate), src/fd_image.cpp
(FdImage::open's type/order/track-count rules and FdImage::read_track: a .nib
is copied, a sector image is nibblized then skewed), src/fd_service.cpp
(FdService::do_image: tracks x 6656 bytes, $FF-filled, each track written
over its front) and src/protocol.hpp (proto::fd::kTrackBytes = 6656).  Where
the host and AppleWin differ, this follows the host.

A sector track is 6384 nibbles: gap 1 (48 x $FF), then per physical sector
the address field D5 AA 96, volume 254, track, sector, checksum in 4&4,
DE AA EB; gap 2 (6 x $FF); the data field D5 AA AD, 343 6&2 nibbles,
DE AA EB; gap 3 (27 x $FF).  Then it is rotated LEFT by (768 * t) % 6384
nibbles (the byte at index skew comes first), and sits at the front of a
6656-byte slot whose last 272 bytes stay $FF.  A .nib track is its 6656
bytes as they are in the file.

    tools/nib525.py IMAGE [--hex OUT] [--bits --counts OUT] [--info] [--verify]

--bits makes the hex file the tracks as the CARD reads them now (branch
woz_support): each track's nibbles as a bit stream, high bit first, every
$FF outside an address or data field ten bits wide (eight ones, two zeros),
zero-padded to 6656 bytes - a port of the host's fd_nibble.cpp
bits_from_nibbles - and --counts writes each track's bit count, one a line.

The hex file is tracks x 6656 lines, one byte a line, two lowercase hex
digits ($readmemh); track t is lines t*6656 .. t*6656+6655.  The summary
(type, order, tracks, nibbles per track) always goes to stdout; --info asks
for nothing more.  --verify decodes every track back (circularly over the
nibbles per track, checking every checksum and epilogue) and compares the
rebuilt image with the file byte for byte.
"""
import sys

# ---- the host's constants (fd_nibble.hpp, protocol.hpp) ---------------------
SECTOR_BYTES = 256
SECTORS = 16
TRACK_SECTOR_BYTES = SECTORS * SECTOR_BYTES     # 4096
NIBBLES_PER_TRACK = 6384                        # a nibblized sector track
NIB_NIBBLES = 6656                              # a .nib's track
DEFAULT_VOLUME = 254
TRACK_BYTES = 6656                              # proto::fd::kTrackBytes
SKEW_PER_TRACK = 768

GAP1 = 48
GAP2 = 6
GAP3 = 27

ORDER_PRODOS = 0
ORDER_DOS = 1
ORDER_NAMES = {ORDER_PRODOS: 'ProDOS', ORDER_DOS: 'DOS'}

# fd_nibble.cpp kDiskByte: the 6&2 alphabet.
DISK_BYTE = [
    0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA6,
    0xA7, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB2, 0xB3,
    0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC,
    0xBD, 0xBE, 0xBF, 0xCB, 0xCD, 0xCE, 0xCF, 0xD3,
    0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE,
    0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC,
    0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6,
    0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
]

# fd_nibble.cpp kSectorNumber[order][physical] = logical sector in the file.
SECTOR_NUMBER = [
    [0x00, 0x08, 0x01, 0x09, 0x02, 0x0A, 0x03, 0x0B,
     0x04, 0x0C, 0x05, 0x0D, 0x06, 0x0E, 0x07, 0x0F],   # ProDOS
    [0x00, 0x07, 0x0E, 0x06, 0x0D, 0x05, 0x0C, 0x04,
     0x0B, 0x03, 0x0A, 0x02, 0x09, 0x01, 0x08, 0x0F],   # DOS
]


def code44a(a):
    return ((a >> 1) & 0x55) | 0xAA


def code44b(a):
    return (a & 0x55) | 0xAA


def encode62(sector):
    """fd_nibble.cpp encode62: 256 bytes -> 343 nibbles.  `offset` is a byte
    and wraps, as in the C++."""
    six = []
    offset = 0xAC
    while offset != 0x02:
        value = 0
        for step in (0x56, 0x56, 0x53):
            a = sector[offset]
            value = ((value << 2) | ((a & 0x01) << 1) | ((a & 0x02) >> 1)) & 0xFF
            offset = (offset - step) & 0xFF
        six.append((value << 2) & 0xFF)
    six[-2] &= 0x3F
    six[-1] &= 0x3F
    six.extend(sector[:256])
    assert len(six) == 342
    out = []
    saved = 0
    for i in range(342):
        out.append(DISK_BYTE[(saved ^ six[i]) >> 2])
        saved = six[i]
    out.append(DISK_BYTE[saved >> 2])
    return out


def nibblize_track(sectors, order, track, volume=DEFAULT_VOLUME):
    """fd_nibble.cpp nibblize_track: 4096 bytes in `order` -> 6384 nibbles."""
    t = track & 0xFF
    p = [0xFF] * GAP1
    for s in range(SECTORS):
        p += [0xD5, 0xAA, 0x96,
              code44a(volume), code44b(volume),
              code44a(t), code44b(t),
              code44a(s), code44b(s),
              code44a(volume ^ t ^ s), code44b(volume ^ t ^ s),
              0xDE, 0xAA, 0xEB]
        p += [0xFF] * GAP2
        p += [0xD5, 0xAA, 0xAD]
        log = SECTOR_NUMBER[order][s]
        p += encode62(sectors[log << 8:(log << 8) + 256])
        p += [0xDE, 0xAA, 0xEB]
        p += [0xFF] * GAP3
    assert len(p) == NIBBLES_PER_TRACK, len(p)
    return p


def skew_track(nibbles, track):
    """fd_nibble.cpp skew_track: out[i] = in[(i + skew) % n], skew = 768t % n."""
    n = len(nibbles)
    if n == 0:
        return nibbles
    skew = (track * SKEW_PER_TRACK) % n
    if skew == 0:
        return nibbles
    return nibbles[skew:] + nibbles[:skew]


# ---- FdImage::open: what the file is ----------------------------------------
def sector_image_tracks(size):
    """fd_image.cpp sector_image_tracks (AppleWin's IsValidImageSize)."""
    k = TRACK_SECTOR_BYTES
    if size > 40 * k:
        return 0
    if size >= 36 * k:
        ok = ((size - 35 * k) % k) == 0
    else:
        ok = (143105 <= size <= 143364) or size in (143403, 143488)
    return size // k if ok else 0


def _le16(img, p):
    return img[p] | (img[p + 1] << 8)


def looks_dos_order(img):
    if len(img) < 0x12000:
        return False
    ok = True
    for loop in range(1, 16):
        if img[0x11002 + (loop << 8)] != ((loop - 1) & 0xFF):
            ok = False
            break
    if ok:
        return True
    ok = True
    for loop in range(2, 6):
        p = loop << 9
        if (_le16(img, p + 0x100) != (0 if loop == 5 else 6 - loop) or
                _le16(img, p + 0x102) != (0 if loop == 2 else 8 - loop)):
            ok = False
            break
    return ok


def looks_prodos_order(img):
    if len(img) < 0x12000:
        return False
    ok = True
    for loop in range(5, 14):
        if img[0x11002 + (loop << 8)] != ((14 - loop) & 0xFF):
            ok = False
            break
    if ok:
        return True
    ok = True
    for loop in range(2, 6):
        p = loop << 9
        if (_le16(img, p) != (0 if loop == 2 else loop - 1) or
                _le16(img, p + 2) != (0 if loop == 5 else loop + 1)):
            ok = False
            break
    return ok


def classify(path, data):
    """-> (kind 'nib'|'sector', order, tracks), or raises ValueError as
    FdImage::open refuses."""
    low = path.lower()
    size = len(data)
    if low.endswith('.nib'):
        if size < 35 * NIB_NIBBLES or size % NIB_NIBBLES != 0 or size > 40 * NIB_NIBBLES:
            raise ValueError(f'{path}: not a 35-40 track .nib')
        return 'nib', None, size // NIB_NIBBLES
    tracks = sector_image_tracks(size)
    if tracks == 0:
        raise ValueError(f'{path}: not a 5.25" sector image ({size} bytes)')
    order = ORDER_PRODOS if low.endswith('.po') else ORDER_DOS
    if not low.endswith('.po') and not low.endswith('.do'):
        if looks_dos_order(data):
            order = ORDER_DOS
        elif looks_prodos_order(data):
            order = ORDER_PRODOS
    return 'sector', order, tracks


def read_track(kind, order, data, t):
    """FdImage::read_track: the nibbles for track t (6384 or 6656)."""
    if kind == 'nib':
        return list(data[t * NIB_NIBBLES:(t + 1) * NIB_NIBBLES])
    pos = t * TRACK_SECTOR_BYTES
    sectors = bytearray(TRACK_SECTOR_BYTES)          # a short last track reads zero
    chunk = data[pos:pos + TRACK_SECTOR_BYTES]
    sectors[:len(chunk)] = chunk
    return skew_track(nibblize_track(sectors, order, t), t)


def nibblize_image(path):
    """-> (bytes of tracks * 6656, nibbles_per_track, tracks), as do_image."""
    data = open(path, 'rb').read()
    kind, order, tracks = classify(path, data)
    npt = NIB_NIBBLES if kind == 'nib' else NIBBLES_PER_TRACK
    allb = bytearray([0xFF]) * (tracks * TRACK_BYTES)
    for t in range(tracks):
        nibs = read_track(kind, order, data, t)
        allb[t * TRACK_BYTES:t * TRACK_BYTES + len(nibs)] = bytes(nibs)
    return bytes(allb), npt, tracks


# ---- the track as bits (fd_nibble.cpp bits_from_nibbles) ---------------------
def bits_from_nibbles(nibs):
    """-> (TRACK_BYTES bytes of bit stream, bit count).  A $FF outside a field
    - the address field D5 AA 96 or data field D5 AA AD, to its DE AA - is a
    ten-bit sync nibble; everything else eight bits, high bit first."""
    out = bytearray(TRACK_BYTES)
    k = 0
    def put(b):
        nonlocal k
        if k < 8 * TRACK_BYTES:
            if b:
                out[k >> 3] |= 0x80 >> (k & 7)
            k += 1
    in_field = False
    n = len(nibs)
    i = 0
    while i < n:
        v = nibs[i]
        if (not in_field and v == 0xD5 and i + 2 < n and nibs[i + 1] == 0xAA and
                nibs[i + 2] in (0x96, 0xAD)):
            in_field = True
        for b in range(8):
            put((v >> (7 - b)) & 1)
        if not in_field and v == 0xFF:
            put(0); put(0)
        if in_field and v == 0xDE and i + 1 < n and nibs[i + 1] == 0xAA:
            in_field = False
            a = nibs[i + 1]
            for b in range(8):
                put((a >> (7 - b)) & 1)
            i += 1
        i += 1
    return bytes(out), k

# ---- the reverse, for --verify: an independent reader -----------------------
# Written from the disk format, not from the host's denibblize_track, so that
# it does not share the encoder's arithmetic.
SIX_OF = {v: i for i, v in enumerate(DISK_BYTE)}


def dec44(a, b):
    return ((a << 1) | 1) & b


def decode62_indep(nibs):
    """343 nibbles -> (256 bytes, None) or (None, reason)."""
    x = []
    for n in nibs:
        if n not in SIX_OF:
            return None, f'bad 6&2 nibble {n:02x}'
        x.append(SIX_OF[n])
    v = [0] * 342
    prev = 0
    for i in range(342):
        v[i] = x[i] ^ prev
        prev = v[i]
    if x[342] != prev:
        return None, 'data checksum'
    out = bytearray(256)
    swap = (0, 2, 1, 3)
    for i in range(256):
        out[i] = v[86 + i] << 2
    for j in range(86):
        out[j] |= swap[v[j] & 3]
        out[j + 0x56] |= swap[(v[j] >> 2) & 3]
        if j + 0xAC < 256:
            out[j + 0xAC] |= swap[(v[j] >> 4) & 3]
        elif (v[j] >> 4) & 3:
            return None, 'unused aux bits set'
    return bytes(out), None


def verify_track(nibs, npt, track, order, volume=DEFAULT_VOLUME):
    """Walk a circular track; -> (4096 bytes, errors, sector-0 D5 index)."""
    n = npt
    at = lambda i: nibs[i % n]
    errors = []
    found = {}
    s0_pos = None
    for p in range(n):
        if not (at(p) == 0xD5 and at(p + 1) == 0xAA and at(p + 2) == 0x96):
            continue
        f = [at(p + 3 + k) for k in range(11)]
        vol, trk, sec, ck = dec44(f[0], f[1]), dec44(f[2], f[3]), dec44(f[4], f[5]), dec44(f[6], f[7])
        if vol ^ trk ^ sec ^ ck:
            errors.append(f'T{track} @{p}: address checksum')
            continue
        if f[8:11] != [0xDE, 0xAA, 0xEB]:
            errors.append(f'T{track} @{p}: address epilogue {f[8:11]}')
        if vol != volume or trk != track or sec >= SECTORS:
            errors.append(f'T{track} @{p}: vol {vol} trk {trk} sec {sec}')
            continue
        # The data prologue, within the next gap's reach.
        q = None
        for k in range(p + 14, p + 14 + 64):
            if at(k) == 0xD5 and at(k + 1) == 0xAA and at(k + 2) == 0xAD:
                q = k
                break
        if q is None:
            errors.append(f'T{track} S{sec}: no data field')
            continue
        data, why = decode62_indep([at(q + 3 + k) for k in range(343)])
        if data is None:
            errors.append(f'T{track} S{sec}: {why}')
            continue
        if [at(q + 346 + k) for k in range(3)] != [0xDE, 0xAA, 0xEB]:
            errors.append(f'T{track} S{sec}: data epilogue')
        if sec in found:
            errors.append(f'T{track} S{sec}: twice')
        found[sec] = data
        if sec == 0:
            s0_pos = p
    out = bytearray(TRACK_SECTOR_BYTES)
    for s in range(SECTORS):
        if s not in found:
            errors.append(f'T{track} S{s}: missing')
            continue
        log = SECTOR_NUMBER[order][s]
        out[log << 8:(log << 8) + 256] = found[s]
    return bytes(out), errors, s0_pos


def verify(path):
    data = open(path, 'rb').read()
    kind, order, tracks = classify(path, data)
    allb, npt, tr = nibblize_image(path)
    errors = []
    if len(allb) != tracks * TRACK_BYTES:
        errors.append('wrong total length')
    for t in range(tracks):
        slot = allb[t * TRACK_BYTES:(t + 1) * TRACK_BYTES]
        if any(b != 0xFF for b in slot[npt:]):
            errors.append(f'T{t}: pad not $FF')
    if kind == 'nib':
        if allb != data[:tracks * NIB_NIBBLES]:
            errors.append('.nib passthrough differs from the file')
        return errors, kind, order, tracks, npt
    rebuilt = bytearray()
    for t in range(tracks):
        slot = allb[t * TRACK_BYTES:(t + 1) * TRACK_BYTES]
        sec, errs, s0 = verify_track(slot, npt, t, order)
        errors += errs
        # Where the skew put physical sector 0: gap 1 moved left 768t.
        want = (GAP1 - SKEW_PER_TRACK * t) % npt
        if s0 is not None and s0 != want:
            errors.append(f'T{t}: sector 0 at {s0}, skew says {want}')
        rebuilt += sec
    n = min(len(data), len(rebuilt))
    if bytes(rebuilt[:n]) != data[:n]:
        first = next(i for i in range(n) if rebuilt[i] != data[i])
        errors.append(f'image differs from the file, first at ${first:05x}')
    if len(rebuilt) != len(data):
        errors.append(f'compared {n} bytes: rebuilt {len(rebuilt)}, file {len(data)}')
    return errors, kind, order, tracks, npt


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith('-'):
        sys.exit(__doc__)
    path = args[0]
    hexout = None
    countsout = None
    as_bits = False
    do_verify = False
    i = 1
    while i < len(args):
        if args[i] == '--hex':
            hexout = args[i + 1]; i += 2
        elif args[i] == '--info':
            i += 1
        elif args[i] == '--verify':
            do_verify = True; i += 1
        elif args[i] == '--bits':
            as_bits = True; i += 1
        elif args[i] == '--counts':
            countsout = args[i + 1]; i += 2
        else:
            sys.exit('unknown option ' + args[i])
    data = open(path, 'rb').read()
    try:
        kind, order, tracks = classify(path, data)
    except ValueError as e:
        sys.exit(str(e))
    npt = NIB_NIBBLES if kind == 'nib' else NIBBLES_PER_TRACK
    print(f'{path}: type {kind}, order {ORDER_NAMES.get(order, "n/a")}, '
          f'tracks {tracks}, nibbles per track {npt}, slot {TRACK_BYTES}')
    if do_verify:
        errors, *_ = verify(path)
        for e in errors[:20]:
            print('  ' + e)
        print('verify: ' + ('PASS' if not errors else f'FAIL ({len(errors)} errors)'))
        if errors:
            sys.exit(1)
    if hexout and as_bits:
        allb, npt, tracks = nibblize_image(path)
        counts = []
        with open(hexout, 'w') as f:
            for t in range(tracks):
                bb, k = bits_from_nibbles(list(allb[t * TRACK_BYTES:t * TRACK_BYTES + npt]))
                counts.append(k)
                f.write(''.join('%02x\n' % b for b in bb))
        if countsout:
            with open(countsout, 'w') as f:
                f.write(''.join('%d\n' % k for k in counts))
        print(f'wrote {hexout}: {tracks} tracks x {TRACK_BYTES} as bits, {counts[0]} bits a track')
    elif hexout:
        allb, npt, tracks = nibblize_image(path)
        with open(hexout, 'w') as f:
            f.write(''.join('%02x\n' % b for b in allb))
        print(f'wrote {hexout}: {tracks} tracks x {TRACK_BYTES}')


if __name__ == '__main__':
    main()
