# rvvm-expect: trap 4
# The null guard's last byte.
        .section .text.init
        .globl  _start
_start: sb      zero, 0xFF(zero)
