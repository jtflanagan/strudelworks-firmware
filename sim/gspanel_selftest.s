; SPDX-License-Identifier: GPL-2.0-or-later
; SPDX-FileCopyrightText: 2026 jtflanagan
;
; gspanel_selftest - a panel small enough to read, for sim/gspanel_run_main.cpp
; to prove ITSELF on before a compiler's output is put in front of it
; (docs/GS_CONTROL_PANEL.md R0).  It does what a panel does, once each:
;
;   writes "HI" across row 0's first two columns (aux then main),
;   waits for a key; Return chains to the stock panel (FF/8FB0) and comes
;   back to write "S" in column 2; Escape returns to the caller.
;
; Entry state as the Desk Manager leaves it: native, M = X = 1, DBR = 0,
; D = 0.  Everything it touches is by long address, so DBR never matters.

        .setcpu "65816"
        .smart  +

        .segment "CODE"
header: .byte   "SWCP"
        .word   1                       ; version
        .word   end - header            ; size
        .faraddr entry
        .res    5, 0

entry:  php
        phb
        phd
        .a8
        .i8
        lda     #'H' | $80
        sta     f:$E10400               ; column 0: aux
        lda     #'I' | $80
        sta     f:$E00400               ; column 1: main

wait:   lda     f:$00C000
        bpl     wait
        sta     f:$00C010
        cmp     #$9B                    ; Escape
        beq     done
        cmp     #$8D                    ; Return
        bne     wait
        jsl     stock
        lda     #'S' | $80
        sta     f:$E10401               ; column 2: aux
        jmp     wait

done:   pld
        plb
        plp
        rtl

; The chain: the two instructions the patch at FF/8FAC displaced, then the
; stock panel's own code, whose RTL returns past the JSL above.
stock:  lda     f:$00C015
        pha
        jml     $FF8FB0
end:
