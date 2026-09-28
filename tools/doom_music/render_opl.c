/* SPDX-License-Identifier: GPL-2.0-or-later
   SPDX-FileCopyrightText: 2026 jtflanagan
   render_opl - DOOM's music on the PC through the port's own OPL path
   (tools/doom_music, docs/RVV2_DOOM.md MU3): Chocolate Doom 2.2.1's player
   (i_oplmusic.c, midifile.c, opl.c, opl_queue.c), the engine's driver
   (apple/rvvm/doom/opl_rv.c) and its DBOPL (dbopl_rv.c), at OPL_RATE (the
   build's -DOPL_RATE); writes the OPL's 16-bit mono samples - opl_rv_fill's
   output, before snd_rv.c's gain - to a raw file.  A song from the WAD, or a
   MIDI file (the table builder's one-note captures).  Built by
   tools/doom_music/instruments.py.

     [DMUS_MUTE=0|1] render_opl WAD LUMP|FILE.mid SECONDS OUT.raw [MUSVOL LOOP]
       MUSVOL: the player's volume, 64 = DOOM's default (snd_MusicVolume 8 * 8)
       LOOP: 1 (default) loops the song */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "doomtype.h"
#include "i_sound.h"

void opl_rv_fill(int16_t *out, unsigned n);

static uint8_t *wad; static int32_t nlumps, dirofs;
static int find(const char *name) {
    for (int i = 0; i < nlumps; i++) {
        const uint8_t *d = wad + dirofs + 16 * i;
        if (!strncasecmp((const char *)d + 8, name, 8)) return i;
    }
    return -1;
}
static void *lump(int i, int *len) {
    const uint8_t *d = wad + dirofs + 16 * i;
    int32_t pos, sz; memcpy(&pos, d, 4); memcpy(&sz, d + 4, 4);
    if (len) *len = sz;
    return wad + pos;
}
/* what i_oplmusic.c and friends ask of DOOM */
void *W_CacheLumpName(char *name, int tag) { (void)tag; int i = find(name); if (i < 0) { fprintf(stderr, "no %s\n", name); exit(1); } return lump(i, NULL); }
void W_ReleaseLumpName(char *name) { (void)name; }
void *Z_Malloc(int size, int tag, void *user) { (void)tag; (void)user; return malloc(size); }
void Z_Free(void *p) { free(p); }
char *M_TempFile(char *s) { char b[512]; snprintf(b, sizeof b, "%s/%s", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", s); return strdup(b); }
boolean M_WriteFile(char *name, void *source, int length) { FILE *f = fopen(name, "wb"); if (!f) return false; fwrite(source, 1, length, f); fclose(f); return true; }
char *DEH_String(char *s) { return s; }
int M_snprintf(char *buf, size_t n, char *s, ...) { (void)s; if (n) buf[0] = 0; return 0; }
boolean M_StringConcat(char *d, char *s, size_t n) { strncat(d, s, n - strlen(d) - 1); return true; }
int snd_samplerate = OPL_RATE;
int snd_musicdevice = SNDDEVICE_SB;

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "render WAD LUMP|FILE.mid SECONDS OUT.raw [MUSVOL LOOP]\n"); return 2; }
    int musvol = argc > 5 ? atoi(argv[5]) : 64, loop = argc > 6 ? atoi(argv[6]) : 1;
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    wad = malloc(n); fread(wad, 1, n, f); fclose(f);
    memcpy(&nlumps, wad + 4, 4); memcpy(&dirofs, wad + 8, 4);
    /* DMUS_MUTE=V: voice V (0 or 1) of every GENMIDI instrument never sounds -
       its operators' attack rates zeroed - so a double-voice instrument's other
       voice is captured alone, as DMX plays it (its detune and note offset
       its own) */
    if (getenv("DMUS_MUTE")) {
        const int v = atoi(getenv("DMUS_MUTE")) & 1, g = find("GENMIDI");
        if (g >= 0) {
            uint8_t *gm = lump(g, NULL);
            for (int i = 0; i < 175; i++) {
                uint8_t *voice = gm + 8 + 36 * i + 4 + 16 * v;
                voice[1] &= 0x0F;                       /* the modulator's attack rate (0x60's high nibble) */
                voice[7 + 1] &= 0x0F;                   /* the carrier's */
            }
        }
    }
    if (!music_opl_module.Init()) { fprintf(stderr, "init failed\n"); return 1; }
    music_opl_module.SetMusicVolume(musvol);           /* 64 = S_SetMusicVolume(snd_MusicVolume 8 * 8) */
    int len; void *data;
    if (strstr(argv[2], ".mid")) {                       /* a MIDI file: the player takes MIDI as it is */
        FILE *m = fopen(argv[2], "rb"); fseek(m, 0, SEEK_END); len = ftell(m); rewind(m);
        data = malloc(len); fread(data, 1, len, m); fclose(m);
    } else {
        int li = find(argv[2]); if (li < 0) { fprintf(stderr, "no %s\n", argv[2]); return 1; }
        data = lump(li, &len);
    }
    void *h = music_opl_module.RegisterSong(data, len);
    music_opl_module.PlaySong(h, loop);
    FILE *o = fopen(argv[4], "wb");
    long total = (long)(atof(argv[3]) * OPL_RATE), done = 0; int16_t buf[256]; int peak = 0;
    while (done < total) {
        opl_rv_fill(buf, 256);
        for (int i = 0; i < 256; i++) { int a = abs(buf[i]); if (a > peak) peak = a; }
        fwrite(buf, 2, 256, o); done += 256;
    }
    fclose(o);
    if (getenv("QUIET")) return 0;
    fprintf(stderr, "%s %s @%d Hz: %ld samples, peak %d\n", argv[1], argv[2], OPL_RATE, done, peak);
    return 0;
}
