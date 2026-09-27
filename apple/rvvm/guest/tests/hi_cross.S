# rvvm-expect: exit
# rvvm-load: 0xFF0000
# rvvm-hi
# The 16 MB line: straight-line code, branches and jal/jalr across $0100_0000 in
# both directions, and aligned loads and stores of every width on both sides.
# Below the line is bank $FF - the ROM (docs/RVV2_INTEROP.md, the engine's map):
# read directly, and a store there is dropped as the machine drops it; above it
# the engine's own RAM.  Misaligned accesses straddle the line too (the engine
# does them: a store's ROM bytes dropped, its upper bytes written).
#include "rvvm_exit.h"
        .section .text.init
        .globl  _start
_start: li      gp, 1
        la      t0, seq
        jr      t0
fail:   FAIL
pass:   PASS

        .org    0xFFC0
back:   li      gp, 4                   # reached by a backward branch from above the line
        beq     zero, zero, fwd         # forward, across the line
        j       fail
sub0:   ret                             # reached by jal from above the line

        .org    0xFFF0
seq:    addi    a0, zero, 5
        addi    a0, a0, 1
        addi    a0, a0, 1
        addi    a0, a0, 1               # $00FFFFFC
        addi    a0, a0, 1               # $01000000, by falling through
        li      gp, 2
        li      t1, 9
        beq     a0, t1, 1f
        j       fail
1:      li      gp, 3
        beq     zero, zero, back        # backward, across the line
        j       fail
fwd:    li      gp, 5
        auipc   s0, 0                   # a pc above the line
        li      s1, 0x01000000
        bgeu    s0, s1, 1f
        j       fail
1:      li      gp, 6
        jal     ra, sub0                # backward across, and ret forward across
        li      gp, 7
        li      t0, 0x00FFFFF0          # the last row below the line (the ROM)
        li      t1, 0x01000000          # the first row above it
        lw      s4, 12(t0)              # the ROM's word at $00FFFFFC, before
        li      t2, 0x11223344
        sw      t2, 12(t0)              # $00FFFFFC: dropped
        sw      t2, 0(t1)               # $01000000
        not     t3, t2
        sh      t3, 14(t0)              # $00FFFFFE: dropped
        sb      t3, 1(t1)               # $01000001
        lw      a1, 12(t0)
        beq     a1, s4, 1f              # the ROM is unchanged
        j       fail
1:      li      gp, 8
        lw      a1, 0(t1)
        li      a2, 0x1122BB44
        beq     a1, a2, 1f
        j       fail
1:      li      gp, 9
        lh      a1, 2(t1)               # sign-extended from above the line
        li      a2, 0x1122
        beq     a1, a2, 1f
        j       fail
1:      li      gp, 10
        lbu     a1, 15(t0)              # $00FFFFFF: still the ROM's byte
        srli    a2, s4, 24
        beq     a1, a2, 1f
        j       fail
1:      li      gp, 11
        lb      a1, 1(t1)
        li      a2, -69                 # 0xBB
        beq     a1, a2, 1f
        j       fail
1:      li      gp, 12
        lw      a1, 14(t0)              # $00FFFFFE: two ROM bytes, two above the line
        srli    a2, s4, 16              # the ROM's two
        lw      a3, 0(t1)               # $01000000's word (0x1122BB44)
        slli    a3, a3, 16              # its two low bytes, high
        or      a2, a2, a3
        beq     a1, a2, 1f
        j       fail
1:      li      gp, 13
        li      t2, 0xA1B2C3D4
        sw      t2, 13(t0)              # $00FFFFFD: three bytes dropped, $01000000 = 0xA1
        lbu     a1, 0(t1)
        li      a2, 0xA1
        beq     a1, a2, 1f
        j       fail
1:      lw      a1, 12(t0)
        beq     a1, s4, 1f              # the ROM is unchanged
        j       fail
1:      li      gp, 14
        li      t4, 0x40
        fcvt.d.w fa0, t4                # 64.0 = 0x4050_0000_0000_0000
        fsd     fa0, 12(t0)             # $00FFFFFC: the low word dropped, the high word above
        lw      a1, 0(t1)
        li      a2, 0x40500000
        beq     a1, a2, 1f
        j       fail
1:      li      gp, 15
        fld     fa1, 15(t0)             # $00FFFFFF: one ROM byte and seven above (three words)
        fsd     fa1, 16(t1)
        lbu     a1, 16(t1)
        srli    a2, s4, 24
        beq     a1, a2, 1f
        j       fail
1:      lw      a1, 17(t1)
        lw      a2, 0(t1)
        beq     a1, a2, 1f
        j       fail
1:      j       pass
