/* RVTEST's program: the interop's own test application (docs/RVV2_INTEROP.md,
   rungs I3-I4), beside SPLASH on the demo disk and in sim/run_rv_app.sh.  Loaded
   into the upper 16 MB by the runtime's loader, it checks what it was given,
   reads a file and waits for a key; it exits $100 | the key's character, or the
   number of the first check that failed (under $100):
     1 the environment block's magic, version and size   2 a user ID
     3 the upper half: hi_base above 16 MB, whole banks, inside the 32 MB
     4 the image at hi_base, this code inside it, its size the file's
     5 the heap after the image and its bss, the stack at the top: sp inside
     6 the low block below 16 MB, out of banks $00/$01/$E0/$E1, the bounce buffer
       and the call area inside it
     7 memory: the heap and the stack keep a pattern across whole banks
     8 the low block: a word written to the call area reads back
     9 the program's pathname: a class-1 string naming RVTEST.RV
    10 the relocations: a pointer in data points into this image
    11 a 24 KB table - three of the loader's chunks - every word as built
   Rung I4 (librvgs: call65816, GS/OS through the bounce buffer, the Event Manager):
    20 a missing file: Open says fileNotFound ($46)
    21 9:RVTEST.DAT opens               22 its size is 40000
    23 read into the upper half: 40000 bytes, every one as resources.sh made it
    24 read again at its end: 0         25 it closes
    26 the key: GetNextEvent gave a character
   Rung D3 (raw ADB keys, presses and releases):
    27 A down and up, then Esc down and up ($00 $80 $35 $B5) did not come within
       10 seconds (other events may come between: the key above, say) */
#include "rvgs.h"

static const char *const self_name = "RVTEST.RV";

/* 6144 words, each its index times a golden-ratio constant: a file that takes
   the loader several chunks through the same bounce buffer */
#define V(i)     ((uint32_t)(i) * 2654435761u)
#define R4(i)    V(i), V((i) + 1), V((i) + 2), V((i) + 3)
#define R16(i)   R4(i), R4((i) + 4), R4((i) + 8), R4((i) + 12)
#define R64(i)   R16(i), R16((i) + 16), R16((i) + 32), R16((i) + 48)
#define R256(i)  R64(i), R64((i) + 64), R64((i) + 128), R64((i) + 192)
#define R1024(i) R256(i), R256((i) + 256), R256((i) + 512), R256((i) + 768)
#define TABLE_N  6144
static const uint32_t table[TABLE_N] = {R1024(0), R1024(1024), R1024(2048), R1024(3072), R1024(4096), R1024(5120)};

static int check(void) {
    const struct rv_env *e = rv_env;
    if (e->magic != RV_ENV_MAGIC || e->version != 1 || e->size != 64) return 1;
    if (e->user_id == 0) return 2;
    if (e->hi_base < 0x01000000u || (e->hi_base & 0xFFFF) || (e->hi_size & 0xFFFF) || e->hi_size == 0 ||
        e->hi_base + e->hi_size > 0x02000000u) return 3;
    const uint32_t here = (uint32_t)(uintptr_t)&check;
    if (e->image_base != e->hi_base || here < e->image_base || here >= e->image_base + e->image_size) return 4;
    uint32_t sp;
    __asm__ volatile("mv %0, sp" : "=r"(sp));
    if (e->heap_base <= e->image_base + e->image_size - 1 || e->heap_base >= e->hi_base + e->hi_size ||
        sp <= e->heap_base || sp > e->hi_base + e->hi_size) return 5;
    const uint32_t lb = e->low_base >> 16;
    if (e->low_base >= 0x01000000u || lb < 2 || lb == 0xE0 || lb == 0xE1 ||
        e->bounce < e->low_base || e->bounce + e->bounce_size > e->low_base + e->low_size ||
        e->call < e->bounce + e->bounce_size || e->call + e->call_size > e->low_base + e->low_size) return 6;
    /* the heap: 160 KB across bank boundaries, written then read back */
    volatile uint32_t *h = (volatile uint32_t *)(uintptr_t)((e->heap_base + 15) & ~15u);
    const uint32_t n = 160 * 1024 / 4;
    if ((uint32_t)(uintptr_t)(h + n) > sp - 4096) return 7;
    for (uint32_t i = 0; i < n; i++) h[i] = i * 2654435761u ^ 0xA5A5A5A5u;
    for (uint32_t i = 0; i < n; i++) if (h[i] != (i * 2654435761u ^ 0xA5A5A5A5u)) return 7;
    volatile uint32_t stack_words[256];
    for (uint32_t i = 0; i < 256; i++) stack_words[i] = ~i;
    for (uint32_t i = 0; i < 256; i++) if (stack_words[i] != ~i) return 7;
    volatile uint32_t *c = (volatile uint32_t *)(uintptr_t)e->call;
    c[0] = 0x5A3C96E1u;
    if (c[0] != 0x5A3C96E1u) return 8;
    c[0] = 0;
    /* the pathname (below 16 MB: the engine reads it directly, it is RAM) */
    const volatile uint8_t *p = (const volatile uint8_t *)(uintptr_t)e->app_path;
    const unsigned len = p[0] | (p[1] << 8);
    if (e->app_path == 0 || len < 9) return 9;
    for (unsigned i = 0; i < 9; i++) if (p[2 + len - 9 + i] != (uint8_t)self_name[i]) return 9;
    if ((uint32_t)(uintptr_t)self_name < e->image_base || (uint32_t)(uintptr_t)self_name >= e->heap_base) return 10;
    for (uint32_t i = 0; i < TABLE_N; i++) if (((const volatile uint32_t *)table)[i] != V(i)) return 11;
    return 0;
}

#define DAT_SIZE 40000

static int files(void) {
    if (rvgs_open("9:NOSUCH") != -0x46) return 20;
    const int ref = rvgs_open("9:RVTEST.DAT");
    if (ref <= 0) return 21;
    if (rvgs_eof(ref) != DAT_SIZE) return 22;
    uint8_t *buf = (uint8_t *)(uintptr_t)((rv_env->heap_base + 15) & ~15u);   /* the upper half */
    if (rvgs_read(ref, buf, DAT_SIZE + 100) != DAT_SIZE) return 23;
    for (uint32_t i = 0; i < DAT_SIZE; i++) if (buf[i] != (uint8_t)(7 * i + (i >> 8))) return 23;
    if (rvgs_read(ref, buf, 16) != 0) return 24;
    if (rvgs_close(ref) != 0) return 25;
    return 0;
}

static int adb(void) {
    static const uint8_t want[4] = {0x00, 0x80, 0x35, 0xB5};
    unsigned got = 0;
    const uint32_t t0 = rvgs_ticks();
    while (got < 4 && rvgs_ticks() - t0 < 600) {
        const int ev = rvgs_adb_event();
        if (ev >= 0 && ev == want[got]) got++;
    }
    return got == 4 ? 0 : 27;
}

int main(void) {
    int r = check();
    if (r) return r;
    if ((r = files()) != 0) return r;
    const int key = rvgs_key();
    if (key < 0) return 26;
    if ((r = adb()) != 0) return r;
    return 0x100 | key;
}
