# rvvm-expect: trap 5
# rvvm-load: 0x1000
# A jal below address 0.
        .section .text.init
        .globl  _start
_start: nop
        jal     ra, . - 0x2000          # $1004 -> $FFFFF004
