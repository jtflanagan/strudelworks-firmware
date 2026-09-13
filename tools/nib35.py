#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""A 3.5" 800K ProDOS-order image, nibblized track by track the way KEGS does it.

A PORT OF KEGS 1.38's iwm_nibblize_track_35 (src/iwm.c), which is GPL-2.0 and
Kent Dickey's; the zone table, the interleave, the sync counts, the address and
data fields and the three-way checksum are its, line for line, so that a track
this makes is the track KEGS makes and the IIgs ROM reads.  This is the
behavioural source for the host's nibblizer (strudelworks-host
src/fd35_nibble.cpp) and the maker of the bench's track images
(sim/run_boot_gs_tb.sh --fd35=IMAGE).  docs/IWM35.md.

THE TRACK IS A NIBBLE STREAM HERE, NOT A BIT STREAM.  KEGS packs each track
into `track_bits` bits and writes its sync bytes as ten-bit $FF (eight ones,
two zeros); the card's drive turns a nibble at a time, a slot per nibble, and a
sync slot is an $FF like any other - the two zero bits only ever mattered to
the timing of a bit-level reader, and the IWM's own data register hides them.
So a track is a list of bytes, 12 sectors' worth in zone 0, and the count is
what the drive turns over: `track_nibbles(t)` says how many.

    tools/nib35.py IMAGE.po --hex OUT.hex [--stride N] [--counts OUT.txt]
    tools/nib35.py IMAGE.po --check           # decode every sector back

