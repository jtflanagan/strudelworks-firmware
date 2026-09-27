/* SDL.h - the little of SDL that Chocolate Doom's OPL library and MIDI reader
   use (../chocolate-doom at chocolate-doom-2.2.1: opl/opl.c, src/midifile.c),
   for DOOM on the RISC-V engine (docs/RVV2_DOOM.md, rung MU1).  One thread: the
   mutexes are nothing, and OPL_Delay's wait - for a callback the SDL mixing
   thread would reach - runs the OPL's next callback now (opl_rv.c).  Included
   into every file (app.mk), for midifile.c's byte swaps. */
#if !defined(RV_SDL_H) && !defined(__ASSEMBLER__)
#define RV_SDL_H
#include <stdint.h>

typedef struct SDL_mutex SDL_mutex;
typedef struct SDL_cond SDL_cond;
void opl_rv_wait(void);
static inline SDL_mutex *SDL_CreateMutex(void) { return (SDL_mutex *)1; }
static inline void SDL_DestroyMutex(SDL_mutex *m) { (void)m; }
static inline int SDL_LockMutex(SDL_mutex *m) { (void)m; return 0; }
static inline int SDL_UnlockMutex(SDL_mutex *m) { (void)m; return 0; }
static inline SDL_cond *SDL_CreateCond(void) { return (SDL_cond *)1; }
static inline void SDL_DestroyCond(SDL_cond *c) { (void)c; }
static inline int SDL_CondSignal(SDL_cond *c) { (void)c; return 0; }
static inline int SDL_CondWait(SDL_cond *c, SDL_mutex *m) { (void)c; (void)m; opl_rv_wait(); return 0; }
#define SDL_SwapBE16(x) ((uint16_t)__builtin_bswap16((uint16_t)(x)))
#define SDL_SwapBE32(x) ((uint32_t)__builtin_bswap32((uint32_t)(x)))
#endif
