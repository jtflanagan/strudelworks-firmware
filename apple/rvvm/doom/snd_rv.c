/* snd_rv.c - DOOM's sound effects on the IIgs's Ensoniq (docs/RVV2_DOOM.md,
   rungs S1-S3): doomgeneric's sound module (i_sound.h), a mixer on the engine.
   The effects are the WAD's DS lumps - 8-bit unsigned, $80 the middle, 11025
   Hz, 16 bytes of padding at each end - played as they are: the DOC's rate is
   11026.8 Hz (librvgs, RVGS_SND_RATE), too close to step.  Eight channels mix
   into 256-sample chunks, left and right by DOOM's separation (SDL's rule: 0 is
   the left), never $00 (that stops a DOC voice); the runtime's interrupt
   copies each into the DOC.  Mixed as the ring has room, SND_AHEAD chunks
   ahead of the DOC, from DOOM's per-tic Update and from its sleeps
   (snd_pump, doom_rv.c) - paced by the DOC's own clock.  Music: none yet. */
#include <stdint.h>
#include <stdio.h>
#include "doomtype.h"
#include "i_sound.h"
#include "w_wad.h"
#include "z_zone.h"
#include "rvgs.h"

#define NCH       8
#define SND_AHEAD 3                             /* chunks mixed ahead of the DOC */

struct chan {
    const uint8_t *data;                        /* the samples; NULL = free */
    uint32_t len;                               /* in samples */
    uint32_t pos, step;                         /* 16.16 */
    int vl, vr;                                 /* 0-127 */
};
static struct chan ch[NCH];
static boolean on, use_prefix;

/* The variables i_sound.c binds to the config file (SDL's, unused here). */
int use_libsamplerate = 0;
float libsamplerate_scale = 0.65f;
void I_InitTimidityConfig(void) {}

static void mix_chunk(void) {
    static uint8_t l[RVGS_SND_CHUNK] __attribute__((aligned(4))), r[RVGS_SND_CHUNK] __attribute__((aligned(4)));
    for (unsigned i = 0; i < RVGS_SND_CHUNK; i++) {
        int sl = 0, sr = 0;
        for (unsigned c = 0; c < NCH; c++) {
            struct chan *h = &ch[c];
            if (!h->data) continue;
            const int s = (int)h->data[h->pos >> 16] - 128;
            sl += s * h->vl;
            sr += s * h->vr;
            h->pos += h->step;
            if ((h->pos >> 16) >= h->len) h->data = NULL;
        }
        sl >>= 7; sr >>= 7;
        if (sl < -127) sl = -127; else if (sl > 127) sl = 127;
        if (sr < -127) sr = -127; else if (sr > 127) sr = 127;
        l[i] = (uint8_t)(sl + 128);
        r[i] = (uint8_t)(sr + 128);
    }
    rvgs_snd_put(l, r);
}

void snd_pump(void) {
    if (!on) return;
    while (RVGS_SND_RING - rvgs_snd_room() < SND_AHEAD) mix_chunk();
}

static void set_vol(struct chan *h, int vol, int sep) {
    int l = (254 - sep) * vol / 127, r = sep * vol / 127;
    h->vl = l > 127 ? 127 : l;
    h->vr = r > 127 ? 127 : r;
}

static boolean snd_init(boolean use_sfx_prefix) {
    use_prefix = use_sfx_prefix;
    for (unsigned c = 0; c < NCH; c++) ch[c].data = NULL;
    on = rvgs_snd_on() == 0;
    return on;
}

static void snd_shutdown(void) {
    if (on) rvgs_snd_off();
    on = false;
}

static int snd_lump(sfxinfo_t *sfx) {
    char name[9];
    if (sfx->link) sfx = sfx->link;
    snprintf(name, sizeof name, use_prefix ? "ds%s" : "%s", sfx->name);
    return W_CheckNumForName(name);             /* -1: not in this WAD - played as nothing */
}

static void snd_update(void) { snd_pump(); }

static void snd_params(int handle, int vol, int sep) {
    if (handle >= 0 && handle < NCH) set_vol(&ch[handle], vol, sep);
}

static int snd_start(sfxinfo_t *sfx, int channel, int vol, int sep) {
    if (channel < 0 || channel >= NCH || sfx->lumpnum < 0) return -1;
    struct chan *h = &ch[channel];
    h->data = NULL;
    const uint8_t *d = W_CacheLumpNum(sfx->lumpnum, PU_STATIC);
    const uint32_t lumplen = W_LumpLength(sfx->lumpnum);
    if (lumplen < 8 || d[0] != 3 || d[1] != 0) return -1;
    const uint32_t rate = d[2] | d[3] << 8, n = d[4] | d[5] << 8 | (uint32_t)d[6] << 16 | (uint32_t)d[7] << 24;
    if (n > lumplen - 8 || n <= 48 || rate == 0) return -1;
    set_vol(h, vol, sep);
    h->len = n - 32;                            /* DMX's padding, 16 at each end */
    h->pos = 0;
    h->step = (uint32_t)(((uint64_t)rate << 16) / RVGS_SND_RATE);
    h->data = d + 8 + 16;
    return channel;
}

static void snd_stop(int handle) {
    if (handle >= 0 && handle < NCH) ch[handle].data = NULL;
}

static boolean snd_playing(int handle) {
    return handle >= 0 && handle < NCH && ch[handle].data != NULL;
}

static snddevice_t devices[] = { SNDDEVICE_SB };

sound_module_t DG_sound_module = {
    devices, sizeof devices / sizeof devices[0],
    snd_init, snd_shutdown, snd_lump, snd_update, snd_params,
    snd_start, snd_stop, snd_playing, NULL,
};

/* Music: none yet (docs/RVV2_DOOM.md) - a module that plays nothing. */
static boolean mus_init(void) { return true; }
static void mus_void(void) {}
static void mus_volume(int v) { (void)v; }
static void *mus_register(void *data, int len) { (void)data; (void)len; return NULL; }
static void mus_unregister(void *h) { (void)h; }
static void mus_play(void *h, boolean loop) { (void)h; (void)loop; }
static boolean mus_playing(void) { return false; }

music_module_t DG_music_module = {
    NULL, 0,
    mus_init, mus_void, mus_volume, mus_void, mus_void,
    mus_register, mus_unregister, mus_play, mus_void, mus_playing, NULL,
};
