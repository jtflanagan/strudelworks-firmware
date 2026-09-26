# rvvm-expect: trap 4
        .section .text.init
        .globl  _start
_start: li      t0, -4
        sw      zero, 0(t0)
