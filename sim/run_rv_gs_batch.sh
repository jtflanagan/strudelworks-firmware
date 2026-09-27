#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The RISC-V engine's batch on the GS bench (docs/REQ_RVVM.md): guests run
# through the whole card - the engine in gs_top, its 65816 VM (rvengine.s,
# bank $F1), L1-D, the TLB, page_cam and the stream - by sim/run_boot_gs_tb.sh
# --engine.  A guest passes when the bench says PASS: every check green (the
# read oracle, every engine write one 0xB record, the guest's own exit 0).
#
#   sim/run_rv_gs_batch.sh [--coremark] [NAME-FILTER]
#
# The riscv-tests binaries come from sim/run_rvvm_tests.sh's work directory
# (run it first); --coremark adds CoreMark (sim/run_rvvm_coremark.sh's
# binary) at --room=0, the performance setting.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests="$root/sim/rvvm_work/tests"
work="$root/sim/rvvm_work/gs_batch"
mkdir -p "$work"
cm=0; filter=""
for a in "$@"; do
    case "$a" in
        --coremark) cm=1 ;;
        *) filter="$a" ;;
    esac
done
"$root/sim/run_rvvm.sh" --build-only > /dev/null
vm="$root/sim/rvvm_work/rvengine.bin"

# Loads and stores of every width, both directions of every branch kind, the
# jumps, M, Zba/Zbb, fence.i over code the guest wrote, and a C program; then
# guests in the engine's upper 16 MB (NAME@LOAD), through the L2 like the rest.
guests=(rv32ui-add rv32ui-addi rv32ui-lw rv32ui-lh rv32ui-lhu rv32ui-lb rv32ui-lbu
        rv32ui-sw rv32ui-sh rv32ui-sb rv32ui-beq rv32ui-bltu rv32ui-jal rv32ui-jalr
        rv32ui-fence_i rv32um-mul rv32um-divu rv32uzba-sh2add rv32uzbb-rev8 rvvm-c-hello
        rvvm-hi_top@0x1800000 rvvm-c-pie@0x1800000)
# (hi_cross is not here: it straddles $0100_0000 from bank $FF, which on the IIgs
# is ROM - the flat-memory benches, run_rvvm_tests.sh, keep it)
pass=0; fail=0; failed=()
run() {   # name, binary, load address, extra runner args...
    local n="$1" bin="$2" at="$3"; shift 3
    [ -f "$bin" ] || { echo "no $bin (run sim/run_rvvm_tests.sh first)" >&2; exit 2; }
    local log="$work/$n.log"   # one tag: the card is built once and each guest read at run time
    "$root/sim/run_boot_gs_tb.sh" --engine="$vm" --guest="$bin" --guest-at="$at" --tag=rvb "$@" > "$log" 2>&1 || true
    if grep -q '^PASS$' "$log" && grep -q 'the guest exited 0 through the engine' "$log"; then
        pass=$((pass + 1)); printf "PASS %-20s %s\n" "$n" "$(grep -E 'clocks from the first step' "$log" | head -1 | sed 's/^ *//')"
    else
        fail=$((fail + 1)); failed+=("$n")
        printf "FAIL %-20s %s\n" "$n" "$(grep -E '^FAIL|rror|exit|trap' "$log" | head -3 | tr '\n' ' ')"
    fi
}
for g in "${guests[@]}"; do
    n="${g%@*}"; at=0x020000; [ "$g" != "$n" ] && at="${g#*@}"
    [ -n "$filter" ] && [[ "$n" != *"$filter"* ]] && continue
    tag="$n"; [ "$at" != 0x020000 ] && tag="$n@$at"
    run "$tag" "$tests/$n.bin" "$at" --instrs=20000000
done
if [ $cm = 1 ]; then
    run coremark "$root/sim/rvvm_work/coremark/coremark.bin" 0x020000 --room=0 --instrs=2000000000 --clks=2000000000
    grep -E 'crcfinal|clocks from the first step' "$work/coremark.log" || true
fi
echo "$pass passed, $fail failed${failed:+: ${failed[*]}}"
[ $fail = 0 ]
