#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Klaus Dormann's functional suites, run on rtl/a2/cpu65c02.sv.  ~15 s.
#
# Both suites matter and they are not disjoint.  The 65C02 suite covers the
# instructions the CMOS part added; the NMOS suite hammers corner cases in the
# instructions BOTH parts share - flag edges, page wraps, indexing, BCD - and the
# 65C02 still has to get all of those right.  A core that passes only the 65C02
# suite has not been tested on most of its own opcodes.
#
# The 65C02 suite is re-assembled for the BASE part before it runs: upstream
# ships it with Rockwell's bit instructions fully tested, and this core does not
# have them.  See third_party/build_base_65c02_test.sh.
#
# The NMOS suite is safe to run on a CMOS part because it tests documented
# behaviour only: it uses no undocumented opcodes, and it explicitly ignores
# N, V and Z after decimal arithmetic - precisely where the two parts disagree.
# The other CMOS divergences (the JMP ($xxFF) page-wrap bug, the RMW dummy write)
# are NMOS bugs, so a documented-behaviour test does not depend on them either.
#
# Verilated rather than run under iverilog, which is the default everywhere else
# in this project.  Measured, on this machine: the 6502 suite is ~96 million bus
# cycles, 7.8 s Verilated and about 26 minutes under iverilog.  The core is still
# covered by both simulators - sim/run_cpu_cycles_tb.sh is iverilog - so nothing
# is lost by not having a second, unusably slow copy of this same memory model.
#
# A failing run prints the trap address and the source around it.  That lookup is
# the whole debugging loop for this core: "FAIL trap $1b2c" is useless on its own
# and completely specific once the listing names the instruction under test.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests="$root/third_party/6502_tests/bin_files"
work="$root/sim/cpu_work"

if [ ! -d "$tests" ]; then
    echo "Test images missing.  Run third_party/fetch_6502_tests.sh first." >&2
    exit 1
fi

mkdir -p "$work"

# The generated microcode must match its generator, or the ROM and the datapath
# are describing different machines.  Same contract as gen_ddr3_xdc.py --check.
python3 "$root/sim/gen_microcode.py" --check

# The microcode ROM is loaded by $readmemh at elaboration, so its path has to
# be absolute - the simulator's working directory is not the RTL's directory.
verilator --cc --exe --build -O2 -Wno-fatal --top-module cpu65c02 \
    -I"$root/rtl/common" -I"$root/rtl/a2" \
    -GUCODE_FILE="\"$root/rtl/a2/cpu65c02_ucode.hex\"" \
    -Mdir "$work/obj_dir" "$root/rtl/a2/cpu65c02.sv" "$root/sim/cpu65c02_main.cpp" \
    -o cpu65c02_sim > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -20 "$work/verilator.log" >&2; exit 1; }

# The trap addresses are read out of the listings rather than hard-coded: they
# move whenever upstream re-assembles, and a stale "expected success address"
# would turn into a green run that proves nothing.  In both listings the success
# trap is the `jmp *` right after the "S U C C E S S" banner.
find_success() {
    awk '/S U C C E S S/ {hot=1; next}
         hot && /^[0-9a-f]{4} :/ {print substr($0,1,4); exit}' "$1"
}

run_one() {
    local name="$1" start="$2" dir="${3:-$tests}"
    local bin="$dir/$name.bin" lst="$dir/$name.lst"
    local hex="$work/$name.hex" success rc=0 out trap line

    success="$(find_success "$lst")"
    [ -n "$success" ] || { echo "could not find success trap in $lst" >&2; exit 1; }

    # $readmemh-style text, one byte per line.
    od -An -v -tx1 -w1 "$bin" | tr -d ' ' > "$hex"

    echo "=============================================================="
    out="$("$work/obj_dir/cpu65c02_sim" --hex="$hex" --start="$start" --success="$success")" || rc=$?
    echo "$out"
    [ $rc -eq 0 ] && return 0

    trap="$(sed -n 's/^TRAP=//p' <<<"$out")"
    if [ -n "$trap" ] && [ "$trap" != "none" ] && [ "$trap" != "stp" ]; then
        echo
        echo "--- $name.lst around \$$trap ---------------------------------"
        # The instruction under test is ABOVE the trap, not at it.
        line="$(grep -n -m1 "^$trap :" "$lst" | cut -d: -f1 || true)"
        if [ -n "$line" ]; then
            sed -n "$((line > 24 ? line - 24 : 1)),$((line + 2))p" "$lst"
        else
            echo "(address not found in listing)"
        fi
    fi
    return 1
}

# The 65C02 suite is RE-ASSEMBLED rather than taken as shipped.  Upstream's
# prebuilt binary fully tests Rockwell's BBR/BBS/RMB/SMB, and this core is a
# base 65C02 that has none of them - see rtl/a2/cpu65c02.sv's VARIANT note.  Built
# with those switches at 0, the suite tests those encodings AS NOPs, which is
# the stronger check: it would catch a core that implemented them anyway.
base_dir="$root/sim/cpu_work/base_test"
if [ ! -f "$base_dir/65C02_base_opcodes_test.bin" ]; then
    bash "$root/third_party/build_base_65c02_test.sh"
fi

fail=0
run_one 6502_functional_test      0400 || fail=1
run_one 65C02_base_opcodes_test   0400 "$base_dir" || fail=1

echo "=============================================================="
if [ $fail -eq 0 ]; then echo "both suites passed"; else echo "FAILURES"; fi
exit $fail
