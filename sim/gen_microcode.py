#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Assemble the cpu65c02 microcode ROM.

Emits two generated files, both committed:

    rtl/cpu65c02_ucode.vh    field positions and symbolic values
    rtl/cpu65c02_ucode.hex   the ROM contents, one microinstruction per line

Both come from the field table below, so the RTL cannot disagree with the
assembler about where a field lives.  That is the classic way a microcoded
design goes wrong - the ROM says one thing, the datapath decodes another, and
the symptom is an instruction that misbehaves in a way that looks like a logic
bug anywhere but in the bit numbering.  Generating both removes the possibility
rather than documenting the hazard.

Run with --check to verify the committed files are current, the same contract
tools/gen_ddr3_xdc.py uses.

---------------------------------------------------------------------------
THE DESIGN RULE THIS FILE EXISTS TO ENFORCE

Microcode is not here to save LUTs.  It is here because it lets the work be
spread explicitly across the cycles the instruction set already grants, instead
of being crammed into one cycle by a state machine that has nowhere else to put
it.  The 6502 is unusually generous about this:

    * every 16-bit address computation decomposes into an 8-bit add plus a
      carry into the high byte, and
    * the instruction set gives an EXTRA CYCLE exactly when that carry actually
      has to propagate - the indexed page-cross penalty, the taken-branch page
      cross, the sixth cycle of JMP (abs) that buys the CMOS page-wrap fix.

So the rule every microinstruction below obeys:

    NO microinstruction adds two arbitrary 8-bit operands into the high byte.

The AGU's low half is a real 8-bit adder.  Its high half is only ever an
incrementer/decrementer - plus one, minus one, or nothing - driven by a carry
SAVED from a previous cycle (an add whose carry the ISA already paid a cycle
for).  Two arbitrary operands never meet on the high byte, so the longest
arithmetic path in the core is eight bits wide.

And a second rule, one notch stronger, arrived when the logic-depth audit
(build/depth.sh, results/logic_depth.rpt) showed the low adder's carry-out
chaining straight into the high incrementer inside one cycle:

    the high byte NEVER consumes a live carry.  agu_co lands in the agu_c
    register before anything arithmetic reads it.

The two instructions that used a live carry - JMP (abs) and JMP (abs,X), for
their pointer increment - both have a dummy cycle immediately before that
increment, granted by the CMOS part for exactly this work.  The dummy cycle
now PROBES the carry (computes lo+1, loads nothing, lets agu_c catch the
carry-out) and the increment cycle consumes it as SAVED.  Same addresses on
the bus, same cycle counts; one fewer arithmetic event per cycle.  HI_C has
no LIVE encoding left, and the RTL has no live-carry path into the high half
at all.

