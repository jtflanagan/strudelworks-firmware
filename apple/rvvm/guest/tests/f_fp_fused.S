# rvvm-expect: exit
# The fused four with rs3 in bits 31:27, where OP-FP keeps its funct5: rs3 =
# f4, f5, f8, f11, f20, f24, f26, f28, f30 (the funct5 of fsgnj, fmin/max,
# fcvt.s.d/d.s, fsqrt, the compares, fcvt.w, fcvt.s.w, fclass/fmv.x.w, fmv.w.x)
# in both formats - a decoder or a model that reads them as funct5 goes wrong
# here.  2 * 3 + rs3 = 6 + 1 = 7 everywhere.
        .section .text.init
        .globl  _start
_start:
        li      t0, 2                   # (sources and results off the list)
        fcvt.d.w f6, t0
        fcvt.s.w f16, t0
        li      t0, 3
        fcvt.d.w f7, t0
        fcvt.s.w f17, t0
        li      t0, 1
        .irp r, f4, f5, f8, f11, f20, f24, f26, f28, f30
        fcvt.d.w \r, t0
        .endr
        li      gp, 1
        .irp r, f4, f5, f8, f11, f20, f24, f26, f28, f30
        fmadd.d f13, f6, f7, \r
        fcvt.w.d t1, f13
        li      t2, 7
        bne     t1, t2, fail
        fnmsub.d f14, f6, f7, \r      # -(2*3) + 1 = -5
        fcvt.w.d t1, f14
        li      t2, -5
        bne     t1, t2, fail
        addi    gp, gp, 1
        .endr
        .irp r, f4, f5, f8, f11, f20, f24, f26, f28, f30
        fcvt.s.w \r, t0
        .endr
        .irp r, f4, f5, f8, f11, f20, f24, f26, f28, f30
        fmadd.s f13, f16, f17, \r
        fcvt.w.s t1, f13
        li      t2, 7
        bne     t1, t2, fail
        fmsub.s f14, f16, f17, \r     # 2*3 - 1 = 5
        fcvt.w.s t1, f14
        li      t2, 5
        bne     t1, t2, fail
        fnmadd.s f15, f16, f17, \r    # -(2*3) - 1 = -7
        fcvt.w.s t1, f15
        li      t2, -7
        bne     t1, t2, fail
        addi    gp, gp, 1
        .endr
        li      a0, 0
        li      a7, 93
        ecall
fail:   mv      a0, gp
        li      a7, 93
        ecall
