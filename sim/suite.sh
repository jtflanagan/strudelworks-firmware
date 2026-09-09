#!/usr/bin/env bash
# strudelworks-firmware
# SPDX-License-Identifier: GPL-2.0-or-later
#
# The named compositions of sim/run_*.sh that the docs describe in prose
# (docs/DLINE.md "Phasing and proof", docs/BOOT_BENCH.md), as one command:
#
#   sim/suite.sh quick      lint + microcode check + every bench under ~10 s      (~1 min)
#   sim/suite.sh cpu        cpu_tb, cpu_cycles, cpu_irq, cpu_predict                 (~2 min)
#   sim/suite.sh battery    quick + accel_vl + mem_integ + page_cache + fb_sim_vl    (~8 min)
#   sim/suite.sh boot       run_boot_tb.sh --verilator per image, in parallel        (~4 min)
#   sim/suite.sh gs         the 65816: microcode check, cycle table, SingleStepTests
#                           sample, the GS map sweep, the GS ROM boot         (~5 min)
#   sim/suite.sh all        battery + cpu + boot
#
#   --iverilog      add the iverilog accel battery (run_accel_tb.sh, ~2 min) - the
#                   rung gate wants both simulators; the everyday loop is Verilator-first
#   --images=A,B    the boot images (else $BOOT_IMAGES, else sim/images.local, one path
#                   per line; never hard-coded, per BOOT_BENCH.md)
#
# Each bench logs to sim/suite_work/<bench>.log (prints "== running <bench> ->
# <log>" first, so sim/progress.sh can follow the live one) and is judged by
# its own PASS contract.  Ends with "SUITE <name>: N/N PASS" or the FAIL list.
# Exit 0 all PASS, 1 otherwise.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/sim/suite_work"
mkdir -p "$work"
suite="${1:-}"; shift || true
iverilog=0; images=""
for a in "$@"; do case "$a" in --iverilog) iverilog=1;; --images=*) images="${a#*=}";; esac; done
[ -n "$suite" ] || { sed -n 5,25p "$0"; exit 1; }
cd "$root"

