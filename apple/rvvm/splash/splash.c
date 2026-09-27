/* SPLASH (docs/RVV2_INTEROP.md, rung I5): DOOM's title screen.  The program,
   in the upper 16 MB, reads TITLEPIC.PNG from its folder through the bounce
   buffer, decodes it (apple/rvvm/guest/png.c), draws it into enhanced video's
   mode 1 - a 320x200 RGB565 bitmap in banks $80-$81 - turns the compositing on,
   waits for a key and exits; the runtime turns enhanced video off.
   Its report ($EE:FE00, rvgs.h), for the host to read:
     +0 'SPLR'  +4 the stage reached (the failing one on an error)  +8 the error
     +12 ticks to read the file  +16 ticks to decode it  +20 ticks to draw it
     +24 the file's bytes  +28 width  +32 height  +36 colour type  +40 the key
     +44 the compressed image data's bytes
   Exit 0, or the stage that failed. */
#include "rvgs.h"
#include "png.h"

#define W 320
#define H 200
#define VIDEO_BANK 0x00800000u          /* rows 0-99 here, 100-199 in the next bank */
#define ROW_BYTES  640

static volatile uint32_t *const report = (volatile uint32_t *)(uintptr_t)RVGS_REPORT;
static uint16_t row[W];
static struct png pic;

static int fail(int stage, int err) {
    report[1] = (uint32_t)stage;
    report[2] = (uint32_t)err;
    return stage;
}

int main(void) {
    for (int i = 0; i < 64; i++) report[i] = 0;
    report[0] = 0x524C5053u;            /* 'S','P','L','R' */
    const struct rv_env *e = rv_env;
    uint8_t *heap = (uint8_t *)(uintptr_t)((e->heap_base + 15) & ~15u);
    const uint32_t heap_n = e->hi_base + e->hi_size - 0x10000 - (uint32_t)(uintptr_t)heap;   /* below the stack */

    /* 1: the file */
    report[1] = 1;
    uint32_t t0 = rvgs_ticks();
    const int ref = rvgs_open("9:TITLEPIC.PNG");
    if (ref < 0) return fail(1, -ref);
    const long n = rvgs_eof(ref);
    if (n <= 0 || (uint32_t)n > heap_n / 4) return fail(1, (int)n);
    if (rvgs_read(ref, heap, (unsigned long)n) != n) return fail(1, 0);
    rvgs_close(ref);
    const uint32_t t1 = rvgs_ticks();
    report[3] = t1 - t0;
    report[6] = (uint32_t)n;

    /* 2: the decode */
    report[1] = 2;
    uint8_t *work = heap + (((uint32_t)n + 15) & ~15u);
    const int err = png_decode(heap, (uint32_t)n, work, heap_n - (uint32_t)(work - heap), &pic);
    const uint32_t t2 = rvgs_ticks();
    report[4] = t2 - t1;
    report[7] = pic.width; report[8] = pic.height; report[9] = pic.color; report[11] = pic.idat_bytes;
    if (err) return fail(2, err);
    if (pic.width != W || pic.height != H) return fail(2, -1);

    /* 3: the picture, into mode 1's banks, two pixels a store */
    report[1] = 3;
    for (uint32_t y = 0; y < H; y++) {
        png_row_rgb565(&pic, y, row);
        volatile uint32_t *dst = (volatile uint32_t *)(uintptr_t)(VIDEO_BANK + (y / 100) * 0x10000u + (y % 100) * ROW_BYTES);
        const uint32_t *src = (const uint32_t *)row;
        for (uint32_t x = 0; x < W / 2; x++) dst[x] = src[x];
    }
    const uint32_t t3 = rvgs_ticks();
    report[5] = t3 - t2;

    /* 4: enhanced video (docs/ENHANCED_VIDEO.md): mode slot 0 a 320x200 bitmap
       on banks $80-$81, committed; every region of the claim map to slot 0;
       the compositing on, latched by the global commit */
    report[1] = 4;
    if (!(e->flags & RV_ENV_VIDEO) || e->video == 0) return fail(4, 0);
    volatile uint8_t *ctl = (volatile uint8_t *)(uintptr_t)e->video;
    ctl[0x11] = 1;                      /* type: bitmap 320x200 RGB565 */
    ctl[0x12] = 0;                      /* flags: no AUTO */
    ctl[0x13] = 0x80;                   /* first bank */
    ctl[0x14] = 2;                      /* banks */
    ctl[0x10] = 0;                      /* COMMIT: the picture as it is now */
    volatile uint32_t *claim = (volatile uint32_t *)(uintptr_t)(e->video + 0x1000);
    for (int i = 0; i < 4000 / 4; i++) claim[i] = 0x55555555u;   /* 01 = slot 0, every region */
    ctl[0] = 1;                         /* ENABLE */
    ctl[1] = 0;                         /* the global commit */

    /* 5: a key */
    report[1] = 5;
    const int key = rvgs_key();
    report[10] = (uint32_t)key;
    report[1] = 6;
    return key < 0 ? 5 : 0;
}
