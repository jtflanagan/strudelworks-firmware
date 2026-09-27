#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The 800K demo disk for GS/OS applications backed by RISC-V (docs/RVV2_INTEROP.md):
# a ProDOS volume /RVDEMO with a folder per application - the stub (an S16
# file, apple/rvvm/stub) and, beside it, the program and its resources.  Built
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

# The stub: position-independent, linked at 0, wrapped as a relocation-free S16.
printf 'MEMORY { S: start = $0000, size = $10000, file = %%O; }\nSEGMENTS { CODE: load = S, type = ro; }\n' > "$work/stub.cfg"
ca65 -o "$work/stub.o" "$root/apple/rvvm/stub/stub.s"
ld65 -C "$work/stub.cfg" -o "$work/stub.bin" "$work/stub.o"
python3 "$root/tools/omf_s16.py" "$work/stub.bin" "$work/SPLASH" > /dev/null

[ -x "$host/build-pi5/prodos_put" ] || { echo "no $host/build-pi5/prodos_put - cross-build the host first" >&2; exit 1; }
# A mounted image sits in disks/In Use (the host's own marker): refuse it.
if ssh $SSH_OPTS "$PI" "test -e '$PI_DIR/disks/In Use/$img'"; then
    echo "disks/$img is mounted by swhost (it is in disks/In Use) - stop swhost first" >&2; exit 1
fi
rsync -az -e "ssh $SSH_OPTS" "$host/build-pi5/prodos_put" "$work/SPLASH" "$PI:$PI_DIR/"
ssh $SSH_OPTS "$PI" "cd $PI_DIR && rm -f disks/$img && ./prodos_put disks/$img --format RVDEMO 1600 && \
    ./prodos_put disks/$img --mkdir / SPLASH && \
    ./prodos_put disks/$img SPLASH SPLASH B3 0000 SPLASH"
echo "disks/$img on the Pi: /RVDEMO/SPLASH/SPLASH (S16, $(stat -c %s "$work/stub.bin") bytes of stub)"
