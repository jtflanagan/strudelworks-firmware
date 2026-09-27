# rvvm-expect: exit
# Misaligned loads and stores, done by the engine itself (the user, 2026-09-26):
# every width at every offset across a word, a 16-byte row, a 256-byte page and
# a bank; a double across three words; a load's value used at once; a store
# read straight back; an access half in a bank the 65816 serves (the VM does it
# whole, both ways round); a store into the ROM, dropped.  The bench judges
# every retire against the model; the checks here are for runs it cannot.
#include "rvvm_exit.h"
        .section .text.init
        .globl  _start
_start: la      s0, buf                 # 512 bytes, 256-aligned: byte i = i
        li      t0, 0
1:      add     t1, s0, t0
        sb      t0, 0(t1)
        addi    t0, t0, 1
        li      t1, 256
        bltu    t0, t1, 1b
        li      t0, 0
1:      add     t1, s0, t0
        sb      t0, 256(t1)
        addi    t0, t0, 1
        li      t1, 256
        bltu    t0, t1, 1b
        # words at every offset
        li      gp, 1
        lw      a0, 1(s0)
        li      a1, 0x04030201
        bne     a0, a1, fail
        lw      a0, 2(s0)
        li      a1, 0x05040302
        bne     a0, a1, fail
        lw      a0, 3(s0)
        li      a1, 0x06050403
        bne     a0, a1, fail
        # across a row, a page
        li      gp, 2
        lw      a0, 14(s0)
        li      a1, 0x11100F0E
        bne     a0, a1, fail
        lw      a0, 254(s0)
        li      a1, 0x0100FFFE
        bne     a0, a1, fail
        # halves across a word, signed and not
        li      gp, 3
        lhu     a0, 3(s0)
        li      a1, 0x0403
        bne     a0, a1, fail
        lh      a0, 255(s0)             # 0x00FF: positive
        li      a1, 0xFF
        bne     a0, a1, fail
        lh      a0, 511(s0)             # 0xFF and the byte past buf (0): positive too
        lh      a0, 127(s0)             # 0x807F
        li      a1, 0xFFFF807F
        bne     a0, a1, fail
        # the value used at once
        li      gp, 4
        lw      a0, 5(s0)
        addi    a1, a0, 1
        li      a2, 0x08070606
        bne     a1, a2, fail
        # stores: a word across a word, a half across a word, read straight back
        li      gp, 5
        li      t2, 0xA1B2C3D4
        sw      t2, 65(s0)
        lw      a0, 65(s0)
        bne     a0, t2, fail
        lbu     a0, 65(s0)
        li      a1, 0xD4
        bne     a0, a1, fail
        lbu     a0, 68(s0)
        li      a1, 0xA1
        bne     a0, a1, fail
        lbu     a0, 64(s0)              # untouched either side
        li      a1, 64
        bne     a0, a1, fail
        lbu     a0, 69(s0)
        li      a1, 69
        bne     a0, a1, fail
        li      t2, 0xBEEF
        sh      t2, 71(s0)
        lhu     a0, 71(s0)
        bne     a0, t2, fail
        # across a page
        li      gp, 6
        li      t2, 0x5A6B7C8D
        sw      t2, 254(s0)
        lw      a0, 254(s0)
        bne     a0, t2, fail
        # a double across three words, and stored across three
        li      gp, 7
        fld     fa0, 129(s0)
        fsd     fa0, 201(s0)
        lw      a0, 201(s0)
        li      a1, 0x84838281
        bne     a0, a1, fail
        lw      a0, 205(s0)
        li      a1, 0x88878685
        bne     a0, a1, fail
        fsw     fa0, 211(s0)
        flw     ft0, 211(s0)
        fmv.x.w a0, ft0
        li      a1, 0x84838281
        bne     a0, a1, fail
        # across a bank the engine serves: $02FFFE
        li      gp, 8
        li      t0, 0x2FFFFE
        li      t2, 0x13572468
        sw      t2, 0(t0)
        lw      a0, 0(t0)
        bne     a0, t2, fail
        # half in bank $01 (the 65816's), half in $02: the VM does it whole
        li      gp, 9
        li      t0, 0x1FFFC
        li      t2, 0x44332211
        sw      t2, 0(t0)               # bank $01: the VM's
        li      t3, 0x88776655
        sw      t3, 4(t0)               # $020000: the engine's
        lw      a0, 2(t0)
        li      a1, 0x66554433
        bne     a0, a1, fail
        li      t2, 0xCAFEF00D
        sw      t2, 2(t0)
        lw      a0, 2(t0)
        bne     a0, t2, fail
        lw      a0, 4(t0)
        li      a1, 0x8877CAFE
        bne     a0, a1, fail
        # the other way round: $DFFFFE, the engine's word then bank $E0's
        li      gp, 10
        li      t0, 0xDFFFFE
        li      t2, 0x0BADC0DE
        sw      t2, 0(t0)
        lw      a0, 0(t0)
        bne     a0, t2, fail
        # into the ROM: dropped, the ROM as it was
        li      gp, 11
        li      t0, 0xFE0000
        lw      s1, 0(t0)
        lw      s2, 4(t0)
        li      t2, 0x12345678
        sw      t2, 2(t0)
        lw      a0, 0(t0)
        bne     a0, s1, fail
        lw      a0, 4(t0)
        bne     a0, s2, fail
        PASS
fail:   FAIL

        .data
        .balign 256
buf:    .space  512
        .word   0
