# rvvm-expect: trap 3
# rvvm-load: 0x1FF0000
# rvvm-hi
# A double's second word must be in the space too: fld at the last 8 bytes
# is fine, at the last word it is a load fault (tval the first address).
        .section .text.init
        .globl  _start
_start:
        li      s0, 0x1FFFFF8
        fsd     fa0, 0(s0)
        fld     fa1, 0(s0)
        flw     ft0, 4(s0)
        fld     fa2, 4(s0)
        li      a0, 0
        li      a7, 93
        ecall
