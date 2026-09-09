#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
"""Assemble the cpu65816 microcode ROM.

Emits two generated files, both committed:

    rtl/cpu65816_ucode.vh    field positions and symbolic values
    rtl/cpu65816_ucode.hex   the ROM contents, one microinstruction per line

Both files come from the field table below, so the RTL cannot disagree with the
assembler about where a field lives.  That is the classic way a microcoded
design goes wrong - the ROM says one thing, the datapath decodes another, and
the symptom is an instruction that misbehaves in a way that looks like a logic
bug anywhere but in the bit numbering.  Generating both removes the possibility
rather than documenting the hazard.

Run with --check to verify the committed files are current.

---------------------------------------------------------------------------
WHAT SHAPES THIS MICROCODE

Microcode earns its place here because it lets the work be spread explicitly
across the cycles the instruction set already grants, rather than crammed into
one cycle by a state machine with nowhere else to put it.  The 65816 is
generous about this, and the interesting question is exactly where it stops
being generous - because that is what sets the width of the address adder.

Two of the three new indexed modes decompose into 8-bit adds:

    long,X   Five cycles flat: cycle 2 reads the address high byte and adds XL
             to ADL, cycle 3 reads the bank byte and adds XH + carry to ADH.
    abs,X    The low add rides the high-byte read; the high add is the fixup
             cycle the ISA grants for a page cross - or, when x=0, always.

One does not:

    (dp),Y   Six cycles with DL!=0, and the bus trace shows the pointer's high
             byte being read in the SAME cycle that produces the final address:
             ADL = MDL + YL and ADH = din + YH + carry, together.  There is no
             spare cycle to defer the high add into, because the one cycle the
             mode grants is already spent on the page-cross fixup.  [dp],Y and
             (sr,S),Y are the same shape, and [dp],Y carries on into the bank
             byte - a 24-bit chain.

So the AGU is a genuine 16-bit adder with a bank incrementer above it.  Measured
out of context the core runs at ~122 MHz, and the binding path is the sequencer
loop: the microcode ROM's output back to its own address input.  The AGU sits in
that loop, but not as address arithmetic - COND_CARRY/COND_IDX/COND_PAGE test
its carry out LIVE, so the next ROM address cannot form until the add resolves.
The single largest term in the path is not logic at all but the block RAM's
2.1 ns clock-to-out.  See docs/UCODE816.md.

This was checked against ground truth rather than a datasheet table - see
sim/gen_cycle_table816.py, which reads the cycle counts and the bus traces out
of the SingleStepTests/65816 suite.

THE MODE BITS DO NOT INDEX THE ROM.  An instruction's length depends on m, x,
DL and e, and the obvious thing to do - widen the ROM address with the mode
bits - multiplies the ROM by eight, to 64 block RAMs, which does not fit the
part at all.  Instead each mode-dependent cycle is an ordinary CONDITIONAL SLOT,
skipped by the sequencer.  The ROM stays {opcode, ucycle} with no mapping stage,
so there is no instruction decoder anywhere in the design.

One trap, and it cost the first four wrong sequences: a condition selects the
SUCCESSOR slot; it does not suppress the microinstruction carrying it.  A cycle
that must be skipped has to be tested by the slot BEFORE it.
---------------------------------------------------------------------------
"""

import sys
import os

# ---------------------------------------------------------------------------
# Symbolic values.  Names here become `UC_<NAME>` localparams in the .vh.
# ---------------------------------------------------------------------------

# addr_sel - where the 24-bit address bus comes from.  EVERY ONE of these is a
# plain concatenation of registers, and that is a property worth protecting: it
# means the live AGU result never reaches the address pins, so the adder is not
# in the address bus's cone at all.
#
# The first draft carried an AGU source here, copied from the 8-bit core, where
# a cycle could drive a freshly computed effective address straight onto the
# bus.  Every addressing mode in this core computes into ADL/ADH/BANK and drives
# from AD a cycle later, so it was never once used - and it cost timing on every
# path through the address mux.  DP and AGUSP went the same way.  If a future
# mode really needs to drive the AGU output directly, add it back knowingly;
# do not leave it here on the chance.
ADDR = dict(PC=0, AD=1, SP=2, VEC=3, VEC1=4)

# AGU low half: agu_lo = lo_a + lo_b + lo_ci, 8 bits, carry out.
LO_A = dict(ADL=0, PCL=1, SL=2, MDL=3, ZERO=4, DIN=5, ADH=6, DL=7)
LO_B = dict(ZERO=0, XL=1, YL=2, ONE=3, FF=4, DIN=5, DL=6, ADL=7)

# AGU high half: agu_hi = hi_a + hi_b + carry_term - dec_term.  With hi_c=LIVE
# this is chained to the low half, making the pair the 16-bit adder that (dp),Y
# forces - see the header.
HI_A = dict(ADH=0, PCH=1, ZERO=2, ONE=3, DIN=4, SH=5, MDH=6, DH=7)
# The second high operand: an index register's high byte, D's high byte, or -
# for the 16-bit relative branches - the offset's high byte.
HI_B = dict(ZERO=0, XH=1, YH=2, DH=3, MDH=4)
# LIVEW is the 6502's direct-page wrap: the live carry, EXCEPT in emulation
# mode with DL zero, where dp,X and the (dp) pointer's second byte stay inside
# the page.
HI_C = dict(NONE=0, LIVE=1, SAVED=2, LIVEW=3)
HI_D = dict(NONE=0, ONE=1, SIGN=2)

# Bank half: 24-bit addressing.  This one IS only ever a register plus a carry,
# because a bank boundary is only ever crossed by a carry out of the high byte
# - never by adding a second bank operand.  So the 24-bit address is a 16-bit
# adder with an 8-bit incrementer on top, not a 24-bit adder.
# Only two sources are ever selected: the bank already held, or the byte being
# read this cycle (the bank operand of a long address).  DBR/PBR/ZERO reach the
# bank register through ld_bk instead, which is where they are actually needed.
BK_A = dict(BANK=0, DIN=1)
# BORROW is ad_dec's partner: bank - 1 when the high byte wrapped, which the
# high half's ninth bit reports for a decrement (see the RTL).
BK_C = dict(NONE=0, LIVE=1, SAVED=2, BORROW=3)

# Register loads
LD_ADL = dict(NONE=0, AGU=1, DIN=2, MDL=3)
LD_ADH = dict(NONE=0, AGU=1, DIN=2, MDH=3)
LD_BK  = dict(NONE=0, AGU=1, DIN=2, DBR=3, PBR=4, ZERO=5)
# JMP takes {din, MDL}; MD takes {MDH, MDL}, for the jumps whose target was
# read into MD several cycles earlier.
# M3C is the block moves' rewind: PC - 3, and ONLY when the move has more bytes
# to do - the one conditional register load in the core, gated on the register
# it loads and nothing else (see the RTL's note on why there is no global one).
LD_PC  = dict(NONE=0, INC=1, AGU=2, AGU_LO=3, AGU_HI=4, JMP=5, JMPL=6, MD=7,
              M3C=8)
# INC/DEC are the 6502-era stack steps: in emulation mode they stay in page
# one.  INCN/DECN are the 65816-only instructions' steps - PEA, PEI, PER, PHD,
# PLD, PLB, JSL, RTL - which run S through all sixteen bits in emulation mode
# (a push at $0100 lands the next byte at $00FF); NORM then puts the high byte
# back to $01 on the instruction's last stack cycle, which is where the suite
# says it reads $01 again.  Native mode: all the same plain 16-bit steps.
LD_S   = dict(NONE=0, INC=1, DEC=2, AGU=3, INCN=4, DECN=5, NORM=6)

# Write data source
DOUT = dict(AL=0, AH=1, XL=2, XH=3, YL=4, YH=5, ZERO=6, P_B=7, PCL=8, PCH=9,
            PBR=10, MDL=11, MDH=12, DBR=13, DL=14, DH=15, ADL=16, ADH=17)

