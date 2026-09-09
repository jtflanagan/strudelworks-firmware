#!/bin/bash
# Produce a deterministic KEGS reference trace of the GS ROM booting with no
# disks (tools/kegs/README.md).  Needs the patched xkegs (kegs-1.38-trace.patch).
#
#   tools/kegs/trace_rom.sh OUT.bin [N_INSTRUCTIONS] [ROM]
#
# Defaults: 5,000,000 instructions, ../strudelworks-host/assets/apple2gs_rom3.bin.
# The clock is pinned to 2026-09-08 12:00:00 (seconds since 1904) so the ROM's
# clock reads are the same every run; BRAM starts all zero (no bram lines).
set -e
FW=/home/flana/repos/strudelworks-firmware
KEGS=/home/flana/repos/kegs.1.38
OUT=${1:?OUT.bin}
N=${2:-5000000}
ROM=${3:-/home/flana/repos/strudelworks-host/assets/apple2gs_rom3.bin}
PIN=3871713600   # 2026-09-08 12:00:00 since 1904-01-01 (python: datetime(2026,9,8,12)-datetime(1904,1,1))
WORK=$(mktemp -d)
cat > "$WORK/trace.kegs" <<CFG
# KEGS configuration file version 1.07
g_cfg_rom_path = $ROM
g_limit_speed = 2
CFG
cd "$WORK"
timeout 600 "$KEGS/xkegs" -cfg "$WORK/trace.kegs" -trace "$OUT" -tracemax "$N" -pintime $PIN -audio 0 > "$WORK/xkegs.log" 2>&1 || true
grep -E 'trace:|Found ROM|Read:|Patching' "$WORK/xkegs.log" || tail -5 "$WORK/xkegs.log"
ls -l "$OUT"