# bench name -> "script|PASS regex"
declare -A B=(
  [lint]="sim/lint.sh|^(lint clean|all OK)|LINTEXIT"
  [microcode]="python3 sim/gen_microcode.py --check|microcode up to date"
  [microcode816]="python3 sim/gen_microcode816.py --check|microcode up to date"
  [adb_keymap]="python3 tools/gen_adb_keymap.py --check|ADB keymap up to date"
  [cpu816_cycles]="python3 sim/gen_cycle_table816.py|every observed cycle count is reachable"
  [cpu816_trace]="sim/run_cpu816_trace.sh --limit 400 --flags|^PASS$"
  [boot_hold]="sim/run_boot_hold_tb.sh|^PASS$"
  [bus_event_filter]="sim/run_bus_event_filter_tb.sh|^PASS$"
  [bus_snoop]="sim/run_bus_snoop_tb.sh|^PASS$"
  [bus_write]="sim/run_bus_write_tb.sh|^PASS$"
  [bustest]="sim/run_bustest.sh|^PASS: bustest"
  [cpu_cycles]="sim/run_cpu_cycles_tb.sh|checks, 0 failures"
  [cpu_irq]="sim/run_cpu_irq_tb.sh|^PASS$"
  [floppy_card]="sim/run_floppy_card_tb.sh|^PASS$"
  [ft601_fifo]="sim/run_ft601_fifo_tb.sh|^PASS: "
  [ft601_msg]="sim/run_ft601_msg_tb.sh|^PASS$"
  [ft601_msg_rx]="sim/run_ft601_msg_rx_tb.sh|^PASS$"
  [hd_card]="sim/run_hd_card_tb.sh|^PASS$"
  [kbd_inject]="sim/run_kbd_inject_tb.sh|^PASS$"
  [mockingboard]="sim/run_mockingboard_tb.sh|^PASS$"
  [audio]="sim/run_audio_vl.sh|^PASS$"
  [mouse_card]="sim/run_mouse_card_tb.sh|^PASS$"
  [msg_arb]="sim/run_msg_arb_tb.sh|^PASS$"
  [no_slot_clock]="sim/run_no_slot_clock_tb.sh|^PASS: "
  [reg_map]="sim/run_reg_map_tb.sh|^PASS$"
  [mmu_xlate]="sim/run_mmu_xlate_tb.sh +quick|^PASS$"
  [mmu_xlate_gs]="sim/run_mmu_xlate_gs_tb.sh +quick|^PASS$"
  # The GS ROM booting against the KEGS trace, with the floor the last rung
  # reached pinned (docs/GS.md rung 3): the run FAILS if the two part company
  # sooner.  41,877 at the end of 3a; 66,749 once gs_io answered the ADB micro
  # and the map's own registers; 67,398 once the clock chip did.  Raise it
  # whenever a rung moves it - AND THE
  # RUN LENGTH WITH IT: the floor is in events and --instrs is in
  # instructions, so a run that stops short fails as "below floor" for want of
  # length rather than for want of agreement.  67,398 events is card
  # instruction 202,326.
  # It needs sim/boot_work/rom3.kegs.trc - tools/kegs/trace_rom.sh makes it -
  # and without one the bench still runs and only the diff is skipped.
  [boot_gs]="sim/run_boot_gs_tb.sh --instrs=250000 --tag=suite --floor=67398|^PASS$"
  [ports]="python3 tools/check_ports.py|^PASS: 0 unknown"
  [report]="sim/run_report_tb.sh|^REPORT OK"
  [ssi263]="sim/run_ssi263_tb.sh|^PASS$"
  [tx_ring]="sim/run_tx_ring_tb.sh|^PASS$"
  [uthernet2]="sim/run_uthernet2_tb.sh|^PASS$"
  [vbeam_vl]="sim/run_vbeam_vl.sh|^PASS$"
  [vidhd_card]="sim/run_vidhd_card_tb.sh|^PASS$"
  [trace_selftest]="sim/run_trace_selftest.sh|self-test: PASS"
  [cpu_tb]="sim/run_cpu_tb.sh|both suites passed"
  [cpu_predict]="sim/run_cpu_predict_tb.sh|predict/cancel contract holds"
  [accel_vl]="sim/run_accel_vl.sh|^PASS$"
  [accel_iv]="sim/run_accel_tb.sh|^PASS$"
  [mem_integ]="sim/run_mem_integ_tb.sh|^PASS$"
  [page_cache]="sim/run_page_cache_tb.sh|^PASS$"
  [fb_sim_vl]="sim/run_fb_sim_vl.sh|^PASS$"
)
QUICK="lint microcode boot_hold bus_event_filter bus_snoop bus_write bustest cpu_cycles cpu_irq floppy_card ft601_fifo ft601_msg ft601_msg_rx hd_card kbd_inject mockingboard audio mouse_card msg_arb no_slot_clock reg_map mmu_xlate ports report ssi263 tx_ring uthernet2 vbeam_vl vidhd_card trace_selftest mmu_xlate_gs"
CPU="cpu_tb cpu_cycles cpu_irq cpu_predict"
GS="microcode816 adb_keymap cpu816_cycles cpu816_trace mmu_xlate_gs boot_gs"
BATTERY="$QUICK accel_vl mem_integ page_cache fb_sim_vl"
[ "$iverilog" = 1 ] && BATTERY="$BATTERY accel_iv"

