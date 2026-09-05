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
IRQARM  = $03FB          ; irqtest writes 1 here to start the tb's IRQ timer, 0 to stop
ISRA    = $03FA          ; the ISR acks by writing here; the tb drops IRQ' on it
ISRC    = $03F9          ; the ISR's own counter
SMCRES  = $03F8          ; smcsweep's target writes its loaded byte here
SMCTMP  = $03F7          ; smcsweep's compare scratch
PTR     = $06
IPTR    = $08            ; irqtest's roving pointer, distinct from PTR

.macro  jne target
        beq :+
        jmp target
:
.endmacro

.macro  jpl target
        bmi :+
        jmp target
:
.endmacro

.macro  jmi target
        bpl :+
        jmp target
:
.endmacro

.macro  jcs target
        bcc :+
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

        ; ---- 2b. writes at one clock (rtl/dline.sv rung 3): a push burst
        ; deeper than the posted FIFO, a fresh line written and read straight
        ; back, the zero page written and read byte by byte
        jsr wrtest
        jcs fail

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
        jcs fail

        ; ---- 4b. the op right after a bank switch comes from the new bank:
        ; a stub present in BOTH banks flips RAMRD/RAMWRT and its very next
        ; fetch, read or write must land on the other side (the Nox splash
        ; lockup of 2026-09-04, docs/CXXX.md "The switch writes")
        jsr bankfetch
        jcs fail

        ; ---- 5. the RamWorks banks, from the ROM - once the card is serving.
        ; The machine the testbench models has no RamWorks; the card is it,
        ; and only its image can answer.  The testbench sets RWFLAG through
        ; the override path when it turns serving on.
        lda RWFLAG
        beq norw
        jsr rwtest
        jcs fail
norw:
        jsr cxtest

        ; ---- 5b. the keyboard: served from the parked-dummy latch in the
        ; closed regime, the bus otherwise; the same byte either way.
        lda $C000
        sta $0310               ; the tb watches this byte
        bpl nokey
        lda $C010               ; a key waited: take it, clear the strobe
