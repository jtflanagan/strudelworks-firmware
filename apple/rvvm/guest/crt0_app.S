/* The start-up of a GS/OS application's RISC-V program (docs/RVV2_INTEROP.md):
   a static PIE the runtime's loader copies into the upper 16 MB and enters at
   its first byte with a0 = the environment block (struct rv_env, rvgs.h) and
   sp at the top of the memory registered to the application.
   THE IMAGE HEADER follows the first jump; the runtime reads it from the first
   chunk of the file, before anything runs, to size that memory:
     +4  'RVIM'     +8  its version (1)
     +12 memory: the image and its bss (_end - _start)
     +16 the stack, +20 the heap to reserve (link.ld's __stack_size, __heap_size)
   Then as crt0.S: relocate, gp, .bss; rv_env = the environment block;
   main(0, 0); exit with its result. */
        .section .text.init
        .option norvc
        .globl  _start
_start: j       1f
        .word   0x4D495652              /* 'RVIM' */
        .word   1
        .word   _end - _start
        .word   __stack_size
        .word   __heap_size
1:      mv      s0, a0                  /* the environment block, kept past the start-up */
        lla     t0, _start
        lla     t1, link_start
        lw      t2, 0(t1)               /* where it was linked (read before it is relocated) */
        sub     t0, t0, t2              /* the offset */
        beqz    t0, 3f
        lla     t3, __rela_dyn_start
        lla     t4, __rela_dyn_end
        li      t6, 3                   /* R_RISCV_RELATIVE, no symbol */
1:      bgeu    t3, t4, 3f
        lw      t5, 4(t3)
        beq     t5, t6, 2f
        ebreak                          /* not a relative relocation: rebuild with -fPIE */
2:      lw      t5, 0(t3)
        lw      t2, 8(t3)
        add     t5, t5, t0
        add     t2, t2, t0
        sw      t2, 0(t5)
        addi    t3, t3, 12
        j       1b
3:
        .option push
        .option norelax
        lla     gp, __global_pointer$
        .option pop
        lla     t0, __bss_start
        lla     t1, _end
4:      bgeu    t0, t1, 5f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       4b
5:      lla     t0, rv_env
        sw      s0, 0(t0)
        li      a0, 0
        li      a1, 0
        call    main
        li      a7, 93
        ecall

        .section .data.rel.ro
        .p2align 2
link_start:
        .word   _start

        .section .bss
        .p2align 2
        .globl  rv_env
rv_env: .space  4
