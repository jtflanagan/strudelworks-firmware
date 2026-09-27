# rvvm-expect: exit
# The engine's view of the machine's map (docs/RVV2_INTEROP.md): what it reads
# itself must equal what the 65816 reads (peek) - the ROM and our banks direct,
# banks $01 and $E1 delegated - a store to the ROM is dropped as the machine
# drops it, and a store to our RAM or a delegated bank sticks.
#include "rvvm_exit.h"
        .section .text.init
        .globl  _start

# PEEK4 rd, addr-reg: the 65816's own read of a word
.macro  PEEK4 rd, ar
        mv      a0, \ar
        li      a1, 4
        li      a7, 0x5001
        ecall
        mv      \rd, a0
.endm

_start: li      gp, 1
        li      s0, 0x00F10000          # the ROM: the runtime's bank
        lw      s1, 0(s0)               # the engine's own read (direct)
        PEEK4   s2, s0
        beq     s1, s2, 1f
        j       fail
1:      li      gp, 2
        li      s0, 0x00FFFFFC          # the ROM's last word (the 65816's vectors)
        lw      s1, 0(s0)
        PEEK4   s2, s0
        beq     s1, s2, 1f
        j       fail
1:      li      gp, 3
        li      t0, 0x5A5A5A5A          # a store to the ROM is dropped
        sw      t0, 0(s0)
        lw      s3, 0(s0)
        beq     s3, s1, 1f
        j       fail
1:      li      gp, 4
        li      s0, 0x00E20100          # our RAM: written and read directly
        li      t0, 0x13572468
        sw      t0, 0(s0)
        lw      s1, 0(s0)
        bne     s1, t0, fail
        PEEK4   s2, s0
        bne     s2, t0, fail
        li      gp, 5
        li      s0, 0x00E12000          # $E1: delegated both ways, still memory
        li      t0, 0x0BADF00D
        sw      t0, 0(s0)
        lw      s1, 0(s0)
        bne     s1, t0, fail
        PEEK4   s2, s0
        bne     s2, t0, fail
        li      gp, 6
        li      s0, 0x00018000          # $01: likewise
        li      t0, 0x600DCAFE
        sw      t0, 0(s0)
        lw      s1, 0(s0)
        bne     s1, t0, fail
        PEEK4   s2, s0
        bne     s2, t0, fail
        j       pass
fail:   FAIL
pass:   PASS