# ALU.  The adder stays 8 bits wide; 16-bit arithmetic is two passes over it,
# in the two cycles the instruction set already charges for a 16-bit operand.
OP = dict(NOP=0, LD=1, AND=2, ORA=3, EOR=4, ADC=5, SBC=6, CMP=7, CPX=8,
          CPY=9, BIT=10, BITI=11, ASL=12, LSR=13, ROL=14, ROR=15, INC=16,
          DEC=17, TRB=18, TSB=19, FLAG=20, XCE=21, REP=22, SEP=23, XBA=24,
          TCS=25, MOV=26)
ALU_A = dict(DIN=0, A=1, X=2, Y=3, S=4, D=5, MD=6, ZERO=7)

# Two kinds of write-back, and the distinction is the whole 8/16 story:
#
#   AL / AH   write ONE BYTE.  Used by the memory-driven operations, which
#             visit the accumulator twice because the operand took two bus
#             cycles - so each pass must touch only its own half.
#   A16 / X16 / Y16   write as many bytes as the MODE says.  Used by the
#             register operations (INC A, ASL A, the transfers), which are two
#             cycles whatever the width and so have to do all of it at once.
#
# S16 and D16 are always 16 bits wide: S and D have no 8-bit form in native
# mode, and emulation mode pins SH to $01 in the register file rather than
# here.
WB    = dict(NONE=0, AL=1, AH=2, XL=3, XH=4, YL=5, YH=6, MDL=7, MDH=8,
             P=9, DBR=10, PBR=11, DL=12, DH=13,
             A16=14, X16=15, Y16=16, S16=17, D16=18, MD16=19,
             # A written 16 bits wide REGARDLESS of M - the block-move count.
             AF16=20)

# Flag update mode.  A 16-bit operation sets Z from BOTH halves, N from the
# high one, and C/V from the high pass - so the two passes cannot use the same
# encoding.
FL = dict(NONE=0, B8=1, L16=2, H16=3)

# Bus class - what VDA/VPA say about this cycle.  NONE is an internal cycle
# (the address pins hold whatever, and nothing may act on them), P a program
# read (an operand byte at PC), D a data access, PD an opcode fetch.  VPB is
# not a field: it follows the vector address sources.
BUS = dict(NONE=0, P=1, D=2, PD=3)

# Sequencing: next = cond ? (ucycle + 1) : alt
COND = dict(ALWAYS=0, NEVER=1, CARRY=2, BRANCH=3, PAGE=4, DEC=5, M16=6,
            X16=7, DL=8, IDX=9, EPAGE=10, EMU=11, MVDONE=12, NOTEMU=13)

# ---------------------------------------------------------------------------
# Microinstruction layout.  Order here is the bit order in the ROM word.
# ---------------------------------------------------------------------------
FIELDS = [
    ("sync",      1),   # this cycle is an opcode fetch
    ("rw",        1),   # 1 = read, 0 = write
    ("addr_sel",  3),
    ("lo_a",      3),
    ("lo_b",      3),
    ("lo_ci",     1),
    ("hi_a",      3),
    ("hi_b",      3),
    ("hi_c",      2),
    ("hi_d",      2),
    ("bk_a",      1),
    ("bk_c",      2),
    ("ld_adl",    2),
    ("ld_adh",    2),
    ("ld_bk",     3),
    ("ld_pc",     4),
    ("ld_s",      3),
    ("dout",      5),
    ("alu_op",    5),
    ("alu_a",     3),
    ("wb",        5),
    ("fl",        2),
    ("seti",      1),   # set I and clear D (interrupt entry)
    ("ew",        1),   # in emulation mode this internal cycle is a dummy WRITE
    ("bus",       2),   # BUS: VDA/VPA for the cycle
    ("cond",      4),
    ("alt",       4),
]
WIDTH = sum(w for _, w in FIELDS)
SLOTS = 16
SLOTS_LOG2 = 4

DEFAULTS = dict(sync=0, rw=1, addr_sel=ADDR["PC"], lo_a=LO_A["ADL"],
                lo_b=LO_B["ZERO"], lo_ci=0, hi_a=HI_A["ADH"],
                hi_b=HI_B["ZERO"], hi_c=HI_C["NONE"], hi_d=HI_D["NONE"],
                bk_a=BK_A["BANK"], bk_c=BK_C["NONE"], ld_adl=0, ld_adh=0,
                ld_bk=0, ld_pc=0, ld_s=0, dout=DOUT["AL"],
                alu_op=OP["NOP"], alu_a=ALU_A["DIN"], wb=0, fl=FL["NONE"],
                seti=0, ew=0, bus=None, cond=COND["ALWAYS"], alt=0)


def u(**kw):
    """One microinstruction.  `alt` may be a string label, resolved later.

    `bus` defaults from the address source: a fetch is PD, anything else at PC
    is a program read, AD/SP/VEC are data.  Internal cycles say bus=NONE
    explicitly - internal() does, and so must any PC-addressed cycle that is
    not actually reading an operand (a dummy read, a branch's add cycle).
    """
    m = dict(DEFAULTS)
    for k, v in kw.items():
        if k not in DEFAULTS and k != "label":
            raise KeyError(f"unknown microinstruction field {k}")
        m[k] = v
    if m["bus"] is None:
        if m["sync"]:
            m["bus"] = BUS["PD"]
        elif m["addr_sel"] == ADDR["PC"]:
            m["bus"] = BUS["P"]
        else:
            m["bus"] = BUS["D"]
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


def fetch(**kw):
    return u(**FETCH, **kw)


def read_operand(**kw):
    """Read a byte at PC and advance.  The workhorse prefix cycle."""
    return u(addr_sel=ADDR["PC"], ld_pc=LD_PC["INC"], **kw)


def internal(**kw):
    """A cycle with no bus transaction of its own.

    The real part leaves the previous address on the bus and drops VDA/VPA.
    Holding ADDR_AD keeps the address pins quiet; VDA and VPA are both low.
    """
    return u(addr_sel=ADDR["AD"], bus=BUS["NONE"], **kw)


def ad_inc(bank=False, **kw):
    """Step the effective address to the next byte, for a 16-bit access.

    A 16-bit carry chain, but the high half is an INCREMENTER here (hi_c=LIVE
    with hi_b=ZERO), so this is a 16-bit increment rather than the two-operand
    add the header is about.  With `bank` the step carries into the bank as
    well: a 16-bit operand at $FFFF of a DBR- or long-addressed bank continues
    in the next bank, while direct page and stack stay in bank zero.
    """
    d = dict(lo_a=LO_A["ADL"], lo_b=LO_B["ONE"], ld_adl=LD_ADL["AGU"],
             hi_a=HI_A["ADH"], hi_c=HI_C["LIVE"], ld_adh=LD_ADH["AGU"], **kw)
    if bank:
        d.update(ld_bk=LD_BK["AGU"], bk_a=BK_A["BANK"], bk_c=BK_C["LIVE"])
    return d


def ad_inc_w(**kw):
    """ad_inc for a 6502-era direct-page pointer: in emulation mode with DL
    zero the second byte comes from the same page."""
    return dict(lo_a=LO_A["ADL"], lo_b=LO_B["ONE"], ld_adl=LD_ADL["AGU"],
                hi_a=HI_A["ADH"], hi_c=HI_C["LIVEW"], ld_adh=LD_ADH["AGU"], **kw)


# ---------------------------------------------------------------------------
# Addressing modes.  Each returns (prefix_slots, access_addr_sel).
#
# The access slot itself is appended by build(), which knows whether the
# instruction reads, writes or does both, and how wide the operand is.
# ---------------------------------------------------------------------------

def am_imp():
    return [], ADDR["PC"]


def am_imm():
    return [], ADDR["PC"]


def am_dp():
    """D + dp, in one 16-bit add.

    The extra cycle the table charges when DL != 0 is SPENT here, not used:
    the address is already complete.  That is the honest reading of the
    hardware - the real part's adder is 16 bits wide too, and the DL cycle
    exists because the low byte of D has to be fetched from a register file
    that a zero DL lets it skip.
    """
    return [
        read_operand(lo_a=LO_A["DL"], lo_b=LO_B["DIN"], ld_adl=LD_ADL["AGU"],
                     hi_a=HI_A["DH"], hi_c=HI_C["LIVE"], ld_adh=LD_ADH["AGU"],
                     ld_bk=LD_BK["ZERO"], cond=COND["DL"], alt="skip1"),
        internal(),
    ], ADDR["AD"]