That is what the extra cycles are FOR.  A core that computes the full 16-bit
effective address in one cycle is not being clever, it is declining a cycle the
architecture handed it and paying for the refusal in Fmax.
---------------------------------------------------------------------------
"""

import sys
import os

# ---------------------------------------------------------------------------
# Symbolic values.  Names here become `UC_<NAME>` localparams in the .vh.
# ---------------------------------------------------------------------------

# addr_sel - where the address bus comes from.  Every one of these is a plain
# concatenation of registers except AGU; keeping them separate means the AGU is
# free to compute a value to LATCH while the bus shows something else, which is
# what the dummy-read cycles need.
# LAST is the address driven during the previous bus cycle, and it is what every
# CMOS dummy cycle selects.  The NMOS part put a half-computed effective address
# on the bus during an internal cycle; the 65C02 re-reads whatever it read last.
# One source covers all of it - the operand byte for zp,X and abs,X, the
# pointer's high byte for (zp),Y, PC for a taken branch - because that is
# genuinely one rule and not six coincidences.  Measured against a real part
# over 24.7 million cycles; see docs/DERISK.md.
# FIXUP is LAST or AD depending on whether the index actually carried, decided
# in hardware from the saved carry.  It exists because the part's behaviour on
# the indexed fixup cycle is not a property of the INSTRUCTION but of the DATA:
# if the address needed fixing it re-reads the last program byte, and if it did
# not it drives the effective address.  Microcode cannot see that; the AGU's
# saved carry can.
ADDR = dict(PC=0, AGU=1, ZP=2, AD=3, SP=4, VEC=5, VEC1=6, LAST=7, FIXUP=8)

# AGU low-half operands.  agu_lo = lo_a + lo_b + lo_ci, 8 bits, carry out.
LO_A = dict(ADL=0, PCL=1, S=2, MD=3)
# DIN=6 is retired: no microinstruction ever fed the bus into the adder, but
# the mux arm in the RTL put the instruction front's combinational serve path
# in series with the AGU carry chain on every timing path through the adder -
# the depth audit's whole 18-20-level tail.  The encoding is left unassigned so
# a stale ROM that somehow contains it selects ZERO, not the bus.
LO_B = dict(ZERO=0, X=1, Y=2, ONE=3, FF=4, ADL=5, VEC=7)

# AGU high half.  agu_hi = hi_a + carry_term - dec_term.  NEVER a second
# 8-bit operand - see the design rule above.
HI_A = dict(ADH=0, PCH=1, ZERO=2, ONE=3, FF=4)
# LIVE=1 is retired - the high byte never consumes a live carry (the rule in
# the header).  The encoding stays unassigned; the RTL treats it as NONE.
HI_C = dict(NONE=0, SAVED=2)              # carry_term
HI_D = dict(NONE=0, ONE=1, SIGN=2)        # dec_term, SIGN = ADL[7] for branches

# Register loads
LD_ADL = dict(NONE=0, AGU=1, DIN=2, MD=3)
LD_ADH = dict(NONE=0, AGU=1, DIN=2)
LD_PC  = dict(NONE=0, INC=1, AGU=2, AGU_LO=3, AGU_HI=4, JMP=5)   # JMP: {din, MD}
LD_S   = dict(NONE=0, INC=1, DEC=2)

# Write data source
DOUT = dict(A=0, X=1, Y=2, ZERO=3, P_B=4, PCL=5, PCH=6, MD=7)

# ALU
OP = dict(NOP=0, LD=1, AND=2, ORA=3, EOR=4, ADC=5, SBC=6, CMP=7, CPX=8,
          CPY=9, BIT=10, BITI=11, ASL=12, LSR=13, ROL=14, ROR=15, INC=16,
          DEC=17, TRB=18, TSB=19, RMB=20, SMB=21, FLAG=22, TXS=23,
          DADC=24, DSBC=25)
ALU_A = dict(DIN=0, A=1, X=2, Y=3, S=4, ZERO=5, MD=6)
WB    = dict(NONE=0, A=1, X=2, Y=3, S=4, MD=5, P=6)

# Sequencing: next = cond ? (ucycle + 1) : alt
COND = dict(ALWAYS=0, NEVER=1, CARRY=2, BRANCH=3, PAGE=4, DEC=5, ZPBIT=6)

# ---------------------------------------------------------------------------
# Microinstruction layout.  Order here is the bit order in the ROM word.
# ---------------------------------------------------------------------------
FIELDS = [
    ("sync",      1),   # this cycle is an opcode fetch
    ("rw",        1),   # 1 = read, 0 = write
    ("addr_sel",  4),
    ("lo_a",      2),
    ("lo_b",      3),
    ("lo_ci",     1),
    ("hi_a",      3),
    ("hi_c",      2),
    ("hi_d",      2),
    ("ld_adl",    2),
    ("ld_adh",    2),
    ("ld_pc",     3),
    ("ld_s",      2),
    ("ld_if",     1),   # gate all register loads on the condition
    ("dout",      3),
    ("alu_op",    5),
    ("alu_a",     3),
    ("wb",        3),
    ("fl",        1),   # update flags from the ALU
    ("seti",      1),   # set I and clear D (interrupt entry)
    ("cond",      3),
    ("alt",       3),
]
WIDTH = sum(w for _, w in FIELDS)

DEFAULTS = dict(sync=0, rw=1, addr_sel=ADDR["PC"], lo_a=LO_A["ADL"],
                lo_b=LO_B["ZERO"], lo_ci=0, hi_a=HI_A["ADH"], hi_c=HI_C["NONE"],
                hi_d=HI_D["NONE"], ld_adl=0, ld_adh=0, ld_pc=0, ld_s=0, ld_if=0,
                dout=DOUT["A"], alu_op=OP["NOP"], alu_a=ALU_A["DIN"], wb=0,
                fl=0, seti=0, cond=COND["ALWAYS"], alt=0)


def u(**kw):
    """One microinstruction.  `alt` may be a string label, resolved later."""
    m = dict(DEFAULTS)
    for k, v in kw.items():
        if k not in DEFAULTS and k != "label":
            raise KeyError(f"unknown microinstruction field {k}")
        m[k] = v
    return m


def encode(m):
    word = 0
    pos = 0
    for name, w in FIELDS:
        v = m[name]
        if not isinstance(v, int):
            raise TypeError(f"field {name} unresolved: {v!r}")
        if v >= (1 << w) or v < 0:
            raise ValueError(f"field {name}={v} does not fit in {w} bits")
        word |= v << pos
        pos += w
    return word


# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------

FETCH = dict(sync=1, addr_sel=ADDR["PC"], ld_pc=LD_PC["INC"])


def fetch():
    return u(**FETCH)


def read_operand(**kw):
    """Read a byte at PC and advance.  The workhorse prefix cycle."""
    return u(addr_sel=ADDR["PC"], ld_pc=LD_PC["INC"], **kw)


def index_lo(idx, alt, always=False):
    """Add an index to the address low byte, deferring the carry.

    This is the cycle the design rule is about.  Only the LOW byte is added
    here; if it carried, the next microinstruction fixes the high byte, and
    that microinstruction is the extra cycle the instruction set already
    charges for a page crossing.  `always` forces it even without a carry,
    which is what stores and INC/DEC abs,X do.
    """
    return dict(lo_a=LO_A["ADL"], lo_b=idx, ld_adl=LD_ADL["AGU"],
                cond=COND["ALWAYS"] if always else COND["CARRY"], alt=alt)


def fixup(bus="fixup"):
    """Propagate the deferred carry into the address high byte.

    ADH moves by the SAVED carry, not by one.  The distinction matters because
    stores and INC/DEC abs,X spend this cycle unconditionally - they are here
    even when the index did not carry, and incrementing regardless puts the
    store a page high.  Reads only arrive here when the carry was set, so they
    cannot tell the two apart, which is what makes this a store-only bug.

    WHAT THE BUS SHOWS SPLITS, and it splits on whether the cycle is CONDITIONAL
    or MANDATORY - which is not a distinction anyone would have guessed, and is
    measured rather than reasoned:

    WHAT THE BUS SHOWS is not a property of the instruction, which is what made
    it hard to guess and easy to measure:

      abs,X / abs,Y   if the index CARRIED, the part re-reads the last program
                      byte - the high operand.  If it did not, it drives the
                      effective address, which in that case is already correct.
                      Reads and the shifts only reach this cycle on a carry, so
                      they always take the first form; stores and INC/DEC reach
                      it either way and take both.  ADDR["FIXUP"] is that
                      choice, made in hardware from the saved carry, because the
                      microcode cannot see the data.

      (zp),Y          re-reads the pointer's own high byte in page zero, carry
                      or no carry.  So STA (zp),Y re-reads its pointer while
                      STA abs,X does not - an asymmetry with no obvious reason
                      behind it, and the trace is the authority.

    All of this used to be the un-fixed address unconditionally - a defensible
    guess before there was a part to compare against.  Of the 77 differences the
    bustest capture found, 26 were this one cycle.
    """
    return u(addr_sel=ADDR["FIXUP"] if bus == "fixup" else ADDR["LAST"],
             hi_a=HI_A["ADH"], hi_c=HI_C["SAVED"], ld_adh=LD_ADH["AGU"])


# ---------------------------------------------------------------------------
# Addressing modes.  Each returns (prefix_slots, access_addr_sel).
# The access slot itself is appended by the caller, which knows whether the
# instruction reads, writes or does both.
# ---------------------------------------------------------------------------

def am_imp():
    # Dummy read of the byte after the opcode; pc does NOT advance.
    return [], ADDR["PC"]


def am_imm():
    return [], ADDR["PC"]


def am_zp():
    return [read_operand(ld_adl=LD_ADL["DIN"])], ADDR["ZP"]


def am_zpidx(idx):
    return [read_operand(ld_adl=LD_ADL["DIN"]),
            # The dummy cycle, indexing as it goes.  Zero page wraps, so the
            # carry is simply dropped - no fixup cycle, and none is charged for.
            # The bus re-reads the operand byte (LAST); the NMOS part showed the
            # un-indexed zero-page address here instead.
            u(addr_sel=ADDR["LAST"], lo_a=LO_A["ADL"], lo_b=idx,
              ld_adl=LD_ADL["AGU"])], ADDR["ZP"]


def am_abs():
    return [read_operand(ld_adl=LD_ADL["DIN"]),
            read_operand(ld_adh=LD_ADH["DIN"])], ADDR["AD"]


def am_absidx(idx, always, acc_label):
    return [read_operand(ld_adl=LD_ADL["DIN"]),
            read_operand(ld_adh=LD_ADH["DIN"], **index_lo(idx, acc_label, always)),
            fixup()], ADDR["AD"]


def am_idx():
    # (zp,X): index the pointer in page zero, then read the two pointer bytes.
    return [read_operand(ld_adl=LD_ADL["DIN"]),
            # Indexing the pointer is internal work, so the bus re-reads the
            # operand byte rather than showing the un-indexed zero-page address.
            u(addr_sel=ADDR["LAST"], lo_a=LO_A["ADL"], lo_b=LO_B["X"],
              ld_adl=LD_ADL["AGU"]),
            u(addr_sel=ADDR["ZP"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
              wb=WB["MD"], lo_a=LO_A["ADL"], lo_b=LO_B["ONE"],
              ld_adl=LD_ADL["AGU"]),
            u(addr_sel=ADDR["ZP"], ld_adh=LD_ADH["DIN"],
              ld_adl=LD_ADL["MD"])], ADDR["AD"]


def am_idy(always, acc_label):
    # (zp),Y: read the pointer, then index it - with the same deferred carry.
    return [read_operand(ld_adl=LD_ADL["DIN"]),
            u(addr_sel=ADDR["ZP"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
              wb=WB["MD"], lo_a=LO_A["ADL"], lo_b=LO_B["ONE"],
              ld_adl=LD_ADL["AGU"]),
            u(addr_sel=ADDR["ZP"], ld_adh=LD_ADH["DIN"],
              lo_a=LO_A["MD"], lo_b=LO_B["Y"], ld_adl=LD_ADL["AGU"],
              cond=COND["ALWAYS"] if always else COND["CARRY"], alt=acc_label),
            fixup(bus="last")], ADDR["AD"]


def am_ind():
    # (zp), the CMOS addressing mode - no indexing, so no carry to defer.
    return [read_operand(ld_adl=LD_ADL["DIN"]),
            u(addr_sel=ADDR["ZP"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
              wb=WB["MD"], lo_a=LO_A["ADL"], lo_b=LO_B["ONE"],
              ld_adl=LD_ADL["AGU"]),
            u(addr_sel=ADDR["ZP"], ld_adh=LD_ADH["DIN"],
              ld_adl=LD_ADL["MD"])], ADDR["AD"]


MODES = {
    "imp":  am_imp,   "imm": am_imm,  "zp":  am_zp,
    "abs":  am_abs,   "idx": am_idx,  "ind": am_ind,
}


def build(mode, acc, op=OP["NOP"], alu_a=ALU_A["DIN"], wb=WB["NONE"], fl=0,
          dout=None, decimal=False):
    """Assemble one instruction's microcode from a mode and an access kind."""
    ACC = "acc"
    always = (acc == "write") or (acc == "rmw" and op in (OP["INC"], OP["DEC"]))

    if mode == "zpx":     pre, asel = am_zpidx(LO_B["X"])
    elif mode == "zpy":   pre, asel = am_zpidx(LO_B["Y"])
    elif mode == "abx":   pre, asel = am_absidx(LO_B["X"], always, ACC)
    elif mode == "aby":   pre, asel = am_absidx(LO_B["Y"], always, ACC)
    elif mode == "idy":   pre, asel = am_idy(always, ACC)
    else:                 pre, asel = MODES[mode]()

    slots = list(pre)

    if acc == "none":
        # Implied / accumulator: the dummy read at pc is where the work happens.
        slots.append(u(addr_sel=ADDR["PC"], alu_op=op, alu_a=alu_a, wb=wb, fl=fl,
                       label=ACC))
    elif acc == "read":
        s = u(addr_sel=asel, alu_op=op, alu_a=alu_a, wb=wb, fl=fl, label=ACC)
        if mode == "imm":
            s["ld_pc"] = LD_PC["INC"]
        slots.append(s)
    elif acc == "write":
        s = u(addr_sel=asel, rw=0, dout=dout, label=ACC)
        slots.append(s)
    elif acc == "rmw":
        slots.append(u(addr_sel=asel, label=ACC))                       # read
        slots.append(u(addr_sel=asel, alu_op=op, alu_a=ALU_A["DIN"],    # compute
                       wb=WB["MD"], fl=fl))
        slots.append(u(addr_sel=asel, rw=0, dout=DOUT["MD"]))           # write

    if decimal:
        # ADC/SBC take one more cycle on the 65C02 when D is set.  Skipping it
        # is a conditional slot, so the binary case costs nothing.
        #
        # The decimal OPERATION runs in that cycle (2026-09-14).  With D set
        # the read slot writes nothing (rtl/cpu65c02.sv dec_defer) and the core
        # keeps the operand it read (dm); this slot does the BCD add from
        # registers and lands A and N/V/Z/C.  The bus cycle is the same dummy
        # read at PC it always was.  What it buys: the nibble correction is off
        # the served byte's path into A and the flags - the IIe's deepest
        # core chain ran through it (build woz5, dline -> f_z at 15 levels).
        slots[-1]["cond"] = COND["DEC"]
        slots[-1]["alt"] = "end"
        slots.append(u(addr_sel=ADDR["PC"], alu_a=ALU_A["A"], wb=WB["A"], fl=1,
                       alu_op=OP["DADC"] if op == OP["ADC"] else OP["DSBC"]))

    slots.append(u(**FETCH, label="end"))
    return slots


