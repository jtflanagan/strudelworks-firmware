/* librvgs (docs/RVV2_INTEROP.md): a GS/OS application's RISC-V side - the IIgs
   through call65816, files through the bounce buffer, keys through the Event
   Manager.  Everything the 65816 reads or writes for it lives in the low block's
   call area (rv_env->call):
     +0    the descriptor (32 bytes)     +32   the push image (up to 224)
     +256  the results (up to 64)        +320  parameter blocks and strings (rvgs_scratch) */
#include "rvgs.h"

#define CALL_DESC   0
#define CALL_PUSH   32
#define CALL_PUSHN  224
#define CALL_PULL   256
#define CALL_PULLN  64
#define CALL_SCR    320

void *memcpy(void *d, const void *s, unsigned long n) {
    uint8_t *dp = d; const uint8_t *sp = s;
    if ((((uintptr_t)dp | (uintptr_t)sp | n) & 3) == 0) {
        for (; n; n -= 4, dp += 4, sp += 4) *(uint32_t *)dp = *(const uint32_t *)sp;
        return d;
    }
    while (n--) *dp++ = *sp++;
    return d;
}
void *memset(void *d, int c, unsigned long n) {
    uint8_t *dp = d;
    while (n--) *dp++ = (uint8_t)c;
    return d;
}

static uint8_t *call_area(void) { return (uint8_t *)(uintptr_t)rv_env->call; }

void *rvgs_scratch(unsigned *size) {
    if (size) *size = rv_env->call_size > CALL_SCR ? rv_env->call_size - CALL_SCR : 0;
    return call_area() + CALL_SCR;
}

long rvgs_call(struct rvgs_call *d) {
    register long a0 __asm__("a0") = (long)(uintptr_t)d;
    register long a7 __asm__("a7") = 0x5010;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a7)
                     : "memory", "a1", "a2", "a3", "a4", "a5", "a6", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "ra");
    return a0;
}

static unsigned call(uint32_t target, unsigned x, const void *params, unsigned plen, void *result, unsigned rlen) {
    uint8_t *ca = call_area();
    struct rvgs_call *d = (struct rvgs_call *)(ca + CALL_DESC);
    if (plen + rlen > CALL_PUSHN || rlen > CALL_PULLN) return 0xFFFF;
    memcpy(ca + CALL_PUSH, params, plen);
    memset(ca + CALL_PUSH + plen, 0, rlen);
    d->target = target;
    d->a = 0; d->x = (uint16_t)x; d->y = 0;
    d->push_len = (uint16_t)(plen + rlen);
    d->push = (uint32_t)(uintptr_t)(ca + CALL_PUSH);
    d->pull_len = (uint16_t)rlen; d->reserved = 0;
    d->pull = (uint32_t)(uintptr_t)(ca + CALL_PULL);
    if (rvgs_call(d) != 0) return 0xFFFF;
    if (rlen) memcpy(result, ca + CALL_PULL, rlen);
    return (d->p_out & 1) ? d->a_out : 0;
}

unsigned rvgs_tool(unsigned num, const void *params, unsigned plen, void *result, unsigned rlen) {
    return call(0xE10000, num, params, plen, result, rlen);
}

unsigned rvgs_gsos(unsigned num, void *pblock) {
    const uint32_t pb = (uint32_t)(uintptr_t)pblock;
    const uint8_t p[6] = {(uint8_t)num, (uint8_t)(num >> 8), (uint8_t)pb, (uint8_t)(pb >> 8), (uint8_t)(pb >> 16), 0};
    return call(0xE100B0, 0, p, 6, 0, 0);
}

/* ---- files ------------------------------------------------------------------------ */
/* The parameter blocks, at the start of the scratch area: one of each is enough,
   calls do not overlap. */
struct pb_open  { uint16_t pcount, ref; uint32_t path; uint16_t access; } __attribute__((packed));
struct pb_eof   { uint16_t pcount, ref; uint32_t eof; } __attribute__((packed));
struct pb_read  { uint16_t pcount, ref; uint32_t buf, request, transfer; } __attribute__((packed));
struct pb_close { uint16_t pcount, ref; } __attribute__((packed));
#define PB_AT   0
#define PATH_AT 64                     /* a class-1 string: a length word, then the name */
#define PATH_MAX_LEN 190

int rvgs_open(const char *path) {
    uint8_t *s = rvgs_scratch(0);
    unsigned n = 0;
    while (path[n] && n < PATH_MAX_LEN) { s[PATH_AT + 2 + n] = (uint8_t)path[n]; n++; }
    s[PATH_AT] = (uint8_t)n; s[PATH_AT + 1] = 0;
    volatile struct pb_open *p = (volatile struct pb_open *)(s + PB_AT);
    p->pcount = 3; p->ref = 0; p->path = (uint32_t)(uintptr_t)(s + PATH_AT); p->access = 1;
    const unsigned err = rvgs_gsos(0x2010, (void *)p);
    return err ? -(int)err : p->ref;
}

long rvgs_eof(int ref) {
    volatile struct pb_eof *p = (volatile struct pb_eof *)((uint8_t *)rvgs_scratch(0) + PB_AT);
    p->pcount = 2; p->ref = (uint16_t)ref; p->eof = 0;
    const unsigned err = rvgs_gsos(0x2019, (void *)p);
    return err ? -(long)err : (long)p->eof;
}

