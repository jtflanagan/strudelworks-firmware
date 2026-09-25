#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Load a bitstream into the Alchitry board over JTAG.  BY DEFAULT INTO THE FLASH
# (docs/BOOT_LOADER.md, the development load): the bitstream at 0, then its
# record - <bitstream>.rec beside it, made by tools/mkpkg.py (run_build.sh runs it)
# - at 0x3FF000, both verified, and the FPGA then boots from flash.  The card now
# boots that image at every power-up and every LINK_RESET, and QUERY checks it.
#
#   build/load.sh path/to/card.bit     # flash: the image, then its record
#   build/load.sh --sram path/x.bit    # VOLATILE (SRAM): gone at power-off; the
#                                      # flash image returns at the next reset
#   FLASH_OFFSET=N build/load.sh f     # write one file raw at flash offset N
#   build/load.sh --detach             # hand the board back to Windows
#   BOARD=au_v2 build/load.sh ...      # override the board (see below)
#
# A bitstream with no record is refused in flash mode: flashing an image the
# card cannot identify leaves QUERY answering NO_RECORD.  Make the record
# (python3 tools/mkpkg.py BIT) or load it with --sram.
#
# WHICH BOARD: build/build.tcl writes <bitstream>.board beside every bitstream
# it produces (au_v2 | pt_v2), and that is what decides the
# loader's part below.  BOARD=... overrides it; without either, pt_v2.
# openFPGALoader checks the IDCODE before it writes anything, so a bitstream
# for the wrong board is refused rather than loaded.
#
# WHY THIS EXISTS: programming from the Vivado GUI keeps the project open, and
# the GUI holds a lock on the Windows-side work directory, so the next
# build/build.sh fails with "Cannot clear the Vivado work directory".  Loading
# over openFPGALoader touches neither Vivado nor the project, so build and flash
# stop fighting each other.
#
# Both boards' USB is an FT2232H (0403:6010): channel A is JTAG, channel B is
# the UART this design prints its report on.  usbipd moves the WHOLE device to WSL,
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
VIDPID="0403:6010"          # FT2232H on the Alchitry Au V2 and Pt V2 alike

# openFPGALoader arguments per board.  The Au has a native board definition;
# the Pt does not (openFPGALoader 0.12), but a board definition is only a cable
# plus a part, and both are known: the same FT2232H cable, and xc7a100tfgg484,
# for which openFPGALoader ships the spiOverJtag bridge that -f (flash) needs.
loader_args() {
    case "$1" in
        au_v2)              echo "-b alchitry_au" ;;
        pt_v2)  echo "-c ft2232 --fpga-part xc7a100tfgg484" ;;
        *) echo "unknown board '$1' (au_v2 | pt_v2)" >&2; return 1 ;;
    esac
}

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

sram=0
bit=""
for a in "$@"; do
    case "$a" in
        --sram) sram=1 ;;
        *)      bit="$a" ;;
    esac
done
bit="${bit:-$root/build/results/au_top.bit}"
[ -f "$bit" ] || { echo "No bitstream at $bit - run build/build.sh first" >&2; exit 1; }
rec="${bit%.bit}.rec"
if [ "$sram" = 0 ] && [ -z "${FLASH_OFFSET:-}" ] && [ ! -f "$rec" ]; then
    echo "No record at $rec: make it (python3 tools/mkpkg.py $bit) or load with --sram (volatile)" >&2
    exit 1
fi

busid="${BUSID:-$(find_busid)}"

# The board: BOARD= if given, else the sidecar build.tcl wrote, else pt_v2.
sidecar="${bit%.bit}.board"
if [ -z "${BOARD:-}" ] && [ -f "$sidecar" ]; then
    BOARD="$(tr -d '[:space:]' < "$sidecar")"
fi
BOARD="${BOARD:-pt_v2}"
loader_str="$(loader_args "$BOARD")" || exit 1
read -r -a LOADER_ARGS <<< "$loader_str"
echo "board: $BOARD  (openFPGALoader ${LOADER_ARGS[*]})"

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

# The flash writes (docs/BOOT_LOADER.md, Writers): -o N, verified by reading
# back; openFPGALoader erases only the 4 KB sectors it writes, and afterwards the
# FPGA reconfigures from flash address 0.  The record goes SECOND, so a load that
# stops early leaves no record and QUERY says so.  (--file-type bin: the record's
# .rec extension means nothing to openFPGALoader.)
t0=$SECONDS
if [ "$sram" = 1 ]; then
    echo "loading $(basename "$bit") into the FPGA (SRAM, volatile)"
    "$LOADER" "${LOADER_ARGS[@]}" "$bit"
elif [ -n "${FLASH_OFFSET:-}" ]; then
    echo "writing $(basename "$bit") into the FLASH at offset $FLASH_OFFSET (persistent), verified"
    "$LOADER" "${LOADER_ARGS[@]}" -f -o "$FLASH_OFFSET" --verify "$bit"
else
    echo "writing $(basename "$bit") into the FLASH at 0 (persistent), verified"
    "$LOADER" "${LOADER_ARGS[@]}" -f -o 0 --verify "$bit"
    echo "writing its record $(basename "$rec") at 0x3FF000, verified"
    "$LOADER" "${LOADER_ARGS[@]}" -f -o 0x3FF000 --file-type bin --verify "$rec"
fi
echo "load time: $((SECONDS - t0)) s"
echo
echo "done.  UART report:  build/report.sh   (or: /dev/ttyUSB1 at 115200)"
