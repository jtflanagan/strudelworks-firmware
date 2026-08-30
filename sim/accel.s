; SPDX-License-Identifier: GPL-2.0-or-later
; SPDX-FileCopyrightText: 2026 jtflanagan
;
; accel.s - sim/mem_integ.s with a $C100-$CFFF section, for sim/accel_tb.sv: exercises every kind of
; memory the card's image claims to serve, and says whether each read came
; back right.  Runs from RAM at $6000 (copied out of the ROM by the reset
; code), with the auxiliary-memory and RamWorks tests in ROM because RAMRD
; would take the code away from under them.
;
; PASS ($0300) counts completed passes; FAILF ($03FF) is $FF if anything
; disagreed, and the program then halts.

PASS    = $0300
FAILF   = $03FF
RWFLAG  = $03FE          ; non-zero once the card is serving: run the RamWorks test
PTR     = $06

.macro  jne target
        beq :+
        jmp target
:
.endmacro

.segment "CODE"

main:
        lda #$00
        sta PASS
        sta FAILF
loop:
        ; ---- 1. a page of RAM, written and read back ----------------------------
        lda #$00
        sta PTR
        lda #$10
        sta PTR+1
        ldy #0
fill:   tya
        clc
        adc PASS
        sta (PTR),y
        iny
        bne fill
        inc PTR+1
        lda PTR+1
        cmp #$11
        bne fill
        lda #$10
        sta PTR+1
        ldy #0
ver:    tya
        clc
        adc PASS
        cmp (PTR),y
        jne fail
        iny
        bne ver
        inc PTR+1
        lda PTR+1
        cmp #$11
        bne ver

        ; ---- 2. the stack and a subroutine -----------------------------------
        lda #$5A
        pha
        jsr sub
        pla
        cmp #$5A
        jne fail

        ; ---- 3. the language card --------------------------------------------
        lda $C083               ; bank 2, read RAM, two reads: write enabled
        lda $C083
        lda #$D2
        sta $D000
        lda #$E1
        sta $E000
        lda $C08B               ; bank 1, read RAM, write enabled
        lda $C08B
        lda #$D1
        sta $D000
        lda $D000
        cmp #$D1
        jne fail
        lda $E000               ; shared above $E000
        cmp #$E1
        jne fail
        lda $C080               ; bank 2, read RAM, write protected
        lda $D000
        cmp #$D2
        jne fail
        lda #$77
        sta $D000               ; must land nowhere
        lda $D000
        cmp #$D2
        jne fail
        lda $C082               ; bank 2, read ROM, write protected
        lda $D000
        cmp #$C7                ; the ROM's byte there
        jne fail
        lda $C081               ; read ROM, write RAM bank 2
        lda $C081
        lda #$D3
        sta $D000               ; lands under the ROM
        lda $D000
        cmp #$C7
        jne fail
        lda $C080
        lda $D000
        cmp #$D3
        jne fail
        lda $C089               ; one read of an odd address: no write enable yet
        lda #$44
        sta $D000               ; bank 1: still write protected
        lda $C08B
        lda $D000
        cmp #$D1
        jne fail
        lda $C082               ; back to ROM, protected, before touching aux

        ; ---- 4. auxiliary memory, from the ROM -------------------------------
        jsr auxtest
        bcs fail

        ; ---- 5. the RamWorks banks, from the ROM - once the card is serving.
        ; The machine the testbench models has no RamWorks; the card is it,
        ; and only its image can answer.  The testbench sets RWFLAG through
        ; the override path when it turns serving on.
        lda RWFLAG
        beq norw
        jsr rwtest
        bcs fail
norw:
        jsr cxtest

        inc PASS
        jmp loop

; ---- $C100-$CFFF: the internal ROM, a slot ROM, the expansion ROM latch ----
; Reads whose bytes the testbench checks against its own model of UTAIIe
; 5-28 (rtl/apple_mmu.sv, "THE CX CLASS"); the program only makes them.
; Every switch is restored before returning.
cxtest: sta $C007               ; INTCXROM on: all of $C100-$CFFF is internal
        lda $C100
        lda $C3FF
        lda $C800
        lda $CFFE
        lda $CFFF
        sta $C006               ; off: the slots' pages are the slots'
        sta $C00A               ; SLOTC3ROM off: $C3xx is internal regardless
        lda $C300               ; ...and sets INTC8ROM
        lda $C800               ; internal, by that latch
        lda $CFFF               ; clears it
        lda $C800               ; nothing there now: the floating bus
        lda $C500               ; the testbench's slot 5 card ROM
        lda $C400               ; an empty slot
        sta $C00B               ; SLOTC3ROM on: slot 3's page is the slot's
        lda $C300               ; ...which is empty
        lda $C800               ; still nothing: no INTC8ROM without slot 3 internal
        sta $C00A               ; restore
        rts

