/* png.c - a PNG decoder for RISC-V programs (png.h; docs/RVV2_INTEROP.md, rung I5).
   The inflate is Mark Adler's puff (zlib's contrib/puff: the reference decoder,
   one bit at a time through canonical Huffman codes) - chosen to be simple and
   right first; its speed is measured on the engine, the baseline to beat. */
#include "png.h"

/* ---- CRC-32 and Adler-32 ------------------------------------------------------- */
static uint32_t crc_table[256];
static int crc_ready;

static void crc_init(void) {
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[n] = c;
    }
    crc_ready = 1;
}

static uint32_t crc32(const uint8_t *p, uint32_t n) {
    uint32_t c = 0xFFFFFFFFu;
    while (n--) c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return ~c;
}

static uint32_t adler32(const uint8_t *p, uint32_t n) {
    uint32_t a = 1, b = 0;
    while (n) {
        uint32_t k = n < 5552 ? n : 5552;        /* the most before b can overflow */
        n -= k;
        while (k--) { a += *p++; b += a; }
        a %= 65521; b %= 65521;
    }
    return (b << 16) | a;
}

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

/* ---- inflate (puff) ------------------------------------------------------------ */
struct state {
    const uint8_t *in;
    uint32_t inlen, incnt;
    uint32_t bitbuf;
    int bitcnt;
    uint8_t *out;
    uint32_t outlen, outcnt;
    int starved;                                /* the input ran out */
};

/* `need` bits, first bit the least significant; bitcnt is left at 0-7. */
static int bits(struct state *s, int need) {
    uint32_t val = s->bitbuf;
    while (s->bitcnt < need) {
        if (s->incnt == s->inlen) { s->starved = 1; return 0; }
        val |= (uint32_t)s->in[s->incnt++] << s->bitcnt;
        s->bitcnt += 8;
    }
    s->bitbuf = val >> need;
    s->bitcnt -= need;
    return (int)(val & ((1u << need) - 1));
}

static int stored(struct state *s) {
    s->bitbuf = 0;
    s->bitcnt = 0;
    if (s->incnt + 4 > s->inlen) return 2;
    uint32_t len = s->in[s->incnt] | (s->in[s->incnt + 1] << 8);
    if (s->in[s->incnt + 2] != (~len & 0xFF) || s->in[s->incnt + 3] != ((~len >> 8) & 0xFF)) return -2;
    s->incnt += 4;
    if (s->incnt + len > s->inlen) return 2;
    if (s->outcnt + len > s->outlen) return 1;
    while (len--) s->out[s->outcnt++] = s->in[s->incnt++];
    return 0;
}

#define MAXBITS 15
struct huffman { uint16_t *count, *symbol; };

/* A symbol: the code's bits one at a time, each length's first code and count
   telling whether it has ended (puff's fast form: the bits taken straight from
   the buffer and the input). */
