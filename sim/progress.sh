#!/usr/bin/env bash
# strudelworks-firmware
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Where a long bench is, from its log's progress counters - the standing rule
# (docs/BOOT_BENCH.md): monitor by counters and extrapolation, never
# timeout-and-retry.  Reads the last "    ...N clocks, ..." line.
#
#   sim/progress.sh LOG [--cycles=N] [--expect=N]
#
#   boot_tb  : percent = bus cycles / --cycles (default: the log's header, else 2000000);
#              bad and mism must stay 0, blocks r/w climbing is the boot progressing
#   accel_tb : percent = clocks / --expect (default: LOG.expect, written by suite.sh
#              from the previous PASS, else unknown)
#   mem_integ: clocks, reads, hits/misses
#
# Exit 0 PASS seen; 3 FAIL, or bad/mism > 0 (abort it); 4 still running; 5 no
# progress line yet.
set -uo pipefail
log="${1:-}"; shift || true
[ -f "$log" ] || { echo "usage: sim/progress.sh LOG [--cycles=N] [--expect=N]" >&2; exit 5; }
cycles=""; expect=""
for a in "$@"; do case "$a" in --cycles=*) cycles="${a#*=}";; --expect=*) expect="${a#*=}";; esac; done

line="$(grep -E '^    \.\.\.[0-9]+ clocks' "$log" | tail -1)"
verdict=""
if grep -qE '^PASS$|^PASS: |both suites passed|predict/cancel contract holds|self-test: PASS|checks, 0 failures' "$log"; then verdict=PASS
elif grep -qE '^FAIL$|^FAIL: |^FAILURES|self-test: FAIL|checks, [1-9][0-9]* failures' "$log"; then verdict=FAIL; fi

# rate: from the file's birth time when the filesystem has it
born="$(stat -c %W "$log" 2>/dev/null || echo 0)"
now="$(date +%s)"
elapsed=$(( now - born ))
[ "$born" -gt 0 ] || elapsed=0

if [ -z "$line" ]; then
    [ "$verdict" = PASS ] && { echo "PASS (no progress line printed)"; exit 0; }
    [ "$verdict" = FAIL ] && { echo "FAIL"; grep -E 'FAIL|error' "$log" | head -5; exit 3; }
    echo "no progress line yet ($(wc -l < "$log") lines, ${elapsed}s)"; exit 5
fi
clocks="$(sed -E 's/^    \.\.\.([0-9]+) clocks.*/\1/' <<<"$line")"
rate=""; [ "$elapsed" -gt 0 ] && rate=$(( clocks / elapsed ))
rate_txt="rate ?"; [ -n "$rate" ] && rate_txt="rate $(( rate / 1000 ))k clk/s"

if grep -q ' bus cycles, ' <<<"$line"; then
    # boot_tb
    bus="$(sed -E 's/.*clocks, ([0-9]+) bus cycles.*/\1/' <<<"$line")"
    pc="$(sed -E 's/.*PC~\$([0-9a-fA-F]+).*/\1/' <<<"$line")"
    blocks="$(sed -E 's/.*blocks (r[0-9]+ w[0-9]+).*/\1/' <<<"$line")"
    bad="$(sed -E 's/.*bad ([0-9]+).*/\1/' <<<"$line")"
    mism="$(sed -E 's/.*mism ([0-9]+).*/\1/' <<<"$line")"
    [ -n "$cycles" ] || cycles="$(grep -oE 'cycles=[0-9]+' "$log" | head -1 | cut -d= -f2)"
    [ -n "$cycles" ] || cycles=2000000
    pct=$(( bus * 100 / cycles ))
    eta=""
    if [ -n "$rate" ] && [ "$rate" -gt 0 ] && [ "$bus" -gt 0 ]; then
        eta=$(( (cycles - bus) * elapsed / bus ))
        eta=", ETA ~$(( eta / 60 ))m$(( eta % 60 ))s"
    fi
    echo "boot ${pct}% (bus cycles $bus/$cycles, $clocks clocks, ${elapsed}s, $rate_txt$eta) PC~\$$pc blocks $blocks bad $bad mism $mism${verdict:+ -> $verdict}"
    if [ "$bad" != 0 ] || [ "$mism" != 0 ]; then echo "ABORT: bad/mism nonzero"; exit 3; fi
elif grep -q ' reads (' <<<"$line"; then
    # accel_tb
    reads="$(sed -E 's/.*clocks, ([0-9]+) reads \(([0-9]+) fast\).*/\1 (\2 fast)/' <<<"$line")"
    ops="$(sed -E 's/.*fast_ops ([0-9]+) turbo ([0-9]+) bus_ops ([0-9]+) cycles ([0-9]+).*/fast_ops \1 turbo \2 bus_ops \3 cycles \4/' <<<"$line")"
    [ -n "$expect" ] || { [ -f "$log.expect" ] && expect="$(cat "$log.expect")"; }
    pct="?"; eta=""
    if [ -n "$expect" ] && [ "$expect" -gt 0 ]; then
        pct=$(( clocks * 100 / expect ))
        if [ -n "$rate" ] && [ "$rate" -gt 0 ]; then eta=$(( (expect - clocks) / rate )); eta=", ETA ~$(( eta / 60 ))m$(( eta % 60 ))s"; fi
    fi
    echo "accel ${pct}% ($clocks clocks${expect:+/$expect}, ${elapsed}s, $rate_txt$eta) reads $reads $ops${verdict:+ -> $verdict}"
else
    echo "${line#    ...} (${elapsed}s, $rate_txt)${verdict:+ -> $verdict}"
fi
case "$verdict" in PASS) exit 0;; FAIL) exit 3;; *) exit 4;; esac