# ---------------------------------------------------------------------------
# The opcode table
# ---------------------------------------------------------------------------
PROG = {}


def put(opcode, slots):
    if opcode in PROG:
        raise KeyError(f"opcode ${opcode:02X} defined twice")
    PROG[opcode] = slots


def group(opcodes_modes, **kw):
    for opcode, mode, acc in opcodes_modes:
        put(opcode, build(mode, acc, **kw))


# ---- loads ----------------------------------------------------------------
for oc, mode in [(0xA9, "imm"), (0xA5, "zp"), (0xB5, "zpx"), (0xAD, "abs"),
                 (0xBD, "abx"), (0xB9, "aby"), (0xA1, "idx"), (0xB1, "idy"),
                 (0xB2, "ind")]:
    put(oc, build(mode, "read", op=OP["LD"], wb=WB["A"], fl=1))
for oc, mode in [(0xA2, "imm"), (0xA6, "zp"), (0xB6, "zpy"), (0xAE, "abs"),
                 (0xBE, "aby")]:
    put(oc, build(mode, "read", op=OP["LD"], wb=WB["X"], fl=1))
for oc, mode in [(0xA0, "imm"), (0xA4, "zp"), (0xB4, "zpx"), (0xAC, "abs"),
                 (0xBC, "abx")]:
    put(oc, build(mode, "read", op=OP["LD"], wb=WB["Y"], fl=1))

