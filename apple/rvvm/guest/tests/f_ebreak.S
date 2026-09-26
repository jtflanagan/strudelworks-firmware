# rvvm-expect: trap 2
        .section .text.init
        .globl  _start
_start: li      a0, 42
        ebreak