The hex file is 160 tracks (track*2 + side, KEGS's qtr_track order) at a fixed
stride of N nibbles each (default 10240, the card's buffer), one byte a line
for $readmemh; the counts file is one line per track, the nibbles in it.
"""
import sys

# KEGS iwm.c: bits per track by zone (394-590 rpm at 2 us a bit) and the
# sectors per track that go with them.  The bit counts are what KEGS's
# bit-level track holds; this stream has no use for them beyond the report.
TRACK_BITS_35  = [77779, 71433, 64926, 58371, 51940]
SECTORS_35     = [12, 11, 10, 9, 8]
TRACK_BYTES_35 = [s * 512 for s in SECTORS_35]

TO_DISK_BYTE = [
    0x96, 0x97, 0x9a, 0x9b, 0x9d, 0x9e, 0x9f, 0xa6, 0xa7, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb2, 0xb3,
    0xb4, 0xb5, 0xb6, 0xb7, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xcb, 0xcd, 0xce, 0xcf, 0xd3,
    0xd6, 0xd7, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe5, 0xe6, 0xe7, 0xe9, 0xea, 0xeb, 0xec,
    0xed, 0xee, 0xef, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
]
FROM_DISK_BYTE = {v: i for i, v in enumerate(TO_DISK_BYTE)}

SYNC_FIRST = 400      # sync nibbles before physical sector 0
SYNC_OTHER = 54       # ...and before every other sector
SYNC_INTER = 5        # between the address field and the data field
STRIDE_DEFAULT = 10240


def zone(track):
    return track >> 4


def track_nibbles(track):
    """Nibbles in a track of this zone: what nibblize_track returns."""
    n = SECTORS_35[zone(track)]
    return SYNC_FIRST + (n - 1) * SYNC_OTHER + n * (3 + 5 + 2 + SYNC_INTER + 3 + 1 + 699 + 4 + 3)


def interleave(num_sectors):
    """Physical slot -> logical sector, KEGS's 2:1 walk."""
    phys_to_log = [-1] * num_sectors
    phys = 0
    for log in range(num_sectors):
        while phys_to_log[phys] >= 0:
            phys += 1
            if phys >= num_sectors:
                phys = 0
        phys_to_log[phys] = log
        phys += 2
        if phys >= num_sectors:
            phys -= num_sectors
    return phys_to_log


def encode_sector(buf):
    """The 524-byte sector (12 tag + 512 data) as KEGS nibblizes 512 data bytes
    with a zero tag: 699 data nibbles and the four checksum nibbles."""
    out = []
    buf_c00 = [0] * 0x100
    buf_d00 = [0] * 0x100
    buf_e00 = [0] * 0x100
    tmp_5e = tmp_5d = tmp_5c = 0
    y = 0
    x = 0xAF
    for _ in range(4):
        buf_c00[x] = 0; buf_d00[x] = 0; buf_e00[x] = 0
        x -= 1
    # KEGS feeds `buf` = the 512 data bytes; buf[y] for y up to 0x1FF.  The
    # 12 tag bytes a real sector carries are the ZEROS the four cleared slots
    # above stand for.
    while x >= 0:
        tmp_5c = tmp_5c << 1
        carry = tmp_5c >> 8
        tmp_5c = (tmp_5c + carry) & 0xFF
        val = buf[y]
        tmp_5e = val + tmp_5e + carry
        carry = tmp_5e >> 8
        tmp_5e &= 0xFF
        val ^= tmp_5c
        buf_c00[x] = val
        y += 1
        val = buf[y]
        tmp_5d = tmp_5d + val + carry
        carry = tmp_5d >> 8
        tmp_5d &= 0xFF
        val ^= tmp_5e
        buf_d00[x] = val
        y += 1
        x -= 1
        if x <= 0:
            break
        val = buf[y]
        tmp_5c = tmp_5c + val + carry
        carry = tmp_5c >> 8
        tmp_5c &= 0xFF
        val ^= tmp_5d
        buf_e00[x + 1] = val
        y += 1
    val = ((tmp_5c >> 2) ^ tmp_5d) & 0x3F
    val = (val ^ tmp_5d) >> 2
    val = (val ^ tmp_5e) & 0x3F
    val = (val ^ tmp_5e) >> 2
    tmp_5f = val
    tmp_63 = tmp_64 = tmp_65 = 0
    acc_hi = 0
    y = 0xAE
    while y >= 0:
        out.append(TO_DISK_BYTE[acc_hi & 0x3F])
        val = TO_DISK_BYTE[tmp_63 & 0x3F]
        tmp_63 = buf_c00[y]
        acc_hi = tmp_63 >> 6
        out.append(val)
        val = TO_DISK_BYTE[tmp_64 & 0x3F]
        tmp_64 = buf_d00[y]
        acc_hi = (acc_hi << 2) + (tmp_64 >> 6)
        out.append(val)
        y -= 1
        if y < 0:
            break
        val = TO_DISK_BYTE[tmp_65 & 0x3F]
        tmp_65 = buf_e00[y + 1]
        acc_hi = (acc_hi << 2) + (tmp_65 >> 6)
        out.append(val)
    out.append(TO_DISK_BYTE[tmp_5f & 0x3F])
    out.append(TO_DISK_BYTE[tmp_5e & 0x3F])
    out.append(TO_DISK_BYTE[tmp_5d & 0x3F])
    out.append(TO_DISK_BYTE[tmp_5c & 0x3F])
    return out


def nibblize_track(track_buf, qtr_track):
    """The bytes of one track (SECTORS_35[zone] * 512 of them, logical
    order) to its nibbles.  qtr_track = track * 2 + side."""
    track = qtr_track >> 1
    side = qtr_track & 1
    num_sectors = len(track_buf) >> 9
    phys_to_log = interleave(num_sectors)
    out = []
    for phys_sec in range(num_sectors):
        log_sec = phys_to_log[phys_sec]
        out.extend([0xFF] * (SYNC_FIRST if phys_sec == 0 else SYNC_OTHER))
        out.extend([0xD5, 0xAA, 0x96])
        phys_track = track & 0x3F
        phys_side = (side << 5) + (track >> 6)
        capacity = 0x22
        out.append(TO_DISK_BYTE[phys_track])
        out.append(TO_DISK_BYTE[log_sec])
        out.append(TO_DISK_BYTE[phys_side])
        out.append(TO_DISK_BYTE[capacity])
        cksum = (phys_track ^ log_sec ^ phys_side ^ capacity) & 0x3F
        out.append(TO_DISK_BYTE[cksum])
        out.extend([0xDE, 0xAA])
        out.extend([0xFF] * SYNC_INTER)
        out.extend([0xD5, 0xAA, 0xAD])
        out.append(TO_DISK_BYTE[log_sec])
        out.extend(encode_sector(track_buf[log_sec << 9:(log_sec + 1) << 9]))
        out.extend([0xDE, 0xAA, 0xFF])
    assert len(out) == track_nibbles(track), (len(out), track_nibbles(track))
    return out


def image_tracks(image):
    """The 160 tracks of an 800K image: (qtr_track, bytes), in file order -
    KEGS lays the file out track 0 side 0, track 0 side 1, track 1 side 0..."""
    pos = 0
    for q in range(160):
        n = TRACK_BYTES_35[zone(q >> 1)]
        buf = image[pos:pos + n]
        if len(buf) < n:
            buf = buf + bytes(n - len(buf))
        yield q, buf
        pos += n


# ---- the reverse, for --check: a reader as the IIgs ROM is one ---------------
def decode_sector_replay(nibs):
    """Decode by replaying KEGS's encoder register game exactly: the stream is
    the encoder's outputs in order, so read them back in that order."""
    vals = [FROM_DISK_BYTE.get(n, -1) for n in nibs]
    if -1 in vals or len(vals) < 703:
        return None
    buf_c00 = [0] * 0x100; buf_d00 = [0] * 0x100; buf_e00 = [0] * 0x101
    i = 0
    y = 0xAE
    # Encoder per group at y: out(acc_hi_prev), out(tmp_63_prev), tmp_63=c[y],
    # out(tmp_64_prev), tmp_64=d[y], [out(tmp_65_prev), tmp_65=e[y+1]].
    # So the values written at group y are the LOW bits of c/d/e captured in
    # group y+1, and acc_hi written at group y is the HIGH bits of those same
    # captured values (c[y+1] bits 7:6, d[y+1] 7:6, e[y+2] 7:6).
    pend = None    # (y+1) whose low bits arrive this group
    while y >= 0:
        hi = vals[i]; lo_c = vals[i + 1]; lo_d = vals[i + 2]; i += 3
        if pend is not None:
            buf_c00[pend] = lo_c | (((hi >> 4) & 3) << 6)
            buf_d00[pend] = lo_d | (((hi >> 2) & 3) << 6)
        yy = y
        y -= 1
        if y < 0:
            break
        lo_e = vals[i]; i += 1
        if pend is not None:
            buf_e00[pend] = lo_e | ((hi & 3) << 6)
        pend = yy
    # Group y carries the low six bits of c[y+1], d[y+1], e[y+1] and the
    # high two of each in its first nibble; the last group (y = 0) has no e
    # nibble, e[1] being one of the encoder's cleared slots.  Then the four
    # checksum nibbles: tmp_5f (the checksums' high bits), 5e, 5d, 5c.
    tmp_5f, tmp_5e, tmp_5d, tmp_5c = vals[i], vals[i + 1], vals[i + 2], vals[i + 3]
    # Undo the encoder's whitening: replay the forward pass to regenerate
    # the tmp_ registers from decoded bytes.
    out = bytearray(512)
    t5e = t5d = t5c = 0
    yb = 0
    x = 0xAF - 4
    # The encoder cleared c/d/e at x = 0xAF..0xAC and started data at x = 0xAB.
    while x >= 0:
        t5c = t5c << 1
        carry = t5c >> 8
        t5c = (t5c + carry) & 0xFF
        val = buf_c00[x] ^ t5c
        out[yb] = val; yb += 1
        t5e = val + t5e + carry
        carry = t5e >> 8
        t5e &= 0xFF
        val = buf_d00[x] ^ t5e
        out[yb] = val; yb += 1
        t5d = t5d + val + carry
        carry = t5d >> 8
        t5d &= 0xFF
        x -= 1
        if x <= 0:
            break
        val = buf_e00[x + 1] ^ t5d
        out[yb] = val; yb += 1
        t5c = t5c + val + carry
        carry = t5c >> 8
        t5c &= 0xFF
    # Checksum as the encoder computes it.
    v = ((t5c >> 2) ^ t5d) & 0x3F
    v = (v ^ t5d) >> 2
    v = (v ^ t5e) & 0x3F
    v = (v ^ t5e) >> 2
    if (v & 0x3F) != tmp_5f or (t5e & 0x3F) != tmp_5e or (t5d & 0x3F) != tmp_5d or (t5c & 0x3F) != tmp_5c:
        return None
    return bytes(out), yb


def check_image(image):
    bad = 0
    total = 0
    for q, buf in image_tracks(image):
        nibs = nibblize_track(buf, q)
        # Walk the address fields and decode each data field.
        i = 0
        found = 0
        n = len(nibs)
        while i < n - 3:
            if nibs[i] == 0xD5 and nibs[i + 1] == 0xAA and nibs[i + 2] == 0x96:
                trk = FROM_DISK_BYTE[nibs[i + 3]]; sec = FROM_DISK_BYTE[nibs[i + 4]]
                # The side byte carries the side in bit 5 and bit 6 of the
                # track in bit 0: tracks 64-79 write their number modulo 64.
                sb = FROM_DISK_BYTE[nibs[i + 5]]
                side = sb >> 5
                trk = trk | ((sb & 1) << 6)
                j = i + 10
                while not (nibs[j] == 0xD5 and nibs[j + 1] == 0xAA and nibs[j + 2] == 0xAD):
                    j += 1
                sec2 = FROM_DISK_BYTE[nibs[j + 3]]
                r = decode_sector_replay(nibs[j + 4:j + 4 + 703])
                total += 1
                if r is None or sec2 != sec or trk != (q >> 1) or side != (q & 1):
                    bad += 1
                else:
                    data, nbytes = r
                    if data != buf[sec << 9:(sec + 1) << 9]:
                        bad += 1
                found += 1
                i = j + 4
            else:
                i += 1
        if found != len(buf) >> 9:
            print(f'track {q>>1}.{q&1}: {found} sectors found, {len(buf)>>9} expected')
            bad += 1
    return total, bad


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    path = args[0]
    hexout = counts = None
    stride = STRIDE_DEFAULT
    check = False
    i = 1
    while i < len(args):
        if args[i] == '--hex':
            hexout = args[i + 1]; i += 2
        elif args[i] == '--counts':
            counts = args[i + 1]; i += 2
        elif args[i] == '--stride':
            stride = int(args[i + 1]); i += 2
        elif args[i] == '--check':
            check = True; i += 1
        else:
            sys.exit('unknown option ' + args[i])
    image = open(path, 'rb').read()
    if len(image) != 800 * 1024:
        print(f'warning: {path} is {len(image)} bytes, not 800K', file=sys.stderr)
    print('nibbles per track by zone:', [track_nibbles(z * 16) for z in range(5)],
          'max', max(track_nibbles(t) for t in range(80)), 'stride', stride)
    if check:
        total, bad = check_image(image)
        print(f'check: {total} sectors decoded, {bad} bad')
        sys.exit(1 if bad else 0)
    if hexout:
        with open(hexout, 'w') as f, (open(counts, 'w') if counts else open('/dev/null', 'w')) as cf:
            for q, buf in image_tracks(image):
                nibs = nibblize_track(buf, q)
                assert len(nibs) <= stride
                nibs = nibs + [0xFF] * (stride - len(nibs))
                f.write(''.join('%02x\n' % v for v in nibs))
                cf.write('%d\n' % track_nibbles(q >> 1))
        print(f'wrote {hexout}: 160 tracks x {stride}')


if __name__ == '__main__':
    main()
