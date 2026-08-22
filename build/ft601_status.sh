#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Decode the status frames ft601_top prints on the Au's UART.
#
#   build/ft601_status.sh          # decode 5 frames and exit
#   build/ft601_status.sh -n 20
#   PORT=/dev/ttyUSB0 build/ft601_status.sh
#
# The board emits "C=xxxxxxxx F=xx" about ten times a second: words sent, and
# host-requested FT601 resets.  The FSM/clock/FIFO fields it used to print are
# gone along with the logic that produced them.
#
#
# pyserial rather than stty+cat, for the reason build/report.sh documents at
# length: stty applies its settings and then closes the port, which reverts them,
# and the following read gets garbage at the default baud.
set -euo pipefail

PORT="${PORT:-/dev/ttyUSB1}"
N=5
while [ $# -gt 0 ]; do
    case "$1" in
        -n) N="$2"; shift 2 ;;
        *)  echo "usage: $0 [-n frames]" >&2; exit 2 ;;
    esac
done

if [ ! -e "$PORT" ]; then
    echo "no $PORT - is the board attached to WSL?  build/load.sh does that." >&2
    exit 1
fi

python3 - "$PORT" "$N" <<'PY'
import re, sys
try:
    import serial
except ImportError:
    sys.exit("pyserial missing:  pip install pyserial  (or apt install python3-serial)")

port, n = sys.argv[1], int(sys.argv[2])
pat = re.compile(r"C=([0-9A-Fa-f]{8}) F=([0-9A-Fa-f]{2})")
seen = 0
with serial.Serial(port, 115200, timeout=2) as ser:
    ser.reset_input_buffer()
    buf = ""
    while seen < n:
        chunk = ser.read(256).decode("ascii", "replace")
        if not chunk:
            sys.exit("timed out waiting for status frames - is ft601_top loaded?")
        buf += chunk
        for m in pat.finditer(buf):
            c, resets = int(m.group(1), 16), int(m.group(2), 16)
            print("words_sent=%-11d chip_resets=%d" % (c, resets))
            seen += 1
            if seen >= n:
                break
        buf = buf[buf.rfind("\n") + 1:] if "\n" in buf else buf
PY
