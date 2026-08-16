#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Hold the pipelined 65816 sequencer to the straightforward one it replaced.
# ~40 s.
#
# The decode-once rewrite changes WHEN the microcode is read and WHEN a
# condition is evaluated, and nothing about what the machine should do.  That is
# invisible to sim/gen_cycle_table816.py, which walks the microcode IMAGE - an
# image the rewrite does not touch - so that check passes whether the RTL
# pipeline is right or not.  This is the test that actually covers it.
#
# The reference is whatever the branch had before the rewrite, taken straight
# from git rather than kept as a second copy in the tree, so it cannot rot and
# cannot silently drift into agreeing.
#
# It earned its place immediately: it found two bugs the static audit could not.
# The dispatch hardcoded slot 1 as the successor of an opcode fetch, when slot
# 0's own condition may skip it - EOR # in 8-bit mode is three cycles instead of
# two.  And the branch condition read ir[7:6], which during a fetch cycle still
# holds the PREVIOUS opcode, so branches resolved against the wrong instruction.
# Both are one-cycle errors in 1 opcode of 256, invisible to anything coarser.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/cpu816_work"
mkdir -p "$work"

# The reference core: the last commit before the pipelined sequencer landed.
REF_REV="${REF_REV:-ucode-816-prepipeline}"
if ! git -C "$root" rev-parse --verify -q "$REF_REV^{commit}" >/dev/null; then
    echo "No reference revision '$REF_REV'." >&2
    echo "Set REF_REV to a commit whose rtl/cpu65816.sv predates the pipeline." >&2
    exit 1
fi
git -C "$root" show "$REF_REV:rtl/cpu65816.sv" \
    | sed 's/module cpu65816/module cpu65816_ref/' > "$work/cpu65816_ref.sv"

python3 "$root/sim/gen_microcode816.py" --check

rm -f "$work/equiv.out"
if ! iverilog -g2012 -I "$root/rtl" -o "$work/equiv.out" -s cpu816_equiv_tb \
        -Pcpu816_equiv_tb.UCODE="\"$root/rtl/cpu65816_ucode.hex\"" \
        -Pcpu816_equiv_tb.UCODE0="\"$root/rtl/cpu65816_ucode0.hex\"" \
        -Pcpu816_equiv_tb.USEQ0="\"$root/rtl/cpu65816_useq0.hex\"" \
        "$root/sim/cpu816_equiv_tb.sv" "$root/rtl/cpu65816.sv" \
        "$work/cpu65816_ref.sv" > "$work/equiv_build.log" 2>&1; then
    grep -vE "sorry: constant selects|cannot be synthesized" \
        "$work/equiv_build.log" >&2
    echo "compile failed" >&2
    exit 1
fi

exec vvp -n "$work/equiv.out"
