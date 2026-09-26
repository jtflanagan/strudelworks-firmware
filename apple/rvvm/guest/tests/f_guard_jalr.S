# rvvm-expect: trap 5
# A call through a null function pointer.
        .section .text.init
        .globl  _start
_start: jalr    ra, 0x40(zero)