def am_dpidx(idx_lo, idx_hi):
    """D + dp + index.  Two 16-bit adds, in the two cycles the mode grants:
    the operand read forms dp + index, the internal cycle adds D.  The 6502's
    page wrap applies to the first add in emulation mode with DL zero."""
    return [
        read_operand(lo_a=LO_A["DIN"], lo_b=idx_lo, ld_adl=LD_ADL["AGU"],
                     hi_a=HI_A["ZERO"], hi_b=idx_hi, hi_c=HI_C["LIVEW"],
                     ld_adh=LD_ADH["AGU"], ld_bk=LD_BK["ZERO"]),
        internal(lo_a=LO_A["ADL"], lo_b=LO_B["DL"], ld_adl=LD_ADL["AGU"],
                 hi_a=HI_A["ADH"], hi_b=HI_B["DH"], hi_c=HI_C["LIVE"],
                 ld_adh=LD_ADH["AGU"], cond=COND["DL"], alt="skip1"),
        internal(),
    ], ADDR["AD"]


def am_abs():
    return [read_operand(ld_adl=LD_ADL["DIN"]),
            read_operand(ld_adh=LD_ADH["DIN"], ld_bk=LD_BK["DBR"])], ADDR["AD"]


def am_absidx(idx_lo, idx_hi, always, acc_label):
    """DBR:abs + index.  The whole 16-bit add lands in the cycle that reads the
    address high byte; the granted cycle after it carries into the BANK, which
    is the one place a 65816 index really can run past the end of a bank."""
    return [
        read_operand(ld_adl=LD_ADL["DIN"]),
        read_operand(lo_a=LO_A["ADL"], lo_b=idx_lo, ld_adl=LD_ADL["AGU"],
                     hi_a=HI_A["DIN"], hi_b=idx_hi, hi_c=HI_C["LIVE"],
                     ld_adh=LD_ADH["AGU"], ld_bk=LD_BK["DBR"],
                     cond=COND["ALWAYS"] if always else COND["IDX"],
                     alt=acc_label),
        internal(ld_bk=LD_BK["AGU"], bk_a=BK_A["BANK"], bk_c=BK_C["SAVED"]),
    ], ADDR["AD"]


def am_long():
    return [read_operand(ld_adl=LD_ADL["DIN"]),
            read_operand(ld_adh=LD_ADH["DIN"]),
            read_operand(ld_bk=LD_BK["DIN"])], ADDR["AD"]


def am_longidx(idx_lo, idx_hi):
    """long,X - five cycles flat, no page-cross penalty.  The bank byte read is
    also the cycle that adds the bank carry, so the 24-bit sum needs no cycle
    of its own."""
    return [
        read_operand(ld_adl=LD_ADL["DIN"]),
        read_operand(lo_a=LO_A["ADL"], lo_b=idx_lo, ld_adl=LD_ADL["AGU"],
                     hi_a=HI_A["DIN"], hi_b=idx_hi, hi_c=HI_C["LIVE"],
                     ld_adh=LD_ADH["AGU"]),
        read_operand(ld_bk=LD_BK["AGU"], bk_a=BK_A["DIN"], bk_c=BK_C["SAVED"]),
    ], ADDR["AD"]


def _dp_pointer():
    """The dp prefix every (dp)-flavoured mode shares: form D + dp, leaving the
    POINTER's address in AD."""
    return am_dp()[0]


def am_dpind():
    """(dp) - a 16-bit pointer in bank zero; the data bank comes from DBR."""
    return _dp_pointer() + [
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDL"], **ad_inc_w()),
        u(addr_sel=ADDR["AD"], ld_adh=LD_ADH["DIN"], ld_adl=LD_ADL["MDL"],
          ld_bk=LD_BK["DBR"]),
    ], ADDR["AD"]


def am_dpindidx():
    """(dp,X) - index the pointer inside the direct page, then read it."""
    return am_dpidx(LO_B["XL"], HI_B["XH"])[0] + [
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDL"], **ad_inc_w()),
        u(addr_sel=ADDR["AD"], ld_adh=LD_ADH["DIN"], ld_adl=LD_ADL["MDL"],
          ld_bk=LD_BK["DBR"]),
    ], ADDR["AD"]


def am_dpindy(always, acc_label):
    """(dp),Y - THE mode that forces a 16-bit adder.

    The cycle that reads the pointer's high byte is the same cycle that
    produces the final address: ADL = MDL + YL and ADH = din + YH + carry,
    together, with no cycle in between.  The one cycle this mode does grant is
    already committed to the page-cross fixup, which here means the bank carry.
    """
    return _dp_pointer() + [
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDL"], **ad_inc_w()),
        u(addr_sel=ADDR["AD"], lo_a=LO_A["MDL"], lo_b=LO_B["YL"],
          ld_adl=LD_ADL["AGU"], hi_a=HI_A["DIN"], hi_b=HI_B["YH"],
          hi_c=HI_C["LIVE"], ld_adh=LD_ADH["AGU"], ld_bk=LD_BK["DBR"],
          cond=COND["ALWAYS"] if always else COND["IDX"], alt=acc_label),
        internal(ld_bk=LD_BK["AGU"], bk_a=BK_A["BANK"], bk_c=BK_C["SAVED"]),
    ], ADDR["AD"]


def am_dpindl():
    """[dp] - a 24-bit pointer.  No indexing, so no carry to defer."""
    return _dp_pointer() + [
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDL"], **ad_inc()),
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDH"], **ad_inc()),
        u(addr_sel=ADDR["AD"], ld_bk=LD_BK["DIN"], ld_adl=LD_ADL["MDL"],
          ld_adh=LD_ADH["MDH"]),
    ], ADDR["AD"]


def am_dpindly():
    """[dp],Y - seven cycles flat, so the 24-bit sum has to complete in the
    cycle that reads the pointer's bank byte.  This is the longest arithmetic
    path in the design: low add, carry into the high add, carry into the bank
    incrementer.  If anything sets this core's Fmax, it is this."""
    return _dp_pointer() + [
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDL"], **ad_inc()),
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDH"], **ad_inc()),
        u(addr_sel=ADDR["AD"], lo_a=LO_A["MDL"], lo_b=LO_B["YL"],
          ld_adl=LD_ADL["AGU"], hi_a=HI_A["MDH"], hi_b=HI_B["YH"],
          hi_c=HI_C["LIVE"], ld_adh=LD_ADH["AGU"],
          ld_bk=LD_BK["AGU"], bk_a=BK_A["DIN"], bk_c=BK_C["LIVE"]),
    ], ADDR["AD"]


def am_sr():
    """sr,S - stack relative, bank zero.  One granted cycle for the add."""
    return [
        read_operand(lo_a=LO_A["SL"], lo_b=LO_B["DIN"], ld_adl=LD_ADL["AGU"],
                     hi_a=HI_A["SH"], hi_c=HI_C["LIVE"], ld_adh=LD_ADH["AGU"],
                     ld_bk=LD_BK["ZERO"]),
        internal(),
    ], ADDR["AD"]


def am_srindy():
    """(sr,S),Y - pointer at S+off in bank zero, data bank from DBR, Y indexed
    with a bank carry in the granted cycle."""
    return am_sr()[0] + [
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDL"], **ad_inc()),
        u(addr_sel=ADDR["AD"], lo_a=LO_A["MDL"], lo_b=LO_B["YL"],
          ld_adl=LD_ADL["AGU"], hi_a=HI_A["DIN"], hi_b=HI_B["YH"],
          hi_c=HI_C["LIVE"], ld_adh=LD_ADH["AGU"], ld_bk=LD_BK["DBR"]),
        internal(ld_bk=LD_BK["AGU"], bk_a=BK_A["BANK"], bk_c=BK_C["SAVED"]),
    ], ADDR["AD"]


# ---------------------------------------------------------------------------
# Access shapes.  A 16-bit operand is two bus cycles, and the second one is a
# conditional slot - so an 8-bit operation costs nothing for the ability.
# ---------------------------------------------------------------------------