# ---- stores ---------------------------------------------------------------
for oc, mode in [(0x85, "zp"), (0x95, "zpx"), (0x8D, "abs"), (0x9D, "abx"),
                 (0x99, "aby"), (0x81, "idx"), (0x91, "idy"), (0x92, "ind")]:
    put(oc, build(mode, "write", dout=DOUT["A"]))
for oc, mode in [(0x86, "zp"), (0x96, "zpy"), (0x8E, "abs")]:
    put(oc, build(mode, "write", dout=DOUT["X"]))
for oc, mode in [(0x84, "zp"), (0x94, "zpx"), (0x8C, "abs")]:
    put(oc, build(mode, "write", dout=DOUT["Y"]))
for oc, mode in [(0x64, "zp"), (0x74, "zpx"), (0x9C, "abs"), (0x9E, "abx")]:
    put(oc, build(mode, "write", dout=DOUT["ZERO"]))

# ---- transfers ------------------------------------------------------------
put(0xAA, build("imp", "none", op=OP["LD"], alu_a=ALU_A["A"], wb=WB["X"], fl=1))
put(0xA8, build("imp", "none", op=OP["LD"], alu_a=ALU_A["A"], wb=WB["Y"], fl=1))
put(0x8A, build("imp", "none", op=OP["LD"], alu_a=ALU_A["X"], wb=WB["A"], fl=1))
put(0x98, build("imp", "none", op=OP["LD"], alu_a=ALU_A["Y"], wb=WB["A"], fl=1))
put(0xBA, build("imp", "none", op=OP["LD"], alu_a=ALU_A["S"], wb=WB["X"], fl=1))
put(0x9A, build("imp", "none", op=OP["TXS"], alu_a=ALU_A["X"], wb=WB["S"], fl=0))

