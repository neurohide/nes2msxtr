; MMC3 test ROM for the nes2msxtr translator (64K PRG in 8K banks, 32K CHR
; ROM in 1K banks, horizontal mirroring). Original code.
;
; Banks 0, 2, 4 are built for $8000 (R6), 1, 3, 5 for $A000 (R7). Reset
; runs self-checks: the same addresses in different banks of each slot, in
; pairs and not (2 at $8000 with 5 at $A000), a call from $8000 code into
; whatever $A000 holds, fixed code reading both slots, a JMP (ptr) table in
; a bank, the 2-byte NOP skip trick, a return address pushed by hand before
; JMP (ptr), STA / RTS code built in RAM, CHR ROM banks read through $2007
; with and without the $8000 bit 7 inversion, and $A000 mirroring.
; testfail = number of the first failing check (0 = all passed); results
; are folded into cks. The backdrop turns green on a pass, red on a fail.
;
; NMI calls into bank 0 and restores R6, switches R2 every 16 frames and
; arms the scanline IRQ (latch 50); the IRQ handler changes the X scroll
; and arms the next one 61 lines further down, until frame 100, so RAM and
; CHR can be compared between implementations.

PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
OAMADDR   = $2003
PPUSCROLL = $2005
PPUADDR   = $2006
PPUDATA   = $2007
OAMDMA    = $4014

ptr      = $00                  ; 2 bytes
jptr     = $02                  ; 2 bytes
frame    = $10
testfail = $11
cks      = $12                  ; 2 bytes
res      = $14
nmicnt   = $15
irqcnt   = $16
irqline  = $17                  ; IRQs so far this frame
chrsum   = $18
r6       = $19                  ; banks mapped by map6 / map7
r7       = $1A
ramout   = $0300
ramcode  = $0700

; CHR ROM byte at offset o of 1K bank k
.define CHRB(k, o) (((k) * 29 + (o) * 7 + ((o) >> 4)) & $FF)

CHR_9_5  = CHRB 9, 5
CHR_20_5 = CHRB 20, 5
CHR_20_7 = CHRB 20, 7
CHR_9_9  = CHRB 9, 9

; same layout in each bank of a slot; the first one's labels are used
.macro slot0 id
        .local t0, t1, jt
        .byte id                ; $8000: bank number
.if id = 0
s0_entry:
.endif
        lda $8000               ; A = $80 + bank
        ora #$80
        rts
.if id = 0
s0_cross:
.endif
        jsr s1_entry            ; the bank at $A000, whatever it is
        clc
        adc #id * 8
        rts
.if id = 0
s0_jump:
.endif
        asl a                   ; A = case
        tax
        lda jt,x
        sta jptr
        lda jt + 1,x
        sta jptr + 1
        jmp (jptr)
t0:     lda #$40 + id
        rts
t1:     lda #$50 + id
        rts
jt:     .word t0, t1
.if id = 0
s0_skip:
.endif
        ldx #$10 + id           ; A = 1: X + 1
        cmp #1
        beq :+
        .byte $80               ; 2-byte NOP: skips the INX
:       inx
        txa
        rts
.if id = 0
s0_nmi:
.endif
        inc nmicnt
        rts
.endmacro

.macro slot1 id
        .byte id                ; $A000: bank number
.if id = 1
s1_entry:
.endif
        lda $A000               ; A = $90 + bank
        ora #$90
        rts
.if id = 1
s1_table:
.endif
        .byte $20 + id, $30 + id, $40 + id, $50 + id
.endmacro

.segment "HEADER"
        .byte "NES", $1A, 4, 4, $40, $00
        .res 8, 0

.segment "BANK0"
        slot0 0
.segment "BANK1"
        slot1 1
.segment "BANK2"
        slot0 2
.segment "BANK3"
        slot1 3
.segment "BANK4"
        slot0 4
.segment "BANK5"
        slot1 5

.segment "CHARS"
.repeat 32, k
.repeat 1024, o
        .byte CHRB k, o
.endrep
.endrep

.segment "CODE"

