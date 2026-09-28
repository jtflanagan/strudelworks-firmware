/* SPDX-License-Identifier: GPL-2.0-or-later
   SPDX-FileCopyrightText: 2026 jtflanagan
   mus_rv.c - DOOM's music on the RISC-V engine the DOC's way (docs/RVV2_DOOM.md,
   rung MU3): sampled instruments mixed into one stream, in place of an OPL.
   doomgeneric's music module.  The instruments are DOOMMUS.INS, beside the WAD
   (9:DOOMMUS.INS): every OPL voice DMX plays, captured from DOOM's own GENMIDI
   patches through the port's OPL path when the program is built
   (tools/doom_music/instruments.py; the layout in tools/doom_music/dmus.py).
   This is tools/doom_music/preview.py in integers, and must stay so:

   - the MUS read as it plays, a tic (140 Hz) at a time; the song loops;
   - DMX's nine OPL voices allocated as Chocolate Doom's player does
     (i_oplmusic.c, opl_v_new): a free list taken from its head and given back
     at its tail; a double-voice instrument's second voice only if one is free;
     when none is, ReplaceExistingVoice's victim - a second voice, else the
     last on the highest MIDI channel (mus2mid's order: first use, 9 skipped);
     a released voice sounds on - its volume and bend as they were - until it
     is taken again;
   - DMX's volume law: the carrier level 0x3f - full_volume, 0.75 dB a step;
   - each voice its entry (the note's own, else the nearest) read with linear
     interpolation - the attack, then the loop in phase - at the note's pitch
     and the channel's bend, its amplitude ramped every sample between the
     tics' envelope points;
   - summed at RVGS_SND_CRATE (26320 Hz: 188 samples a tic, exactly).

   mus_rv_fill hands the mixer (snd_rv.c) the sum for its centre stream. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include "doomtype.h"
#include "i_sound.h"
#include "w_wad.h"
#include "z_zone.h"
#include "rvgs.h"

#define RATE      RVGS_SND_CRATE
#define TIC_HZ    140
#define PER_TIC   (RATE / TIC_HZ)                 /* 188 */
#define NVOICES   9                               /* an OPL2's, as DMX has them */
#ifndef INS_FILE
#define INS_FILE  "9:DOOMMUS.INS"                 /* beside the WAD (the PC's harness names its own) */
#endif

/* ---- DOOMMUS.INS (tools/doom_music/dmus.py) ------------------------------------------ */
typedef struct {
    uint8_t  ins, ref, voice, flags;              /* flags: 1 fixed pitch, 2 one-shot */
    uint32_t f0, arate;                           /* 16.16: Hz, bytes a second, at ref */
    uint32_t a_ofs, a_size, l_ofs, l_size, e_ofs;
    uint16_t n_hold, n_rel, a_amp, decay;         /* decay: 0.16 a tic */
    uint8_t  reach, pad[7];
} ins_entry_t;
_Static_assert(sizeof(ins_entry_t) == 48, "DOOMMUS.INS entry");

static uint8_t *ins;                              /* the file */
static const ins_entry_t *ents;
static unsigned n_ents;
static int16_t first_of[175 * 2 + 1];             /* ents index of each (ins, voice)'s first; -1 none */

static const int8_t *tab(uint32_t ofs) { return (const int8_t *)(ins + ofs); }
static const uint16_t *env(const ins_entry_t *e) { return (const uint16_t *)(ins + e->e_ofs); }

static int load_ins(void) {
    const int fd = open(INS_FILE, O_RDONLY);
    if (fd < 0) return 0;
    uint8_t hdr[32];
    if (read(fd, hdr, 32) != 32 || memcmp(hdr, "DMUS", 4) || (hdr[4] | hdr[5] << 8) != 2) { close(fd); return 0; }
    const uint32_t size = hdr[12] | hdr[13] << 8 | (uint32_t)hdr[14] << 16 | (uint32_t)hdr[15] << 24;
    ins = malloc(size);
    if (!ins) { close(fd); return 0; }
    memcpy(ins, hdr, 32);
    for (uint32_t at = 32; at < size; ) {
        const long r = read(fd, ins + at, size - at);
        if (r <= 0) { close(fd); free(ins); ins = NULL; return 0; }
        at += (uint32_t)r;
    }
    close(fd);
    n_ents = ins[8] | ins[9] << 8;
    ents = (const ins_entry_t *)(ins + 32);
    for (unsigned i = 0; i < sizeof first_of / sizeof first_of[0]; i++) first_of[i] = -1;
    for (unsigned i = n_ents; i-- > 0; ) first_of[ents[i].ins * 2 + ents[i].voice] = (int16_t)i;   /* sorted: (ins, voice, ref) */
    return 1;
}