# ---- ALU ------------------------------------------------------------------
ALU_MODES = [("imm", 0x09), ("zp", 0x05), ("zpx", 0x15), ("abs", 0x0D),
             ("abx", 0x1D), ("aby", 0x19), ("idx", 0x01), ("idy", 0x11),
             ("ind", 0x12)]
for base, op, dec in [(0x00, OP["ORA"], False), (0x20, OP["AND"], False),
                      (0x40, OP["EOR"], False), (0x60, OP["ADC"], True),
                      (0xE0, OP["SBC"], True), (0xC0, OP["CMP"], False)]:
    for mode, off in ALU_MODES:
        wb = WB["NONE"] if op == OP["CMP"] else WB["A"]
        put(base | off, build(mode, "read", op=op, wb=wb, fl=1, decimal=dec))

for oc, mode in [(0xE0, "imm"), (0xE4, "zp"), (0xEC, "abs")]:
    put(oc, build(mode, "read", op=OP["CPX"], fl=1))
for oc, mode in [(0xC0, "imm"), (0xC4, "zp"), (0xCC, "abs")]:
    put(oc, build(mode, "read", op=OP["CPY"], fl=1))
for oc, mode in [(0x24, "zp"), (0x34, "zpx"), (0x2C, "abs"), (0x3C, "abx")]:
    put(oc, build(mode, "read", op=OP["BIT"], fl=1))
put(0x89, build("imm", "read", op=OP["BITI"], fl=1))

# ---- read-modify-write ----------------------------------------------------
for base, op in [(0x00, OP["ASL"]), (0x20, OP["ROL"]), (0x40, OP["LSR"]),
                 (0x60, OP["ROR"])]:
    put(base | 0x0A, build("imp", "none", op=op, alu_a=ALU_A["A"], wb=WB["A"], fl=1))
    for mode, off in [("zp", 0x06), ("zpx", 0x16), ("abs", 0x0E), ("abx", 0x1E)]:
        put(base | off, build(mode, "rmw", op=op, fl=1))
for base, op in [(0xC0, OP["DEC"]), (0xE0, OP["INC"])]:
    for mode, off in [("zp", 0x06), ("zpx", 0x16), ("abs", 0x0E), ("abx", 0x1E)]:
        put(base | off, build(mode, "rmw", op=op, fl=1))
put(0x1A, build("imp", "none", op=OP["INC"], alu_a=ALU_A["A"], wb=WB["A"], fl=1))
put(0x3A, build("imp", "none", op=OP["DEC"], alu_a=ALU_A["A"], wb=WB["A"], fl=1))
put(0xE8, build("imp", "none", op=OP["INC"], alu_a=ALU_A["X"], wb=WB["X"], fl=1))
put(0xC8, build("imp", "none", op=OP["INC"], alu_a=ALU_A["Y"], wb=WB["Y"], fl=1))
put(0xCA, build("imp", "none", op=OP["DEC"], alu_a=ALU_A["X"], wb=WB["X"], fl=1))
put(0x88, build("imp", "none", op=OP["DEC"], alu_a=ALU_A["Y"], wb=WB["Y"], fl=1))

put(0x14, build("zp", "rmw", op=OP["TRB"], fl=1))
put(0x1C, build("abs", "rmw", op=OP["TRB"], fl=1))
put(0x04, build("zp", "rmw", op=OP["TSB"], fl=1))
put(0x0C, build("abs", "rmw", op=OP["TSB"], fl=1))
# Rockwell's RMBn / SMBn are NOT on the base part.  $x7 is a one-byte NOP there;
# see the CMOS no-op table below, which is where those encodings now live.

# ---- flags ----------------------------------------------------------------
for oc in (0x18, 0x38, 0x58, 0x78, 0xB8, 0xD8, 0xF8):
    put(oc, build("imp", "none", op=OP["FLAG"]))

