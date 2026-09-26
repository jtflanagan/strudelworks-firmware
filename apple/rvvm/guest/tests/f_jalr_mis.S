# rvvm-expect: trap 5
# Without C every target must be 4-aligned; jalr clears only bit 0.
        .section .text.init
        .globl  _start
_start: la      t0, _start
        addi    t0, t0, 10
        jalr    ra, t0
