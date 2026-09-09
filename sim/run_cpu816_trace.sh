#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# cpu65816 against SingleStepTests/65816, instruction by instruction: every
# cycle's address, direction and data, the cycle count, the final registers and
# memory.  See sim/cpu816_trace_main.cpp for the contract.
#
#   sim/run_cpu816_trace.sh                    # every sampled opcode, both modes
#   sim/run_cpu816_trace.sh --opcodes ea,a9    # a subset
#   sim/run_cpu816_trace.sh --limit 200        # tests per opcode file
#   sim/run_cpu816_trace.sh --flags            # also compare vda/vpa/vpb
#
# Needs sim/fetch_65816_tests.sh's samples (sim/cpu816_work/samples).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/cpu816_work"
mkdir -p "$work"
[ -d "$work/samples" ] || { echo "No samples: run sim/fetch_65816_tests.sh first" >&2; exit 1; }

opcodes=""; limit=0; flags=""; detail=3
while [ $# -gt 0 ]; do
    case "$1" in
        --opcodes) opcodes="$2"; shift 2;;
        --limit) limit="$2"; shift 2;;
        --flags) flags="--flags"; shift;;
        --detail) detail="$2"; shift 2;;
        *) echo "unknown argument $1" >&2; exit 1;;
    esac
done

python3 "$root/sim/gen_microcode816.py" --check

verilator --cc --exe --build -O2 -Wno-fatal --public-flat-rw --top-module cpu65816 \
    -I"$root/rtl" \
    -GUCODE_FILE="\"$root/rtl/cpu65816_ucode.hex\"" \
    -GUCODE0_FILE="\"$root/rtl/cpu65816_ucode0.hex\"" \
    -GUSEQ0_FILE="\"$root/rtl/cpu65816_useq0.hex\"" \
    -Mdir "$work/obj_trace" "$root/rtl/cpu65816.sv" "$root/sim/cpu816_trace_main.cpp" \
    -o cpu816_trace > "$work/verilator_trace.log" 2>&1 || {
        echo "build failed:" >&2; tail -30 "$work/verilator_trace.log" >&2; exit 1; }

pack=("$work/tests.bin")
[ -n "$opcodes" ] && pack+=(--opcodes "$opcodes")
[ "$limit" != 0 ] && pack+=(--limit "$limit")
python3 "$root/sim/cpu816_tests.py" "${pack[@]}"

"$work/obj_trace/cpu816_trace" --tests="$work/tests.bin" --hex="$root/rtl/cpu65816_ucode.hex" \
    --detail="$detail" $flags
