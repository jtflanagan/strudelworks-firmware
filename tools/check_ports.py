#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Named port connections against the modules they name.

Verilator does not lint master_top (it instantiates Xilinx primitives it
cannot resolve), so a .port() that no longer exists on the instantiated module
is found only by Vivado - after a ten-minute elaboration.  This finds it in a
second, which is the same bargain sim/lint.sh makes.

Reports, for every named connection in rtl/ and sim/, a port the target module
does not declare.  A module this repo does not define (an XPM macro, an
UberDDR3 file) is skipped, and so is the port list of a module it cannot parse.
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
files = sorted(root.glob('rtl/*.sv')) + sorted(root.glob('rtl/*.v')) + sorted(root.glob('sim/*.sv'))

mod_re = re.compile(r'^\s*module\s+(\w+)\s*(#\s*\((?:[^()]|\([^()]*\))*\))?\s*\(', re.M)
ident_re = re.compile(r'[A-Za-z_]\w*')


def port_names(plist):
    """The port names in a module's port list.

    One name per comma-separated item, and the name is the item's LAST
    identifier - which reads `input wire [7:0] foo`, a bare continuation
    `bar` of `output logic [11:0] foo, bar`, and a non-ANSI `(a, b, c)`
    alike.  Commas inside a range or a function call do not split.
    """
    names, item, depth = set(), [], 0
    for ch in plist:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            names.add(''.join(item)); item = []
        else:
            item.append(ch)
    names.add(''.join(item))
    out = set()
    for it in names:
        it = re.sub(r'\[[^\]]*\]', ' ', it)          # drop packed/unpacked dims
        ids = ident_re.findall(it)
        if ids:
            out.add(ids[-1])
    return out

def strip_comments(t):
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)
    return re.sub(r'//[^\n]*', '', t)

ports = {}
for f in files:
    text = strip_comments(f.read_text(errors='ignore'))
    for m in mod_re.finditer(text):
        name = m.group(1)
        # the port list: from the '(' the match ends on to its matching ')'
        i, depth = m.end() - 1, 0
        while i < len(text):
            if text[i] == '(': depth += 1
            elif text[i] == ')':
                depth -= 1
                if depth == 0: break
            i += 1
        ports[name] = port_names(text[m.end():i])

inst_re = re.compile(r'\b([A-Za-z_]\w*)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?'
                     r'([A-Za-z_]\w*)\s*(\()\s*\.\s*\w', re.S)
kw = {'if', 'else', 'for', 'while', 'case', 'begin', 'end', 'assign', 'always',
      'always_ff', 'always_comb', 'return', 'function', 'task', 'module'}

bad = 0
for f in files:
    text = strip_comments(f.read_text(errors='ignore'))
    for m in inst_re.finditer(text):
        mod, inst = m.group(1), m.group(2)
        if mod in kw or mod not in ports:
            continue
        start = m.start(3)          # the instantiation's own '('
        i, depth = start, 0
        while i < len(text):
            if text[i] == '(': depth += 1
            elif text[i] == ')':
                depth -= 1
                if depth == 0: break
            i += 1
        body = text[start:i]
        for p in re.findall(r'\.\s*(\w+)\s*\(', body):
            if p not in ports[mod]:
                line = text[:m.start()].count('\n') + 1
                print(f"{f.relative_to(root)}:{line}: {mod} {inst}: no port '{p}'")
                bad += 1

print(f"{'FAIL' if bad else 'PASS'}: {bad} unknown named port connection(s)")
sys.exit(1 if bad else 0)
