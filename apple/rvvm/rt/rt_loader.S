/* SPDX-License-Identifier: GPL-2.0-or-later
 * SPDX-FileCopyrightText: 2026 jtflanagan
 *
 * rt_loader - the runtime's RISC-V loader (docs/RVV2_INTEROP.md, rung I3), run
 * in place in the runtime's bank ($F1): the 65816 cannot write the upper 16 MB,
 * the engine can.  a0 = the environment block; the runtime has opened the
 * program's file, sized and registered its upper-half memory from the image
 * header, and holds the file's first chunk in the bounce buffer.
 *
 *   loop: n = ECALL $5020 (the next chunk: the bytes now in the bounce buffer,
 *         0 at the end, negative a GS/OS error) -> copy them to image_base + offset
 *   then: the whole file arrived, fence.i (the program was written through the
 *         data side), sp = the top of its memory, a0 = the environment block,
 *         and into the program's first byte.
 *
 * Exit codes of its own: the GS/OS error, negated; -8 the file ended short of
 * image_size.  Chunks are the bounce buffer's size (a multiple of 4) but the
 * last, so the copy is by words and the last chunk's tail by bytes.
 */
        .option norvc
        .section .text
        .globl  _start
_start: mv      s0, a0
        lw      s1, 44(s0)              /* image_base */
        mv      s2, s1                  /* where the next byte goes */
        lw      s3, 20(s0)              /* the bounce buffer */
1:      li      a7, 0x5020
        ecall
        bltz    a0, fail
        beqz    a0, 5f
        mv      t0, s3
        add     t1, s3, a0              /* the chunk's end */
2:      addi    t2, t0, 4
        bltu    t1, t2, 3f
        lw      t3, 0(t0)
        sw      t3, 0(s2)
        mv      t0, t2
        addi    s2, s2, 4
        j       2b
3:      bgeu    t0, t1, 1b
        lbu     t3, 0(t0)
        sb      t3, 0(s2)
        addi    t0, t0, 1
        addi    s2, s2, 1
        j       3b
5:      sub     t0, s2, s1
        lw      t1, 48(s0)              /* image_size */
        li      a0, -8
        bne     t0, t1, fail
        fence.i
        lw      t0, 36(s0)              /* hi_base */
        lw      t1, 40(s0)              /* hi_size */
        add     sp, t0, t1
        mv      a0, s0
        jr      s1
fail:   li      a7, 93
        ecall
4:      j       4b                      /* exit does not return */
