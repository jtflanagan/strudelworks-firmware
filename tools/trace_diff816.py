#!/usr/bin/env python3
"""Compare the card's IIgs instruction trace against KEGS's (docs/GS.md rung 3).

    tools/trace_diff816.py CARD.trc KEGS.bin [--limit N] [--context N] [--period N] [--regs] [--raw]

CARD.trc is sim/boot_gs_tb.sv's twenty-byte record; KEGS.bin is the reference
trace tools/kegs/trace_rom.sh produces (its own 32-byte Pc_log struct).  Both
are decoded to the same tuple and walked in instruction order.

WHAT IS COMPARED, and why not everything.  By default: the bank and PC of
every instruction and its opcode.  That is the architectural sequence, and it
is what the two machines must agree on.  --regs adds A, X, Y, S, D, DBR and
the flags, which is a stronger check and a noisier one: the card's core and
KEGS need not agree on the state left by an instruction that read an I/O
register neither models the same way, so a register difference is often the
CONSEQUENCE of a divergence rather than one of its own.

TIMING IS NOT COMPARED AT ALL.  KEGS's cycle model is not the card's - it does
not model refresh, and its 1 MHz stretch applies only to I/O and shadowed
writes (tools/kegs/README.md) - so nothing here reads a cycle count.

AND A WAIT LOOP IS ONE EVENT ON EITHER SIDE, which is the whole reason the
comparison is possible at all.  The ROM spends most of its startup in delay
loops - at 100,000 instructions on the first run of this bench, 55% of them
were the two instructions at $FF/FCDC - and the two machines do not count
down the same number of times, because the loop is a TIMING construct and
their cycle models differ.  So a maximal run of records that repeats with a
period of at most --period instructions is collapsed to one copy of that
period before the comparison, and the divergence is reported in COLLAPSED
EVENTS as well as in raw instructions.  The event count is the honest measure
of how far the two machines agree; the raw count is the one that flatters.

The output is the first divergence with context either side, and the counts.
Exit 0 whether or not the traces diverge: a divergence is a MEASUREMENT at
this rung, not a failure.  Exit 2 means a trace could not be read.

--floor N makes it a regression gate instead: the run FAILS (exit 1) if the
traces part company before event N, and prints AT-FLOOR/ABOVE-FLOOR otherwise.
That is how sim/suite.sh pins the number a rung reached, so the next change
cannot quietly take it back; raise the floor when a rung moves it.
"""
import struct
import sys

CARD = struct.Struct('<IIIII')      # 20 bytes: see sim/boot_gs_tb.sv
KEGS = struct.Struct('<QIIIIII')    # 32 bytes: KEGS's Pc_log


class Rec:
    __slots__ = ('pbr', 'pc', 'op', 'a', 'x', 'y', 's', 'd', 'dbr', 'p', 'e')

    def key(self, regs):
        if regs:
            return (self.pbr, self.pc, self.op, self.a, self.x, self.y,
                    self.s, self.d, self.dbr, self.p, self.e)
        return (self.pbr, self.pc, self.op)

    def __str__(self):
        return ('%02x/%04x op=%02x A=%04x X=%04x Y=%04x S=%04x D=%04x '
                'B=%02x P=%02x E=%d' % (self.pbr, self.pc, self.op, self.a,
                                        self.x, self.y, self.s, self.d,
                                        self.dbr, self.p, self.e))


def _mk(pbr, pc, op, a, x, y, s, d, dbr, psr):
    r = Rec()
    r.pbr, r.pc, r.op = pbr, pc, op
    r.a, r.x, r.y, r.s, r.d, r.dbr = a, x, y, s, d, dbr
    r.p, r.e = psr & 0xff, (psr >> 8) & 1
    return r


def read_card(path, limit):
    out = []
    with open(path, 'rb') as f:
        while limit is None or len(out) < limit:
            buf = f.read(CARD.size)
            if len(buf) < CARD.size:
                break
            w0, w1, w2, w3, w4 = CARD.unpack(buf)
            out.append(_mk((w0 >> 16) & 0xff, w0 & 0xffff, (w1 >> 24) & 0xff,
                           w2 & 0xffff, w3 >> 16, w3 & 0xffff,
                           w4 >> 16, w4 & 0xffff, (w0 >> 24) & 0xff, w2 >> 16))
    return out