reset:
        sei
        cld
        ldx #$FF
        txs
        inx
        stx PPUCTRL
        stx PPUMASK
        stx $E000               ; no IRQ
@vb1:   bit PPUSTATUS
        bpl @vb1
        txa
@clr:   sta $00,x
        sta $0300,x
        sta $0700,x
        inx
        bne @clr
        lda #$F8
@oam:   sta $0200,x
        inx
        bne @oam
@vb2:   bit PPUSTATUS
        bpl @vb2

        jsr tests
        jsr screen

        lda #0                  ; banks 0 / 1 while idle
        jsr map6
        lda #1
        jsr map7
        lda #$88                ; NMI on, sprites from $1000
        sta PPUCTRL
        cli                     ; scanline IRQs
forever:
        jmp forever

map6:   ldx #6                  ; A = bank for $8000
        stx $8000
        sta $8001
        sta r6
        rts
map7:   ldx #7                  ; A = bank for $A000
        stx $8000
        sta $8001
        sta r7
        rts

fail:
        lda testfail
        bne @keep
        stx testfail
@keep:  rts

addck:  clc
        adc cks
        sta cks
        lda cks + 1
        adc #0
        sta cks + 1
        rts

; A = result, expected in res; X = check number
check:  cmp res
        beq @ok
        jsr fail
@ok:    jmp addck

; PPU address A (high) / X (low) -> A = byte there (buffered read)
ppurd:  sta PPUADDR
        stx PPUADDR
        lda PPUDATA
        lda PPUDATA
        rts

pushed: lda #$66                ; returns to the address pushed by hand
        rts

tests:
        lda #0                  ; 1-2: banks 0 / 1
        jsr map6
        lda #1
        jsr map7
        jsr s0_entry
        ldx #$80
        stx res
        ldx #1
        jsr check
        jsr s1_entry
        ldx #$91
        stx res
        ldx #2
        jsr check

        lda #2                  ; 3-5: 2 / 5, not a pair
        jsr map6
        lda #5
        jsr map7
        jsr s0_entry
        ldx #$82
        stx res
        ldx #3
        jsr check
        jsr s1_entry
        ldx #$95
        stx res
        ldx #4
        jsr check
        jsr s0_cross            ; bank 2 calls bank 5
        ldx #$A5
        stx res
        ldx #5
        jsr check

        lda #4                  ; 6: 4 / 3
        jsr map6
        lda #3
        jsr map7
        jsr s0_cross
        ldx #$B3
        stx res
        ldx #6
        jsr check

        lda $8000               ; 7: fixed code reads both slots
        clc
        adc $A000
        ldx #7
        stx res
        jsr check

        lda s1_table + 2        ; 8: tables in the $A000 bank (3)
        ldx #1
        clc
        adc s1_table,x
        ldx #$76
        stx res
        ldx #8
        jsr check

        lda #1                  ; 9: JMP (ptr) table in bank 4
        jsr s0_jump
        ldx #$54
        stx res
        ldx #9
        jsr check

        lda #1                  ; 10: skip trick, both ways
        jsr s0_skip
        sta res
        lda #0
        jsr s0_skip
        clc
        adc res
        ldx #$15 + $14
        stx res
        ldx #10
        jsr check

        lda #>(@ret - 1)        ; 11: return address pushed by hand
        pha
        lda #<(@ret - 1)
        pha
        lda #<pushed
        sta jptr
        lda #>pushed
        sta jptr + 1
        jmp (jptr)
