; SPDX-License-Identifier: GPL-2.0-or-later
; SPDX-FileCopyrightText: 2026 jtflanagan
;
; BUSTEST - a 65C02 exerciser written to be WATCHED, not to pass.
;
; WHAT IT IS FOR.  sim/run_trace_replay.sh compares rtl/cpu65c02.sv against a
; real 65C02 cycle by cycle, using a bus trace captured from a running Apple II.
; A trace of the monitor's idle loop answers only the questions the monitor
; happens to ask: the first capture covered eleven distinct dummy-cycle sites
; because that is all the keyboard loop reaches.  This program is the other
; half - it executes every opcode the part has, and every page-sensitive
; addressing mode in BOTH its same-page and page-crossing forms, so the trace
; contains the whole instruction set rather than a sample of it.
;
; IT IS NOT SELF-CHECKING, deliberately.  Klaus Dormann's suites already prove
; the core computes the right answers, and they run in simulation in seconds.
; What no simulation can produce is the address a real chip drives during a
; cycle whose value it discards, so the only thing this program has to do is
; EXECUTE - correctly, deterministically, and without touching anything that
; would change what happens next.  The comparison is the check.
;
; VARIANT: base 65C02, assembled as 65SC02 so the assembler REFUSES Rockwell's
; RMB/SMB/BBR/BBS.  The chip in this machine is a first-generation part without
; them, and an exerciser that quietly assembled one would be testing an
; instruction the hardware answers as a NOP.  Their encodings are still
; executed, as raw bytes, in the NOP section - because "does nothing, in one
; cycle, without taking an operand" is itself behaviour worth capturing.
;
; WHAT IT AVOIDS, and why each matters on this machine:
;   $C000-$CFFF   I/O.  A READ there is not a read - it toggles soft switches,
;                 strobes the keyboard, and moves the machine underneath us.
;                 Nothing here goes near it.
;   $D000-$FFFF   ROM and the language card.  Writes are either ignored or bank
;                 switches, and neither is a thing to do by accident.
;   $9600-$BFFF   DOS 3.3.
;   $0100-$01FF   the stack, beyond balanced pushes and pops.
;   $03F0-$03FF   the vectors, after setup - they are how we got here.
;
; HOW IT IS ENTERED.  BRUN installs it and returns; pressing Ctrl-Reset then
; runs it, because install points the reset vector here.  That is not a
; convenience: swhost's capture ARMS on RES', so a trace only begins at a
; reset, and entering the program any other way produces a capture that starts
; from a state nothing can reproduce.  Ctrl-Reset both starts the recording and
; puts the machine in a known state, in one keystroke.

.setcpu "65SC02"

; ---- the machine ----------------------------------------------------------
SOFTEV  = $03F2                 ; warm-start vector, taken by Ctrl-Reset
PWREDUP = $03F4                 ; must be SOFTEV+1 EOR $A5 or reset cold-starts
BRKV    = $03F0                 ; the Autostart ROM's BRK vector
COUT    = $FDED
SCREEN  = $0400                 ; text page 1, line 0

; ---- our memory -----------------------------------------------------------
; $4000-$43FF is hi-res page 2. Nothing displays it here, and it is clear of
; DOS, of the text screen, and of the program itself.
DATA    = $4000
D_SAME  = DATA + $80            ; +$20 indexed stays inside the page
D_CROSS = DATA + $F0            ; +$20 indexed leaves it - the fixup cycle
WRAPPTR = DATA + $2FF           ; a JMP (abs) pointer ending at $xxFF

; Zero page.  Entered from reset with nothing else running, so this is ours -
; but stay above $10 anyway: the monitor's own reset path uses what is below,
; and $20-$4F is its text-window state.
;
; The allocations do not overlap, and that took a bug to get right: SCRATCH is
; reached as SCRATCH,X with X=4, so it occupies SIX bytes and not four.  COUNT
; sat on the fifth, so every pass rewrote the pass counter with the same value
; and the exerciser looked hung when it was running perfectly.
PZ_SAME = $10                   ; -> D_SAME          $10,$11
PZ_CROSS= $12                   ; -> D_CROSS         $12,$13
PZ_IDX  = $14                   ; -> D_SAME, via (zp,X)   $14,$15
WRAPDST = $16                   ; where the zero-page wrap test lands
SCRATCH = $18                   ; $18..$1D - four direct, plus indexed by 4
COUNT   = $1E                   ; passes, and the byte shown on screen

