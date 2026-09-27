/* rvgs.h - a GS/OS application's RISC-V side (docs/RVV2_INTEROP.md): the
   environment block the runtime hands its program (crt0_app.S keeps it in
   rv_env).  Every address is a 24-bit IIgs address unless it says upper.
   The start of librvgs. */
#ifndef RVGS_H
#define RVGS_H
#include <stdint.h>

struct rv_env {
    uint32_t magic;                     /* 'RVEN' */
    uint16_t version, size;             /* 1, 64 */
    uint16_t user_id;                   /* the application's GS/OS user ID */
    uint16_t flags;                     /* RV_ENV_VIDEO: it owns enhanced video */
    uint32_t low_base, low_size;        /* the low block: this block, then the runtime's */
    uint32_t bounce, bounce_size;       /* the I/O bounce buffer */
    uint32_t call, call_size;           /* the call area */
    uint32_t hi_base, hi_size;          /* the upper-half memory registered to it (upper) */
    uint32_t image_base, image_size;    /* the program as loaded: its file's bytes (upper) */
    uint32_t heap_base;                 /* the first byte after the image and its bss (upper) */
    uint32_t app_path;                  /* the program's pathname, a GS/OS class-1 string */
    uint32_t video;                     /* the enhanced video control bank, 0 = not the owner */
};
#define RV_ENV_MAGIC 0x4E455652u        /* 'R','V','E','N' */
#define RV_ENV_VIDEO 0x0001u

extern struct rv_env *rv_env;

/* call65816 (ECALL $5010): a JSL on the 65816, described in the call area. */
struct rvgs_call {
    uint32_t target;                    /* 24-bit: $E10000 the toolbox, $E100B0 GS/OS */
    uint16_t a, x, y;                   /* registers in */
    uint16_t push_len;
    uint32_t push;                      /* the stack's bytes from its top up: last pushed first */
    uint16_t pull_len, reserved;        /* bytes the call leaves (its results)... */
    uint32_t pull;                      /* ...and where they go */
    uint16_t a_out, x_out, y_out, p_out;   /* registers out; p_out bit 0: carry */
};
long rvgs_call(struct rvgs_call *d);

/* A toolbox call: `params` as they lie on the stack (the last pushed first,
   longs low word first), `result` the result space the caller pushes first.
   Returns the tool's error, 0 for none. */
unsigned rvgs_tool(unsigned num, const void *params, unsigned plen, void *result, unsigned rlen);
/* A class-1 GS/OS call on a parameter block in the call area (rvgs_scratch).
   Returns GS/OS's error, 0 for none. */
unsigned rvgs_gsos(unsigned num, void *pblock);
/* The part of the call area librvgs leaves free, and its size. */
void *rvgs_scratch(unsigned *size);

/* Files, through the bounce buffer.  A path is a C string (prefix 9: = the
   application's folder).  Negative returns are -(GS/OS error). */
int  rvgs_open(const char *path);
long rvgs_eof(int ref);
long rvgs_read(int ref, void *buf, unsigned long n);   /* bytes read; fewer at the end */
int  rvgs_close(int ref);
long rvgs_seek(int ref, unsigned long pos);            /* SetMark from the start; 0 or -(error) */
long rvgs_tell(int ref);                               /* GetMark */

/* The next key-down (or auto-key) from the Event Manager: its character. */
int rvgs_key(void);
/* The keyboard's raw ADB events, presses AND releases (docs/RVV2_DOOM.md, D3):
   {bit 7 released, keycode}, from the Pi's keyboard and the IIe's alike, or -1
   when there is none now.  When the ring the runtime keeps in $EE is empty and
   nothing is outstanding, it asks the ADB Tool Set for the keyboard's register
   0 (AsyncADBReceive $0D09, command $C2), whose answer the runtime's completion
   ($F1:0040) puts in the ring. */
int rvgs_adb_event(void);
#define RVGS_ADB_UP 0x80

/* Sound (docs/RVV2_DOOM.md, S1-S3): the program mixes, the IIgs's Ensoniq
   plays.  Chunks of RVGS_SND_CHUNK samples at RVGS_SND_RATE (11026.8 Hz, the
   DOC's own clock: pace the mixing by rvgs_snd_room, never by a timer), 8-bit
   unsigned - $80 silence, and never $00, which stops the DOC's voice - a left
   and a right.  The runtime owns the voices (two Sound Tool Set generators,
   played directly) and gives them back when the program ends, however it ends;
   the application's tool list must name the Sound Tool Set (tool 8).
   rvgs_snd_on: 0, or the Sound Tool Set's error ($FFFF: not two generators
   free).  rvgs_snd_room: the chunks the ring takes now (0 = full). */
#define RVGS_SND_CHUNK 256
#define RVGS_SND_RATE  11027
#define RVGS_SND_RING  16
unsigned rvgs_snd_on(void);
void     rvgs_snd_off(void);
unsigned rvgs_snd_room(void);
void     rvgs_snd_put(const uint8_t *left, const uint8_t *right);
unsigned rvgs_snd_played(void);   /* chunks the DOC has taken so far */

/* The Event Manager's tick count (TickCount $1006): 60 a second. */
uint32_t rvgs_ticks(void);

/* A program's report for the host: 256 bytes in our RAM bank $EE (the runtime's
   trace is at $EE:FF00), read with a peek - a program's own measurements, say.
   Nothing reads it but a person; nothing clears it. */
#define RVGS_REPORT 0x00EEFE00u

void *memcpy(void *d, const void *s, unsigned long n);
void *memset(void *d, int c, unsigned long n);

static inline __attribute__((noreturn)) void rvgs_exit(int code) {
    register long a0 __asm__("a0") = code;
    register long a7 __asm__("a7") = 93;
    __asm__ volatile("ecall" : : "r"(a0), "r"(a7) : "memory");
    __builtin_unreachable();
}

#endif
