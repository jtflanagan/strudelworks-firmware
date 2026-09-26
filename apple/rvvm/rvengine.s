; SPDX-License-Identifier: GPL-2.0-or-later
; SPDX-FileCopyrightText: 2026 jtflanagan
;
; rvengine - the 65816 side of the RISC-V ENGINE (docs/REQ_RVVM.md section 9;
; rtl/gs/rv_engine.sv).  The engine executes the instructions and holds the
; RISC-V state; this program runs the step loop and does what the engine hands
; back: the ECALL services, the loads, stores and fetches it delegates
; (integration's rung 1 delegates all of them), and the monitor on a trap.
; There is no software VM on riscv_v2: the engine addresses 32 MB and the 65816
; reaches only the lower 16, so the engine is the only way a guest runs.
;
; THE WINDOW is $EF:FE00-$EF:FEFF (rv_engine's header).  DBR is $EF throughout,
; so a window register is an absolute address; guest memory is reached by long
; pointers in the direct page, the sim's ports by long addresses.
;
; THE HOT LOOP is 8-bit and absolute: `lda a:RUN` / `beq` - the read stalls
; while the engine runs, and 0 means it yielded (an interrupt to take, or its
; slice spent: REQ_RVVM "RUN") - and any other result is the event table's
; index.  An engine of version 1 has no RUN: the same loop reads STEP.
;
; The header and the verdict in the direct page (CODE, STATUS, CAUSE, TVAL)
; are the old software VM's (rvvm.s, left on the `riscv` branch); header version 3
; says "the engine's", and the harness holds the ENGINE in lockstep.

        .setcpu "65816"
        .smart  +

; ---- the window -------------------------------------------------------------------
WIN     = $FE00
WX      = WIN               ; x0..x31, 4 bytes each
WPC     = WIN + $80
STEP    = WIN + $84
RUN     = WIN + $85
RESUME  = WIN + $86
EVADDR  = WIN + $88
EVIW    = WIN + $8C
EVDATA  = WIN + $90
RVAL    = WIN + $94
WID     = WIN + $98
; the registers the services use, as window addresses
WA0     = WX + 10 * 4
WA1     = WX + 11 * 4
WA2     = WX + 12 * 4
WA7     = WX + 17 * 4

; ---- the engine's result codes (rv_core) ------------------------------------------
E_ECALL  = 2
E_FFAULT = 12

; ---- the direct page -----------------------------------------------------------------
PTR     = $00           ; a long pointer into guest memory (4)
TGT     = $04           ; a cursor (4)
CNT     = $08           ; a count (4)
REM     = $0C           ; bytes moved (4)
STRP    = $10           ; string long pointer for the monitor (4)
TV      = $14           ; scratch for printing (4)
RUNM    = $18           ; nonzero: the engine has RUN (version 2 and up)
CODE    = $C0           ; exit code (4)       - the harness reads these four
STATUS  = $C4           ; 0 running, 1 exit, 2 trap
CAUSE   = $C6           ; trap cause
TVAL    = $C8           ; trap value (4)

ALIM    = $0100
GUARD   = $0100

T_ILLEGAL = 1
T_EBREAK  = 2
T_LOAD    = 3
T_STORE   = 4
T_FETCH   = 5

PORT_PUTC  = $EFFFE0
PORT_GETC  = $EFFFE1
PORT_AVAIL = $EFFFE2
PORT_CYC   = $EFFFE4

        .segment "HEADER"
hdr:        .byte   "RVVM"
            .word   3                       ; version 3: the engine's VM
            .word   .loword(entry)
            .word   .loword(loop)           ; the step loop
            .byte   0, 0
hdr_pc:     .dword  $800000                 ; the guest's entry pc (the loader's)
hdr_sp:     .dword  0                       ; the guest's initial sp; 0 = $E00000

        .segment "CODE"

; ---- entry ------------------------------------------------------------------------------
; Arrives native (the caller did CLC/XCE), M/X unknown.
entry:  rep     #$30
        .a16
        .i16
        lda     #$01FF
        tcs
        lda     #$0000
        tcd
        ldx     #$00FE
:       stz     0,x
        dex
        dex
        bpl     :-
        sep     #$20
        .a8
        lda     #$EF
        pha
        plb                             ; DBR = $EF: the window is absolute
        rep     #$20
        .a16
        lda     a:WID                   ; is the engine there?
        cmp     #('V' << 8) | 'R'
        beq     @eng
        lda     #.loword(s_noeng)
        jsr     puts
        lda     #T_ILLEGAL
        sta     CAUSE
        lda     #2
        sta     STATUS
        stp
@eng:   lda     a:WID+2                 ; "E", the version: RUN from version 2
        and     #$FF00
        cmp     #$0200
        bcc     :+
        inc     RUNM
:       ldx     #4                      ; x1..x31 = 0 (the register file has no reset)
:       stz     a:WX,x
        stz     a:WX+2,x
        inx
        inx
        inx
        inx
        cpx     #$80
        bne     :-
        lda     f:hdr_sp                ; sp: the header's, or $E00000
        ora     f:hdr_sp+2
        bne     :+
        lda     #$00E0
        sta     a:WX+2*4+2
        bra     @pc
:       lda     f:hdr_sp
        sta     a:WX+2*4
        lda     f:hdr_sp+2
        sta     a:WX+2*4+2
@pc:    lda     f:hdr_pc
        sta     a:WPC
        lda     f:hdr_pc+2
        sta     a:WPC+2

; ---- the step loop -------------------------------------------------------------------
loop:   sep     #$20
        .a8
        lda     RUNM
        beq     @s
@r:     lda     a:RUN
        beq     @r
        bra     @ev
@s:     lda     a:STEP
        beq     @s
@ev:    rep     #$30
        .a16
        and     #$00FF
        tax
        jmp     (.loword(evtab),x)

; PTR = the event's address (a long pointer: the identity map).
evptr:  lda     a:EVADDR
        sta     PTR
        lda     a:EVADDR+2
        sta     PTR+2
        rts

; ---- delegated fetch, loads and stores --------------------------------------------
ev_fetch:
        jsr     evptr
        lda     [PTR]
        sta     a:RVAL
        ldy     #2
        lda     [PTR],y
        sta     a:RVAL+2
resume: sta     a:RESUME
        jmp     loop

ev_lb:                                  ; lb and lbu: the engine extends
        jsr     evptr
        lda     [PTR]
        and     #$00FF
        sta     a:RVAL
        stz     a:RVAL+2
        bra     resume
ev_lh:  jsr     evptr
        lda     [PTR]
        sta     a:RVAL
        stz     a:RVAL+2
        bra     resume
ev_lw:  jsr     evptr
        lda     [PTR]
        sta     a:RVAL
        ldy     #2
        lda     [PTR],y
        sta     a:RVAL+2
        bra     resume
ev_sb:  jsr     evptr
        sep     #$20
        .a8
        lda     a:EVDATA
        sta     [PTR]
        rep     #$20
        .a16
        bra     resume
ev_sh:  jsr     evptr
        lda     a:EVDATA
        sta     [PTR]
        bra     resume
ev_sw:  jsr     evptr
        lda     a:EVDATA
        sta     [PTR]
        lda     a:EVDATA+2
        ldy     #2
        sta     [PTR],y
        bra     resume

; ---- ECALL: a7 = the service (Linux/newlib numbers; rvvm's own from $5000) --------
ev_ecall:
        lda     a:WA7+2
        bne     enosys
        lda     a:WA7
        cmp     #93
        bne     :+
        jmp     sys_exit
:       cmp     #64
        bne     :+
        jmp     sys_write
:       cmp     #63
        bne     :+
        jmp     sys_read
:       cmp     #$5000
        bne     :+
        jmp     sys_cycles
:       cmp     #$5001
        bne     :+
        jmp     sys_peek
:       cmp     #$5002
        bne     enosys
        jmp     sys_poke
enosys: lda     #$FFDA                  ; -38, ENOSYS
ret_neg:
        sta     a:WA0
        lda     #$FFFF
        sta     a:WA0+2
        jmp     resume
ebadf:  lda     #$FFF7                  ; -9, EBADF
        bra     ret_neg
ret_a:  sta     a:WA0                   ; a0 = A, zero-extended
        stz     a:WA0+2
        jmp     resume

sys_exit:
        lda     a:WA0
        sta     CODE
        sta     TV
        lda     a:WA0+2
        sta     CODE+2
        sta     TV+2
        lda     #1
        sta     STATUS
        lda     #.loword(s_exit)        ; the verdict on the console too (a bench
        jsr     puts                    ; that cannot read the direct page reads it)
        jsr     puttv
        lda     #.loword(s_nl)
        jsr     puts
        jmp     plat_halt

sys_cycles:
        lda     f:PORT_CYC
        sta     a:WA0
        lda     f:PORT_CYC+2
        sta     a:WA0+2
        lda     f:PORT_CYC+4
        sta     a:WA1
        lda     f:PORT_CYC+6
        sta     a:WA1+2
        jmp     resume

; PTR = the guest byte at TGT; C set when off the space or in the null guard.
cur_mp: lda     TGT
        sta     PTR
        lda     TGT+2
        sta     PTR+2
        cmp     #ALIM
        bcs     @no
        cmp     #1
        bcs     @ok
        lda     TGT
        cmp     #GUARD
        bcc     @no
@ok:    clc
        rts
@no:    sec
        rts
; TGT += 1, CNT -= 1.
cursor: inc     TGT
        bne     :+
        inc     TGT+2
:       lda     CNT
        bne     :+
        dec     CNT+2
:       dec     CNT
        rts
; TGT = a1, CNT = a2.
args12: lda     a:WA1
        sta     TGT
        lda     a:WA1+2
        sta     TGT+2
        lda     a:WA2
        sta     CNT
        lda     a:WA2+2
        sta     CNT+2
        rts
; A fault in a service: the engine's pc stays on the ECALL.
cur_fault:
        pha
        lda     TGT
        sta     TVAL
        lda     TGT+2
        sta     TVAL+2
        pla
        jmp     trap

sys_write:
        lda     a:WA0+2
        bne     :+
        lda     a:WA0
        cmp     #1
        beq     @ok
        cmp     #2
        beq     @ok
:       jmp     ebadf
@ok:    jsr     args12
@l:     lda     CNT
        ora     CNT+2
        beq     @d
        jsr     cur_mp
        bcs     @bad
        sep     #$20
        .a8
        lda     [PTR]
        jsr     plat_putc
        rep     #$20
        .a16
        jsr     cursor
        bra     @l
@d:     lda     a:WA2
        sta     a:WA0
        lda     a:WA2+2
        sta     a:WA0+2
        jmp     resume
@bad:   lda     #T_LOAD
        bra     cur_fault

sys_read:
        lda     a:WA0+2
        ora     a:WA0
        beq     :+
        jmp     ebadf
:       jsr     args12
        stz     REM
        stz     REM+2
@l:     lda     CNT
        ora     CNT+2
        beq     @d
        jsr     plat_avail
        bcs     @d
        jsr     cur_mp
        bcs     @bad
        sep     #$20
        .a8
        jsr     plat_getc
        sta     [PTR]
        rep     #$20
        .a16
        inc     REM
        bne     :+
        inc     REM+2
:       jsr     cursor
        bra     @l
@d:     lda     REM
        sta     a:WA0
        lda     REM+2
        sta     a:WA0+2
        jmp     resume
@bad:   lda     #T_STORE
        jmp     cur_fault

; peek(a0 = addr, a1 = width) / poke(a0 = addr, a1 = value, a2 = width):
; anywhere below $0100_0000, the guard included; a bad width does nothing
; (peek 0, poke -22).
pk_mp:  lda     a:WA0
        sta     PTR
        sta     TGT
        lda     a:WA0+2
        sta     PTR+2
        sta     TGT+2
        cmp     #ALIM
        rts
sys_peek:
        jsr     pk_mp
        bcc     :+
        lda     #T_LOAD
        jmp     cur_fault
:       lda     a:WA1+2
        bne     @zero
        lda     a:WA1
        cmp     #1
        beq     @b
        cmp     #2
        beq     @h
        cmp     #4
        bne     @zero
        lda     [PTR]
        sta     a:WA0
        ldy     #2
        lda     [PTR],y
        sta     a:WA0+2
        jmp     resume
@h:     lda     [PTR]
        jmp     ret_a
@b:     lda     [PTR]
        and     #$00FF
        jmp     ret_a
@zero:  lda     #0
        jmp     ret_a
sys_poke:
        jsr     pk_mp
        bcc     :+
        lda     #T_STORE
        jmp     cur_fault
:       lda     a:WA2+2
        bne     @inval
        lda     a:WA2
        cmp     #1
        beq     @b
        cmp     #2
        beq     @h
        cmp     #4
        bne     @inval
        lda     a:WA1
        sta     [PTR]
        lda     a:WA1+2
        ldy     #2
        sta     [PTR],y
        bra     @ok
@h:     lda     a:WA1
        sta     [PTR]
        bra     @ok
@b:     sep     #$20
        .a8
        lda     a:WA1
        sta     [PTR]
        rep     #$20
        .a16
@ok:    lda     #0
        jmp     ret_a
@inval: lda     #$FFEA                  ; -22, EINVAL
        jmp     ret_neg

; ---- the engine's traps -> the monitor ----------------------------------------------
ev_ebreak:
        lda     #T_EBREAK
        bra     ev_trap
ev_ill: lda     #T_ILLEGAL
        bra     ev_trap
ev_lf:  lda     #T_LOAD
        bra     ev_trap
ev_sf:  lda     #T_STORE
        bra     ev_trap
ev_ff:  lda     #T_FETCH
ev_trap:
        pha
        lda     a:EVADDR
        sta     TVAL
        lda     a:EVADDR+2
        sta     TVAL+2
        pla
; A = cause, TVAL set; the engine's pc is the instruction's.
trap:   sta     CAUSE
        lda     #2
        sta     STATUS
        lda     #.loword(s_trap)
        jsr     puts
        lda     CAUSE
        dec
        asl
        tax
        lda     f:causes,x
        jsr     puts
        lda     #.loword(s_pc)
        jsr     puts
        lda     a:WPC
        sta     TV
        lda     a:WPC+2
        sta     TV+2
        jsr     puttv
        lda     #.loword(s_tval)
        jsr     puts
        lda     TVAL
        sta     TV
        lda     TVAL+2
        sta     TV+2
        jsr     puttv
        lda     #.loword(s_iw)
        jsr     puts
        lda     a:EVIW
        sta     TV
        lda     a:EVIW+2
        sta     TV+2
        jsr     puttv
        ldx     #0
@r:     phx
        txa
        and     #$000C
        bne     :+
        lda     #.loword(s_nl)
        jsr     puts
:       lda     #.loword(s_sp)
        jsr     puts
        plx
        lda     a:WX,x
        sta     TV
        lda     a:WX+2,x
        sta     TV+2
        phx
        jsr     puttv
        plx
        inx
        inx
        inx
        inx
        cpx     #$80
        bne     @r
        lda     #.loword(s_nl)
        jsr     puts
        jmp     plat_halt

; ---- printing ----------------------------------------------------------------------------
puts:   sta     STRP
        phk
        sep     #$20
        .a8
        pla
        sta     STRP+2
        ldy     #0
@l:     lda     [STRP],y
        beq     @d
        jsr     plat_putc
        iny
        bra     @l
@d:     rep     #$20
        .a16
        rts
puttv:  sep     #$20                    ; TV as 8 hex digits
        .a8
        lda     TV+3
        jsr     puthex8
        lda     TV+2
        jsr     puthex8
        lda     TV+1
        jsr     puthex8
        lda     TV
        jsr     puthex8
        rep     #$20
        .a16
        rts
        .a8
puthex8:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr     @nib
        pla
        and     #$0F
@nib:   cmp     #10
        bcc     :+
        adc     #6
:       adc     #'0'
        jmp     plat_putc
        .a16

; ---- the platform: the sim's ports ---------------------------------------------------
        .a8
plat_putc:
        sta     f:PORT_PUTC
        rts
plat_getc:
        lda     f:PORT_GETC
        rts
        .a16
plat_avail:
        sep     #$20
        .a8
        lda     f:PORT_AVAIL
        rep     #$20
        .a16
        and     #$00FF
        beq     :+
        clc
        rts
:       sec
        rts
plat_halt:
        stp

        .segment "RODATA"
s_noeng: .byte  "rvengine: no RISC-V engine at $EF:FE00", 10, 0
s_exit: .byte   10, "rvvm: exit ", 0
s_trap: .byte   "rvvm: trap: ", 0
s_pc:   .byte   " pc=", 0
s_tval: .byte   " tval=", 0
s_iw:   .byte   " inst=", 0
s_sp:   .byte   " ", 0
s_nl:   .byte   10, 0
c_ill:  .byte   "illegal instruction", 0
c_ebr:  .byte   "ebreak", 0
c_ld:   .byte   "load fault", 0
c_st:   .byte   "store fault", 0
c_fe:   .byte   "fetch fault", 0
causes: .word   .loword(c_ill), .loword(c_ebr), .loword(c_ld), .loword(c_st), .loword(c_fe)

; The engine's result code (even, under 32) to its handler.
evtab:  .word   .loword(loop)           ;  0 NEXT (never here)
        .word   .loword(ev_ecall)       ;  2
        .word   .loword(ev_ebreak)      ;  4
        .word   .loword(ev_ill)         ;  6
        .word   .loword(ev_lf)          ;  8
        .word   .loword(ev_sf)          ; 10
        .word   .loword(ev_ff)          ; 12
        .word   .loword(ev_lb)          ; 14 lb
        .word   .loword(ev_lb)          ; 16 lbu
        .word   .loword(ev_lh)          ; 18 lh
        .word   .loword(ev_lh)          ; 20 lhu
        .word   .loword(ev_lw)          ; 22 lw
        .word   .loword(ev_sb)          ; 24 sb
        .word   .loword(ev_sh)          ; 26 sh
        .word   .loword(ev_sw)          ; 28 sw
        .word   .loword(ev_fetch)       ; 30 fetch