.org $6000

; ---------------------------------------------------------------------------
; A two-entry jump table at a fixed address, so nothing downstream has to parse
; a map file to find its way in.
;
;   $6000  install   what BRUN calls: arm the reset vector, print, return
;   $6003  test      the exerciser itself
;
; $6003 is what sim/run_bustest.sh points the reset vector at, and it is also
; there for a person with a monitor prompt and no disk: 6003G runs it.
; ---------------------------------------------------------------------------
        jmp install
        jmp test

; ===========================================================================
; install - what BRUN calls.  Arms the reset vector and gets out of the way.
; ===========================================================================
install:
        lda #<test
        sta SOFTEV
        lda #>test
        sta SOFTEV+1
        ; The power-up byte is how the Autostart ROM tells a warm start from a
        ; cold one. Without it Ctrl-Reset reboots the disk instead of coming
        ; here, and the trace captures a boot rather than this program.
        eor #$A5
        sta PWREDUP

        ldy #0
@msg:   lda banner,y
        beq @done
        jsr COUT
        iny
        bne @msg
@done:  rts

banner: .byte "BUSTEST INSTALLED - PRESS CTRL-RESET", $8D, $8D, 0

; ===========================================================================
; test - the reset vector lands here, and never leaves.
; ===========================================================================
test:
        sei                     ; nothing may interrupt a trace
        cld
        ldx #$FF
        txs

        lda #<our_brk
        sta BRKV
        lda #>our_brk
        sta BRKV+1

        jsr setup

mainloop:
        jsr sec_imm
        jsr sec_zp
        jsr sec_zpidx
        jsr sec_abs
        jsr sec_absidx
        jsr sec_indirect
        jsr sec_rmw
        jsr sec_stack
        jsr sec_flags
        jsr sec_bits
        jsr sec_transfer
        jsr sec_branch
        jsr sec_jump
        jsr sec_rti
        jsr sec_nops
        jsr sec_brk

        ; A visible sign of life, and a marker in the trace: one write to the
        ; top-left of the screen per pass.
        inc COUNT
        lda COUNT
        ora #$80
        sta SCREEN
        jmp mainloop

; ---------------------------------------------------------------------------
; setup - deterministic data, so every pass drives the same addresses.
; ---------------------------------------------------------------------------
setup:
        lda #<D_SAME
        sta PZ_SAME
        lda #>D_SAME
        sta PZ_SAME+1
        lda #<D_CROSS
        sta PZ_CROSS
        lda #>D_CROSS
        sta PZ_CROSS+1
        lda #<D_SAME
        sta PZ_IDX
        lda #>D_SAME
        sta PZ_IDX+1

        ; Fill four pages with something that is neither all zeros nor all
        ; ones, so a wrong address reads a wrong value rather than the same
        ; value by luck.
        ldx #0
@fill:  txa
        eor #$5A
        sta DATA,x
        sta DATA+$100,x
        sta DATA+$200,x
        sta DATA+$300,x
        inx
        bne @fill

        ; AFTER the fill, and the order is not incidental: WRAPPTR lives at
        ; $42FF, inside the range above, so setting it first means setting it
        ; and then erasing it.  That put $5AA5 in the pointer and sent
        ; JMP (WRAPPTR) into the weeds - found by sim/run_bustest.sh, which is
        ; what it is for.
        ;
        ; The pointer's low byte sits at $xxFF on purpose.  The NMOS part
        ; fetches the high byte from $xx00 - the same page, wrapped - and the
        ; CMOS part carries into the next page instead and charges a sixth
        ; cycle for it.
        lda #<jmp_wrap_target
        sta WRAPPTR
        lda #>jmp_wrap_target
        sta WRAPPTR+1

        stz COUNT
        rts

; ---------------------------------------------------------------------------
; immediate - one operand byte, no addressing to get wrong. The baseline.
; ---------------------------------------------------------------------------
sec_imm:
        lda #$3C
        ldx #$5A
        ldy #$A5
        and #$F0
        ora #$0F
        eor #$55
        clc
        adc #$11
        sec
        sbc #$07
        cmp #$40
        cpx #$5A
        cpy #$A5
        bit #$80                ; 65C02 only: immediate BIT sets Z alone
        bit #$7F
        rts

