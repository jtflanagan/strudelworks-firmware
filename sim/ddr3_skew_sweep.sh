#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# UBERDDR3.md rung 1: the DQS-versus-CK skew sweep in the Micron-model bench.
# Each point compiles sim/mem_ddr3_tb.sv with the write-direction skew
# (SW_WRITE_SKEW_PS: DQS and DQ late at the pins) or the clock skew
# (SW_CK_SKEW_PS: CK late = DQS early) and runs it long enough to calibrate,
# then prints one line: the skew, whether it calibrated and when, the
# controller's self-restarts and the state they came from, the DRAM's
# write-level answer per lane, and the model's tDQSS/tWLS/tWLH complaints.
#
#   sim/ddr3_skew_sweep.sh                 # DQS late 0..800 ps, CK late 200..800 ps
#   sim/ddr3_skew_sweep.sh 0 300 600       # DQS late at these ps
#   CK=1 sim/ddr3_skew_sweep.sh 300 600    # CK late (DQS early) at these ps
#   SECS=180 ...                           # per-point wall-clock bound (default 150)
#   ENFORCE=1 ...                          # a tDQSS violation costs the write (the card's failure)
#   PHASE=1 ...                            # CK_PHASE_SHIFT on: the controller walks CK under the feedback
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
uber="$root/third_party/UberDDR3"; tb="$uber/testbench"
work="$root/sim/suite_work/skew"; mkdir -p "$work"
secs="${SECS:-150}"
if [ $# -gt 0 ]; then pts=("$@"); elif [ "${CK:-0}" = 1 ]; then pts=(200 400 600 800); else pts=(0 200 400 600 800); fi
macro=SW_WRITE_SKEW_PS; [ "${CK:-0}" = 1 ] && macro=SW_CK_SKEW_PS
enforce=(); [ "${ENFORCE:-0}" = 1 ] && enforce=(-DSW_ENFORCE_TDQSS)   # the model's tDQSS violation costs the write (ddr3.sv)
phase=();   [ "${PHASE:-0}" = 1 ]   && phase=(-DSW_CK_PHASE_SHIFT)     # CK_PHASE_SHIFT: the controller walks CK's phase under the feedback (rung 2)
srcs=("$root/sim/mem_ddr3_tb.sv" "$root/rtl/common/tx_ring.sv" "$root/rtl/common/page_client.sv" "$root/rtl/common/msg_master.sv"
      "$root/rtl/common/wb_arb.sv" "$root/rtl/common/sync_fifo.sv" "$tb/ddr3.sv" "$tb"/models/*_model.v
      "$uber/rtl/ddr3_top.v" "$uber/rtl/ddr3_controller.v" "$uber/rtl/ddr3_phy.v")
one() {
    local ps="$1"
    local tag="${macro}_$ps${ENFORCE:+_enforce}${PHASE:+_phase}"
    local out="$work/$tag"
    iverilog -g2012 -o "$out.out" -s mem_ddr3_tb -DSIM_MODEL -DNO_TEST_MODEL -DCAL_TRACE -D"$macro=$ps" "${enforce[@]}" "${phase[@]}" \
        -I "$tb" "${srcs[@]}" > "$out.log" 2>&1 || { echo "$tag: COMPILE FAILED (see $out.log)"; return; }
    mkdir -p "$out.model"; rm -f "$out.model"/*   # the model's DRAM files, this point's own (see run_mem_ddr3_tb.sh)
    timeout "$secs" vvp -n "$out.out" +model_data+"$out.model" >> "$out.log" 2>&1
    rm -rf "$out.model"
    local cal rst st wl tdqss wls wlh fills park
    cal="$(grep -m1 -o 'calibrated at [0-9.]* ps' "$out.log" | sed 's/calibrated at //')"
    rst="$(grep -c 'CAL_TRACE reset_from' "$out.log")"
    st="$(grep 'CAL_TRACE state [0-9]* -> 0 ' "$out.log" | sed 's/.*state \([0-9]*\) -> 0.*/\1/' | sort | uniq -c | sort -rn | head -2 | awk '{printf "%s(x%s) ", $2, $1}')"
    wl="$(grep 'write_level_feedback' "$out.log" | head -2 | sed 's/.*lane=\([0-9]\) value=\([0-9]\) settled=\([0-9]\).*/L\1=\2\/\3/' | tr '\n' ' ')"
    tdqss="$(grep -c 'tDQSS violation' "$out.log")"; wls="$(grep -c 'tWLS violation' "$out.log")"; wlh="$(grep -c 'tWLH violation' "$out.log")"
    fills="$(grep -o 'FAIL: [0-9]* fill bytes' "$out.log" | head -1)"
    park="$(sed -n 's/.*ck_phase parked at step \([0-9]*\) of \([0-9]*\) (entered at \([0-9]*\)).*/\1\/\2 from \3/p' "$out.log" | tail -1)"
    printf '%-30s calibrated=%-14s restarts=%-4s from-state=%-11s WL=%-14s CKphase=%-12s tDQSS=%-5s %s\n' \
        "$tag" "${cal:-NO}" "$rst" "${st:-none}" "${wl:-none}" "${park:-off}" "$tdqss" "${fills:-}"
}
for p in "${pts[@]}"; do one "$p" & done
wait
