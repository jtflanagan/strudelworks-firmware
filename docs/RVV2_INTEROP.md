# RISC-V applications under GS/OS: the high/low interop

Status: **2026-09-26, branch `riscv_v2`. DESIGN reviewed by the user 2026-09-26. The engine's map
rule is built (gs_map3, TIMING MET 0/91,875, on the card). RUNG I1 DONE ON HARDWARE: the Finder
launches `/RVDEMO/SPLASH/SPLASH` (tools/omf_s16.py, apple/rvvm/make_disk.sh), the stub finds
"RVVM" in `$F1` (the host's `gs_rvrom`), JSLs `$F1:0020` and quits through `$F1:0030`; the
runtime's trace at `$EE:FF00` shows the entry taken once per launch, the user ID ($1002) and the
stub's header read back through the address it passed ("RVAP").** The card's main memory is the whole 32 MB DDR3 bank: the lower 16 MB the 65816's, the
upper 16 MB the RISC-V engine's alone, all of it through the L2 (fw 06b4b3f, on hardware). This
document is how a RISC-V program becomes a GS/OS application. The decisions marked *(user)* were
made by the user on 2026-09-26; everything else is proposed and open to change.

## The shape

The rule everything follows from: **the 65816 cannot reach the upper 16 MB.** A RISC-V program's
code, stack and heap live up there - fast, private, never in GS/OS's way - so anything the 65816
must read or write on the program's behalf (a GS/OS parameter block, a toolbox call's arguments, a
file's bytes, a string) has to be in the lower 16 MB, in memory the application owns. Nothing is
bounced through the stack or any other place that only happens to be low.

A RISC-V application is three things *(user)*:

1. **The stub** - a small GS/OS application (S16) in the application's folder, built from **one
   template** that carries the standard interop set, plus **an identifying header** *(user)*. It is
   what the Finder launches and what owns the application's GS/OS identity.
2. **The runtime** - the engine's 65816 side, **in our ROM at bank `$F1`** *(user)*: the RUN loop,
   every service, the loader, the bookkeeping. One copy for every application.
3. **The program image and its resources** - files in the same folder: the RISC-V image (a
   self-relocating static PIE, as today's guests) and whatever the program reads (e.g. a PNG).

```
  Finder -> SPLASH (the stub, S16)          -- JSL -->  $F1 runtime (ROM)
                |                                          |  low block (GS/OS handle, the app's user ID)
                | owns: user ID, DP/stack                  |  upper-half banks (registered to the user ID)
                v                                          v
            SPLASH.RV, TITLEPIC.PNG  (files)        RISC-V program in the upper 16 MB
```

## The engine's map

What the engine reads and writes itself - through the L2, at full speed - and what it hands to the
65816 as a real access (delegated). Fixed in `rtl/gs/rv_mem.sv`, the machine's map (the user,
2026-09-26; it replaced the old programmable `dlo`/`dhi` range):

| | direct | delegated to the 65816 |
|---|---|---|
| read | the upper 16 MB, `$02`-`$DF`, `$E2`-`$FF` (our RAM and the ROM) | banks `$00`, `$01`, `$E0`, `$E1` |
| write | the upper 16 MB, `$02`-`$DF`, `$E2`-`$EF` | `$00`, `$01`, `$E0`, `$E1`, and `$F0`-`$FF` (the ROM: the 65816 drops it) |

Banks `$00`/`$01` are the switched views (RAMRD/RAMWRT, ALTZP, the language card) and hold the I/O
page, `$E0`/`$E1` the Mega II's I/O page and the video memory the card watches byte by byte; they
may later get some protection of their own. The null guard (`$000000`-`$0000FF`) faults first.

## The stub

**How a GS/OS application is loaded.** An application is an OMF (Object Module Format) file of
segments. The GS/OS loader puts each segment wherever the Memory Manager finds room - a different
address each run - so code that names its own addresses (a jump to a label, a table) must be
patched where it landed; OMF carries a list of those places, the relocation records, and the loader
patches them. ORCA, APW and Merlin write those records; our 65816 assembler (ca65/ld65) writes raw
bytes for a fixed address and cannot.

**So the stub needs no patching.** It is a few instructions - push the user ID, find its own header,
call the runtime, quit - using only relative branches, `PER` (which pushes an address computed from
where the code actually is) and fixed long addresses (the runtime at `$F1`, the toolbox at `$E1`),
which never move. All the real logic is in the runtime, at a fixed address in ROM. With nothing to
patch, the OMF file is a header and one block of the stub's bytes with no relocation records, plus a
second tiny segment asking for the direct page and stack the runtime will use - both written by a
small script (`tools/omf_s16.py`, to write). To the Finder and the loader it is an ordinary
application. Every stub is the same code; only its header differs.

On entry GS/OS gives an S16 its user ID in A and a direct page / stack segment in bank 0. The stub:

```
        pha                       ; the user ID
        per   header              ; the header's address, wherever the loader put us
        jsl   $F1xxxx             ; the runtime's app entry (fixed in the $F1 header)
        ...                       ; A = the program's exit code
        _QuitGS (via the runtime, or inline)
header: "RVAP", version
        image name   (a GS/OS class-1 string, relative to the stub's own folder: prefix 1:)
        low block size, bounce buffer size, call area size, 65816 stack need
        tool set list (the standard startup, and any extra tools with versions)
        flags (e.g. wants enhanced video)
```

The stub's own direct page and stack are the runtime's 65816 context while the application runs;
the header asks GS/OS's loader for enough (the `~Direct` / stack segment size).

## The runtime's lifecycle (one application)

1. **Enter** from the stub: the user ID, the header, the stub's D and S.
2. **Register** the user ID in the runtime's global table (below).
3. **The low block**: one Memory Manager handle under the user ID - locked, fixed, not crossing a
   bank - sized from the header. Laid out the same way for every application:
   - the **environment block** (below), first;
   - the **bounce buffers** (file and console I/O);
   - the **call area** (GS/OS parameter blocks, toolbox argument images, strings, results);
   - the **callback trampolines**.
4. **Start the tools** the header lists (the standard set: Tool Locator, Memory Manager, Misc
   Tools, the Event Manager *(user: input through the Event Manager)*, and whatever else), their
   direct pages from the Memory Manager under the user ID. Shut down in reverse at the end.
5. **Enhanced video**: the application becomes its owner - the only one, for now the current main
   application *(user)*. On exit the runtime turns it off (ENABLE 0, a global commit) and releases it.
6. **Upper-half memory**: banks `$100`-`$1FF` handed out to the user ID (below): enough for the
   image, its stack and an initial heap.
7. **Load** the image (below), then **run** it: pc = the image's base, sp = the top of its stack
   allocation, a0 = the environment block's address. The RUN loop services ECALLs; interrupts stay
   enabled (RUN yields to an IRQ the 65816 would take, as today).
8. **Exit** (ECALL `exit`, or a trap): tools down, enhanced video released, upper-half banks
   freed, the user ID unregistered; the low block goes with the user ID's memory at `_QuitGS`.
   The exit code returns to the stub.

## The environment block

The guest's one handle on the low half, at a0 on entry. Versioned; little-endian; every address a
24-bit GS address (all below 16 MB) unless it says upper. A first cut:

```c
struct rv_env {
    uint32_t magic;            /* 'RVEN' */
    uint16_t version, size;
    uint16_t user_id;          /* the application's GS/OS user ID */
    uint16_t flags;            /* e.g. owns enhanced video */
    uint32_t low_base, low_size;        /* the whole low block */
    uint32_t bounce, bounce_size;       /* I/O bounce buffer(s) */
    uint32_t call, call_size;           /* the call area */
    uint32_t hi_base, hi_size;          /* the upper-half memory registered to this app */
    uint32_t image_base, image_size;    /* where the image was loaded (upper half) */
    uint32_t heap_base;                 /* first free upper-half byte after image + stack */
    uint32_t app_path;                  /* GS/OS class-1 string: the stub's pathname */
    uint32_t video;                     /* the enhanced video control bank ($E2xxxx), 0 = not owner */
};
```

## Upper-half ownership: per user ID from the start *(user)*

A global table in our RAM, not in any application's memory (it must outlive and see all of them):
**one owner word per 64 KB bank** of the upper half - 256 banks, 512 bytes - where 0 is free.
Allocation is whole banks, contiguous, first fit. It lives in bank `$EE` (ours, RAM, unused by
anything else; `$E2` is enhanced video's, `$EF` the panel's) *(user: `$EE` and 64 KB banks)*. A registration table beside it names
the live RISC-V applications (user ID, their low block) - one entry today, room for more later (a
RISC-V desk accessory beside an application).

## Loading into the upper half: the loader in ROM *(user)*

The 65816 cannot write the upper half; the engine can, so the engine does the copying, and it needs
code to run while it does - which cannot be the image, the image being what is loaded. That is a
small RISC-V **loader**, kept in `$F1` and run there in place: the engine reads the ROM directly
(the map above). The runtime runs it:

```
  loader(env):
      loop: n = ECALL next_chunk()          -- the runtime reads the next piece of the image file
            if n == 0: break                    through GS/OS into the bounce buffer
            copy n bytes, bounce -> image_base + offset
      jump image_base with a0 = env           -- crt0 relocates the PIE, as today
```

The same path later loads anything else the program asks for into the upper half (a WAD).

## Calling the IIgs

The old branch's design (commit 229cf28, docs/REQ_RVVM.md there) stands, with one change: **the
descriptor and everything it points at live in the call area**, never in the upper half.
- `call65816(desc)` (ECALL `0x5010`): target, registers, a push image, inline bytes (GS/OS), a
  pull area for results, registers out. Tools (`$E10000`), GS/OS (`$E100A8`), plain routines.
- C wrappers generated per tool from a signature table; GS/OS calls through `rvgs_gsos(num, pb)`.
  A wrapper builds its argument image in the call area, and a pointer argument that names guest
  data (a string, a buffer, a rectangle) is copied into the call area first - in and/or out as the
  signature says. That copying is the generated code's job, never the programmer's.
- Callbacks: `make_callback(fn, pop_bytes)` returns a 65816 address of a trampoline in the low
  block; the runtime resumes the engine at `fn` with the tool's parameters copied into the call
  area; `callback_return` goes back. Not at interrupt time in v1 (as the old design).

## I/O

`read`/`write` and every file service take buffers in the low block. The guest library bounces a
large or upper-half buffer through the environment's bounce buffer, a chunk at a time; a program
that wants zero-copy asks for low memory of its own (a service that allocates from the low block or
a further handle under the user ID).

## The guest library

`librvgs` (C, beside today's guest runtime): the environment block, the bounce I/O, GS/OS and tool
wrappers (generated), callbacks, upper-half heap (`sbrk` over `heap_base`, growing by an ECALL that
registers more banks), enhanced video helpers (the control bank, descriptors, commits).

## How it is tested

- **Sim, without GS/OS**: the GS bench's engine mode with the GS/OS and toolbox entry points
  (`$E100A8`, `$E10000`) played by a small 65816 stand-in that answers the calls the runtime makes
  (NewHandle, Open/Read/Close, the tool startups, GetNextEvent with a scripted key). The runtime's
  logic and the loader, in lockstep as today.
- **Hardware, with GS/OS**: an 800K ProDOS disk *(user)*, a folder holding the stub, the image and
  its resources, mounted on the 3.5" drive (`fd35 =`), launched from the Finder.

## Rungs

| # | What | Proves |
|---|------|--------|
| I1 **done** | `$F1` on the card (a host conf key loads the runtime image there as the panel is at `$F0`), `tools/omf_s16.py`, the host's 800K disk builder, a stub whose runtime entry only returns | the Finder launches the stub, it enters `$F1` and quits back, on hardware |
| I2 | registration, the low block, the environment block, tool startup/shutdown, enhanced video ownership | the lifecycle, in sim (stand-in) and on hardware |
| I3 | the loader, the image read through GS/OS, upper-half banks | a guest loaded into the upper 16 MB runs and exits back to the Finder |
| I4 | `call65816`, generated wrappers, bounce I/O, callbacks, the Event Manager key | a guest reads a file and waits for a key |
| I5 | the splash: enhanced video mode 1, the PNG decoder (measured) | DOOM's title screen, a key, back to the Finder |

## Open

- The stub's exact header layout and the OMF details (`~Direct` size, KIND).
- Where the runtime's own per-application state lives (in the low block, found through the
  registration table, is the proposal).
- Console output (fd 1/2): a GS/OS desktop application has no console - it draws in windows - so C's
  stdout is **discarded**, as any desktop application's would be. A debug channel to the host's log
  is a possible development aid, decided when a real application needs it.
- The tool signature table's source and licensing (carried over from the old branch).