def acc_read(asel, op, alu_lo, alu_hi, wb_lo, wb_hi, wide, imm, label="acc",
             bank=False):
    """Read one operand, 8 or 16 bits wide."""
    slots = []
    lo = u(addr_sel=asel, alu_op=op, alu_a=alu_lo, wb=wb_lo,
           fl=FL["L16"] if wide else FL["B8"], label=label)
    if imm:
        lo["ld_pc"] = LD_PC["INC"]
    else:
        lo.update(ad_inc(bank))
    if not wide:
        slots.append(lo)
        return slots
    lo["cond"] = COND["M16"] if wide == "m" else COND["X16"]
    lo["alt"] = "end"
    slots.append(lo)
    hi = u(addr_sel=asel, alu_op=op, alu_a=alu_hi, wb=wb_hi, fl=FL["H16"])
    if imm:
        hi["ld_pc"] = LD_PC["INC"]
    slots.append(hi)
    return slots


def acc_write(asel, dout_lo, dout_hi, wide, label="acc", bank=False):
    slots = [u(addr_sel=asel, rw=0, dout=dout_lo, label=label, **ad_inc(bank))]
    if wide:
        slots[0]["cond"] = COND["M16"] if wide == "m" else COND["X16"]
        slots[0]["alt"] = "end"
        slots.append(u(addr_sel=asel, rw=0, dout=dout_hi))
    return slots


def ad_dec(bank=False, **kw):
    """Step the effective address back a byte.  Adding $FF carries out of the
    low byte unless it was zero, so the high half takes carry - 1: an ordinary
    borrow, and still only an incrementer/decrementer on the high side.  With
    `bank`, the borrow continues into the bank (the partner of ad_inc's
    carry, for a 16-bit RMW that straddled a bank)."""
    d = dict(lo_a=LO_A["ADL"], lo_b=LO_B["FF"], ld_adl=LD_ADL["AGU"],
             hi_a=HI_A["ADH"], hi_c=HI_C["LIVE"], hi_d=HI_D["ONE"],
             ld_adh=LD_ADH["AGU"], **kw)
    if bank:
        d.update(ld_bk=LD_BK["AGU"], bk_a=BK_A["BANK"], bk_c=BK_C["BORROW"])
    return d