; ---------------------------------------------------------------------------
; zero page - every access shape, one page, no indexing.
; ---------------------------------------------------------------------------
sec_zp:
        lda #$C3
        sta SCRATCH
        stx SCRATCH+1
        sty SCRATCH+2
        stz SCRATCH+3
        lda SCRATCH
        ldx SCRATCH+1
        ldy SCRATCH+2
        and SCRATCH
        ora SCRATCH+1
        eor SCRATCH+2
        clc
        adc SCRATCH
        sec
        sbc SCRATCH+1
        cmp SCRATCH
        cpx SCRATCH+1
        cpy SCRATCH+2
        bit SCRATCH
        inc SCRATCH
        dec SCRATCH
        asl SCRATCH
        lsr SCRATCH
        rol SCRATCH
        ror SCRATCH
        rts

; ---------------------------------------------------------------------------
; zero-page indexed - including the wrap, which is a behaviour and not an edge
; case: $F0 + $20 is $10, in the page, and never $0110.
; ---------------------------------------------------------------------------
sec_zpidx:
        ldx #$04
        ldy #$04
        lda #$77
        sta SCRATCH,x
        stz SCRATCH,x
        sty SCRATCH,x
        lda SCRATCH,x
        ldy SCRATCH,x
        and SCRATCH,x
        ora SCRATCH,x
        eor SCRATCH,x
        clc
        adc SCRATCH,x
        sec
        sbc SCRATCH,x
        cmp SCRATCH,x
        bit SCRATCH,x           ; 65C02 only
        inc SCRATCH,x
        dec SCRATCH,x
        asl SCRATCH,x
        lsr SCRATCH,x
        rol SCRATCH,x
        ror SCRATCH,x

        ldx SCRATCH,y           ; zp,Y - only LDX and STX have it
        stx SCRATCH,y

        ; The wrap, which is a behaviour rather than an edge case: $F0 + $26 is
        ; $116, and a 6502 addresses $16 - inside the page - never $0116.  The
        ; index is chosen so the access lands on WRAPDST and on nothing else.
        ldx #$26
        lda $F0,x
        sta $F0,x
        ldx #$04
        rts

; ---------------------------------------------------------------------------
; absolute - three-byte addressing, no index, nothing to cross.
; ---------------------------------------------------------------------------
sec_abs:
        lda #$1E
        sta D_SAME
        stx D_SAME+1
        sty D_SAME+2
        stz D_SAME+3
        lda D_SAME
        ldx D_SAME+1
        ldy D_SAME+2
        and D_SAME
        ora D_SAME+1
        eor D_SAME+2
        clc
        adc D_SAME
        sec
        sbc D_SAME+1
        cmp D_SAME
        cpx D_SAME+1
        cpy D_SAME+2
        bit D_SAME
        inc D_SAME
        dec D_SAME
        asl D_SAME
        lsr D_SAME
        rol D_SAME
        ror D_SAME
        rts

; ---------------------------------------------------------------------------
; absolute indexed - the section this program exists for.
;
; Every form is done TWICE: once from D_SAME, where base+index stays inside the
; page, and once from D_CROSS, where it does not.  The difference is a whole
; cycle on a read, and on that cycle the part drives an address that no
; functional test can see.  The write forms pay it either way, which is its own
; thing to capture: a store crossing no boundary still takes the fixup cycle.
; ---------------------------------------------------------------------------
sec_absidx:
        ldx #$20
        ldy #$20

        ; --- inside the page ---
        lda D_SAME,x
        lda D_SAME,y
        ldy D_SAME,x
        ldx D_SAME,y
        ldy #$20
        and D_SAME,x
        ora D_SAME,x
        eor D_SAME,x
        clc
        adc D_SAME,x
        sec
        sbc D_SAME,x
        cmp D_SAME,x
        bit D_SAME,x            ; 65C02 only
        and D_SAME,y
        ora D_SAME,y
        eor D_SAME,y
        clc
        adc D_SAME,y
        sec
        sbc D_SAME,y
        cmp D_SAME,y
        sta D_SAME,x
        sta D_SAME,y
        stz D_SAME,x

        ; --- across it ---
        lda D_CROSS,x
        lda D_CROSS,y
        ldy D_CROSS,x
        ldx D_CROSS,y
        ldx #$20
        ldy #$20
        and D_CROSS,x
        ora D_CROSS,x
        eor D_CROSS,x
        clc
        adc D_CROSS,x
        sec
        sbc D_CROSS,x
        cmp D_CROSS,x
        bit D_CROSS,x
        and D_CROSS,y
        ora D_CROSS,y
        eor D_CROSS,y
        clc
        adc D_CROSS,y
        sec
        sbc D_CROSS,y
        cmp D_CROSS,y
        sta D_CROSS,x
        sta D_CROSS,y
        stz D_CROSS,x

        ; Read-modify-write indexed. INC/DEC abs,X are a flat 7 cycles; the
        ; shifts are 6 or 7 depending on the crossing, which is exactly the
        ; distinction worth having both cases for.
        inc D_SAME,x
        dec D_SAME,x
        asl D_SAME,x
        lsr D_SAME,x
        rol D_SAME,x
        ror D_SAME,x
        inc D_CROSS,x
        dec D_CROSS,x
        asl D_CROSS,x
        lsr D_CROSS,x
        rol D_CROSS,x
        ror D_CROSS,x
        rts

