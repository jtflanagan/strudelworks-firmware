#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Assemble bustest, and put it on a bootable disk.
#
#   apple/build.sh              -> apple/build/bustest.bin and bustest.dsk
#
# THE DISK IS A REAL DOS 3.3 DISK, built by copying one and adding two files to
# it with a2kit.  An earlier version of this script hand-rolled the whole image
# - a boot sector of its own, plus a Python DOS 3.3 writer - which was correct
# but was reinventing a solved problem, and the boot sector in particular was
# 60 bytes of code that no Apple had ever run.  DOS has been booting since 1980.
#
# THE DOS IMAGE IS NOT IN THIS REPO, and that is the one thing this script
# cannot do for you.  DOS is Apple's code; this project fetches rather than
# vendors third-party code (see LICENSING.md) and Apple's is not fetchable.
# Drop any bootable DOS 3.3 image at the path below - an empty INITed disk is
# ideal, and a master with a do-nothing HELLO is what this was developed
# against.
#
# THE ASSEMBLER IS THE FIRST TEST.  --cpu 65SC02 is the base 65C02: the CMOS
# additions, and none of Rockwell's bit instructions.  It is not a formality -
# the chip this exercises does not have RMB/SMB/BBR/BBS, and picking the wrong
# CPU here would silently assemble instructions the hardware answers as NOPs.
#
# The page-crossing branches are checked the same way: apple/bustest.s carries
# .assert directives comparing the page of each branch target against the page
# of the instruction after the branch.  A layout edit that stopped a branch from
# crossing fails the build instead of quietly weakening the test.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
here="$root/apple"
out="$here/build"
# a2kit takes addresses in DECIMAL only - "0x6000" is a ParseIntError and
# "0x801" is an OutOfRange, both of which look like a broken disk rather than a
# broken argument. Kept alongside the hex so the two cannot drift.
LOAD_HEX=6000
LOAD_DEC=24576
BASIC_DEC=2049                  # $0801, where Applesoft programs start
BASE="${A2_DOS_MASTER:-$here/base/dos33_master.dsk}"

mkdir -p "$out"

for t in ca65 ld65 a2kit; do
    command -v "$t" >/dev/null || {
        echo "need $t on PATH" >&2
        [ "$t" = a2kit ] && echo "  cargo install a2kit" >&2
        exit 1; }
done

if [ ! -f "$BASE" ]; then
    cat >&2 <<MSG
No DOS 3.3 image at $BASE

Put a bootable DOS 3.3 disk image there, or point A2_DOS_MASTER at one.  It is
not in this repo because DOS is Apple's code, not ours to redistribute.  Any
INITed 143360-byte .dsk will do; the files this script adds are all it needs.
MSG
    exit 1
fi

# ---- assemble ---------------------------------------------------------------
# fill = no: the binary is the program and nothing after it.  With fill on the
# linker pads to the region size and DOS would store 13 KB of $EA.
cat > "$out/bustest.cfg" <<'CFG'
MEMORY { RAM: start = $6000, size = $3600, file = %O, fill = no; }
SEGMENTS { CODE: load = RAM, type = ro; }
CFG

ca65 --cpu 65SC02 -l "$out/bustest.lst" -o "$out/bustest.o" "$here/bustest.s"
ld65 -C "$out/bustest.cfg" -o "$out/bustest.bin" -m "$out/bustest.map" "$out/bustest.o"

size=$(stat -c %s "$out/bustest.bin")
printf 'bustest.bin  %s bytes, $%s..$%04X\n' "$size" "$LOAD_HEX" \
       $(( 0x$LOAD_HEX + size - 1 ))

# ---- the disk ---------------------------------------------------------------
cp "$BASE" "$out/bustest.dsk"

a2kit put -f BUSTEST -t bin -a "$LOAD_DEC" -d "$out/bustest.dsk" < "$out/bustest.bin"

# A greeting program, so booting the disk installs the exerciser without anyone
# having to type anything.  It only BRUNs it - see below for why that is not the
# same as running it.
a2kit delete -f HELLO -d "$out/bustest.dsk" 2>/dev/null || true
printf '10  PRINT CHR$(4)"BRUN BUSTEST"\n' \
    | a2kit tokenize -t atxt -a "$BASIC_DEC" \
    | a2kit put -f HELLO -t atok -d "$out/bustest.dsk"

# ---- read it back -----------------------------------------------------------
# Through DOS's own structures, by the tool that will not agree with itself by
# construction the way the hand-written writer and its hand-written verifier
# did.  If this does not match, the disk does not hold what was built.
a2kit get -f BUSTEST -t bin -d "$out/bustest.dsk" > "$out/readback.bin"
cmp "$out/readback.bin" "$out/bustest.bin" || {
    echo "FAIL: BUSTEST does not read back off the disk unchanged" >&2; exit 1; }
rm -f "$out/readback.bin"

echo
a2kit catalog -d "$out/bustest.dsk"
echo "  (BUSTEST reads back off the disk byte for byte)"

cat <<MSG

On the Apple:

    Boot it.  HELLO runs BRUN BUSTEST, which prints and returns to BASIC.
              Then press Ctrl-Reset.

BRUN only INSTALLS it - it points the reset vector at the exerciser and
returns.  Ctrl-Reset is what runs it, and that is deliberate: swhost's capture
arms on RES', so the trace has to begin at a reset or it begins from a state
nothing can reproduce.  One keystroke starts the recording and puts the machine
in a known state.
MSG