/* The (ins, voice)'s entry at the note, else the nearest (a tie: the higher, moved down). */
static const ins_entry_t *entry_for(unsigned in, unsigned voice, int note) {
    int i = first_of[in * 2 + voice];
    if (i < 0) return NULL;
    const ins_entry_t *best = &ents[i];
    for (; i < (int)n_ents && ents[i].ins == in && ents[i].voice == voice; i++) {
        const int d = abs((int)ents[i].ref - note), bd = abs((int)best->ref - note);
        if (d < bd || (d == bd && ents[i].ref > best->ref)) best = &ents[i];
    }
    return best;
}

static uint16_t gm_flags[175];                    /* GENMIDI's, for the double voices */

/* ---- the volume law and the pitch ------------------------------------------------------ */
static const uint8_t vmt[128] = {                 /* i_oplmusic.c's volume_mapping_table */
    0, 1, 3, 5, 6, 8, 10, 11, 13, 14, 16, 17, 19, 20, 22, 23, 25, 26, 27, 29, 30, 32, 33, 34, 36, 37, 39, 41, 43, 45, 47, 49,
    50, 52, 54, 55, 57, 59, 60, 61, 63, 64, 66, 67, 68, 69, 71, 72, 73, 74, 75, 76, 77, 79, 80, 81, 82, 83, 84, 84, 85, 86, 87, 88,
    89, 90, 91, 92, 92, 93, 94, 95, 96, 96, 97, 98, 99, 99, 100, 101, 101, 102, 103, 103, 104, 105, 105, 106, 107, 107, 108, 109, 109, 110, 110, 111,
    112, 112, 113, 113, 114, 114, 115, 115, 116, 117, 117, 118, 118, 119, 119, 120, 120, 121, 121, 122, 122, 123, 123, 123, 124, 124, 125, 125, 126, 126, 127, 127};
static uint32_t gain_q16[64];                     /* full_volume -> the amplitude against the capture's (63) */
static uint32_t semi32_q16[384];                  /* 2^(i/384): a 1/32 semitone at a time */
static int musvol = 64;

static uint32_t gain(int vel, int chvol) {
    const unsigned mv = 2 * (vmt[(chvol * musvol) / 127] + 1);
    return gain_q16[(vmt[vel] * mv) >> 9];
}

/* 2^(d/384) in 16.16, d in 1/32 semitones */
static uint32_t ratio_q16(int d) {
    int oct = d >= 0 ? d / 384 : -((-d + 383) / 384);
    const uint32_t r = semi32_q16[d - oct * 384];
    return oct >= 0 ? r << oct : r >> -oct;
}

/* ---- the song ---------------------------------------------------------------------------- */
typedef struct {
    const ins_entry_t *e;
    int ch, key, vel, voice;                      /* ch: MUS's */
    int held, sounding, in_loop;
    uint32_t tics;                                /* tics since the note-on (held) or the note-off */
    uint32_t pos;                                 /* 16.16 bytes into the attack, or the loop */
    uint32_t sa, sl;                              /* 16.16 bytes a sample: the attack's, the loop's */
    uint32_t frozen_gain, frozen_hold;            /* at the note-off */
    int frozen_bend;
    uint32_t tail;                                /* the hold past n_hold: its last value x decay^k */
    int32_t amp_a, amp_l, da, dl;                 /* 16.16 amplitudes and their steps a sample */
} voice_t;

static voice_t voices[NVOICES];
static voice_t *free_list[NVOICES], *alloc_list[NVOICES];
static int n_free, n_alloc;

static const uint8_t *score, *score_end, *at;
static uint32_t wait_tics;
static int playing, paused, looping;
static int prog[16], chvol[16], bend[16], last_vel[16];
static int8_t midich[16];                         /* mus2mid's channel order: the priority */
static unsigned tic_left;                         /* samples before the next tic */
uint32_t mus_rv_notes, mus_rv_peak;               /* for DOOM's report (doom_rv.c) */