; ---------------------------------------------------------------------------
; indirect - the pointer is in zero page, so the effective address is built
; from memory rather than from the instruction. (zp),Y crosses or does not
; depending on the pointer, so both pointers get used.
; ---------------------------------------------------------------------------
sec_indirect:
        ldx #$00                ; (zp,X) with X=0 is the plain pointer
        ldy #$20

        lda (PZ_IDX,x)
        and (PZ_IDX,x)
        ora (PZ_IDX,x)
        eor (PZ_IDX,x)
        clc
        adc (PZ_IDX,x)
        sec
        sbc (PZ_IDX,x)
        cmp (PZ_IDX,x)
        sta (PZ_IDX,x)

        ; (zp),Y inside the page
        lda (PZ_SAME),y
        and (PZ_SAME),y
        ora (PZ_SAME),y
        eor (PZ_SAME),y
        clc
        adc (PZ_SAME),y
        sec
        sbc (PZ_SAME),y
        cmp (PZ_SAME),y
        sta (PZ_SAME),y

        ; (zp),Y across it
        lda (PZ_CROSS),y
        and (PZ_CROSS),y
        ora (PZ_CROSS),y
        eor (PZ_CROSS),y
        clc
        adc (PZ_CROSS),y
        sec
        sbc (PZ_CROSS),y
        cmp (PZ_CROSS),y
        sta (PZ_CROSS),y

        ; (zp) with no index at all - a 65C02 addition
        lda (PZ_SAME)
        and (PZ_SAME)
        ora (PZ_SAME)
        eor (PZ_SAME)
        clc
        adc (PZ_SAME)
        sec
        sbc (PZ_SAME)
        cmp (PZ_SAME)
        sta (PZ_SAME)
        rts

; ---------------------------------------------------------------------------
; read-modify-write on the accumulator, and INC A / DEC A which the NMOS part
; does not have.
; ---------------------------------------------------------------------------
sec_rmw:
        lda #$81
        asl a
        lsr a
        rol a
        ror a
        inc a                   ; 65C02 only
        dec a                   ; 65C02 only
        rts

; ---------------------------------------------------------------------------
; the stack. Balanced, and TXS is put back where it was found - an exerciser
; that loses the stack pointer takes the return address with it.
; ---------------------------------------------------------------------------
sec_stack:
        lda #$5C
        pha
        pla
        php
        plp
        phx                     ; 65C02 only
        plx
        phy                     ; 65C02 only
        ply
        tsx
        txs
        rts

; ---------------------------------------------------------------------------
; flags, and the one arithmetic case where the CMOS part takes an extra cycle:
; decimal ADC and SBC. D is cleared again immediately - leaving it set would
; quietly corrupt every later add.
; ---------------------------------------------------------------------------
sec_flags:
        clc
        sec
        clv
        cld
        sei
        cli
        sei                     ; straight back off: nothing may interrupt

        sed
        lda #$19
        clc
        adc #$08                ; decimal: the extra cycle
        sec
        sbc #$05
        adc D_SAME              ; and again from memory
        sbc D_SAME
        cld
        rts

; ---------------------------------------------------------------------------
; TRB and TSB - test-and-reset / test-and-set bits. 65C02 only, and read-modify-
; write, so they are three bus accesses to the same address.
; ---------------------------------------------------------------------------
sec_bits:
        lda #$0F
        sta SCRATCH
        lda #$03
        trb SCRATCH
        tsb SCRATCH
        sta D_SAME
        trb D_SAME
        tsb D_SAME
        rts

; ---------------------------------------------------------------------------
; register transfers. No memory, no addressing - here so the opcode is covered.
; ---------------------------------------------------------------------------
sec_transfer:
        lda #$33
        tax
        tay
        txa
        tya
        inx
        iny
        dex
        dey
        nop
        rts

