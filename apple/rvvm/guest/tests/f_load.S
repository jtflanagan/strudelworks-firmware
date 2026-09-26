# rvvm-expect: trap 3
        .section .text.init
        .globl  _start
_start: li      t0, 0x7F000000
        lw      t1, 0(t0)