static void retune(voice_t *v) {
    const ins_entry_t *e = v->e;
    if (e->flags & 2) { v->sa = (uint32_t)(((uint64_t)e->arate) / RATE); return; }
    const int b = v->held ? bend[v->ch] : v->frozen_bend;
    const uint32_t r = (e->flags & 1) ? 0x10000 : ratio_q16((v->key - e->ref) * 32 + b);
    v->sa = (uint32_t)(((uint64_t)e->arate * r / RATE) >> 16);
    v->sl = (uint32_t)(((uint64_t)e->f0 * e->l_size * r / RATE) >> 16);
}

/* The hold at the voice's tic (held: from the note-on), stepping the tail as it goes. */
static uint32_t hold_at(voice_t *v, uint32_t i) {
    const ins_entry_t *e = v->e;
    if (i < e->n_hold) { v->tail = env(e)[i]; return v->tail; }
    if (i > 0) v->tail = (uint32_t)(((uint64_t)v->tail * e->decay) >> 16);
    return v->tail;
}

/* The voice's amplitudes (16.16 of the file's u16 scale x the gain) at tic offset k (0 now, 1 next). */
static void level(voice_t *v, int k, int32_t *a, int32_t *l) {
    const ins_entry_t *e = v->e;
    uint32_t g, h, rel = 0x10000;
    if (v->held) {
        g = gain(v->vel, chvol[v->ch]);
        h = (e->flags & 2) ? 0 : (k == 0 ? v->tail : (v->tics + 1 < e->n_hold ? env(e)[v->tics + 1]
                                                       : (uint32_t)(((uint64_t)v->tail * e->decay) >> 16)));
    } else {
        g = v->frozen_gain; h = v->frozen_hold;
        const uint32_t i = v->tics + k;
        rel = i < e->n_rel ? env(e)[e->n_hold + i] : 0;
    }
    *a = (int32_t)(((uint64_t)e->a_amp * g >> 16) * rel >> 16);
    *l = (int32_t)(((uint64_t)h * g >> 16) * rel >> 16);
}

static void key_off(voice_t *v) {                 /* VoiceKeyOff + ReleaseVoice */
    v->frozen_gain = gain(v->vel, chvol[v->ch]);
    v->frozen_hold = v->tail;
    v->frozen_bend = bend[v->ch];
    v->held = 0; v->tics = 0;
    for (int i = 0; i < n_alloc; i++)
        if (alloc_list[i] == v) { memmove(&alloc_list[i], &alloc_list[i + 1], (n_alloc - i - 1) * sizeof *alloc_list); n_alloc--; break; }
    free_list[n_free++] = v;
}

static void voice_key_on(int ch, unsigned in, int voice, int key, int vel) {
    if (!n_free) return;
    const ins_entry_t *e = entry_for(in, voice, key);
    if (!e) return;
    voice_t *v = free_list[0];
    memmove(&free_list[0], &free_list[1], (--n_free) * sizeof *free_list);
    alloc_list[n_alloc++] = v;
    v->e = e; v->ch = ch; v->key = key; v->vel = vel; v->voice = voice;
    v->held = 1; v->sounding = 1; v->in_loop = 0; v->tics = 0; v->pos = 0;
    v->tail = (e->flags & 2) ? 0 : env(e)[0];
    retune(v);
    mus_rv_notes++;
}

static void key_on(int ch, int key, int vel) {
    unsigned in;
    if (ch == 15) {
        if (key < 35 || key > 81) return;
        in = 128 + key - 35;
    } else in = prog[ch];
    if (!n_free) {                                /* ReplaceExistingVoice */
        voice_t *r = alloc_list[0];
        for (int i = 0; i < n_alloc; i++)
            if (alloc_list[i]->voice != 0 || midich[alloc_list[i]->ch] >= midich[r->ch]) r = alloc_list[i];
        key_off(r);
    }
    voice_key_on(ch, in, 0, key, vel);
    if (gm_flags[in] & 4) voice_key_on(ch, in, 1, key, vel);
}

static void all_off(int ch) {
    for (int i = 0; i < n_alloc; )
        if (ch < 0 || alloc_list[i]->ch == ch) key_off(alloc_list[i]); else i++;
}

