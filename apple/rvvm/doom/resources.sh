#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# DOOM's resources (apple/rvvm/build_app.sh runs this with OUTDIR): DOOM1.WAD,
# the shareware WAD (../doom-shareware/doom1.wad, or $DOOM_WAD) - never in git;
# and, for the bench, TITLEPIC.565, the title page as a right frame shows it
# (through DOOM's gamma level 0).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
out="${1:?usage: resources.sh OUTDIR}"
wad="${DOOM_WAD:-$root/../doom-shareware/doom1.wad}"
[ -f "$wad" ] || { echo "no DOOM WAD at $wad (set DOOM_WAD)" >&2; exit 1; }
cp "$wad" "$out/DOOM1.WAD"
# the reference through DOOM's own gamma level 0 (doomgeneric's tables.c), as DOOM draws it
python3 "$root/tools/wad_titlepic.py" "$wad" "$out/TITLEPIC.PNG" "$out/TITLEPIC.565" \
    --gamma-from "$root/../doomgeneric/doomgeneric/tables.c"
echo DOOM1.WAD
