#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Reset the FT601 without touching the cable.
#
#   build/ft601_reset.sh          # pulse RESET# and report the result
#   PORT=/dev/ttyUSB0 build/ft601_reset.sh
#
# Sends 'R' to ft601_top over the Alchitry Au's own serial bridge.  That bridge
# is a SEPARATE USB device from the FT601, which is the whole point: it is
# reachable exactly when the FT601 is the thing that is stuck, so this works in
# the case where talking to the FT601 itself would not.
#
# The gateware holds RESET# low for a full millisecond, so the chip really does
# restart and re-enumerate on the host.  Under WSL that means usbipd drops the
# attachment and it has to be re-attached afterwards:
#
#   usbipd attach --wsl --busid <id>
#
# Needs the board attached to WSL (build/load.sh does that).  Channel B of the
# FT2232H is the UART; channel A is JTAG.
set -euo pipefail

PORT="${PORT:-/dev/ttyUSB1}"

if [ ! -e "$PORT" ]; then
    echo "no $PORT - is the board attached to WSL?  build/load.sh does that." >&2
    exit 1
fi

python3 - "$PORT" <<'PY'
import sys, time
try:
    import serial
except ImportError:
    sys.exit("pyserial missing:  pip install pyserial  (or apt install python3-serial)")

port = sys.argv[1]
with serial.Serial(port, 115200, timeout=2) as ser:
    ser.reset_input_buffer()

    # Read the reset counter before, so we can prove the command landed rather
    # than just assuming it did.
    before = None
    t0 = time.time()
    buf = ""
    while time.time() - t0 < 2:
        buf += ser.read(128).decode("ascii", "replace")
        i = buf.find("F=")
        if i >= 0 and len(buf) >= i + 4:
            before = int(buf[i+2:i+4], 16)
            break
    if before is None:
        sys.exit("no status frames on %s - is ft601_top loaded?" % port)

    ser.write(b"R")
    ser.flush()
    print("sent reset command (chip_resets was %d)" % before)

    # RESET# is held 1 ms, then the chip re-enumerates, which takes a while.
    time.sleep(0.5)

    ser.reset_input_buffer()
    t0 = time.time()
    buf = ""
    while time.time() - t0 < 3:
        buf += ser.read(128).decode("ascii", "replace")
        i = buf.find("F=")
        if i >= 0 and len(buf) >= i + 4:
            after = int(buf[i+2:i+4], 16)
            if after != before:
                print("FT601 reset: chip_resets %d -> %d" % (before, after))
                print("under WSL, re-attach it now:  usbipd attach --wsl --busid <id>")
                sys.exit(0)
            buf = buf[i+4:]
    sys.exit("counter did not advance - the command may not have been received")
PY
