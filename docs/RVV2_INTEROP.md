# RISC-V applications under GS/OS: the high/low interop

Status: **2026-09-26, branch `riscv_v2`. DESIGN reviewed by the user 2026-09-26. The engine's map
rule is built (gs_map3, TIMING MET 0/91,875, on the card). RUNG I1 DONE ON HARDWARE (fw d422b82).
RUNGS I2 AND I3 DONE ON HARDWARE (under System 6.0.1, launched from the Finder by the MCP): the
lifecycle (registration in `$EE`, the Tool Locator and Memory Manager, the low block, the environment
block, StartUpTools, enhanced video's ownership, all undone in reverse) and now THE PROGRAM - its file
opened through GS/OS (`9:SPLASH.RV`, 25,724 bytes from the 800K floppy), its image header read, six
banks of the upper half registered to it, the RISC-V loader in `$F1` pulling the file through the
bounce buffer into `$0100_0000`, and the program running there: its eleven checks pass (the
environment block, 160 KB of heap across banks, the stack, the call area, its pathname, its
relocations, a 24 KB table word for word) and it exits 0 at its own ECALL (`$0100_00BC`), twice in a
row. `sim/run_rv_app.sh` (the engine's memory side and 32 MB in the bench, sim/l2_model.h) passes a
clean machine, a stale registration and a missing file, each launched twice; five mutations caught.
Hardware found two bugs the bench then learned to see: StartUpTools is `$1801` / ShutDownTools `$1901`
(read off the machine's own Tool Locator, not recalled), and an engine event left pending by the last
program (its exit's ECALL) must be finished before the next program starts.** The card's main memory is
the whole 32 MB DDR3 bank: the lower 16 MB the 65816's, the upper 16 MB the RISC-V engine's alone,
all of it through the L2 (fw 06b4b3f, on hardware). This
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

### The stub's header (version 2, built at rung I2)

`apple/rvvm/stub/stub.s` is the one template; each application's `app.inc` (e.g.
`apple/rvvm/splash/app.inc`) gives its values and lists. Offsets from the header:

| off | what |
|---|---|
| +0 | `"RVAP"` |
| +4 | the header's version, 2 |
| +6 | flags: bit 0 = the application owns enhanced video |
| +8 | StartUpTools' video mode (`$0000` 320, `$0080` 640) |
| +10 | the bounce buffer, bytes |
| +12 | the call area, bytes |
| +14 | the tool list's offset: a count (at most 32), then (tool number, minimum version) word pairs |
| +16 | the program image's name's offset: a GS/OS class-1 string, `9:` = the application's folder (rung I3) |

`tools/omf_s16.py` writes the stub's code segment and a `~Direct` segment (KIND `$12`, 4 KB, reserved
space only): GS/OS enters the stub with D at its start and S at its end, and that direct page and
stack are the runtime's while the application runs. The sim measures the stack the lifecycle itself
uses (25 bytes of the stand-in's calls; the real tools take more - hence 4 KB, not the loader's default).

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

**As built at rung I2** (`apple/rvvm/rvengine.s`, `app_entry`): the order is register -> TLStartUp,
MMStartUp -> NewHandle (the low block, attributes `$C01C`: locked, fixed, page-aligned, not across a
bank, not in banks `$00`/`$01`/`$E0`/`$E1` - so the engine reads and writes it itself) -> the
environment block and the start/stop record in it -> StartUpTools(user ID, 0, the record) ->
enhanced video (header flag) -> the engine -> and the undoing, driven by a DONE mask so a failure part
way undoes exactly what was done: video off, ShutDownTools(0, the record), DisposeHandle (explicitly,
not left to QuitGS), MMShutDown, TLShutDown, unregister. The start/stop record lives in the low block
because StartUpTools writes the resource file and direct page handle back into it and ShutDownTools
reads them. The low block is: the environment block (64 bytes), the start/stop record (12 + 4 per
tool), the bounce buffer, the call area, each 4-aligned.

While the engine runs for an application the runtime's platform changes: the console is discarded,
nothing is read, and an exit or a trap returns to the lifecycle (to the S saved when the engine
started) instead of stopping the machine. Exit codes the runtime makes itself: -2 a header it does
not know, -3 a toolbox call refused (the trace says which and why), -4 no engine.

At rung I2 the program is `rt_null` (`apple/rvvm/rt/rt_null.S`, RISC-V code in the runtime's bank at
`$F1:E000`, run in place): it checks the environment block - the magic, version and size, the user
ID, the low block's bank, the pieces inside it in order, a word written to the call area, the video
field against the flags and ENABLE off - and exits 0 or the failing check's number.

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
    uint32_t heap_base;                 /* the first byte after the image and its bss (upper) */
    uint32_t app_path;                  /* GS/OS class-1 string: the program's pathname */
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

As built at rung I2 (`$EE:0000`, made when its magic is not there - DDR3 holds whatever it held):

| at | what |
|---|---|
| `+$000` | `"RVRG"`, then the version (1) at `+4` |
| `+$006` | enhanced video's owner: a user ID, 0 = none |
| `+$008` | the application slot: its user ID (0 = free), its low block (long) at `+$00A` |
| `+$100` | 256 owner words, banks `$100`-`$1FF` of the engine's space |

Only one application runs at a time, so one found in the slot at an entry is dead (its quit never
unregistered it: a reset, a crash): everything registered to its user ID is taken back - its banks,
and enhanced video, turned off - before the slot is reused.

**The trace** (`$EE:FF00`, `"RVRT"`): what the last lifecycle did, read from the host's mirror - an
entry count, the user ID, the header's address, the last step taken (`$FF` when it came back), the
last toolbox error, the low block, the exit code, the engine's status/cause/tval/pc at the stop,
StartUpTools' ref, and the DONE mask at its highest. (The mirror shows only what was written since
swhost started: the marker and the count may read 0 there while the card holds them.)

## Loading into the upper half: the loader in ROM *(user)*

**As built at rung I3.** A program is a static PIE started by `apple/rvvm/guest/crt0_app.S`, whose
first jump is followed by THE IMAGE HEADER - `'RVIM'`, version 1, the memory it needs (the image and
its bss), its stack and the heap to reserve (`link.ld`'s `__stack_size` / `__heap_size`, set per
application in `app.mk`). `crt0_app` keeps a0 (the environment block) in `rv_env` (`rvgs.h`, the
start of librvgs) and calls `main`. The runtime (`file_up`), after the tools and video:
1. Open (`requestAccess` read) the header's image name, GetEOF, and Read the first chunk into the
   bounce buffer - class-1 calls through GS/OS's stack entry `$E1:00B0` (the panel's proven way; the
   parameter blocks are the runtime's own, in the low block after the start/stop record);
2. check the image header in that chunk and size its memory: the image and bss (16-aligned) + heap +
   stack, in whole 64 KB banks, first fit in the registration table (`-6` a bad header, `-7` no room);
3. fill the environment block's upper-half fields (`hi_base`/`hi_size`, `image_base` = `hi_base`,
   `image_size` = the file's size, `heap_base` = after the image and its bss, `app_path` = the
   program's pathname) and start the engine in `rt_loader` (`$F1:E000`, `apple/rvvm/rt`).
The loader asks for chunks with ECALL `$5020` (the first is the one already read; then one Read each;
0 at the end - the runtime closes the file then; a GS/OS error comes back negated), copies each to
`image_base` + offset, checks the whole file arrived (`-8`), `fence.i`, sets sp to the top of the
application's memory and jumps into the program with a0 = the environment block. GS/OS errors on the
file are `-5` with the error in the trace (`$46` fileNotFound when the program is missing).

The chunks reuse the bounce buffer, so what the engine read of the last one must not survive the next:
a Read written by the 65816 is snooped, one by DMA empties the engine's rows (`inval`, gs_top's
override writes) - the bench models the DMA case, and without that invalidate the loader copies stale
rows (a mutation caught). Before any program starts, the runtime finishes an event the engine still
holds from the last (`eng_idle`: RESUME with a NOP as the resume value) - nothing resets the engine
between applications or machine resets, and a RUN with an event pending only reports it again. The
one pending event that is not cleanly finished that way, a delegated fetch left by a reset, needs an
abort in the engine (open).

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

