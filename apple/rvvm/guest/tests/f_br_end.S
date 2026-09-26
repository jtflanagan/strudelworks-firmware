# rvvm-expect: trap 5
# rvvm-load: 0xFF0000
# A forward branch past the end of the 24-bit space.
        .section .text.init
        .globl  _start
_start: j       tail
        .org    0xFFF8
tail:   beq     zero, zero, . + 16      # $FFFFF8 -> $01000008
