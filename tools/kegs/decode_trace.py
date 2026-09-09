#!/usr/bin/env python3
"""Decode a KEGS instruction trace written by the -trace hook (tools/kegs/README.md).

Each record is KEGS's own Pc_log struct, 32 bytes, little-endian:
    u64 dfcyc          cycle count, 48.16 fixed point (1 MHz-ish cycles)
    u32 dbank_kpc      {dbank[7:0], pbr[7:0], pc[15:0]}
    u32 instr          {opcode[7:0], byte3, byte2, byte1} (operands little-endian below the opcode)
    u32 psr_acc        {psr[15:0], acc[15:0]}  psr bit 8 = E
    u32 xreg_yreg      {x[15:0], y[15:0]}
    u32 stack_direct   {s[15:0], d[15:0]}
    u32 pad

Output, one line per instruction, the shape sim/trace_diff.py wants:
    <n> <pbr>/<pc> op=<opcode> args=<b1 b2 b3> A=<a> X=<x> Y=<y> S=<s> D=<d> B=<dbr> P=<psr> E=<e> cyc=<cycles>

Usage: decode_trace.py TRACE.bin [--limit N] [--from N]
"""
import struct
import sys

REC = struct.Struct('<QIIIIII')


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    path = args[0]
    limit = None
    start = 0
    i = 1
    while i < len(args):
        if args[i] == '--limit':
            limit = int(args[i + 1]); i += 2
        elif args[i] == '--from':
            start = int(args[i + 1]); i += 2
        else:
            sys.exit('unknown option ' + args[i])
    out = sys.stdout
    with open(path, 'rb') as f:
        n = 0
        emitted = 0
        while True:
            buf = f.read(REC.size)
            if len(buf) < REC.size:
                break
            dfcyc, dbank_kpc, instr, psr_acc, xy, sd, _pad = REC.unpack(buf)
            if n >= start:
                dbr = (dbank_kpc >> 24) & 0xff
                kpc = dbank_kpc & 0xffffff
                op = (instr >> 24) & 0xff
                b1, b2, b3 = instr & 0xff, (instr >> 8) & 0xff, (instr >> 16) & 0xff
                psr = (psr_acc >> 16) & 0xffff
                acc = psr_acc & 0xffff
                out.write('%d %02x/%04x op=%02x args=%02x%02x%02x A=%04x X=%04x Y=%04x '
                          'S=%04x D=%04x B=%02x P=%02x E=%d cyc=%d\n' % (
                              n, kpc >> 16, kpc & 0xffff, op, b1, b2, b3, acc,
                              xy >> 16, xy & 0xffff, sd >> 16, sd & 0xffff, dbr,
                              psr & 0xff, (psr >> 8) & 1, dfcyc >> 16))
                emitted += 1
                if limit is not None and emitted >= limit:
                    break
            n += 1


if __name__ == '__main__':
    main()
