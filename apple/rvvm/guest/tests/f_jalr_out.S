# rvvm-expect: trap 5
# $0100_0000 is the first address past the 65816's space.
        .section .text.init
        .globl  _start
_start: li      t0, 0x01000000
        jalr    ra, t0
