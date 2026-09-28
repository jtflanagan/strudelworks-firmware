#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""instruments - DOOM's instruments sampled for the engine's wavetable music
(docs/RVV2_DOOM.md MU3): every OPL voice DMX plays - each GENMIDI instrument's
voice 0, and voice 1 of a double-voice one - at every note the WAD's songs
play it, captured through the port's own OPL path (render_opl: Chocolate
Doom's player, opl_rv.c, dbopl_rv.c at 52640 Hz) one note at a time with the
other voice muted, and turned into tables - written as DOOMMUS.INS
(tools/doom_music/dmus.py has the layout).  Each note captured at its own
pitch, so only a pitch bend moves a table.  Nothing made from the WAD goes
into git.

  melodic: an ATTACK one-shot - the first ~100 ms, a whole number of
    periods, resampled to fill 2048 bytes - that runs into a LOOP, one cycle
    resynthesised from the harmonics just after the attack; both band-limited
    so the highest note the entry serves (its reach: a whole-tone bend) stays
    under 11 kHz; the loop's amplitude a tick at a time through an 8 s hold,
    kept only until one decay carries the rest within 0.5 dB; the release a
    tick at a time from the note-off, to -60 dB
  percussion: a one-shot at 13160 Hz to -45 dB (at most 8192 bytes, faded when
    cut), and the release

  tools/doom_music/instruments.py WAD OUT.INS [--work DIR] [--all]
    --all: every instrument at notes 6, 18, ... 90 (reach 7) and every drum,
    not only the songs' - for songs the WAD does not have
