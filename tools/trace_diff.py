# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Compare two boot_tb traces op by op and report the first divergence.

A trace is a stream of 8-byte records, two little-endian u32s per retired op:
    word0: the 100 MHz clock count at retirement
    word1: [31:24] flags {0,0,0,0, turbo, dhit, sync, rw}
           [23:16] the byte (din for a read, dout for a write)
           [15:0]  the address

The comparison keys on (addr, rw, data, sync) - the architectural stream.
The clock and the dhit/turbo flags differ legitimately between checkouts and
are reported, not compared.

usage: trace_diff.py A.trc B.trc [--context=N] [--skip=N]
"""

import struct
import sys


def read_trace(path):
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // 8
    return data, n


def rec(data, i):
    clk, w = struct.unpack_from("<II", data, i * 8)
    return clk, w & 0xFFFF, (w >> 16) & 0xFF, (w >> 24) & 0x0F


def fmt(data, i):
    clk, addr, byte, fl = rec(data, i)
    kind = "W" if not (fl & 1) else "r"
    if fl & 8:
        kind += " turbo"
    elif fl & 4:
        kind += " d$"
    sync = " SYNC" if fl & 2 else ""
    return f"op {i:>9}  clk {clk:>10}  ${addr:04X} {kind} {byte:02X}{sync}"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=") for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    context = int(opts.get("context", 16))
    skip = int(opts.get("skip", 0))
    if len(args) != 2:
        sys.exit(__doc__)

    da, na = read_trace(args[0])
    db, nb = read_trace(args[1])
    print(f"A: {args[0]}: {na} ops")
    print(f"B: {args[1]}: {nb} ops")

    n = min(na, nb)
    div = -1
    for i in range(skip, n):
        _, aa, ba, fa = rec(da, i)
        _, ab, bb, fb = rec(db, i)
        # Compare addr, byte, and the rw/sync flag bits only.
        if aa != ab or ba != bb or (fa & 3) != (fb & 3):
            div = i
            break

    if div < 0:
        print(f"identical for {n} ops ({'A' if na < nb else 'B'} is shorter)"
              if na != nb else f"identical: all {n} ops")
        return

    print(f"\nFIRST DIVERGENCE at op {div}:")
    print(f"  A: {fmt(da, div)}")
    print(f"  B: {fmt(db, div)}")
    lo = max(0, div - context)
    hi = min(n, div + context // 2 + 1)
    print(f"\ncontext (A | B), ops {lo}..{hi - 1}:")
    for i in range(lo, hi):
        mark = " <<<" if i == div else ""
        print(f"  A {fmt(da, i)}")
        print(f"  B {fmt(db, i)}{mark}")

    # A quick tail summary: how far past the divergence do they re-converge?
    resync = 0
    for i in range(div, min(n, div + 100000)):
        _, aa, ba, fa = rec(da, i)
        _, ab, bb, fb = rec(db, i)
        if aa == ab and ba == bb and (fa & 3) == (fb & 3):
            resync += 1
    print(f"\nof the next 100000 ops, {resync} happen to match (streams may re-align or not)")


if __name__ == "__main__":
    main()