long rvgs_read(int ref, void *buf, unsigned long n) {
    volatile struct pb_read *p = (volatile struct pb_read *)((uint8_t *)rvgs_scratch(0) + PB_AT);
    const uint8_t *bounce = (const uint8_t *)(uintptr_t)rv_env->bounce;
    unsigned long done = 0;
    while (done < n) {
        unsigned long chunk = n - done;
        if (chunk > rv_env->bounce_size) chunk = rv_env->bounce_size;
        p->pcount = 4; p->ref = (uint16_t)ref;
        p->buf = rv_env->bounce; p->request = chunk; p->transfer = 0;
        const unsigned err = rvgs_gsos(0x2012, (void *)p);
        const unsigned long got = p->transfer;
        if (err && err != 0x4C) return -(long)err;     /* $4C: the end of the file */
        memcpy((uint8_t *)buf + done, bounce, got);
        done += got;
        if (got < chunk) break;
    }
    return (long)done;
}

int rvgs_close(int ref) {
    volatile struct pb_close *p = (volatile struct pb_close *)((uint8_t *)rvgs_scratch(0) + PB_AT);
    p->pcount = 1; p->ref = (uint16_t)ref;
    const unsigned err = rvgs_gsos(0x2014, (void *)p);
    return err ? -(int)err : 0;
}

struct pb_mark { uint16_t pcount, ref, base; uint32_t disp; } __attribute__((packed));
struct pb_getmark { uint16_t pcount, ref; uint32_t pos; } __attribute__((packed));

long rvgs_seek(int ref, unsigned long pos) {
    volatile struct pb_mark *p = (volatile struct pb_mark *)((uint8_t *)rvgs_scratch(0) + PB_AT);
    p->pcount = 3; p->ref = (uint16_t)ref; p->base = 0; p->disp = pos;   /* base 0: from the start */
    const unsigned err = rvgs_gsos(0x2016, (void *)p);
    return err ? -(long)err : 0;
}

long rvgs_tell(int ref) {
    volatile struct pb_getmark *p = (volatile struct pb_getmark *)((uint8_t *)rvgs_scratch(0) + PB_AT);
    p->pcount = 2; p->ref = (uint16_t)ref; p->pos = 0;
    const unsigned err = rvgs_gsos(0x2017, (void *)p);
    return err ? -(long)err : (long)p->pos;
}

/* ---- events ----------------------------------------------------------------------- */
/* GetNextEvent $0A06 (read off the machine's Event Manager: the event record's
   long address pushed last, the mask before it, a word result pushed first;
   6 bytes taken off).  keyDown = 3, autoKey = 5. */
struct event { uint16_t what; uint32_t message, when; uint16_t y, x, modifiers; } __attribute__((packed));
#define EV_AT 272                      /* after the pathname (PATH_AT + 2 + PATH_MAX_LEN) */

int rvgs_key(void) {
    volatile struct event *e = (volatile struct event *)((uint8_t *)rvgs_scratch(0) + EV_AT);
    const uint32_t ep = (uint32_t)(uintptr_t)e;
    const uint16_t mask = (1u << 3) | (1u << 5);
    const uint8_t params[6] = {(uint8_t)ep, (uint8_t)(ep >> 8), (uint8_t)(ep >> 16), 0, (uint8_t)mask, (uint8_t)(mask >> 8)};
    for (;;) {
        uint16_t got = 0;
        if (rvgs_tool(0x0A06, params, 6, &got, 2) != 0) return -1;
        if (got && (e->what == 3 || e->what == 5)) return (int)(e->message & 0xFF);
    }
}

uint32_t rvgs_ticks(void) {
    uint32_t t = 0;
    rvgs_tool(0x1006, 0, 0, &t, 4);             /* no parameters, a long result */
    return t;
}

/* ---- raw ADB keys --------------------------------------------------------------- */
/* The ring (apple/rvvm/rvengine.s KEY_*): in our RAM bank $EE, which the engine
   reads and writes itself; the completion (65816, interrupt time) writes the
   head and clears the request, the program the tail and the request. */
#define KEY_HEAD ((volatile uint16_t *)(uintptr_t)0x00EE0300u)
#define KEY_TAIL ((volatile uint16_t *)(uintptr_t)0x00EE0302u)
#define KEY_ASK  ((volatile uint16_t *)(uintptr_t)0x00EE0304u)
#define KEY_RING ((volatile uint8_t *)(uintptr_t)0x00EE0400u)
/* ours beside it, for the host's mirror: asks, refusals, the last refusal, and
   requests given up on (the runtime's own counters are $306-$30B) */
#define KEY_ASKS ((volatile uint16_t *)(uintptr_t)0x00EE030Cu)
#define KEY_REFS ((volatile uint16_t *)(uintptr_t)0x00EE030Eu)
#define KEY_RERR ((volatile uint16_t *)(uintptr_t)0x00EE0310u)
#define KEY_GONE ((volatile uint16_t *)(uintptr_t)0x00EE0312u)

int rvgs_adb_event(void) {
    static unsigned waited;                     /* polls since the request went out */
    if (*KEY_ASK != 0 && ++waited > 64) {      /* never answered: ask again */
        *KEY_ASK = 0;
        ++*KEY_GONE;
    }
    if (*KEY_TAIL == *KEY_HEAD && *KEY_ASK == 0) {
        waited = 0;
        /* AsyncADBReceive(completion, command): the command pushed last, so first
           on the stack; the completion's long address after it (its top byte 0) */
        static const uint8_t params[6] = {0xC2, 0x00, 0x40, 0x00, 0xF1, 0x00};
        *KEY_ASK = 1;
        ++*KEY_ASKS;
        const int err = rvgs_tool(0x0D09, params, 6, 0, 0);
        if (err != 0) {                         /* busy: ask again next time */
            *KEY_ASK = 0;
            ++*KEY_REFS;
            *KEY_RERR = (uint16_t)err;
        }
    }
    const uint16_t tail = *KEY_TAIL;
    if (tail == *KEY_HEAD) return -1;
    const int ev = KEY_RING[tail & 0xFF];
    *KEY_TAIL = (uint16_t)((tail + 1) & 0xFF);
    return ev;
}