"""
import argparse, os, struct, subprocess, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dmus

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FS = 52640                      # the capture's rate: 4 x 13160, ~ the OPL's own 49716
HOLD_S, TAIL_S = 8.0, 1.0       # a capture: the note held, then released
FIT_DB = 0.5                    # a hold is kept until one decay carries the rest within this
F_CUT = 11000.0                 # what any table may carry at the top of its band
ATTACK_MS, ATTACK_SIZE = 100.0, 2048
PERC_RATE, PERC_MAX, PERC_FLOOR_DB = 894886.25 / 34 / 2, 8192, -45.0

ap = argparse.ArgumentParser()
ap.add_argument("wad"); ap.add_argument("out")
ap.add_argument("--work", default=os.path.join(ROOT, "sim", "rvvm_work", "doom_music"))
ap.add_argument("--all", action="store_true")
a = ap.parse_args()
cap_dir = os.path.join(a.work, "cap"); os.makedirs(cap_dir, exist_ok=True)

# ---- the harness ---------------------------------------------------------------------
render = os.path.join(a.work, "render_opl")
choc, dg, fwd = os.path.join(ROOT, "..", "chocolate-doom"), os.path.join(ROOT, "..", "doomgeneric", "doomgeneric"), os.path.join(ROOT, "apple", "rvvm", "doom")
srcs = [os.path.join(HERE, "render_opl.c"), f"{choc}/src/i_oplmusic.c", f"{choc}/src/midifile.c", f"{choc}/opl/opl.c",
        f"{choc}/opl/opl_queue.c", f"{HERE}/opl_rv.c", f"{HERE}/dbopl_rv.c", f"{dg}/mus2mid.c", f"{dg}/memio.c"]
if not os.path.exists(f"{choc}/opl/dbopl.c"):
    sys.exit(f"no chocolate-doom-2.2.1 at {choc} (git -C {choc} checkout chocolate-doom-2.2.1)")
if not os.path.exists(render) or any(os.path.getmtime(s) > os.path.getmtime(render) for s in srcs):
    subprocess.run(["cc", "-O2", "-w", f"-DOPL_RATE={FS}", f"-I{HERE}/stub", f"-I{fwd}/compat", "-include", f"{fwd}/compat/SDL.h",
                    "-DFEATURE_SOUND", "-D_DEFAULT_SOURCE", f"-I{dg}", f"-I{choc}/opl", f"-I{choc}/src",
                    "-Dopl_sdl_driver=opl_rv_driver", "-o", render] + srcs + ["-lm"], check=True)
    for f in os.listdir(cap_dir): os.remove(os.path.join(cap_dir, f))    # a new harness: new captures

def varlen(v):
    out = [v & 127]; v >>= 7
    while v: out.append((v & 127) | 128); v >>= 7
    return bytes(reversed(out))

def capture(tag, ch, program, note, voice):
    """One note at full volume through the port's OPL path, only `voice` sounding:
    HOLD_S held, TAIL_S released."""
    raw = os.path.join(cap_dir, f"{tag}_v{voice}_{HOLD_S:g}+{TAIL_S:g}.raw")
    if not os.path.exists(raw):
        tr = varlen(0) + bytes([0xFF, 0x51, 3]) + (1000000).to_bytes(3, "big")          # 1 tick = 1 ms
        tr += varlen(0) + bytes([0xB0 | ch, 7, 127])
        if ch != 9: tr += varlen(0) + bytes([0xC0 | ch, program])
        tr += varlen(0) + bytes([0x90 | ch, note, 127])
        tr += varlen(int(HOLD_S * 1000)) + bytes([0x80 | ch, note, 0])
        tr += varlen(int(TAIL_S * 1000)) + bytes([0xFF, 0x2F, 0])
        mid = os.path.join(cap_dir, tag + ".mid")
        open(mid, "wb").write(b"MThd" + struct.pack(">IHHH", 6, 0, 1, 1000) + b"MTrk" + struct.pack(">I", len(tr)) + tr)
        subprocess.run([render, a.wad, mid, str(HOLD_S + TAIL_S), raw, "127", "0"], check=True,
                       env=dict(os.environ, TMPDIR=cap_dir, QUIET="1", DMUS_MUTE=str(1 - voice)),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return np.fromfile(raw, np.int16).astype(np.float64)

# ---- signal helpers --------------------------------------------------------------------
def lowpass(x, fc, fs, taps=255):
    if fc >= fs / 2 * 0.98: return x
    n = np.arange(taps) - (taps - 1) / 2
    h = np.sinc(2 * fc / fs * n) * np.kaiser(taps, 9.0); h /= h.sum()
    return np.convolve(x, h, mode="same")

def resample(x, fs_in, fs_out, n_out):
    return np.interp(np.arange(n_out) * fs_in / fs_out, np.arange(len(x)), x, right=0.0)

HOP = int(round(FS / dmus.TICK_HZ))
def envelope(x, period=0.0):
    """RMS a tick at a time, each over at least two periods (centred) so a low
    note's own waveform does not ripple it."""
    n = len(x) // HOP
    w = max(HOP, int(2 * period))
    if w == HOP: return np.sqrt(np.mean(x[:n * HOP].reshape(n, HOP) ** 2, axis=1) + 1e-9)
    c = np.concatenate([[0.0], np.cumsum(x * x)])
    mid = np.arange(n) * HOP + HOP // 2
    lo, hi = np.clip(mid - w // 2, 0, len(x)), np.clip(mid + w // 2, 0, len(x))
    return np.sqrt((c[hi] - c[lo]) / np.maximum(hi - lo, 1) + 1e-9)

def detect_f0(x, f_exp):
    """The loop's pitch: the note's own, unless the capture plainly is an octave off it."""
    seg = x[int(0.12 * FS): int(0.37 * FS)]
    if np.sqrt(np.mean(seg ** 2)) < 1: seg = x[: int(0.25 * FS)]
    def ac(f):
        lag = FS / f
        i0 = np.arange(len(seg) - int(lag) - 2)
        y = np.interp(i0 + lag, np.arange(len(seg)), seg)
        return np.dot(seg[i0], y) / (np.sqrt(np.dot(seg[i0], seg[i0]) * np.dot(y, y)) + 1e-9)
    cands = [(ac(f_exp * 2.0 ** k), f_exp * 2.0 ** k) for k in (-2, -1, 0, 1, 2) if 8 < f_exp * 2.0 ** k < 6000]
    best = max(cands)
    own = [c for c in cands if c[1] == f_exp]
    f = f_exp if own and own[0][0] >= 0.8 * best[0] else best[1]
    for step in (0.01, 0.002, 0.0004):
        f = max((ac(f * (1 + step * j)), f * (1 + step * j)) for j in range(-4, 5))[1]
    return f

def midi_hz(n): return 440.0 * 2.0 ** ((n - 69) / 12)

def shorten(hold):
    """The hold kept only as far as it must be: from the first tick where one
    decay (never a rise), from the kept part's last value, carries the rest of
    the capture within FIT_DB; that tick's factor is the decay."""
    db = 20 * np.log10(np.maximum(hold, 1e-3))
    for n in range(10, len(hold) - 10, 5):
        t = np.arange(len(hold) - n + 1)
        k = min(0.0, np.polyfit(t, db[n - 1:], 1)[0])            # dB a tick
        if np.max(np.abs(db[n - 1] + k * t - db[n - 1:])) < FIT_DB:
            return hold[:n], float(10 ** (k / 20))
    return hold, float(10 ** (min(0.0, np.polyfit(np.arange(20), db[-20:], 1)[0]) / 20))

# ---- what to build ---------------------------------------------------------------------
lumps = dmus.read_wad(a.wad)
INSTR = dmus.genmidi(lumps)
if a.all:
    used = {}
    for i in range(175):
        for v in ((0, 1) if INSTR[i]["flags"] & 4 else (0,)):
            used[(i, v)] = set(range(6, 96, 12)) if i < 128 else {i - 128 + 35}
else:
    used = {}
    for s in dmus.songs(lumps):
        for k, v in dmus.usage(dmus.parse_mus(lumps[s])[0], INSTR).items(): used.setdefault(k, set()).update(v)

nh = int(HOLD_S * dmus.TICK_HZ)
ents = []
for (ins, voice), notes in sorted(used.items()):
    I = INSTR[ins]
    fixed, drum = bool(I["flags"] & 1), ins >= 128
    for ref in (sorted(notes) if drum or not fixed else [I["fixed"]]):
        x = capture(f"p{ref:03d}" if drum else f"m{ins:03d}_{ref:03d}", 9 if drum else 0, 0 if drum else ins, ref, voice)
        env = envelope(x)
        rel = np.minimum(env[nh:] / (env[nh - 1] + 1e-9), 1.0)
        if drum:                                                              # a one-shot, to -45 dB
            live = np.nonzero(env > env.max() * 10 ** (PERC_FLOOR_DB / 20))[0]
            want = int(((live[-1] + 1) if len(live) else 7) / dmus.TICK_HZ * PERC_RATE) + 1
            n = min(want, PERC_MAX)
            size = 256
            while size < n: size *= 2
            xp = resample(lowpass(x, min(F_CUT, PERC_RATE / 2 * 0.9), FS), FS, PERC_RATE, size)
            if n < size: xp[n:] = 0
            if want > PERC_MAX:
                q = size // 4; xp[-q:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, q)))   # cut short: faded
            pk = np.abs(xp).max() + 1e-9
            ents.append(dict(ins=ins, ref=ref, voice=voice, flags=1 | 2, f0=0.0, arate=PERC_RATE,
                             atab=np.clip(np.round(127 * xp / pk), -127, 127), ltab=np.zeros(0), hold=np.zeros(0), rel=rel,
                             a_amp=pk, decay=0.0, reach=0))
            continue
        reach = 0 if fixed else (7 if a.all else 2)                           # a whole-tone bend (--all: half an octave more)
        # the note's pitch: GENMIDI's offset for this voice (DMX's FrequencyForVoice)
        off = 0 if fixed else struct.unpack_from("<h", lumps["GENMIDI"], 8 + 36 * ins + 4 + 16 * voice + 14)[0]
        tune = (I["fine"] // 2 - 64) / 32 if voice else 0.0                   # voice 1's fine tuning, in semitones
        f0 = detect_f0(x, midi_hz(ref + off + tune))
        fc = F_CUT * 2.0 ** (-reach / 12)
        per = FS / f0
        ta = max(1, int(round(ATTACK_MS / 1000 * f0))) * per                   # a whole number of periods
        arate = ATTACK_SIZE / (ta / FS)
        xa = resample(lowpass(x, min(fc, arate / 2 * 0.9), FS), FS, arate, ATTACK_SIZE)
        apk = np.abs(xa).max() + 1e-9
        seg = x[int(ta):int(ta) + int(max(8 * per, 0.04 * FS))]
        tt, win = np.arange(len(seg)) / FS, np.hanning(len(seg))
        kmax = max(1, int(fc / f0))
        lsize = 256
        while lsize < 4 * kmax: lsize *= 2
        ph = np.arange(lsize) / lsize
        cyc = np.zeros(lsize)
        for k in range(1, kmax + 1):
            ck = 2 * np.sum(win * seg * np.exp(-2j * np.pi * k * f0 * tt)) / np.sum(win)
            cyc += np.real(ck * np.exp(2j * np.pi * k * ph))
        lpk = np.abs(cyc).max() + 1e-9
        env = envelope(x, per)                                                  # the loop's, over whole periods
        env_w = np.sqrt(np.mean(seg ** 2)) + 1e-9
        hold = lpk * env[:nh] / env_w                                          # the loop's amplitude, a tick at a time
        ents.append(dict(ins=ins, ref=ref, voice=voice, flags=int(fixed), f0=f0, arate=arate,
                         atab=np.clip(np.round(127 * xa / apk), -127, 127), ltab=np.clip(np.round(127 * cyc / lpk), -127, 127),
                         hold=hold, rel=rel, a_amp=apk, reach=reach))

for e in ents:
    if len(e["hold"]): e["hold"], e["decay"] = shorten(e["hold"])
    rl = np.nonzero(e["rel"] > 10 ** (-60 / 20))[0]                     # the release to -60 dB
    e["rel"] = e["rel"][:(rl[-1] + 2) if len(rl) else 1]

# one amplitude scale for the file: the loudest anything reaches is 65535
top = max([e["a_amp"] for e in ents] + [e["hold"].max() for e in ents if len(e["hold"])])
for e in ents:
    e["hold"] = np.round(e["hold"] / top * 65535); e["a_amp"] = int(round(e["a_amp"] / top * 65535))
    e["rel"] = np.round(e["rel"] * 65535); e["decay"] = min(65535, int(round(e["decay"] * 65536)))
size = dmus.write_ins(a.out, ents)
nv = len({(e["ins"], e["voice"]) for e in ents})
print(f"{a.out}: {len(ents)} entries ({nv} voices of {len({e['ins'] for e in ents})} instruments), {size} bytes")
