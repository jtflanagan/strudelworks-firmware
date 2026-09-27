; SPDX-License-Identifier: GPL-2.0-or-later
; SPDX-FileCopyrightText: 2026 jtflanagan
;
; RVTEST's header (apple/rvvm/stub/stub.s includes it): the interop's test
; application (docs/RVV2_INTEROP.md) - it owns enhanced video (so the runtime's
; ownership is exercised) and starts the same tools as SPLASH.

APP_FLAGS  = HF_VIDEO
APP_VMODE  = $0000                      ; QuickDraw II at 320
APP_BOUNCE = 8192
APP_CALL   = 1024

; The tools StartUpTools starts (Tool Locator and Memory Manager are the
; runtime's own): a count, then (tool, minimum version) pairs.
tools:  .word   3
        .word   $03, $0000              ; Miscellaneous Tool Set
        .word   $04, $0000              ; QuickDraw II
        .word   $06, $0000              ; Event Manager

; The program image, a GS/OS class-1 string; prefix 9: is the application's
; own folder (loaded at rung I3).
image:  .word   .strlen("9:RVTEST.RV")
        .byte   "9:RVTEST.RV"
