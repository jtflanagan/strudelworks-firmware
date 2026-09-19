#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Exercises sim/trace_replay_main.cpp end to end, with no Apple II in the room.
#
# WHAT THIS PROVES, and what it does not.  It generates a trace from this same
# core, in the host's on-disk format, with a synthesised reset in front of it -
# then replays it.  A pass says the tool works: the reset is found, the vector
# located, the stack pointer recovered from both sides and compensated, the
# alignment right and every field decoded the way the host encodes it.
#
# It says NOTHING about whether the core is correct, because the core is on both
# sides of that comparison: one that drove the wrong address during a dummy cycle
# would emit that wrong address and then dutifully match it.  Only a capture of a
# real 65C02 can answer that, which is what sim/run_trace_replay.sh is for.
#
# The second half is the part that would otherwise go untested: a trace with one
# address deliberately corrupted must FAIL, at that word and no other.  A checker
# that cannot fail is not a checker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/trace_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

verilator --cc --exe --build -O2 -Wno-fatal --top-module cpu65c02 \
    -I"$root/rtl/common" -I"$root/rtl/a2" \
    -GUCODE_FILE="\"$root/rtl/a2/cpu65c02_ucode.hex\"" \
    -Mdir "$work/obj_dir" "$root/rtl/a2/cpu65c02.sv" "$root/sim/trace_replay_main.cpp" \
    -o trace_replay > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -20 "$work/verilator.log" >&2; exit 1; }

bin="$work/obj_dir/trace_replay"
good="$work/selftest.bustrace"
bad="$work/selftest_corrupt.bustrace"
fail=0

echo "=== 1. a trace this core generated must replay clean ==="
"$bin" --emit="$good" > /dev/null
if "$bin" --trace="$good" > "$work/selftest.log" 2>&1; then
    grep -E '^(stack|          this core|matched|compens)' "$work/selftest.log" || true
    echo "  PASS"
else
    cat "$work/selftest.log"
    echo "  FAIL: a self-generated trace did not replay clean" >&2
    fail=1
fi

echo
echo "=== 2. one corrupted address must be caught, at that word ==="
# Word 400 of the stream, past the reset preamble and well into the program.
# Flipping a bit in the address field is the exact shape of the bug this tool
# exists to find: right cycle, right direction, wrong address.
victim=400
python3 - "$good" "$bad" "$victim" <<'PY'
import struct, sys
src, dst, victim = sys.argv[1], sys.argv[2], int(sys.argv[3])
raw = open(src, 'rb').read()
head, body = raw[:32], bytearray(raw[32:])
off = victim * 8                                 # 64-bit records; the address is in word 0
w = struct.unpack_from('<I', body, off)[0]
struct.pack_into('<I', body, off, w ^ 0x0040)   # one bit of the address
open(dst, 'wb').write(head + bytes(body))
print(f"  corrupted record {victim}: word 0 {w:08x} -> {w ^ 0x0040:08x}")
PY
if "$bin" --trace="$bad" --quiet > "$work/selftest_corrupt.log" 2>&1; then
    cat "$work/selftest_corrupt.log"
    echo "  FAIL: the corrupted trace replayed clean - the checker cannot fail" >&2
    fail=1
else
    at=$(awk '/^diverged: at trace word/ {print $5}' "$work/selftest_corrupt.log")
    grep -E '^(diverged|          real)' "$work/selftest_corrupt.log" || true
    if [ "$at" = "$victim" ]; then
        echo "  PASS: caught at word $at, which is where it was planted"
    else
        echo "  FAIL: caught at word ${at:-none}, expected $victim" >&2
        fail=1
    fi
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "trace replay self-test: PASS"
else
    echo "trace replay self-test: FAIL" >&2
fi
exit "$fail"
