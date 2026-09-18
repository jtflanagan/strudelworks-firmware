#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Fetch UberDDR3 at a pinned commit into third_party/UberDDR3/.
#
# UberDDR3 is GPL-3.0-or-later, and so is this project's gateware (see
# LICENSING.md), so vendoring would be legal.  It is still fetched rather than
# vendored, for provenance: the pinned SHA below is checkable, and upstream's
# code stays visibly upstream's rather than blurring into ours - now from our
# fork, whose commits on top of upstream are the ones meant to go back.
set -euo pipefail

# Our fork, branch strudelworks-research (docs/UBERDDR3.md): upstream's
# 4a51b96 (2026-06-12) plus the DDR3 clock pin through an OSERDES when
# ODELAY is unsupported (CK_OSERDES) and the calibration diagnostics
# (o_debug1..3, the IDELAYCTRL RDY synchroniser).  Every commit on it is
# cut to be sent upstream as a pull request; the branch head is pinned
# here by SHA as before.
REPO="https://github.com/jtflanagan/UberDDR3.git"
# Pinned 2026-09-14: fork commit d728e6a on strudelworks-research.
SHA="32284cbf6be37124f616fc4990fb27ebd71b48a7"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dst="$here/UberDDR3"

if [ -d "$dst/.git" ]; then
  have="$(git -C "$dst" rev-parse HEAD)"
  if [ "$have" = "$SHA" ]; then
    echo "UberDDR3 already at $SHA"
    exit 0
  fi
  echo "UberDDR3 at $have, moving to $SHA"
  git -C "$dst" fetch --depth 50 origin "$SHA"
else
  rm -rf "$dst"
  git clone --filter=blob:none --no-checkout "$REPO" "$dst"
  git -C "$dst" fetch --depth 50 origin "$SHA"
fi

git -C "$dst" checkout --detach "$SHA"
echo "UberDDR3 checked out at $SHA"