def acc_rmw(asel, op, wide, label="acc", bank=False):
    """Read-modify-write.

    An 8-bit RMW is three cycles: read, compute, write.  A 16-bit
    one reads LOW then HIGH, spends its internal cycle on a shift or increment
    of the register pair, then writes HIGH then LOW - the reverse order, which
    is what the part does.  The address walks forward over the reads and back
    over the writes rather than being recomputed, so no extra address register
    is needed to remember where the operand started.
    """
    # The internal cycle between read and write: in emulation mode the part
    # writes the OLD value back with VDA low, the 6502's dummy write.
    if not wide:
        return [
            u(addr_sel=asel, alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
              label=label),
            internal(alu_op=op, alu_a=ALU_A["MD"], wb=WB["MDL"], fl=FL["B8"],
                     ew=1, dout=DOUT["MDL"]),
            u(addr_sel=asel, rw=0, dout=DOUT["MDL"]),
        ]
    return [
        u(addr_sel=asel, alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
          label=label, cond=COND["M16"], alt="rmw8", **ad_inc(bank)),
        u(addr_sel=asel, alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"]),
        # Both halves are in MD, so the 16-bit shift or increment is one
        # operation on a register pair, with no bus cycle of its own.
        internal(alu_op=op, alu_a=ALU_A["MD"], wb=WB["MD16"], fl=FL["B8"]),
        u(addr_sel=asel, rw=0, dout=DOUT["MDH"], **ad_dec(bank)),
        u(addr_sel=asel, rw=0, dout=DOUT["MDL"], cond=COND["NEVER"],
          alt="end"),
        # The 8-bit tail.  Reached only from the conditional above, and it has
        # to undo the address step that the shared first cycle took.
        internal(alu_op=op, alu_a=ALU_A["MD"], wb=WB["MDL"], fl=FL["B8"],
                 label="rmw8", ew=1, dout=DOUT["MDL"], **ad_dec(bank)),
        u(addr_sel=asel, rw=0, dout=DOUT["MDL"]),
    ]


MODES = {
    "imp": am_imp, "imm": am_imm, "dp": am_dp, "abs": am_abs,
    "long": am_long, "dpind": am_dpind, "dpindx": am_dpindidx,
    "dpindl": am_dpindl, "dpindly": am_dpindly, "sr": am_sr,
    "srindy": am_srindy,
}


def build(mode, acc, op=OP["NOP"], alu_lo=ALU_A["DIN"], alu_hi=ALU_A["DIN"],
          wb_lo=WB["NONE"], wb_hi=WB["NONE"], dout_lo=DOUT["AL"],
          dout_hi=DOUT["AH"], wide=None, decimal=False):
    """Assemble one instruction's microcode from a mode and an access kind.

    `wide` is None for a fixed 8-bit operation, "m" for one sized by the M
    flag, or "x" for one sized by the X flag.
    """
    ACC = "acc"
    always = (acc == "write") or (acc == "rmw")

    if mode == "dpx":     pre, asel = am_dpidx(LO_B["XL"], HI_B["XH"])
    elif mode == "dpy":   pre, asel = am_dpidx(LO_B["YL"], HI_B["YH"])
    elif mode == "absx":  pre, asel = am_absidx(LO_B["XL"], HI_B["XH"], always, ACC)
    elif mode == "absy":  pre, asel = am_absidx(LO_B["YL"], HI_B["YH"], always, ACC)
    elif mode == "longx": pre, asel = am_longidx(LO_B["XL"], HI_B["XH"])
    elif mode == "dpindy": pre, asel = am_dpindy(always, ACC)
    else:                 pre, asel = MODES[mode]()

    slots = list(pre)
    imm = (mode == "imm")
    # Direct page, stack-relative and their pointers live in bank zero; every
    # DBR- or long-addressed operand can straddle a bank boundary.
    bank = mode not in ("imp", "imm", "dp", "dpx", "dpy", "sr")

    if acc == "none":
        # Implied / accumulator: the dummy read at PC is where the work
        # happens, and it is a single cycle whatever the operand width - a
        # 16-bit INC A is two cycles, not three.
        # One pass whatever the width: the ALU's flags are computed over the
        # width the write-back names, so B8 is right for a 16-bit INC A too.
        slots.append(u(addr_sel=ADDR["PC"], bus=BUS["NONE"], alu_op=op,
                       alu_a=alu_lo, wb=wb_lo, fl=FL["B8"], label=ACC))
    elif acc == "read":
        slots += acc_read(asel, op, alu_lo, alu_hi, wb_lo, wb_hi, wide, imm,
                          bank=bank)
    elif acc == "write":
        slots += acc_write(asel, dout_lo, dout_hi, wide, bank=bank)
    elif acc == "rmw":
        slots += acc_rmw(asel, op, wide, bank=bank)

    # (The 65C02's extra decimal-mode cycle does not exist on the 65816: the
    # suite shows ADC/SBC at the same count with D set.  `decimal` is kept as
    # an argument so the table reads the same; it changes nothing.)

    slots.append(fetch(label="end"))
    return slots


# ---------------------------------------------------------------------------
# The opcode table
# ---------------------------------------------------------------------------
PROG = {}


def put(opcode, slots):
    if opcode in PROG:
        raise KeyError(f"opcode ${opcode:02X} defined twice")
    PROG[opcode] = slots


# The full 65816 addressing-mode map for the accumulator group, by offset from
# the group base.  This is the table that makes ORA/AND/EOR/ADC/STA/LDA/CMP/SBC
# one loop instead of eight.
ALU_MODES = [("dpindx", 0x01), ("sr", 0x03), ("dp", 0x05), ("dpindl", 0x07),
             ("imm", 0x09), ("abs", 0x0D), ("long", 0x0F),
             ("dpindy", 0x11), ("dpind", 0x12), ("srindy", 0x13),
             ("dpx", 0x15), ("dpindly", 0x17), ("absy", 0x19),
             ("absx", 0x1D), ("longx", 0x1F)]

# ---- accumulator group ----------------------------------------------------
for base, op, dec in [(0x00, OP["ORA"], False), (0x20, OP["AND"], False),
                      (0x40, OP["EOR"], False), (0x60, OP["ADC"], True),
                      (0xA0, OP["LD"], False), (0xC0, OP["CMP"], False),
                      (0xE0, OP["SBC"], True)]:
    for mode, off in ALU_MODES:
        wb_lo = WB["NONE"] if op == OP["CMP"] else WB["AL"]
        wb_hi = WB["NONE"] if op == OP["CMP"] else WB["AH"]
        put(base | off, build(mode, "read", op=op,
                              alu_lo=ALU_A["DIN"], alu_hi=ALU_A["DIN"],
                              wb_lo=wb_lo, wb_hi=wb_hi, wide="m", decimal=dec))

# STA has no immediate mode; $89 is BIT # instead.
for mode, off in ALU_MODES:
    if mode == "imm":
        continue
    put(0x80 | off, build(mode, "write", dout_lo=DOUT["AL"], dout_hi=DOUT["AH"],
                          wide="m"))

# ---- index register loads and stores --------------------------------------
for oc, mode in [(0xA2, "imm"), (0xA6, "dp"), (0xB6, "dpy"), (0xAE, "abs"),
                 (0xBE, "absy")]:
    put(oc, build(mode, "read", op=OP["LD"], wb_lo=WB["XL"], wb_hi=WB["XH"],
                  wide="x"))
for oc, mode in [(0xA0, "imm"), (0xA4, "dp"), (0xB4, "dpx"), (0xAC, "abs"),
                 (0xBC, "absx")]:
    put(oc, build(mode, "read", op=OP["LD"], wb_lo=WB["YL"], wb_hi=WB["YH"],
                  wide="x"))
for oc, mode in [(0x86, "dp"), (0x96, "dpy"), (0x8E, "abs")]:
    put(oc, build(mode, "write", dout_lo=DOUT["XL"], dout_hi=DOUT["XH"],
                  wide="x"))
for oc, mode in [(0x84, "dp"), (0x94, "dpx"), (0x8C, "abs")]:
    put(oc, build(mode, "write", dout_lo=DOUT["YL"], dout_hi=DOUT["YH"],
                  wide="x"))
for oc, mode in [(0x64, "dp"), (0x74, "dpx"), (0x9C, "abs"), (0x9E, "absx")]:
    put(oc, build(mode, "write", dout_lo=DOUT["ZERO"], dout_hi=DOUT["ZERO"],
                  wide="m"))

# ---- compares -------------------------------------------------------------
for oc, mode in [(0xE0, "imm"), (0xE4, "dp"), (0xEC, "abs")]:
    put(oc, build(mode, "read", op=OP["CPX"], wide="x"))
for oc, mode in [(0xC0, "imm"), (0xC4, "dp"), (0xCC, "abs")]:
    put(oc, build(mode, "read", op=OP["CPY"], wide="x"))
for oc, mode in [(0x24, "dp"), (0x34, "dpx"), (0x2C, "abs"), (0x3C, "absx")]:
    put(oc, build(mode, "read", op=OP["BIT"], wide="m"))
put(0x89, build("imm", "read", op=OP["BITI"], wide="m"))

# ---- read-modify-write ----------------------------------------------------
for base, op in [(0x00, OP["ASL"]), (0x20, OP["ROL"]), (0x40, OP["LSR"]),
                 (0x60, OP["ROR"])]:
    put(base | 0x0A, build("imp", "none", op=op, alu_lo=ALU_A["A"],
                           wb_lo=WB["A16"], wide="m"))
    for mode, off in [("dp", 0x06), ("dpx", 0x16), ("abs", 0x0E), ("absx", 0x1E)]:
        put(base | off, build(mode, "rmw", op=op, wide="m"))
for base, op in [(0xC0, OP["DEC"]), (0xE0, OP["INC"])]:
    for mode, off in [("dp", 0x06), ("dpx", 0x16), ("abs", 0x0E), ("absx", 0x1E)]:
        put(base | off, build(mode, "rmw", op=op, wide="m"))

put(0x1A, build("imp", "none", op=OP["INC"], alu_lo=ALU_A["A"], wb_lo=WB["A16"], wide="m"))
put(0x3A, build("imp", "none", op=OP["DEC"], alu_lo=ALU_A["A"], wb_lo=WB["A16"], wide="m"))
put(0xE8, build("imp", "none", op=OP["INC"], alu_lo=ALU_A["X"], wb_lo=WB["X16"], wide="x"))
put(0xC8, build("imp", "none", op=OP["INC"], alu_lo=ALU_A["Y"], wb_lo=WB["Y16"], wide="x"))
put(0xCA, build("imp", "none", op=OP["DEC"], alu_lo=ALU_A["X"], wb_lo=WB["X16"], wide="x"))
put(0x88, build("imp", "none", op=OP["DEC"], alu_lo=ALU_A["Y"], wb_lo=WB["Y16"], wide="x"))

put(0x14, build("dp", "rmw", op=OP["TRB"], wide="m"))
put(0x1C, build("abs", "rmw", op=OP["TRB"], wide="m"))
put(0x04, build("dp", "rmw", op=OP["TSB"], wide="m"))
put(0x0C, build("abs", "rmw", op=OP["TSB"], wide="m"))

# ---- transfers ------------------------------------------------------------
# Every one of these is two cycles regardless of width, so the 16-bit half is a
# plain second write-back in the same microinstruction, not an extra slot.
for oc, alu, wb in [(0xAA, ALU_A["A"], WB["X16"]), (0xA8, ALU_A["A"], WB["Y16"]),
                    (0x8A, ALU_A["X"], WB["A16"]), (0x98, ALU_A["Y"], WB["A16"]),
                    (0xBA, ALU_A["S"], WB["X16"]), (0x9B, ALU_A["X"], WB["Y16"]),
                    (0xBB, ALU_A["Y"], WB["X16"])]:
    put(oc, build("imp", "none", op=OP["MOV"], alu_lo=alu, wb_lo=wb, wide="m"))
put(0x9A, build("imp", "none", op=OP["TCS"], alu_lo=ALU_A["X"], wb_lo=WB["S16"]))
put(0x1B, build("imp", "none", op=OP["TCS"], alu_lo=ALU_A["A"], wb_lo=WB["S16"]))   # TCS
put(0x3B, build("imp", "none", op=OP["MOV"], alu_lo=ALU_A["S"], wb_lo=WB["AF16"]))  # TSC: 16 bits whatever M says
put(0x5B, build("imp", "none", op=OP["MOV"], alu_lo=ALU_A["A"], wb_lo=WB["D16"], wide="m"))   # TCD
put(0x7B, build("imp", "none", op=OP["MOV"], alu_lo=ALU_A["D"], wb_lo=WB["AF16"]))  # TDC: 16 bits whatever M says
# XBA is three cycles, not two: swapping the halves of A is one operation but
# the part spends a second internal cycle on it regardless of M.
put(0xEB, [internal(), internal(alu_op=OP["XBA"], alu_a=ALU_A["A"],
                                wb=WB["AF16"], fl=FL["B8"]), fetch()])          # XBA
put(0xFB, build("imp", "none", op=OP["XCE"]))                                                # XCE

# ---- flags ----------------------------------------------------------------
for oc in (0x18, 0x38, 0x58, 0x78, 0xB8, 0xD8, 0xF8):
    put(oc, build("imp", "none", op=OP["FLAG"]))
put(0xC2, [read_operand(alu_op=OP["REP"], alu_a=ALU_A["DIN"]),
           internal(), fetch()])                                   # REP #
put(0xE2, [read_operand(alu_op=OP["SEP"], alu_a=ALU_A["DIN"]),
           internal(), fetch()])                                   # SEP #

# ---- branches -------------------------------------------------------------
# Two cycles not taken, three taken, four when the low-byte add left the page -
# and that fourth cycle exists ONLY in emulation mode, which the derived cycle
# table confirms and the datasheet footnote states.
def branch(cond):
    return [
        read_operand(ld_adl=LD_ADL["DIN"], cond=cond, alt="end"),
        # PC + sign-extended offset, all sixteen bits at once: PCL + off with
        # the carry into PCH, and off's sign subtracted from PCH.  A native-mode
        # branch gets exactly this one cycle whether or not it crosses a page.
        u(addr_sel=ADDR["PC"], bus=BUS["NONE"], lo_a=LO_A["PCL"],
          lo_b=LO_B["ADL"], hi_a=HI_A["PCH"], hi_c=HI_C["LIVE"],
          hi_d=HI_D["SIGN"], ld_pc=LD_PC["AGU"],
          cond=COND["EPAGE"], alt="end"),
        # The emulation-mode page-cross cycle: the 6502's fixup, already done.
        u(addr_sel=ADDR["PC"], bus=BUS["NONE"]),
        fetch(label="end"),
    ]


for oc in (0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0):
    put(oc, branch(COND["BRANCH"]))
put(0x80, branch(COND["ALWAYS"]))

# BRL is a 16-bit relative add, and it gets exactly one cycle to do it in - so
# the low add and the high add DO share a cycle here.  That is legitimate under
# the shape the rest of the AGU already has: PCH + offset_hi is the only add on
# the high side, and the carry arrives from the low half as a carry-in rather
# than through a second adder.
put(0x82, [                                            # BRL rel16
    read_operand(ld_adl=LD_ADL["DIN"]),
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"]),
    u(addr_sel=ADDR["PC"], bus=BUS["NONE"], lo_a=LO_A["PCL"],
      lo_b=LO_B["ADL"], hi_a=HI_A["PCH"], hi_b=HI_B["MDH"],
      hi_c=HI_C["LIVE"], ld_pc=LD_PC["AGU"]),
    fetch(),
])

# ---- jumps ----------------------------------------------------------------
put(0x4C, [                                            # JMP abs
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"]),
    u(addr_sel=ADDR["PC"], ld_pc=LD_PC["JMP"]),
    fetch(),
])
put(0x5C, [                                            # JML long
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"]),
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"]),
    u(addr_sel=ADDR["PC"], ld_pc=LD_PC["JMPL"], ld_bk=LD_BK["DIN"], wb=WB["PBR"]),
    fetch(),
])
put(0x6C, [                                            # JMP (abs)
    read_operand(ld_adl=LD_ADL["DIN"]),
    read_operand(ld_adh=LD_ADH["DIN"], ld_bk=LD_BK["ZERO"]),
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
      **ad_inc()),
    u(addr_sel=ADDR["AD"], ld_pc=LD_PC["JMP"]),
    fetch(),
])
put(0x7C, [                                            # JMP (abs,X)
    read_operand(ld_adl=LD_ADL["DIN"]),
    read_operand(ld_adh=LD_ADH["DIN"], ld_bk=LD_BK["PBR"],
                 lo_a=LO_A["ADL"], lo_b=LO_B["XL"], ld_adl=LD_ADL["AGU"]),
    internal(ld_adh=LD_ADH["AGU"], hi_a=HI_A["ADH"], hi_b=HI_B["XH"],
             hi_c=HI_C["SAVED"]),
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
      **ad_inc()),
    u(addr_sel=ADDR["AD"], ld_pc=LD_PC["JMP"]),
    fetch(),
])
put(0xDC, [                                            # JML [abs]
    read_operand(ld_adl=LD_ADL["DIN"]),
    read_operand(ld_adh=LD_ADH["DIN"], ld_bk=LD_BK["ZERO"]),
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
      **ad_inc()),
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"],
      **ad_inc()),
    u(addr_sel=ADDR["AD"], ld_pc=LD_PC["JMPL"], wb=WB["PBR"]),
    fetch(),
])

