# rvvm-expect: trap 5
# rvvm-load: 0xFF0000
# Straight-line code falls off the end of the 24-bit space.
        .section .text.init
        .globl  _start
_start: j       tail
        .org    0xFFF8
tail:   nop
        nop                             # the next fetch is $01000000
