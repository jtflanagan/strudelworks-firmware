# rvvm-expect: exit
# rvvm-load: 0x1800000
# rvvm-hi
# A guest wholly in the upper 16 MB, touching its last word, halfword and byte:
# $01FF_FFFC is the last aligned word the engine has.
#include "rvvm_exit.h"
        .section .text.init
        .globl  _start
_start: li      gp, 1
        auipc   t0, 0                   # the second instruction: $01800004
        li      t1, 0x01800004
        beq     t0, t1, 1f
        j       fail
1:      li      gp, 2
        li      t0, 0x01FFFFFC
        li      t1, 0xA5C3E1F0
        sw      t1, 0(t0)
        lw      t2, 0(t0)
        beq     t1, t2, 1f
        j       fail
1:      li      gp, 3
        li      t3, 0x7E
        sb      t3, 3(t0)               # $01FFFFFF, the last byte
        lhu     t2, 2(t0)
        li      t4, 0x7EC3
        beq     t2, t4, 1f
        j       fail
1:      li      gp, 4
        sh      zero, 0(t0)
        lw      t2, 0(t0)
        li      t4, 0x7EC30000
        beq     t2, t4, 1f
        j       fail
1:      j       pass
fail:   FAIL
pass:   PASS
