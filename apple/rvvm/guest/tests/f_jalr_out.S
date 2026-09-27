# rvvm-expect: trap 5
# $0200_0000 is the first address past the engine's 32 MB.
        .section .text.init
        .globl  _start
_start: li      t0, 0x02000000
        jalr    ra, t0