/* One tic of the score: the events due, then the wait to the next. */
static void tic(void) {
    while (playing && wait_tics == 0) {
        if (at >= score_end) { playing = 0; break; }
        const uint8_t d = *at++;
        const int ch = d & 15;
        switch ((d >> 4) & 7) {
        case 0: {                                 /* release */
            const int key = *at++ & 127;
            for (int i = 0; i < n_alloc; )
                if (alloc_list[i]->ch == ch && alloc_list[i]->key == key) key_off(alloc_list[i]); else i++;
            break; }
        case 1: {                                 /* play */
            const int n = *at++;
            if (n & 0x80) last_vel[ch] = *at++ & 127;
            if (last_vel[ch]) key_on(ch, n & 127, last_vel[ch]);
            else for (int i = 0; i < n_alloc; )
                if (alloc_list[i]->ch == ch && alloc_list[i]->key == (n & 127)) key_off(alloc_list[i]); else i++;
            break; }
        case 2:                                   /* pitch bend: MSB - 64, 1/32 semitones */
            bend[ch] = (*at++ >> 1) - 64;
            for (int i = 0; i < n_alloc; i++) if (alloc_list[i]->ch == ch) retune(alloc_list[i]);
            break;
        case 3:                                   /* system: 11 all notes off (10 ignored, as DMX) */
            if (*at++ == 11) all_off(ch);
            break;
        case 4: {                                 /* controller */
            const int c = at[0], val = at[1]; at += 2;
            if (c == 0) prog[ch] = val & 127;
            else if (c == 3) chvol[ch] = val & 127;
            break; }
        case 5: break;                            /* end of measure */
        case 6:                                   /* the end */
            if (looping) { at = score; continue; }
            playing = 0; return;
        default: playing = 0; return;
        }
        if (d & 0x80) {
            uint32_t t = 0; uint8_t c;
            do { c = *at++; t = t * 128 + (c & 127); } while (c & 0x80);
            wait_tics = t;
        }
    }
    if (wait_tics) wait_tics--;
}

/* The tic's amplitude ramps, and the envelope's clock. */
static void ramps(void) {
    for (int i = 0; i < NVOICES; i++) {
        voice_t *v = &voices[i];
        if (!v->sounding) continue;
        int32_t a0, l0, a1, l1;
        level(v, 0, &a0, &l0);
        level(v, 1, &a1, &l1);
        if (!v->held && a0 == 0 && l0 == 0) { v->sounding = 0; continue; }
        v->amp_a = a0 << 8; v->da = ((a1 - a0) << 8) / PER_TIC;       /* 16.8 */
        v->amp_l = l0 << 8; v->dl = ((l1 - l0) << 8) / PER_TIC;
    }
}

static void advance_envelopes(void) {
    for (int i = 0; i < NVOICES; i++) {
        voice_t *v = &voices[i];
        if (!v->sounding) continue;
        v->tics++;
        if (v->held && !(v->e->flags & 2)) hold_at(v, v->tics);
    }
}

/* ---- the mix ------------------------------------------------------------------------------- */
static void mix_voice(voice_t *v, int32_t *out, unsigned n) {
    const ins_entry_t *e = v->e;
    const int8_t *a = tab(e->a_ofs);
    const uint32_t a_end = (e->a_size - 1) << 16;
    unsigned k = 0;
    if (!v->in_loop) {
        for (; k < n && v->pos < a_end; k++) {
            const uint32_t i = v->pos >> 16, f = (v->pos >> 8) & 0xFF;
            const int32_t s = a[i] * 256 + (a[i + 1] - a[i]) * (int32_t)f;           /* 8.8 */
            out[k] += (s * (v->amp_a >> 10)) >> 12;
            v->amp_a += v->da; v->amp_l += v->dl;
            v->pos += v->sa;
        }
        if (k == n) return;
        if (e->flags & 2) { for (; k < n; k++) { v->amp_a += v->da; v->amp_l += v->dl; } return; }   /* a one-shot, done */
        v->pos = (uint32_t)(((uint64_t)(v->pos - a_end) * v->sl) / (v->sa ? v->sa : 1));      /* the loop, in phase */
        v->in_loop = 1;
    }
    const int8_t *l = tab(e->l_ofs);
    const uint32_t mask = (e->l_size << 16) - 1, lm = e->l_size - 1;
    for (; k < n; k++) {
        v->pos &= mask;
        const uint32_t i = v->pos >> 16, f = (v->pos >> 8) & 0xFF;
        const int32_t s = l[i] * 256 + (l[(i + 1) & lm] - l[i]) * (int32_t)f;
        out[k] += (s * (v->amp_l >> 10)) >> 12;
        v->amp_a += v->da; v->amp_l += v->dl;
        v->pos += v->sl;
    }
}

