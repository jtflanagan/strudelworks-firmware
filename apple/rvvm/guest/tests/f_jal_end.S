# rvvm-expect: trap 5
# rvvm-load: 0xFF0000
# A jal past the end of the 24-bit space (rd must not be written).
        .section .text.init
        .globl  _start
_start: li      ra, 0x1234
        jal     ra, . + 0x20000
