/* A guest of rvvm (docs/REQ_RVVM.md): the identity map - a guest address is
   the 65816's.  Position-dependent images (the asm tests) link at their load
   address, -Wl,--defsym=__load=ADDR; C links at 0 as a static PIE and crt0
   applies its own R_RISCV_RELATIVE relocations wherever it was loaded.  The
   image is objcopy'd to a flat binary. */
ENTRY(_start)
SECTIONS {
  . = DEFINED(__load) ? __load : 0;
  .text : { *(.text.init) *(.text .text.*) }
  . = ALIGN(16);
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  . = ALIGN(16);
  .data.rel.ro : { *(.data.rel.ro .data.rel.ro.*) }
  .dynamic : { *(.dynamic) }
  .got : { *(.got .got.*) }
  .rela.dyn : { __rela_dyn_start = .; *(.rela.dyn .rela.*) __rela_dyn_end = .; }
  . = ALIGN(16);
  .data : { *(.data .data.*) }
  . = ALIGN(16);
  __global_pointer$ = . + 0x800;
  .sdata : { *(.sdata .sdata.*) }
  __bss_start = .;
  .sbss : { *(.sbss .sbss.*) }
  .bss : { *(.bss .bss.*) *(COMMON) }
  . = ALIGN(16);
  _end = .;
  /DISCARD/ : { *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash) *(.interp) *(.comment) }
}