pass=0; fail=0; failed=""
run_bench() {
    local name="$1" spec="${B[$1]}" script rx log rc t0 t1
    script="${spec%%|*}"; rx="${spec#*|}"
    log="$work/$name.log"
    echo "== running $name -> sim/suite_work/$name.log"
    t0=$(date +%s)
    bash -c "$script" > "$log" 2>&1; rc=$?
    t1=$(date +%s)
    local ok=0
    if [ "$name" = lint ]; then [ "$rc" = 0 ] && ok=1
    elif grep -qE "$rx" "$log"; then ok=1; fi
    # accel: for a run whose PASS is per sweep point, both must pass
    if [ "$ok" = 1 ] && [[ "$name" == accel_* ]]; then
        [ "$(grep -cE '^PASS$' "$log")" -ge 2 ] || ok=0
        grep -E '^    \.\.\.[0-9]+ clocks' "$log" | tail -1 | sed -E 's/^    \.\.\.([0-9]+) clocks.*/\1/' > "$log.expect"
    fi
    local checks; checks="$(grep -oE '[0-9]+ checks, [0-9]+ (errors|failures)' "$log" | tail -1)"
    if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '   PASS %-18s %4ds  %s\n' "$name" $((t1-t0)) "$checks"
    else fail=$((fail+1)); failed="$failed $name"; printf '   FAIL %-18s %4ds  exit %s  %s\n' "$name" $((t1-t0)) "$rc" "$(grep -E 'FAIL|rror' "$log" | head -2 | tr '\n' ' ' | cut -c1-140)"; fi
}

run_boot() {
    local imgs=() i
    if [ -n "$images" ]; then IFS=', ' read -r -a imgs <<<"$images"
    elif [ -n "${BOOT_IMAGES:-}" ]; then IFS=', ' read -r -a imgs <<<"$BOOT_IMAGES"
    elif [ -f "$root/sim/images.local" ]; then mapfile -t imgs < <(grep -v '^#' "$root/sim/images.local" | grep .)
    fi
    [ "${#imgs[@]}" -gt 0 ] || { echo "   FAIL boot: no images - pass --images=A,B, set BOOT_IMAGES, or list them in sim/images.local (one path per line)"; fail=$((fail+1)); failed="$failed boot"; return; }
    local pids=() names=() logs=()
    for i in "${imgs[@]}"; do
        [ -f "$i" ] || { echo "   FAIL boot: no image at $i"; fail=$((fail+1)); failed="$failed boot"; continue; }
        local base; base="$(basename "$i")"; base="${base%.*}"
        local tag="suite_$base" log="$work/boot_$base.log"
        echo "== running boot_$base -> sim/suite_work/boot_$base.log (also sim/boot_work/boot_$tag.log)"
        ( sim/run_boot_tb.sh "$i" --verilator --tag="$tag" > "$log" 2>&1 ) &
        pids+=($!); names+=("boot_$base"); logs+=("$log")
    done
    local n
    for n in "${!pids[@]}"; do
        local t0; t0=$(date +%s)
        wait "${pids[$n]}"; local rc=$?
        local log="${logs[$n]}" name="${names[$n]}"
        local prog; prog="$(sim/progress.sh "$log" 2>/dev/null | head -1)"
        if grep -qE '^PASS$' "$log" && ! grep -qE 'bad [1-9]|mism [1-9]' <<<"$prog"; then
            pass=$((pass+1)); printf '   PASS %-18s  %s\n' "$name" "$(grep -oE '[0-9]+ checks, [0-9]+ errors' "$log" | tail -1) | $prog"
        else
            fail=$((fail+1)); failed="$failed $name"; printf '   FAIL %-18s  exit %s | %s\n' "$name" "$rc" "$prog"
        fi
    done
}

case "$suite" in
    quick)   for b in $QUICK; do run_bench "$b"; done ;;
    cpu)     for b in $CPU; do run_bench "$b"; done ;;
    gs)      for b in $GS; do run_bench "$b"; done ;;
    battery) for b in $BATTERY; do run_bench "$b"; done ;;
    boot)    run_boot ;;
    all)     for b in $BATTERY; do run_bench "$b"; done; for b in cpu_tb cpu_predict; do run_bench "$b"; done; run_boot ;;
    *)       echo "unknown suite '$suite': quick|cpu|gs|battery|boot|all" >&2; exit 1 ;;
esac
total=$((pass+fail))
if [ "$fail" = 0 ]; then echo "SUITE $suite: $pass/$total PASS"; exit 0
else echo "SUITE $suite: $pass/$total PASS, FAILED:$failed"; exit 1; fi
