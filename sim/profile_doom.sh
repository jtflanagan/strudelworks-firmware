#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Where DOOM's engine cycles go (docs/RVV2_DOOM.md): DOOM built to warp
# straight into E1M1 (DOOM_PROFILE=warp, its music playing) - or, with --demo,
# to play DEMO1 as fast as it draws (-timedemo: a tic a frame, no cap, the
# scenes the demo walks through) with every frame's cycles logged - run on the application
# bench (sim/run_rv_app.sh's runner: the card's engine and 65816, GS/OS's
# stand-in) and every clock from --from on charged to the oldest instruction
# not yet retired (the runner's --profile) - its stalls and the 65816's service
# of its events included - then summed by function from the ELF's symbols.
# The run ends at --to (DOOM never quits: the runner reports a runaway, as it
# should for any program that does not).
#
#   sim/profile_doom.sh [--demo] [--from=CYCLES] [--to=CYCLES] [--top=N]
#   defaults: from 500M (E1M1 playing) to 800M (3 s of the card's time);
#   --demo: from 400M to 1000M, and the frames' cycles (the median, the slowest)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
from=500000000; to=800000000; top=40; build=warp; from_set=; to_set=
for a in "$@"; do
    case "$a" in
        --demo)   build=timedemo;;
        --from=*) from="${a#--from=}"; from_set=1;;
        --to=*)   to="${a#--to=}"; to_set=1;;
        --top=*)  top="${a#--top=}";;
        *) echo "usage: profile_doom.sh [--demo] [--from=CYCLES] [--to=CYCLES] [--top=N]" >&2; exit 2;;
    esac
done
if [ $build = timedemo ]; then [ -n "$from_set" ] || from=400000000; [ -n "$to_set" ] || to=1000000000; fi
work="$root/sim/rvvm_work/profile"
mkdir -p "$work"
run="$root/sim/rvvm_work/app/obj/rvvm_run"
"$root/sim/run_rv_app.sh" nosuchapp > /dev/null 2>&1 || true     # builds the runner (and the runtime) if stale
[ -x "$run" ] || { echo "no runner at $run" >&2; exit 1; }
DOOM_PROFILE=$build "$root/apple/rvvm/build_app.sh" doom "$work"
files=()
while read -r f; do [ -n "$f" ] && files+=(--file="9:$f=$work/$f"); done < "$work/DOOM.res"
"$run" --hex="$root/rtl/gs/cpu65816_ucode.hex" --vm="$root/sim/rvvm_work/rvengine.bin" --app="$work/DOOM.stub" \
    --image="$work/DOOM.RV" "${files[@]}" --max-cycles="$to" --profile="$work/doom.prof" --profile-from="$from" --frame-log="$work/frames.log" \
    < /dev/null > "$work/doom.log" 2>&1 || true
grep -E "^app: (profile|[0-9]+M cycles)" "$work/doom.log" | tail -4
[ -s "$work/doom.prof" ] || { echo "no profile (see $work/doom.log)" >&2; exit 1; }
llvm-nm -n --defined-only "$work/DOOM.RV.elf" > "$work/doom.nm"
python3 - "$work/doom.prof" "$work/doom.nm" "$top" <<'EOF'
import bisect, sys
prof, nm, top = sys.argv[1], sys.argv[2], int(sys.argv[3])
syms = []
for line in open(nm):
    p = line.split()
    if len(p) == 3 and p[1] in 'tTwW':
        syms.append((int(p[0], 16), p[2]))
syms.sort()
addrs = [a for a, _ in syms]
head = open(prof).readline().split()
total, base = int(head[2]), int(head[4], 16)
by = {}
for line in open(prof):
    if line.startswith('#'): continue
    pc, n = line.split(); pc = int(pc, 16); n = int(n)
    off = pc - base
    if off < 0 or off >= 0x1000000:
        name = '(outside the program: the runtime, idle)'
    else:
        i = bisect.bisect_right(addrs, off) - 1
        name = syms[i][1] if i >= 0 else '(before the first symbol)'
    by[name] = by.get(name, 0) + n
print(f"{total} cycles ({total / 1e8:.2f} s of the card), {' '.join(head[5:])}")
for name, n in sorted(by.items(), key=lambda e: -e[1])[:top]:
    print(f"{100 * n / total:6.2f}%  {n:>11}  {name}")
EOF
# The frames inside the window: each one's cycles, at the card's 100 MHz.
python3 - "$work/frames.log" "$from" <<'EOF'
import sys
f = [tuple(map(int, l.split())) for l in open(sys.argv[1]) if l.strip()]
f = [(n, at, c) for n, at, c in f if at >= int(sys.argv[2]) and n > 1]
if not f: sys.exit()
cs = sorted(c for _, _, c in f)
ms = lambda c: c / 1e5
print(f"frames in the window: {len(f)}, median {ms(cs[len(cs)//2]):.1f} ms ({1e8/cs[len(cs)//2]:.1f} fps), "
      f"90th {ms(cs[int(len(cs)*0.9)]):.1f} ms, worst {ms(cs[-1]):.1f} ms")
for lo, hi in ((0, 28.6), (28.6, 33.3), (33.3, 40), (40, 50), (50, 1e9)):
    k = sum(1 for c in cs if lo <= ms(c) < hi)
    print(f"  {lo:5.1f}-{hi if hi < 1e8 else 'up':>5} ms: {k:4d} frames")
print("the slowest: " + ", ".join(f"#{n} {ms(c):.1f} ms" for n, _, c in sorted(f, key=lambda e: -e[2])[:8]))
EOF
