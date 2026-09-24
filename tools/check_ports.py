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
# Three trees since 2026-09-18: rtl/common, rtl/a2 (the 65C02 card) and rtl/gs
# (the 65816 card).  The two cards each carry their own copy of the sequencer,
# L1 and L2 under the SAME module names, so a port list is kept per tree and a
# connection is checked against its own tree first, then common, then the other.
files = sorted(root.glob('rtl/*/*.sv')) + sorted(root.glob('rtl/*/*.v')) + sorted(root.glob('sim/*.sv'))
def tree_of(f):
    parts = f.relative_to(root).parts
    if parts[0] == 'rtl': return parts[1]
    import re as _re
    return 'gs' if _re.search(r'gs|816|gspanel|adb', f.name) else 'a2'
def lookup_order(t):
    return {'common': ['common','a2','gs'], 'a2': ['a2','common','gs'], 'gs': ['gs','common','a2']}[t]

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


COND_RE = re.compile(r'^\s*`(ifdef|ifndef|elsif|else|endif)\s*(\w*)')


def select(text, defined):
    """The text a preprocessor with these macros defined would hand the parser.

    An inactive branch becomes BLANK LINES, not nothing, so the line numbers
    this tool reports stay the file's own.  It has to be done: an
    instantiation can span a conditional whose other branch opens a second
    instantiation (boot_gs_tb's l1i / l1i_store, gs_top's), and a parser that
    reads both at once never closes the first one's port list - it swallows
    every connection after it and blames them all on the first module.  That
    was 1,170 reports from two instantiations (2026-09-22).
    """
    out, stack = [], []          # stack of (active_now, any_branch_taken)
    for line in text.split('\n'):
        m = COND_RE.match(line)
        if m:
            kind, name = m.group(1), m.group(2)
            if kind in ('ifdef', 'ifndef'):
                on = (name in defined) if kind == 'ifdef' else (name not in defined)
                on = on and all(a for a, _ in stack)
                stack.append((on, on))
            elif kind == 'elsif':
                if stack:
                    _, taken = stack[-1]
                    on = (not taken) and (name in defined) and all(a for a, _ in stack[:-1])
                    stack[-1] = (on, taken or on)
            elif kind == 'else':
                if stack:
                    _, taken = stack[-1]
                    on = (not taken) and all(a for a, _ in stack[:-1])
                    stack[-1] = (on, True)
            elif kind == 'endif':
                if stack:
                    stack.pop()
            out.append('')
            continue
        out.append(line if all(a for a, _ in stack) else '')
    return '\n'.join(out)


def macros_in(texts):
    found = set()
    for t in texts:
        for m in re.finditer(r'`(?:ifdef|ifndef|elsif)\s+(\w+)', t):
            found.add(m.group(1))
    return found

raw = {f: strip_comments(f.read_text(errors='ignore')) for f in files}
# Every branch of every conditional gets checked, not just the default build's:
# nothing defined, then each macro on its own, then all of them.  A report is
# printed once however many passes find it.
MACROS = sorted(macros_in(raw.values()))
passes = [frozenset()] + [frozenset([m]) for m in MACROS] + [frozenset(MACROS)]


def collect(defined):
  ports = {'common': {}, 'a2': {}, 'gs': {}}   # per tree; sim/ benches define none we check
  for f in files:
    t = tree_of(f)
    if t not in ports: continue
    text = select(raw[f], defined)
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
        ports[t][name] = port_names(text[m.end():i])
  return ports

inst_re = re.compile(r'\b([A-Za-z_]\w*)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?'
                     r'([A-Za-z_]\w*)\s*(\()\s*\.\s*\w', re.S)
kw = {'if', 'else', 'for', 'while', 'case', 'begin', 'end', 'assign', 'always',
      'always_ff', 'always_comb', 'return', 'function', 'task', 'module'}

seen = {}


def check(defined, ports):
  for f in files:
    text = select(raw[f], defined)
    order = lookup_order(tree_of(f))
    for m in inst_re.finditer(text):
        mod, inst = m.group(1), m.group(2)
        if mod in kw:
            continue
        found = next((ports[t][mod] for t in order if mod in ports[t]), None)
        if found is None:
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
            if p not in found:
                line = text[:m.start()].count('\n') + 1
                seen[(str(f.relative_to(root)), line, mod, inst, p)] = True


for d in passes:
    check(d, collect(d))

for (fn, line, mod, inst, p) in sorted(seen):
    print(f"{fn}:{line}: {mod} {inst}: no port '{p}'")
bad = len(seen)
print(f"{'FAIL' if bad else 'PASS'}: {bad} unknown named port connection(s)")
sys.exit(1 if bad else 0)
