; SPDX-License-Identifier: GPL-2.0-or-later
; SPDX-FileCopyrightText: 2026 jtflanagan
;
; DOOM's header (apple/rvvm/stub/stub.s includes it): doomgeneric on the RISC-V
; engine (docs/RVV2_DOOM.md), drawn on enhanced video mode 1, its WAD beside it.

APP_FLAGS  = HF_VIDEO
APP_VMODE  = $0000                      ; QuickDraw II at 320
APP_BOUNCE = 16384                      ; the WAD's lumps come through here
APP_CALL   = 1024

tools:  .word   3
        .word   $03, $0000              ; Miscellaneous Tool Set
        .word   $04, $0000              ; QuickDraw II
        .word   $06, $0000              ; Event Manager

image:  .word   .strlen("9:DOOM.RV")
        .byte   "9:DOOM.RV"
