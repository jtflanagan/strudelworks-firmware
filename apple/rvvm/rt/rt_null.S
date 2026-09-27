/* SPDX-License-Identifier: GPL-2.0-or-later
 * SPDX-FileCopyrightText: 2026 jtflanagan
 *
 * rt_null - the RISC-V side of rung I2 (docs/RVV2_INTEROP.md): what the
 * runtime runs, in its own ROM bank ($F1), where an application's program will
 * run at rung I3.  It checks the environment block it is handed in a0 and
 * exits 0, or with the number of the first check that failed:
 *   1 the magic 'RVEN'         2 version 1, size 64      3 a user ID
 *   4 low_base is a0           5 the low block is in a bank the engine reads
 *                                itself (not $00/$01/$E0/$E1, below 16 MB)
 *   6 the bounce buffer and the call area lie inside the low block, in order
 *   7 the call area keeps a word written to it
 *   8 the video field agrees with the flags, and ENABLE is off
 * Position-independent: its only addresses are a0's and constants.
 */
        .option norvc
        .section .text
        .globl  _start
_start: mv      s0, a0
        li      a0, 1
        lw      t0, 0(s0)
        li      t1, 0x4E455652          /* 'R','V','E','N' */
        bne     t0, t1, fail
        li      a0, 2
        lhu     t0, 4(s0)
        li      t1, 1
        bne     t0, t1, fail
        lhu     t0, 6(s0)
        li      t1, 64
        bne     t0, t1, fail
        li      a0, 3
        lhu     t0, 8(s0)
        beqz    t0, fail
        li      a0, 4
        lw      t0, 12(s0)
        bne     t0, s0, fail
        li      a0, 5
        srli    t0, s0, 16              /* the bank */
        li      t1, 2
        bltu    t0, t1, fail            /* $00, $01 */
        li      t1, 0xE0
        beq     t0, t1, fail
        li      t1, 0xE1
        beq     t0, t1, fail
        li      t1, 0x100
        bgeu    t0, t1, fail
        li      a0, 6
        lw      t2, 16(s0)              /* low_size */
        add     t2, t2, s0              /* the low block's end */
        lw      t3, 20(s0)              /* bounce */
        lw      t4, 24(s0)
        add     t4, t4, t3              /* its end */
        lw      t5, 28(s0)              /* call */
        lw      t6, 32(s0)
        add     t6, t6, t5              /* its end */
        addi    t0, s0, 64
        bltu    t3, t0, fail            /* after the environment block */
        bltu    t5, t4, fail            /* the call area after the bounce buffer */
        bltu    t2, t6, fail            /* both inside */
        li      a0, 7
        li      t0, 0x5A3C96E1
        sw      t0, 0(t5)
        lw      t1, 0(t5)
        bne     t0, t1, fail
        sw      zero, 0(t5)
        li      a0, 8
        lhu     t0, 10(s0)              /* flags bit 0: owns enhanced video */
        andi    t0, t0, 1
        lw      t1, 60(s0)              /* the control bank */
        beqz    t0, 1f
        li      t2, 0x00E20000
        bne     t1, t2, fail
        lbu     t2, 0(t1)               /* ENABLE: off, as the runtime left it */
        bnez    t2, fail
        j       2f
1:      bnez    t1, fail
2:      li      a0, 0
fail:   li      a7, 93
        ecall
1:      j       1b                      /* exit does not return */
