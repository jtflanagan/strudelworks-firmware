/* SDL_endian.h - for Chocolate Doom's i_swap.h (its i_oplmusic.c and
   midifile.c find their own headers first): the engine is little-endian, as
   the WAD is; the big-endian swaps are in compat/SDL.h. */
#define SDL_SwapLE16(x) (x)
#define SDL_SwapLE32(x) (x)
