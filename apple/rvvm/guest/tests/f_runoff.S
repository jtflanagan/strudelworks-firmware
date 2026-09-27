# rvvm-expect: trap 5
# rvvm-load: 0x1FF0000
# rvvm-hi
# Straight-line code falls off the end of the engine's 32 MB.
        .section .text.init
        .globl  _start
_start: j       tail
        .org    0xFFF8
tail:   nop
        nop                             # the next fetch is $02000000
