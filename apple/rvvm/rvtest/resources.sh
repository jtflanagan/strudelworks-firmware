#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# RVTEST's resources (apple/rvvm/build_app.sh runs this with OUTDIR and lists what
# it prints: one file name a line, each put beside the application on its disk).
# RVTEST.DAT, 40000 bytes, byte i = (7i + i/256) mod 256 - the program
# reads it through the bounce buffer and checks every byte.
set -euo pipefail
out="${1:?usage: resources.sh OUTDIR}"
python3 -c "
import sys
open(sys.argv[1], 'wb').write(bytes(((7 * i + (i >> 8)) & 0xFF) for i in range(40000)))
" "$out/RVTEST.DAT"
echo RVTEST.DAT
