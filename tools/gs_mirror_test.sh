#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The host's mirror against the card's memory, on a real IIgs boot.
#
#   tools/gs_mirror_test.sh [--instrs=N] [--hdv=FILE]
#
# Runs sim/boot_gs_tb.sv with --mirror, which writes every retired op in the
# host's own record shape and the physical pages the machine wrote; ships both
# to the Pi with the host's gs_replay_test; and replays the one against the
# other.  The sweeps on either side argue a model against a model - this holds
# both maps to a boot that actually happened.
#
# The op stream is tens of megabytes and is not kept: it lives in
# sim/mirror_work and goes to the Pi's /tmp.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="$root/../strudelworks-host"
work="$root/sim/mirror_work"
# The Pi is the host repo's, and named there once: never a second copy of
# the address and the user (strudelworks-host tools/pi5.env).
. "$host/tools/pi5.env"

instrs=700000
hdv=""
for a in "$@"; do
    case "$a" in
        --instrs=*) instrs="${a#*=}" ;;
        --hdv=*) hdv="${a#*=}" ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done
if [ -z "$hdv" ] && [ -f "$root/sim/images.local" ]; then
    hdv="$(grep -v '^#' "$root/sim/images.local" | head -1)"
fi

bin="$host/build-pi5/gs_replay_test"
[ -f "$bin" ] || { echo "no $bin - cross-build the host first" >&2; exit 2; }

rm -rf "$work"; mkdir -p "$work"
echo "== the IIgs boots, and every op it retires is written down"
"$root/sim/run_boot_gs_tb.sh" --instrs="$instrs" --clks=$((instrs * 45)) \
    --tag=mirror --ref=none --bram=6,7 --mirror="$work" \
    ${hdv:+--hdv="$hdv"} | grep -E "mirror's side|checks,|^PASS|^FAIL" || true

echo "== the host's mirror replays it on the Pi"
ssh $SSH_OPTS "$PI" "mkdir -p /tmp/swmirror"
rsync -az -e "ssh $SSH_OPTS" "$work/ops.bin" "$work/pages.bin" "$bin" "$PI:/tmp/swmirror/"
ssh $SSH_OPTS "$PI" "cd /tmp/swmirror && ./gs_replay_test ops.bin pages.bin"
