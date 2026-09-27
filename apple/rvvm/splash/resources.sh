#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# SPLASH's resources (apple/rvvm/build_app.sh runs this with OUTDIR and puts the
# files it names beside the application): TITLEPIC.PNG, DOOM's title screen out
# of the shareware WAD (tools/wad_titlepic.py; the WAD sits beside this repo,
# ../doom-shareware/doom1.wad, or $DOOM_WAD) - made at build time, never in git.
# TITLEPIC.565 beside it is the bench's reference picture (not on the disk).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
out="${1:?usage: resources.sh OUTDIR}"
wad="${DOOM_WAD:-$root/../doom-shareware/doom1.wad}"
[ -f "$wad" ] || { echo "no DOOM WAD at $wad (set DOOM_WAD)" >&2; exit 1; }
python3 "$root/tools/wad_titlepic.py" "$wad" "$out/TITLEPIC.PNG" "$out/TITLEPIC.565"
echo TITLEPIC.PNG