sub:    lda #$C3
        rts

fail:   lda #$FF
        sta FAILF
halt:   jmp halt

.import __CODE_LOAD__, __CODE_RUN__, __CODE_SIZE__

.segment "BOOT"

reset:  sei
        cld
        ldx #$FF
        txs
        lda #<__CODE_LOAD__
        sta $00
        lda #>__CODE_LOAD__
        sta $01
        lda #<__CODE_RUN__
        sta $02
        lda #>__CODE_RUN__
        sta $03
        ldx #>(__CODE_SIZE__ + 255)
        ldy #0
copy:   lda ($00),y
        sta ($02),y
        iny
        bne copy
        inc $01
        inc $03
        dex
        bne copy
        jmp __CODE_RUN__

; Carry set on failure.  Every switch is restored before any branch into RAM.
auxtest:
        sta $C005               ; RAMWRT aux
        lda #$AA
        sta $0800
        sta $C004               ; RAMWRT main
        lda #$55
        sta $0800
        lda $0800
        cmp #$55
        jne axfail
        sta $C003               ; RAMRD aux: this code is in ROM, unaffected
        lda $0800
        cmp #$AA
        jne axfail_rd
        sta $C002
        lda #$11                ; ALTZP: the zero page moves, the stack with it
        sta $20
        sta $C009
        lda #$22
        sta $20
        lda $20
        cmp #$22
        jne axfail_zp
        sta $C008
        lda $20
        cmp #$11
        jne axfail
        sta $C001               ; 80STORE: PAGE2 steers the text page
        sta $C055
        lda #$BB
        sta $0400
        sta $C054
        lda #$CC
        sta $0400
        lda $0400
        cmp #$CC
        jne axfail_80
        sta $C055
        lda $0400
        cmp #$BB
        jne axfail_80
        sta $C054
        sta $C057               ; ...and with HIRES, the hires page too
        sta $C055
        lda #$DD
        sta $2000
        sta $C054
        lda #$EE
        sta $2000
        sta $C055
        lda $2000
        cmp #$DD
        jne axfail_80
        sta $C054
        sta $C056
        sta $C000
        lda $2000
        cmp #$EE
        jne axfail
        clc
        rts
axfail_80: sta $C054
        sta $C056
        sta $C000
        sec
        rts
axfail_rd: sta $C002
        sec
        rts
axfail_zp: sta $C008
        sec
        rts
axfail: sec
        rts

; The RamWorks: bank 0 is the regular auxiliary memory auxtest just used,
; banks 1-3 are their own; a bank that does not exist is ignored; ALTZP's
; zero page follows the bank.  Carry set on failure; every switch and the
; bank register restored before any branch into RAM - and the stack is not
; touched while ALTZP is on, since the return address is on the main one.
rwtest:
        sta $C005               ; RAMWRT aux
        ldx #1
        stx $C073
        lda #$B1
        sta $0900               ; bank 1
        ldx #2
        stx $C073
        lda #$B2
        sta $0900               ; bank 2
        ldx #3
        stx $C071               ; the register's other address
        lda #$B3
        sta $0900               ; bank 3
        ldx #0
        stx $C073
        lda #$B0
        sta $0900               ; bank 0
        sta $C004               ; RAMWRT main
        sta $C003               ; RAMRD aux, still bank 0
        lda $0900
        cmp #$B0
        jne rwfail
        lda $0800               ; auxtest's $AA: bank 0 kept it through the others
        cmp #$AA
        jne rwfail
        ldx #2
        stx $C073
        lda $0900
        cmp #$B2
        jne rwfail
        ldx #$FF
        stx $C073               ; no such bank: ignored, still bank 2
        lda $0900
        cmp #$B2
        jne rwfail
        ldx #3
        stx $C073
        lda $0900
        cmp #$B3
        jne rwfail
        ldx #1
        stx $C071
        lda $0900
        cmp #$B1
        jne rwfail
        sta $C002               ; RAMRD main
        sta $C009               ; ALTZP: the zero page is bank 1's now
        lda #$C1
        sta $30
        ldx #3
        stx $C073
        lda #$C3
        sta $30                 ; bank 3's zero page
        ldx #1
        stx $C073
        lda $30
        cmp #$C1
        jne rwfail_zp
        ldx #3
        stx $C073
        lda $30
        cmp #$C3
        jne rwfail_zp
        sta $C008               ; ALTZP off
        ldx #0
        stx $C073
        clc
        rts
rwfail_zp:
        sta $C008
rwfail: sta $C002
        ldx #0
        stx $C073
        sec
        rts

.segment "VECTORS"
        .word reset, reset, reset
