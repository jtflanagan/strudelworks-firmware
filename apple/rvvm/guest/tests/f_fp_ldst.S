# rvvm-expect: exit
# F and D loads and stores: aligned, a double at a 4-byte boundary (its two
# words in different 8-byte blocks), misaligned (the VM does the whole access:
# R_DFL/R_DFS), in bank $01 (delegated: the 65816's), a single's box, and the
# integer <-> FP moves after a load (the load-use wait on an integer source).
# The bench judges every retire; the checks here are for the runs it cannot.
        .section .text.init
        .globl  _start
_start:
        la      s0, buf
        li      s1, 0x010100            # bank $01
        li      s2, 0x89ABCDEF
        li      s3, 0x01234567
        li      s4, 0xFFFFFFFF
        sw      s2, 0(s0)
        sw      s3, 4(s0)
        # aligned: fld, fsd, the words back
        li      gp, 1
        fld     fa0, 0(s0)
        fsd     fa0, 16(s0)
        lw      t2, 16(s0)
        bne     t2, s2, fail
        lw      t2, 20(s0)
        bne     t2, s3, fail
        # at a 4-byte boundary
        li      gp, 2
        fsd     fa0, 36(s0)
        fld     fa1, 36(s0)
        fsd     fa1, 48(s0)
        lw      t2, 48(s0)
        bne     t2, s2, fail
        lw      t2, 52(s0)
        bne     t2, s3, fail
        # a single: flw boxes it, fsw stores the low word, fsd shows the box
        li      gp, 3
        flw     ft0, 4(s0)
        fsw     ft0, 64(s0)
        fsd     ft0, 72(s0)
        lw      t2, 64(s0)
        bne     t2, s3, fail
        lw      t2, 72(s0)
        bne     t2, s3, fail
        lw      t2, 76(s0)
        bne     t2, s4, fail
        # misaligned, both widths
        li      gp, 4
        fsd     fa0, 81(s0)
        fld     fa2, 81(s0)
        fsd     fa2, 96(s0)
        lw      t2, 96(s0)
        bne     t2, s2, fail
        lw      t2, 100(s0)
        bne     t2, s3, fail
        fsw     ft0, 107(s0)
        flw     ft1, 107(s0)
        fmv.x.w t2, ft1
        bne     t2, s3, fail
        # bank $01, both widths
        li      gp, 5
        fsd     fa0, 0(s1)
        fld     fa3, 0(s1)
        fsd     fa3, 112(s0)
        lw      t2, 112(s0)
        bne     t2, s2, fail
        lw      t2, 116(s0)
        bne     t2, s3, fail
        fsw     ft0, 8(s1)
        flw     ft2, 8(s1)
        fmv.x.w t2, ft2
        bne     t2, s3, fail
        # an integer load straight into an FP op, and back
        li      gp, 6
        lw      t0, 0(s0)
        fmv.w.x ft3, t0
        fmv.x.w t1, ft3
        bne     t1, s2, fail
        lw      t0, 4(s0)
        fcvt.d.w fa4, t0
        fcvt.w.d t1, fa4, rtz
        bne     t1, s3, fail
        # an FP load straight into an FP op, its result straight into a store
        li      gp, 7
        fld     fa5, 0(s0)
        fsgnjx.d fa6, fa5, fa5          # sign xor itself: cleared
        fsd     fa6, 128(s0)
        lw      t2, 132(s0)
        li      t3, 0x01234567
        bne     t2, t3, fail
        li      a0, 0
        li      a7, 93
        ecall
fail:   mv      a0, gp
        li      a7, 93
        ecall

        .data
        .align  4
buf:    .space  256
