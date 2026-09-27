/* doom_rv.c - doomgeneric's platform on the RISC-V engine (docs/RVV2_DOOM.md):
   the frame through the palette to RGB565 in enhanced video's mode 1, time from
   the Event Manager's ticks, the WAD beside the program (9:DOOM1.WAD), keys
   from the ADB itself.  Its report ($EE:FE00): 'DOOM', frames drawn, the ticks at
   the first frame, the ticks now, and the frames of the last whole second
   (tenths).  That rate is drawn in the picture's top right corner, "RV 35.0" -
   the engine's, DOOM's own ceiling being 35; the host's HUD shows beside it the
   rate the Pi puts on the screen ("PI"). */
#include <stdint.h>
#include "doomgeneric.h"
#include "i_video.h"
#include "rvgs.h"

#define VIDEO_BANK 0x00800000u
#define ROW_BYTES  640

extern boolean palette_changed;

static volatile uint32_t *const report = (volatile uint32_t *)(uintptr_t)RVGS_REPORT;
static uint16_t lut[256];
static uint32_t frames;
static uint32_t rate_tick, rate_frames, rate10;   /* the last whole second's frames, in tenths */
static int rate_known;                             /* drawn from the first whole second on (frame 1 stays DOOM's own) */

/* A 3x5 font, two pixels a dot: the rate's characters only. */
static const uint8_t glyph[][5] = {
    {7,5,5,5,7}, {2,6,2,2,7}, {7,1,7,4,7}, {7,1,7,1,7}, {5,5,7,1,1},   /* 0-4 */
    {7,4,7,1,7}, {7,4,7,5,7}, {7,1,1,1,1}, {7,5,7,5,7}, {7,5,7,1,7},   /* 5-9 */
    {6,5,6,5,5}, {5,5,5,5,2}, {0,0,0,0,2}, {0,0,0,0,0},                /* R V . space */
};
enum { G_R = 10, G_V, G_DOT, G_SP };

static void put_px(uint32_t x, uint32_t y, uint16_t c) {
    volatile uint16_t *row = (volatile uint16_t *)(uintptr_t)(VIDEO_BANK + (y / 100) * 0x10000u + (y % 100) * ROW_BYTES);
    row[x] = c;
}

/* "RV dd.d" on black in the top right corner, over DOOM's own picture. */
static void draw_rate(void) {
    uint8_t text[7] = {G_R, G_V, G_SP, G_SP, G_SP, G_DOT, 0};
    const uint32_t r = rate10 > 999 ? 999 : rate10;
    if (r >= 100) text[3] = (uint8_t)(r / 100);
    text[4] = (uint8_t)(r / 10 % 10);
    text[6] = (uint8_t)(r % 10);
    const uint32_t x0 = 320 - 7 * 8 - 1, y0 = 1;
    for (uint32_t y = y0 - 1; y < y0 + 11; y++)
        for (uint32_t x = x0 - 2; x < 320; x++) put_px(x, y, 0);
    for (uint32_t i = 0; i < 7; i++)
        for (uint32_t gy = 0; gy < 5; gy++)
            for (uint32_t gx = 0; gx < 3; gx++)
                if (glyph[text[i]][gy] & (4 >> gx)) {
                    const uint32_t x = x0 + i * 8 + gx * 2, y = y0 + gy * 2;
                    put_px(x, y, 0xFFFF); put_px(x + 1, y, 0xFFFF);
                    put_px(x, y + 1, 0xFFFF); put_px(x + 1, y + 1, 0xFFFF);
                }
}

void DG_Init(void) {
    for (int i = 0; i < 64; i++) report[i] = 0;
    report[0] = 0x4D4F4F44u;            /* 'D','O','O','M' */
}

static void video_on(void) {
    volatile uint8_t *ctl = (volatile uint8_t *)(uintptr_t)rv_env->video;
    ctl[0x11] = 1;                      /* mode slot 0: bitmap 320x200 RGB565 */
    ctl[0x12] = 0;
    ctl[0x13] = 0x80;
    ctl[0x14] = 2;
    volatile uint32_t *claim = (volatile uint32_t *)(uintptr_t)(rv_env->video + 0x1000);
    for (int i = 0; i < 4000 / 4; i++) claim[i] = 0x55555555u;
    ctl[0] = 1;                         /* ENABLE, latched by the global commit */
    ctl[1] = 0;
}

