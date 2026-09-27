# rvvm-expect: trap 3
# A write() whose buffer is in the upper 16 MB: the 65816 performs the
# service and cannot reach it, so it is a load fault at the buffer.
        .section .text.init
        .globl  _start
_start: li      a0, 1
        li      a1, 0x01000100
        li      a2, 4
        li      a7, 64
        ecall
