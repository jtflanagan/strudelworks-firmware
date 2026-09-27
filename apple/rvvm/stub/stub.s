; SPDX-License-Identifier: GPL-2.0-or-later
; SPDX-FileCopyrightText: 2026 jtflanagan
;
; stub - the GS/OS side of an application backed by RISC-V (docs/RVV2_INTEROP.md).
; Every such application is this code and its own header; the work is the
; runtime's, in our ROM at bank $F1.
;
; RELOCATION-FREE.  The GS/OS loader puts this segment wherever the Memory
; Manager finds room, and nothing here is patched (tools/omf_s16.py writes no
; relocation records): the stub's own addresses are only ever reached through
; PER and relative branches, and every other address is one that never moves -
; the runtime's doors in $F1 and GS/OS's entry in $E1.
;
; GS/OS enters an S16 application in native mode with its user ID in A.  The
; runtime is entered with A = the user ID, X/Y = the header's address (X the low
; word, Y the bank) and returns the exit code in A.  No runtime in $F1 (the bank
; is zeroed then) and the stub quits at once.

        .setcpu "65816"
        .smart  -

RT_SIG  = $F10000               ; "RVVM"
RT_DOOR = $F10020               ; the runtime's application entry (JML)
RT_QUIT = $F10030               ; a QuitGS parameter block, pCount 0
GSOS    = $E100A8               ; GS/OS's inline entry
QUIT_GS = $2029

        .segment "CODE"
        .a16
        .i16
start:  rep     #$30
        pha                             ; the user ID
        lda     f:RT_SIG
        cmp     #('V' << 8) | 'R'
        bne     quit
        lda     f:RT_SIG + 2
        cmp     #('M' << 8) | 'V'
        bne     quit
        per     header
        plx                             ; X = the header's low word
        phk
        phk
        pla
        and     #$00FF
        tay                             ; Y = its bank
        pla                             ; A = the user ID
        jsl     RT_DOOR                 ; A = the exit code
quit:   jsl     GSOS
        .word   QUIT_GS
        .dword  RT_QUIT
        brk     $00                     ; QuitGS does not return

; THE HEADER: what the runtime reads to know this application
; (docs/RVV2_INTEROP.md "The stub").  Rung I1 carries the signature alone.
header: .byte   "RVAP"
        .word   1                       ; the header's version
