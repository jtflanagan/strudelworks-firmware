/* doom_rv.c - doomgeneric's platform on the RISC-V engine (docs/RVV2_DOOM.md):
   the frame through the palette to RGB565 in enhanced video's mode 1, time from
   the Event Manager's ticks, the WAD beside the program (9:DOOM1.WAD), keys
   from the ADB itself.  Its report ($EE:FE00): 'DOOM', frames drawn, the ticks at
   the first frame, the ticks now. */
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
    volatile uint8_t *ctl = (volatile uint8_t *)(uintptr_t)rv_env->video;
    ctl[0x10] = 0;                      /* COMMIT mode slot 0: this frame */
    if (frames++ == 0) {
        video_on();
        report[2] = rvgs_ticks();
    }
    report[1] = frames;
    report[3] = rvgs_ticks();
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
