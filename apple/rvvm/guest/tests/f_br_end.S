# rvvm-expect: trap 5
# rvvm-load: 0x1FF0000
# rvvm-hi
# A forward branch past the end of the engine's 32 MB.
        .section .text.init
        .globl  _start
_start: j       tail
        .org    0xFFF8
tail:   beq     zero, zero, . + 16      # $01FFFFF8 -> $02000008
