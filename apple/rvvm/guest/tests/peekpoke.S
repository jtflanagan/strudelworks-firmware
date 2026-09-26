# rvvm-expect: exit
# peek/poke (ECALL $5001/$5002): every width, a bank straddle, the guard read
# deliberately, bad widths - and ordinary loads and stores of the same bytes,
# since a guest address is the 65816's.
#include "rvvm_exit.h"
        .section .text.init
        .globl  _start
_start: li      gp, 1
        li      s0, 0xE12000            # Super Hi-Res memory
        mv      a0, s0
        li      a1, 0x11223344
        li      a2, 4
        li      a7, 0x5002
        ecall
        bnez    a0, fail
        li      gp, 2
        mv      a0, s0
        li      a1, 4
        li      a7, 0x5001
        ecall
        li      t0, 0x11223344
        bne     a0, t0, fail
        li      gp, 3
        addi    a0, s0, 1
        li      a1, 2
        li      a7, 0x5001
        ecall
        li      t0, 0x2233
        bne     a0, t0, fail
        li      gp, 4
        addi    a0, s0, 3
        li      a1, 1
        li      a7, 0x5001
        ecall
        li      t0, 0x11
        bne     a0, t0, fail
        li      gp, 5
        lw      t1, 0(s0)               # the same bytes by an ordinary load
        li      t0, 0x11223344
        bne     t1, t0, fail
        li      gp, 6
        li      t0, 0x55667788
        sw      t0, 4(s0)               # an ordinary store, read by peek
        addi    a0, s0, 4
        li      a1, 4
        li      a7, 0x5001
        ecall
        bne     a0, t0, fail
        li      gp, 7
        li      s1, 0x81FFFF            # poke 2 bytes across a bank boundary
        mv      a0, s1
        li      a1, 0xBEEF
        li      a2, 2
        li      a7, 0x5002
        ecall
        lbu     t1, 0(s1)
        li      t0, 0xEF
        bne     t1, t0, fail
        lbu     t1, 1(s1)
        li      t0, 0xBE
        bne     t1, t0, fail
        li      gp, 8
        li      a0, 0x10                # the guard, deliberately: no fault
        li      a1, 1
        li      a7, 0x5001
        ecall
        li      gp, 9
        mv      a0, s0                  # a bad width: peek returns 0 ...
        li      a1, 3
        li      a7, 0x5001
        ecall
        bnez    a0, fail
        li      gp, 10
        mv      a0, s0                  # ... and poke -22, writing nothing
        li      a1, 0
        li      a2, 8
        li      a7, 0x5002
        ecall
        li      t0, -22
        bne     a0, t0, fail
        lw      t1, 0(s0)
        li      t0, 0x11223344
        bne     t1, t0, fail
        PASS
fail:   FAIL