nokey:

        ; ---- 5c. the switch reads in the closed regime (docs/CXXX.md): the
        ; status page read back through the program's own hands after each
        ; switch, the floating-value toggles, the language card's pair.  In
        ; the closed regime none of these READS ride a bus cycle (the STAs
        ; still do); in every mode the answers are the same, because the
        ; model's pins answer the status page too.  BIT tests bit 7 only.
        lda $C083
        lda $C083               ; bank 2, read RAM, write enabled
        bit $C011
        jpl fail                ; RDLCBNK2 must be set
        bit $C012
        jpl fail                ; RDLCRAM must be set
        lda $C08B
        lda $C08B               ; bank 1
        bit $C011
        jmi fail
        lda $C082               ; ROM back, protected
        bit $C012
        jmi fail
        lda $C055               ; PAGE2 on, by a read: a floating value comes back
        bit $C01C
        jpl fail
        lda $C054               ; off
        bit $C01C
        jmi fail
        lda $C054               ; again - quiet: no switch moves, no word
        lda $C053               ; MIXED on
        bit $C01B
        jpl fail
        lda $C052               ; off
        bit $C01B
        jmi fail
        lda $C051               ; TEXT on (it is already: quiet)
        bit $C01A
        jpl fail
        sta $C001               ; 80STORE on (a write: served on the card too, since step 4)
        bit $C018
        jpl fail
        sta $C000               ; off
        bit $C018
        jmi fail
        bit $C013               ; RAMRD is off here
        jmi fail

        ; ---- 5d. the switch WRITES in the closed regime (docs/CXXX.md, "The
        ; switch writes"): every memory-mapping and IOU strobe, the toggles
        ; and the language card by a write, each read back through the
        ; status page; two quiet writes (no switch moves, no word); and the
        ; two Cx-ROM switches, which ride the bus in every mode - the
        ; testbench counts them on the pins.  This code runs from RAM at
        ; $6000, so RAMRD cannot be turned on here (the next fetch would come
        ; from aux) - the aux tests in ROM below do that, and in mode 2 their
        ; STAs now take this path; RAMWRT and ALTZP are flipped only between
        ; instructions that touch no memory but the switch and the status page.
        sta $C002               ; RAMRD main, already: a quiet write
        sta $C005               ; RAMWRT aux
        bit $C014
        jpl fail
        sta $C004               ; main
        bit $C014
        jmi fail
        sta $C009               ; ALTZP on (no zero page or stack use until it is off)
        bit $C016
        jpl fail
        sta $C008               ; off
        bit $C016
        jmi fail
        sta $C00D               ; 80COL on
        bit $C01F
        jpl fail
        sta $C00C               ; off
        bit $C01F
        jmi fail
        sta $C00F               ; ALTCHAR on
        bit $C01E
        jpl fail
        sta $C00E               ; off
        bit $C01E
        jmi fail
        sta $C055               ; PAGE2 on, by a write
        bit $C01C
        jpl fail
        sta $C054               ; off
        bit $C01C
        jmi fail
        sta $C054               ; again - quiet
        sta $C057               ; HIRES on
        bit $C01D
        jpl fail
        sta $C056               ; off
        bit $C01D
        jmi fail
        sta $C08B               ; the LC by a write: bank 1, read RAM; A0 = 1 on a
        bit $C011               ; write clears prewrite, the enable stays as it was
        jmi fail                ; RDLCBNK2 clear
        bit $C012
        jpl fail                ; RDLCRAM set
        sta $C082               ; ROM back, protected, bank 2
        bit $C011
        jpl fail
        bit $C012
        jmi fail
        sta $C007               ; INTCXROM on: this write rides the bus
        bit $C015
        jpl fail
        sta $C006               ; off: so does this one
        bit $C015
        jmi fail
        sta $C00B               ; SLOTC3ROM on: the bus
        bit $C017
        jpl fail
        sta $C00A               ; off: the bus
        bit $C017
        jmi fail

        ; ---- 5e. the speaker (docs/CXXX.md "The speaker"): every access
        ; toggles it, read or write, and in the closed regime none rides the
        ; bus - the testbench counts them served and none on the pins.
        lda $C030
        sta $C030
        bit $C030
        sta $C03F
        lda $C03F

        ; ---- 6. self-modifying code: the operand and the opcode change
        ; under the icache's feet.  A stale line shows as the wrong A or X.
        jsr smctest
        jcs fail

        ; ---- 7. the branch-prefetch front: hot loops, calls, and writes
        ; into retained lines (rtl/iline.sv's CAM, rtl/iscan.sv's scanner)
        jsr bptest
        jcs fail

        ; ---- 8. the CMOS dummy re-reads (rtl/dline.sv's last byte) --------
        jsr dumtest
        jcs fail

        ; ---- 9. the data front under an interrupt storm ------------------
        ; The dimension no sim has exercised and the one the hardware lock
        ; lives in: a Mockingboard-shaped timer IRQ interposing on the
        ; accelerated data stream (docs/DLINE.md, the hgr-corruption hunt).
        ; A wrong byte served across an interposed interrupt fails here -
        ; the testbench's program-order reference checks every served byte -
        ; or in the compares below.  IRQ-safe by construction: default map,
        ; main bank 0, ALTZP off, the ISR touching only its own page-3
        ; scratch and preserving every register.
        jsr irqtest
        jcs fail

        ; ---- 10b. self-modifying code into a HOT icache line -----------
        ; Moon Patrol's compiled-sprite shape, found in a hardware trace: a
        ; STA patches the operand byte of an instruction in a DIFFERENT
        ; 16-byte line, and that line is hot in the icache from the loop's
        ; previous pass.  If the front's SMC snoop misses the cross-line
        ; write, the operand fetch serves the stale cached byte - the
        ; graphics corruption.  The testbench's reference catches the stale
        ; fetch; the compare here is a second net.  Swept over the operand's
        ; offset within the line by smcsweep.
        jsr smcsweep
        jcs fail

        ; ---- 10. HGR page-flipping under the interrupt storm ------------
        ; Moon Patrol's actual shape: 80STORE+PAGE2 steer the hires page
        ; ($2000-$3FFF) between main and aux, holding DIFFERENT bytes in
        ; each, flipped under the interrupt storm.  The CAM serves rung-2
        ; reads on a virtual tag and is kept honest only by the flash-clear
        ; on map_changed; a stale line surviving a flip serves the WRONG
        ; BANK's byte.  Both the compares here and the reference catch it.
        jsr hgrtest
        jcs fail

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
        ; Code RESIDENT in $C3xx (the testbench pokes it into the internal
        ; ROM image): the first fetch rides the sequencer and sets INTC8ROM,
        ; every fetch after that is the front's (accel_tb: turbo_c3).
        jsr $C380               ; LDX #16 / DEX / BNE / RTS - one line
        jsr $C380               ; one clock throughout now
        jsr $C39A               ; a loop across two lines: the crossing
        jsr $C372               ; LDX $CFFF / RTS - the 80-column firmware's
                                ; own shape: the clear, then an RTS the front
                                ; must NOT serve - it re-sets the latch...
        lda $C800               ; ...so this is the internal ROM again
        lda $CFFF               ; clear
        sta $C007               ; INTCXROM on
        jsr $C380               ; sets INTC8ROM on the machine regardless
        sta $C006               ; INTCXROM off...
        lda $C800               ; ...and $C800 is STILL internal (UTAIIe 5-28)
        lda $CFFF               ; clear: back to the entry state
        rts

sub:    lda #$C3
        rts

; The data front under an interrupt storm.  A timer in the testbench pulls
; IRQ' low while IRQARM is set and releases it when the ISR acks, so an
; interrupt interposes on the accelerated data stream at every phase of
; every instruction - the Moon Patrol lockup's shape (Mockingboard timer
; IRQs over HGR-heavy code).  The traffic hammers all three servers: the
; zero-page/stack shadow, the CAM across a spread of $6000-$7FFF lines, and
; the last byte through crossing reads' FIXUP dummies.  A byte served wrong
; across an interposed interrupt fails the testbench's own program-order
; reference immediately; the self-checks here are a second net.  Carry set
; on failure.  Runs in the default map with A/X/Y all its own.
irqtest:
        ; A known-safe map: main memory both ways, ALTZP off, ROM readable
        ; at the vectors, bank 0 - so the ISR (resident in RAM) is reached
        ; through the ROM vector and touches only main.
        lda $C082               ; LC reads ROM ($D000-$FFFF the vector's home)
        sta $C000               ; 80STORE off
        sta $C002               ; RAMRD main
        sta $C004               ; RAMWRT main
        sta $C008               ; ALTZP main
        lda #$00
        sta $C073               ; RamWorks bank 0
        sta ISRC
        ; A deterministic pattern: $7000+i = i, $7100+i = i.
        ldx #$00
@fill:  txa
        sta $7000,x
        sta $7100,x
        inx
        bne @fill
        ; Start the storm, then unmask: interrupts fire only across this
        ; hammer, never in the delicate phases above.
        lda #$01
        sta IRQARM
        cli
        ; Hammer: a few passes over the page, each iteration a crossing read
        ; (FIXUP), a straight read (shadow/CAM), a copy (splice), and a
        ; stack round trip whose byte must survive the interposition.  Kept
        ; small so mode 0's 98-clocks-a-cycle stays inside the timeout; the
        ; interrupt RATE, not the loop size, is what saturates the window.
        ldy #$04
@outer: ldx #$00
@inner: lda $6000,x             ; a spread of CAM lines under pressure: this
        lda $6800,x             ; code's own pages, tracked by the reference
        lda $70FF,x             ; crosses to $7100+ at x>=1: FIXUP re-reads operand
        lda $7000,x             ; = x, straight through a server
        sta $7200,x             ; copy out, splicing into any holder
        pha                     ; onto the stack (shadow page 1)
        pla                     ; back off it
        cmp $7000,x             ; the pulled byte must still be x
        jne irqbad
        ; Every 64 iterations flip the video switches - PAGE2 then HIRES,
        ; net-neutral with 80STORE off (no change to what RAM the reads
        ; resolve to) but each edge pulses map_changed, so the CAM flash-
        ; clears mid-stream while interrupts interpose: Moon Patrol's shape
        ; (page flipping under a music IRQ), aimed at the rung-2 mechanism
        ; a bench has never raced.
        txa
        and #$3F
        bne @nosw
        sta $C055               ; PAGE2 on  -> map_changed
        sta $C054               ; PAGE2 off -> map_changed
        lda $C057               ; HIRES on  -> map_changed
        lda $C056               ; HIRES off -> map_changed
@nosw:  inx
        bne @inner
        dey
        bne @outer
        ; Mask, stop the storm, then verify quietly that nothing moved.
        sei
        lda #$00
        sta IRQARM
        ldx #$00
@ver:   txa
        cmp $7000,x             ; the source is untouched
        jne irqbad
        txa
        cmp $7200,x             ; the copy took every byte faithfully
        jne irqbad
        inx
        bne @ver
        clc
        rts
irqbad:   sei
        lda #$00
        sta IRQARM              ; never leave the storm running on the way out
        sec
        rts

; The interrupt service routine, resident in RAM (this segment runs at
; $6000+).  Reached through the ROM IRQ vector; preserves every register,
; exercises a server or two from inside the interrupt, acks so the testbench
; releases IRQ', and returns.  Touches only its own page-3 scratch and reads.
irqsvc: pha
        phx
        phy
        inc ISRC                ; abs RMW at $03F9: a LAST dummy in the ISR
        lda IPTR                ; a zero-page read through the shadow
        ldx #$01
        lda $70FF,x             ; a crossing read: the ISR's own FIXUP dummy
        lda #$01
        sta ISRA                ; ack: the testbench drops IRQ'
        ply
        plx
        pla
        rti

; HGR page-flipping under the storm.  80STORE on and HIRES on steer the
; hires page by PAGE2; $2000+i holds i in main and i EOR $FF in aux.  The
; loop flips PAGE2 (a bus op, so map_changed and the CAM flash-clear have
; the whole cycle) and reads each bank back under interrupts, twice per
; side so the CAM fills then serves.  A stale virtual-tagged line surviving
; a flip reads as the wrong bank.  The ISR stays map-neutral (zero page,
; page 1, page 3 - none of them the hires page), so it never disturbs the
; pattern.  Carry set on failure.
hgrtest:
        lda $C082               ; ROM at the vectors
        sta $C001               ; 80STORE on
        sta $C057               ; HIRES on: $2000-$3FFF now steered by PAGE2
        sta $C008               ; ALTZP off (the ISR's zp/stack are main)
        lda #$00
        sta $C073               ; bank 0
        sta $C054               ; PAGE2 off: writes reach main
        ldx #$00
@hfm:   txa
        sta $2000,x
        inx
        bne @hfm
        sta $C055               ; PAGE2 on: writes reach aux
        ldx #$00
@hfa:   txa
        eor #$FF
        sta $2000,x
        inx
        bne @hfa
        sta $C054               ; PAGE2 off
        lda #$01
        sta IRQARM
        cli
        ldy #$08
@hl:    sta $C054               ; PAGE2 off: $2000+x reads main = x
        jsr @rdm
        jcs @hbad
        jsr @rdm
        jcs @hbad
        sta $C055               ; PAGE2 on: $2000+x reads aux = x EOR $FF
        jsr @rda
        jcs @hbad
        jsr @rda
        jcs @hbad
        dey
        bne @hl
        sei
        lda #$00
        sta IRQARM
        sta $C054               ; PAGE2 off
        sta $C000               ; 80STORE off
        sta $C056               ; HIRES off
        clc
        rts
@hbad:  sei
        lda #$00
        sta IRQARM
        sta $C054
        sta $C000
        sta $C056
        sec
        rts
@rdm:   ldx #$00
@rml:   txa
        cmp $2000,x             ; main byte is x
        bne @hf
        inx
        bne @rml
        clc
        rts
@rda:   ldx #$00
@ral:   txa
        eor #$FF
        cmp $2000,x             ; aux byte is x EOR $FF
        bne @hf
        inx
        bne @ral
        clc
        rts
@hf:    sec
        rts

; The CMOS dummy re-reads, made unavoidable: a page-crossing indexed read's
; FIXUP cycle re-reads the operand byte - here in RAM, in dumrom's twin in
; ROM - and an absolute RMW's LAST cycle re-reads its own target.  The data
; front's last-byte register (rtl/dline.sv) is the only server for a cold
; one; the testbench checks its count.  Carry set on failure.
dumtest:
        lda #$5A
        sta $6BFF
        lda #$A5
        sta $6C00
        ldx #$01
        lda $6BFF,x             ; crosses into $6C00: FIXUP re-reads the operand
        cmp #$A5
        jne dumfail
        lda #$11
        sta $6D00
        inc $6D00               ; absolute RMW: LAST re-reads $6D00
        lda $6D00
        cmp #$12
        jne dumfail
        jsr dumrom              ; the twin with its operand bytes in ROM
        bcs dumfail
        clc
        rts
dumfail:
        sec
        rts

fail:   lda #$FF
        sta FAILF
halt:   jmp halt

; The operand of an immediate is rewritten and at once executed; then an
; instruction's OPCODE is rewritten, both ways.  The compares read the
; patched byte back through the data side, so a fetch served stale from an
; instruction cache disagrees with its own memory and fails here.  Below
; `fail` so the branches above keep their range.
smctest:
        ldx #4
smloop: txa
        ora #$30
        sta smimm+1             ; patch the operand below
smimm:  lda #$00
        cmp smimm+1             ; the byte, read back as data
        jne smfail
        dex
        bne smloop
        lda #$E8                ; INX
        sta smop
        ldx #7
        jsr smrun
        cpx #8
        jne smfail
        lda #$CA                ; DEX: the same byte, the other way
        sta smop
        ldx #7
        jsr smrun
        cpx #6
        jne smfail
        ; The store INTO THE NEXT OPCODE, and into the next instruction's
        ; operand: the tightest self-modification there is.  Under rung 3
        ; the store retires in one clock and the patched fetch is the very
        ; next clock (the opcode) or the one after (the operand); the front
        ; that held the line must kill it in between.
        ldx #7
        lda #$E8                ; INX
        sta smnx
smnx:   nop                     ; becomes INX, fetched the clock after the store
        cpx #8
        jne smfail
        lda #$EA                ; NOP again, for the next pass
        sta smnx
        lda #$5A
        sta smnx2+1
smnx2:  lda #$00                ; the operand is the byte just stored
        cmp #$5A
        jne smfail
        lda #$00
        sta smnx2+1
        clc
        rts
smrun:
smop:   nop                     ; becomes INX, then DEX
        rts
smfail: sec
        rts

; Rung 3's food (rtl/dline.sv, splice + post).  Twelve pushes in a row
; supply the posted FIFO faster than the page cache drains it, so writes
; WAIT for a slot and must never fall to the dispatcher; a line nothing on
; the front holds is written whole and read straight back, so the read
; waits the drain out; the zero page is written and read byte by byte
; through the shadow's splice.  Carry set on failure.
wrtest:
        ldx #12
wrpush: txa
        pha
        dex
        bne wrpush
        ldx #1
wrpop:  pla
        stx SMCTMP
        cmp SMCTMP
        bne wrbad
        inx
        cpx #13
        bne wrpop
        ldx #0
wrfill: txa
        eor PASS
        sta $0F80,x
        inx
        cpx #16
        bne wrfill
        ldx #0
wrver:  txa
        eor PASS
        cmp $0F80,x
        bne wrbad
        inx
        cpx #16
        bne wrver
        ldx #16
wrzp:   txa
        eor #$A5
        sta $E0,x
        cmp $E0,x
        bne wrbad
        dex
        bne wrzp
        clc
        rts
wrbad:  sec
        rts

; Self-modifying code into a hot icache line - the Moon Patrol shape.  Each
; of the four target lines below is 16-byte aligned and holds an LDA #imm
; whose operand sits at a DIFFERENT offset (1,4,7,10); the sweep patches
; that operand from here (a different line) and calls the target, which is
; hot in the icache from the previous pass.  A stale operand fetch - the
; front serving a cached line the cross-line write did not invalidate -
; shows as SMCRES != the value patched in.  Carry set on failure.
        ; The loop body straddles two 16-byte lines: the STA and its NOP
        ; fill in the first, the patched LDA and the loop control in the
        ; second.  Both lines are executed every pass, so both stay hot in
        ; the icache; the STA patches the OPERAND of the LDA one line ahead,
        ; which the icache holds cached from the previous pass.  This is the
        ; Moon Patrol shape (a compiled sprite patching a hot line it is
        ; about to fall through).  The STA (3 bytes) plus 13 NOPs is exactly
        ; 16, so smctgt is one line after @lp whatever @lp's own offset.
; One variant of the loop: the STA sits N bytes into its line, so its cycle
; falls at a different phase against the scanner's prefetch of the next line
; - and STA(3)+N+.res(13-N) is always 16, so the patched line is exactly one
; line on whatever N.  Sweeping N walks the STA across the window; the phase
; that lands the prefetch's bank read on the write's P+2 fetches stale.
.macro SMCV n
        .ident(.sprintf("smcvlp%d", n)):
        .res n, $EA
        stx .ident(.sprintf("smcvt%d", n)) + 1
        .res 13 - n, $EA
        .ident(.sprintf("smcvt%d", n)):
        lda #$00
        sta SMCRES
        lda SMCRES
        stx SMCTMP
        cmp SMCTMP
        bne .ident(.sprintf("smcvb%d", n))
        inx
        bne .ident(.sprintf("smcvlp%d", n))
        clc
        rts
        .ident(.sprintf("smcvb%d", n)):
        sec
        rts
.endmacro

.macro SMCVDEF n
        .ident(.sprintf("smcv%d", n)):
        ldx #$00
        SMCV n
.endmacro

.macro SMCVCALL n
        jsr .ident(.sprintf("smcv%d", n))
        jcs smcsweep_bad
.endmacro

smcsweep:
        SMCVCALL 0
        SMCVCALL 1
        SMCVCALL 2
        SMCVCALL 3
        SMCVCALL 4
        SMCVCALL 5
        SMCVCALL 6
        SMCVCALL 7
        SMCVCALL 8
        SMCVCALL 9
        SMCVCALL 10
        SMCVCALL 11
        SMCVCALL 12
        SMCVCALL 13
        clc
        rts
smcsweep_bad:
        sec
        rts
        SMCVDEF 0
        SMCVDEF 1
        SMCVDEF 2
        SMCVDEF 3
        SMCVDEF 4
        SMCVDEF 5
        SMCVDEF 6
        SMCVDEF 7
        SMCVDEF 8
        SMCVDEF 9
        SMCVDEF 10
        SMCVDEF 11
        SMCVDEF 12
        SMCVDEF 13

; The branch-prefetch front's food (rtl/iline.sv, rtl/iscan.sv).  Carry set
; on failure.  Every loop is wider than one 16-byte line, so the two-slot
; front cannot hold it by linearity alone: the loop bit pins a two-line
; pair, the retention CAM promotes the rest, and every refetched byte is
; checked against the reference by the testbench as always.
bptest:
        ; A. a clean hot loop wider than one line: pinned, or promoted -
        ; and correct either way.
        ldy #16
        ldx #0
bpa:    inx
        .repeat 16
        nop
        .endrep
        dey
        bne bpa
        cpx #16
        jne bpfail

        ; B. the same shape rewriting its own immediate every iteration:
        ; the write lands inside the pinned pair, the pinned line must die
        ; and refetch, and the sum proves every patched operand was seen.
        ldy #16
        ldx #0
        stz $40
bpb:    inx
        txa
        sta bpb1+1
        clc
bpb1:   lda #$00
        adc $40
        sta $40
        .repeat 6
        nop
        .endrep
        dey
        bne bpb
        lda $40
        cmp #136                ; 1 + 2 + ... + 16
        jne bpfail

        ; C. a loop no pair can hold - three to four lines: after the
        ; first iteration every line is retained, and the crossings
        ; promote instead of refetching.
        ldy #16
        ldx #0
bpc:    inx
        .repeat 40
        nop
        .endrep
        dey
        bne bpc
        cpx #16
        jne bpfail

        ; D. calls the scanner follows, each far enough to be its own
        ; line: the target lines are prefetched and then retained.
        ldy #16
        ldx #0
bpd:    nop
        nop
        nop
        nop
        jsr bpf1
        jsr bpf2
        dey
        bne bpd
        cpx #32
        jne bpfail

        ; E. the retained line's own hazard: run a routine, roll the slots
        ; well past its lines (the CAM still holds them), rewrite its
        ; opcode, run back into it.  The write must kill the RETAINED
        ; copy, or the promote serves the stale instruction and x comes
        ; back +1 instead of -1.
        ldx #0
        jsr bpcx                ; x = 1, the line fetched and retained
        .repeat 32
        nop                     ; the slots roll two lines past bpcx's
        .endrep
        lda #$CA                ; DEX
        sta bpcx1
        ldx #5
        jsr bpcx                ; must run the DEX: x = 4
        cpx #4
        jne bpfail
        lda #$E8                ; INX back, for the next pass
        sta bpcx1
        clc
        rts
bpfail: sec
        rts

; D's callees, padded apart so each is its own line.
bpf1:   inx
        rts
        .repeat 12
        nop
        .endrep
bpf2:   inx
        rts
        .repeat 12
        nop
        .endrep
; E's routine, padded so its patched byte sits clear of the call site.
bpcx:   .repeat 6
        nop
        .endrep
bpcx1:  inx
        rts

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

; bankfetch: the hazard Nox Archaist's splash found on hardware (2026-09-04).
; A program that sits in both banks flips RAMRD and simply keeps executing -
; the next opcode fetch, the next data read, the next write must all see
; the NEW bank, with no instruction in between.  On the bus that always
; held: a switch's commit lands clocks before the core's next op can be
; served.  A switch served on the card (steps 3/4) retires with a
; synthetic commit one clock after the core moved, so the fronts and the
; dispatcher have to hold until the shadow and map_changed have landed.
; Four stubs at $1F00-$1F3F, identical in both banks except for the byte
; under test; each called twice so the second time runs with the stub's
; line resident in the CAM under the OLD bank.  Carry set on failure;
; RAMRD/RAMWRT are off again before any return, and the stack (main, ALTZP
; off) is untouched by the flips.
bankfetch:
        ; write the main copy, then the aux copy, of the stubs
        ldx #0
bf_wm:  lda bf_main,x
        sta $1F00,x
        inx
        cpx #bf_len
        bne bf_wm
        sta $C005               ; RAMWRT aux
        ldx #0
bf_wa:  lda bf_aux,x
        sta $1F00,x
        inx
        cpx #bf_len
        bne bf_wa
        sta $C004               ; RAMWRT main
        ; stub 1: RAMRD on, then the very next OPCODE byte is aux's DEX (main
        ; has INX there): the one byte the front can serve before the kill
        ldx #0
        jsr $1F00
        cpx #$FF
        jne bf_fail
        ldx #0
        jsr $1F00               ; again, the main line resident
        cpx #$FF
        jne bf_fail
        ; stub 2: RAMRD on, then the next DATA READ is aux's $1F80 = $44
        jsr $1F10
        cmp #$44
        jne bf_fail
        jsr $1F10
        cmp #$44
        jne bf_fail
        ; stub 3: RAMWRT on, then the next WRITE lands in aux $1F90
        lda #$77
        sta $1F90               ; main's copy: $77
        lda #$88
        jsr $1F20               ; aux's copy: $88
        lda $1F90
        cmp #$77
        jne bf_fail
        sta $C003               ; RAMRD aux (this code is in ROM)
        lda $1F90
        sta $C002
        cmp #$88
        jne bf_fail
        lda #$99
        jsr $1F20               ; again
        sta $C003
        lda $1F90
        sta $C002
        cmp #$99
        jne bf_fail
        ; stub 4: RAMRD off, from aux: the next opcode is main's INX (aux: DEX)
        ldx #0
        sta $C003               ; enter the stub with RAMRD on: aux's copy runs
        jsr $1F30
        cpx #1
        jne bf_fail
        ldx #0
        sta $C003
        jsr $1F30
        cpx #1
        jne bf_fail
        clc
        rts
bf_fail:
        sta $C002
        sta $C004
        sec
        rts
; the stubs: 16 bytes each, at $1F00, $1F10, $1F20, $1F30; $1F80/$1F90 data
bf_main:
        .byte $8D,$03,$C0, $E8, $8D,$02,$C0, $60, $EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA   ; $1F00 STA $C003; INX; STA $C002; RTS
        .byte $8D,$03,$C0, $AD,$80,$1F, $8D,$02,$C0, $60, $EA,$EA,$EA,$EA,$EA,$EA   ; $1F10 STA $C003; LDA $1F80; STA $C002; RTS
        .byte $8D,$05,$C0, $8D,$90,$1F, $8D,$04,$C0, $60, $EA,$EA,$EA,$EA,$EA,$EA   ; $1F20 STA $C005; STA $1F90; STA $C004; RTS
        .byte $8D,$02,$C0, $E8, $60, $EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA    ; $1F30 STA $C002; INX; RTS
        .res  $40, $EA                                                               ; $1F40-$1F7F
        .byte $33                                                                    ; $1F80
        .res  $0F, $EA
        .byte $00                                                                    ; $1F90
bf_len = * - bf_main
bf_aux:
        .byte $8D,$03,$C0, $CA, $8D,$02,$C0, $60, $EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA   ; $1F00: DEX here
        .byte $8D,$03,$C0, $AD,$80,$1F, $8D,$02,$C0, $60, $EA,$EA,$EA,$EA,$EA,$EA
        .byte $8D,$05,$C0, $8D,$90,$1F, $8D,$04,$C0, $60, $EA,$EA,$EA,$EA,$EA,$EA
        .byte $8D,$02,$C0, $CA, $60, $EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA    ; $1F30: DEX here (must NOT run)
        .res  $40, $EA
        .byte $44                                                                    ; $1F80: aux's byte
        .res  $0F, $EA
        .byte $00

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

; dumtest's twin, resident in ROM so the crossing's FIXUP dummy re-reads a
; ROM operand byte - the last-byte serve's ROM-class case.
dumrom: lda #$77
        sta $6E00
        ldx #$01
        lda $6DFF,x             ; crosses into $6E00: FIXUP re-reads ROM
        cmp #$77
        beq dumrom_ok
        sec
        rts
dumrom_ok:
        clc
        rts

.segment "VECTORS"
        .word reset, reset, irqsvc
