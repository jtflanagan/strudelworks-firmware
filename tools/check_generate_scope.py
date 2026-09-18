#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Identifiers named inside a generate block but declared below it.

Verilator resolves such a forward reference to the module-level net; Vivado
declares an IMPLICIT, UNDRIVEN net in the generate scope and warns (Synth
8-3848 "does not have driver") after a forty-minute build.  On the IIgs both
fronts ran with a never-servable map because of exactly this (docs/GS.md rung
6).  This finds it in a second: every `generate ... begin : NAME` block's body
is scanned for identifiers whose module-level `wire`/`logic`/`reg` declaration
sits at a later line than the block's start.  Exit 1 on any hit.
"""
import re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
# A declaration may carry a synthesis attribute in front of it -
# `(* max_fanout = 24 *) logic [11:0] f_vtag;` - and it is still a
# declaration.  Without this the scanner does not see the name at all and
# reports the first USE of it as a forward reference into a generate scope,
# which is what it did for iline's f_vtag on 2026-09-18.
attr = r'(?:\(\*[^*]*\*\)\s*)*'
decl_re = re.compile(r'^\s*' + attr + r'(?:wire|logic|reg)\b[^;=]*?\b([A-Za-z_]\w*)\s*(?:,\s*([A-Za-z_]\w*)\s*)*(?:=[^;]*)?;', re.M)
bad = 0
for f in sorted(root.glob('rtl/*.sv')):
    src = f.read_text()
    lines = src.split('\n')
    # module-level declarations: name -> first line (1-based); a comma list names several
    decl = {}
    for i, l in enumerate(lines, 1):
        s = l.split('//')[0]
        m = re.match(r'^\s*' + attr + r'(?:wire|logic|reg)\b\s*(?:\[[^\]]*\]\s*)*(.*);\s*$', s)
        if not m: continue
        for part in m.group(1).split(','):
            name = part.strip().split('=')[0].strip().split('[')[0].strip()
            if re.match(r'^[A-Za-z_]\w*$', name) and name not in decl:
                decl[name] = i
    # generate blocks: from "generate" to matching "endgenerate" (top level only)
    depth = 0; start = None
    for i, l in enumerate(lines, 1):
        s = l.split('//')[0]
        if re.search(r'\bgenerate\b', s) and not re.search(r'\bendgenerate\b', s):
            if depth == 0: start = i
            depth += 1
        if re.search(r'\bendgenerate\b', s):
            depth -= 1
            if depth == 0 and start is not None:
                body = '\n'.join(x.split('//')[0] for x in lines[start-1:i])
                for name in set(re.findall(r'\b[A-Za-z_]\w*\b', body)):
                    if name in decl and decl[name] > i:
                        # declared after the block ends: used inside, declared below
                        bad += 1
                        print(f"{f.relative_to(root)}:{start}: generate block names '{name}', declared at line {decl[name]}")
                start = None
print("PASS: no generate block names a later declaration" if bad == 0 else f"FAIL: {bad} forward reference(s) into generate scope")
sys.exit(1 if bad else 0)
