#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Re-assemble Klaus Dormann's 65C02 suite for the BASE part.
#
# WHY THIS EXISTS.  Upstream ships a prebuilt binary assembled with
# `rkwl_wdc_op = 1`, which FULLY TESTS Rockwell's BBR/BBS/RMB/SMB.  The chip in
# the machine this core stands in for is a first-generation 65C02 and has none
# of them, so that binary tests instructions the part does not have and would
# fail on a core that is correct.
#
# The suite already knows about this: both switches take 0 to mean "test these
# encodings AS NOPs".  That is a stronger check than skipping them, because a
# core that quietly implemented RMB would now be caught - the NOP test asserts
# that $x7 changes nothing.
#
#   wdc_op      = 0   test WAI/STP as NOPs   (was 1: do not test at all)
#   rkwl_wdc_op = 0   test BBR/BBS/RMB/SMB as NOPs   (was 1: full test)
#
# The output is NOT committed.  Klaus's sources are GPL-3.0 and this project
# fetches rather than vendors them - see LICENSING.md - and an assembled image
# of GPL-3 source is still GPL-3 source.
#
# THE ASSEMBLER is Frank Kingswood's as65, which upstream ships in
# as65_142.zip and which Klaus declines to move away from.  The zip carries a
# 32-bit Linux ELF and a Win32 exe; the ELF needs an i386 runtime that a modern
# amd64 install usually lacks, so this falls back to running the exe through
# WSL's Windows interop.  If neither works, this says so rather than leaving a
# stale binary in place to be mistaken for a fresh one.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
src="$here/6502_tests/65C02_extended_opcodes_test.a65c"
zip="$here/6502_tests/as65_142.zip"
work="$root/sim/cpu_work/base_test"
name="65C02_base_opcodes_test"

[ -f "$src" ] || { echo "no $src - run third_party/fetch_6502_tests.sh first" >&2; exit 1; }

mkdir -p "$work"
python3 - "$zip" "$work" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
for n in ("as65", "as65.exe"):
    if n in z.namelist():
        z.extract(n, sys.argv[2])
PY
chmod +x "$work/as65" "$work/as65.exe" 2>/dev/null || true

cd "$work"

# Probed by its banner, not by its exit status: run with no arguments as65
# prints usage and exits NONZERO, so a `cmd >/dev/null 2>&1` test rejects a
# perfectly working assembler.  Captured rather than piped, because
# `set -o pipefail` would fail the pipeline on that same nonzero exit.
runs() {
    local out
    out="$("$1" 2>&1 || true)"
    [[ "$out" == *"AS65 Assembler"* ]]
}

if [ -x "./as65" ] && runs "./as65"; then
    AS65="./as65"
elif [ -x "./as65.exe" ] && runs "./as65.exe"; then
    AS65="./as65.exe"
else
    cat >&2 <<'MSG'
ERROR: cannot run as65.

  The Linux build in as65_142.zip is a 32-bit ELF and needs an i386 runtime:
      sudo dpkg --add-architecture i386 && sudo apt install libc6:i386
  On WSL the bundled as65.exe runs through Windows interop instead.
MSG
    exit 1
fi

# ---------------------------------------------------------------------------
# The image builder, and a control that proves it.
#
# as65's own .bin begins at the LOWEST used address and fills gaps with $ff,
# which is not a 64 KiB memory image and silently shifts everything by $0a if
# you treat it as one.  So the addressed Intel-hex output (-s2) is used instead
# and the image is assembled here.
#
# THE CONTROL comes first: assemble upstream's configuration UNCHANGED and
# require it to reproduce upstream's prebuilt binary byte for byte.  If that
# holds, the assembler, the flags and the image builder are all faithful, and
# the variant build below differs from upstream only by the two switches.
# Without it a wrong flag would produce a subtly different test, which would
# fail, and the failure would be blamed on the core.
# ---------------------------------------------------------------------------
mkimage() {   # $1 = .hex in, $2 = .bin out
    python3 "$here/ihex_to_image.py" "$1" "$2"
}

assemble() {  # $1 = source basename, no extension
    # -x is 65SC02 extensions: the base CMOS set, which is precisely the variant
    # wanted here.  Without it the (zp) modes and JMP (abs,X) do not assemble.
    "$AS65" -l -m -w -h0 -x -q -s2 "$1.a65c" 2>&1 | grep -vE '^AS65|^Reading line' || true
    [ -s "$1.hex" ] || { echo "ERROR: as65 produced no hex for $1" >&2; exit 1; }
    mkimage "$1.hex" "$1.bin"
}

upstream_bin="$here/6502_tests/bin_files/65C02_extended_opcodes_test.bin"
if [ -f "$upstream_bin" ]; then
    cp "$src" "$work/control.a65c"
    assemble control
    if cmp -s "$work/control.bin" "$upstream_bin"; then
        echo "  control: reproduces upstream's prebuilt image byte for byte"
    else
        echo "ERROR: assembling upstream's OWN configuration does not reproduce their" >&2
        echo "       binary, so the toolchain is not faithful and the variant build" >&2
        echo "       below cannot be trusted either." >&2
        cmp -l "$work/control.bin" "$upstream_bin" 2>/dev/null | head -5 >&2
        exit 1
    fi
else
    echo "  control: skipped, no upstream binary to compare against"
fi

# Flip the two switches, and nothing else.  A sed rather than a patch file
# because a patch would rot against any upstream edit near those lines, and
# these two assignments are the whole change.
sed -e 's/^wdc_op = 1/wdc_op = 0/' \
    -e 's/^rkwl_wdc_op = 1/rkwl_wdc_op = 0/' "$src" > "$work/$name.a65c"
for want in 'wdc_op = 0' 'rkwl_wdc_op = 0'; do
    grep -qx "$want" "$work/$name.a65c" || {
        echo "ERROR: '$want' not set - upstream's switches have moved" >&2; exit 1; }
done

assemble "$name"
cp "$work/$name.lst" "$work/$name.lst" 2>/dev/null || true
printf '  %-32s %s bytes\n' "$name.bin" "$(stat -c %s "$work/$name.bin")"
echo "built for the base 65C02: BBR/BBS/RMB/SMB and WAI/STP tested as NOPs"
