# rvvm-expect: trap 3
# peek past the 65816's space is a load fault.
        .section .text.init
        .globl  _start
_start: li      a0, 0x01000000
        li      a1, 1
        li      a7, 0x5001
        ecall
