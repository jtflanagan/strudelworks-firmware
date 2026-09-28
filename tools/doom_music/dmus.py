# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""dmus - what tools/doom_music's builder and preview share (docs/RVV2_DOOM.md
MU3): the WAD's lumps, GENMIDI's instruments, MUS parsed into events, DMX's
volume law (Chocolate Doom's i_oplmusic.c SetVoiceVolume), and the instrument
tables file, DOOMMUS.INS.

DOOMMUS.INS, little-endian, everything at its natural alignment - one entry
for each OPL voice DMX plays (an instrument's voice 0, and voice 1 of a
double-voice one), at each note it is played at:

  header, 32 bytes
     0 char[4]  "DMUS"
     4 u16      version (2)
     6 u16      tick_hz: the envelopes' step (MUS's own tic, 140)
     8 u16      n, 10 u16 0
    12 u32      the file's size
    16 u32[4]   0
  n entries, 48 bytes each, sorted by (ins, voice, ref):
     0 u8  ins     GENMIDI's index: 0-127 melodic, 128 + key - 35 percussion
     1 u8  ref     the MIDI note (percussion: the key) captured
     2 u8  voice   0, or 1: a double-voice instrument's second
     3 u8  flags   bit 0: fixed pitch (the instrument's one ref, never moved);
                   bit 1: one-shot (no loop - the percussion)
     4 u32 f0      the loop's pitch at ref, Hz in 16.16
     8 u32 arate   the attack's (a one-shot's) bytes a second at ref, 16.16
    12 u32 a_ofs  16 u32 a_size   the attack: a one-shot of int8 samples
    20 u32 l_ofs  24 u32 l_size   the loop: one cycle of int8 samples (0: none)
    28 u32 e_ofs   u16s: n_hold loop amplitudes, one a tick from the note-on,
                   then n_rel release factors (0.16), one a tick from the note-off
    32 u16 n_hold 34 u16 n_rel
    36 u16 a_amp   the attack's amplitude
    38 u16 decay   0.16: a tick's factor on the loop's amplitude past n_hold
    40 u8  reach   the semitones above ref it is band-limited for
    41 u8[7] 0
  the data: int8 tables, u16 envelopes

Amplitudes (hold, a_amp) share one scale: 65535 is the loudest anything in the
file reaches at full volume; a sample's contribution is
(int8 / 127) * amplitude * the volume law's gain.
"""
import struct
import numpy as np

TICK_HZ = 140

def read_wad(path):
    wad = open(path, "rb").read()
    n, d = struct.unpack_from("<ii", wad, 4)
    lumps = {}
    for i in range(n):
        p, s, nm = struct.unpack_from("<ii8s", wad, d + 16 * i)
        lumps.setdefault(nm.rstrip(b"\0").decode("latin1"), wad[p:p + s])
    return lumps

def genmidi(lumps):
    """GENMIDI's 175 instruments (128 melodic, then 47 percussion for keys 35-81)."""
    gm = lumps["GENMIDI"]
    assert gm[:8] == b"#OPL_II#"
    out = []
    for i in range(175):
        b = gm[8 + 36 * i: 8 + 36 * (i + 1)]
        flags, fine, fixed = struct.unpack_from("<HBB", b, 0)
        off0 = struct.unpack_from("<h", b, 4 + 14)[0]
        name = gm[8 + 36 * 175 + 32 * i: 8 + 36 * 175 + 32 * (i + 1)].split(b"\0")[0].decode("latin1").strip()
        out.append(dict(flags=flags, fine=fine, fixed=fixed, off0=off0, name=name))
    return out

def songs(lumps):
    return sorted(k for k, v in lumps.items() if v[:4] == b"MUS\x1a")

def parse_mus(mus):
    """[(tic, kind, ch, x, y)], and the song's length in tics.  Kinds: on (note,
    volume), off (note), bend (0-255, 128 the middle), ctrl (number, value),
    sys (number), end.  MUS's channel 15 is percussion."""
    assert mus[:4] == b"MUS\x1a"
    slen, sstart = struct.unpack_from("<HH", mus, 4)
    score = mus[sstart:sstart + slen]
    ev, t, i = [], 0, 0
    last_vol = [127] * 16
    while i < len(score):
        d = score[i]; i += 1
        last, kind, ch = d & 0x80, (d >> 4) & 7, d & 15
        if kind == 0: ev.append((t, "off", ch, score[i] & 127, 0)); i += 1
        elif kind == 1:
            n = score[i]; i += 1
            if n & 0x80: last_vol[ch] = score[i] & 127; i += 1
            ev.append((t, "on", ch, n & 127, last_vol[ch]))
        elif kind == 2: ev.append((t, "bend", ch, score[i], 0)); i += 1
        elif kind == 3: ev.append((t, "sys", ch, score[i], 0)); i += 1
        elif kind == 4: ev.append((t, "ctrl", ch, score[i], score[i + 1])); i += 2
        elif kind == 5: pass
        elif kind == 6: ev.append((t, "end", ch, 0, 0)); break
        else: raise ValueError("MUS event type 7")
        if last:
            dl = 0
            while True:
                c = score[i]; i += 1; dl = dl * 128 + (c & 127)
                if not c & 0x80: break
            t += dl
    return ev, t

