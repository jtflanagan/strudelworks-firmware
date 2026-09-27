# Misaligned access on the RISC-V engine

Status: **2026-09-27, branch `riscv_v2`, uncommitted. The engine does every misaligned load and store
itself (`rtl/gs/rv_pipe.sv`'s M stage); the VM only ever does an access to the 65816's own banks.
IN SIM: the guest suite 136/136 on the core bench with the new `f_misaligned`, `f_mis_top` and the
widened `hi_cross`; the stress set 136/136 in all ten configurations, `--engine-sys` 127/127, the GS
batch 24/24, the app bench (RVTEST, SPLASH). Pt build `mis3` (with the 65816's I-side chain cut and
the chipset's register slice, docs/CORE_REFACTOR_65816.md) TIMING MET, 44,272 LUTs; ON HARDWARE
(flash, 20260927 180948): Nox's title and menu, GS/OS, RVTEST $15A (its misaligned FP now the
engine's), DOOM's demo at 34.4 fps. Uncommitted.**

## The decision (the user, 2026-09-26)

Misaligned loads and stores are handled ENGINE-SIDE, everywhere - not only in the upper 16 MB, which
the 65816 cannot reach. They went to the VM on the old branch only because the 65816 bus was in the
way; with the engine's own memory path it is easier inside. A performance hit, handled internally:
no more "misaligned" event. (Decided with the 32 MB map; built 2026-09-27, after the splash, DOOM
and floating point had been done on the old way.)

## As built

- **An access is the words its bytes touch** (`rtl/gs/rv_pipe.sv`): one for anything inside a word
  (a halfword at offset 1 included), two for a word or half across a word boundary or a word-aligned
  double, three for a double at an odd offset. E works out the count (`m_n`), the store's data and
  byte enables spread across the words (`m_wd`, `m_bew`: the store value shifted by the offset); M
  makes the word accesses one after the other, each through rv_mem as any word, and while words are
  left `d_pre` - rv_mem's row read a clock early - is the next word's, so a word from the row cache
  follows the last on the next clock.
- **Stores** go out a word at a time with their byte enables (each a posted store and its engine-write
  record). **Loads** gather their words (`m_acc`); a load that was not word-aligned is put together
  on one clock more (`m_fin`: shift, then the extension as for any load), a word-aligned double
  takes its high word straight from the answer. A one-word access is exactly as before.
- **The space**: an access must lie wholly in it - its first and last bytes below 32 MB and
  outside the null guard - or it is a load/store fault with its first byte as tval (`f_mis_top`).
- **Delegation is by memory only.** rv_mem hands the VM an access to banks $00, $01, $E0 and $E1;
  if any word of an access is there, the whole access is the VM's, as the event of the access's own
  kind (R_DLB..R_DSW, R_DFL/R_DFS) from its first byte - the 65816 has no alignment and crosses a
  bank without trouble (`f_misaligned` has both ways round: $01FFFE and $DFFFFE). A store's words
  that went out before the delegated one are written again by the VM, with the same bytes.
- **A write to the ROM ($F0-$FF) is dropped by rv_mem itself** (answered, nothing written, no
  record) - as the machine drops it, where before it was delegated so the 65816 could drop it. With
  that, no bank the VM serves borders the upper 16 MB, so a misaligned access across $0100_0000
  (`hi_cross`: bank $FF's ROM below, the engine's RAM above) is always the engine's.
- **The runtime** keeps its delegated-access handlers for the 65816's banks; no misaligned access in
  RAM reaches it now.

## Verification

- `sim/rv_ref.h`: alignment free, the range rule on the first and last byte (`acc_ok`); the core
  bench's memory model drops ROM writes as rv_mem does.
- `f_misaligned` (every width at every offset across a word, a row, a page and a bank; a double over
  three words; the value used at once; a store read straight back; half in the 65816's bank $01 and
  half in $02, the engine's $DF and $E0's; a store into the ROM, dropped - seven events in all, the
  six delegated accesses and the exit); `f_mis_top` (last-byte faults); `hi_cross` (misaligned words
  and doubles across the 16 MB line); `f_fp_ldst` (FP at every alignment).
