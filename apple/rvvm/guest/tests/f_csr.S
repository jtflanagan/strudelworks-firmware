# rvvm-expect: trap 1
# No Zicsr in the production VM: a CSR read is illegal.
        .section .text.init
        .globl  _start
_start: .word   0xC0002573              # csrr a0, cycle
