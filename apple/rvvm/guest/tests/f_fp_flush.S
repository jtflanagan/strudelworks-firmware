# rvvm-expect: exit
# An FPU operation killed in flight: behind a mispredicted branch (the redirect
# from M), behind a delegated load (the event from M flushes E), and behind a
# delegated FP load (R_DFL) - each then runs the next FP op clean.  The flags
# a killed op would have raised must not reach fflags.
        .section .text.init
        .globl  _start
_start:
        la      s0, buf
        li      s1, 0x010100            # bank $01: delegated
        li      t0, 7
        fcvt.d.w fa1, t0
        li      t0, 3
        fcvt.d.w fa2, t0
        fcvt.d.w fa3, zero
        fsflags zero
        li      gp, 1
        beq     zero, zero, 1f          # forward, taken: predicted not
        fdiv.d  fa0, fa1, fa3           # the wrong path (1/0: DZ if it counted)
        fdiv.d  fa0, fa1, fa3
1:      frflags t2
        bnez    t2, fail
        fdiv.d  fa4, fa1, fa2           # 7/3, inexact
        frflags t2
        li      t3, 1
        bne     t2, t3, fail
        fsflags zero
        li      gp, 2
        lw      t1, 0(s1)               # delegated: an event in M
        fsqrt.d fa5, fa2                # flushed behind it, then again
        fmul.d  fa6, fa5, fa5
        fcvt.w.d t2, fa6, rne
        li      t3, 3
        bne     t2, t3, fail
        li      gp, 3
        fld     fa7, 0(s1)              # bank $01: the VM's (R_DFL)
        fdiv.d  fa0, fa1, fa2
        fmadd.d fa0, fa0, fa2, fa3
        fcvt.w.d t2, fa0, rne
        li      t3, 7
        bne     t2, t3, fail
        li      gp, 4
        li      t0, 1
        bnez    t0, 2f                  # taken, forward
        fcvt.s.d ft0, fa1
2:      fcvt.s.d ft1, fa2
        fcvt.w.s t2, ft1
        li      t3, 3
        bne     t2, t3, fail
        li      a0, 0
        li      a7, 93
        ecall
fail:   mv      a0, gp
        li      a7, 93
        ecall

        .data
        .align  4
buf:    .space  64
