# rvvm-expect: exit
# The L2's probe against a 65816 write's landing (rtl/gs/page_cam.sv, il_ack;
# on HW 2026-09-27 the engine ran $00F1E000, a word memory did not hold, after an
# ECALL).  A probe acked the clock after a write's P0 had its row read taken
# by the landing, and rv_mem kept the landed row as the probe's.  The setup
# that met it: the fetch past an ECALL, out when the ECALL flushed the pipe,
# missing the instruction cache AND the L2 - its fill and second probe run on
# while the 65816 services the ECALL (its RAM writes: the VM's direct page,
# the stack).  Here every ECALL (the VM's peek, 0x5001) is the last word of a
# page, and the instruction after it the first of a page 100 stubs
# (50 KB, more than the L2's 32 KB) have gone by since: cold.  Each post-ECALL
# instruction counts itself; a peek must read what the engine reads.  On the
# GS bench page_cam's own check names the clash the clock it happens - but the
# bench has no interrupt source, and the unfixed page_cam met no clash here in
# 2000 ECALLs: the write that met it on HW was most likely an interrupt's.
#include "rvvm_exit.h"
        .section .text.init
        .globl  _start

#define NSTUB  100
#define ROUNDS 20

_start: li      gp, 1
        li      s0, 0x00F10000          # the ROM: what the peek reads
        lw      s4, 0(s0)               # ...and the engine's own read of it
        li      s3, 0                   # post-ECALL instructions run
        li      s5, ROUNDS
round:  la      t2, stubs + 0xF4
        li      s6, NSTUB
next:   mv      a0, s0
        li      a1, 4
        jalr    ra, 0(t2)
        bne     a0, s4, fail
        addi    t2, t2, 512
        addi    s6, s6, -1
        bnez    s6, next
        addi    s5, s5, -1
        bnez    s5, round
        li      gp, 2
        li      t0, NSTUB * ROUNDS
        bne     s3, t0, fail
        j       pass
fail:   FAIL
pass:   PASS

# Each stub: the peek's ECALL in the last word of one page, the instruction
# after it the first of the next; two pages a stub.
        .balign 256
stubs:
        .rept   NSTUB
        .skip   0xF4
        lui     a7, 0x5
        addi    a7, a7, 1
        ecall
        addi    s3, s3, 1               # (offset 0 of a cold page)
        ret
        .skip   0xF8
        .endr