def read_kegs(path, limit):
    out = []
    with open(path, 'rb') as f:
        while limit is None or len(out) < limit:
            buf = f.read(KEGS.size)
            if len(buf) < KEGS.size:
                break
            _cyc, dbank_kpc, instr, psr_acc, xy, sd, _pad = KEGS.unpack(buf)
            out.append(_mk((dbank_kpc >> 16) & 0xff, dbank_kpc & 0xffff,
                           (instr >> 24) & 0xff, psr_acc & 0xffff,
                           xy >> 16, xy & 0xffff, sd >> 16, sd & 0xffff,
                           (dbank_kpc >> 24) & 0xff, psr_acc >> 16))
    return out


def collapse(recs, keys, period_max):
    """A maximal run repeating with period p <= period_max becomes one copy of it.

    Returns (events, index) - the kept records, and for each the index of the
    first raw instruction it stands for.  Only exact repetitions collapse, so
    a loop that does different work on its last pass keeps that pass.
    """
    out, idx = [], []
    i = 0
    n = len(recs)
    while i < n:
        best = 0
        for p in range(1, period_max + 1):
            if i + 2 * p > n:
                break
            if keys[i:i + p] == keys[i + p:i + 2 * p]:
                best = p
                break
        out.extend(recs[i:i + max(best, 1)])
        idx.extend(range(i, i + max(best, 1)))
        if best == 0:
            i += 1
            continue
        # How far does this period run?
        j = i + best
        while j + best <= n and keys[j:j + best] == keys[i:i + best]:
            j += best
        i = j
    return out, idx


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    card_path, kegs_path = args[0], args[1]
    limit = None
    context = 8
    regs = False
    period = 16
    raw = False
    floor = None
    i = 2
    while i < len(args):
        if args[i] == '--limit':
            limit = int(args[i + 1]); i += 2
        elif args[i] == '--context':
            context = int(args[i + 1]); i += 2
        elif args[i] == '--period':
            period = int(args[i + 1]); i += 2
        elif args[i] == '--regs':
            regs = True; i += 1
        elif args[i] == '--floor':
            floor = int(args[i + 1]); i += 2
        elif args[i] == '--raw':
            raw = True; i += 1
        else:
            sys.exit('unknown option ' + args[i])

    try:
        card = read_card(card_path, limit)
        # The reference is 5M instructions and the card's runs are shorter, so
        # read only as much of it as could possibly be compared: the card's
        # count times a generous factor for the loops KEGS spins longer in.
        kegs = read_kegs(kegs_path, limit if limit is not None
                         else max(1000, len(card) * 8))
    except OSError as e:
        print('trace_diff816: %s' % e)
        return 2

    n_card_raw, n_kegs_raw = len(card), len(kegs)
    ck = [r.key(regs) for r in card]
    kk = [r.key(regs) for r in kegs]
    if raw:
        c_idx, k_idx = list(range(n_card_raw)), list(range(n_kegs_raw))
    else:
        card, c_idx = collapse(card, ck, period)
        kegs, k_idx = collapse(kegs, kk, period)

    n = min(len(card), len(kegs))
    print('trace_diff816: card %d instructions -> %d events, KEGS %d -> %d, '
          'comparing %d%s' % (n_card_raw, len(card), n_kegs_raw, len(kegs), n,
                              ' with registers' if regs else ''))
    if n == 0:
        print('trace_diff816: nothing to compare')
        return 0

    at = None
    for k in range(n):
        if card[k].key(regs) != kegs[k].key(regs):
            at = k
            break

    if at is None:
        who = 'the card' if len(card) <= len(kegs) else 'the reference'
        print('trace_diff816: NO DIVERGENCE in %d events / %d card instructions '
              '(%s ran out first)' % (n, n_card_raw, who))
        if floor is not None:
            if n < floor:
                print('trace_diff816: BELOW FLOOR - only %d events compared, '
                      'floor is %d (the run was too short)' % (n, floor))
                return 1
            print('trace_diff816: ABOVE FLOOR (%d events, floor %d)' % (n, floor))
        return 0

    print('trace_diff816: divergence at event %d (card instruction %d, '
          'reference instruction %d)' % (at, c_idx[at], k_idx[at]))
    lo = max(0, at - context)
    hi = min(n, at + context + 1)
    print('    %-6s %-8s %-52s %s' % ('event', 'instr', 'card', 'KEGS'))
    for k in range(lo, hi):
        mark = '>>' if k == at else '  '
        print('  %s%-6d %-8d %-52s %s' % (mark, k, c_idx[k], card[k], kegs[k]))
    if floor is not None:
        if at < floor:
            print('trace_diff816: BELOW FLOOR - diverged at event %d, floor is %d'
                  % (at, floor))
            return 1
        print('trace_diff816: %s FLOOR (event %d, floor %d)'
              % ('AT' if at == floor else 'ABOVE', at, floor))
    return 0


if __name__ == '__main__':
    sys.exit(main())
