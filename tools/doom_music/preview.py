#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""preview - a DOOM song played from DOOMMUS.INS the way the engine's wavetable
music will play it (docs/RVV2_DOOM.md MU3), to a WAV, for the ear.  The MUS
sequenced at its 140 Hz tic; DMX's nine OPL voices allocated as Chocolate
Doom's player does (i_oplmusic.c, opl_v_new): a free list taken from its head
and given back at its tail, a double-voice instrument's second voice only if
one is free, and when none is, ReplaceExistingVoice's victim - a second voice,
else the last on the highest MIDI channel (mus2mid's order); a released voice
sounds on - its volume and bend as they were - until it is taken again.  Each
voice plays its table entry (the note's own, else the nearest) with linear
interpolation - the attack, then the loop in phase - its amplitude ramped every
sample between the tics' envelope points; the voices summed into one stream at
RATE and cut to 8 bits as the DOC gets it (the song's peak at 120 of 127 unless
--gain).

  tools/doom_music/preview.py WAD DOOMMUS.INS SONG OUT.wav [--seconds 45]
      [--rate 26320] [--musvol 64] [--gain G] [--wide]
    --wide: the stream before the 8-bit cut, at 16 bits
"""
import argparse, os, sys, wave
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dmus

ap = argparse.ArgumentParser()
ap.add_argument("wad"); ap.add_argument("ins"); ap.add_argument("song"); ap.add_argument("out")
ap.add_argument("--seconds", type=float, default=45); ap.add_argument("--rate", type=float, default=26320)
ap.add_argument("--musvol", type=int, default=64)
ap.add_argument("--gain", type=float, default=0); ap.add_argument("--wide", action="store_true")
a = ap.parse_args()

lumps = dmus.read_wad(a.wad)
INSTR = dmus.genmidi(lumps)
tick_hz, TABLES = dmus.read_ins(a.ins)
events, song_tics = dmus.parse_mus(lumps[a.song])
MIDICH = dmus.midi_channels(events)
NVOICES = 9                                                   # an OPL2's, as DMX has them

def entry_for(ins, voice, note):
    """The voice's entry at the note (percussion: the key), else the nearest (a tie: the higher, moved down)."""
    have = TABLES.get((ins, voice))
    if not have: return None
    return have[min(have, key=lambda r: (abs(r - note), -r))]

class Voice:
    def __init__(s): s.sounding = False; s.t_on = s.t_off = -1

voices = [Voice() for _ in range(NVOICES)]
free, alloced = list(voices), []                              # DMX's two lists
chan_vol, chan_bend, prog = [127] * 16, [0] * 16, [0] * 16
missing, steals = set(), 0

def key_off(v, now):                                          # VoiceKeyOff + ReleaseVoice: the release runs on
    v.t_off, v.chvol, v.bend = now, chan_vol[v.ch], chan_bend[v.ch]
    alloced.remove(v); free.append(v)

def voice_key_on(ch, ins, voice, key, vel, now):
    if not free: return
    e = entry_for(ins, voice, key)
    if e is None: missing.add((ins, voice)); return
    v = free.pop(0); alloced.append(v)
    v.ch, v.key, v.vel, v.e, v.voice = ch, key, vel, e, voice
    v.t_on, v.t_off, v.sounding, v.pos, v.in_loop = now, -1, True, 0.0, False

def key_on(ch, key, vel, now):
    global steals
    if ch == 15:
        if not 35 <= key <= 81: return
        ins = 128 + key - 35
    else: ins = prog[ch]
    if not free:                                              # ReplaceExistingVoice
        r = alloced[0]
        for q in alloced:
            if q.voice != 0 or MIDICH[q.ch] >= MIDICH[r.ch]: r = q
        key_off(r, now); steals += 1
    voice_key_on(ch, ins, 0, key, vel, now)
    if INSTR[ins]["flags"] & 4: voice_key_on(ch, ins, 1, key, vel, now)

def level(v, now):
    """The voice's amplitudes at tic `now`: (attack's or one-shot's, loop's)."""
    held = v.t_off < 0
    g = dmus.gain(v.vel, chan_vol[v.ch] if held else v.chvol, a.musvol)
    e = v.e
    rel = 1.0
    if not held:
        i = now - v.t_off
        rel = e["rel"][i] if i < len(e["rel"]) else 0.0
    if e["oneshot"]: return (g * e["a_amp"] * rel, 0.0)
    i = (now if held else v.t_off) - v.t_on
    h = e["hold"]
    hold = h[i] if i < len(h) else h[-1] * e["decay"] ** (i - len(h) + 1)
    return (g * e["a_amp"] * rel, g * hold * rel)

def interp(tab, p, wrap):
    i = np.floor(p).astype(np.int64); f = p - i
    j = (i + 1) % len(tab) if wrap else np.minimum(i + 1, len(tab) - 1)
    return tab[i % len(tab) if wrap else i] * (1 - f) + tab[j] * f

out, ev_i, loop_base, acc = [], 0, 0, 0.0
for now in range(int(a.seconds * tick_hz)):
    while True:                                               # this tic's events
        if ev_i >= len(events): ev_i, loop_base = 0, loop_base + song_tics
        t, k, ch, x, y = events[ev_i]
        if t + loop_base > now: break
        ev_i += 1
        if k == "end": ev_i, loop_base = 0, loop_base + t; continue
        if k == "on" and y > 0: key_on(ch, x, y, now)
        elif k in ("on", "off"):                              # KeyOffEvent: every voice on this key
            for v in [v for v in alloced if v.ch == ch and v.key == x]: key_off(v, now)
        elif k == "bend": chan_bend[ch] = x // 2 - 64
        elif k == "ctrl":
            if x == 0: prog[ch] = y
            elif x == 3: chan_vol[ch] = y
        elif k == "sys" and x == 11:                          # all notes off (MIDI 123; 120 is ignored)
            for v in [v for v in alloced if v.ch == ch]: key_off(v, now)
    n = int(acc + a.rate / tick_hz) - int(acc); acc += a.rate / tick_hz
    mix, fr = np.zeros(n), np.arange(n) / n
    for v in voices:
        if not v.sounding: continue
        l0, l1 = level(v, now), level(v, now + 1)
        if v.t_off >= 0 and max(l0) == 0: v.sounding = False; continue
        ramp = [p + (q - p) * fr for p, q in zip(l0, l1)]
        e = v.e
        if e["oneshot"]:
            st = e["arate"] / a.rate
            p = v.pos + st * np.arange(n); v.pos = p[-1] + st
            live = int(np.searchsorted(p, len(e["atab"]) - 1))
            mix[:live] += interp(e["atab"], p[:live], False) * ramp[0][:live]
            continue
        bend = chan_bend[v.ch] if v.t_off < 0 else v.bend
        r = 2.0 ** ((0.0 if e["fixed"] else (v.key - e["ref"]) + bend / 32.0) / 12)
        sa, sl = e["arate"] * r / a.rate, e["f0"] * r * len(e["ltab"]) / a.rate
        start = 0
        if not v.in_loop:
            p = v.pos + sa * np.arange(n)
            na = int(np.searchsorted(p, len(e["atab"]) - 1))
            mix[:na] += interp(e["atab"], p[:na], False) * ramp[0][:na]
            if na == n: v.pos = p[-1] + sa; continue
            v.in_loop, v.pos, start = True, (p[na] - (len(e["atab"]) - 1)) / sa * sl, na   # the loop starts in phase
        q = v.pos + sl * np.arange(n - start); v.pos = (q[-1] + sl) % len(e["ltab"])
        mix[start:] += interp(e["ltab"], q, True) * ramp[1][start:]
    out.append(mix)

y = np.concatenate(out)
g = a.gain or 120 / (np.abs(y).max() + 1e-9)
y8 = np.clip(np.round(y * g), -127, 127)
with wave.open(a.out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(int(round(a.rate)))
    w.writeframes(np.clip(np.round((y * g if a.wide else y8) * 256), -32768, 32767).astype(np.int16).tobytes())
print(f"{a.song}: {len(y) / a.rate:.1f} s at {a.rate:.0f} Hz, gain {g:.6f} (peak {np.abs(y).max() * g:.0f} of 127)"
      + f"; {steals} voices taken" + (f"; not in the tables: {sorted(missing)}" if missing else ""))