def midi_channels(events):
    """mus2mid's MUS -> MIDI channel map: percussion (15) is 9, the others take
    0, 1, ... (skipping 9) in the order they first appear - which is DMX's
    priority (ReplaceExistingVoice: a higher MIDI channel is discarded first)."""
    cmap, nxt = {15: 9}, 0
    for t, k, ch, x, y in events:
        if ch not in cmap:
            cmap[ch] = nxt; nxt += 1
            if nxt == 9: nxt += 1
    return cmap

def usage(events, instr):
    """What a song plays: {(ins, voice): {notes}} - percussion as its key."""
    prog, out = [0] * 16, {}
    for t, k, ch, x, y in events:
        if k == "ctrl" and x == 0: prog[ch] = y
        if k == "on" and y > 0:
            if ch == 15:
                if not 35 <= x <= 81: continue
                ins = 128 + x - 35
            else: ins = prog[ch]
            for v in ((0, 1) if instr[ins]["flags"] & 4 else (0,)):
                out.setdefault((ins, v), set()).add(x)
    return out

# DMX's volume: i_oplmusic.c's volume_mapping_table and SetVoiceVolume - the
# carrier's level register gets 0x3f - full_volume, 0.75 dB a step.
VMT = [0, 1, 3, 5, 6, 8, 10, 11, 13, 14, 16, 17, 19, 20, 22, 23, 25, 26, 27, 29, 30, 32, 33, 34, 36, 37, 39, 41, 43, 45, 47, 49,
       50, 52, 54, 55, 57, 59, 60, 61, 63, 64, 66, 67, 68, 69, 71, 72, 73, 74, 75, 76, 77, 79, 80, 81, 82, 83, 84, 84, 85, 86, 87, 88,
       89, 90, 91, 92, 92, 93, 94, 95, 96, 96, 97, 98, 99, 99, 100, 101, 101, 102, 103, 103, 104, 105, 105, 106, 107, 107, 108, 109, 109, 110, 110, 111,
       112, 112, 113, 113, 114, 114, 115, 115, 116, 117, 117, 118, 118, 119, 119, 120, 120, 121, 121, 122, 122, 123, 123, 123, 124, 124, 125, 125, 126, 126, 127, 127]

def full_volume(vel, chvol, musvol):
    return (VMT[vel] * 2 * (VMT[(chvol * musvol) // 127] + 1)) >> 9

FULL_CAPTURE = full_volume(127, 127, 127)          # what the tables were captured at

def gain(vel, chvol, musvol):
    """The amplitude, against the capture's, of a note at (velocity, channel volume, music volume)."""
    return 10 ** (-0.75 * (FULL_CAPTURE - full_volume(vel, chvol, musvol)) / 20)

# ---- DOOMMUS.INS -------------------------------------------------------------------
HDR, ENT = "<4sHHHHI16x", "<BBBBIIIIIIIHHHHB7x"
assert struct.calcsize(HDR) == 32 and struct.calcsize(ENT) == 48

def write_ins(path, ents):
    """ents: dicts (ins ref voice flags f0 arate atab ltab hold rel a_amp decay
    reach); tables int8 arrays (ltab empty for a one-shot), envelopes u16 arrays."""
    ents = sorted(ents, key=lambda e: (e["ins"], e["voice"], e["ref"]))
    data = bytearray()
    def put(arr, align):
        while len(data) % align: data.append(0)
        at = len(data); data.extend(arr.tobytes()); return at
    base = 32 + 48 * len(ents)
    table = b""
    for e in ents:
        a = put(e["atab"].astype(np.int8), 4)
        l = put(e["ltab"].astype(np.int8), 4) if len(e["ltab"]) else 0
        v = put(np.concatenate([e["hold"], e["rel"]]).astype("<u2"), 4)
        table += struct.pack(ENT, e["ins"], e["ref"], e["voice"], e["flags"], int(round(e["f0"] * 65536)),
                             int(round(e["arate"] * 65536)), base + a, len(e["atab"]), base + l if len(e["ltab"]) else 0,
                             len(e["ltab"]), base + v, len(e["hold"]), len(e["rel"]), e["a_amp"], e["decay"], e["reach"])
    while len(data) % 4: data.append(0)
    body = struct.pack(HDR, b"DMUS", 2, TICK_HZ, len(ents), 0, base + len(data)) + table + bytes(data)
    open(path, "wb").write(body)
    return len(body)

def read_ins(path):
    """{(ins, voice): {ref: entry}}, tables as floats (-1..1), envelopes as floats."""
    b = open(path, "rb").read()
    magic, ver, tick, n, _, size = struct.unpack_from(HDR, b, 0)
    assert magic == b"DMUS" and ver == 2 and size == len(b), "not a DOOMMUS.INS v2"
    out = {}
    for i in range(n):
        ins, ref, voice, flags, f0, arate, ao, asz, lo, lsz, eo, nh, nr, aamp, decay, reach = struct.unpack_from(ENT, b, 32 + 48 * i)
        env = np.frombuffer(b, "<u2", nh + nr, eo).astype(np.float64)
        out.setdefault((ins, voice), {})[ref] = dict(
            ins=ins, ref=ref, voice=voice, fixed=bool(flags & 1), oneshot=bool(flags & 2), f0=f0 / 65536, arate=arate / 65536,
            atab=np.frombuffer(b, np.int8, asz, ao).astype(np.float64) / 127,
            ltab=np.frombuffer(b, np.int8, lsz, lo).astype(np.float64) / 127 if lsz else np.zeros(0),
            hold=env[:nh], rel=env[nh:] / 65535, a_amp=float(aamp), decay=decay / 65536, reach=reach)
    return tick, out
