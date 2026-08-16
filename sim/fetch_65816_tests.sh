#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Sample SingleStepTests/65816 - the closest thing the 65816 has to Klaus
# Dormann's suites, and in one respect better: every test records the
# cycle-by-cycle BUS ACTIVITY, not just the register state at the end.
#
# The full suite is 512 files and 2.9 GB of JSON (20,000 tests per opcode,
# 10,000 native and 10,000 emulated).  That is worth having eventually, and it
# is far too much to pull for a cycle-count check.  Each test is one LINE, so a
# byte-range request returns a valid random sample of a few hundred tests per
# opcode - about 130 MB, and about ten seconds.
#
#   sim/fetch_65816_tests.sh            # ~256 KB per opcode file
#   BYTES=2000000 sim/fetch_65816_tests.sh   # a deeper sample
#   FULL=1 sim/fetch_65816_tests.sh     # all 2.9 GB, for a real regression
#
# Not vendored: the suite has no stated licence, so it is fetched, never
# committed.  sim/cpu816_work/ is gitignored for that reason.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/cpu816_work/samples"
mkdir -p "$out"

BASE="https://raw.githubusercontent.com/SingleStepTests/65816/main/v1"
BYTES="${BYTES:-262144}"
FULL="${FULL:-}"

fetch_one() {
    local f="$1"
    [ -s "$out/$f" ] && return 0
    if [ -n "$FULL" ]; then
        curl -sfL "$BASE/$f" -o "$out/$f.part"
    else
        # A prefix of a line-per-test file is still parseable; the last,
        # truncated line is dropped by the reader.
        curl -sfL -r "0-$BYTES" "$BASE/$f" -o "$out/$f.part"
    fi
    mv "$out/$f.part" "$out/$f"
}
export -f fetch_one
export out BASE BYTES FULL

for i in $(seq 0 255); do
    printf '%02x.n.json\n%02x.e.json\n' "$i" "$i"
done | xargs -P 16 -I{} bash -c 'fetch_one "$@"' _ {}

echo "$(ls "$out" | wc -l) files, $(du -sh "$out" | cut -f1) in $out"
