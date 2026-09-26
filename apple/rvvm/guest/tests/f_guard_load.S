# rvvm-expect: trap 3
# The null guard: a load through a null pointer.
        .section .text.init
        .globl  _start
_start: lw      t0, 0(zero)
