# rvvm-expect: trap 3
# rvvm-load: 0x1FF0000
# rvvm-hi
# A misaligned access must lie wholly in the space: a word whose first bytes
# are the space's last is fine up to its last byte, and one past it is a load
# fault (tval its first byte).
        .section .text.init
        .globl  _start
_start:
        li      s0, 0x1FFFFF8
        lw      a0, 4(s0)               # the last word: fine
        lw      a0, 3(s0)               # ends on the last byte: fine
        lh      a0, 6(s0)               # likewise
        lw      a0, 5(s0)               # one byte past the end: a load fault
        li      a0, 0
        li      a7, 93
        ecall