void DG_DrawFrame(void) {
    if (palette_changed) {
        for (int i = 0; i < 256; i++)
            lut[i] = (uint16_t)(((colors[i].r >> 3) << 11) | ((colors[i].g >> 2) << 5) | (colors[i].b >> 3));
        palette_changed = false;
    }
    const uint8_t *src = (const uint8_t *)DG_ScreenBuffer;
    for (uint32_t y = 0; y < 200; y++, src += 320) {
        volatile uint32_t *dst = (volatile uint32_t *)(uintptr_t)(VIDEO_BANK + (y / 100) * 0x10000u + (y % 100) * ROW_BYTES);
        for (uint32_t x = 0; x < 320; x += 2) dst[x / 2] = lut[src[x]] | ((uint32_t)lut[src[x + 1]] << 16);
    }
    /* the rate: the frames committed over the last whole second (60 ticks or more) */
    const uint32_t now = rvgs_ticks();
    if (frames == 0) { rate_tick = now; rate_frames = 0; }
    else if (now - rate_tick >= 60) {
        rate10 = (frames - rate_frames) * 600 / (now - rate_tick);
        rate_tick = now; rate_frames = frames;
        report[4] = rate10;
        rate_known = 1;
    }
    if (rate_known) draw_rate();
    volatile uint8_t *ctl = (volatile uint8_t *)(uintptr_t)rv_env->video;
    ctl[0x10] = 0;                      /* COMMIT mode slot 0: this frame */
    if (frames++ == 0) {
        video_on();
        report[2] = rvgs_ticks();
    }
    report[1] = frames;
    report[3] = now;
}

void DG_SleepMs(uint32_t ms) {
    const uint32_t end = DG_GetTicksMs() + ms;
    while (DG_GetTicksMs() < end) {}
}

uint32_t DG_GetTicksMs(void) { return rvgs_ticks() * 50 / 3; }    /* 60 ticks a second */

/* Keys: the keyboard's raw ADB events (rvgs_adb_event: presses and releases),
   modifiers and arrows by keycode, the rest by the ADB micro's own plain ASCII
   (adb_ascii.h, generated from rtl/gs/adb_keymap.hex).  Control fires and space
   opens as in DOOM - doomgeneric binds fire and use to keys of its own,
   KEY_FIRE and KEY_USE (m_controls.c), not to right control and space - option
   (or command) strafes, shift runs. */
#include "doomkeys.h"
#include "adb_ascii.h"

static unsigned char doom_key(unsigned code) {
    switch (code) {
    case 0x3B: return KEY_LEFTARROW;
    case 0x3C: return KEY_RIGHTARROW;
    case 0x3D: return KEY_DOWNARROW;
    case 0x3E: return KEY_UPARROW;
    case 0x36: return KEY_FIRE;         /* control */
    case 0x31: return KEY_USE;          /* space */
    case 0x38: return KEY_RSHIFT;       /* shift */
    case 0x3A: case 0x37: return KEY_RALT;   /* option, command */
    case 0x35: return KEY_ESCAPE;
    case 0x24: case 0x4C: return KEY_ENTER;
    case 0x30: return KEY_TAB;
    case 0x33: return KEY_BACKSPACE;
    default: {
        unsigned char c = code < 128 ? adb_ascii[code] : 0;
        if (c >= 'A' && c <= 'Z') c = (unsigned char)(c + 32);
        return c;
    }
    }
}

int DG_GetKey(int *pressed, unsigned char *key) {
    for (;;) {
        const int ev = rvgs_adb_event();
        if (ev < 0) return 0;
        const unsigned char k = doom_key((unsigned)ev & 0x7F);
        if (!k) continue;                       /* a key DOOM has no use for */
        *pressed = !(ev & RVGS_ADB_UP);
        *key = k;
        return 1;
    }
}

void DG_SetWindowTitle(const char *title) { (void)title; }

int main(void) {
    static char *args[] = {"doom", "-iwad", "9:DOOM1.WAD", 0};
    if (!(rv_env->flags & RV_ENV_VIDEO)) return 1;
    doomgeneric_Create(3, args);
    for (;;) doomgeneric_Tick();
}
