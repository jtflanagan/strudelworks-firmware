/* rvvm guest start-up (docs/REQ_RVVM.md): the VM enters at the image's first
   byte with sp set and every other register 0.  The image is a static PIE
   linked at 0 and loaded anywhere (the identity map: its addresses are the
   65816's), so first it relocates itself - every R_RISCV_RELATIVE in .rela.dyn
   gets the load offset added; any other kind is a build error (an object
   without -fPIE) and stops at an ebreak.  Then gp, .bss, main(0, 0), exit. */
        .section .text.init
        .option norvc
        .globl  _start
_start:
        lla     t0, _start              /* where it is */
        lla     t1, link_start
        lw      t2, 0(t1)               /* where it was linked (read before it is relocated) */
        sub     t0, t0, t2              /* the offset */
        beqz    t0, 3f
        lla     t3, __rela_dyn_start
        lla     t4, __rela_dyn_end
        li      t6, 3                   /* R_RISCV_RELATIVE, no symbol */
1:      bgeu    t3, t4, 3f
        lw      t5, 4(t3)               /* r_info */
        beq     t5, t6, 2f
        ebreak                          /* not a relative relocation: rebuild with -fPIE */
2:      lw      t5, 0(t3)               /* r_offset */
        lw      t2, 8(t3)               /* r_addend */
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
5:      li      a0, 0
        li      a1, 0
        call    main
        li      a7, 93
        ecall

        .section .data.rel.ro
        .p2align 2
link_start:
        .word   _start
