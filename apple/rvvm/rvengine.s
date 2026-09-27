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
WSTAT   = WIN + $9C     ; bit 1: an event pending
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

; THE FIXED DOORS for GS/OS applications backed by RISC-V (docs/RVV2_INTEROP.md).
; A stub checks "RVVM" at $F1:0000, then JSLs $F1:0020 - an address that never
; moves, so a stub needs no relocation.  $F1:0030 is a QuitGS parameter block
; with pCount 0; a zeroed bank (no runtime) reads the same there, so a stub can
; quit through it either way.
            .res    $20 - (* - hdr)
app_door:   jml     app_entry               ; $F1:0020
            .res    $30 - (* - hdr)
quit_pb:    .word   0                       ; $F1:0030: QuitGS, pCount 0

        .segment "CODE"

; ---- a GS/OS application's lifecycle (docs/RVV2_INTEROP.md, rungs I2-I3) --------------
; From a stub's JSL $F1:0020: A = the application's user ID, X/Y = its header's
; address (X the low word, Y the bank), D/S the stub's direct page and stack
; (its ~Direct segment), which are the runtime's while the application runs.
; Returns (RTL) with A = the exit code's low word, D and S as they came, B
; restored; the stub then quits.
;
;   register in $EE -> TLStartUp, MMStartUp -> the low block (NewHandle) -> the
;   environment block and the start/stop record in it -> StartUpTools -> enhanced
;   video, if the header asks -> the program's file opened, its first chunk read,
;   its image header -> the upper-half banks it needs registered -> the engine
;   runs the loader (rt_loader, a0 = the environment block), which pulls the
;   rest of the file through the bounce buffer and enters the program -> and
;   everything undone in reverse (DONE says what was done).
;
; The direct page (the step loop's own at $00-$19 and $C0-$CB):
APPM    = $1A           ; nonzero: an application's run - no console, an exit returns
RUN_S   = $1C           ; S when the engine was started: an exit or a trap returns to it
UID     = $1E           ; the application's user ID
HDR     = $20           ; its header (4)
LOWH    = $24           ; the low block's handle (4)
LOWP    = $28           ; its address = the environment block (4)
RECP    = $2C           ; the start/stop record, in the low block (4)
BNC     = $30           ; the bounce buffer (4)
CALLP   = $34           ; the call area (4)
LSIZE   = $38           ; the low block's size
BOFF    = $3A           ; the bounce buffer's offset in it
COFF    = $3C           ; the call area's
DONE    = $3E           ; the steps done, to undo
ERR     = $40           ; the last toolbox error
NTOOLS  = $42           ; the header's tool count
LIST    = $44           ; the header's tool pairs (4)
RTP     = $48           ; the runtime's own GS/OS parameter blocks, in the low block (4)
PATH    = $4C           ; the program's pathname, the header's class-1 string (4)
EOFV    = $50           ; the program file's size (4)
MEMSZ   = $54           ; the image header's memory: the image and its bss, 16-aligned (4)
TOTAL   = $58           ; all of the upper-half memory it needs (4)
FIRSTN  = $5C           ; the first chunk's bytes, read before the engine starts
NCHUNK  = $5E           ; chunks handed to the loader
NB      = $60           ; upper-half banks: how many...
HIB     = $62           ; ...and the first (0-255: bank $100 + HIB)
DMAX    = $64           ; every step ever done (DONE loses them as they are undone)
GSN     = $66           ; a GS/OS call's number

D_REG   = $0001         ; DONE: registered in $EE
D_MM    = $0002         ;       TLStartUp + MMStartUp
D_LOW   = $0004         ;       the low block
D_TOOLS = $0008         ;       StartUpTools
D_VIDEO = $0010         ;       enhanced video owned
D_FILE  = $0020         ;       the program's file open
.macro  did     bit
        lda     #bit
        tsb     DONE
        tsb     DMAX
.endmacro

; The stub's header (apple/rvvm/stub/stub.s)
H_VER    = 4
H_FLAGS  = 6
H_VMODE  = 8
H_BOUNCE = 10
H_CALL   = 12
H_TOOLS  = 14
H_IMAGE  = 16
HF_VIDEO = $0001
MAX_TOOLS = 32

; The environment block, first in the low block (the guest's `struct rv_env`)
EV_MAGIC  = 0           ; 'RVEN'
EV_VER    = 4
EV_SIZE   = 6
EV_UID    = 8
EV_FLAGS  = 10          ; bit 0: owns enhanced video
EV_LOW    = 12
EV_LOWSZ  = 16
EV_BNC    = 20
EV_BNCSZ  = 24
EV_CALL   = 28
EV_CALLSZ = 32
EV_HI     = 36          ; the upper half's banks (rung I3)
EV_HISZ   = 40
EV_IMG    = 44
EV_IMGSZ  = 48
EV_HEAP   = 52
EV_PATH   = 56
EV_VIDEO  = 60          ; the enhanced video control bank, 0 = not the owner
ENV_LEN   = 64
REC_LEN   = 12          ; the start/stop record before its tool pairs
; The runtime's GS/OS parameter blocks, after the record (class 1, pCount first)
RT_OPEN   = 0           ; Open: pCount 3, refNum, pathname (4), requestAccess 1 (read)
RT_EOF    = 10          ; GetEOF: pCount 2, refNum, eof (4)
RT_READ   = 18          ; Read: pCount 4, refNum, dataBuffer (4), requestCount (4), transferCount (4)
RT_CLOSE  = 34          ; Close: pCount 1, refNum
RT_LEN    = 40
; The program's image header (apple/rvvm/guest/crt0_app.S), after its first jump
IM_MAGIC  = 4           ; 'RVIM'
IM_VER    = 8           ; 1
IM_MEM    = 12          ; the image and its bss (4)
IM_STACK  = 16          ; (4)
IM_HEAP   = 20          ; (4)

; The registration table, bank $EE (ours): read by nothing else.  One owner word
; per 64 KB bank of the upper half; one application slot (a RISC-V desk
; accessory would get slots of its own).
REG       = $EE0000     ; "RVRG"
REG_VER   = REG + 4     ; 1
REG_VIDEO = REG + 6     ; enhanced video's owner, a user ID, 0 = none
REG_APP   = REG + 8     ; the application's user ID, 0 = none
REG_LOW   = REG + 10    ; its low block (4)
REG_BANKS = REG + $100  ; 256 owner words: banks $100-$1FF
EV_CTL    = $E20000     ; enhanced video: ENABLE; +1 the global commit

; The trace, $EE:FF00: what the last application's lifecycle did, for the host's
; mirror (every field rewritten at each entry but the count).
RT_TRACE = $EEFF00      ; "RVRT"
TR_COUNT = 4            ; entries (restarting at 1 when the marker is not there)
TR_UID   = 6
TR_HDR   = 8            ; (4)
TR_STEP  = 12           ; the last step taken (below), $FF when it came back
TR_ERR   = 14           ; the last toolbox error
TR_LOW   = 16           ; the low block (4)
TR_CODE  = 20           ; the exit code (4)
TR_STAT  = 24           ; 1 exit, 2 trap, 0 never ran
TR_CAUSE = 26
TR_TVAL  = 28           ; (4)
TR_PC    = 32           ; the engine's pc at the stop (4)
TR_REF   = 36           ; StartUpTools' startStopRef (4)
TR_DONE  = 40           ; every step done (DMAX)
TR_HI    = 42           ; the upper-half memory: its base (4)...
TR_HISZ  = 46           ; ...and size (4)
TR_EOF   = 50           ; the program file's size (4)
TR_LEN   = 54
.macro  step    n
        lda     #n
        sta     f:RT_TRACE + TR_STEP
.endmacro

TOOLS   = $E10000
GSOS_STACK = $E100B0    ; GS/OS's stack entry: the parameter block (long), the call number
GS_OPEN  = $2010
GS_READ  = $2012
GS_CLOSE = $2014
GS_GETEOF = $2019
GS_EOF_ERR = $004C      ; Read at the end of the file
RT_CHUNK = $5020        ; the loader's ECALL: the next chunk of the program's file
TL_STARTUP   = $0201
TL_SHUTDOWN  = $0301
MM_STARTUP   = $0202
MM_SHUTDOWN  = $0302
NEW_HANDLE   = $0902
DISPOSE_HANDLE = $1002
STARTUP_TOOLS  = $1801
SHUTDOWN_TOOLS = $1901
; locked, fixed, page-aligned, not across a bank, not in special memory (banks
; $00/$01/$E0/$E1): the engine reads and writes the low block itself.
LOW_ATTR = $C01C

app_entry:
        rep     #$30
        .a16
        .i16
        phb
        pha
        phx
        phy
        ldx     #$00CE                  ; the direct page is ours now
:       stz     0,x
        dex
        dex
        bpl     :-
        ply
        plx
        pla
        sta     UID
        stx     HDR
        sty     HDR+2
        inc     APPM
        jsr     tr_enter
        jsr     hdr_check               ; C: not a header this runtime knows
        bcs     @bad
        jsr     reg_up
        step    2
        jsr     mm_up
        step    3
        jsr     low_up                  ; C: NewHandle refused
        bcs     @fail
        jsr     env_fill
        step    4
        jsr     tools_up                ; C: StartUpTools refused
        bcs     @fail
        step    5
        jsr     video_up
        step    6
        jsr     file_up                 ; C: the program's file, its header or its memory (CODE says)
        bcs     @down
        step    7
        jsr     app_run
        step    8
        bra     @down
@bad:   lda     #$FFFE                  ; -2: the header
        bra     @code
@fail:  lda     #$FFFD                  ; -3: a toolbox call (TR_ERR, TR_STEP say which)
@code:  sta     CODE
        lda     #$FFFF
        sta     CODE+2
@down:  jsr     app_down
        jsr     tr_leave
        lda     CODE
        plb
        rtl

; ---- the steps ------------------------------------------------------------------------
; The header: "RVAP", version 2, a sane tool count; the low block's layout from it.
hdr_check:
        lda     [HDR]
        cmp     #('V' << 8) | 'R'
        bne     @no
        ldy     #2
        lda     [HDR],y
        cmp     #('P' << 8) | 'A'
        bne     @no
        ldy     #H_VER
        lda     [HDR],y
        cmp     #2
        bne     @no
        ldy     #H_TOOLS                ; LIST = the tool list (the stub is one bank)
        lda     [HDR],y
        clc
        adc     HDR
        sta     LIST
        lda     HDR+2
        sta     LIST+2
        lda     [LIST]
        cmp     #MAX_TOOLS + 1
        bcs     @no
        sta     NTOOLS
        lda     LIST                    ; LIST = the pairs, after the count
        inc
        inc
        sta     LIST
        lda     NTOOLS                  ; env, record, pairs, the runtime's blocks; then the bounce buffer...
        asl
        asl
        adc     #ENV_LEN + REC_LEN + 3
        and     #$FFFC
        adc     #RT_LEN
        sta     BOFF
        ldy     #H_BOUNCE
        lda     [HDR],y
        jsr     round4
        bcs     @no
        adc     BOFF
        bcs     @no
        sta     COFF                    ; ...then the call area
        ldy     #H_CALL
        lda     [HDR],y
        jsr     round4
        bcs     @no
        adc     COFF
        bcs     @no
        sta     LSIZE
        clc
        rts
@no:    sec
        rts
round4: clc                             ; A = A rounded up to 4; C on overflow
        adc     #3
        and     #$FFFC
        rts

; The registration table: made when it is not there; an application found in the
; slot is gone (only one runs at a time - its quit never unregistered it: a reset,
; a crash), and what it held is taken back; then the slot is ours.
reg_up: lda     f:REG
        cmp     #('V' << 8) | 'R'
        bne     @init
        lda     f:REG+2
        cmp     #('G' << 8) | 'R'
        bne     @init
        lda     f:REG_VER
        cmp     #1
        beq     @ok
@init:  lda     #0
        ldx     #$02FE
:       sta     f:REG,x
        dex
        dex
        bpl     :-
        lda     #('V' << 8) | 'R'
        sta     f:REG
        lda     #('G' << 8) | 'R'
        sta     f:REG+2
        lda     #1
        sta     f:REG_VER
@ok:    lda     f:REG_APP
        beq     :+
        jsr     reclaim
:       lda     UID
        sta     f:REG_APP
        did     D_REG
        rts

; Everything registered to the user ID in A goes back: its upper-half banks, and
; enhanced video (turned off) if it owned it.
reclaim:
        sta     TGT
        ldx     #$01FE
@b:     lda     f:REG_BANKS,x
        cmp     TGT
        bne     :+
        lda     #0
        sta     f:REG_BANKS,x
:       dex
        dex
        bpl     @b
        lda     f:REG_VIDEO
        cmp     TGT
        bne     :+
        jsr     video_off
        lda     #0
        sta     f:REG_VIDEO
:       rts

reg_down:
        lda     UID
        jsr     reclaim
        lda     #0
        sta     f:REG_APP
        sta     f:REG_LOW
        sta     f:REG_LOW+2
        rts

mm_up:  ldx     #TL_STARTUP
        jsl     TOOLS
        pha                             ; MMStartUp: the user ID (the loader's, again)
        ldx     #MM_STARTUP
        jsl     TOOLS
        pla
        did     D_MM
        rts

; NewHandle(size, user ID, attributes, location): the low block.
low_up: pha
        pha                             ; the handle
        pea     0
        pei     (LSIZE)
        pei     (UID)
        pea     LOW_ATTR
        pea     0
        pea     0
        ldx     #NEW_HANDLE
        jsl     TOOLS
        sta     ERR
        pla
        sta     LOWH
        pla
        sta     LOWH+2
        bcs     @no
        lda     [LOWH]                  ; the master pointer: the block, locked in place
        sta     LOWP
        ldy     #2
        lda     [LOWH],y
        sta     LOWP+2
        sta     RECP+2                  ; the pieces: one bank (not across one)
        sta     BNC+2
        sta     CALLP+2
        lda     LOWP
        clc
        adc     #ENV_LEN
        sta     RECP
        lda     LOWP
        adc     BOFF
        sta     BNC
        lda     LOWP
        adc     COFF
        sta     CALLP
        lda     LOWP
        adc     BOFF
        sec
        sbc     #RT_LEN
        sta     RTP
        lda     LOWP+2
        sta     RTP+2
        lda     LOWP
        sta     f:REG_LOW
        lda     LOWP+2
        sta     f:REG_LOW+2
        did     D_LOW
        clc
        rts
@no:    lda     ERR
        sta     f:RT_TRACE + TR_ERR
        sec
        rts

; The environment block, every field.
env_fill:
        lda     #('V' << 8) | 'R'
        ldy     #EV_MAGIC
        sta     [LOWP],y
        lda     #('N' << 8) | 'E'
        ldy     #EV_MAGIC+2
        sta     [LOWP],y
        lda     #1
        ldy     #EV_VER
        sta     [LOWP],y
        lda     #ENV_LEN
        ldy     #EV_SIZE
        sta     [LOWP],y
        lda     UID
        ldy     #EV_UID
        sta     [LOWP],y
        lda     #0                      ; flags, and every upper-half field: rung I3
        ldy     #EV_FLAGS
        sta     [LOWP],y
        ldy     #EV_HI
:       sta     [LOWP],y
        iny
        iny
        cpy     #ENV_LEN
        bne     :-
        ldy     #EV_LOW
        ldx     #LOWP
        jsr     env_ptr
        lda     LSIZE
        ldy     #EV_LOWSZ
        jsr     env_word
        ldy     #EV_BNC
        ldx     #BNC
        jsr     env_ptr
        lda     COFF
        sec
        sbc     BOFF
        ldy     #EV_BNCSZ
        jsr     env_word
        ldy     #EV_CALL
        ldx     #CALLP
        jsr     env_ptr
        lda     LSIZE
        sec
        sbc     COFF
        ldy     #EV_CALLSZ
        jmp     env_word
; env[Y] = the long pointer in the direct page at X
env_ptr:
        lda     0,x
        sta     [LOWP],y
        iny
        iny
        lda     2,x
        sta     [LOWP],y
        rts
; env[Y] = A, a 32-bit field
env_word:
        sta     [LOWP],y
        iny
        iny
        lda     #0
        sta     [LOWP],y
        rts

; StartUpTools(user ID, 0 = a pointer, the start/stop record): the record in the
; low block (StartUpTools writes its resource file and direct page handle back
; into it, and ShutDownTools reads them) - flags 0, the header's video mode, then
; the header's tools.
tools_up:
        lda     #0
        sta     [RECP]                  ; flags
        ldy     #4
        sta     [RECP],y                ; resFileID
        ldy     #6
        sta     [RECP],y                ; dPageHandle
        ldy     #8
        sta     [RECP],y
        ldy     #H_VMODE
        lda     [HDR],y
        ldy     #2
        sta     [RECP],y                ; videoMode
        lda     NTOOLS
        ldy     #10
        sta     [RECP],y                ; numTools
        lda     RECP                    ; TGT = the record's pairs
        clc
        adc     #REC_LEN
        sta     TGT
        lda     RECP+2
        sta     TGT+2
        lda     NTOOLS
        asl
        asl
        tax                             ; bytes of pairs
        ldy     #0
@c:     cpx     #0
        beq     @go
        lda     [LIST],y
        sta     [TGT],y
        iny
        iny
        dex
        dex
        bra     @c
@go:    pha
        pha                             ; startStopRef
        pei     (UID)
        pea     0
        pei     (RECP+2)
        pei     (RECP)
        ldx     #STARTUP_TOOLS
        jsl     TOOLS
        sta     ERR
        pla
        sta     f:RT_TRACE + TR_REF
        pla
        sta     f:RT_TRACE + TR_REF + 2
        bcs     @no
        did     D_TOOLS
        clc
        rts
@no:    lda     ERR
        sta     f:RT_TRACE + TR_ERR
        sec
        rts

; ---- the program's file (rung I3) ------------------------------------------------------
; A class-1 GS/OS call through the stack entry: A = the call number, X = its
; parameter block's offset from RTP.  C and A = GS/OS's error (A = 0 when none).
; B is kept (the panel's gs_call learned it): the engine's run needs $EF.
gs_call:
        sta     GSN
        phb
        lda     RTP+2
        pha                             ; the parameter block, high word...
        txa
        clc
        adc     RTP
        pha                             ; ...then low
        pei     (GSN)
        jsl     GSOS_STACK
        bcs     :+
        lda     #0
:       plb
        rts

; The program: its file opened (the header's pathname, prefix 9: = the
; application's folder), its size, its first chunk read into the bounce buffer,
; the image header in that chunk checked, and the upper-half memory it asks for
; registered to the application.  C set with CODE: -5 the file (TR_ERR = GS/OS's
; error), -6 its image header, -7 no room in the upper half.
file_up:
        ldy     #H_IMAGE
        lda     [HDR],y
        bne     :+
        jmp     @nofile                 ; a header without an image
:       clc
        adc     HDR
        sta     PATH
        lda     HDR+2
        sta     PATH+2
        lda     #3                      ; Open(refNum, pathname, read)
        ldy     #RT_OPEN
        sta     [RTP],y
        ldy     #RT_OPEN+4
        lda     PATH
        sta     [RTP],y
        iny
        iny
        lda     PATH+2
        sta     [RTP],y
        ldy     #RT_OPEN+8
        lda     #1
        sta     [RTP],y
        lda     #GS_OPEN
        ldx     #RT_OPEN
        jsr     gs_call
        bcc     :+
        jmp     @gserr
:       did     D_FILE
        ldy     #RT_OPEN+2
        lda     [RTP],y                 ; the refNum, into every other block
        ldy     #RT_EOF+2
        sta     [RTP],y
        ldy     #RT_READ+2
        sta     [RTP],y
        ldy     #RT_CLOSE+2
        sta     [RTP],y
        lda     #2
        ldy     #RT_EOF
        sta     [RTP],y
        lda     #1
        ldy     #RT_CLOSE
        sta     [RTP],y
        lda     #4                      ; Read(refNum, the bounce buffer, its size)
        ldy     #RT_READ
        sta     [RTP],y
        ldy     #RT_READ+4
        lda     BNC
        sta     [RTP],y
        iny
        iny
        lda     BNC+2
        sta     [RTP],y
        ldy     #RT_READ+8
        lda     COFF
        sec
        sbc     BOFF
        sta     [RTP],y
        iny
        iny
        lda     #0
        sta     [RTP],y
        lda     #GS_GETEOF
        ldx     #RT_EOF
        jsr     gs_call
        bcc     :+
        jmp     @gserr
:       ldy     #RT_EOF+4
        lda     [RTP],y
        sta     EOFV
        iny
        iny
        lda     [RTP],y
        sta     EOFV+2
        jsr     read_chunk              ; the first chunk: the image header is in it
        bcc     :+
        jmp     @gserr
:       sta     FIRSTN
        cmp     #IM_HEAP + 4
        bcs     :+
        jmp     @badimg
:       ldy     #IM_MAGIC               ; 'RVIM', version 1
        lda     [BNC],y
        cmp     #('V' << 8) | 'R'
        beq     :+
        jmp     @badimg
:       iny
        iny
        lda     [BNC],y
        cmp     #('M' << 8) | 'I'
        beq     :+
        jmp     @badimg
:       ldy     #IM_VER
        lda     [BNC],y
        cmp     #1
        beq     :+
        jmp     @badimg
:       ldy     #IM_MEM                 ; MEMSZ = the image and its bss, 16-aligned
        lda     [BNC],y
        clc
        adc     #15
        and     #$FFF0
        sta     MEMSZ
        iny
        iny
        lda     [BNC],y
        adc     #0
        sta     MEMSZ+2
        lda     MEMSZ+2                 ; the file must fit in it (EOFV <= MEMSZ)
        cmp     EOFV+2
        bne     :+
        lda     MEMSZ
        cmp     EOFV
:       bcs     :+
        jmp     @badimg
:       lda     MEMSZ                   ; TOTAL = MEMSZ + the heap + the stack
        ldy     #IM_HEAP
        clc
        adc     [BNC],y
        sta     TOTAL
        iny
        iny
        lda     MEMSZ+2
        adc     [BNC],y
        sta     TOTAL+2
        bcc     :+
        jmp     @badimg
:       ldy     #IM_STACK
        lda     TOTAL
        clc
        adc     [BNC],y
        sta     TOTAL
        iny
        iny
        lda     TOTAL+2
        adc     [BNC],y
        sta     TOTAL+2
        bcc     :+
        jmp     @badimg
:       lda     TOTAL                   ; NB = whole banks, 1-256
        cmp     #1                      ; C = a partial bank
        lda     TOTAL+2
        adc     #0
        beq     @badimg
        cmp     #257
        bcs     @room
        sta     NB
        jsr     bank_alloc              ; C: no run of NB free banks
        bcs     @room
        jsr     env_hi
        clc
        rts
@nofile:
        lda     #0
        sta     f:RT_TRACE + TR_ERR
@gserr: sta     f:RT_TRACE + TR_ERR
        lda     #$FFFB                  ; -5: the program's file
        bra     @code
@badimg:
        lda     #$FFFA                  ; -6: its image header
        bra     @code
@room:  stz     NB
        lda     #$FFF9                  ; -7: no room in the upper half
@code:  sta     CODE
        lda     #$FFFF
        sta     CODE+2
        sec
        rts

; Read the next chunk into the bounce buffer: A = the bytes read (0 at the end
; of the file), C and A = GS/OS's error otherwise.
read_chunk:
        lda     #GS_READ
        ldx     #RT_READ
        jsr     gs_call
        bcc     @ok
        cmp     #GS_EOF_ERR
        bne     @no
@ok:    ldy     #RT_READ+12             ; transferCount (a chunk is under 64 KB)
        lda     [RTP],y
        clc
        rts
@no:    sec
        rts

; The file closed, if it is open.
file_close:
        lda     #D_FILE
        trb     DONE
        beq     :+
        lda     #GS_CLOSE
        ldx     #RT_CLOSE
        jsr     gs_call
:       rts

; NB banks of the upper half, contiguous, first fit, registered to the
; application: HIB the first.  C set when there is no such run.
bank_alloc:
        ldx     #0                      ; the bank (x2)
@start: stx     HIB                     ; a run starts here...
        ldy     NB                      ; ...needing this many more
@next:  cpx     #$0200
        bcs     @no
        lda     f:REG_BANKS,x
        inx
        inx
        cmp     #0
        bne     @start                  ; taken: a new run from the next bank
        dey
        bne     @next
        lda     HIB                     ; found: HIB (x2) .. X
        tax
        ldy     NB
        lda     UID
:       sta     f:REG_BANKS,x
        inx
        inx
        dey
        bne     :-
        lda     HIB
        lsr
        sta     HIB
        clc
        rts
@no:    sec
        rts

; The environment block's upper-half fields and the program's pathname.
env_hi: lda     #0
        ldy     #EV_HI
        sta     [LOWP],y
        ldy     #EV_IMG
        sta     [LOWP],y
        ldy     #EV_HISZ
        sta     [LOWP],y
        lda     HIB
        clc
        adc     #$0100
        ldy     #EV_HI+2
        sta     [LOWP],y
        ldy     #EV_IMG+2
        sta     [LOWP],y
        ldy     #EV_HEAP+2              ; the heap: after the image and its bss
        clc
        adc     MEMSZ+2
        sta     [LOWP],y
        lda     MEMSZ
        ldy     #EV_HEAP
        sta     [LOWP],y
        lda     NB
        ldy     #EV_HISZ+2
        sta     [LOWP],y
        ldy     #EV_IMGSZ
        ldx     #EOFV
        jsr     env_ptr
        ldy     #EV_PATH
        ldx     #PATH
        jmp     env_ptr

; ECALL RT_CHUNK (the loader's): a0 = the bytes of the program's file now in the
; bounce buffer - the first chunk, read before the engine started, then one
; Read each - 0 at the end (the file is closed then), -error from GS/OS.
sys_chunk:
        lda     APPM
        bne     :+
        jmp     enosys
:       lda     NCHUNK
        inc     NCHUNK
        cmp     #0
        bne     :+
        lda     FIRSTN
        bra     @n
:       jsr     read_chunk
        bcc     @n
        eor     #$FFFF                  ; -error
        inc
        jmp     ret_neg
@n:     cmp     #0
        bne     :+
        pha
        jsr     file_close
        pla
:       jmp     ret_a

; Enhanced video: the one owner is the running application (the user,
; 2026-09-26).  It starts off (ENABLE 0, latched), whatever was left.
video_up:
        ldy     #H_FLAGS
        lda     [HDR],y
        and     #HF_VIDEO
        beq     @no
        lda     UID
        sta     f:REG_VIDEO
        jsr     video_off
        ldy     #EV_FLAGS
        lda     #1
        sta     [LOWP],y
        ldy     #EV_VIDEO
        lda     #.loword(EV_CTL)
        sta     [LOWP],y
        ldy     #EV_VIDEO+2
        lda     #^EV_CTL
        sta     [LOWP],y
        did     D_VIDEO
@no:    rts
video_off:
        sep     #$20
        .a8
        lda     #0
        sta     f:EV_CTL                ; ENABLE 0...
        sta     f:EV_CTL + 1            ; ...latched by the global commit
        rep     #$20
        .a16
        rts

; The engine runs the program: DBR $EF (the window), x1-x31 zero, a0 = the
; environment block.  sys_exit and the traps come back through app_done to
; app_run's caller.  The engine starts in the loader, rt_loader, in this bank.
app_run:
        sep     #$20
        .a8
        lda     #$EF
        pha
        plb
        rep     #$20
        .a16
        lda     a:WID
        cmp     #('V' << 8) | 'R'
        beq     :+
        lda     #$FFFC                  ; -4: no engine
        sta     CODE
        lda     #$FFFF
        sta     CODE+2
        rts
:       jsr     eng_mode
        jsr     eng_idle
        jsr     eng_clear
        lda     LOWP
        sta     a:WA0
        lda     LOWP+2
        sta     a:WA0+2
        lda     #.loword(rt_loader)
        sta     a:WPC
        lda     #^rt_loader
        sta     a:WPC+2
        tsc
        sta     RUN_S
        jmp     loop
app_done:
        rep     #$30
        .a16
        .i16
        lda     RUN_S
        tcs
        rts

; RUNM: the engine has RUN from version 2 ("E", the version, in WID+2).
eng_mode:
        lda     a:WID+2
        and     #$FF00
        cmp     #$0200
        bcc     :+
        inc     RUNM
:       rts
; The engine idle for a new program: an event the last program left pending -
; its exit's ECALL, above all: nothing resets the engine between applications or
; machine resets - is finished, or the first RUN would only report it again (and
; the RESUME that answered it would step the new pc past its first instruction:
; the loader's a0 was lost that way on hardware, 2026-09-26).  The resume value
; is a NOP for the one event RESUME re-executes, a delegated fetch; that one is
; still not clean (the NOP would stand for the new pc's first instruction) and
; needs an abort in the engine - it is only left by a reset in the middle of a
; delegated fetch, which no program here makes.
eng_idle:
        sep     #$20
        .a8
        lda     a:WSTAT
        rep     #$20
        .a16
        and     #$0002
        beq     :+
        lda     #$0013                  ; addi x0, x0, 0
        sta     a:RVAL
        lda     #0
        sta     a:RVAL+2
        sta     a:RESUME
:       rts
; x1..x31 = 0: the register file has no reset.
eng_clear:
        ldx     #4
:       stz     a:WX,x
        stz     a:WX+2,x
        inx
        inx
        inx
        inx
        cpx     #$80
        bne     :-
        rts

; Undo what DONE says, in reverse.
app_down:
        lda     DMAX
        sta     f:RT_TRACE + TR_DONE
        lda     #D_VIDEO
        trb     DONE
        beq     :+
        jsr     video_off
        lda     #0
        sta     f:REG_VIDEO
        step    9
:       jsr     file_close
        lda     #D_TOOLS
        trb     DONE
        beq     :+
        pea     0                       ; ShutDownTools(0 = a pointer, the record)
        pei     (RECP+2)
        pei     (RECP)
        ldx     #SHUTDOWN_TOOLS
        jsl     TOOLS
        step    10
:       lda     #D_LOW
        trb     DONE
        beq     :+
        pei     (LOWH+2)                  ; DisposeHandle
        pei     (LOWH)
        ldx     #DISPOSE_HANDLE
        jsl     TOOLS
        step    11
:       lda     #D_MM
        trb     DONE
        beq     :+
        pei     (UID)
        ldx     #MM_SHUTDOWN
        jsl     TOOLS
        ldx     #TL_SHUTDOWN
        jsl     TOOLS
        step    12
:       lda     #D_REG
        trb     DONE
        beq     :+
        jsr     reg_down
        step    13
:       rts

; The trace: counted, the fields of the last run cleared.
tr_enter:
        lda     f:RT_TRACE
        cmp     #('V' << 8) | 'R'
        bne     @first
        lda     f:RT_TRACE + 2
        cmp     #('T' << 8) | 'R'
        bne     @first
        lda     f:RT_TRACE + TR_COUNT
        inc
        bra     @count
@first: lda     #('V' << 8) | 'R'
        sta     f:RT_TRACE
        lda     #('T' << 8) | 'R'
        sta     f:RT_TRACE + 2
        lda     #1
@count: sta     f:RT_TRACE + TR_COUNT
        lda     #0
        ldx     #TR_UID
:       sta     f:RT_TRACE,x
        inx
        inx
        cpx     #TR_LEN
        bne     :-
        lda     UID
        sta     f:RT_TRACE + TR_UID
        lda     HDR
        sta     f:RT_TRACE + TR_HDR
        lda     HDR+2
        sta     f:RT_TRACE + TR_HDR + 2
        step    1
        rts
tr_leave:
        lda     LOWP
        sta     f:RT_TRACE + TR_LOW
        lda     LOWP+2
        sta     f:RT_TRACE + TR_LOW + 2
        lda     CODE
        sta     f:RT_TRACE + TR_CODE
        lda     CODE+2
        sta     f:RT_TRACE + TR_CODE + 2
        lda     STATUS
        sta     f:RT_TRACE + TR_STAT
        lda     CAUSE
        sta     f:RT_TRACE + TR_CAUSE
        lda     TVAL
        sta     f:RT_TRACE + TR_TVAL
        lda     TVAL+2
        sta     f:RT_TRACE + TR_TVAL + 2
        lda     f:$EF0000 + WPC
        sta     f:RT_TRACE + TR_PC
        lda     f:$EF0000 + WPC + 2
        sta     f:RT_TRACE + TR_PC + 2
        lda     EOFV
        sta     f:RT_TRACE + TR_EOF
        lda     EOFV+2
        sta     f:RT_TRACE + TR_EOF + 2
        lda     #0
        sta     f:RT_TRACE + TR_HI
        sta     f:RT_TRACE + TR_HISZ
        lda     NB
        beq     :+
        sta     f:RT_TRACE + TR_HISZ + 2
        lda     HIB
        clc
        adc     #$0100
        sta     f:RT_TRACE + TR_HI + 2
:
        step    $FF
        rts

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
@eng:   jsr     eng_mode
        jsr     eng_idle
        jsr     eng_clear
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
        bne     :+
        jmp     sys_poke
:       cmp     #RT_CHUNK
        bne     enosys
        jmp     sys_chunk
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

; ---- the platform: the sim's ports; an application has neither ---------------------
; An application's run (APPM) has no console: what it writes is discarded, as a
; desktop application's stdout is (docs/RVV2_INTEROP.md), and it reads nothing;
; its exit or trap goes back to the lifecycle instead of stopping the machine.
        .a8
plat_putc:
        pha
        lda     APPM
        bne     :+
        pla
        sta     f:PORT_PUTC
        rts
:       pla
        rts
plat_getc:
        lda     f:PORT_GETC
        rts
        .a16
plat_avail:
        lda     APPM
        bne     :+
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
        lda     APPM
        beq     :+
        jmp     app_done
:       stp

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

; ---- RISC-V code the runtime runs, in this bank (apple/rvvm/rt; the engine reads
; the ROM itself).  rt_loader: the loader - the program's file through the bounce
; buffer into the upper half, then into the program.
        .segment "RVCODE"
rt_loader:
        .incbin "rt_loader.bin"

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
