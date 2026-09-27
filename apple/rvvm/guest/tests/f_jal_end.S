# rvvm-expect: trap 5
# rvvm-load: 0x1FF0000
# rvvm-hi
# A jal past the end of the engine's 32 MB (rd must not be written).
        .section .text.init
        .globl  _start
_start: li      ra, 0x1234
        jal     ra, . + 0x20000
