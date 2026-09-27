# rvvm-expect: trap 1
# frm = 5 (reserved) and an op on the dynamic mode: an illegal instruction.
# An op with a static mode still runs.
        .section .text.init
        .globl _start
_start:
        li      t0, 5
        fsrm    t0
        fcvt.d.w fa2, zero
        fsgnjn.d fa3, fa2, fa2          # no rounding mode: fine
        fadd.d  fa0, fa2, fa2, rne      # static: fine
        fadd.d  fa0, fa2, fa2           # dynamic with frm 5: illegal
        li      a0, 0
        li      a7, 93
        ecall
