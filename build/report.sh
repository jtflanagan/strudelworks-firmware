#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Read the latency report the board prints once a second.
#
#   build/report.sh          # print 2 reports and exit
#   build/report.sh -n 5     # print 5
#   build/report.sh -f       # follow until interrupted
#   PORT=/dev/ttyUSB0 build/report.sh
#
# Needs the board attached to WSL (build/load.sh does that).  Channel B of the
# FT2232H is the UART; channel A is JTAG.
#
# USE pyserial, NOT stty+cat.  Two ways that goes wrong, both of which cost real
# time here and both of which look identical to "the board is not transmitting":
#
#   * `stty -F PORT ...` opens the port, applies settings, then CLOSES it - and
#     the close reverts them.  The following `cat` opens fresh at the default
#     baud and reads garbage or nothing.
#   * Setting termios by hand and zeroing c_cflag leaves the baud bits at B0.
#     On Linux B0 means HANG UP THE LINE: DTR drops and the receiver is disabled,
#     so the port stays silent no matter what the far end sends.
set -euo pipefail

follow=0
count=2
port="${PORT:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        -f) follow=1 ;;
        -n) shift; count="$1" ;;
        *)  port="$1" ;;
    esac
    shift
done

exec python3 - "$port" "$count" "$follow" <<'PY'
import sys, time, glob
try:
    import serial
except ImportError:
    sys.exit("pyserial missing:  sudo apt install python3-serial")

port, count, follow = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"

if not port:
    cands = sorted(glob.glob("/dev/ttyUSB*"))
    if not cands:
        sys.exit("No /dev/ttyUSB* found. Attach the board:  build/load.sh")
    # Channel A is usually unbound for JTAG, so the UART is typically the only
    # node left - but try each rather than guessing at the numbering.
    cands.reverse()
else:
    cands = [port]

for dev in cands:
    try:
        s = serial.Serial(dev, 115200, bytesize=8, parity="N", stopbits=1,
                          timeout=1)
    except Exception as e:
        print(f"{dev}: {e}", file=sys.stderr)
        continue

    if follow:
        print(f"following {dev} at 115200 (ctrl-C to stop)", file=sys.stderr)
        try:
            while True:
                sys.stdout.write(s.read(256).decode("ascii", "replace"))
                sys.stdout.flush()
        except KeyboardInterrupt:
            s.close()
            sys.exit(0)

    buf = b""
    deadline = time.time() + 8 + count * 2
    while time.time() < deadline and buf.count(b"errors=") < count:
        buf += s.read(256)
    s.close()

    if buf:
        sys.stdout.write(buf.decode("ascii", "replace").lstrip("\r\n"))
        sys.exit(0)
    print(f"{dev}: silent", file=sys.stderr)

sys.exit("No report seen. Is the design calibrated?  A single lit LED means "
         "calibration has not completed, and nothing is transmitted until it does.")
PY
