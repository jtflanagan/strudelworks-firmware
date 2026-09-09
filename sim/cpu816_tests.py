#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Pack SingleStepTests/65816 JSON into the flat binary sim/cpu816_trace_main.cpp reads.

One record per test, little-endian:
    u8  opcode, u8 emulated-file flag
    regs: u16 pc, u16 s, u8 p, u16 a, u16 x, u16 y, u8 dbr, u16 d, u8 pbr, u8 e   (initial)
    u16 n_ram, n_ram x (u32 addr, u8 val)
    regs (final), u16 n_ram, entries
    u16 n_cycles, n_cycles x (u32 addr or 0xFFFFFFFF, u16 val or 0xFFFF, u8 flags)
      flags bit0 VDA, bit1 VPA, bit2 VPB, bit3 read, bit4 E, bit5 M, bit6 X, bit7 MLB

    sim/cpu816_tests.py OUT.bin [--limit N] [--opcodes aa,bb,..] [--samples DIR]
"""
import json, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REGS = struct.Struct('<HHBHHHBHBB')


def load(path, limit):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip().lstrip('[').rstrip(',').rstrip(']')
            if not line.endswith('}'):
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
            if limit and len(out) >= limit:
                break
    return out


def regs(r):
    return REGS.pack(r['pc'], r['s'], r['p'], r['a'], r['x'], r['y'], r['dbr'],
                     r['d'], r['pbr'], r['e'])


def ram(entries):
    out = [struct.pack('<H', len(entries))]
    for a, v in entries:
        out.append(struct.pack('<IB', a, v))
    return b''.join(out)


def flags(s):
    b = 0
    if 'd' in s: b |= 1
    if 'p' in s: b |= 2
    if 'v' in s: b |= 4
    if 'r' in s: b |= 8
    if 'e' in s: b |= 16
    if 'm' in s: b |= 32
    if 'x' in s: b |= 64
    if 'l' in s: b |= 128
    return b


def main():
    args = sys.argv[1:]
    out = args.pop(0)
    limit = 0
    opcodes = list(range(256))
    samples = os.path.join(HERE, 'cpu816_work', 'samples')
    while args:
        a = args.pop(0)
        if a == '--limit': limit = int(args.pop(0))
        elif a == '--opcodes': opcodes = [int(x, 16) for x in args.pop(0).split(',')]
        elif a == '--samples': samples = args.pop(0)
        else: sys.exit('unknown option ' + a)
    n = 0
    with open(out, 'wb') as f:
        for oc in opcodes:
            for mode in 'ne':
                p = os.path.join(samples, f'{oc:02x}.{mode}.json')
                if not os.path.exists(p):
                    continue
                for t in load(p, limit):
                    rec = [struct.pack('<BB', oc, 1 if mode == 'e' else 0),
                           regs(t['initial']), ram(t['initial']['ram']),
                           regs(t['final']), ram(t['final']['ram']),
                           struct.pack('<H', len(t['cycles']))]
                    for c in t['cycles']:
                        addr = 0xFFFFFFFF if c[0] is None else c[0]
                        val = 0xFFFF if c[1] is None else c[1]
                        rec.append(struct.pack('<IHB', addr, val, flags(c[2])))
                    f.write(b''.join(rec))
                    n += 1
    print(f'{n} tests -> {out}')


if __name__ == '__main__':
    main()