- **Sim, without GS/OS**: `sim/run_rv_app.sh [APP]` - `rvvm_run --app=STUB.bin`, built with the
  engine's memory side (`sim/rvvm_sys.sv` MEM=1: rv_mem on the card's map, `sim/l2_model.h` - the
  engine bench's L2 model, shared - behind it, 32 MB): the card's 65816 and the engine, the stub
  entered as the loader would, GS/OS's entry points (`$E10000`, `$E100A8`, `$E100B0`) 65816
  trampolines into a C++ stand-in that answers the calls the runtime makes, the program's file served
  from `--image=` (Read written as a DMA would, the engine's rows invalidated after). The verdict: the
  calls in order with their arguments (the start/stop record against the stub's header, every Read of
  the file, Close before the tools go down), every start with its stop, the trace, the upper half
  holding the file byte for byte when the program starts and the host's mirror of it (the engine's own
  0xB records) equal to memory at the end, the registration table empty again, enhanced video left
  off, the stack balanced at every QuitGS, and no 65816 write outside what the lifecycle owns. Three
  cases - clean, `--stale`, no program file (`-5`) - each launched twice on the one engine.
- **Hardware, with GS/OS**: an 800K ProDOS disk *(user)*, a folder holding the stub, the image and
  its resources, mounted on the 3.5" drive (`fd35 =`), launched from the Finder.

## Rungs

| # | What | Proves |
|---|------|--------|
| I1 **done** | `$F1` on the card (a host conf key loads the runtime image there as the panel is at `$F0`), `tools/omf_s16.py`, the host's 800K disk builder, a stub whose runtime entry only returns | the Finder launches the stub, it enters `$F1` and quits back, on hardware |
| I2 **done** | registration, the low block, the environment block, tool startup/shutdown, enhanced video ownership | the lifecycle, in sim (stand-in) and on hardware |
| I3 **done** | the loader, the image read through GS/OS, upper-half banks | a guest loaded into the upper 16 MB runs and exits back to the Finder |
| I4 | `call65816`, generated wrappers, bounce I/O, callbacks, the Event Manager key | a guest reads a file and waits for a key |
| I5 | the splash: enhanced video mode 1, the PNG decoder (measured) | DOOM's title screen, a key, back to the Finder |

## Open

- Where the runtime's own per-application state lives: the stub's direct page while the application
  runs, and the start/stop record in the low block (rung I2); a second RISC-V client (a desk
  accessory) will need it found through the registration table.
- Console output (fd 1/2): a GS/OS desktop application has no console - it draws in windows - so C's
  stdout is **discarded**, as any desktop application's would be. A debug channel to the host's log
  is a possible development aid, decided when a real application needs it.
- The tool signature table's source and licensing (carried over from the old branch).
