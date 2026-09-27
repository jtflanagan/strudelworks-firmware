# rvvm-expect: exit
# NaN-boxing: a single whose register is not boxed reads as the canonical NaN
# in every op (arithmetic, sign injection, class, fcvt.d.s), while fmv.x.w and
# fsw take its raw bits; every single result is boxed (fmv.w.x too).
        .section .text.init
        .globl  _start
_start:
        la      s0, buf
        li      s1, 0x3F800000          # 1.0f
        li      s2, 0x12345678          # not a box
        li      s4, 0xFFFFFFFF
        li      s5, 0x7FC00000          # the canonical NaN
        sw      s1, 0(s0)
        sw      s2, 4(s0)
        fld     ft0, 0(s0)              # 1.0f, not boxed
        li      gp, 1
        fadd.s  ft1, ft0, ft0
        fmv.x.w t2, ft1
        bne     t2, s5, fail
        li      gp, 2
        fmv.x.w t2, ft0                 # raw
        bne     t2, s1, fail
        fsw     ft0, 16(s0)             # raw
        lw      t2, 16(s0)
        bne     t2, s1, fail
        li      gp, 3
        fsgnjn.s ft2, ft0, ft0          # NaN, the sign of -(NaN)
        fmv.x.w t2, ft2
        li      t3, 0xFFC00000
        bne     t2, t3, fail
        li      gp, 4
        fclass.s t2, ft0
        li      t3, 0x200               # a quiet NaN
        bne     t2, t3, fail
        li      gp, 5
        fcvt.d.s fa0, ft0
        fsd     fa0, 24(s0)
        lw      t2, 28(s0)
        li      t3, 0x7FF80000
        bne     t2, t3, fail
        lw      t2, 24(s0)
        bnez    t2, fail
        li      gp, 6
        fsd     ft1, 32(s0)             # a single result: boxed
        lw      t2, 36(s0)
        bne     t2, s4, fail
        fmv.w.x ft3, s1
        fsd     ft3, 40(s0)
        lw      t2, 44(s0)
        bne     t2, s4, fail
        li      gp, 7
        fadd.s  ft4, ft3, ft3           # 2.0f, from a proper box
        fmv.x.w t2, ft4
        li      t3, 0x40000000
        bne     t2, t3, fail
        li      gp, 8
        frflags t2                      # nothing signalled so far (quiet NaNs)
        bnez    t2, fail
        li      a0, 0
        li      a7, 93
        ecall
fail:   mv      a0, gp
        li      a7, 93
        ecall

        .data
        .align  4
buf:    .space  64
