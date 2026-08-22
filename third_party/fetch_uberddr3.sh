#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Fetch UberDDR3 at a pinned commit into third_party/UberDDR3/.
#
# UberDDR3 is GPL-3.0-or-later, and so is this project's gateware (see
# LICENSING.md), so vendoring would be legal.  It is still fetched rather than
# vendored, for provenance: the pinned SHA below is checkable, and upstream's
# code stays visibly upstream's rather than blurring into ours.
set -euo pipefail

REPO="https://github.com/AngeloJacobo/UberDDR3.git"
# Pinned 2026-08-11.  Upstream commit 4a51b96, authored 2026-06-12.
SHA="4a51b9671347130759c9980d6756918f084e2124"

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

# Local patches, applied on top of the pinned commit.
#
# These MUST live here rather than as edits to a vendored tree: without this
# step a re-fetch silently reverts them, and the symptom would be a refresh
# landing in the middle of a CPU cycle - intermittent, timing-dependent, and
# nothing like an obvious "your patch is missing" failure.
shopt -s nullglob
patches=("$here"/../patches/*.patch)
if [ ${#patches[@]} -gt 0 ]; then
  for p in "${patches[@]}"; do
    echo "applying $(basename "$p")"
    git -C "$dst" apply --check "$p" || {
      echo "ERROR: $(basename "$p") does not apply to $SHA." >&2
      echo "       Upstream moved, or the patch was authored against a different pin." >&2
      exit 1
    }
    git -C "$dst" apply "$p"
  done
  echo "${#patches[@]} patch(es) applied"
fi