# ---- branches -------------------------------------------------------------
# Three slots, and which of them run is the whole cycle-count story: 2 cycles
# not taken, 3 taken, 4 when the low-byte add carried out of the page.  The
# fourth cycle is where PCH moves - never in the same cycle as the PCL add.
def branch(cond):
    return [
        read_operand(ld_adl=LD_ADL["DIN"], cond=cond, alt="end"),
        # PCL + offset, 8 bits.  PCH is left alone; if the add stayed inside
        # the page it was already correct.
        u(addr_sel=ADDR["PC"], lo_a=LO_A["PCL"], lo_b=LO_B["ADL"],
          hi_a=HI_A["PCH"], ld_pc=LD_PC["AGU_LO"], cond=COND["PAGE"], alt="end"),
        # The page did change: this is the granted cycle, and all it does is
        # move PCH by one.  The bus re-reads what the previous cycle drove,
        # which was PC before the low byte moved - ADDR["PC"] would give the
        # half-updated {old PCH, new PCL} instead, which is the NMOS behaviour.
        u(addr_sel=ADDR["LAST"], hi_a=HI_A["PCH"], hi_c=HI_C["SAVED"],
          hi_d=HI_D["SIGN"], ld_pc=LD_PC["AGU_HI"]),
        u(**FETCH, label="end"),
    ]


for oc in (0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0):
    put(oc, branch(COND["BRANCH"]))
put(0x80, branch(COND["ALWAYS"]))

# Rockwell's BBRn / BBSn are NOT on the base part either.  $xF is a one-byte
# NOP there; see the CMOS no-op table below.

# ---- jumps ----------------------------------------------------------------
put(0x4C, [                                            # JMP abs
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MD"]),
    u(addr_sel=ADDR["PC"], ld_pc=LD_PC["JMP"]),
    u(**FETCH),
])

# JMP (abs) is SIX cycles on the 65C02 against five on the NMOS part, and the
# extra one is exactly the carry cycle: the NMOS bug is that it never fixes the
# pointer high byte, so ($xxFF) wraps within the page.  Spending a cycle on
# ADH + carry is both the fix and the reason the count went up.
put(0x6C, [
    read_operand(ld_adl=LD_ADL["DIN"]),
    read_operand(ld_adh=LD_ADH["DIN"]),
    # The CMOS extra cycle - the one that buys the page-wrap fix.  It re-reads
    # the pointer's high byte, which is what the cycle before it drove - and it
    # PROBES the pointer increment: ADL+1 runs through the low adder with
    # nothing loaded, purely so agu_c catches the carry-out.  This is the cycle
    # the carry was granted; spending it here is what lets the next cycle take
    # the carry SAVED instead of live off the adder.
    u(addr_sel=ADDR["LAST"], lo_a=LO_A["ADL"], lo_b=LO_B["ONE"]),
    # Read the target low byte and increment the POINTER: the low half re-runs
    # the same ADL+1 (register-direct, cheap), the high half moves by the carry
    # the probe cycle saved.  The high half must land here and not in the next
    # one: the next cycle is the one that reads the target high byte at
    # {ADH, ADL}, and an ADH that updates on that cycle's own edge is still
    # stale when the address is driven - which reproduces precisely the NMOS
    # ($xxFF) page-wrap bug this instruction spends its sixth cycle to avoid.
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MD"],
      lo_a=LO_A["ADL"], lo_b=LO_B["ONE"], ld_adl=LD_ADL["AGU"],
      hi_a=HI_A["ADH"], hi_c=HI_C["SAVED"], ld_adh=LD_ADH["AGU"]),
    u(addr_sel=ADDR["AD"], ld_pc=LD_PC["JMP"]),
    u(**FETCH),
])
put(0x7C, [                                            # JMP (abs,X)
    read_operand(ld_adl=LD_ADL["DIN"]),
    read_operand(ld_adh=LD_ADH["DIN"], lo_a=LO_A["ADL"], lo_b=LO_B["X"],
                 ld_adl=LD_ADL["AGU"]),
    # The X index carry lands here (SAVED, from the cycle above) - and the same
    # cycle probes the POINTER increment's carry: ADL already holds the indexed
    # low byte, so ADL+1 through the low adder is the increment the next cycle
    # needs, and agu_c catches its carry-out at this cycle's edge, just after
    # the high half here consumed the X carry.  One register, two carries, one
    # cycle apart - which is exactly the spacing the instruction's six cycles
    # grant.
    u(addr_sel=ADDR["LAST"], hi_a=HI_A["ADH"], hi_c=HI_C["SAVED"],
      ld_adh=LD_ADH["AGU"], lo_a=LO_A["ADL"], lo_b=LO_B["ONE"]),
    # Same as JMP (abs): the pointer increment completes here, a cycle before the
    # address it produces is driven, its carry taken SAVED from the probe above.
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MD"],
      lo_a=LO_A["ADL"], lo_b=LO_B["ONE"], ld_adl=LD_ADL["AGU"],
      hi_a=HI_A["ADH"], hi_c=HI_C["SAVED"], ld_adh=LD_ADH["AGU"]),
    u(addr_sel=ADDR["AD"], ld_pc=LD_PC["JMP"]),
    u(**FETCH),
])

