/* opl_rv.c - an OPL2 for DOOM's music on the RISC-V engine (docs/RVV2_DOOM.md,
   rung MU1): Chocolate Doom's OPL driver (opl/opl_sdl.c, chocolate-doom-2.2.1)
   without SDL.  DOSBox's DBOPL (opl/dbopl.c) at the DOC's rate; the callback
   queue timed in the samples made - the music's clock is the DOC's, as the
   effects' is; the two timers modelled for OPL_Detect.  The mixer (snd_rv.c)
   asks for each chunk's samples (opl_rv_fill); OPL_Delay's wait runs the next
   callback at once (compat/SDL.h) - only OPL_Init's detection waits. */
#include <stdint.h>
#include <stdlib.h>
#include "opl.h"
#include "opl_internal.h"
#include "opl_queue.h"
#include "dbopl.h"
#include "rvgs.h"

typedef struct {
    unsigned int rate;                  /* the timer's tick rate */
    unsigned int value;                 /* the start value */
    int enabled;
    uint64_t expire_time;               /* in us */
} opl_timer_t;

static opl_callback_queue_t *queue;
static uint64_t current_time, pause_offset;
static int paused, live, register_num;
static Chip chip;
static opl_timer_t timer1 = { 12500, 0, 0, 0 }, timer2 = { 3125, 0, 0, 0 };
static int32_t block[RVGS_SND_CHUNK];
/* For DOOM's report (doom_rv.c): the OPL's register writes, and its loudest
   sample since the report last took it. */
uint32_t opl_rv_writes, opl_rv_peak;

static void run_due(void) {
    opl_callback_t cb;
    void *data;
    while (!OPL_Queue_IsEmpty(queue) && current_time >= OPL_Queue_Peek(queue) + pause_offset)
        if (OPL_Queue_Pop(queue, &cb, &data)) cb(data);
}

static void advance(unsigned n) {
    const uint64_t us = ((uint64_t)n * OPL_SECOND) / RVGS_SND_RATE;
    current_time += us;
    if (paused) pause_offset += us;
    run_due();
}

/* The mixer's: n (<= a chunk) samples of the OPL's output, mono, with every
   callback run at its sample. */
void opl_rv_fill(int16_t *out, unsigned n) {
    unsigned filled = 0;
    if (!live) { for (unsigned i = 0; i < n; i++) out[i] = 0; return; }
    while (filled < n) {
        uint64_t k = n - filled;
        if (!paused && !OPL_Queue_IsEmpty(queue)) {
            const uint64_t next = OPL_Queue_Peek(queue) + pause_offset;
            uint64_t until = next > current_time ? ((next - current_time) * RVGS_SND_RATE + OPL_SECOND - 1) / OPL_SECOND : 0;
            if (until < k) k = until;
        }
        if (k) {
            Chip__GenerateBlock2(&chip, (Bitu)k, block);
            for (unsigned i = 0; i < k; i++) {
                const int32_t v = block[i];
                out[filled + i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
                const uint32_t a = (uint32_t)(v < 0 ? -v : v);
                if (a > opl_rv_peak) opl_rv_peak = a;
            }
        }
        filled += (unsigned)k;
        advance((unsigned)k);
    }
}

/* OPL_Delay's wait: to the next callback's time, and run it. */
void opl_rv_wait(void) {
    if (!queue || OPL_Queue_IsEmpty(queue)) return;
    const uint64_t t = OPL_Queue_Peek(queue) + pause_offset;
    if (t > current_time) current_time = t;
    run_due();
}

static int rv_init(unsigned int port_base) {
    (void)port_base;
    paused = 0; pause_offset = 0; current_time = 0;
    queue = OPL_Queue_Create();
    DBOPL_InitTables();
    Chip__Chip(&chip);
    Chip__Setup(&chip, RVGS_SND_RATE);
    live = 1;
    return 1;
}

static void rv_shutdown(void) {
    live = 0;
    if (queue) { OPL_Queue_Destroy(queue); queue = NULL; }
}

static unsigned int rv_read(opl_port_t port) {
    unsigned int r = 0;
    if (port == OPL_REGISTER_PORT_OPL3) return 0xff;     /* an OPL2 */
    if (timer1.enabled && current_time > timer1.expire_time) r |= 0xC0;
    if (timer2.enabled && current_time > timer2.expire_time) r |= 0xA0;
    return r;
}

static void end_time(opl_timer_t *t) {
    if (t->enabled) t->expire_time = current_time + ((uint64_t)(0x100 - t->value) * OPL_SECOND) / t->rate;
}

static void rv_write(opl_port_t port, unsigned int value) {
    if (port == OPL_REGISTER_PORT) { register_num = value; return; }
    if (port == OPL_REGISTER_PORT_OPL3) { register_num = value | 0x100; return; }
    if (port != OPL_DATA_PORT) return;
    opl_rv_writes++;
    switch (register_num) {
    case OPL_REG_TIMER1: timer1.value = value; end_time(&timer1); break;
    case OPL_REG_TIMER2: timer2.value = value; end_time(&timer2); break;
    case OPL_REG_TIMER_CTRL:
        if (value & 0x80) { timer1.enabled = 0; timer2.enabled = 0; break; }
        if (!(value & 0x40)) { timer1.enabled = (value & 0x01) != 0; end_time(&timer1); }
        if (!(value & 0x20)) { timer2.enabled = (value & 0x02) != 0; end_time(&timer2); }
        break;
    default: Chip__WriteReg(&chip, register_num, (Bit8u)value); break;
    }
}

static void rv_set_callback(uint64_t us, opl_callback_t cb, void *data) {
    OPL_Queue_Push(queue, cb, data, current_time - pause_offset + us);
}
static void rv_clear_callbacks(void) { OPL_Queue_Clear(queue); }
static void rv_nothing(void) {}
static void rv_set_paused(int p) { paused = p; }
static void rv_adjust(float factor) { OPL_Queue_AdjustCallbacks(queue, current_time, factor); }

opl_driver_t opl_rv_driver = {
    "RISC-V engine",
    rv_init, rv_shutdown, rv_read, rv_write, rv_set_callback, rv_clear_callbacks,
    rv_nothing, rv_nothing, rv_set_paused, rv_adjust,
};