static int decode(struct state *s, const struct huffman *h) {
    int code = 0, first = 0, index = 0, len = 1, left;
    uint32_t bitbuf = s->bitbuf;
    const uint16_t *next = h->count + 1;
    left = s->bitcnt;
    for (;;) {
        while (left--) {
            code |= bitbuf & 1;
            bitbuf >>= 1;
            const int count = *next++;
            if (code - count < first) {
                s->bitbuf = bitbuf;
                s->bitcnt = (s->bitcnt - len) & 7;
                return h->symbol[index + (code - first)];
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
            len++;
        }
        left = (MAXBITS + 1) - len;
        if (left == 0) break;
        if (s->incnt == s->inlen) { s->starved = 1; return -9; }
        bitbuf = s->in[s->incnt++];
        if (left > 8) left = 8;
    }
    return -10;                                 /* ran past the longest code */
}

/* Canonical codes from lengths; < 0 over-subscribed, > 0 incomplete. */
static int construct(struct huffman *h, const uint16_t *length, int n) {
    uint16_t offs[MAXBITS + 1];
    for (int len = 0; len <= MAXBITS; len++) h->count[len] = 0;
    for (int sym = 0; sym < n; sym++) h->count[length[sym]]++;
    if (h->count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= MAXBITS; len++) {
        left <<= 1;
        left -= h->count[len];
        if (left < 0) return left;
    }
    offs[1] = 0;
    for (int len = 1; len < MAXBITS; len++) offs[len + 1] = offs[len] + h->count[len];
    for (int sym = 0; sym < n; sym++) if (length[sym] != 0) h->symbol[offs[length[sym]]++] = (uint16_t)sym;
    return left;
}

static const uint16_t lbase[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                   35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const uint16_t lext[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const uint16_t dbase[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                   257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
static const uint16_t dext[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

static int codes(struct state *s, const struct huffman *lencode, const struct huffman *distcode) {
    int symbol;
    do {
        symbol = decode(s, lencode);
        if (symbol < 0) return symbol;
        if (symbol < 256) {
            if (s->outcnt == s->outlen) return 1;
            s->out[s->outcnt++] = (uint8_t)symbol;
        } else if (symbol > 256) {
            symbol -= 257;
            if (symbol >= 29) return -10;
            uint32_t len = lbase[symbol] + bits(s, lext[symbol]);
            symbol = decode(s, distcode);
            if (symbol < 0) return symbol;
            if (symbol >= 30) return -10;
            const uint32_t dist = dbase[symbol] + bits(s, dext[symbol]);
            if (s->starved) return -9;
            if (dist > s->outcnt) return -11;
            if (s->outcnt + len > s->outlen) return 1;
            uint8_t *o = s->out + s->outcnt;
            const uint8_t *from = o - dist;
            s->outcnt += len;
            while (len--) *o++ = *from++;
        }
    } while (symbol != 256);
    return 0;
}

static uint16_t fixed_lcnt[MAXBITS + 1], fixed_lsym[288], fixed_dcnt[MAXBITS + 1], fixed_dsym[30];
static int fixed_ready;

static int fixed(struct state *s) {
    struct huffman lencode = {fixed_lcnt, fixed_lsym}, distcode = {fixed_dcnt, fixed_dsym};
    if (!fixed_ready) {
        uint16_t lengths[288];
        int sym = 0;
        for (; sym < 144; sym++) lengths[sym] = 8;
        for (; sym < 256; sym++) lengths[sym] = 9;
        for (; sym < 280; sym++) lengths[sym] = 7;
        for (; sym < 288; sym++) lengths[sym] = 8;
        construct(&lencode, lengths, 288);
        for (sym = 0; sym < 30; sym++) lengths[sym] = 5;
        construct(&distcode, lengths, 30);
        fixed_ready = 1;
    }
    return codes(s, &lencode, &distcode);
}

static int dynamic(struct state *s) {
    static const uint8_t order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
    uint16_t lengths[320], lencnt[MAXBITS + 1], lensym[288], distcnt[MAXBITS + 1], distsym[30];
    struct huffman lencode = {lencnt, lensym}, distcode = {distcnt, distsym};
    const int nlen = bits(s, 5) + 257, ndist = bits(s, 5) + 1, ncode = bits(s, 4) + 4;
    if (nlen > 286 || ndist > 30) return -3;
    int index;
    for (index = 0; index < ncode; index++) lengths[order[index]] = (uint16_t)bits(s, 3);
    for (; index < 19; index++) lengths[order[index]] = 0;
    if (construct(&lencode, lengths, 19) != 0) return -4;
    index = 0;
    while (index < nlen + ndist) {
        int symbol = decode(s, &lencode);
        if (symbol < 0) return symbol;
        if (symbol < 16) lengths[index++] = (uint16_t)symbol;
        else {
            int len = 0, rep;
            if (symbol == 16) {
                if (index == 0) return -5;
                len = lengths[index - 1];
                rep = 3 + bits(s, 2);
            } else if (symbol == 17) rep = 3 + bits(s, 3);
            else rep = 11 + bits(s, 7);
            if (index + rep > nlen + ndist) return -6;
            while (rep--) lengths[index++] = (uint16_t)len;
        }
    }
    if (lengths[256] == 0) return -9;
    int err = construct(&lencode, lengths, nlen);
    if (err && (err < 0 || nlen != lencode.count[0] + lencode.count[1])) return -7;
    err = construct(&distcode, lengths + nlen, ndist);
    if (err && (err < 0 || ndist != distcode.count[0] + distcode.count[1])) return -8;
    return codes(s, &lencode, &distcode);
}

/* A raw deflate stream: 0, or puff's error codes. */
static int inflate(struct state *s) {
    int last, err;
    do {
        last = bits(s, 1);
        const int type = bits(s, 2);
        if (s->starved) return 2;
        err = type == 0 ? stored(s) : type == 1 ? fixed(s) : type == 2 ? dynamic(s) : -1;
        if (s->starved) return 2;
        if (err != 0) break;
    } while (!last);
    return err;
}

/* ---- PNG ----------------------------------------------------------------------- */
static int paeth(int a, int b, int c) {
    const int p = a + b - c;
    int pa = p - a, pb = p - b, pc = p - c;
    if (pa < 0) pa = -pa;
    if (pb < 0) pb = -pb;
    if (pc < 0) pc = -pc;
    if (pa <= pb && pa <= pc) return a;
    return pb <= pc ? b : c;
}

int png_decode(const uint8_t *f, uint32_t n, uint8_t *work, uint32_t work_n, struct png *out) {
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    if (!crc_ready) crc_init();
    if (n < 8) return PNG_E_SIGNATURE;
    for (int i = 0; i < 8; i++) if (f[i] != sig[i]) return PNG_E_SIGNATURE;
    uint32_t pos = 8, idat = 0;
    int have_header = 0;
    out->palette_n = 0;
    for (;;) {
        if (pos + 12 > n) return PNG_E_CHUNK;
        const uint32_t len = be32(f + pos);
        const uint8_t *type = f + pos + 4, *data = f + pos + 8;
        if (len > n - pos - 12) return PNG_E_CHUNK;
        if (crc32(type, len + 4) != be32(data + len)) return PNG_E_CRC;
        const uint32_t t = be32(type);
        if (t == 0x49484452u) {                                     /* IHDR */
            if (len != 13) return PNG_E_HEADER;
            out->width = be32(data);
            out->height = be32(data + 4);
            out->color = data[9];
            if (data[8] != 8 || data[10] != 0 || data[11] != 0 || data[12] != 0) return PNG_E_HEADER;
            if (out->color == 0 || out->color == 3) out->bpp = 1;
            else if (out->color == 2) out->bpp = 3;
            else if (out->color == 6) out->bpp = 4;
            else return PNG_E_HEADER;
            if (out->width == 0 || out->height == 0 || out->width > 16384 || out->height > 16384) return PNG_E_HEADER;
            out->stride = out->width * out->bpp;
            have_header = 1;
        } else if (t == 0x504C5445u) {                              /* PLTE */
            if (len % 3 || len > 768) return PNG_E_PALETTE;
            for (uint32_t i = 0; i < len; i++) out->palette[i] = data[i];
            out->palette_n = len / 3;
        } else if (t == 0x49444154u) {                              /* IDAT: gathered */
            if (idat + len > work_n) return PNG_E_MEMORY;
            for (uint32_t i = 0; i < len; i++) work[idat + i] = data[i];
            idat += len;
        } else if (t == 0x49454E44u) break;                         /* IEND */
        pos += 12 + len;
    }
    if (!have_header) return PNG_E_HEADER;
    if (out->color == 3 && out->palette_n == 0) return PNG_E_PALETTE;
    out->idat_bytes = idat;
    /* the zlib stream: its header, deflate, its Adler-32 */
    if (idat < 6) return PNG_E_ZLIB;
    const unsigned cmf = work[0], flg = work[1];
    if ((cmf & 15) != 8 || (cmf >> 4) > 7 || ((cmf << 8) | flg) % 31 || (flg & 0x20)) return PNG_E_ZLIB;
    const uint32_t raw_at = (idat + 15) & ~15u;
    const uint32_t raw_n = out->height * (1 + out->stride);
    if (raw_at > work_n || raw_n > work_n - raw_at) return PNG_E_MEMORY;
    uint8_t *raw = work + raw_at;
    struct state s = {work + 2, idat - 2, 0, 0, 0, raw, raw_n, 0, 0};
    if (inflate(&s) != 0) return PNG_E_INFLATE;
    if (s.outcnt != raw_n) return PNG_E_SIZE;
    if (s.incnt + 4 > s.inlen || be32(s.in + s.incnt) != adler32(raw, raw_n)) return PNG_E_ZLIB;
    /* unfilter, each row moved down over its filter byte (the rows end contiguous) */
    const unsigned bpp = out->bpp;
    const uint32_t stride = out->stride;
    for (uint32_t y = 0; y < out->height; y++) {
        const uint8_t *src = raw + y * (1 + stride);
        uint8_t *row = raw + y * stride;
        const uint8_t *prior = y ? row - stride : 0;
        const unsigned filter = src[0];
        src++;
        switch (filter) {
        case 0: for (uint32_t i = 0; i < stride; i++) row[i] = src[i]; break;
        case 1:
            for (uint32_t i = 0; i < stride; i++) row[i] = (uint8_t)(src[i] + (i >= bpp ? row[i - bpp] : 0));
            break;
        case 2:
            for (uint32_t i = 0; i < stride; i++) row[i] = (uint8_t)(src[i] + (prior ? prior[i] : 0));
            break;
        case 3:
            for (uint32_t i = 0; i < stride; i++) {
                const unsigned a = i >= bpp ? row[i - bpp] : 0, b = prior ? prior[i] : 0;
                row[i] = (uint8_t)(src[i] + ((a + b) >> 1));
            }
            break;
        case 4:
            for (uint32_t i = 0; i < stride; i++) {
                const int a = i >= bpp ? row[i - bpp] : 0, b = prior ? prior[i] : 0;
                const int c = (prior && i >= bpp) ? prior[i - bpp] : 0;
                row[i] = (uint8_t)(src[i] + paeth(a, b, c));
            }
            break;
        default: return PNG_E_FILTER;
        }
    }
    out->rows = raw;
    return PNG_OK;
}

void png_row_rgb565(const struct png *p, uint32_t y, uint16_t *dst) {
    const uint8_t *s = p->rows + y * p->stride;
    for (uint32_t x = 0; x < p->width; x++) {
        unsigned r, g, b;
        switch (p->color) {
        case 0: r = g = b = s[x]; break;
        case 3: {
            const unsigned i = s[x] < p->palette_n ? s[x] : 0;
            r = p->palette[3 * i]; g = p->palette[3 * i + 1]; b = p->palette[3 * i + 2];
            break;
        }
        case 2: r = s[3 * x]; g = s[3 * x + 1]; b = s[3 * x + 2]; break;
        default: r = s[4 * x]; g = s[4 * x + 1]; b = s[4 * x + 2]; break;
        }
        dst[x] = (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
    }
}
