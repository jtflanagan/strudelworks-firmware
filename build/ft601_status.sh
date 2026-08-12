#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Decode the status frames ft601_top prints on the Au's UART.
#
#   build/ft601_status.sh          # decode 5 frames and exit
#   build/ft601_status.sh -n 20
#   PORT=/dev/ttyUSB0 build/ft601_status.sh
#
# The board emits "S=xxxx C=xxxxxxxx" about ten times a second.  This turns the
# hex into the signal names, so a wedged link can be read directly instead of
# inferred from LEDs.
#
# Bit assignments mirror the dbg bus in rtl/ft601_fifo.sv - change both together.
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
STATES = {0: "IDLE", 1: "TX", 2: "RX", 3: "TURNAROUND"}

# name, bit, and whether the signal is active low (so we print what it MEANS)
FLAGS = [
    ("tx_wr_rst_busy", 3,  False),
    ("tx_rd_rst_busy", 4,  False),
    ("rx_wr_rst_busy", 5,  False),
    ("rx_rd_rst_busy", 6,  False),
    ("ft_txe",         7,  True),   # low = FT601 has space for us
    ("ft_rxf",         8,  True),   # low = FT601 has data for us
    ("tx_empty",       9,  False),
    ("tx_full",        10, False),
    ("rx_empty",       11, False),
    ("rx_full",        12, False),
    ("ui_din_full",    13, False),
]

pat = re.compile(r"S=([0-9A-Fa-f]{4}) C=([0-9A-Fa-f]{8})(?: M=([0-9A-Fa-f]{2}) F=([0-9A-Fa-f]{2}))?")
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
            s, c = int(m.group(1), 16), int(m.group(2), 16)
            mmcm   = int(m.group(3), 16) if m.group(3) else 0
            resets = int(m.group(4), 16) if m.group(4) else 0
            state = STATES.get(s & 7, "?%d" % (s & 7))
            bits = []
            for name, bit, active_low in FLAGS:
                v = (s >> bit) & 1
                if active_low:
                    bits.append("%s=%d(%s)" % (name, v, "asserted" if v == 0 else "idle"))
                elif v:
                    bits.append(name)
            warn = ""
            if mmcm:
                warn = "  <-- ft_clk LOST %d time(s) since power-on" % mmcm
            print("state=%-10s count=%-11d clk_lost=%-3d chip_resets=%-3d %s%s"
                  % (state, c, mmcm, resets, " ".join(bits), warn))
            seen += 1
            if seen >= n:
                break
        buf = buf[buf.rfind("\n") + 1:] if "\n" in buf else buf
PY
