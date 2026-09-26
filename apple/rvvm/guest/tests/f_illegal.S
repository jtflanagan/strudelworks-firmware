# rvvm-expect: trap 1
        .section .text.init
        .globl  _start
_start: nop
        .word   0xFFFFFFFF
