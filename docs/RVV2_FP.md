# Floating point on the RISC-V engine: F and D

Status: **2026-09-27, branch `riscv_v2`, uncommitted. The engine is RV32IMFD_Zba_Zbb: standard F
and D with their own 32 x 64-bit register file. IN SIM: TestFloat 105/105 suites on the FPU,
riscv-tests rv32uf/rv32ud 21/21 and the whole guest suite 134/134 in lockstep on the core bench and
with the memory side (the stress set), RVTEST's FP rung and SPLASH through the real runtime (app
bench), Embench-IoT 1.0's FP four 2.5-21.9x over soft float. Pt build `gs_fpu1` TIMING MET, 43,649
LUTs (+5,861). ON HARDWARE (flash, 20260927 142915): RVTEST from the Finder exits $15A with its FP
rung passed; DOOM, built for F/D, plays its demo at
36 fps.**

## The decision (the user, 2026-09-27)

"Add floating point support to the riscv engine", and of the three designs offered - standard F+D,
the shelved Zfinx+Zdinx trial of 2026-09-25 revived, single-only F - **standard F+D**. The trial's
reason for Z*inx (no second register file for the 65816's software VM to hold) went with the VM
(v2 has none), and v2's applications are built by clang 18, whose Zdinx code moves every double
through the stack. The trial's arithmetic is kept: `rtl/gs/rv_fpu.sv` and its oracle.

## The design

- **The registers** (`rtl/gs/rv_pipe.sv`): 32 x 64 bits in LUT RAM, three read ports (E's rs1,
  rs2, rs3) and one write port (W, or a delegated FP load's resume). A single is NaN-boxed: every
  single result is written with the high word all ones, and a single source whose register is not
  boxed reads as the canonical NaN (0x7FC00000) - everywhere but `fmv.x.w` and `fsw`, which take the
  raw low word (the ISA's rules, as spike).
- **No forwarding for FP registers.** An FP source that an instruction in M or W still writes makes
  E wait until it has retired (an FP load, an FP result). FP results travel down the pipe as 64 bits
  (`m_resh`/`w_resh`) and are written at W like the integer file's, so an event or a redirect never
  leaves an FP register written by a flushed instruction. Integer sources of FP ops (`fcvt.d.w`,
  `fmv.w.x`) and integer results (`feq`, `fclass`, `fcvt.w.d`, `fmv.x.w`) use the integer pipe's
  forwarding as any ALU op.
- **The unit** (`rtl/gs/rv_fpu.sv`, the trial's, now with `kill`): one operation at a time, E held
  while it runs; a flush (an older event, a redirect from M) kills it in flight and a new start is
  clean. Add/sub 13 clocks, mul 17-18, fma 17-19, div 37 (s) / 67 (d), sqrt 38 / 66, conversions
  8-13, compares/min/max/class 6-7. Sign injection (`fmv`, `fneg`, `fabs`) and the two moves are
  single-clock in the pipe instead: compilers use `fsgnj` as the register move.
- **Loads and stores.** An access is the words its bytes touch, one after the other in M
  (`docs/RVV2_MISALIGNED.md`): `flw`/`fsw` one word, `fld`/`fsd` two - while M has words to go,
  `d_pre` (rv_mem's early row read) is the next word's, so an aligned double from the row cache costs
  one clock more than a word - and a misaligned one up to three, put together on one clock more.
  An access whose last byte would be past the space is a load/store fault.
- **The VM's part: R_DFL (32) and R_DFS (34).** An FP access that rv_mem delegates (banks
  $00/$01/$E0/$E1: the 65816's own) is presented to the 65816 whole: `ev_addr` its first byte,
  `ev_iw` the instruction (f3 = 3 a double), `ev_data`/`ev_datah` a store's value; a load resumes
  with the resume value and its high word. The window (`rtl/gs/rv_engine.sv`) gains +A8-+AB (the
  resume value's high word, R/W), +AC-+AF (ev_data's high word, R) and +B0 (fcsr, R); the runtime
  (`apple/rvvm/rvengine.s`) `ev_fl`/`ev_fs`.
- **fcsr** (CSRs 1-3, the Zicsr ops): fflags gather at retirement (a flushed op's flags never
  count); a CSR op waits in E for M and W to empty and takes effect as it leaves E; a dynamic
  rounding mode with frm > 4 is an illegal instruction, found in E. There is no mstatus.FS: F and D
  are always on. Nothing resets the engine between applications, so `crt0_app.S` clears fcsr.

## The toolchain

- **Applications** (`apple/rvvm/build_app.sh`): clang, `-march=rv32imfd_zba_zbb_zifencei
  -mabi=ilp32d` - doubles passed and returned in FP registers - linked with picolibc's F/D variant
  (`sim/build_rvvm_picolibc.sh fd`, `apple/rvvm/guest/picolibc-cross-fd.txt`, into
  `sim/rvvm_work/picolibc-fd`: its libm runs on the FPU) and libgcc's `rv32imfd_zicsr/ilp32d`
  multilib (64-bit division; the conversions to and from 64-bit integers RV32 has no instruction
  for). DOOM, SPLASH and RVTEST all build so; DOOM's own floating point is start-up only (DBOPL's
  tables, libm).
- **The benchmarks' baseline** stays soft float (`rv32im_zba_zbb`, ilp32, the plain picolibc):
  CoreMark and integer Embench are unchanged.
- **The tests** build with `rv32imfd` under ilp32 (the riscv-tests, rvvm's edge tests, the C tests):
  soft-ABI calls with hardware FP inside them, so doubles cross between the files at every call.

## Verification

- **The FPU alone** (`sim/run_rv_fpu.sh`): Berkeley SoftFloat 3 (RISCV specialization, spike's
  model, `../berkeley-softfloat-3`) and TestFloat (`../berkeley-testfloat-3`): 200k random cases over
  every op, format and rounding mode, then TestFloat level 1 for every op it has (the FMA's 6.1 M
  cases in each of 10 format/mode pairs): **105 suites, 0 mismatches** with `kill` added.
- **The reference model** (`sim/rv_ref.h`): F and D on SoftFloat, every bench's; the core bench
  (`sim/rv_core_main.cpp`, its own read port `frsel`/`frval`) and the engine-sys bench
  (`sim/rvvm_run_main.cpp`, the core's registers directly) compare all 32 FP registers and fcsr
  after every retirement and at the stop, beside the integer registers and all of memory.
- **The suite** (`sim/run_rvvm_tests.sh`): riscv-tests rv32uf (11) and rv32ud (10, `move` is RV64's)
  beside rv32ui/um/uzba/uzbb; rvvm's edge tests `f_fp_ldst` (aligned, a double at a 4-byte boundary,
  misaligned, bank $01, the load-use waits), `f_fp_nanbox`, `f_fp_flush` (an FPU op killed behind a
  mispredicted branch, a delegated load, a delegated FP load - its flags must not count),
  `f_fp_top` (a double's second word off the space: a load fault), `f_fp_badfrm`, `f_fp_fused`
  (the fused four with rs3 = every register number OP-FP uses as a funct5: the model read them as
  funct5 once - found by cubic, fixed, mutation-checked); C tests `fp_ops` (every F and D
  instruction on edge-biased operands in every rounding mode, flags read back) and `fp_numeric`.
  **134/134** in lockstep: core bench step, `--run`, `--run --yield=40 --hold=20`; with the memory
  side (`--engine-mem`) plain, `--run`, seeds 1-4 with `--evict=20 --hold=10 --rec-stall=80` and
  `--run` seed 5. `--engine-sys` (the runtime on the 65816 serving every access: every FP load and
  store through R_DFL/R_DFS) 126/126, 8 upper-half tests skipped as always. The GS batch through the
  whole `gs_top` (`sim/run_rv_gs_batch.sh --coremark`) 24/24; `sim/suite.sh gs` 18/18.
- **Through the runtime** (`sim/run_rv_app.sh`): RVTEST's FP rung (checks 30-33: fcsr clear at
  entry, 1/3, sqrt 2, fma(0.1, 10, -1) rounded once, a single's 1/3, fcvt.w.d of -3.5 in two modes,
  the NX/DZ/NV flags, a misaligned fsd/fld/fsw/flw round trip through the low block)
  - all three cases pass; SPLASH's picture is the reference's, pixel for pixel.

## What it buys

`sim/run_rv_fp_embench.sh`: Embench-IoT 1.0's floating-point four (2.0 dropped them; from the
`embench-1.0` tag), clang -O2, under RUN on the core bench in lockstep, clocks for the whole run:

| | soft float (ilp32) | F+D (ilp32d, libm on the FPU) | |
|---|---|---|---|
| cubic | 23,197,642 | 9,145,292 | 2.54x |
| minver | 14,128,948 | 2,205,932 | 6.40x |
| nbody | 17,038,537 | 777,250 | 21.92x |
| st | 11,792,782 | 774,900 | 15.22x |

(The Zdinx trial under GCC: 2.50x, 6.29x, 16.87x, 14.17x.)

## The cost

The Pt build `gs_fpu1` (stamp 20260927 142915) **MEETS TIMING** (0 failing endpoints of 98,364; no
undriven or multi-driven nets):

| | LUTs | of them LUT RAM | FFs | DSPs | BRAM tiles |
|---|---|---|---|---|---|
| the card, before (`gs_32mb2`) | 37,788 | | | | 60 |
| the card, with F+D (`gs_fpu1`) | 43,649 (68.9% of the Pt) | 2,425 | 29,477 | 15 | 60 |
| `rv_pipe` (with the FPU) | 9,474 | 198 | 3,356 | 7 | |
| `rv_fpu` | 5,073 | 0 | 1,584 | 3 | |

+5,861 LUTs for the card (`build/results/utilization_hier_gs_fpu1.rpt`): the FPU 5,073, the rest the
FP register file, the sign injection, the unboxing, the second word in M and the wider W.

## Open

- The LUTs, if they matter: the FPU's special-case and result multiplexers, its three wide shifters
  (align 110, normalize 110, round 54) and the full-width magnitude compare are the obvious cuts.
