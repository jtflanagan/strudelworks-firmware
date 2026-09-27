# rvvm-expect: exit
# rvvm-load: 0xFF0000
# rvvm-hi
# The 16 MB line is only a line to the engine: straight-line code, branches and
# jal/jalr across $0100_0000 in both directions, and aligned loads and stores of
# every width on both sides of it (the lower 16 MB is the 65816's space, the
# upper the engine's alone; both are engine-direct).  Aligned only: a misaligned
# access still goes to the 65816, which cannot reach the upper half.
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
        li      t0, 0x00FFFFF0          # the last row below the line
        li      t1, 0x01000000          # the first row above it
        li      t2, 0x11223344
        sw      t2, 12(t0)              # $00FFFFFC
        sw      t2, 0(t1)               # $01000000
        not     t3, t2
        sh      t3, 14(t0)              # $00FFFFFE
        sb      t3, 1(t1)               # $01000001
        lw      a1, 12(t0)
        li      a2, 0xCCBB3344
        beq     a1, a2, 1f
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
        lbu     a1, 15(t0)              # $00FFFFFF
        li      a2, 0xCC
        beq     a1, a2, 1f
        j       fail
1:      li      gp, 11
        lb      a1, 1(t1)
        li      a2, -69                 # 0xBB
        beq     a1, a2, 1f
        j       fail
1:      j       pass
