# rvvm-expect: trap 5
# rvvm-load: 0x1000
# A backward branch into the null guard ($000000-$0000FF) within bank 0.
        .section .text.init
        .globl  _start
_start: nop
        beq     zero, zero, . - 0xF0C   # $1004 -> $00F8
