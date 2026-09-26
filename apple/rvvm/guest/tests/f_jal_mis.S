# rvvm-expect: trap 5
        .section .text.init
        .globl  _start
_start: nop
        jal     ra, . + 6
