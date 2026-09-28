/* SPDX-License-Identifier: GPL-2.0-or-later
   SPDX-FileCopyrightText: 2026 jtflanagan
   render_mus - the engine's music player (apple/rvvm/doom/mus_rv.c) on the PC
   (tools/doom_music, docs/RVV2_DOOM.md MU3): a song from the WAD played from
   DOOMMUS.INS exactly as DOOM plays it on the engine, cut to the centre
   stream's 8 bits as snd_rv.c cuts it (>> 8, clamped to 127), to a WAV at
   26320 Hz - for the ear, and against tools/doom_music/preview.py.

     cc -O2 -Wall -DFEATURE_SOUND -DINS_FILE='"DOOMMUS.INS"' -Itools/doom_music/stub \
        -I../doomgeneric/doomgeneric tools/doom_music/render_mus.c \
        apple/rvvm/doom/mus_rv.c -lm -o render_mus
     render_mus WAD SONG SECONDS OUT.wav [MUSVOL] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "doomtype.h"
#include "i_sound.h"

#define MUS_SHIFT 8                               /* snd_rv.c's */
void mus_rv_fill(int32_t *out, unsigned n);
extern uint32_t mus_rv_notes;

static uint8_t *wad; static int32_t nlumps, dirofs;
static int find(const char *name) {
    for (int i = 0; i < nlumps; i++)
        if (!strncasecmp((const char *)wad + dirofs + 16 * i + 8, name, 8)) return i;
    return -1;
}
static void *lump(int i, int *len) {
    int32_t pos, sz; memcpy(&pos, wad + dirofs + 16 * i, 4); memcpy(&sz, wad + dirofs + 16 * i + 4, 4);
    if (len) *len = sz;
    return wad + pos;
}
void *W_CacheLumpName(char *name, int tag) { (void)tag; int i = find(name); if (i < 0) { fprintf(stderr, "no %s\n", name); exit(1); } return lump(i, NULL); }

static void le16(FILE *f, unsigned v) { fputc(v & 255, f); fputc(v >> 8, f); }
static void le32(FILE *f, uint32_t v) { le16(f, v & 0xFFFF); le16(f, v >> 16); }

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "render_mus WAD SONG SECONDS OUT.wav [MUSVOL]\n"); return 2; }
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    wad = malloc(n); if (fread(wad, 1, n, f) != (size_t)n) return 1; fclose(f);
    memcpy(&nlumps, wad + 4, 4); memcpy(&dirofs, wad + 8, 4);
    if (!DG_music_module.Init()) { fprintf(stderr, "no instruments (DOOMMUS.INS)\n"); return 1; }
    DG_music_module.SetMusicVolume(argc > 5 ? atoi(argv[5]) : 64);
    int li = find(argv[2]), len; if (li < 0) { fprintf(stderr, "no %s\n", argv[2]); return 1; }
    void *song = lump(li, &len);
    void *h = DG_music_module.RegisterSong(song, len);
    DG_music_module.PlaySong(h, true);
    const uint32_t total = (uint32_t)(atof(argv[3]) * 26320) / 512 * 512;
    FILE *o = fopen(argv[4], "wb");
    fwrite("RIFF", 1, 4, o); le32(o, 36 + total * 2); fwrite("WAVEfmt ", 1, 8, o);
    le32(o, 16); le16(o, 1); le16(o, 1); le32(o, 26320); le32(o, 26320 * 2); le16(o, 2); le16(o, 16);
    fwrite("data", 1, 4, o); le32(o, total * 2);
    int32_t buf[512]; int peak = 0; unsigned clipped = 0;
    for (uint32_t done = 0; done < total; done += 512) {
        mus_rv_fill(buf, 512);
        for (int i = 0; i < 512; i++) {
            int s = buf[i] >> MUS_SHIFT;
            if (abs(s) > peak) peak = abs(s);
            if (s > 127) { s = 127; clipped++; } else if (s < -127) { s = -127; clipped++; }
            le16(o, (uint16_t)(int16_t)(s * 256));
        }
    }
    fclose(o);
    printf("%s: %.1f s, %u notes, peak %d of 127, %u clipped\n", argv[2], total / 26320.0, mus_rv_notes, peak, clipped);
    return 0;
}
