#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Fetch Klaus Dormann's 6502/65C02 functional tests at a pinned commit.
#
# These are the standard functional suites for this class of core: self-checking
# 64 KiB images that run on the CPU itself and halt on a `jmp *`.  Same treatment
# as UberDDR3 - GPL-3.0, fetched rather than vendored, so the pinned SHA is
# checkable and upstream's code stays visibly upstream's.
#
# Only the two binaries and their listings are used.  The listings matter as much
# as the binaries: a failing run stops at a trap address, and the ONLY way to
# turn that address into "which instruction, which flag" is to look it up in the
# .lst.  Fetching the binary without the listing would leave every failure as a
# bare hex number.
set -euo pipefail

REPO="https://github.com/Klaus2m5/6502_65C02_functional_tests.git"
# Pinned 2026-08-15.  Upstream commit 7954e2d, committed 2020-01-05 - the suite
# has been stable since, which is what you want from a reference.
SHA="7954e2dbb49c469ea286070bf46cdd71aeb29e4b"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dst="$here/6502_tests"

if [ -d "$dst/.git" ]; then
  have="$(git -C "$dst" rev-parse HEAD)"
  if [ "$have" = "$SHA" ]; then
    echo "6502 tests already at $SHA"
    exit 0
  fi
  echo "6502 tests at $have, moving to $SHA"
  git -C "$dst" fetch --depth 50 origin "$SHA"
else
  rm -rf "$dst"
  git clone --filter=blob:none --no-checkout "$REPO" "$dst"
  git -C "$dst" fetch --depth 50 origin "$SHA"
fi

git -C "$dst" checkout --detach "$SHA"
echo "6502 tests checked out at $SHA"

# Both images are full 64 KiB memory dumps loaded at $0000 and entered at $0400.
# The trap addresses below are read out of the listings, not remembered - they
# move when upstream re-assembles.  sim/run_cpu_tb.sh re-derives them, so this is
# a cross-check, not the source of truth.
for f in 6502_functional_test 65C02_extended_opcodes_test; do
  [ -f "$dst/bin_files/$f.bin" ] || { echo "ERROR: missing $f.bin" >&2; exit 1; }
  [ -f "$dst/bin_files/$f.lst" ] || { echo "ERROR: missing $f.lst" >&2; exit 1; }
  printf '  %-32s %s bytes\n' "$f.bin" "$(stat -c %s "$dst/bin_files/$f.bin")"
done
