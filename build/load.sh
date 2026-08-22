#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Load a bitstream into the Alchitry Au over JTAG, VOLATILE (SRAM) - it is gone
# at power-off, which is what you want for test iterations.
#
#   build/load.sh                      # loads build/results/au_top.bit
#   build/load.sh path/to/other.bit
#   build/load.sh --detach             # hand the board back to Windows
#
# WHY THIS EXISTS: programming from the Vivado GUI keeps the project open, and
# the GUI holds a lock on the Windows-side work directory, so the next
# build/build.sh fails with "Cannot clear the Vivado work directory".  Loading
# over openFPGALoader touches neither Vivado nor the project, so build and flash
# stop fighting each other.
#
# The Au's USB is an FT2232H (0403:6010): channel A is JTAG, channel B is the
# UART this design prints its report on.  usbipd moves the WHOLE device to WSL,
# so while attached, Windows loses both - Vivado cannot see the board and the
# Windows COM port disappears.  In exchange the UART shows up here as
# /dev/ttyUSB* and the report can be read from this side.  `--detach` reverses it.
#
# ONE-TIME SETUP, requires an ADMINISTRATOR PowerShell on Windows:
#     usbipd bind --busid <BUSID>
# The bind persists across reboots, so it is genuinely once.  Everything after
# that is unprivileged and handled below.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USBIPD="/mnt/c/Program Files/usbipd-win/usbipd.exe"
VIDPID="0403:6010"          # FT2232H on the Alchitry Au
BOARD="alchitry_au"         # native openFPGALoader board definition

# Absolute path ON PURPOSE.  ~/.local/bin/openFPGALoader is a WSL->Windows
# wrapper for oss-cad-suite's openFPGALoader.EXE (used by the Tang Mega work),
# and it comes first on PATH.  That wrapper cannot work here: usbipd moves the
# board to WSL, so the Windows binary loses the device and reports
# "unable to open ftdi device: -4", which reads like a permissions problem and
# is not.  Use the native Linux build.
LOADER="/usr/bin/openFPGALoader"

# usbipd must be invoked from a non-UNC cwd, or cmd/Windows complains and the
# working directory silently becomes C:\Windows.
usbipd() { ( cd / && "$USBIPD" "$@" ); }

# Snapshot the listing ONCE.  Piping usbipd into an awk that exits early
# SIGPIPEs it, and with `set -o pipefail` that aborts the whole script with
# status 141 and no message - which looks exactly like the script doing nothing.
USBIPD_LIST="$(usbipd list 2>/dev/null || true)"

find_busid() {
    local matches
    matches=$(printf '%s\n' "$USBIPD_LIST" | awk -v vp="$VIDPID" '$2==vp && NF>2 {print $1}')
    case $(printf '%s\n' "$matches" | grep -c .) in
        0) echo "No $VIDPID device found. Is the Au plugged in?" >&2; return 1 ;;
        1) printf '%s\n' "$matches" ;;
        *) echo "More than one $VIDPID device; set BUSID=<busid> explicitly." >&2
           printf '%s\n' "$matches" >&2; return 1 ;;
    esac
}

# --detach must be tolerant: if the board has dropped off USB entirely there is
# nothing to detach, and failing at device discovery hides that fact behind a
# "device not found" error that looks like the detach itself went wrong.
if [ "${1:-}" = "--detach" ]; then
    if busid="${BUSID:-$(find_busid 2>/dev/null)}" && [ -n "$busid" ]; then
        usbipd detach --busid "$busid" || true
        echo "detached $busid - Windows has the board back"
    else
        echo "No $VIDPID on USB at all - nothing to detach."
        echo "The board is not in WSL and not on Windows either; replug the cable."
        echo "(Being 'Shared' does not take it from Windows - only 'Attached' does,"
        echo " so after a replug Vivado will see it without any further command.)"
    fi
    exit 0
fi

busid="${BUSID:-$(find_busid)}"

bit="${1:-$root/build/results/au_top.bit}"
[ -f "$bit" ] || { echo "No bitstream at $bit - run build/build.sh first" >&2; exit 1; }

# Match the whole line, not $NF: the STATE column holds multi-word values, and
# "Not shared" ends in "shared", so a last-field test reads exactly backwards.
if ! printf '%s\n' "$USBIPD_LIST" | grep -q "^$busid .*Attached"; then
    if ! usbipd attach --wsl --busid "$busid" 2>&1; then
        cat >&2 <<EOF

Could not attach $busid.

If the error above says "Device is not shared", the one-time bind has not been
done.  In an ADMINISTRATOR PowerShell on Windows:

    usbipd bind --busid $busid

then re-run this script.  No elevation is needed after that.
EOF
        exit 1
    fi
fi

# usbipd returns as soon as it has handed the device over; the WSL kernel still
# has to enumerate it.  Loading immediately fails with "-3 (device not found)",
# which reads like the board is absent when it is merely a fraction of a second
# behind.  Wait for the device node instead of sleeping a guessed interval.
for _ in $(seq 1 40); do
    if [ -n "$(ls /dev/bus/usb/*/* 2>/dev/null)" ] \
       && grep -qs . /sys/bus/usb/devices/*/idProduct 2>/dev/null \
       && grep -qls "6010" /sys/bus/usb/devices/*/idProduct 2>/dev/null; then
        break
    fi
    sleep 0.25
done

# The kernel binds BOTH FT2232H channels to ftdi_sio on attach, which leaves
# channel A (JTAG) owned by the serial driver and unavailable to libusb.  Release
# just that interface; channel B stays a tty so the UART report still works.
for iface in /sys/bus/usb/drivers/ftdi_sio/*:1.0; do
    [ -e "$iface" ] || continue
    echo "releasing $(basename "$iface") from ftdi_sio (JTAG channel)"
    echo -n "$(basename "$iface")" | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind >/dev/null
    sleep 1
done

echo "loading $(basename "$bit") into the FPGA (SRAM, volatile)"
"$LOADER" -b "$BOARD" "$bit"
echo
echo "done.  UART report:  build/report.sh   (or: /dev/ttyUSB1 at 115200)"