# The PC load rides the LAST push rather than taking a cycle of its own: the
# target is already in MD, so nothing has to be read for it.  Giving it its own
# slot is the obvious way to write this and it costs a cycle the part does not
# spend.
put(0x20, [                                            # JSR abs
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"]),
    # The high byte's read does not advance PC: what gets pushed is the
    # address of the instruction's LAST byte, and RTS adds the one.
    u(addr_sel=ADDR["PC"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"]),
    internal(),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCH"], ld_s=LD_S["DEC"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCL"], ld_s=LD_S["DEC"],
      ld_pc=LD_PC["MD"]),
    fetch(),
])
# JSL pushes PBR BEFORE the bank operand is read - the ordering is odd, it is
# what the part does, and the traces show it plainly.
put(0x22, [                                            # JSL long
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"]),
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PBR"], ld_s=LD_S["DECN"]),
    internal(),
    # Same rule as JSR: the bank byte's read leaves PC on the last byte.
    u(addr_sel=ADDR["PC"], ld_bk=LD_BK["DIN"], wb=WB["PBR"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCH"], ld_s=LD_S["DECN"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCL"], ld_s=LD_S["DEC"],
      ld_pc=LD_PC["MD"]),
    fetch(),
])
put(0xFC, [                                            # JSR (abs,X)
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCH"], ld_s=LD_S["DEC"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCL"], ld_s=LD_S["DEC"]),
    read_operand(ld_adh=LD_ADH["DIN"], ld_adl=LD_ADL["MDL"],
                 ld_bk=LD_BK["PBR"], lo_a=LO_A["MDL"], lo_b=LO_B["XL"]),
    internal(ld_adl=LD_ADL["AGU"], lo_a=LO_A["ADL"], lo_b=LO_B["XL"],
             ld_adh=LD_ADH["AGU"], hi_a=HI_A["ADH"], hi_b=HI_B["XH"],
             hi_c=HI_C["SAVED"]),
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
      **ad_inc()),
    u(addr_sel=ADDR["AD"], ld_pc=LD_PC["JMP"]),
    fetch(),
])

put(0x60, [                                            # RTS
    internal(),
    internal(ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
      ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], ld_pc=LD_PC["JMP"]),
    u(addr_sel=ADDR["PC"], bus=BUS["NONE"], ld_pc=LD_PC["INC"]),
    fetch(),
])
put(0x6B, [                                            # RTL
    internal(), internal(ld_s=LD_S["INCN"]),
    u(addr_sel=ADDR["SP"], ld_s=LD_S["INCN"], alu_op=OP["LD"],
      alu_a=ALU_A["DIN"], wb=WB["MDL"]),
    u(addr_sel=ADDR["SP"], ld_s=LD_S["INCN"], alu_op=OP["LD"],
      alu_a=ALU_A["DIN"], wb=WB["MDH"]),
    u(addr_sel=ADDR["SP"], ld_s=LD_S["NORM"], wb=WB["PBR"],
      lo_a=LO_A["MDL"], lo_b=LO_B["ONE"], hi_a=HI_A["MDH"], hi_c=HI_C["LIVE"],
      ld_pc=LD_PC["AGU"]),
    fetch(),
])
# RTI pulls P, PCL, PCH - and, in native mode only, PBR.  Seven cycles native,
# six emulated.  The stack pointer steps on the second internal cycle so that
# the first stack READ already lands on S+1.
# The stack pointer steps in the cycle BEFORE each pull, so a pull reads at
# the stepped S; the last pull of the sequence therefore does not step.  In
# native mode PCH's pull steps once more for PBR; in emulation mode it is the
# last pull, so the two modes get their own PCH slot.
put(0x40, [                                            # RTI
    internal(),
    internal(ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], wb=WB["P"], ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
      ld_s=LD_S["INC"], cond=COND["NOTEMU"], alt="pch_e"),
    u(addr_sel=ADDR["SP"], ld_pc=LD_PC["JMP"], ld_s=LD_S["INC"]),
    u(addr_sel=ADDR["SP"], wb=WB["PBR"]),
    fetch(label="end"),
    u(addr_sel=ADDR["SP"], ld_pc=LD_PC["JMP"], label="pch_e",
      cond=COND["NEVER"], alt="end"),
])

# ---- stack ----------------------------------------------------------------
def width_cond(wide):
    """The condition that says "this operand is 16 bits wide"."""
    return COND["M16"] if wide == "m" else COND["X16"]


def push(src_lo, src_hi, wide, new=False):
    """A push writes HIGH then LOW, so the conditional half comes first - and
    the test therefore lives on the internal cycle BEFORE it.  A condition
    selects the next slot; it does not suppress the slot it sits on.

    `new` marks a 65816-only push (PHD): its first step runs S through all
    sixteen bits in emulation mode, the last one puts the page back.
    """
    dec1 = LD_S["DECN"] if new else LD_S["DEC"]
    if not wide:
        return [internal(),
                u(addr_sel=ADDR["SP"], rw=0, dout=src_lo, ld_s=LD_S["DEC"]),
                fetch()]
    head = internal() if wide == "always" else internal(
        cond=width_cond(wide), alt="lo")
    return [
        head,
        u(addr_sel=ADDR["SP"], rw=0, dout=src_hi, ld_s=dec1),
        u(addr_sel=ADDR["SP"], rw=0, dout=src_lo, ld_s=LD_S["DEC"], label="lo"),
        fetch(),
    ]


