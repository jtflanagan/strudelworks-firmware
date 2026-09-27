/* rvvm's C tests (sim/run_rvvm_tests.sh): the PNG decoder (apple/rvvm/guest/png.c)
   on synthetic PNGs (tools/png_testdata.py -> png_data.h): stored, fixed and
   dynamic deflate blocks, all five row filters, colour types 0/2/3/6, image
   data split over many IDAT chunks, and a bad CRC refused.  Each decoded
   image's RGB565 pixels must hash (FNV-1a) as the generator says.
   Exit 0 = pass, else 10 * case + what failed (1 error, 2 size, 3 pixels).
   rvvm-hi: no I/O, so it also runs in the upper 16 MB. */
#include "../png.c"
#include "png_data.h"

static uint8_t work[20000];
static uint16_t row[64];

int main(void) {
    for (unsigned k = 0; k < sizeof png_cases / sizeof png_cases[0]; k++) {
        const struct png_case *c = &png_cases[k];
        struct png p;
        const int err = png_decode(c->data, c->n, work, sizeof work, &p);
        if (err != c->err) return 10 * (int)k + 1;
        if (err) continue;
        if (p.width != c->w || p.height != c->h) return 10 * (int)k + 2;
        uint32_t h = 0x811C9DC5u;
        for (uint32_t y = 0; y < p.height; y++) {
            png_row_rgb565(&p, y, row);
            for (uint32_t x = 0; x < p.width; x++) {
                h = (h ^ (row[x] & 0xFF)) * 0x01000193u;
                h = (h ^ (row[x] >> 8)) * 0x01000193u;
            }
        }
        if (h != c->fnv) return 10 * (int)k + 3;
    }
    return 0;
}
