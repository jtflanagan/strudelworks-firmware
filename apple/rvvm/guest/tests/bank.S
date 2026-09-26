# rvvm-expect: exit
# Straight-line code, branches, jal/jalr, loads and stores across a 64 KB
# bank boundary (loaded at the default $800000, a bank start) - the paths no
# riscv-test reaches.
#include "rvvm_exit.h"
        .section .text.init
        .globl  _start
_start: li      gp, 1
        la      t0, seq
        jr      t0
fail:   FAIL
pass:   PASS

        .org    0xFFC0
back:   li      gp, 4                   # reached by a backward branch from bank 1
        beq     zero, zero, fwd         # forward, across the boundary
        j       fail
sub0:   ret                             # reached by jal from bank 1

        .org    0xFFF0
seq:    addi    a0, zero, 5
        addi    a0, a0, 1
        addi    a0, a0, 1
        addi    a0, a0, 1               # 0xFFFC
        addi    a0, a0, 1               # 0x10000, by falling through
        li      gp, 2
        li      t1, 9
        beq     a0, t1, 1f
        j       fail
1:      li      gp, 3
        beq     zero, zero, back        # backward, across the boundary
        j       fail
fwd:    li      gp, 5
        auipc   s0, 0                   # a pc in bank 1
        la      s1, fwd
        addi    s1, s1, 4
        beq     s0, s1, 1f
        j       fail
1:      li      gp, 6
        jal     ra, sub0                # backward across, and ret forward across
        li      gp, 7
        la      t0, _start
        li      t1, 0x1FFFE
        add     t0, t0, t1
        lw      t1, 0(t0)               # straddles a bank boundary
        li      t2, 0x66554433
        beq     t1, t2, 1f
        j       fail
1:      li      gp, 8
        lh      t1, 1(t0)               # 0x1FFFF: one byte each side
        li      t2, 0x5544
        beq     t1, t2, 1f
        j       fail
1:      li      gp, 9
        la      t0, _start
        li      t1, 0x2FFFD
        add     t0, t0, t1
        li      t1, 0xA1B2C3D4
        sw      t1, 0(t0)               # 0x2FFFD..0x30000
        lbu     t2, 3(t0)
        li      t3, 0xA1
        beq     t2, t3, 1f
        j       fail
1:      li      gp, 10
        lw      t2, 0(t0)
        beq     t2, t1, 1f
        j       fail
1:      li      gp, 11
        sh      t1, 2(t0)               # 0x2FFFF..0x30000
        lhu     t2, 2(t0)
        li      t3, 0xC3D4
        beq     t2, t3, 1f
        j       fail
1:      j       pass

        .org    0x1FFFC
        .word   0x44332211, 0x88776655
