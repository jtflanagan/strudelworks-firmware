#!/usr/bin/env bash
# DOOM's tuned DBOPL (apple/rvvm/doom/dbopl_rv.c) against Chocolate Doom's own
# (../chocolate-doom/opl/dbopl.c, tag chocolate-doom-2.2.1): sim/dbopl_equiv.c
# built on the PC once with each, the same register writes into both, every
# 256-sample chunk's hash compared line for line (OPL2 then OPL3).  PASS = the
# two outputs are identical.
#   sim/run_dbopl_equiv.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
choc="$root/../chocolate-doom"
[ -f "$choc/opl/dbopl.c" ] || { echo "no chocolate-doom-2.2.1 at $choc" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for v in orig rv; do
    src="$choc/opl/dbopl.c"; [ $v = rv ] && src="$root/apple/rvvm/doom/dbopl_rv.c"
    cc -O2 -I"$choc/opl" -I"$choc/src" -o "$work/$v" "$root/sim/dbopl_equiv.c" "$src" -lm
    "$work/$v" > "$work/$v.out"
done
n=$(wc -l < "$work/orig.out")
if cmp -s "$work/orig.out" "$work/rv.out"; then
    echo "PASS dbopl-equiv: $((n - 1)) chunks identical ($(tail -1 "$work/rv.out"))"
else
    echo "FAIL dbopl-equiv: first difference:"; diff "$work/orig.out" "$work/rv.out" | head -5; exit 1
fi