def pull(wb_lo, wb_hi, wide, new=False):
    """A pull reads LOW then HIGH.  S steps in the cycle BEFORE each read, so
    the 8-bit and 16-bit shapes need separate low-byte slots: the 16-bit low
    read steps S again for the high byte, the 8-bit one does not.  The width
    test therefore sits on the second internal cycle, which is where the
    first step happens too.

    `new` marks a 65816-only pull (PLD, PLB): sixteen-bit steps in emulation
    mode, the page restored on the last read.
    """
    inc = LD_S["INCN"] if new else LD_S["INC"]
    last = LD_S["NORM"] if new else LD_S["NONE"]
    if not wide:
        return [internal(), internal(ld_s=inc),
                u(addr_sel=ADDR["SP"], ld_s=last, alu_op=OP["LD"],
                  alu_a=ALU_A["DIN"], wb=wb_lo, fl=FL["B8"]),
                fetch()]
    head = internal(ld_s=inc) if wide == "always" else internal(
        ld_s=inc, cond=width_cond(wide), alt="lo8")
    return [
        internal(),
        head,
        u(addr_sel=ADDR["SP"], ld_s=inc, alu_op=OP["LD"],
          alu_a=ALU_A["DIN"], wb=wb_lo, fl=FL["L16"]),
        u(addr_sel=ADDR["SP"], ld_s=last, alu_op=OP["LD"],
          alu_a=ALU_A["DIN"], wb=wb_hi, fl=FL["H16"]),
        fetch(label="end"),
        u(addr_sel=ADDR["SP"], ld_s=last, alu_op=OP["LD"],
          alu_a=ALU_A["DIN"], wb=wb_lo, fl=FL["B8"], label="lo8",
          cond=COND["NEVER"], alt="end"),
    ]


put(0x48, push(DOUT["AL"], DOUT["AH"], "m"))                       # PHA
put(0xDA, push(DOUT["XL"], DOUT["XH"], "x"))                       # PHX
put(0x5A, push(DOUT["YL"], DOUT["YH"], "x"))                       # PHY
put(0x08, push(DOUT["P_B"], DOUT["P_B"], None))                    # PHP
put(0x8B, push(DOUT["DBR"], DOUT["DBR"], None))                    # PHB
put(0x4B, push(DOUT["PBR"], DOUT["PBR"], None))                    # PHK
put(0x0B, push(DOUT["DL"], DOUT["DH"], "always", new=True))        # PHD (always 16)
put(0x68, pull(WB["AL"], WB["AH"], "m"))                           # PLA
put(0xFA, pull(WB["XL"], WB["XH"], "x"))                           # PLX
put(0x7A, pull(WB["YL"], WB["YH"], "x"))                           # PLY
put(0xAB, pull(WB["DBR"], WB["DBR"], None, new=True))              # PLB
put(0x2B, pull(WB["DL"], WB["DH"], "always", new=True))            # PLD
put(0x28, [internal(), internal(ld_s=LD_S["INC"]),
           u(addr_sel=ADDR["SP"], wb=WB["P"]),
           fetch()])                                               # PLP

put(0xF4, [                                            # PEA abs
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"]),
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["MDH"], ld_s=LD_S["DECN"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["MDL"], ld_s=LD_S["DEC"]),
    fetch(),
])
put(0xD4, _dp_pointer() + [                            # PEI (dp)
    # 65816-only: its pointer does NOT page-wrap in emulation mode (the
    # suite: D=$0C00, dp=$FF reads $0CFF then $0D00).
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"],
      **ad_inc()),
    u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["MDH"], ld_s=LD_S["DECN"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["MDL"], ld_s=LD_S["DEC"]),
    fetch(),
])
put(0x62, [                                            # PER rel16
    read_operand(ld_adl=LD_ADL["DIN"]),
    read_operand(alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDH"]),
    internal(lo_a=LO_A["PCL"], lo_b=LO_B["ADL"], ld_adl=LD_ADL["AGU"],
             hi_a=HI_A["PCH"], hi_b=HI_B["MDH"], hi_c=HI_C["LIVE"],
             ld_adh=LD_ADH["AGU"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["ADH"], ld_s=LD_S["DECN"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["ADL"], ld_s=LD_S["DEC"]),
    fetch(),
])

# ---- block moves ----------------------------------------------------------
# MVN/MVP re-fetch the opcode and BOTH operand bytes for every byte moved, so
# the microcode is a loop back to the instruction's own fetch slot and the PC
# simply never advances past it.  Seven cycles per byte, exactly as the table
# says, and no cycle counter anywhere in the hardware.
#
# INCOMPLETE, DELIBERATELY.  The loop structure and the seven-cycle period are
# right, and the count in A is decremented so it terminates.  What is NOT here
# is the source/destination addressing: a block move reads {srcbank, X} and
# writes {dstbank, Y}, and the bank operand mux has no path from MD to the bank
# half to express that.  Adding one is a field, not a redesign, but it changes
# the bank mux this exploration is trying to measure, so it is left out and
# said out loud rather than half-done.  MVN/MVP are excluded from the cycle
# check for an unrelated reason - their length depends on the block size - so
# nothing here is being hidden by that exclusion.  See docs/UCODE816.md.
def blockmove(direction):
    return [
        # Destination bank: into DBR, where it stays - the move sets DBR.
        read_operand(ld_bk=LD_BK["DIN"], wb=WB["DBR"]),
        # Source bank straight into BANK, and AD <- X, so the next cycle can
        # read {srcbank, X}.
        read_operand(ld_bk=LD_BK["DIN"],
                     lo_a=LO_A["ZERO"], lo_b=LO_B["XL"], ld_adl=LD_ADL["AGU"],
                     hi_a=HI_A["ZERO"], hi_b=HI_B["XH"], ld_adh=LD_ADH["AGU"]),
        # Read the byte; meanwhile AD <- Y and BANK <- DBR for the write.
        u(addr_sel=ADDR["AD"], alu_op=OP["LD"], alu_a=ALU_A["DIN"],
          wb=WB["MDL"], ld_bk=LD_BK["DBR"],
          lo_a=LO_A["ZERO"], lo_b=LO_B["YL"], ld_adl=LD_ADL["AGU"],
          hi_a=HI_A["ZERO"], hi_b=HI_B["YH"], ld_adh=LD_ADH["AGU"]),
        # Write it.  The count is 16-bit whatever M says, so this is the one
        # write-back that ignores the mode.
        u(addr_sel=ADDR["AD"], rw=0, dout=DOUT["MDL"],
          alu_op=OP["DEC"], alu_a=ALU_A["A"], wb=WB["AF16"]),
        internal(alu_op=direction, alu_a=ALU_A["X"], wb=WB["X16"]),
        # Y steps, and if the count has not wrapped PC rewinds to the opcode
        # so the loop re-fetches the instruction - seven cycles per byte.
        internal(alu_op=direction, alu_a=ALU_A["Y"], wb=WB["Y16"],
                 ld_pc=LD_PC["M3C"], cond=COND["MVDONE"], alt="again"),
        fetch(),
        # The loop target: run this instruction again from its own opcode.
        fetch(label="again"),
    ]


put(0x54, blockmove(OP["INC"]))                        # MVN
put(0x44, blockmove(OP["DEC"]))                        # MVP

# ---- interrupts and the sequence they share -------------------------------
# BRK/COP/IRQ/NMI/ABORT/RESET all run this microcode.  Native mode pushes PBR
# as a fourth byte; emulation mode does not, which is the one place the
# sequence forks.
INT_SEQ = [
    # The test for "is this native mode" sits on the operand read, because the
    # slot it has to suppress is the one AFTER it - a condition picks the
    # successor, it does not cancel the microinstruction carrying it.
    read_operand(cond=COND["NOTEMU"], alt="pch"),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PBR"], ld_s=LD_S["DEC"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCH"], ld_s=LD_S["DEC"],
      label="pch"),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["PCL"], ld_s=LD_S["DEC"]),
    u(addr_sel=ADDR["SP"], rw=0, dout=DOUT["P_B"], ld_s=LD_S["DEC"], seti=1),
    u(addr_sel=ADDR["VEC"], alu_op=OP["LD"], alu_a=ALU_A["DIN"], wb=WB["MDL"]),
    # PBR is forced to zero by the hardware on a vector fetch, so this slot
    # does not write it: every 65816 vector lands in bank zero.
    u(addr_sel=ADDR["VEC1"], ld_pc=LD_PC["JMP"], ld_bk=LD_BK["ZERO"]),
    fetch(),
]
put(0x00, list(INT_SEQ))                               # BRK
put(0x02, list(INT_SEQ))                               # COP