/* n samples of the music at RATE into out (the sum: 8.8 samples x 16-bit amplitudes >> 14).  */
void mus_rv_fill(int32_t *out, unsigned n) {
    memset(out, 0, n * sizeof *out);
    if (!ins || !playing || paused) return;
    while (n) {
        if (tic_left == 0) { tic(); ramps(); tic_left = PER_TIC; }
        const unsigned k = n < tic_left ? n : tic_left;
        for (int i = 0; i < NVOICES; i++) if (voices[i].sounding) mix_voice(&voices[i], out, k);
        out += k; n -= k; tic_left -= k;
        if (tic_left == 0) advance_envelopes();
    }
}

/* ---- the module -------------------------------------------------------------------------- */
static void reset_voices(void) {
    n_free = n_alloc = 0;
    for (int i = 0; i < NVOICES; i++) { voices[i].sounding = voices[i].held = 0; free_list[n_free++] = &voices[i]; }
}

static boolean mus_init(void) {
    if (!ins && !load_ins()) return false;
    for (int f = 0; f < 64; f++) gain_q16[f] = (uint32_t)(65536.0 * pow(10.0, -0.75 * (63 - f) / 20.0) + 0.5);
    for (int i = 0; i < 384; i++) semi32_q16[i] = (uint32_t)(65536.0 * pow(2.0, i / 384.0) + 0.5);
    /* GENMIDI's flags: which instruments are double-voice */
    const uint8_t *gm = W_CacheLumpName("GENMIDI", PU_STATIC);
    for (int i = 0; i < 175; i++) gm_flags[i] = gm[8 + 36 * i] | gm[9 + 36 * i] << 8;
    reset_voices();
    return true;
}

static void mus_shutdown(void) { playing = 0; reset_voices(); }
static void mus_volume(int v) { musvol = v < 0 ? 0 : v > 127 ? 127 : v; }
static void mus_pause(void) { paused = 1; }
static void mus_resume(void) { paused = 0; }

static void *mus_register(void *data, int len) {
    const uint8_t *m = data;
    if (len < 16 || memcmp(m, "MUS\x1a", 4)) return NULL;
    return data;
}
static void mus_unregister(void *h) { (void)h; }

static void mus_play(void *h, boolean loop) {
    const uint8_t *m = h;
    if (!m || !ins) return;
    const unsigned len = m[4] | m[5] << 8, start = m[6] | m[7] << 8;
    score = m + start; score_end = score + len; at = score;
    reset_voices();
    for (int c = 0; c < 16; c++) { prog[c] = 0; chvol[c] = 127; bend[c] = 0; last_vel[c] = 127; midich[c] = -1; }
    /* mus2mid's channel order: 15 is 9, the rest by first use, 9 skipped */
    int next = 0;
    midich[15] = 9;
    for (const uint8_t *p = score; p < score_end; ) {
        const uint8_t d = *p++;
        const int ch = d & 15, type = (d >> 4) & 7;
        if (midich[ch] < 0) { midich[ch] = (int8_t)next++; if (next == 9) next++; }
        if (type == 6) break;
        p += type == 1 ? ((*p & 0x80) ? 2 : 1) : type == 4 ? 2 : (type == 5 ? 0 : 1);
        if (d & 0x80) while (*p++ & 0x80) {}
    }
    wait_tics = 0; tic_left = 0; looping = loop; paused = 0; playing = 1;
}

static void mus_stop(void) { all_off(-1); playing = 0; }
static boolean mus_playing(void) { return playing; }

static snddevice_t devices[] = { SNDDEVICE_SB, SNDDEVICE_ADLIB, SNDDEVICE_GENMIDI };

music_module_t DG_music_module = {
    devices, sizeof devices / sizeof devices[0],
    mus_init, mus_shutdown, mus_volume, mus_pause, mus_resume,
    mus_register, mus_unregister, mus_play, mus_stop, mus_playing, NULL,
};