; ---------------------------------------------------------------------------
; branches.
;
; Every condition is taken and not taken, and the taken ones are done both
; inside a page and across one.  A taken branch that crosses costs a fourth
; cycle, and on it the part drives the address the branch has NOT finished
; computing - the high byte is still the old one.  That address is one of the
; things this whole exercise exists to observe, so the crossings are not left
; to chance: each is checked by the ASSEMBLER, below, against the page of the
; instruction that follows the branch.  A layout edit that quietly stopped a
; branch from crossing would otherwise turn into a test that silently stopped
; testing.
; ---------------------------------------------------------------------------
sec_branch:
        ; --- not taken: two cycles, no address arithmetic at all ---
        lda #$01                ; Z clear, N clear
        clc
        clv
        beq @nt1
@nt1:   bmi @nt2
@nt2:   bvs @nt3
@nt3:   bcs @nt4
@nt4:   lda #$00                ; Z set
        bne @nt5
@nt5:   lda #$80                ; N set
        bpl @nt6
@nt6:   sec
        bcc @nt7
@nt7:   bit @vset               ; bit 6 of the operand -> V
        bvc @nt8
@nt8:
        ; --- taken, inside the page ---
        lda #$00
        beq @t1
        .byte $EA
@t1:    lda #$01
        bne @t2
        .byte $EA
@t2:    clc
        bcc @t3
        .byte $EA
@t3:    sec
        bcs @t4
        .byte $EA
@t4:    lda #$80
        bmi @t5
        .byte $EA
@t5:    lda #$01
        bpl @t6
        .byte $EA
@t6:    clv
        bvc @t7
        .byte $EA
@t7:    bit @vset
        bvs @t8
        .byte $EA
@t8:    bra @t9                 ; 65C02 only, and always taken
        .byte $EA
@t9:    .assert >(@t9) = >(@t8+2), error, "same-page branches must not cross"
        jmp brcross

@vset:  .byte $40               ; bit 6 set: BIT puts it in V

; The crossing branches sit at the very top of their page, so that a short
; forward offset lands in the next one - and a second set sits just past the
; boundary and branches BACKWARD across it, because the fixup cycle moves PCH
; in both directions and only one of them is exercised by branching forward.
;
; The blocks are packed against $7000 by hand.  Each branch is TAKEN, so
; control never falls out of a block; each target jumps to the next.  Every
; crossing is checked by .assert, so this layout cannot rot silently.
; The boundary is COMPUTED, not written down.  It used to be $7000, which sat
; three kilobytes past the end of the code and padded the binary out to 4265
; bytes of mostly $EA.  The next page boundary after the code does the same job
; and the program is 1449 bytes, with byte-identical behaviour - the padding was
; never buying anything but a longer load.
XBASE = (* + $FF) & $FF00       ; the next page boundary at or after here
XB    = XBASE + $100            ; ...and the one after that, which is crossed

        .res XBASE + $E0 - *, $EA

yt1:    jmp yb2                 ; XB-$20 - a backward branch's landing site
yt2:    rts                     ; XB-$1D

        .res XBASE + $EC - *, $EA

brcross:
        clc                     ; XB-$14
        bcc xt1
        .assert >(xt1) <> >(*), error, "BCC must cross a page"
xb:     sec
        bcs xt2
        .assert >(xt2) <> >(*), error, "BCS must cross a page"
xc:     lda #$00
        beq xt3
        .assert >(xt3) <> >(*), error, "BEQ must cross a page"
xd:     lda #$01
        bne xt4
        .assert >(xt4) <> >(*), error, "BNE must cross a page"
xe:     bra xt5
        .assert >(xt5) <> >(*), error, "BRA must cross a page"

        .res XB - *, $EA

xt1:    jmp xb                  ; XB
xt2:    jmp xc
xt3:    jmp xd
xt4:    jmp xe
xt5:    jmp yb1

yb1:    clc
        bcc yt1                 ; backward, and across
        .assert >(yt1) <> >(*), error, "backward BCC must cross a page"
yb2:    lda #$00
        beq yt2                 ; backward, and across
        .assert >(yt2) <> >(*), error, "backward BEQ must cross a page"

