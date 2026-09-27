/* rvgs.h - a GS/OS application's RISC-V side (docs/RVV2_INTEROP.md): the
   environment block the runtime hands its program (crt0_app.S keeps it in
   rv_env).  Every address is a 24-bit IIgs address unless it says upper.
   The start of librvgs. */
#ifndef RVGS_H
#define RVGS_H
#include <stdint.h>

struct rv_env {
    uint32_t magic;                     /* 'RVEN' */
    uint16_t version, size;             /* 1, 64 */
    uint16_t user_id;                   /* the application's GS/OS user ID */
    uint16_t flags;                     /* RV_ENV_VIDEO: it owns enhanced video */
    uint32_t low_base, low_size;        /* the low block: this block, then the runtime's */
    uint32_t bounce, bounce_size;       /* the I/O bounce buffer */
    uint32_t call, call_size;           /* the call area */
    uint32_t hi_base, hi_size;          /* the upper-half memory registered to it (upper) */
    uint32_t image_base, image_size;    /* the program as loaded: its file's bytes (upper) */
    uint32_t heap_base;                 /* the first byte after the image and its bss (upper) */
    uint32_t app_path;                  /* the program's pathname, a GS/OS class-1 string */
    uint32_t video;                     /* the enhanced video control bank, 0 = not the owner */
};
#define RV_ENV_MAGIC 0x4E455652u        /* 'R','V','E','N' */
#define RV_ENV_VIDEO 0x0001u

extern struct rv_env *rv_env;

static inline __attribute__((noreturn)) void rvgs_exit(int code) {
    register long a0 __asm__("a0") = code;
    register long a7 __asm__("a7") = 93;
    __asm__ volatile("ecall" : : "r"(a0), "r"(a7) : "memory");
    __builtin_unreachable();
}

#endif