put(0x20, [                                            # JSR abs
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MD"]),
    u(addr_sel=ADDR["SP"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCH"], ld_s=LD_S["DEC"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCL"], ld_s=LD_S["DEC"]),
    u(addr_sel=ADDR["PC"], ld_pc=LD_PC["JMP"]),
    u(**FETCH),
])
put(0x60, [                                            # RTS
    u(addr_sel=ADDR["PC"]),
    u(addr_sel=ADDR["SP"], ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MD"],
      ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], ld_pc=LD_PC["JMP"]),
    u(addr_sel=ADDR["PC"], ld_pc=LD_PC["INC"]),
    u(**FETCH),
])
put(0x40, [                                            # RTI
    u(addr_sel=ADDR["PC"]),
    u(addr_sel=ADDR["SP"], ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], wb=WB["P"], ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MD"],
      ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], ld_pc=LD_PC["JMP"]),
    u(**FETCH),
])

# ---- stack ----------------------------------------------------------------
for oc, src in [(0x48, DOUT["A"]), (0x08, DOUT["P_B"]), (0xDA, DOUT["X"]),
                (0x5A, DOUT["Y"])]:
    put(oc, [u(addr_sel=ADDR["PC"]),
             u(addr_sel=ADDR["SP"], rw=0, dout=src, ld_s=LD_S["DEC"]),
             u(**FETCH)])