; ---------------------------------------------------------------------------
; jumps.
;
; JMP (abs) is here for one reason above the others: the sixth cycle.  The NMOS
; part fetches the high byte of a pointer ending in $FF from $xx00 - the same
; page, wrapped - and the CMOS part fixed it and charged a cycle for the fix.
; So the pointer at WRAPPTR is deliberately at $42FF, and a core that wraps
; instead of carrying will jump somewhere else entirely and the trace will say
; so on the very next cycle.
; ---------------------------------------------------------------------------
sec_jump:
        jmp @j1
@j1:    jmp (jmp_ptr)
jmp_back1:
        ldx #$02
        jmp (jmp_tab,x)         ; 65C02 only
jmp_back2:
        jmp (WRAPPTR)           ; the pointer that ends at $xxFF
jmp_wrap_target:
        jsr @sub
        rts
@sub:   rts

jmp_ptr:  .word jmp_back1
jmp_tab:  .word $FFFF           ; index 0, never taken
          .word jmp_back2       ; index 2

; ---------------------------------------------------------------------------
; RTI, from an interrupt frame we build ourselves.
;
; RTI pulls the status byte and then the return address, and unlike RTS it does
; not add one - so the address pushed is the exact destination.  The status is
; $34: I stays SET, because an exerciser that re-enabled interrupts halfway
; through a capture would be handing the trace to whatever asks next.
; ---------------------------------------------------------------------------
sec_rti:
        lda #>@back
        pha
        lda #<@back
        pha
        lda #$34
        pha
        rti
@back:  rts

; ---------------------------------------------------------------------------
; the undefined encodings.
;
; Not filler.  On the base part these are NOPs of three different shapes, and
; which shape is a fact about the chip: $x3/$x7/$xB/$xF take no operand and one
; cycle, $02 and friends take an operand byte, and $5C takes two and spends
; EIGHT cycles doing nothing - five of them driving addresses that this project
; has never verified.  They are emitted as raw bytes because the assembler,
; correctly, refuses to write them as instructions.
;
; $x7 and $xF are where Rockwell put RMB/SMB and BBR/BBS, and $CB and $DB are
; WDC's WAI and STP.  This part has none of them, so here they are NOPs - and
; executing them is how the trace proves it.
; ---------------------------------------------------------------------------
sec_nops:
        ; one byte, one cycle
        .byte $03, $13, $23, $33, $43, $53, $63, $73
        .byte $83, $93, $A3, $B3, $C3, $D3, $E3, $F3
        .byte $07, $17, $27, $37, $47, $57, $67, $77
        .byte $87, $97, $A7, $B7, $C7, $D7, $E7, $F7
        .byte $0B, $1B, $2B, $3B, $4B, $5B, $6B, $7B
        .byte $8B, $9B, $AB, $BB, $CB, $DB, $EB, $FB
        .byte $0F, $1F, $2F, $3F, $4F, $5F, $6F, $7F
        .byte $8F, $9F, $AF, $BF, $CF, $DF, $EF, $FF

        ; two bytes
        .byte $02, $EA
        .byte $22, $EA
        .byte $42, $EA
        .byte $62, $EA
        .byte $82, $EA
        .byte $C2, $EA
        .byte $E2, $EA
        .byte $44, $10          ; 2 bytes, 3 cycles - reads zero page
        .byte $54, $10          ; 2 bytes, 4 cycles
        .byte $D4, $10
        .byte $F4, $10

        ; three bytes.  $5C is the eight-cycle one.
        .byte $5C, $00, $40
        .byte $DC, $00, $40
        .byte $FC, $00, $40
        rts

; ---------------------------------------------------------------------------
; BRK - last in the pass, and the only thing here that can derail a capture.
;
; It vectors through ROM to the Autostart monitor, which saves the registers
; and then jumps through $03F0.  We point that at our own handler, so control
; comes back.  If this machine's ROM does not honour $03F0, the monitor takes
; over instead: the screen shows its prompt, the loop stops, and the capture
; ends early - which is a visible failure and not a silent one.  It runs last
; so that a pass which dies here has already executed everything else.
;
; The handler does not try to unwind whatever the ROM pushed.  It puts the
; stack pointer back where it was before the BRK and jumps to the continuation,
; which is correct no matter what the ROM did in between.
; ---------------------------------------------------------------------------
sec_brk:
        tsx
        stx save_s
        brk
        .byte $EA               ; BRK's signature byte, skipped by the return
brk_back:
        rts

our_brk:
        ldx save_s
        txs
        jmp brk_back

save_s: .byte 0

.assert * < $9600, error, "BUSTEST has grown into DOS"
