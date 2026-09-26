#!/usr/bin/env bash
# strudelworks-firmware
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Load a bitstream into the card - by default INTO ITS FLASH, the image and then
# its record (build/load.sh; docs/BOOT_LOADER.md), so the card boots it from then
# on; --sram for a volatile load - with the states checked first, in the order
# they matter:
#
#   CABLE PRESENT/ABSENT   the FT2232H (JTAG + UART) USB cable, seen by usbipd
#   PI UP/OFF              the Pi powers the card over USB3; no Pi, no card
#   SWHOST UP/DOWN         swhost holds the FT601 and its parser cannot resync:
#                          it must be DOWN (mcp swhost action=stop, or tools/pi.sh stop)
#
# The Apple may be off.  The UART is NOT read: the load is confirmed by
# starting swhost and reading the firmware stamp over USB3 (the fw-load skill
# does that); --uart adds build/report.sh for the case where no register
# answers at all.
#
#   build/load_card.sh [BIT] [--sram] [--force] [--dry-run] [--uart]
#     BIT defaults to build/results/master_top.bit (build/load.sh's own default
#     is au_top.bit, which is stale for the card design).
# Exit 0 loaded, 1 a state refused it, 2 the load itself failed.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
host="$root/../strudelworks-host"
bit="$root/build/results/master_top.bit"; force=0; dry=0; uart=0; sram=0
for a in "$@"; do case "$a" in
    --force) force=1;; --dry-run) dry=1;; --uart) uart=1;; --sram) sram=1;;
    -h|--help) sed -n 5,22p "$0"; exit 0;;
    *) bit="$a";; esac; done

# ---- the bit -----------------------------------------------------------------
if [ ! -f "$bit" ]; then echo "no bitstream at $bit"; exit 1; fi
board="$(tr -d '[:space:]' < "${bit%.bit}.board" 2>/dev/null || echo pt_v2)"
echo "bit     : $bit ($(date -r "$bit" '+%Y-%m-%d %H:%M'), board $board)"
"$root/build/wns.sh" 2>/dev/null | head -1 | sed 's/^/timing  : /' || true

# ---- the states ---------------------------------------------------------------
USBIPD="/mnt/c/Program Files/usbipd-win/usbipd.exe"
cable="CABLE ABSENT"
if [ -x "$USBIPD" ]; then
    if (cd /mnt/c && "$USBIPD" list 2>/dev/null | grep -qi '0403:6010'); then cable="CABLE PRESENT"; fi
else
    cable="CABLE ? (usbipd not found at $USBIPD)"
fi
pi="PI OFF"; swh="SWHOST ?"
if [ -f "$host/tools/pi5.env" ]; then
    # shellcheck disable=SC1091
    . "$host/tools/pi5.env"
    if out="$(ssh -o BatchMode=yes -o ConnectTimeout=4 "$PI" 'pgrep -x swhost >/dev/null && echo running || echo stopped' 2>/dev/null)"; then
        pi="PI UP"
        case "$out" in *running*) swh="SWHOST UP";; *) swh="SWHOST DOWN";; esac
    fi
else
    pi="PI ? (no $host/tools/pi5.env)"
fi
echo "states  : $cable  $pi  $swh"
[ "$dry" = 1 ] && exit 0

case "$cable" in "CABLE ABSENT") echo "refused: $cable - plug the FT2232H USB cable (and usbipd bind --busid once, as Administrator)"; exit 1;; esac
case "$pi" in "PI OFF") echo "refused: $pi - the Pi powers the card over USB3; power it (and check its ethernet)"; exit 1;; esac
if [ "$swh" = "SWHOST UP" ] && [ "$force" != 1 ]; then
    echo "refused: $swh - stop it first (mcp swhost action=stop, or $host/tools/pi.sh stop); the link cannot resync under a reload"
    exit 1
fi

# ---- the load ------------------------------------------------------------------
sram_arg=(); [ "$sram" = 1 ] && sram_arg=(--sram)
echo "== build/load.sh ${sram_arg[*]} $bit"
"$root/build/load.sh" "${sram_arg[@]}" "$bit" || { echo "LOAD FAILED"; exit 2; }
# The board re-enumerates for a few seconds after programming (docs/DERISK.md).
sleep 4
if [ -n "${FLASH_OFFSET:-}" ]; then
    echo "written: $(basename "$bit") into the flash at $FLASH_OFFSET; the FPGA booted from flash address 0."
    exit 0
fi
if [ "$sram" = 0 ]; then
    echo "written: $(basename "$bit") and its record into the FLASH; the card boots it from now on."
    echo "Confirm over USB3: swboot identify / query on the Pi, or start swhost and read 'firmware: built ...'."
    exit 0
fi
echo "loaded: $(basename "$bit") in SRAM (volatile; the flash image returns at the next reset).  Confirm over USB3: start swhost and read 'firmware: built ...' (mcp swhost action=start)."
if [ "$uart" = 1 ]; then
    echo "== build/report.sh -n 1 (UART)"
    "$root/build/report.sh" -n 1 || echo "(no UART report - only matters if swhost then reports firmware: unknown)"
fi
exit 0