for oc, wb in [(0x68, WB["A"]), (0xFA, WB["X"]), (0x7A, WB["Y"])]:
    put(oc, [u(addr_sel=ADDR["PC"]),
             u(addr_sel=ADDR["SP"], ld_s=LD_S["INC"]),
             u(addr_sel=ADDR["SP"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
               wb=wb, fl=1),
             u(**FETCH)])
put(0x28, [u(addr_sel=ADDR["PC"]),                     # PLP
           u(addr_sel=ADDR["SP"], ld_s=LD_S["INC"]),
           u(addr_sel=ADDR["SP"], wb=WB["P"]),
           u(**FETCH)])

# ---- BRK, and the interrupt sequence that shares it -----------------------
# IRQ/NMI/RESET all run this same microcode; hardware suppresses the pc
# increment, picks the vector, and forces the pushes to reads for reset.
put(0x00, [
    read_operand(),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCH"], ld_s=LD_S["DEC"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCL"], ld_s=LD_S["DEC"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["P_B"], ld_s=LD_S["DEC"], seti=1),
    u(addr_sel=ADDR["VEC"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MD"]),
    u(addr_sel=ADDR["VEC1"], ld_pc=LD_PC["JMP"]),
    u(**FETCH),
])

# ---- STP / WAI ------------------------------------------------------------
# WDC's, and not on the base part.  $CB and $DB are one-byte NOPs there, in the
# table below with the rest of $xB.
#
# The RTL still carries the `hlt` register and the `halted` output, and they are
# INERT against this ROM rather than dead code: `hlt` is set by `ir == $DB` at
# `ucyc == 3'd1`, and a one-cycle NOP never reaches ucyc 1.  Leaving them costs
# nothing and is what a WDC variant of this ROM would need.

# ---- CMOS no-ops ----------------------------------------------------------
put(0xEA, build("imp", "none"))
# Every $x3, $x7, $xB and $xF: one byte, one cycle, on the base 65C02.  The $x7
# and $xF columns are Rockwell's bit instructions and the $CB/$DB pair is WDC's
# WAI/STP - none of which the first-generation part has - so on it they are
# simply the shortest NOP the encoding space has.
for column in (0x03, 0x07, 0x0B, 0x0F):
    for hi in range(0x00, 0x100, 0x10):
        put(hi | column, [u(**FETCH)])                  # 1 byte, 1 cycle
for oc in [0x02, 0x22, 0x42, 0x62, 0x82, 0xC2, 0xE2]:
    put(oc, build("imm", "read", op=OP["NOP"]))        # 2 bytes, 2 cycles
put(0x44, build("zp", "read", op=OP["NOP"]))           # 2 bytes, 3 cycles
for oc in [0x54, 0xD4, 0xF4]:
    put(oc, build("zpx", "read", op=OP["NOP"]))        # 2 bytes, 4 cycles
for oc in [0xDC, 0xFC]:
    put(oc, build("abs", "read", op=OP["NOP"]))        # 3 bytes, 4 cycles
# $5C is the odd one: three bytes, eight cycles, and five of them driving
# addresses that no functional test can see.  A real part drives {$FF, operand
# low} once and then $FFFF four times, so the first operand byte has to be kept
# - the old version left ADL stale and produced {$FF, junk-1} for all five.
#
# $FFFF comes from VEC1, which is {$FF, vec_lo + 1} and vec_lo is $FE outside a
# reset or an NMI entry - neither of which can be in progress during a NOP.
put(0x5C, [                                            # 3 bytes, 8 cycles
    read_operand(ld_adl=LD_ADL["DIN"]),
    read_operand(),
    u(addr_sel=ADDR["AGU"], lo_a=LO_A["ADL"], lo_b=LO_B["ZERO"], hi_a=HI_A["FF"]),
] + [u(addr_sel=ADDR["VEC1"]) for _ in range(4)] + [u(**FETCH)])


# ---------------------------------------------------------------------------
# Resolve labels, check, emit
# ---------------------------------------------------------------------------
SLOTS = 8


def resolve(opcode, slots):
    labels = {"end": len(slots) - 1}
    for i, s in enumerate(slots):
        if s.get("label"):
            labels[s["label"]] = i
    for s in slots:
        s.pop("label", None)
        if isinstance(s["alt"], str):
            if s["alt"] not in labels:
                raise KeyError(f"${opcode:02X}: unknown label {s['alt']}")
            s["alt"] = labels[s["alt"]]
    if len(slots) > SLOTS:
        raise ValueError(f"${opcode:02X}: {len(slots)} slots, max {SLOTS}")
    return slots


def emit_vh(path):
    lines = [
        "// GENERATED by sim/gen_microcode.py - do not edit.",
        "// Field positions and symbolic values for the cpu65c02 microcode ROM.",
        "// Regenerate with:  python3 sim/gen_microcode.py",
        f"localparam int UC_W = {WIDTH};",
        f"localparam int UC_SLOTS_LOG2 = 3;",
        "",
    ]
    pos = 0
    for name, w in FIELDS:
        lines.append(f"localparam int UCP_{name.upper()} = {pos};")
        lines.append(f"localparam int UCW_{name.upper()} = {w};")
        pos += w
    lines.append("")
    # Sized, not bare ints.  Every one of these is compared against a field of
    # known width, and a 32-bit localparam makes the comparison width-mismatch
    # on every use - twenty lint warnings that say nothing.  The generator knows
    # each group's field width, so it emits constants that already fit.
    groups = [("ADDR", ADDR, "addr_sel"), ("LO_A", LO_A, "lo_a"),
              ("LO_B", LO_B, "lo_b"), ("HI_A", HI_A, "hi_a"),
              ("HI_C", HI_C, "hi_c"), ("HI_D", HI_D, "hi_d"),
              ("LD_ADL", LD_ADL, "ld_adl"), ("LD_ADH", LD_ADH, "ld_adh"),
              ("LD_PC", LD_PC, "ld_pc"), ("LD_S", LD_S, "ld_s"),
              ("DOUT", DOUT, "dout"), ("OP", OP, "alu_op"),
              ("ALU_A", ALU_A, "alu_a"), ("WB", WB, "wb"),
              ("COND", COND, "cond")]
    widths = dict(FIELDS)
    for group_name, table, field in groups:
        w = widths[field]
        for k, v in table.items():
            lines.append(f"localparam logic [{w - 1}:0] "
                         f"UC_{group_name}_{k} = {w}'d{v};")
        lines.append("")
    return "\n".join(lines) + "\n"


def emit_hex():
    # Unused slots read as an unconditional jump back to fetch, so a microcode
    # bug that runs off the end of a sequence resynchronises at the next
    # instruction instead of wandering the ROM.
    filler = encode(u(**FETCH))
    out = []
    for opcode in range(256):
        slots = resolve(opcode, PROG[opcode]) if opcode in PROG else []
        words = [encode(s) for s in slots]
        words += [filler] * (SLOTS - len(words))
        nib = (WIDTH + 3) // 4
        for i, w in enumerate(words):
            out.append(f"{w:0{nib}x}")
    return "\n".join(out) + "\n"


def check_decimal():
    """The shape rtl/cpu65c02.sv's dec_defer rests on: every ADC/SBC word is
    a slot whose condition is DEC and whose successor is the matching decimal
    word, and a decimal word appears nowhere else.  A binary ADC/SBC anywhere
    else would have its writes suppressed in decimal mode."""
    pair = {OP["ADC"]: OP["DADC"], OP["SBC"]: OP["DSBC"]}
    for oc in range(256):
        slots = PROG[oc]
        for i, m in enumerate(slots):
            if m["alu_op"] in pair:
                nxt = slots[i + 1] if i + 1 < len(slots) else None
                if m["cond"] != COND["DEC"] or nxt is None or nxt["alu_op"] != pair[m["alu_op"]]:
                    sys.exit(f"ERROR: ${oc:02X} slot {i}: ADC/SBC without its decimal slot")
            if m["alu_op"] in pair.values():
                prev = slots[i - 1] if i > 0 else None
                if prev is None or pair.get(prev["alu_op"]) != m["alu_op"]:
                    sys.exit(f"ERROR: ${oc:02X} slot {i}: a decimal word not after its ADC/SBC")


def main():
    missing = [f"${o:02X}" for o in range(256) if o not in PROG]
    if missing:
        sys.exit(f"ERROR: {len(missing)} opcodes undefined: {' '.join(missing)}")
    check_decimal()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    vh = os.path.join(root, "rtl", "cpu65c02_ucode.vh")
    hx = os.path.join(root, "rtl", "cpu65c02_ucode.hex")
    vh_text, hx_text = emit_vh(vh), emit_hex()

    if "--check" in sys.argv:
        bad = False
        for path, text in ((vh, vh_text), (hx, hx_text)):
            have = open(path).read() if os.path.exists(path) else None
            if have != text:
                print(f"STALE: {path}")
                bad = True
        if bad:
            sys.exit("Regenerate with: python3 sim/gen_microcode.py")
        print(f"microcode up to date ({WIDTH}-bit x {256 * SLOTS} words)")
        return

    open(vh, "w").write(vh_text)
    open(hx, "w").write(hx_text)
    used = sum(len(PROG[o]) for o in range(256))
    print(f"wrote {vh}")
    print(f"wrote {hx}: {256 * SLOTS} words x {WIDTH} bits "
          f"({used} used, {256 * SLOTS - used} filler)")


if __name__ == "__main__":
    main()
