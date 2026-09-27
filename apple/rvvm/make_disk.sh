#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The 800K demo disk for GS/OS applications backed by RISC-V (docs/RVV2_INTEROP.md):
# a ProDOS volume /RVDEMO with a folder per application (SPLASH, RVTEST) - the
# stub (an S16 file, apple/rvvm/stub) and, beside it, the program (APP.RV, type
# $06) and its resources.  Built
# ON THE PI with the host's prodos_put (the host's cross-build), into its
# disks/ directory, where a conf mounts it on the 3.5" drive (`fd35 =`).
#
# Never run while swhost has the image mounted (prodos_put's own rule): the
# machine's cached directory would not know.
#
#   apple/rvvm/make_disk.sh [IMAGE, default rvdemo.po]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
host="$root/../strudelworks-host"
. "$host/tools/pi5.env"
img="${1:-rvdemo.po}"
work="$root/sim/rvvm_work/disk"
mkdir -p "$work"

# The applications, a folder each: the stub as an S16, the program, its resources
# (apple/rvvm/build_app.sh; APP.res names them).
apps=(splash rvtest)
for a in "${apps[@]}"; do "$root/apple/rvvm/build_app.sh" "$a" "$work/$a"; done

[ -x "$host/build-pi5/prodos_put" ] || { echo "no $host/build-pi5/prodos_put - cross-build the host first" >&2; exit 1; }
# A mounted image sits in disks/In Use (the host's own marker): refuse it.
if ssh $SSH_OPTS "$PI" "test -e '$PI_DIR/disks/In Use/$img'"; then
    echo "disks/$img is mounted by swhost (it is in disks/In Use) - stop swhost first" >&2; exit 1
fi
cmds="rm -f disks/$img && ./prodos_put disks/$img --format RVDEMO 1600"
summary=""
for a in "${apps[@]}"; do
    up="$(echo "$a" | tr a-z A-Z)"
    cmds="$cmds && ./prodos_put disks/$img --mkdir / $up"
    cmds="$cmds && ./prodos_put disks/$img $up $up B3 0000 rvdisk/$up/$up"
    cmds="$cmds && ./prodos_put disks/$img $up $up.RV 06 0000 rvdisk/$up/$up.RV"
    res=()
    while read -r f; do [ -n "$f" ] && res+=("$f"); done < "$work/$a/$up.res"
    for f in "${res[@]}"; do
        cmds="$cmds && ./prodos_put disks/$img $up $f 06 0000 rvdisk/$up/$f"
    done
    summary="$summary /RVDEMO/$up/{$up,$up.RV${res[*]:+,${res[*]}}}"
done
ssh $SSH_OPTS "$PI" "cd $PI_DIR && rm -rf rvdisk && mkdir -p rvdisk $(for a in "${apps[@]}"; do echo -n "rvdisk/$(echo "$a" | tr a-z A-Z) "; done)"
rsync -az -e "ssh $SSH_OPTS" "$host/build-pi5/prodos_put" "$PI:$PI_DIR/"
for a in "${apps[@]}"; do
    up="$(echo "$a" | tr a-z A-Z)"
    rsync -az -e "ssh $SSH_OPTS" "$work/$a/$up" "$work/$a/$up.RV" $(sed "s#^#$work/$a/#" "$work/$a/$up.res") "$PI:$PI_DIR/rvdisk/$up/"
done
ssh $SSH_OPTS "$PI" "cd $PI_DIR && $cmds"
echo "disks/$img on the Pi:$summary"