@ret:   ldx #$66
        stx res
        ldx #11
        jsr check

        lda #$8D                ; 12: STA ramout / RTS built in RAM
        sta ramcode
        lda #<ramout
        sta ramcode + 1
        lda #>ramout
        sta ramcode + 2
        lda #$60
        sta ramcode + 3
        lda #$5A
        jsr ramcode
        lda ramout
        ldx #$5A
        stx res
        ldx #12
        jsr check

        ldx #0                  ; 13: CHR banks through $2007: R0 = 8
        stx $8000               ; at $0000-$07FF, R2 = 20 at $1000
        lda #8
        sta $8001
        ldx #2
        stx $8000
        lda #20
        sta $8001
        lda #$04
        ldx #$05
        jsr ppurd               ; bank 9, offset $405 & $3FF
        sta chrsum
        lda #$10
        ldx #$05
        jsr ppurd               ; bank 20, offset 5
        clc
        adc chrsum
        sta chrsum
        lda #$80                ; inverted: R2 at $0000, R0 at $1000
        sta $8000
        lda #$00
        ldx #$07
        jsr ppurd               ; bank 20, offset 7
        clc
        adc chrsum
        sta chrsum
        lda #$14
        ldx #$09
        jsr ppurd               ; bank 9, offset $409 & $3FF
        clc
        adc chrsum
        ldx #(CHR_9_5 + CHR_20_5 + CHR_20_7 + CHR_9_9) & $FF
        stx res
        ldx #13
        jsr check
        lda #$00                ; back: not inverted
        sta $8000

        lda #0                  ; 14: vertical, then horizontal mirroring
        sta $A000
        lda #$24
        sta PPUADDR
        lda #$00
        sta PPUADDR
        lda #$55
        sta PPUDATA
        lda #$2C
        ldx #$00
        jsr ppurd               ; $2C00 = $2400
        sta chrsum
        lda #1
        sta $A000
        lda #$20
        sta PPUADDR
        lda #$01
        sta PPUADDR
        lda #$66
        sta PPUDATA
        lda #$24
        ldx #$01
        jsr ppurd               ; $2401 = $2001
        clc
        adc chrsum
        ldx #$55 + $66
        stx res
        ldx #14
        jsr check
        rts

; palette, rows of tiles from the CHR banks; backdrop by result
screen:
        lda #$3F
        sta PPUADDR
        lda #$00
        sta PPUADDR
        lda #$1A                ; green: pass
        ldx testfail
        beq @pass
        lda #$16                ; red: fail
@pass:  sta PPUDATA
        lda #$0F
        sta PPUDATA
        lda #$20
        sta PPUDATA
        lda #$12
        sta PPUDATA
        lda #$20                ; rows 8-15 of nametable 0: tiles 0-255
        sta PPUADDR
        lda #$00
        sta PPUADDR
        ldx #0
@clr:   lda #0
        sta PPUDATA
        sta PPUDATA
        sta PPUDATA
        sta PPUDATA
        inx
        bne @clr
        lda #$21
        sta PPUADDR
        lda #$00
        sta PPUADDR
        ldx #0
@row:   stx PPUDATA
        inx
        bne @row
        lda #$1E
        sta PPUMASK
        rts

nmi:
        pha
        txa
        pha
        tya
        pha
        lda frame
        cmp #100
        bne @run
        sta $E000               ; done: no more IRQs
        jmp @out
@run:   inc frame
        lda r6                  ; bank 0 for the handler, then back
        pha
        lda #0
        jsr map6
        jsr s0_nmi
        pla
        jsr map6
        lda frame               ; every 16 frames: another bank in R2
        and #15
        bne @same
        lda #2
        sta $8000
        lda frame
        lsr a
        lsr a
        lsr a
        lsr a
        clc
        adc #16
        sta $8001
@same:  lda #0
        sta irqline
        lda #50                 ; first IRQ after line 49
        sta $C000
        sta $C001
        sta $E001
        lda #0
        sta PPUSCROLL
        sta PPUSCROLL
@out:   pla
        tay
        pla
        tax
        pla
        rti

irq:
        pha
        txa
        pha
        sta $E000               ; acknowledge (and stop)
        inc irqcnt
        ldx irqline
        inc irqline
        lda xscroll,x
        sta PPUSCROLL
        lda #0
        sta PPUSCROLL
        cpx #0
        bne @last
        lda #60                 ; the next one 61 lines further down
        sta $C000
        sta $E001
@last:  pla
        tax
        pla
        rti

xscroll:
        .byte 16, 40

.segment "VECTORS"
        .word nmi, reset, irq
