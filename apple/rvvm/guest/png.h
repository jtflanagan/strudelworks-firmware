/* png.h - a PNG decoder for RISC-V programs (docs/RVV2_INTEROP.md, rung I5):
   8-bit greyscale, RGB, palette and RGBA, not interlaced; zlib inflate with its
   Adler-32, every chunk's CRC-32.  Freestanding: the caller gives it memory. */
#ifndef PNG_H
#define PNG_H
#include <stdint.h>

enum {
    PNG_OK = 0,
    PNG_E_SIGNATURE = 1,        /* not a PNG */
    PNG_E_CHUNK = 2,            /* a chunk runs off the file */
    PNG_E_CRC = 3,              /* a chunk's CRC-32 is wrong */
    PNG_E_HEADER = 4,           /* IHDR missing, or a kind this decoder does not take */
    PNG_E_PALETTE = 5,          /* a palette image without a usable PLTE */
    PNG_E_MEMORY = 6,           /* the work memory is too small */
    PNG_E_ZLIB = 7,             /* the zlib header, or its Adler-32 */
    PNG_E_INFLATE = 8,          /* the deflate stream is bad */
    PNG_E_SIZE = 9,             /* the image data is not the size IHDR says */
    PNG_E_FILTER = 10,          /* a row's filter type is not 0-4 */
};

struct png {
    uint32_t width, height;
    unsigned color;             /* 0 grey, 2 RGB, 3 palette, 6 RGBA */
    unsigned bpp;               /* bytes a pixel: 1, 3, 1, 4 */
    uint32_t stride;            /* bytes a row of `rows` (width * bpp) */
    const uint8_t *rows;        /* the pixels, unfiltered, row after row */
    uint8_t palette[256 * 3];
    unsigned palette_n;
    uint32_t idat_bytes;        /* what the image data came to, compressed */
};

/* Decode the PNG in `file` (n bytes).  `work` (work_n bytes) holds the
   compressed data and the pixels: the image data's size plus height * (1 +
   stride) is enough.  Returns PNG_OK or an error above. */
int png_decode(const uint8_t *file, uint32_t n, uint8_t *work, uint32_t work_n, struct png *out);

/* One row as RGB565 (bits 15-11 red, 10-5 green, 4-0 blue), `width` pixels. */
void png_row_rgb565(const struct png *p, uint32_t y, uint16_t *dst);

#endif
