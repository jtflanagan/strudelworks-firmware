/* rvvm guest services: the VM's ECALL door (a7 = number, Linux/newlib
   numbering; docs/REQ_RVVM.md section 3). */
#ifndef RVVM_H
#define RVVM_H

static inline long rvvm_ecall3(long n, long a0, long a1, long a2) {
    register long r_a0 __asm__("a0") = a0;
    register long r_a1 __asm__("a1") = a1;
    register long r_a2 __asm__("a2") = a2;
    register long r_a7 __asm__("a7") = n;
    __asm__ volatile("ecall" : "+r"(r_a0) : "r"(r_a1), "r"(r_a2), "r"(r_a7) : "memory");
    return r_a0;
}
static inline long rvvm_write(int fd, const void *buf, unsigned long len) { return rvvm_ecall3(64, fd, (long)buf, (long)len); }
static inline long rvvm_read(int fd, void *buf, unsigned long len) { return rvvm_ecall3(63, fd, (long)buf, (long)len); }
/* rvvm's own service $5000: the platform's cycle counter (in the sim, the
   exact 65816 cycle count). */
static inline unsigned long long rvvm_cycles(void) {
    register long r_a0 __asm__("a0");
    register long r_a1 __asm__("a1");
    register long r_a7 __asm__("a7") = 0x5000;
    __asm__ volatile("ecall" : "=r"(r_a0), "=r"(r_a1) : "r"(r_a7) : "memory");
    return ((unsigned long long)(unsigned long)r_a1 << 32) | (unsigned long)r_a0;
}
/* rvvm's own services $5001/$5002: a deliberate access at any 24-bit address,
   the null guard ($000000-$0000FF) included, performed as a real 65816 access. */
static inline unsigned long rvvm_peek(unsigned long addr, unsigned width) { return (unsigned long)rvvm_ecall3(0x5001, (long)addr, (long)width, 0); }
static inline long rvvm_poke(unsigned long addr, unsigned long value, unsigned width) { return rvvm_ecall3(0x5002, (long)addr, (long)value, (long)width); }
static inline unsigned char  rvvm_peek8(unsigned long a)  { return (unsigned char)rvvm_peek(a, 1); }
static inline unsigned short rvvm_peek16(unsigned long a) { return (unsigned short)rvvm_peek(a, 2); }
static inline unsigned long  rvvm_peek32(unsigned long a) { return rvvm_peek(a, 4); }
static inline void rvvm_poke8(unsigned long a, unsigned char v)   { rvvm_poke(a, v, 1); }
static inline void rvvm_poke16(unsigned long a, unsigned short v) { rvvm_poke(a, v, 2); }
static inline void rvvm_poke32(unsigned long a, unsigned long v)  { rvvm_poke(a, v, 4); }
static inline __attribute__((noreturn)) void rvvm_exit(int code) { rvvm_ecall3(93, code, 0, 0); __builtin_unreachable(); }

#endif