# ---- STP / WAI / NOP ------------------------------------------------------
put(0xDB, [internal(), internal(cond=COND["NEVER"], alt=1), fetch()])   # STP
put(0xCB, [internal(), internal(cond=COND["NEVER"], alt=1), fetch()])   # WAI
put(0xEA, build("imp", "none"))                                        # NOP
put(0x42, [read_operand(bus=BUS["NONE"]), fetch()])                     # WDM: the operand cycle is internal


# ---------------------------------------------------------------------------
# Resolve labels, check, emit
# ---------------------------------------------------------------------------

def resolve(opcode, slots):
    labels = {"end": len(slots) - 1}
    for i, s in enumerate(slots):
        if s.get("label"):
            labels[s["label"]] = i
    for i, s in enumerate(slots):
        s.pop("label", None)
        if not isinstance(s["alt"], str):
            continue
        # "skip1" is relative: the condition failed, so step over exactly the
        # next slot.  Every mode-dependent cycle is expressed this way, which
        # keeps the mode conditions local instead of naming a label that only
        # exists in some of the shapes an addressing mode can take.
        if s["alt"] == "skip1":
            s["alt"] = i + 2
            continue
        if s["alt"] not in labels:
            raise KeyError(f"${opcode:02X}: unknown label {s['alt']}")
        s["alt"] = labels[s["alt"]]
    if len(slots) > SLOTS:
        raise ValueError(f"${opcode:02X}: {len(slots)} slots, max {SLOTS}")
    return slots


def emit_vh():
    lines = [
        "// GENERATED by sim/gen_microcode816.py - do not edit.",
        "// Field positions and symbolic values for the cpu65816 microcode ROM.",
        "// Regenerate with:  python3 sim/gen_microcode816.py",
        f"localparam int UC_W = {WIDTH};",
        f"localparam int UC_SLOTS_LOG2 = {SLOTS_LOG2};",
        "",
    ]
    pos = 0
    for name, w in FIELDS:
        lines.append(f"localparam int UCP_{name.upper()} = {pos};")
        lines.append(f"localparam int UCW_{name.upper()} = {w};")
        pos += w
    lines.append("")
    groups = [("ADDR", ADDR, "addr_sel"), ("LO_A", LO_A, "lo_a"),
              ("LO_B", LO_B, "lo_b"), ("HI_A", HI_A, "hi_a"),
              ("HI_B", HI_B, "hi_b"), ("HI_C", HI_C, "hi_c"),
              ("HI_D", HI_D, "hi_d"), ("BK_A", BK_A, "bk_a"),
              ("BK_C", BK_C, "bk_c"), ("LD_ADL", LD_ADL, "ld_adl"),
              ("LD_ADH", LD_ADH, "ld_adh"), ("LD_BK", LD_BK, "ld_bk"),
              ("LD_PC", LD_PC, "ld_pc"), ("LD_S", LD_S, "ld_s"),
              ("DOUT", DOUT, "dout"), ("OP", OP, "alu_op"),
              ("ALU_A", ALU_A, "alu_a"), ("WB", WB, "wb"),
              ("FL", FL, "fl"), ("BUS", BUS, "bus"), ("COND", COND, "cond")]
    widths = dict(FIELDS)
    for group_name, table, field in groups:
        w = widths[field]
        for k, v in table.items():
            lines.append(f"localparam logic [{w - 1}:0] "
                         f"UC_{group_name}_{k} = {w}'d{v};")
        lines.append("")
    return "\n".join(lines) + "\n"


def emit_hex0():
    """Slot 0 of every opcode, for the distributed-RAM decode ROM.

    The opcode arrives on din at the END of its fetch cycle, so the first
    microinstruction of an instruction is the one thing that cannot be
    prefetched - there was nothing to address the block RAM with.  That is the
    same constraint that stops a 6502 instruction taking one cycle, and it gets
    the same answer: a small fast decode for the first cycle only.  256 entries
    in distributed RAM read combinationally from the registered opcode.
    """
    filler = encode(u(**FETCH))
    out = []
    for opcode in range(256):
        slots = PROG.get(opcode)
        w = encode(slots[0]) if slots else filler
        out.append(f"{w:0{(WIDTH + 3) // 4}x}")
    return "\n".join(out) + "\n"


def emit_seq0():
    """Just the cond/alt of every opcode's slot 0, 8 bits per opcode.

    Separate from the wide decode ROM on purpose.  Slot 0's branch decision has
    to be made during the FETCH cycle, addressed by the opcode arriving on din -
    while the wide word is only ever read on the cycle AFTER, addressed by the
    registered ir.  Sharing one array would make the wide ROM's address depend
    on din and on the interrupt decision, which puts both in front of every
    datapath path through the microinstruction.  Splitting keeps the wide read
    addressed purely by a register.
    """
    out = []
    for opcode in range(256):
        slots = PROG.get(opcode)
        if slots:
            cond, alt = slots[0]["cond"], slots[0]["alt"]
        else:
            cond, alt = COND["ALWAYS"], 0
        out.append(f"{((cond & 0xF) << 4) | (alt & 0xF):02x}")
    return "\n".join(out) + "\n"


def emit_hex():
    filler = encode(u(**FETCH))
    out = []
    for opcode in range(256):
        slots = resolve(opcode, PROG[opcode]) if opcode in PROG else []
        words = [encode(s) for s in slots]
        words += [filler] * (SLOTS - len(words))
        nib = (WIDTH + 3) // 4
        for w in words:
            out.append(f"{w:0{nib}x}")
    return "\n".join(out) + "\n"


def main():
    undefined = [o for o in range(256) if o not in PROG]

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    vh = os.path.join(root, "rtl", "cpu65816_ucode.vh")
    hx = os.path.join(root, "rtl", "cpu65816_ucode.hex")
    h0 = os.path.join(root, "rtl", "cpu65816_ucode0.hex")
    hs = os.path.join(root, "rtl", "cpu65816_useq0.hex")
    # resolve() mutates PROG, and emit_hex0 must see the SAME resolved slots as
    # emit_hex - so the main image is built first.
    hx_text = emit_hex()
    vh_text, h0_text, hs_text = emit_vh(), emit_hex0(), emit_seq0()

    if "--check" in sys.argv:
        bad = False
        for path, text in ((vh, vh_text), (hx, hx_text), (h0, h0_text),
                           (hs, hs_text)):
            have = open(path).read() if os.path.exists(path) else None
            if have != text:
                print(f"STALE: {path}")
                bad = True
        if bad:
            sys.exit("Regenerate with: python3 sim/gen_microcode816.py")
        print(f"microcode up to date ({WIDTH}-bit x {256 * SLOTS} words, "
              f"{len(undefined)} opcodes still unimplemented)")
        return

    open(vh, "w").write(vh_text)
    open(hx, "w").write(hx_text)
    open(h0, "w").write(h0_text)
    open(hs, "w").write(hs_text)
    used = sum(len(PROG[o]) for o in PROG)
    print(f"wrote {vh}")
    print(f"wrote {hx}: {256 * SLOTS} words x {WIDTH} bits "
          f"({used} used, {256 * SLOTS - used} filler)")
    print(f"wrote {h0}: 256 words x {WIDTH} bits (the decode ROM)")
    print(f"wrote {hs}: 256 words x 8 bits (slot 0 cond/alt)")
    if undefined:
        print(f"NOTE: {len(undefined)} opcodes not yet implemented: "
              + " ".join(f"${o:02X}" for o in undefined))


if __name__ == "__main__":
    main()
