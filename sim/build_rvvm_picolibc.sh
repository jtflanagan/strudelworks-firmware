#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# picolibc for rvvm guests (docs/REQ_RVVM.md), from the sibling checkout
# ../picolibc, built with clang for exactly rv32im_zba_zbb/ilp32 and installed
# into sim/rvvm_work/picolibc.  Single-threaded, errno a plain global (no TLS),
# no picocrt (apple/rvvm/guest/crt0.S) and no semihosting (the VM's ECALLs);
# position-independent, because guests are static PIEs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${PICOLIBC:-$root/../picolibc}"
# `fd`: the applications' variant - F and D, the ilp32d ABI (doubles in FP
# registers), its libm on the engine's FPU (apple/rvvm/build_app.sh); without it
# soft float under ilp32, the benchmarks' baseline (CoreMark, Embench)
variant="${1:-}"
build="$root/sim/rvvm_work/picolibc${variant:+-$variant}-build"
prefix="$root/sim/rvvm_work/picolibc${variant:+-$variant}"
[ -f "$src/meson.build" ] || { echo "no picolibc at $src" >&2; exit 1; }
cross="$root/apple/rvvm/guest/picolibc-cross${variant:+-$variant}.txt"
[ -f "$cross" ] || { echo "no $cross" >&2; exit 1; }
# A changed cross file (flags) means a fresh configuration.
if [ -f "$build/build.ninja" ] && [ "$cross" -nt "$build/build.ninja" ]; then rm -rf "$build" "$prefix"; fi
if [ ! -f "$build/build.ninja" ]; then
    meson setup "$build" "$src" --cross-file "$cross" \
        --prefix="$prefix" -Dincludedir=include -Dlibdir=lib \
        -Dmultilib=false -Dpicocrt=false -Dsemihost=false -Dtests=false \
        -Dthread-local-storage=false -Dsingle-thread=true -Dspecsdir=none \
        -Dbuildtype=release
fi
ninja -C "$build" install > "$build/install.log"
ls "$prefix/lib"
